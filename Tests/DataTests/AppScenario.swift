@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

enum ScenarioError: Error {
    case notUnlocked(String)
    case missingEntry(String)
}

/// Touch ID store kept in memory, so tests never reach the keychain.
@MainActor
final class FakeBiometricCredentialStore: BiometricCredentialStoring {
    var passwords: [String: String] = [:]
    var loadError: BiometricCredentialError?
    private(set) var loadCount = 0

    func hasSavedMasterPassword(for vaultURL: URL) -> Bool {
        passwords[vaultURL.standardizedFileURL.path] != nil
    }

    func saveMasterPassword(_ password: String, for vaultURL: URL) throws {
        passwords[vaultURL.standardizedFileURL.path] = password
    }

    func loadMasterPassword(for vaultURL: URL, prompt: String) async throws -> String {
        loadCount += 1
        if let loadError {
            throw loadError
        }
        guard let password = passwords[vaultURL.standardizedFileURL.path] else {
            throw BiometricCredentialError.credentialNotFound
        }
        return password
    }

    func deleteMasterPassword(for vaultURL: URL) {
        passwords[vaultURL.standardizedFileURL.path] = nil
    }

    var responses: [String: VaultHardwareKeyResponse] = [:]

    func saveHardwareKeyResponse(_ response: VaultHardwareKeyResponse, for vaultURL: URL) throws {
        responses[vaultURL.standardizedFileURL.path] = response
    }

    func loadHardwareKeyResponse(for vaultURL: URL) -> VaultHardwareKeyResponse? {
        responses[vaultURL.standardizedFileURL.path]
    }

    func deleteHardwareKeyResponse(for vaultURL: URL) {
        responses[vaultURL.standardizedFileURL.path] = nil
    }
}

/// One app session against a database in a temporary folder: isolated defaults, fake Touch ID,
/// no snapshots, no file watching and no notifications unless a test turns them on.
@MainActor
final class AppScenario {
    static let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)

    let directory: URL
    let url: URL
    let password: String
    let suiteName: String
    let defaults: UserDefaults
    let settings: AppSettingsStore
    let biometrics = FakeBiometricCredentialStore()
    private(set) var loader = KeePassKitVaultLoader()
    private(set) var model: AppViewModel

    init(_ testCase: XCTestCase, fileName: String = "Vault.kdbx", password: String = "pw", touchID: Bool = false, syncMode: VaultSyncMode = .off) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeeMacScenario-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(fileName)
        self.password = password
        suiteName = "KeeMacScenario.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(touchID, for: url)
        settings.setSyncMode(syncMode, for: url)
        settings.setExpiryNotificationsEnabled(false, for: url)
        settings.lookForConflictCopies = false
        model = AppViewModel(vaultLoader: loader, settingsStore: settings, userDefaults: defaults, biometricCredentialStore: biometrics)
        testCase.addTeardownBlock { @MainActor [self] in
            await cleanup()
        }
    }

    /// Creates the database through the app and leaves it open.
    func createVault(name: String = "Vault") async throws {
        try await model.createVault(options: VaultCreationOptions(fileURL: url, name: name, masterPassword: password, keyDerivation: Self.fastKDF))
    }

    /// Starts a new app session with the same defaults, like relaunching KeeMac.
    func relaunch() async {
        await model.lockForQuit()
        loader = KeePassKitVaultLoader()
        model = AppViewModel(vaultLoader: loader, settingsStore: settings, userDefaults: defaults, biometricCredentialStore: biometrics)
    }

    func lock(reason: AppViewModel.LockReason = .userInitiated) async {
        model.lockVault(reason: reason)
        await model.finishPendingLock()
    }

    var vault: LoadedVault {
        get throws {
            guard case .loaded(let vault) = model.loadState else {
                throw ScenarioError.notUnlocked("\(model.loadState)")
            }
            return vault
        }
    }

    func entry(titled title: String) throws -> VaultEntry {
        guard let entry = try vault.entries.first(where: { $0.title == title }) else {
            throw ScenarioError.missingEntry(title)
        }
        return entry
    }

    /// The file as another KeePass client would read it.
    func readFromDisk(password: String? = nil) async throws -> LoadedVault {
        try await KeePassKitVaultLoader().loadVault(from: url, masterPassword: password ?? self.password, keyFileURL: nil)
    }

    /// Another device's KeePass client editing the same file.
    func editOnAnotherDevice(_ edit: (KeePassKitVaultLoader) async throws -> Void) async throws {
        let other = KeePassKitVaultLoader()
        _ = try await other.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        // KDBX times have one-second precision; let the other device's change be newer.
        try await Task.sleep(for: .milliseconds(1100))
        try await edit(other)
    }

    func cleanup() async {
        await model.lockForQuit()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ message: @autoclosure () -> String = "condition was not met in time",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail(message(), file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
