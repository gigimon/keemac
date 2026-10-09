@testable import Data
import Domain
import Foundation
import XCTest

/// Two loader instances on the same file stand in for two devices.
final class VaultSyncTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "sync-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Shared.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Shared",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna", password: "original"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    private func reopen() async throws -> LoadedVault {
        try await open().1
    }

    func testOwnWritesAreNotExternalChanges() async throws {
        let (mac, _) = try await open()
        _ = try await mac.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank"))
        let status = await mac.diskStatus()
        XCTAssertEqual(status, .unchanged)
    }

    func testSaveMergesEntriesAddedOnBothDevices() async throws {
        let (mac, _) = try await open()
        let (phone, _) = try await open()

        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Phone"))
        _ = try await mac.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Mac"))

        let reopened = try await reopen()
        let titles = Set(reopened.entries.map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["Mail", "From Phone", "From Mac"]))

        let pending = await mac.takePendingMergeSummary()
        let summary = try XCTUnwrap(pending)
        XCTAssertEqual(summary.changes.map(\.title), ["From Phone"])
        XCTAssertEqual(summary.changes.first?.kind, .added)
    }

    func testOverwriteByAnotherClientIsUndoneOnMerge() async throws {
        let staleCopy = try Data(contentsOf: vaultURL)
        let (mac, _) = try await open()
        _ = try await mac.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Only On Mac"))

        // A client without merge support writes its older copy over the file.
        try staleCopy.write(to: vaultURL)
        let overwritten = try await reopen()
        XCTAssertFalse(overwritten.entries.contains { $0.title == "Only On Mac" })

        let status = await mac.diskStatus()
        XCTAssertEqual(status, .changed)
        let result = try await mac.mergeExternalChanges()
        XCTAssertTrue(result.summary.isEmpty)
        let restored = try await reopen()
        XCTAssertTrue(restored.entries.contains { $0.title == "Only On Mac" })
    }

    func testConcurrentEditKeepsLosingVersionInHistory() async throws {
        let (mac, vault) = try await open()
        let (phone, _) = try await open()
        let mail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" })

        // KDBX timestamps have one-second precision; keep the three versions apart.
        try await Task.sleep(for: .milliseconds(1_100))
        _ = try await phone.updateEntry(id: mail.id, form: VaultEntryForm(title: "Mail", username: "anna", password: "from-phone"))
        try await Task.sleep(for: .milliseconds(1_100))
        _ = try await mac.updateEntry(id: mail.id, form: VaultEntryForm(title: "Mail", username: "anna", password: "from-mac"))

        let reopened = try await reopen()
        let merged = try XCTUnwrap(reopened.entries.first { $0.id == mail.id })
        XCTAssertEqual(merged.password, "from-mac")
        XCTAssertTrue(merged.history.contains { $0.password == "from-phone" })

        let pending = await mac.takePendingMergeSummary()
        let summary = try XCTUnwrap(pending)
        XCTAssertEqual(summary.conflictCount, 1)
    }

    func testNewerExternalEditWinsOnMerge() async throws {
        let (mac, vault) = try await open()
        let (phone, _) = try await open()
        let mail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" })

        try await Task.sleep(for: .milliseconds(1_100))
        _ = try await phone.updateEntry(id: mail.id, form: VaultEntryForm(title: "Mail", username: "anna", password: "rotated", notes: "rotated on phone"))

        let result = try await mac.mergeExternalChanges()
        let change = try XCTUnwrap(result.summary.changes.first)
        XCTAssertEqual(change.kind, .updated)
        XCTAssertEqual(change.changedFields, ["password", "notes"])
        XCTAssertFalse(change.isConflict)
        XCTAssertEqual(result.vault.entries.first { $0.id == mail.id }?.password, "rotated")
    }

    func testDeletionOnOtherDeviceCarriesOver() async throws {
        let (mac, vault) = try await open()
        let (phone, _) = try await open()
        let mail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" })

        _ = try await phone.deleteEntry(id: mail.id)
        let result = try await mac.mergeExternalChanges()

        XCTAssertEqual(result.summary.changes.map(\.kind), [.deleted])
        XCTAssertTrue(result.vault.entries.first { $0.id == mail.id }?.isTrashed ?? true)
    }

    func testPreviewDoesNotTouchOpenDatabase() async throws {
        let (mac, _) = try await open()
        let (phone, _) = try await open()
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Preview Me"))

        let preview = try await mac.previewExternalChanges()
        XCTAssertEqual(preview.changes.map(\.title), ["Preview Me"])
        let status = await mac.diskStatus()
        XCTAssertEqual(status, .changed)

        let result = try await mac.mergeExternalChanges()
        XCTAssertEqual(result.summary.changes.map(\.title), ["Preview Me"])
    }

    func testMergeWithoutLocalChangesDoesNotRewriteFile() async throws {
        let (mac, _) = try await open()
        let (phone, _) = try await open()
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Phone Entry"))
        let phoneBytes = try Data(contentsOf: vaultURL)

        _ = try await mac.mergeExternalChanges()

        XCTAssertEqual(try Data(contentsOf: vaultURL), phoneBytes)
        let status = await mac.diskStatus()
        XCTAssertEqual(status, .unchanged)
    }
}

