@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AppEditingScenarioTests: XCTestCase {
    func testEntryLifecycleReachesDisk() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        let root = try XCTUnwrap(app.vault.groups.first?.path)
        try await app.model.createGroup(inParentPath: root, title: "Work", iconID: nil)
        let work = "\(root).Work"

        try await app.model.createEntry(inGroupPath: work, form: VaultEntryForm(title: "Git", username: "dev", password: "one", tags: ["code"]))
        let created = try app.entry(titled: "Git")
        XCTAssertEqual(created.groupPath, work)
        XCTAssertEqual(created.tags, ["code"])

        var form = VaultEntryForm(title: "GitHub", username: "dev", password: "two", url: "https://github.com", tags: ["code"])
        form.notes = "2FA on"
        try await app.model.updateEntry(id: created.id, form: form)
        let updated = try app.entry(titled: "GitHub")
        XCTAssertEqual(updated.password, "two")
        XCTAssertEqual(updated.history.count, 1, "the previous version goes to history")

        let copyID = try await app.model.duplicateEntry(id: created.id)
        XCTAssertNotEqual(copyID, created.id)
        XCTAssertEqual(try app.vault.entries.filter { !$0.isTrashed }.count, 2)

        try await app.model.moveEntry(id: copyID, toGroupPath: root)
        XCTAssertEqual(try app.vault.entries.first { $0.id == copyID }?.groupPath, root)

        try await app.model.deleteEntry(id: copyID)
        XCTAssertEqual(try app.vault.entries.first { $0.id == copyID }?.isTrashed, true, "deleting moves to the trash first")
        try await app.model.restoreEntry(id: copyID)
        XCTAssertEqual(try app.vault.entries.first { $0.id == copyID }?.isTrashed, false)
        XCTAssertEqual(try app.vault.entries.first { $0.id == copyID }?.groupPath, root, "restored to the group it came from")

        try await app.model.deleteEntry(id: copyID)
        try await app.model.emptyTrash(ids: [copyID])
        XCTAssertNil(try app.vault.entries.first { $0.id == copyID })

        let disk = try await app.readFromDisk()
        XCTAssertEqual(disk.entries.filter { !$0.isTrashed }.map(\.title), ["GitHub"])
        XCTAssertEqual(disk.entries.first?.notes, "2FA on")
        XCTAssertEqual(disk.entries.first?.url?.absoluteString, "https://github.com")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path + ".bak"), "every save keeps a backup next to the database")
    }

    func testRevertEntryToHistoryRevision() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Router", password: "first"))
        let id = try app.entry(titled: "Router").id
        try await app.model.updateEntry(id: id, form: VaultEntryForm(title: "Router", password: "second"))
        try await app.model.updateEntry(id: id, form: VaultEntryForm(title: "Router", password: "third"))
        let history = try app.entry(titled: "Router").history
        XCTAssertEqual(history.map(\.password), ["second", "first"], "newest revision first")

        try await app.model.revertEntry(id: id, toHistoryRevisionAt: 1)
        let reverted = try app.entry(titled: "Router")
        XCTAssertEqual(reverted.password, "first")
        XCTExpectFailure("Bug: restoring a revision drops the current version instead of keeping it in history") {
            XCTAssertEqual(reverted.history.first?.password, "third", "the replaced version stays in history")
        }
    }

    func testGroupLifecycle() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        let root = try XCTUnwrap(app.vault.groups.first?.path)

        try await app.model.createGroup(inParentPath: root, title: "Home", iconID: 12)
        try await app.model.createGroup(inParentPath: root, title: "Servers", iconID: nil)
        try await app.model.createEntry(inGroupPath: "\(root).Servers", form: VaultEntryForm(title: "NAS"))

        try await app.model.updateGroup(path: "\(root).Home", title: "Family", iconID: 13)
        let family = try XCTUnwrap(app.vault.groups.first { $0.path == "\(root).Family" })
        XCTAssertEqual(family.iconID, 13)

        try await app.model.moveGroup(path: "\(root).Servers", toParentPath: "\(root).Family")
        XCTAssertEqual(try app.entry(titled: "NAS").groupPath, "\(root).Family.Servers", "entries move with their group")

        try await app.model.deleteGroup(path: "\(root).Family")
        XCTAssertTrue(try app.entry(titled: "NAS").isTrashed)
        XCTAssertFalse(try app.vault.groups.contains { $0.path.hasPrefix("\(root).Family") && !$0.isTrash })

        let disk = try await app.readFromDisk()
        XCTAssertEqual(disk.entries.first?.isTrashed, true)
    }

    func testUndoAndRedo() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        XCTAssertEqual(app.model.undoState, .empty)

        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Wiki"))
        await app.model.refreshUndoState()
        XCTAssertEqual(app.model.undoState.undoAction, .newEntry)

        let id = try app.entry(titled: "Wiki").id
        try await app.model.updateEntry(id: id, form: VaultEntryForm(title: "Wiki", password: "pw2"))
        await app.model.refreshUndoState()
        XCTAssertEqual(app.model.undoState.undoAction, .editEntry)

        await app.model.undo()
        XCTAssertEqual(try app.entry(titled: "Wiki").password ?? "", "")
        await app.model.refreshUndoState()
        XCTAssertEqual(app.model.undoState.redoAction, .editEntry)

        await app.model.undo()
        XCTAssertTrue(try app.vault.entries.isEmpty)
        let afterUndo = try await app.readFromDisk()
        XCTAssertTrue(afterUndo.entries.isEmpty, "undo is saved like any other change")

        await app.model.redo()
        await app.model.redo()
        XCTAssertEqual(try app.entry(titled: "Wiki").password, "pw2")

        await app.lock()
        XCTAssertEqual(app.model.undoState, .empty, "undo history ends with the session")
    }

    func testFavoritesAndRecentlyViewed() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        for title in ["A", "B", "C"] {
            try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: title))
        }
        let a = try app.entry(titled: "A").id
        let b = try app.entry(titled: "B").id
        let c = try app.entry(titled: "C").id

        app.model.toggleFavorite(entryID: a)
        app.model.toggleFavorite(entryID: b)
        app.model.toggleFavorite(entryID: b)
        XCTAssertEqual(app.model.favoriteEntryIDs, [a])

        app.model.markEntryViewed(a)
        app.model.markEntryViewed(c)
        app.model.markEntryViewed(a)
        XCTAssertEqual(app.model.recentViewedEntryIDs, [a, c])

        try await app.model.deleteEntry(id: c)
        try await app.model.emptyTrash(ids: [c])
        XCTAssertEqual(app.model.recentViewedEntryIDs, [a], "deleted entries leave the recent list")

        await app.lock()
        XCTAssertTrue(app.model.recentViewedEntryIDs.isEmpty, "recently viewed is cleared on lock")

        await app.relaunch()
        await app.model.unlock(masterPassword: app.password)
        XCTAssertEqual(app.model.favoriteEntryIDs, [a], "favorites survive relaunch")

        try await app.model.deleteEntry(id: a)
        try await app.model.emptyTrash(ids: [a])
        XCTAssertTrue(app.model.favoriteEntryIDs.isEmpty)
    }

    func testRecentlyViewedKeepsFifty() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        let ids = (0..<60).map { _ in UUID() }
        ids.forEach(app.model.markEntryViewed)
        XCTAssertEqual(app.model.recentViewedEntryIDs.count, 50)
        XCTAssertEqual(app.model.recentViewedEntryIDs.first, ids.last)
    }

    func testUsageIsSavedOnLock() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Shop"))
        let id = try app.entry(titled: "Shop").id

        app.model.recordEntryUsage(id: id)
        await waitUntil { (try? app.entry(titled: "Shop").usageCount) == 1 }
        let beforeLock = try await app.readFromDisk()
        XCTAssertEqual(beforeLock.entries.first?.usageCount, 0, "usage is not saved right away")

        await app.lock()
        let afterLock = try await app.readFromDisk()
        XCTAssertEqual(afterLock.entries.first?.usageCount, 1)
    }

    func testImportExportAndUndoImport() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        let csv = """
        name,url,username,password,note
        Forum,https://forum.example.com,neo,matrix,
        Mail,https://mail.example.com,neo@example.com,red-pill,old account
        """
        let file = try VaultImporter.read(Data(csv.utf8), format: .chrome)
        let result = try await app.model.importEntries(file, options: VaultImportOptions(destination: .newGroup(title: "Chrome"), keepsFolders: false, skipsDuplicates: true))
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(try app.entry(titled: "Mail").password, "red-pill")
        XCTAssertTrue(try app.entry(titled: "Forum").groupPath.hasSuffix(".Chrome"))
        XCTAssertEqual(app.model.revealRequest?.groupPath, result.groupPath)

        let again = try await app.model.importEntries(file, options: VaultImportOptions(destination: .group(path: result.groupPath), keepsFolders: false, skipsDuplicates: true))
        XCTAssertEqual(again.importedCount, 0, "duplicates are skipped")

        let (data, count) = try await app.model.exportDatabase(VaultExportOptions(format: .csv, groupPath: nil, includesTrash: false, includesHistory: false, includesAttachments: false))
        XCTAssertEqual(count, 2)
        let exported = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(exported.contains("red-pill"))
        XCTAssertTrue(exported.contains("forum.example.com"))

        await app.model.refreshUndoState()
        XCTAssertEqual(app.model.undoState.undoAction, .importEntries)
        await app.model.undo()
        let imported = { try app.vault.entries.contains { !$0.isTrashed && ["Forum", "Mail"].contains($0.title) } }
        let importedAfterOneUndo = try imported()
        XCTExpectFailure("Bug: an import that skipped every entry still adds an empty undo step") {
            XCTAssertFalse(importedAfterOneUndo, "one undo takes the import back")
        }
        await app.model.undo()
        XCTAssertFalse(try imported())
    }

    func testImportAndExportSheetsNeedUnlockedDatabase() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        await app.lock()
        app.model.showImport()
        app.model.showExport()
        XCTAssertFalse(app.model.showsImportSheet)
        XCTAssertFalse(app.model.showsExportSheet)

        await app.model.unlock(masterPassword: app.password)
        app.model.showImport()
        app.model.showExport()
        XCTAssertTrue(app.model.showsImportSheet)
        XCTAssertTrue(app.model.showsExportSheet)
    }

    func testSidebarStateIsPerDatabase() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        let root = try XCTUnwrap(app.vault.groups.first?.path)
        app.model.setBrowserSidebarSelectionID("group.\(root).Work", for: app.url)
        app.model.setBrowserExpandedGroupPaths([root, "\(root).Work"], for: app.url)

        await app.relaunch()
        XCTAssertEqual(app.model.selectedBrowserGroupPath, "\(root).Work")
        XCTAssertEqual(app.model.browserExpandedGroupPaths(for: app.url), [root, "\(root).Work"])
        XCTAssertNil(app.model.browserSidebarSelectionID(for: app.directory.appendingPathComponent("Other.kdbx")))
    }
}
