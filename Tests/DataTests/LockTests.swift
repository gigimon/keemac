@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class LockTests: XCTestCase {
    func testQuittingSavesUsageCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Lock.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(fileURL: url, name: "Lock", masterPassword: "pw", keyDerivation: kdf))
        let created = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail"))
        let id = try XCTUnwrap(created.entries.first?.id)

        let suiteName = "KeeMacLockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        let loader = KeePassKitVaultLoader()
        let model = AppViewModel(vaultLoader: loader, settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: url)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)

        _ = try await loader.recordEntryUsage(id: id)
        await model.lockForQuit()
        XCTAssertFalse(model.loadState.isUnlocked)

        let reopened = try await KeePassKitVaultLoader().loadVault(from: url, masterPassword: "pw", keyFileURL: nil)
        XCTAssertEqual(reopened.entries.first { $0.id == id }?.usageCount, 1, "the usage count reached the file before quitting")
    }
}
