@testable import Data
import Domain
import Foundation
import XCTest

final class TransferBetweenDatabasesTests: XCTestCase {
    private let password = "pw"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVault(_ name: String) async throws -> (KeePassKitVaultLoader, URL) {
        let url = directory.appendingPathComponent("\(name).kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(fileURL: url, name: name, masterPassword: password, keyDerivation: fastKDF))
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        return (loader, url)
    }

    private func open(_ url: URL) async throws -> KeePassKitVaultLoader {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        return loader
    }

    func testMoveEntriesKeepsUUIDHistoryAndTrashesOriginals() async throws {
        let (source, _) = try await makeVault("Source")
        var vault = try await source.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Server", username: "root", password: "old",
            attachments: [VaultAttachment(name: "key.pub", data: Data("ssh".utf8), isProtected: false)]
        ))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Server" }?.id)
        vault = try await source.updateEntry(id: id, form: VaultEntryForm(
            title: "Server", username: "root", password: "new",
            attachments: [VaultAttachment(name: "key.pub", data: Data("ssh".utf8), isProtected: false)]
        ))
        let (target, _) = try await makeVault("Target")

        let payload = try await source.makeTransferPayload(entryIDs: [id], groupPath: nil)
        XCTAssertEqual(payload.entryIDs, [id])
        let conflicts = try await target.transferConflicts(for: payload)
        XCTAssertTrue(conflicts.isEmpty)
        let (received, result) = try await target.receiveTransfer(payload, toGroupPath: nil, decisions: [:])
        XCTAssertEqual(result.receivedEntryIDs, [id])
        let moved = try XCTUnwrap(received.entries.first { $0.title == "Server" })
        XCTAssertEqual(moved.id, id, "a move keeps the entry's UUID")
        XCTAssertEqual(moved.password, "new")
        XCTAssertEqual(moved.history.count, 1)
        XCTAssertEqual(moved.attachments.first?.data, Data("ssh".utf8))

        let afterMove = try await source.trashTransferredEntries([id], groupPath: nil)
        XCTAssertTrue(afterMove.entries.first { $0.id == id }?.isTrashed ?? false)

