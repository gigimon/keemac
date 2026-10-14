@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

final class EntrySelectionTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }
    /// The first four entries are in the main database, the last two in "backup".
    private var database: (UUID) -> String? {
        let backup = Set(ids.suffix(2))
        return { backup.contains($0) ? "backup" : nil }
    }

    func testClickCommandClickAndShiftClick() {
        var selection = EntrySelection(focus: ids[0])
        XCTAssertFalse(selection.isMultiple)

        selection.toggle(ids[2], in: ids, database: database)
        XCTAssertEqual(selection.ids, [ids[0], ids[2]])
        XCTAssertEqual(selection.focus, ids[2])

        selection.toggle(ids[2], in: ids, database: database)
        XCTAssertEqual(selection.ids, [ids[0]], "⌘-click again removes it")
        selection.toggle(ids[0], in: ids, database: database)
        XCTAssertEqual(selection.ids, [ids[0]], "the last entry stays selected")

        selection.select(ids[1])
        selection.extend(to: ids[3], in: ids, database: database)
        XCTAssertEqual(selection.ids, Set(ids[1...3]))
        XCTAssertEqual(selection.ordered(in: ids), Array(ids[1...3]))
        selection.extend(to: ids[0], in: ids, database: database)
        XCTAssertEqual(selection.ids, Set(ids[0...1]), "the range follows the anchor")

        selection.collapse()
        XCTAssertEqual(selection.ids, [ids[0]])
    }

    func testSelectionStaysInOneDatabase() {
        var selection = EntrySelection(focus: ids[3])
        selection.toggle(ids[4], in: ids, database: database)
        XCTAssertEqual(selection.ids, [ids[4]], "⌘-click in another database starts over there")

        selection.select(ids[2])
        selection.extend(to: ids[5], in: ids, database: database)
        XCTAssertEqual(selection.ids, [ids[5]])

        selection.select(ids[1])
        selection.selectAll(in: ids, database: database)
        XCTAssertEqual(selection.ids, Set(ids.prefix(4)), "⌘A takes the focused entry's database")
        XCTAssertEqual(selection.focus, ids[1])
    }

    func testRangeAddsAndFocusMovesToANeighbor() {
        var selection = EntrySelection(focus: ids[0])
        selection.toggle(ids[3], in: ids, database: database)
        selection.extend(to: ids[1], in: ids, database: database, adding: true)
        XCTAssertEqual(selection.ids, Set(ids[0...3]), "⌘⇧-click adds the range from the anchor to what was selected")
        XCTAssertEqual(selection.focus, ids[1])

        selection.toggle(ids[1], in: ids, database: database)
        XCTAssertEqual(selection.focus, ids[2], "the focus goes to the next selected entry")
    }

    func testRangeContinuesAfterTheAnchorIsTrimmed() {
        var selection = EntrySelection(focus: ids[0])
        selection.selectAll(in: Array(ids.prefix(4)), database: database)
        selection.extend(to: ids[2], in: ids, database: database)
        XCTAssertTrue(selection.trim(to: Array(ids[1...3])))
        selection.extend(to: ids[3], in: Array(ids[1...3]), database: database)
        XCTAssertEqual(selection.ids, [ids[2], ids[3]], "the focus becomes the anchor instead of starting over")
    }

    func testTrimKeepsVisibleEntries() {
        var selection = EntrySelection(focus: ids[0])
        selection.selectAll(in: Array(ids.prefix(4)), database: database)
        XCTAssertTrue(selection.trim(to: [ids[1], ids[2]]))
        XCTAssertEqual(selection.ids, [ids[1], ids[2]])
        XCTAssertEqual(selection.focus, ids[1], "the focus moves to a selected entry still listed")

        XCTAssertFalse(selection.trim(to: [ids[5]]))
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.focus)
    }
}

final class BulkTagEditorTests: XCTestCase {
    func testStatesCycleAndChanges() {
        var editor = BulkTagEditor(
            entryTags: [["work", "2fa"], ["Work"], ["shared"]],
            databaseTags: ["work", "2fa", "shared", "personal"]
        )
        XCTAssertEqual(editor.tags, ["2fa", "personal", "shared", "work"])
        XCTAssertEqual(editor.state(of: "work"), .some)
        XCTAssertEqual(editor.count(of: "WORK"), 2, "tags compare case-insensitively")
        XCTAssertEqual(editor.state(of: "personal"), .none)

        editor.cycle("work")
        XCTAssertEqual(editor.state(of: "work"), .all)
        editor.cycle("work")
        XCTAssertEqual(editor.state(of: "work"), .none)
        editor.cycle("work")
        XCTAssertEqual(editor.state(of: "work"), .some, "a mixed tag comes back to mixed")
        XCTAssertFalse(editor.isChanged("work"))

        editor.cycle("personal")
        XCTAssertEqual(editor.state(of: "personal"), .all)
        editor.cycle("2fa")
        editor.cycle("2fa")
        XCTAssertEqual(editor.state(of: "2fa"), .none)
        XCTAssertEqual(editor.changeCount, 2)
        XCTAssertEqual(editor.changes.adding, ["personal"])
        XCTAssertEqual(editor.changes.removing, ["2fa"])
    }

