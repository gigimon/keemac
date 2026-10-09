@testable import Data
import Domain
import Foundation
import KeePassKit
import XCTest

final class KeePassKitVaultLoaderTests: XCTestCase {
    private final class TestTreeEditingDelegate: NSObject, KPKTreeDelegate {
        func shouldEdit(_ tree: KPKTree) -> Bool {
            true
        }
    }

    func testLoadVaultFailsWhenVaultFileDoesNotExist() async {
        let loader = KeePassKitVaultLoader()
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("kdbx")

        do {
            _ = try await loader.loadVault(from: missingURL, masterPassword: "password", keyFileURL: nil)
            XCTFail("Expected failure for missing vault file.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .fileReadFailure(path: missingURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultFailsWhenKeyFileDoesNotExist() async throws {
        let loader = KeePassKitVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        let missingKeyFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("keyx")
        defer { TestSupport.removeIfExists(vaultURL) }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "password", keyFileURL: missingKeyFileURL)
            XCTFail("Expected failure for missing key file.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .fileReadFailure(path: missingKeyFileURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultFailsWhenNoCredentialsProvided() async throws {
        let loader = KeePassKitVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        defer { TestSupport.removeIfExists(vaultURL) }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "", keyFileURL: nil)
            XCTFail("Expected invalid password error.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .invalidPassword)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapKeePassErrorDetectsInvalidPasswordSignals() {
        let passwordError = NSError(
            domain: KPKErrorDomain,
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "The database header hash is wrong"]
        )

        XCTAssertEqual(KeePassKitVaultLoader.mapKeePassError(passwordError), .invalidPassword)
    }

    func testMapKeePassErrorDetectsUnsupportedVariantSignals() {
        let unsupportedError = NSError(
            domain: KPKErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported database format"]
        )

        XCTAssertEqual(KeePassKitVaultLoader.mapKeePassError(unsupportedError), .unsupportedKDBXVariant)
    }

    func testMapKeePassErrorFallsBackToParseFailureForOtherKeePassErrors() {
        let parseError = NSError(
            domain: KPKErrorDomain,
            code: 3001,
            userInfo: [NSLocalizedDescriptionKey: "General parse failure"]
        )

        XCTAssertEqual(
            KeePassKitVaultLoader.mapKeePassError(parseError),
            .parseFailure(details: "General parse failure")
        )
    }

    func testMapKeePassErrorReturnsUnknownForNonKeePassDomain() {
        let externalError = NSError(
            domain: "Network",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Socket closed"]
        )

        XCTAssertEqual(
            KeePassKitVaultLoader.mapKeePassError(externalError),
            .unknown(details: "Socket closed")
        )
    }

    func testCreateEntryPersistsToDiskAndCreatesBackup() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        let loaded = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let targetGroupPath = loaded.groups.first(where: { !$0.path.isEmpty })?.path

        let form = VaultEntryForm(
            title: "Created Entry",
            username: "created-user",
            password: "created-pass",
            url: "https://example.com",
            notes: "created-notes",
            iconID: 9,
            customFields: [
                VaultCustomFieldForm(key: "env", value: "prod", isProtected: false)
            ],
            attachments: [
                VaultAttachment(name: "config.txt", data: Data("hello attachment".utf8))
            ],
            otp: VaultOTPForm(
                secret: "JBSWY3DPEHPK3PXP",
                digits: 6,
                period: 30,
                algorithm: .sha1,
                storageStyle: .otpAuth
            )
        )

        let mutatedVault = try await loader.createEntry(inGroupPath: targetGroupPath, form: form)
        XCTAssertEqual(mutatedVault.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path + ".bak"))

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        guard let entry = persisted.entries.first(where: { $0.title == "Created Entry" }) else {
            return XCTFail("Created entry not found after reload.")
        }