        let targetUndo = await target.undoState()
        XCTAssertEqual(targetUndo.undoAction, .receiveEntries)
        let sourceUndo = await source.undoState()
        XCTAssertEqual(sourceUndo.undoAction, .sendEntries)
        let restored = try await source.undo()
        XCTAssertFalse(restored.entries.first { $0.id == id }?.isTrashed ?? true)
        let emptied = try await target.undo()
        XCTAssertFalse(emptied.entries.contains { $0.title == "Server" })
    }

    func testReferencesBecomePlainValues() async throws {
        let (source, _) = try await makeVault("Source")
        var vault = try await source.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Main", username: "anna", password: "secret"))
        let mainID = try XCTUnwrap(vault.entries.first { $0.title == "Main" }?.id)
        let compact = mainID.uuidString.replacingOccurrences(of: "-", with: "")
        vault = try await source.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Alias", username: "{REF:U@I:\(compact)}", password: "{REF:P@I:\(compact)}"))
        let aliasID = try XCTUnwrap(vault.entries.first { $0.title == "Alias" }?.id)
        let (target, _) = try await makeVault("Target")

        let payload = try await source.makeTransferPayload(entryIDs: [aliasID], groupPath: nil)
        XCTAssertEqual(payload.linkedFieldCount, 2)
        let (received, _) = try await target.receiveTransfer(payload, toGroupPath: nil, decisions: [:])
        let alias = try XCTUnwrap(received.entries.first { $0.title == "Alias" })
        XCTAssertEqual(alias.username, "anna")
        XCTAssertEqual(alias.password, "secret")
        XCTAssertNil(alias.references, "no links point into the other database")
    }

    /// A backup copy of the same database: every UUID matches.
    func testBackupCopyConflictsReplaceKeepBothAndSkip() async throws {
        let (main, mainURL) = try await makeVault("Main")
        var vault = try await main.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna", password: "v1"))
        vault = try await main.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank", username: "anna", password: "b1"))
        vault = try await main.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Shop", username: "anna", password: "s1"))
        let mailID = try XCTUnwrap(vault.entries.first { $0.title == "Mail" }?.id)
        let bankID = try XCTUnwrap(vault.entries.first { $0.title == "Bank" }?.id)
        let shopID = try XCTUnwrap(vault.entries.first { $0.title == "Shop" }?.id)

        let backupURL = directory.appendingPathComponent("Backup.kdbx")
        try FileManager.default.copyItem(at: mainURL, to: backupURL)
        let backup = try await open(backupURL)
        _ = try await backup.updateEntry(id: mailID, form: VaultEntryForm(title: "Mail", username: "anna", password: "v-backup"))

        let payload = try await backup.makeTransferPayload(entryIDs: [mailID, bankID, shopID], groupPath: nil)
        let conflicts = try await main.transferConflicts(for: payload)
        XCTAssertEqual(Set(conflicts.map(\.id)), [mailID, bankID, shopID])
        XCTAssertTrue(conflicts.allSatisfy(\.isSameEntry))

        let (received, result) = try await main.receiveTransfer(payload, toGroupPath: nil, decisions: [
            mailID: .replace, bankID: .keepBoth, shopID: .skip
        ])
        XCTAssertEqual(Set(result.receivedEntryIDs), [mailID, bankID])
        let mail = try XCTUnwrap(received.entries.first { $0.id == mailID })
        XCTAssertEqual(mail.password, "v-backup")
        XCTAssertEqual(mail.history.first?.password, "v1", "the replaced version stays in history")
        let banks = received.entries.filter { $0.title == "Bank" && !$0.isTrashed }
        XCTAssertEqual(banks.count, 2)
        XCTAssertEqual(Set(banks.map(\.id)).count, 2, "the kept copy gets its own UUID")
        XCTAssertEqual(received.entries.filter { $0.title == "Shop" }.count, 1)
    }

    func testSameTitleAndUsernameReplaceTrashesTheOtherEntry() async throws {
        let (source, _) = try await makeVault("Source")
        let sourceVault = try await source.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "GitHub", username: "anna", password: "new"))
        let incomingID = try XCTUnwrap(sourceVault.entries.first?.id)
        let (target, _) = try await makeVault("Target")
        let targetVault = try await target.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "github", username: "Anna", password: "old"))
        let existingID = try XCTUnwrap(targetVault.entries.first?.id)

        let payload = try await source.makeTransferPayload(entryIDs: [incomingID], groupPath: nil)
        let conflicts = try await target.transferConflicts(for: payload)
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertFalse(conflict.isSameEntry)
        XCTAssertEqual(conflict.existingID, existingID)

        let (received, _) = try await target.receiveTransfer(payload, toGroupPath: nil, decisions: [incomingID: .replace])
        XCTAssertTrue(received.entries.first { $0.id == existingID }?.isTrashed ?? false)
        XCTAssertEqual(received.entries.first { $0.id == incomingID }?.password, "new")
    }

    func testMoveGroupWithSubgroups() async throws {
        let (source, _) = try await makeVault("Source")
        var vault = try await source.createGroup(inParentPath: nil, title: "Work", iconID: nil)
        let workPath = try XCTUnwrap(vault.groups.first { $0.title == "Work" }?.path)
        vault = try await source.createGroup(inParentPath: workPath, title: "Servers", iconID: nil)
        let serversPath = try XCTUnwrap(vault.groups.first { $0.title == "Servers" }?.path)
        _ = try await source.createEntry(inGroupPath: workPath, form: VaultEntryForm(title: "VPN"))
        _ = try await source.createEntry(inGroupPath: serversPath, form: VaultEntryForm(title: "Prod"))
        let (target, _) = try await makeVault("Target")

        let payload = try await source.makeTransferPayload(entryIDs: [], groupPath: workPath)
        XCTAssertEqual(payload.groupTitle, "Work")
        XCTAssertEqual(payload.entryIDs.count, 2)
        let (received, result) = try await target.receiveTransfer(payload, toGroupPath: nil, decisions: [:])
        let newWork = try XCTUnwrap(result.groupPath)
        XCTAssertTrue(received.entries.contains { $0.title == "Prod" && $0.groupPath == newWork + ".Servers" })
        XCTAssertTrue(received.entries.contains { $0.title == "VPN" && $0.groupPath == newWork })

        let afterMove = try await source.trashTransferredEntries([], groupPath: workPath)
        XCTAssertTrue(afterMove.entries.filter { ["VPN", "Prod"].contains($0.title) }.allSatisfy(\.isTrashed))
    }
}