    func testAddingAndSuggestions() {
        var editor = BulkTagEditor(entryTags: [[], []], databaseTags: ["shared", "shopping"])
        XCTAssertEqual(editor.suggestions(for: "sh").tags, ["shared", "shopping"])
        XCTAssertTrue(editor.suggestions(for: "sh").canCreate)
        XCTAssertFalse(editor.suggestions(for: "SHARED").canCreate, "an existing tag isn't created again")

        editor.add("Shared")
        XCTAssertEqual(editor.tags, ["shared", "shopping"], "the existing spelling is reused")
        XCTAssertEqual(editor.state(of: "shared"), .all)
        editor.add("  urgent ")
        XCTAssertEqual(editor.tags, ["shared", "shopping", "urgent"])
        XCTAssertEqual(editor.changes.adding, ["shared", "urgent"])
    }

    func testNamesOfTheSelection() {
        XCTAssertEqual(EntrySelectionPanel.names(["GitHub", "Jira"]), "GitHub and Jira")
        XCTAssertEqual(EntrySelectionPanel.names(["GitHub", "Jira", "Mail"]), "GitHub, Jira and Mail")
        XCTAssertEqual(EntrySelectionPanel.names(["A", "B", "C", "D", "E"]), "A, B, C and 2 more")
    }
}

final class BulkLoaderTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "bulk"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Bulk.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL, name: "Bulk", masterPassword: password, keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A loader with Mail, Bank and Shop in the root and an empty Work group.
    private func open() async throws -> (loader: KeePassKitVaultLoader, ids: [UUID], workPath: String) {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", tags: ["work", "2fa"]))
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank", tags: ["Work"]))
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Shop"))
        let vault = try await loader.createGroup(inParentPath: nil, title: "Work", iconID: nil)
        let ids = ["Mail", "Bank", "Shop"].compactMap { title in vault.entries.first { $0.title == title }?.id }
        let workPath = try XCTUnwrap(vault.groups.first { $0.title == "Work" }?.path)
        return (loader, ids, workPath)
    }

    private func reopen() async throws -> LoadedVault {
        try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
    }

    func testMoveIsOneUndoStepAndSaved() async throws {
        let (loader, ids, workPath) = try await open()
        let vault = try await loader.moveEntries(ids: Array(ids.prefix(2)) + [UUID()], toGroupPath: workPath)
        XCTAssertEqual(Set(vault.entries.filter { $0.groupPath == workPath }.map(\.title)), ["Mail", "Bank"], "a missing ID is skipped")
        let reopened = try await reopen()
        XCTAssertEqual(reopened.entries.filter { $0.groupPath == workPath }.count, 2)
        let undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .moveEntries)

        let undone = try await loader.undo()
        XCTAssertFalse(undone.entries.contains { $0.groupPath == workPath }, "one undo takes back both")
    }

    func testDeleteGoesToTrashThenRestore() async throws {
        let (loader, ids, _) = try await open()
        var vault = try await loader.deleteEntries(ids: Array(ids.prefix(2)))
        XCTAssertEqual(vault.entries.filter(\.isTrashed).count, 2)
        var undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .moveEntriesToTrash)

        vault = try await loader.restoreEntries(ids: Array(ids.prefix(2)))
        XCTAssertFalse(vault.entries.contains(where: \.isTrashed))
        undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .restoreEntries)

        _ = try await loader.deleteEntries(ids: Array(ids.prefix(2)))
        vault = try await loader.deleteEntries(ids: Array(ids.prefix(2)))
        XCTAssertEqual(vault.entries.map(\.title), ["Shop"], "deleting from the Trash removes them for good")
        undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .deleteEntriesPermanently)
        vault = try await loader.undo()
        XCTAssertEqual(vault.entries.filter(\.isTrashed).count, 2)
    }

    func testDeleteWithTheBinOffIsPermanent() async throws {
        let (loader, ids, _) = try await open()
        _ = try await loader.updateRecycleBin(enabled: false, group: .current, disposal: .empty)
        let vault = try await loader.deleteEntries(ids: ids)
        XCTAssertTrue(vault.entries.isEmpty)
        let undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .deleteEntriesPermanently)
        let reopened = try await reopen()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testTagsAddAndRemoveWithHistory() async throws {
        let (loader, ids, _) = try await open()
        let vault = try await loader.updateTags(ids: ids, adding: ["shared"], removing: ["WORK"])
        let mail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" })
        XCTAssertEqual(mail.tags, ["2fa", "shared"])
        XCTAssertEqual(vault.entries.first { $0.title == "Bank" }?.tags, ["shared"], "removal ignores case")
        XCTAssertEqual(vault.entries.first { $0.title == "Shop" }?.tags, ["shared"])
        XCTAssertEqual(mail.history.count, 1, "the previous version goes to history")
        let modified = try XCTUnwrap(mail.modifiedAt)
        XCTAssertGreaterThan(modified, try XCTUnwrap(mail.history.first?.modifiedAt), "merges must see the tags as newer")
        let undoState = await loader.undoState()
        XCTAssertEqual(undoState.undoAction, .editTags)
        let reopened = try await reopen()
        XCTAssertEqual(reopened.entries.first { $0.title == "Mail" }?.tags, ["2fa", "shared"])

        let unchanged = try await loader.updateTags(ids: ids, adding: ["shared"], removing: [])
        XCTAssertEqual(unchanged.entries.first { $0.title == "Mail" }?.history.count, 1, "no change, no history")
    }
}

