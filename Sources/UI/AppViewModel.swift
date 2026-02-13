import Data
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class AppViewModel {
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

    private let vaultLoader: any VaultLoading
    private let vaultEditor: (any VaultEditing)?
    private let sessionController: (any VaultSessionControlling)?
    private var idleLockTask: Task<Void, Never>?

    public init(vaultLoader: any VaultLoading = KeePassKitVaultLoader()) {
        self.vaultLoader = vaultLoader
        self.vaultEditor = vaultLoader as? any VaultEditing
        self.sessionController = vaultLoader as? any VaultSessionControlling
    }

    public func selectVault(url: URL) {
        selectedVaultURL = url
        loadState = .idle
    }

    public func clearVaultSelection() {
        selectedVaultURL = nil
        loadState = .idle
    }

    public func selectKeyFile(url: URL?) {
        selectedKeyFileURL = url
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
            loadState = .loaded(loadedVault)
            registerUserActivity()
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? "Unknown error"
            loadState = .failed(message)
        }
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
}
