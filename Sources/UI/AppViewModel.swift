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
        static let recentVaults = "keemac.selection.recent.v1"
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

    public struct RecentVault: Identifiable, Equatable {
        public let vaultURL: URL
        public let keyFileURL: URL?

        public var id: String {
            vaultURL.standardizedFileURL.path
        }

        public var title: String {
            vaultURL.lastPathComponent
        }
    }

    private struct PersistedRecentVault: Codable {
        let vaultBookmark: Data
        let keyFileBookmark: Data?
    }

    public var selectedVaultURL: URL?
    public var selectedKeyFileURL: URL?
    public var loadState: LoadState = .idle
    public private(set) var showBiometricUnlockScreen: Bool = false
    public private(set) var recentVaults: [RecentVault] = []
    public var clipboardAutoClearTimeoutSeconds: TimeInterval {
        get { settingsStore.clipboardAutoClearTimeoutSeconds }
        set { settingsStore.clipboardAutoClearTimeoutSeconds = newValue }
    }

    public var touchIDEnabledForSelectedVault: Bool {
        settingsStore.isTouchIDEnabled(for: selectedVaultURL)
    }

    public var idleLockTimeoutForSelectedVault: TimeInterval {
        settingsStore.idleLockTimeoutSeconds(for: selectedVaultURL)
    }

    public var showDockIcon: Bool {
        settingsStore.showDockIcon
    }

    private let vaultLoader: any VaultLoading
    private let vaultEditor: (any VaultEditing)?
    private let sessionController: (any VaultSessionControlling)?
    private let biometricCredentialStore: any BiometricCredentialStoring
    private let settingsStore: AppSettingsStore
    private let userDefaults: UserDefaults
    private var idleLockTask: Task<Void, Never>?

    public init(
        vaultLoader: any VaultLoading = KeePassKitVaultLoader(),
        settingsStore: AppSettingsStore = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.vaultLoader = vaultLoader
        self.vaultEditor = vaultLoader as? any VaultEditing
        self.sessionController = vaultLoader as? any VaultSessionControlling
        self.biometricCredentialStore = KeychainBiometricCredentialStore()
        self.settingsStore = settingsStore
        self.userDefaults = userDefaults
        restorePersistedSelections()
        restoreRecentVaults()
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

    public func selectRecentVault(_ recentVault: RecentVault) {
        selectedVaultURL = recentVault.vaultURL
        selectedKeyFileURL = recentVault.keyFileURL

        persistSelection(recentVault.vaultURL, key: PersistedSelectionKey.vaultBookmark)
        if let keyFileURL = recentVault.keyFileURL {
            persistSelection(keyFileURL, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }

        refreshBiometricUnlockAvailability()
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

            let touchIDEnabled = settingsStore.isTouchIDEnabled(for: selectedVaultURL)
            if touchIDEnabled && !masterPassword.isEmpty {
                do {
                    try biometricCredentialStore.saveMasterPassword(masterPassword, for: selectedVaultURL)
                    markBiometricCredentialAvailable(for: selectedVaultURL)
                } catch {
                    SecureLogger.logUnlockFailure(error)
                }
            } else if !touchIDEnabled {
                biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
                clearBiometricCredentialMarker(for: selectedVaultURL)
            }

            recordRecentVaultUsage(vaultURL: selectedVaultURL, keyFileURL: selectedKeyFileURL)
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
            recordRecentVaultUsage(vaultURL: selectedVaultURL, keyFileURL: selectedKeyFileURL)
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

    public func setTouchIDEnabledForSelectedVault(_ isEnabled: Bool) {
        guard let selectedVaultURL else {
            return
        }

        settingsStore.setTouchIDEnabled(isEnabled, for: selectedVaultURL)

        if !isEnabled {
            biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
            clearBiometricCredentialMarker(for: selectedVaultURL)
            showBiometricUnlockScreen = false
        }

        refreshBiometricUnlockAvailability()
    }

    public func setIdleLockTimeoutForSelectedVault(_ timeout: TimeInterval) {
        settingsStore.setIdleLockTimeoutSeconds(timeout, for: selectedVaultURL)
        if case .loaded = loadState {
            registerUserActivity()
        }
    }

    public func setShowDockIcon(_ isVisible: Bool) {
        settingsStore.showDockIcon = isVisible
        NotificationCenter.default.post(
            name: AppCommand.dockIconVisibilityChanged,
            object: nil,
            userInfo: [AppCommand.dockIconVisibilityUserInfoKey: isVisible]
        )
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

    public func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.createGroup(inParentPath: parentPath, title: title, iconID: iconID)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    public func updateGroup(path: String, title: String, iconID: Int?) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.updateGroup(path: path, title: title, iconID: iconID)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    public func deleteGroup(path: String) async throws {
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: "Vault is not unlocked.")
        }

        let updatedVault = try await vaultEditor.deleteGroup(path: path)
        loadState = .loaded(updatedVault)
        registerUserActivity()
    }

    private func scheduleIdleLockTimer() {
        cancelIdleLockTimer()

        let timeout = settingsStore.idleLockTimeoutSeconds(for: selectedVaultURL)
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

    private func restoreRecentVaults() {
        guard let data = userDefaults.data(forKey: PersistedSelectionKey.recentVaults) else {
            recentVaults = []
            return
        }

        let decoder = JSONDecoder()
        guard let persistedRecentVaults = try? decoder.decode([PersistedRecentVault].self, from: data) else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            recentVaults = []
            return
        }

        var restored: [RecentVault] = []
        var seenVaultPaths = Set<String>()
        for persisted in persistedRecentVaults {
            guard let vaultURL = restoreURL(fromBookmarkData: persisted.vaultBookmark) else {
                continue
            }

            let identity = vaultIdentity(for: vaultURL)
            guard !seenVaultPaths.contains(identity) else {
                continue
            }

            let keyFileURL = persisted.keyFileBookmark.flatMap { bookmarkData in
                restoreURL(fromBookmarkData: bookmarkData)
            }
            restored.append(RecentVault(vaultURL: vaultURL, keyFileURL: keyFileURL))
            seenVaultPaths.insert(identity)

            if restored.count == 3 {
                break
            }
        }

        recentVaults = restored
        persistRecentVaults()
    }

    private func refreshBiometricUnlockAvailability() {
        guard let selectedVaultURL else {
            showBiometricUnlockScreen = false
            return
        }
        guard settingsStore.isTouchIDEnabled(for: selectedVaultURL) else {
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

    private func bookmarkData(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    private func restoreURL(fromBookmarkData bookmarkData: Data) -> URL? {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return resolvedURL
    }

    private func recordRecentVaultUsage(vaultURL: URL, keyFileURL: URL?) {
        let identity = vaultIdentity(for: vaultURL)
        recentVaults.removeAll { vaultIdentity(for: $0.vaultURL) == identity }
        recentVaults.insert(RecentVault(vaultURL: vaultURL, keyFileURL: keyFileURL), at: 0)
        if recentVaults.count > 3 {
            recentVaults = Array(recentVaults.prefix(3))
        }
        persistRecentVaults()
    }

    private func persistRecentVaults() {
        guard !recentVaults.isEmpty else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            return
        }

        let persistedVaults: [PersistedRecentVault] = recentVaults.prefix(3).compactMap { recentVault in
            guard let vaultBookmark = bookmarkData(for: recentVault.vaultURL) else {
                return nil
            }
            let keyFileBookmark = recentVault.keyFileURL.flatMap { keyFileURL in
                bookmarkData(for: keyFileURL)
            }
            return PersistedRecentVault(vaultBookmark: vaultBookmark, keyFileBookmark: keyFileBookmark)
        }

        if persistedVaults.isEmpty {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            recentVaults = []
            return
        }

        guard let encoded = try? JSONEncoder().encode(persistedVaults) else {
            return
        }
        userDefaults.set(encoded, forKey: PersistedSelectionKey.recentVaults)
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
