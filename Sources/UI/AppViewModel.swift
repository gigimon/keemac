import Data
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class AppViewModel {
    private enum PersistedSelectionKey {
        static let vaultBookmark = "keemac.selection.vault.bookmark"
        static let keyFileBookmark = "keemac.selection.keyfile.bookmark"
        static let biometricVaultPath = "keemac.selection.biometric.vault.path"
    }

    public enum LockReason: String, Sendable {
        case userInitiated
        case idleTimeout
        case systemSleep

        var message: String {
            switch self {
            case .userInitiated:
                return "Vault was locked."
            case .idleTimeout:
                return "Vault was locked after inactivity timeout."
            case .systemSleep:
                return "Vault was locked because the system is going to sleep."
            }
        }
    }

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded(LoadedVault)
        case locked(String)
        case failed(String)
    }

    public var selectedVaultURL: URL?
    public var selectedKeyFileURL: URL?
    public var loadState: LoadState = .idle
    public var idleLockTimeoutSeconds: TimeInterval = 300
    public private(set) var showBiometricUnlockScreen: Bool = false

    private let vaultLoader: any VaultLoading
    private let vaultEditor: (any VaultEditing)?
    private let sessionController: (any VaultSessionControlling)?
    private let biometricCredentialStore: any BiometricCredentialStoring
    private let userDefaults: UserDefaults
    private var idleLockTask: Task<Void, Never>?

    public init(
        vaultLoader: any VaultLoading = KeePassKitVaultLoader(),
        userDefaults: UserDefaults = .standard
    ) {
        self.vaultLoader = vaultLoader
        self.vaultEditor = vaultLoader as? any VaultEditing
        self.sessionController = vaultLoader as? any VaultSessionControlling
        self.biometricCredentialStore = KeychainBiometricCredentialStore()
        self.userDefaults = userDefaults
        restorePersistedSelections()
        refreshBiometricUnlockAvailability()
    }

    public func selectVault(url: URL) {
        selectedVaultURL = url
        persistSelection(url, key: PersistedSelectionKey.vaultBookmark)
        refreshBiometricUnlockAvailability()
        loadState = .idle
    }

    public func clearVaultSelection() {
        selectedVaultURL = nil
        userDefaults.removeObject(forKey: PersistedSelectionKey.vaultBookmark)
        showBiometricUnlockScreen = false
        loadState = .idle
    }

    public func selectKeyFile(url: URL?) {
        selectedKeyFileURL = url
        if let url {
            persistSelection(url, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }
        loadState = .idle
    }

    public func unlock(masterPassword: String) async {
        guard let selectedVaultURL else {
            loadState = .failed("Select a .kdbx file first.")
            return
        }

        cancelIdleLockTimer()
        loadState = .loading

        do {
            let loadedVault = try await vaultLoader.loadVault(
                from: selectedVaultURL,
                masterPassword: masterPassword,
                keyFileURL: selectedKeyFileURL
            )

            if !masterPassword.isEmpty {
                do {
                    try biometricCredentialStore.saveMasterPassword(masterPassword, for: selectedVaultURL)
                    markBiometricCredentialAvailable(for: selectedVaultURL)
                } catch {
                    SecureLogger.logUnlockFailure(error)
                }
            }

            refreshBiometricUnlockAvailability()
            loadState = .loaded(loadedVault)
            registerUserActivity()
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? "Unknown error"
            loadState = .failed(message)
        }
    }

    public func unlockWithBiometrics() async {
        guard let selectedVaultURL else {
            loadState = .failed("Select a .kdbx file first.")
            return
        }
        cancelIdleLockTimer()
        loadState = .loading

        do {
            let prompt = "Unlock \(selectedVaultURL.lastPathComponent)"
            let password = try await biometricCredentialStore.loadMasterPassword(for: selectedVaultURL, prompt: prompt)

            let loadedVault = try await vaultLoader.loadVault(
                from: selectedVaultURL,
                masterPassword: password,
                keyFileURL: selectedKeyFileURL
            )
            refreshBiometricUnlockAvailability()
            loadState = .loaded(loadedVault)
            registerUserActivity()
        } catch let biometricError as BiometricCredentialError {
            SecureLogger.logUnlockFailure(biometricError)
            switch biometricError {
            case .credentialNotFound:
                clearBiometricCredentialMarker(for: selectedVaultURL)
                refreshBiometricUnlockAvailability()
                loadState = .failed(biometricError.localizedDescription)
            case .userCancelled:
                loadState = .idle
            default:
                loadState = .failed(biometricError.localizedDescription)
            }
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? "Unknown error"
            loadState = .failed(message)
        }
    }

    public func disableBiometricUnlockScreen() {
        showBiometricUnlockScreen = false
    }

    public func registerUserActivity() {
        guard case .loaded = loadState else {
            return
        }
        scheduleIdleLockTimer()
    }

    public func lockVault(reason: LockReason) {
        guard case .loaded = loadState else {
            return
        }

        cancelIdleLockTimer()
        SecureLogger.logVaultLocked(reason: reason.rawValue)
        refreshBiometricUnlockAvailability()
        loadState = .locked(reason.message)
        if let sessionController {
            Task {
                await sessionController.clearLoadedSession()
            }
        }
    }

    public func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.createEntry(inGroupPath: groupPath, form: form)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    public func updateEntry(id: UUID, form: VaultEntryForm) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.updateEntry(id: id, form: form)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    public func deleteEntry(id: UUID) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.deleteEntry(id: id)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    private func scheduleIdleLockTimer() {
        cancelIdleLockTimer()

        let timeout = idleLockTimeoutSeconds
        guard timeout > 0 else {
            return
        }

        idleLockTask = Task { [weak self] in
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.lockVault(reason: .idleTimeout)
            }
        }
    }

    private func cancelIdleLockTimer() {
        idleLockTask?.cancel()
        idleLockTask = nil
    }

    private func persistSelection(_ url: URL, key: String) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmarkData, forKey: key)
        } catch {
            SecureLogger.logUnlockFailure(error)
        }
    }

    private func restorePersistedSelections() {
        selectedVaultURL = restoreSelection(for: PersistedSelectionKey.vaultBookmark)
        selectedKeyFileURL = restoreSelection(for: PersistedSelectionKey.keyFileBookmark)
    }

    private func refreshBiometricUnlockAvailability() {
        guard let selectedVaultURL else {
            showBiometricUnlockScreen = false
            return
        }

        let vaultPath = vaultIdentity(for: selectedVaultURL)
        if userDefaults.string(forKey: PersistedSelectionKey.biometricVaultPath) == vaultPath {
            showBiometricUnlockScreen = true
            return
        }

        // Fallback path for older runs where marker is missing.
        if biometricCredentialStore.hasSavedMasterPassword(for: selectedVaultURL) {
            markBiometricCredentialAvailable(for: selectedVaultURL)
            showBiometricUnlockScreen = true
            return
        }

        showBiometricUnlockScreen = false
    }

    private func restoreSelection(for key: String) -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: key) else {
            return nil
        }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                userDefaults.removeObject(forKey: key)
                return nil
            }

            if isStale {
                persistSelection(resolvedURL, key: key)
            }

            return resolvedURL
        } catch {
            userDefaults.removeObject(forKey: key)
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    private func markBiometricCredentialAvailable(for vaultURL: URL) {
        userDefaults.set(vaultIdentity(for: vaultURL), forKey: PersistedSelectionKey.biometricVaultPath)
    }

    private func clearBiometricCredentialMarker(for vaultURL: URL) {
        let vaultPath = vaultIdentity(for: vaultURL)
        if userDefaults.string(forKey: PersistedSelectionKey.biometricVaultPath) == vaultPath {
            userDefaults.removeObject(forKey: PersistedSelectionKey.biometricVaultPath)
        }
    }

    private func vaultIdentity(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
    }
}