@MainActor
final class BulkViewModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "KeeMacBulkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The main database with Mail and Bank, plus a backup copy attached as an additional database.
    private func makeModel() async throws -> (model: AppViewModel, backupURL: URL, key: String) {
        let mainURL = directory.appendingPathComponent("Main.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(fileURL: mainURL, name: "Main", masterPassword: "main", keyDerivation: kdf))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail"))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank"))
        let backupURL = directory.appendingPathComponent("Backup.kdbx")
        try FileManager.default.copyItem(at: mainURL, to: backupURL)

        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: mainURL)
        let model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: mainURL)
        await model.unlock(masterPassword: "main")
        try await model.addAdditionalDatabase(url: backupURL, password: "main", keyFileURL: nil)
        return (model, backupURL, try XCTUnwrap(model.additionalDatabases.first?.id))
    }

    func testBulkActionsGoToTheOwningDatabase() async throws {
        let (model, backupURL, key) = try await makeModel()
        let backupIDs = try XCTUnwrap(model.browserVault?.entries.filter { DatabaseScope.key(of: $0.groupPath) == key }.map(\.id))
        XCTAssertEqual(backupIDs.count, 2)

        try await model.updateTags(ids: backupIDs, adding: ["old"], removing: [])
        let backup = try await KeePassKitVaultLoader().loadVault(from: backupURL, masterPassword: "main", keyFileURL: nil)
        XCTAssertEqual(backup.entries.map(\.tags), [["old"], ["old"]], "saved to the backup file")
        guard case .loaded(let main) = model.loadState else {
            return XCTFail("main database is open")
        }
        XCTAssertTrue(main.entries.allSatisfy(\.tags.isEmpty), "the main database is untouched")

        try await model.deleteEntries(ids: backupIDs)
        XCTAssertEqual(model.browserVault?.entries.filter { DatabaseScope.key(of: $0.groupPath) == key && $0.isTrashed }.count, 2)
    }

    func testSelectionAcrossDatabasesIsRefused() async throws {
        let (model, _, key) = try await makeModel()
        let entries = try XCTUnwrap(model.browserVault?.entries)
        let mixed = [
            try XCTUnwrap(entries.first { DatabaseScope.key(of: $0.groupPath) == nil }?.id),
            try XCTUnwrap(entries.first { DatabaseScope.key(of: $0.groupPath) == key }?.id)
        ]
        do {
            try await model.deleteEntries(ids: mixed)
            XCTFail("a selection spans one database")
        } catch {}
        XCTAssertFalse(model.browserVault?.entries.contains(where: \.isTrashed) ?? true)
    }

    func testMovingToAnotherDatabasesGroupIsRefused() async throws {
        let (model, _, key) = try await makeModel()
        let mainIDs = try XCTUnwrap(model.browserVault?.entries.filter { DatabaseScope.key(of: $0.groupPath) == nil }.map(\.id))
        let backupRoot = try XCTUnwrap(model.additionalRootPath(key))
        do {
            try await model.moveEntries(ids: mainIDs, toGroupPath: backupRoot)
            XCTFail("moving between databases goes through the transfer sheet")
        } catch {}
    }

    func testFavoritesOnlyForTheMainDatabase() async throws {
        let (model, _, _) = try await makeModel()
        let ids = try XCTUnwrap(model.browserVault?.entries.map(\.id))
        model.setFavorite(true, entryIDs: ids)
        XCTAssertEqual(model.favoriteEntryIDs.count, 2, "only the main database's two entries")
        model.setFavorite(false, entryIDs: ids)
        XCTAssertTrue(model.favoriteEntryIDs.isEmpty)
    }
}
