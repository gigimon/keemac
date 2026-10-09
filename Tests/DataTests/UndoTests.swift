@testable import Data
import Domain
import Foundation
import XCTest

final class UndoTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "undo-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Undo.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL, name: "Undo", masterPassword: password, keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    func testUndoAndRedoNewEntry() async throws {
        let (loader, _) = try await open()
        let initialState = await loader.undoState()
        XCTAssertEqual(initialState, .empty)

        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna"))
        let afterCreate = await loader.undoState()
        XCTAssertEqual(afterCreate.undoAction, .newEntry)

        var vault = try await loader.undo()
        XCTAssertFalse(vault.entries.contains { $0.title == "Mail" })
        let afterUndo = await loader.undoState()
        XCTAssertEqual(afterUndo, VaultUndoState(undoAction: nil, redoAction: .newEntry))
        let reopened = try await open().1
        XCTAssertFalse(reopened.entries.contains { $0.title == "Mail" }, "the undo is saved")

        vault = try await loader.redo()
        XCTAssertEqual(vault.entries.first { $0.title == "Mail" }?.username, "anna")
    }

    func testUndoEditMoveAndDelete() async throws {
        let (loader, _) = try await open()
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", password: "one"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Mail" }?.id)
        vault = try await loader.createGroup(inParentPath: nil, title: "Work", iconID: nil)
        let workPath = try XCTUnwrap(vault.groups.first { $0.title == "Work" }?.path)
        let rootPath = try XCTUnwrap(vault.entries.first { $0.id == id }?.groupPath)

        _ = try await loader.updateEntry(id: id, form: VaultEntryForm(title: "Mail", password: "two"))
        vault = try await loader.undo()
        XCTAssertEqual(vault.entries.first { $0.id == id }?.password, "one")

        _ = try await loader.moveEntry(id: id, toGroupPath: workPath)
        vault = try await loader.undo()
        XCTAssertEqual(vault.entries.first { $0.id == id }?.groupPath, rootPath)

        _ = try await loader.deleteEntry(id: id)
        let trashState = await loader.undoState()
        XCTAssertEqual(trashState.undoAction, .moveToTrash)
        vault = try await loader.undo()
        XCTAssertEqual(vault.entries.first { $0.id == id }?.isTrashed, false)

        _ = try await loader.deleteEntry(id: id)
        _ = try await loader.deleteEntry(id: id)
        let deleteState = await loader.undoState()
        XCTAssertEqual(deleteState.undoAction, .deletePermanently)
        vault = try await loader.undo()
        XCTAssertEqual(vault.entries.first { $0.id == id }?.isTrashed, true, "back in the trash")

        vault = try await loader.undo()
        vault = try await loader.undo()
        XCTAssertNil(vault.groups.first { $0.title == "Work" }, "undoing further removes the new group")
    }

    func testUsageAndBrowserSettingsAreNotUndoSteps() async throws {
        let (loader, _) = try await open()
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Mail" }?.id)
        _ = try await loader.recordEntryUsage(id: id)
        _ = try await loader.storeBrowserAssociation(id: "chrome", key: "a2V5", created: "now")
        _ = try await loader.rememberBrowserAccess(allowed: [id], denied: [], hosts: ["example.com"])
        let state = await loader.undoState()
        XCTAssertEqual(state.undoAction, .newEntry)
    }

    func testMergeWithOtherDeviceClearsUndo() async throws {
        let (mac, _) = try await open()
        let (phone, _) = try await open()
        _ = try await mac.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Mac"))
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Phone"))

        let result = try await mac.mergeExternalChanges()
        XCTAssertTrue(result.vault.entries.contains { $0.title == "From Phone" })
        let state = await mac.undoState()
        XCTAssertEqual(state, .empty)
    }

    func testLockClearsUndo() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail"))
        await loader.clearLoadedSession()
        let state = await loader.undoState()
        XCTAssertEqual(state, .empty)
    }
}
