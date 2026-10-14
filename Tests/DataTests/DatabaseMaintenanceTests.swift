import AppKit
@testable import Data
import Domain
import Foundation
import KeePassKit
@testable import UI
import XCTest

final class DatabaseMaintenanceTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "maintenance"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Maintenance.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Maintenance",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(password: String? = nil, keyFileURL: URL? = nil) async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: vaultURL, masterPassword: password ?? self.password, keyFileURL: keyFileURL)
        return (loader, vault)
    }

    private func readTree() throws -> KPKTree {
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        return try KPKTree(data: Data(contentsOf: vaultURL), key: key)
    }

    // MARK: Settings

    func testCipherAndKeyDerivationRoundTrip() async throws {
        let (loader, _) = try await open()
        var settings = try await loader.databaseSettings()
        XCTAssertEqual(settings.cipher, .chacha20, "new databases use ChaCha20")
        settings.cipher = .twofish
        settings.kdf = .aes
        settings.aesRounds = 1_000
        _ = try await loader.updateDatabaseSettings(settings)

        let (reopened, _) = try await open()
        let read = try await reopened.databaseSettings()
        XCTAssertEqual(read.cipher, .twofish)
        XCTAssertEqual(read.kdf, .aes)
        XCTAssertEqual(read.aesRounds, 1_000)
        XCTAssertEqual(try readTree().metaData?.cipherUUID, KPKTwofishCipher.uuid())
    }

    func testUnlockTimeEstimateScalesWithIterations() throws {
        let one = try KeePassKitVaultLoader.estimatedUnlockSeconds(VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1))
        let ten = try KeePassKitVaultLoader.estimatedUnlockSeconds(VaultDatabaseSettings(kdf: .argon2id, argonIterations: 10, argonMemoryMiB: 8, argonParallelism: 1))
        XCTAssertGreaterThan(one, 0)
        XCTAssertGreaterThan(ten, one * 3)
    }

    func testHistoryLimits() async throws {
        let (loader, _) = try await open()
        var status = try await loader.maintenanceStatus()
        XCTAssertEqual(status.history, VaultHistoryLimits(maxItems: 10, maxSizeMB: 6), "KeePassKit's defaults")

        _ = try await loader.updateHistoryLimits(VaultHistoryLimits(maxItems: 2, maxSizeMB: nil))
        status = try await loader.maintenanceStatus()
        XCTAssertEqual(status.history, VaultHistoryLimits(maxItems: 2, maxSizeMB: nil))
        let meta = try XCTUnwrap(try readTree().metaData)
        XCTAssertEqual(meta.historyMaxItems, 2)
        XCTAssertEqual(meta.historyMaxSize, Int(Int32.max), "unlimited isn't -1, which KeePassKit reads as history off")
        XCTAssertTrue(meta.isHistoryEnabled)

        // New edits keep at most two versions.
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", password: "1"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Mail" }?.id)
        for value in ["2", "3", "4", "5"] {
            vault = try await loader.updateEntry(id: id, form: VaultEntryForm(title: "Mail", password: value))
        }
        XCTAssertEqual(vault.entries.first { $0.id == id }?.history.count, 2)

        _ = try await loader.updateHistoryLimits(VaultHistoryLimits(maxItems: nil, maxSizeMB: 3))
        status = try await loader.maintenanceStatus()
        XCTAssertEqual(status.history, VaultHistoryLimits(maxItems: nil, maxSizeMB: 3))
    }

    func testMinusOneFromKeePassReadsAsUnlimited() throws {
        let meta = KPKMetaData()
        meta.historyMaxItems = -1
        meta.historyMaxSize = -1
        XCTAssertEqual(KeePassKitVaultLoader.historyLimits(of: meta), VaultHistoryLimits(maxItems: nil, maxSizeMB: nil))
    }

    // MARK: Recycle bin

    private func trashOneEntry(_ loader: KeePassKitVaultLoader) async throws -> UUID {
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Old" }?.id)
        let trashed = try await loader.deleteEntry(id: id)
        XCTAssertTrue(try XCTUnwrap(trashed.entries.first { $0.id == id }).isTrashed)
        return id
    }

    func testTurningTheBinOffKeepsItAsAGroup() async throws {
        let (loader, _) = try await open()
        let id = try await trashOneEntry(loader)
        var status = try await loader.maintenanceStatus()
        XCTAssertTrue(status.usesRecycleBin)
        XCTAssertEqual(status.recycleBinEntryCount, 1)
        let binPath = try XCTUnwrap(status.recycleBinPath)

        let vault = try await loader.updateRecycleBin(enabled: false, group: .current, disposal: .keepAsGroup)
        XCTAssertFalse(vault.summary.usesRecycleBin)
        let old = try XCTUnwrap(vault.entries.first { $0.id == id })
        XCTAssertFalse(old.isTrashed, "the former bin is a normal group")
        XCTAssertEqual(old.groupPath, binPath)
        XCTAssertTrue(vault.groups.contains { $0.path == binPath && !$0.isTrash })
        status = try await loader.maintenanceStatus()
        XCTAssertFalse(status.usesRecycleBin)
        XCTAssertNil(status.recycleBinPath)

        // Deleting is now permanent.
        let deleted = try await loader.deleteEntry(id: id)
        XCTAssertNil(deleted.entries.first { $0.id == id })
    }

    func testTurningTheBinOffCanEmptyIt() async throws {
        let (loader, _) = try await open()
        let id = try await trashOneEntry(loader)
        let binPath = try await loader.maintenanceStatus().recycleBinPath

        let vault = try await loader.updateRecycleBin(enabled: false, group: .current, disposal: .empty)
        XCTAssertNil(vault.entries.first { $0.id == id })
        XCTAssertFalse(vault.groups.contains { $0.path == binPath })
        let undo = await loader.undoState()
        XCTAssertNil(undo.undoAction, "undo can't bring back what was emptied")

        let (_, reopened) = try await open()
        XCTAssertNil(reopened.entries.first { $0.id == id })
        XCTAssertFalse(reopened.summary.usesRecycleBin)
    }

    func testBinCanUseAnExistingOrNewGroup() async throws {
        let (loader, vault) = try await open()
        let root = try XCTUnwrap(vault.groups.first { !$0.path.contains(".") }?.path)
        _ = try await loader.createGroup(inParentPath: nil, title: "Deleted", iconID: nil)

        var updated = try await loader.updateRecycleBin(enabled: true, group: .existing(path: "\(root).Deleted"), disposal: nil)
        XCTAssertTrue(updated.groups.contains { $0.path == "\(root).Deleted" && $0.isTrash })
        let id = try await trashOneEntry(loader)
        updated = try await loader.updateRecycleBin(enabled: true, group: .current, disposal: nil)
        XCTAssertEqual(updated.entries.first { $0.id == id }?.groupPath, "\(root).Deleted")

        updated = try await loader.updateRecycleBin(enabled: true, group: .new, disposal: nil)
        let bin = try XCTUnwrap(updated.groups.first { $0.isTrash })
        XCTAssertEqual(bin.title, "Recycle Bin")
        XCTAssertNotEqual(bin.path, "\(root).Deleted")
        XCTAssertTrue(updated.groups.contains { $0.path == "\(root).Deleted" && !$0.isTrash }, "the old bin is a normal group again")

        do {
            _ = try await loader.updateRecycleBin(enabled: true, group: .existing(path: root), disposal: nil)
            XCTFail("the root can't be the bin")
        } catch {}
    }

    // MARK: Master key

    func testChangeMasterKeyChecksTheCurrentPassword() async throws {
        let (loader, _) = try await open()
        do {
            _ = try await loader.changeMasterKey(currentPassword: "wrong", currentKeyFileURL: nil, newPassword: "new", keyFile: .keep)
            XCTFail("a wrong current password is refused")
        } catch let error as VaultError {
            XCTAssertEqual(error, .wrongCurrentPassword)
        }
        let unchanged = try await loader.verifyMasterKey(password: password, keyFileURL: nil)
        XCTAssertTrue(unchanged)
    }

    func testChangePasswordOnly() async throws {
        let (loader, _) = try await open()
        let keyFile = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: "new", keyFile: .keep)
        XCTAssertNil(keyFile)
        _ = try await open(password: "new")
    }

    func testGenerateKeyFileThenRemoveIt() async throws {
        let (loader, _) = try await open()
        let keyURL = directory.appendingPathComponent("Maintenance.keyx")
        let result = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: "", keyFile: .generate(keyURL))
        XCTAssertEqual(result, keyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))

        do {
            _ = try await open()
            XCTFail("the password alone no longer opens it")
        } catch {}
        let (withKey, _) = try await open(keyFileURL: keyURL)
        let status = try await withKey.maintenanceStatus()
        XCTAssertTrue(status.hasPassword)

        let removed = try await withKey.changeMasterKey(currentPassword: password, currentKeyFileURL: keyURL, newPassword: nil, keyFile: .remove)
        XCTAssertNil(removed)
        _ = try await open()
    }

    func testChooseAnExistingKeyFile() async throws {
        let keyURL = directory.appendingPathComponent("Existing.keyx")
        try KeePassKitVaultLoader.generateKeyFile(at: keyURL)
        let (loader, _) = try await open()
        _ = try await loader.changeMasterKey(currentPassword: password, currentKeyFileURL: nil, newPassword: "other", keyFile: .use(keyURL))
        _ = try await open(password: "other", keyFileURL: keyURL)
    }

    func testRemovingTheOnlyKeyIsRefusedAndWritesNothing() async throws {
        let keyURL = directory.appendingPathComponent("Only.keyx")
        try KeePassKitVaultLoader.generateKeyFile(at: keyURL)
        let fileOnly = directory.appendingPathComponent("FileOnly.kdbx")
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: fileOnly,
            name: "FileOnly",
            masterPassword: "",
            keyFileURL: keyURL,
            keyDerivation: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        ))
        let fileLoader = KeePassKitVaultLoader()
        _ = try await fileLoader.loadVault(from: fileOnly, masterPassword: "", keyFileURL: keyURL)
        let fileStatus = try await fileLoader.maintenanceStatus()
        XCTAssertFalse(fileStatus.hasPassword)
        do {
            _ = try await fileLoader.changeMasterKey(currentPassword: "", currentKeyFileURL: keyURL, newPassword: nil, keyFile: .remove)
            XCTFail("a database needs some key")
        } catch let error as VaultError {
            XCTAssertEqual(error, .emptyMasterKey)
        }

        // A failed change doesn't leave a generated key file behind.
        let stray = directory.appendingPathComponent("Stray.keyx")
        do {
            _ = try await fileLoader.changeMasterKey(currentPassword: "wrong", currentKeyFileURL: keyURL, newPassword: nil, keyFile: .generate(stray))
            XCTFail("wrong current key")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: Icons

    private static func samplePNG(_ color: NSColor) -> Data? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        bitmap?.setColor(color, atX: 1, y: 1)
        return bitmap?.representation(using: .png, properties: [:])
    }

    func testRemovesOnlyUnusedIcons() async throws {
        let (loader, _) = try await open()
        // One icon in use (set like a downloaded favicon), two unused added the way other clients leave them.
        let vault = try await loader.addBrowserLogin(VaultBrowserNewLogin(title: "Site", url: "https://a.example", username: "", password: "", groupID: nil, allowedHosts: []))
        _ = try await loader.setBrowserEntryIcon(id: vault.entryID, imageData: try XCTUnwrap(Self.samplePNG(.systemBlue)))

        let tree = try readTree()
        for color in [NSColor.systemRed, .systemGreen] {
            tree.metaData?.addCustomIcon(KPKIcon(imageData: try XCTUnwrap(Self.samplePNG(color))))
        }
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        try tree.encrypt(with: key, format: .kdbx).write(to: vaultURL, options: .atomic)

        let (reopened, _) = try await open()
        var status = try await reopened.maintenanceStatus()
        XCTAssertEqual(status.unusedIconCount, 2)
        XCTAssertGreaterThan(status.unusedIconBytes, 0)

        let cleaned = try await reopened.removeUnusedCustomIcons()
        status = try await reopened.maintenanceStatus()
        XCTAssertEqual(status.unusedIconCount, 0)
        XCTAssertNotNil(cleaned.entries.first { $0.id == vault.entryID }?.iconPNGData, "the used icon stays")
        XCTAssertEqual(try readTree().metaData?.customIcons.count, 1)
    }
}

@MainActor
final class DatabaseMaintenanceViewModelTests: XCTestCase {
    func testChangedKeyFileIsRememberedForTheNextUnlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Model.kdbx")
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: url,
            name: "Model",
            masterPassword: "pw",
            keyDerivation: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        ))
        let suiteName = "DatabaseMaintenanceViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        let model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: url)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)

        let keyURL = directory.appendingPathComponent("Model.keyx")
        do {
            try await model.changeMasterKey(currentPassword: "nope", newPassword: "", keyFile: .generate(keyURL))
            XCTFail("wrong current password")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))

        try await model.changeMasterKey(currentPassword: "pw", newPassword: "", keyFile: .generate(keyURL))
        XCTAssertEqual(model.selectedKeyFileURL, keyURL)
        XCTAssertEqual(model.recentVaults.first?.keyFileURL, keyURL)

        model.lockVault(reason: .userInitiated)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked, "the remembered key file opens it")
    }
}