final class VaultSnapshotTests: XCTestCase {
    private var directory: URL!
    private var snapshots: URL!
    private var vaultURL: URL!
    private let password = "snapshot-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        snapshots = directory.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Shared.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Shared",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mac() -> KeePassKitVaultLoader {
        KeePassKitVaultLoader(snapshotDirectory: snapshots)
    }

    func testOverwriteWhileLockedIsRestoredOnUnlock() async throws {
        let staleCopy = try Data(contentsOf: vaultURL)
        let session = mac()
        _ = try await session.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        _ = try await session.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Saved On Mac"))
        await session.clearLoadedSession()

        try staleCopy.write(to: vaultURL)

        let next = mac()
        let vault = try await next.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertTrue(vault.entries.contains { $0.title == "Saved On Mac" })
        let restored = await next.takeRestoreSummary()
        XCTAssertEqual(restored?.changes.map(\.title), ["Saved On Mac"])

        let onDisk = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertTrue(onDisk.entries.contains { $0.title == "Saved On Mac" })
    }

    func testProperMergeElsewhereNeedsNoRestore() async throws {
        let session = mac()
        _ = try await session.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        _ = try await session.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Saved On Mac"))
        await session.clearLoadedSession()

        let phone = KeePassKitVaultLoader()
        _ = try await phone.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Saved On Phone"))
        let phoneBytes = try Data(contentsOf: vaultURL)

        let next = mac()
        let vault = try await next.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(Set(vault.entries.map(\.title)), ["Saved On Mac", "Saved On Phone"])
        let restored = await next.takeRestoreSummary()
        XCTAssertNil(restored)
        XCTAssertEqual(try Data(contentsOf: vaultURL), phoneBytes)
    }

    func testSnapshotsAreOffUnlessConfigured() async throws {
        let plain = KeePassKitVaultLoader()
        _ = try await plain.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        _ = try await plain.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "No Snapshot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshots.path))

        let session = mac()
        _ = try await session.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        XCTAssertEqual(files.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshots.appendingPathComponent(files[0]).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDiscardSnapshotRemovesCopy() async throws {
        let session = mac()
        _ = try await session.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).count, 1)
        await session.discardSnapshot(for: vaultURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).count, 0)
    }
}

