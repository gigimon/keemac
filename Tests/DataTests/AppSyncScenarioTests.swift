@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AppSyncScenarioTests: XCTestCase {
    func testAutomaticModeMergesChangesFromAnotherDevice() async throws {
        let app = try AppScenario(self, syncMode: .automatic)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Local"))
        guard case .synced = app.model.syncStatus else {
            return XCTFail("automatic mode watches the file, got \(app.model.syncStatus)")
        }

        try await app.editOnAnotherDevice { other in
            _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Remote"))
        }
        await app.model.checkForExternalChanges()
        await waitUntil("the file watcher or the check merges the remote entry") {
            (try? app.entry(titled: "Remote")) != nil
        }

        let remote = try app.entry(titled: "Remote")
        XCTAssertTrue(app.model.externallyChangedEntryIDs.contains(remote.id))
        XCTAssertEqual(app.model.lastMergeSummary?.changes.map(\.kind), [.added])
        app.model.markExternalChangeSeen(remote.id)
        XCTAssertFalse(app.model.externallyChangedEntryIDs.contains(remote.id))
        XCTAssertNoThrow(try app.entry(titled: "Local"))
    }

    func testAskModeWaitsForTheUser() async throws {
        let app = try AppScenario(self, syncMode: .ask)
        try await app.createVault()

        try await app.editOnAnotherDevice { other in
            _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Remote"))
        }
        await waitUntil("ask mode reports the change") {
            app.model.syncStatus == .changedOnDisk
        }
        XCTAssertTrue(app.model.showsDiskChangeBanner)
        XCTAssertNil(try? app.entry(titled: "Remote"), "nothing is merged before the user asks")

        app.model.ignoreDiskChanges()
        XCTAssertFalse(app.model.showsDiskChangeBanner)
        app.model.showDiskChangeBanner()
        XCTAssertTrue(app.model.showsDiskChangeBanner)

        let preview = try await app.model.previewDiskChanges()
        XCTAssertEqual(preview.changes.count, 1)
        XCTAssertNil(try? app.entry(titled: "Remote"), "previewing changes nothing")

        await app.model.mergeDiskChanges()
        XCTAssertNoThrow(try app.entry(titled: "Remote"))
        XCTAssertFalse(app.model.showsDiskChangeBanner)
        guard case .synced = app.model.syncStatus else {
            return XCTFail("merged, got \(app.model.syncStatus)")
        }
    }

    func testLocalSaveInAskModeKeepsBothSides() async throws {
        let app = try AppScenario(self, syncMode: .ask)
        try await app.createVault()
        try await app.editOnAnotherDevice { other in
            _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Remote"))
        }

        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Local"))
        XCTAssertNoThrow(try app.entry(titled: "Remote"), "every save merges the file on disk first")
        XCTAssertFalse(app.model.showsDiskChangeBanner)
        let disk = try await app.readFromDisk()
        XCTAssertEqual(Set(disk.entries.map(\.title)), ["Local", "Remote"])
    }

    func testOffModeIgnoresDisk() async throws {
        let app = try AppScenario(self, syncMode: .off)
        try await app.createVault()
        XCTAssertEqual(app.model.syncStatus, .notWatching)

        try await app.editOnAnotherDevice { other in
            _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Remote"))
        }
        await app.model.checkForExternalChanges()
        XCTAssertNil(try? app.entry(titled: "Remote"))
        XCTAssertEqual(app.model.syncStatus, .notWatching)

        app.model.setSyncModeForSelectedVault(.automatic)
        XCTAssertEqual(app.model.syncModeForSelectedVault, .automatic)
        await waitUntil("switching to automatic picks up the waiting change") {
            (try? app.entry(titled: "Remote")) != nil
        }
    }

    func testRemoteEditOfSameEntryWinsAndKeepsHistory() async throws {
        let app = try AppScenario(self, syncMode: .ask)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Shared", password: "local"))
        let id = try app.entry(titled: "Shared").id

        try await app.editOnAnotherDevice { other in
            _ = try await other.updateEntry(id: id, form: VaultEntryForm(title: "Shared", password: "remote"))
        }
        await app.model.mergeDiskChanges()
        let merged = try app.entry(titled: "Shared")
        XCTAssertEqual(merged.password, "remote", "the newer version wins")
        XCTAssertTrue(merged.history.contains { $0.password == "local" })
    }

    func testMergeAnotherDatabaseFile() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mine"))

        let backup = app.directory.appendingPathComponent("Backup.kdbx")
        try FileManager.default.copyItem(at: app.url, to: backup)
        let other = KeePassKitVaultLoader()
        _ = try await other.loadVault(from: backup, masterPassword: app.password, keyFileURL: nil)
        _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From backup"))

        app.model.showMergeDatabase()
        XCTAssertEqual(app.model.mergeSheet?.kind, .database)
        let summary = try await app.model.prepareMerge(from: [VaultMergeSource(fileURL: backup, masterPassword: app.password)])
        XCTAssertEqual(summary.changes.map(\.kind), [.added])
        XCTAssertNil(try? app.entry(titled: "From backup"), "preparing doesn't change the open database")

        try await app.model.commitPreparedMerge(sourceName: "Backup.kdbx")
        XCTAssertNil(app.model.mergeSheet)
        XCTAssertNoThrow(try app.entry(titled: "From backup"))
        let disk = try await app.readFromDisk()
        XCTAssertEqual(Set(disk.entries.map(\.title)), ["Mine", "From backup"])
    }

    func testConflictCopiesAreOfferedAfterUnlock() async throws {
        let app = try AppScenario(self, syncMode: .ask)
        try await app.createVault()
        await app.lock()
        let copy = app.directory.appendingPathComponent("Vault (Mac's conflicted copy 2026-10-01).kdbx")
        try FileManager.default.copyItem(at: app.url, to: copy)

        app.settings.lookForConflictCopies = true
        await app.model.unlock(masterPassword: app.password)
        await waitUntil("the conflict copy is found") {
            app.model.syncAlert != nil
        }
        guard case .conflictCopies(let copies) = app.model.syncAlert else {
            return XCTFail("expected conflict copies, got \(String(describing: app.model.syncAlert))")
        }
        XCTAssertEqual(copies.map(\.fileURL.lastPathComponent), [copy.lastPathComponent])
        XCTAssertEqual(copies.first?.provider, .dropbox)

        app.model.reviewConflictCopies()
        XCTAssertNil(app.model.syncAlert)
        XCTAssertEqual(app.model.mergeSheet?.kind, .conflictCopies(copies))
        _ = try await app.model.prepareMerge(from: copies.map { VaultMergeSource(fileURL: $0.fileURL, masterPassword: app.password) })
        try await app.model.commitPreparedMerge(sourceName: copy.lastPathComponent)
        guard case .trashCopies = app.model.syncAlert else {
            return XCTFail("after merging the copies KeeMac offers to trash them")
        }
        app.model.dismissSyncAlert()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testExpiryBannerAfterUnlock() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old", expiresAt: Date().addingTimeInterval(-86_400)))
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Soon", expiresAt: Date().addingTimeInterval(2 * 86_400)))
        await app.lock()

        XCTAssertTrue(app.model.expiryBannerForSelectedVault)
        await app.model.unlock(masterPassword: app.password)
        XCTAssertTrue(app.model.showsExpiryBanner)

        app.model.openPasswordHealth()
        XCTAssertFalse(app.model.showsExpiryBanner)
        XCTAssertEqual(app.model.passwordHealthRequest?.warnDays, app.model.expiryWarnDaysForSelectedVault)
        app.model.consumePasswordHealthRequest()
        XCTAssertNil(app.model.passwordHealthRequest)

        await app.lock()
        app.model.expiryBannerForSelectedVault = false
        await app.model.unlock(masterPassword: app.password)
        XCTAssertFalse(app.model.showsExpiryBanner)
    }

    func testNoExpiryBannerWithoutExpiringEntries() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Later", expiresAt: Date().addingTimeInterval(365 * 86_400)))
        await app.lock()
        await app.model.unlock(masterPassword: app.password)
        XCTAssertFalse(app.model.showsExpiryBanner)
    }
}
