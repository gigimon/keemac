@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AdditionalDatabasesTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "KeeMacAdditionalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The main database with two entries, a backup copy of it (same UUIDs) and an open view model.
    private func makeModel() async throws -> (model: AppViewModel, mainURL: URL, backupURL: URL) {
        let mainURL = directory.appendingPathComponent("Main.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(fileURL: mainURL, name: "Main", masterPassword: "main", keyDerivation: kdf))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna", password: "v1"))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank", username: "anna", password: "b1"))
        let backupURL = directory.appendingPathComponent("Backup.kdbx")
        try FileManager.default.copyItem(at: mainURL, to: backupURL)

        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: mainURL)
        let model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: mainURL)
        await model.unlock(masterPassword: "main")
        XCTAssertTrue(model.loadState.isUnlocked)
        return (model, mainURL, backupURL)
    }

    func testBackupCopyShowsSideBySideWithoutClashingIDs() async throws {
        let (model, mainURL, backupURL) = try await makeModel()
        try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil)
        let key = try XCTUnwrap(model.additionalDatabases.first?.id)
        XCTAssertEqual(model.additionalDatabases.first?.state, .unlocked)

        let vault = try XCTUnwrap(model.browserVault)
        XCTAssertEqual(vault.entries.filter { $0.title == "Mail" }.count, 2)
        XCTAssertEqual(Set(vault.entries.map(\.id)).count, vault.entries.count, "no two entries share an ID in the browser")
        XCTAssertEqual(Set(vault.groups.map(\.path)).count, vault.groups.count, "no two groups share a path")
        let backupMail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" && DatabaseScope.key(of: $0.groupPath) == key })
        XCTAssertEqual(model.databaseKey(ofEntry: backupMail.id), key)

        await XCTAssertThrowsErrorAsync(try await model.addAdditionalDatabase(url: mainURL, password: "main", keyFileURL: nil))
        await XCTAssertThrowsErrorAsync(try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil))
    }

    func testEditsGoToTheDatabaseThatOwnsTheEntry() async throws {
        let (model, _, backupURL) = try await makeModel()
        try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil)
        let key = try XCTUnwrap(model.additionalDatabases.first?.id)
        let backupMail = try XCTUnwrap(model.browserVault?.entries.first { $0.title == "Mail" && DatabaseScope.key(of: $0.groupPath) == key })

        try await model.updateEntry(id: backupMail.id, form: VaultEntryForm(title: "Mail", username: "anna", password: "edited"))
        let vault = try XCTUnwrap(model.browserVault)
        XCTAssertEqual(vault.entries.first { $0.id == backupMail.id }?.password, "edited")
        guard case .loaded(let main) = model.loadState else {
            return XCTFail("main database is open")
        }
        XCTAssertEqual(main.entries.first { $0.title == "Mail" }?.password, "v1", "the main database is untouched")

        let reopened = try await KeePassKitVaultLoader().loadVault(from: backupURL, masterPassword: "main", keyFileURL: nil)
        XCTAssertEqual(reopened.entries.first { $0.title == "Mail" }?.password, "edited", "saved to the backup file")

        let rootPath = try XCTUnwrap(model.additionalRootPath(key))
        try await model.createGroup(inParentPath: rootPath, title: "Restored", iconID: nil)
        XCTAssertTrue(model.browserVault?.groups.contains { $0.title == "Restored" && DatabaseScope.key(of: $0.path) == key } ?? false)
    }

    func testMoveFromBackupReplacesAndUndoesInBothDatabases() async throws {
        let (model, _, backupURL) = try await makeModel()
        try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil)
        let key = try XCTUnwrap(model.additionalDatabases.first?.id)
        let backupMail = try XCTUnwrap(model.browserVault?.entries.first { $0.title == "Mail" && DatabaseScope.key(of: $0.groupPath) == key })
        try await model.updateEntry(id: backupMail.id, form: VaultEntryForm(title: "Mail", username: "anna", password: "from-backup"))

        let transfer = try await model.prepareTransfer(entryIDs: [backupMail.id], groupPath: nil, toGroupPath: nil, isCopy: false)
        XCTAssertNil(transfer.targetKey)
        XCTAssertEqual(transfer.sourceKey, key)
        let conflict = try XCTUnwrap(transfer.conflicts.first)
        XCTAssertTrue(conflict.isSameEntry)

        let count = try await model.commitTransfer(transfer, decisions: [conflict.id: .replace])
        XCTAssertEqual(count, 1)
        guard case .loaded(let main) = model.loadState else {
            return XCTFail("main database is open")
        }
        XCTAssertEqual(main.entries.first { $0.title == "Mail" }?.password, "from-backup")
        XCTAssertTrue(model.browserVault?.entries.first { $0.id == backupMail.id }?.isTrashed ?? false, "the original went to the backup's trash")

        XCTAssertTrue(model.canUndoLastTransfer)
        await model.undoLastTransfer()
        guard case .loaded(let undone) = model.loadState else {
            return XCTFail("main database is open")
        }
        XCTAssertEqual(undone.entries.first { $0.title == "Mail" }?.password, "v1")
        XCTAssertFalse(model.browserVault?.entries.first { $0.id == backupMail.id }?.isTrashed ?? true)
    }

    func testLockingTheMainDatabaseLocksAdditionalOnesAndKeepsTheList() async throws {
        let (model, mainURL, backupURL) = try await makeModel()
        try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil)
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()
        XCTAssertEqual(model.additionalDatabases.map(\.state), [.locked])
        XCTAssertNil(model.browserVault)

        model.selectVault(url: mainURL)
        await model.unlock(masterPassword: "main")
        XCTAssertEqual(model.additionalDatabases.count, 1, "the list is remembered for the main database")
        XCTAssertEqual(model.browserVault?.entries.count, 2, "additional databases stay locked until asked")

        let key = try XCTUnwrap(model.additionalDatabases.first?.id)
        await XCTAssertThrowsErrorAsync(try await model.unlockAdditionalDatabase(key, password: "wrong", keyFileURL: nil))
        try await model.unlockAdditionalDatabase(key, password: "main", keyFileURL: nil)
        XCTAssertEqual(model.browserVault?.entries.count, 4)

        model.removeAdditionalDatabase(key)
        XCTAssertTrue(model.additionalDatabases.isEmpty)
        XCTAssertEqual(model.browserVault?.entries.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "the file stays where it is")
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