/// Merging other database files: conflicting copies and "Merge Database…".
final class VaultManualMergeTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "merge-test"
    private let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Personal.kdbx")
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Personal",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConflictCopyIsMergedWithCurrentKey() async throws {
        // Another device saved its own copy instead of updating the file.
        let copyURL = directory.appendingPathComponent("Personal (Anna's conflicted copy 2026-10-01).kdbx")
        try FileManager.default.copyItem(at: vaultURL, to: copyURL)
        let phone = KeePassKitVaultLoader()
        _ = try await phone.loadVault(from: copyURL, masterPassword: password, keyFileURL: nil)
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Copy"))

        let mac = KeePassKitVaultLoader()
        _ = try await mac.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let preview = try await mac.prepareMerge(from: [VaultMergeSource(fileURL: copyURL)])
        XCTAssertEqual(preview.changes.map(\.title), ["From Copy"])
        XCTAssertEqual(preview.changes.first?.kind, .added)

        let result = try await mac.commitPreparedMerge()
        XCTAssertEqual(result.summary.changes.map(\.title), ["From Copy"])
        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertTrue(reopened.entries.contains { $0.title == "From Copy" })
    }

    func testMergeDatabaseWithItsOwnKey() async throws {
        // KDBX timestamps have one-second precision; make the other database's settings clearly newer.
        try await Task.sleep(for: .seconds(1.2))
        let otherURL = directory.appendingPathComponent("Old.kdbx")
        let other = KeePassKitVaultLoader()
        _ = try await other.createVault(options: VaultCreationOptions(
            fileURL: otherURL,
            name: "Old",
            masterPassword: "other-password",
            keyDerivation: VaultDatabaseSettings(kdf: .argon2d, argonIterations: 2, argonMemoryMiB: 16, argonParallelism: 2)
        ))
        _ = try await other.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Legacy Bank"))

        let mac = KeePassKitVaultLoader()
        _ = try await mac.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)

        do {
            _ = try await mac.prepareMerge(from: [VaultMergeSource(fileURL: otherURL, masterPassword: "wrong")])
            XCTFail("Wrong password must not open the other database")
        } catch {}

        let preview = try await mac.prepareMerge(from: [VaultMergeSource(fileURL: otherURL, masterPassword: "other-password")])
        XCTAssertTrue(preview.changes.contains { $0.title == "Legacy Bank" && $0.kind == .added })
        let settingsBefore = try await mac.databaseSettings()
        let result = try await mac.commitPreparedMerge()
        XCTAssertTrue(result.vault.entries.contains { $0.title == "Legacy Bank" })
        XCTAssertTrue(result.vault.entries.contains { $0.title == "Mail" })

        // The other database is newer, but its name and encryption must not replace ours.
        let settingsAfter = try await mac.databaseSettings()
        XCTAssertEqual(settingsAfter.name, "Personal")
        XCTAssertEqual(settingsAfter, settingsBefore)
        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertTrue(reopened.entries.contains { $0.title == "Legacy Bank" })
    }

    func testDiscardedMergeChangesNothing() async throws {
        let copyURL = directory.appendingPathComponent("Personal 2.kdbx")
        try FileManager.default.copyItem(at: vaultURL, to: copyURL)
        let phone = KeePassKitVaultLoader()
        _ = try await phone.loadVault(from: copyURL, masterPassword: password, keyFileURL: nil)
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Copy"))

        let mac = KeePassKitVaultLoader()
        _ = try await mac.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let before = try Data(contentsOf: vaultURL)
        _ = try await mac.prepareMerge(from: [VaultMergeSource(fileURL: copyURL)])
        await mac.discardPreparedMerge()
        XCTAssertEqual(try Data(contentsOf: vaultURL), before)
        do {
            _ = try await mac.commitPreparedMerge()
            XCTFail("Nothing should be left to merge")
        } catch {}
    }

    func testFinderMatchesSyncServiceCopiesOnly() throws {
        let names = [
            "Personal 2.kdbx",
            "Personal (Anna's conflicted copy 2026-10-01).kdbx",
            "Personal.sync-conflict-20261001-210700-ABCDEFG.kdbx",
            "Personal.kdbx.bak",
            "Personal Old.kdbx",
            "Work 2.kdbx"
        ]
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let found = VaultConflictCopyFinder.copies(of: vaultURL)
        XCTAssertEqual(
            Set(found.map(\.fileURL.lastPathComponent)),
            ["Personal 2.kdbx", "Personal (Anna's conflicted copy 2026-10-01).kdbx", "Personal.sync-conflict-20261001-210700-ABCDEFG.kdbx"]
        )
        XCTAssertEqual(found.first { $0.fileURL.lastPathComponent == "Personal 2.kdbx" }?.provider, .iCloud)
    }
}