        XCTAssertEqual(entry.username, "created-user")
        XCTAssertEqual(entry.password, "created-pass")
        XCTAssertEqual(entry.url?.absoluteString, "https://example.com")
        XCTAssertEqual(entry.notes, "created-notes")
        XCTAssertEqual(entry.iconID, 9)
        XCTAssertEqual(entry.customFields.count, 1)
        XCTAssertEqual(entry.customFields.first?.key, "env")
        XCTAssertEqual(entry.customFields.first?.value, "prod")
        XCTAssertEqual(entry.attachments.count, 1)
        XCTAssertEqual(entry.attachments.first?.name, "config.txt")
        XCTAssertEqual(String(data: try XCTUnwrap(entry.attachments.first?.data), encoding: .utf8), "hello attachment")
        XCTAssertEqual(entry.otp?.digits, 6)
        XCTAssertEqual(entry.otp?.period, 30)
        XCTAssertEqual(entry.otp?.algorithm, .sha1)
        XCTAssertEqual(entry.otpStorageStyle, .otpAuth)
    }

    func testExpiryAndQualityCheckPersist() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let created = try await loader.createEntry(
            inGroupPath: nil,
            form: VaultEntryForm(title: "Expiring", password: "secret", expiresAt: expiresAt, checksPasswordQuality: false)
        )
        let entryID = try XCTUnwrap(created.entries.first(where: { $0.title == "Expiring" })?.id)

        let persisted = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let entry = try XCTUnwrap(persisted.entries.first(where: { $0.id == entryID }))
        XCTAssertEqual(try XCTUnwrap(entry.expiresAt).timeIntervalSince1970, expiresAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(entry.checksPasswordQuality)

        var form = VaultEntryForm(title: "Expiring", password: "secret")
        form.expiresAt = nil
        let updated = try await loader.updateEntry(id: entryID, form: form)
        let updatedEntry = try XCTUnwrap(updated.entries.first(where: { $0.id == entryID }))
        XCTAssertNil(updatedEntry.expiresAt)
        XCTAssertTrue(updatedEntry.checksPasswordQuality)
    }

    func testPasswordChangedAtIgnoresEditsThatKeepPassword() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Site", password: "first"))
        let original = try XCTUnwrap(created.entries.first(where: { $0.title == "Site" }))
        let originalChange = try XCTUnwrap(original.passwordChangedAt)

        try await Task.sleep(for: .milliseconds(1100))
        let renamed = try await loader.updateEntry(id: original.id, form: VaultEntryForm(title: "Site 2", password: "first"))
        let afterRename = try XCTUnwrap(renamed.entries.first(where: { $0.id == original.id }))
        XCTAssertEqual(try XCTUnwrap(afterRename.passwordChangedAt).timeIntervalSince1970, originalChange.timeIntervalSince1970, accuracy: 1)

        try await Task.sleep(for: .milliseconds(1100))
        let changed = try await loader.updateEntry(id: original.id, form: VaultEntryForm(title: "Site 2", password: "second"))
        let afterChange = try XCTUnwrap(changed.entries.first(where: { $0.id == original.id }))
        XCTAssertGreaterThan(try XCTUnwrap(afterChange.passwordChangedAt), originalChange.addingTimeInterval(1.5))
    }

    func testRecordEntryUsageIsSavedOnlyWhenFlushed() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Used"))
        let entryID = try XCTUnwrap(created.entries.first(where: { $0.title == "Used" })?.id)
        let baseline = try XCTUnwrap(created.entries.first(where: { $0.id == entryID })?.usageCount)

        let touched = try await loader.recordEntryUsage(id: entryID)
        XCTAssertEqual(touched.entries.first(where: { $0.id == entryID })?.usageCount, baseline + 1)

        let beforeFlush = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(beforeFlush.entries.first(where: { $0.id == entryID })?.usageCount, baseline)

        try await loader.savePendingChanges()
        let afterFlush = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(afterFlush.entries.first(where: { $0.id == entryID })?.usageCount, baseline + 1)
    }

    func testCreateVaultWithPasswordAndGeneratedKeyFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = directory.appendingPathComponent("Family.kdbx")
        let keyFileURL = directory.appendingPathComponent("Family.keyx")
        try KeePassKitVaultLoader.generateKeyFile(at: keyFileURL)

        var kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 2, argonMemoryMiB: 16, argonParallelism: 2)
        kdf.name = "ignored"
        let options = VaultCreationOptions(
            fileURL: vaultURL,
            name: "Family",
            details: "Shared logins",
            masterPassword: "correct horse",
            keyFileURL: keyFileURL,
            useTrash: false,
            historyMaxItems: 5,
            cipher: .twofish,
            keyDerivation: kdf,
            compress: false
        )

        let created = try await KeePassKitVaultLoader().createVault(options: options)
        XCTAssertEqual(created.summary.fileName, "Family.kdbx")
        XCTAssertNotNil(created.summary.masterKeyChangedAt)

        let reopenedLoader = KeePassKitVaultLoader()
        let reopened = try await reopenedLoader.loadVault(from: vaultURL, masterPassword: "correct horse", keyFileURL: keyFileURL)
        XCTAssertEqual(reopened.groups.first(where: { !$0.path.contains(".") })?.title, "Family")
        let settings = try await reopenedLoader.databaseSettings()
        XCTAssertEqual(settings.name, "Family")
        XCTAssertEqual(settings.details, "Shared logins")
        XCTAssertEqual(settings.kdf, .argon2id)
        XCTAssertEqual(settings.argonMemoryMiB, 16)

        do {
            _ = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: "correct horse", keyFileURL: nil)
            XCTFail("Opening without the key file must fail.")
        } catch {}

        do {
            _ = try await KeePassKitVaultLoader().createVault(options: options)
            XCTFail("Creating over an existing file must fail.")
        } catch {}
    }

    func testHeaderReaderReportsCipherAndKeyDerivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(VaultCipher, VaultKDFAlgorithm)] = [(.chacha20, .argon2id), (.twofish, .argon2d), (.aes256, .aes)]
        for (index, (cipher, kdf)) in cases.enumerated() {
            let url = directory.appendingPathComponent("Header\(index).kdbx")
            let settings = VaultDatabaseSettings(kdf: kdf, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1, aesRounds: 1_000)
            _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
                fileURL: url,
                name: "Header",
                masterPassword: "secret",
                cipher: cipher,
                keyDerivation: settings
            ))

            let info = try XCTUnwrap(KDBXHeaderReader.read(from: url))
            XCTAssertEqual(info.cipher, cipher)
            XCTAssertEqual(info.kdf, kdf)
            XCTAssertTrue(info.majorVersion == 3 || info.majorVersion == 4)
            XCTAssertTrue(info.summary.hasPrefix("KDBX "))
        }

        let garbage = directory.appendingPathComponent("garbage.kdbx")
        try Data("not a database".utf8).write(to: garbage)
        XCTAssertNil(KDBXHeaderReader.read(from: garbage))
    }

    func testCalibrationScalesWorkFactor() throws {
        let base = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 16, argonParallelism: 2)
        let fast = try KeePassKitVaultLoader.calibrate(base, targetSeconds: 0.05)
        let slow = try KeePassKitVaultLoader.calibrate(base, targetSeconds: 0.5)
        XCTAssertGreaterThanOrEqual(fast.argonIterations, 1)
        XCTAssertGreaterThan(slow.argonIterations, fast.argonIterations)

        let aes = try KeePassKitVaultLoader.calibrate(VaultDatabaseSettings(kdf: .aes), targetSeconds: 0.1)
        XCTAssertGreaterThanOrEqual(aes.aesRounds, 1_000)
    }

    func testUpdateEntryPersistsNativeOTPAndCustomFields() async throws {
        let password = "master-password"
        let seedEntry = SeedEntry(
            title: "Seed Entry",
            username: "seed-user",
            password: "seed-pass",
            url: "https://seed.local",
            notes: "seed-notes"
        )
        let vaultURL = try makeVaultFile(password: password, seedEntry: seedEntry)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        let loaded = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        guard let existing = loaded.entries.first else {
            return XCTFail("Seed entry not found.")
        }

        let updateForm = VaultEntryForm(
            title: "Updated Entry",
            username: "updated-user",
            password: "updated-pass",
            url: "https://updated.local",
            notes: "updated-notes",
            iconID: 58,
            customFields: [
                VaultCustomFieldForm(key: "tier", value: "gold", isProtected: false),
                VaultCustomFieldForm(key: "token", value: "secret", isProtected: true)
            ],
            otp: VaultOTPForm(
                secret: "4a656665",
                digits: 8,
                period: 45,
                algorithm: .sha512,
                storageStyle: .native
            )
        )

        let updatedVault = try await loader.updateEntry(id: existing.id, form: updateForm)
        XCTAssertEqual(updatedVault.entries.count, 1)

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        guard let entry = persisted.entries.first(where: { $0.id == existing.id }) else {
            return XCTFail("Updated entry not found after reload.")
        }

        XCTAssertEqual(entry.title, "Updated Entry")
        XCTAssertEqual(entry.username, "updated-user")
        XCTAssertEqual(entry.password, "updated-pass")
        XCTAssertEqual(entry.url?.absoluteString, "https://updated.local")
        XCTAssertEqual(entry.notes, "updated-notes")
        XCTAssertEqual(entry.iconID, 58)
        XCTAssertEqual(entry.customFields.count, 2)
        XCTAssertTrue(entry.customFields.contains(where: { $0.key == "tier" && $0.value == "gold" && !$0.isProtected }))
        XCTAssertTrue(entry.customFields.contains(where: { $0.key == "token" && $0.value == "secret" && $0.isProtected }))
        XCTAssertEqual(entry.otp?.digits, 8)
        XCTAssertEqual(entry.otp?.period, 45)
        XCTAssertEqual(entry.otp?.algorithm, .sha512)
        XCTAssertEqual(entry.otpStorageStyle, .native)
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertEqual(entry.history.first?.title, "Seed Entry")
        XCTAssertEqual(entry.history.first?.username, "seed-user")
    }

    func testDeleteEntryPersistsToDisk() async throws {
        let password = "master-password"
        let seedEntry = SeedEntry(
            title: "Entry To Delete",
            username: "user",
            password: "pass",
            url: "https://delete.local",
            notes: "notes"
        )
        let vaultURL = try makeVaultFile(password: password, seedEntry: seedEntry)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        let loaded = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        guard let existing = loaded.entries.first else {
            return XCTFail("Seed entry not found.")
        }

        let afterDelete = try await loader.deleteEntry(id: existing.id)
        let trashedAfterDelete = try XCTUnwrap(afterDelete.entries.first(where: { $0.id == existing.id }))
        XCTAssertTrue(trashedAfterDelete.isTrashed)

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        let persistedTrashed = try XCTUnwrap(persisted.entries.first(where: { $0.id == existing.id }))
        XCTAssertTrue(persistedTrashed.isTrashed)
    }

    func testRestoreEntryMovesItOutOfTrashAndPersists() async throws {
        let password = "master-password"
        let seedEntry = SeedEntry(
            title: "Entry To Restore",
            username: "user",
            password: "pass",
            url: "https://restore.local",
            notes: "notes"
        )
        let vaultURL = try makeVaultFile(password: password, seedEntry: seedEntry)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        let loaded = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let existing = try XCTUnwrap(loaded.entries.first)

        let trashedVault = try await loader.deleteEntry(id: existing.id)
        XCTAssertTrue(try XCTUnwrap(trashedVault.entries.first(where: { $0.id == existing.id })).isTrashed)

        let restoredVault = try await loader.restoreEntry(id: existing.id)
        let restoredEntry = try XCTUnwrap(restoredVault.entries.first(where: { $0.id == existing.id }))
        XCTAssertFalse(restoredEntry.isTrashed)
        XCTAssertEqual(restoredEntry.groupPath, existing.groupPath)

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        let persistedEntry = try XCTUnwrap(persisted.entries.first(where: { $0.id == existing.id }))
        XCTAssertFalse(persistedEntry.isTrashed)
        XCTAssertEqual(persistedEntry.groupPath, existing.groupPath)
    }

    func testRevertEntryRestoresSelectedHistoryRevision() async throws {
        let password = "master-password"
        let seedEntry = SeedEntry(
            title: "Version 1",
            username: "user-v1",
            password: "pass-v1",
            url: "https://v1.local",
            notes: "notes-v1"
        )
        let vaultURL = try makeVaultFile(password: password, seedEntry: seedEntry)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        let loaded = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let existing = try XCTUnwrap(loaded.entries.first)

        _ = try await loader.updateEntry(
            id: existing.id,
            form: VaultEntryForm(
                title: "Version 2",
                username: "user-v2",
                password: "pass-v2",
                url: "https://v2.local",
                notes: "notes-v2"
            )
        )

        let afterSecondUpdate = try await loader.updateEntry(
            id: existing.id,
            form: VaultEntryForm(
                title: "Version 3",
                username: "user-v3",
                password: "pass-v3",
                url: "https://v3.local",
                notes: "notes-v3"
            )
        )
        let current = try XCTUnwrap(afterSecondUpdate.entries.first(where: { $0.id == existing.id }))
        XCTAssertEqual(current.history.count, 2)
        XCTAssertEqual(current.history.first?.title, "Version 2")

        let revertedVault = try await loader.revertEntry(id: existing.id, toHistoryRevisionAt: 0)
        let revertedEntry = try XCTUnwrap(revertedVault.entries.first(where: { $0.id == existing.id }))
        XCTAssertEqual(revertedEntry.title, "Version 2")
        XCTAssertEqual(revertedEntry.username, "user-v2")
        XCTAssertEqual(revertedEntry.url?.absoluteString, "https://v2.local")
    }

    func testCreateGroupAndSubgroupPersistToDisk() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)

        let afterGroupCreate = try await loader.createGroup(inParentPath: nil, title: "Services", iconID: 18)
        guard let servicesGroupPath = afterGroupCreate.groups.first(where: { $0.title == "Services" })?.path else {
            return XCTFail("Created group path not found.")
        }

        let afterSubgroupCreate = try await loader.createGroup(inParentPath: servicesGroupPath, title: "Prod", iconID: nil)
        let subgroup = afterSubgroupCreate.groups.first(where: { $0.title == "Prod" })
        XCTAssertNotNil(subgroup)
        XCTAssertTrue(subgroup?.path.hasSuffix(".Prod") ?? false)
        XCTAssertTrue(subgroup?.path.hasPrefix(servicesGroupPath) ?? false)

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        XCTAssertTrue(persisted.groups.contains(where: { $0.title == "Services" }))
        XCTAssertTrue(persisted.groups.contains(where: { $0.title == "Prod" }))
    }

    func testDeleteGroupRemovesNestedSubgroupsFromVisibleVault() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let afterGroupCreate = try await loader.createGroup(inParentPath: nil, title: "Services", iconID: nil)
        guard let servicesGroupPath = afterGroupCreate.groups.first(where: { $0.title == "Services" })?.path else {
            return XCTFail("Created group path not found.")
        }
        _ = try await loader.createGroup(inParentPath: servicesGroupPath, title: "Prod", iconID: nil)

        let afterDelete = try await loader.deleteGroup(path: servicesGroupPath)
        XCTAssertFalse(afterDelete.groups.contains(where: { $0.title == "Services" }))
        XCTAssertFalse(afterDelete.groups.contains(where: { $0.title == "Prod" }))

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        XCTAssertFalse(persisted.groups.contains(where: { $0.title == "Services" }))
        XCTAssertFalse(persisted.groups.contains(where: { $0.title == "Prod" }))
    }

    func testUpdateGroupRenamesAndUpdatesIcon() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let afterGroupCreate = try await loader.createGroup(inParentPath: nil, title: "Services", iconID: 5)

        guard let createdGroup = afterGroupCreate.groups.first(where: { $0.title == "Services" }) else {
            return XCTFail("Created group not found.")
        }

        let afterUpdate = try await loader.updateGroup(path: createdGroup.path, title: "Platforms", iconID: 31)
        guard let updatedGroup = afterUpdate.groups.first(where: { $0.title == "Platforms" }) else {
            return XCTFail("Updated group not found after edit.")
        }
        XCTAssertEqual(updatedGroup.iconID, 31)
        XCTAssertFalse(afterUpdate.groups.contains(where: { $0.title == "Services" }))

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        guard let persistedGroup = persisted.groups.first(where: { $0.title == "Platforms" }) else {
            return XCTFail("Updated group not found after reload.")
        }
        XCTAssertEqual(persistedGroup.iconID, 31)
    }

    func testChangeMasterPasswordReEncryptsWithNewPassword() async throws {
        let oldPassword = "old-password"
        let newPassword = "brand-new-password"
        let vaultURL = try makeVaultFile(password: oldPassword, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: oldPassword, keyFileURL: nil)
        try await loader.changeMasterKey(newPassword: newPassword, keyFileURL: nil)

        // New password must open the vault.
        _ = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: newPassword, keyFileURL: nil)

        // Old password must now fail.
        do {
            _ = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: oldPassword, keyFileURL: nil)
            XCTFail("Old password should no longer unlock the vault.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .invalidPassword)
        }
    }

    func testUpdateDatabaseSettingsPersistsKDFAndMetadata() async throws {
        let password = "master-password"
        let vaultURL = try makeVaultFile(password: password, seedEntry: nil)
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(URL(fileURLWithPath: vaultURL.path + ".bak"))
        }

        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)

        var settings = try await loader.databaseSettings()
        settings.name = "My Vault"
        settings.details = "Test description"
        settings.kdf = .argon2id
        settings.argonIterations = 5
        settings.argonMemoryMiB = 32
        settings.argonParallelism = 4
        _ = try await loader.updateDatabaseSettings(settings)

        // Reopen with the same password (KDF change must keep the key valid) and verify settings.
        let reopened = KeePassKitVaultLoader()
        _ = try await reopened.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let persisted = try await reopened.databaseSettings()

        XCTAssertEqual(persisted.name, "My Vault")
        XCTAssertEqual(persisted.details, "Test description")
        XCTAssertEqual(persisted.kdf, .argon2id)
        XCTAssertEqual(persisted.argonIterations, 5)
        XCTAssertEqual(persisted.argonMemoryMiB, 32)
        XCTAssertEqual(persisted.argonParallelism, 4)
    }

    private struct SeedEntry {
        let title: String
        let username: String
        let password: String
        let url: String
        let notes: String
    }

    private func makeVaultFile(password: String, seedEntry: SeedEntry?) throws -> URL {
        let fileURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        let tree = KPKTree(templateContents: ())
        let editingDelegate = TestTreeEditingDelegate()
        tree.delegate = editingDelegate

        let rootGroup: KPKGroup
        if let existingRoot = tree.root {
            rootGroup = existingRoot
        } else {
            let createdRoot = tree.createGroup(nil)
            createdRoot.title = "Root"
            rootGroup = createdRoot
        }

        let targetGroup = tree.allGroups.first ?? rootGroup

        if let seedEntry {
            let entry = tree.createEntry(targetGroup)
            entry.add(to: targetGroup)
            entry.title = seedEntry.title
            entry.username = seedEntry.username
            entry.password = seedEntry.password
            entry.url = seedEntry.url
            entry.notes = seedEntry.notes
        }

        guard let key = KPKPasswordKey(password: password) else {
            XCTFail("Failed to create password key")
            return fileURL
        }
        let composite = KPKCompositeKey(keys: [key])
        let encrypted = try tree.encrypt(with: composite, format: .kdbx)
        try encrypted.write(to: fileURL, options: [.atomic])
        return fileURL
    }
}
