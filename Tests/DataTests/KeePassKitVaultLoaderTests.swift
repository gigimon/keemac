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
            customFields: [
                VaultCustomFieldForm(key: "env", value: "prod", isProtected: false)
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
        XCTAssertEqual(entry.customFields.count, 1)
        XCTAssertEqual(entry.customFields.first?.key, "env")
        XCTAssertEqual(entry.customFields.first?.value, "prod")
        XCTAssertEqual(entry.otp?.digits, 6)
        XCTAssertEqual(entry.otp?.period, 30)
        XCTAssertEqual(entry.otp?.algorithm, .sha1)
        XCTAssertEqual(entry.otpStorageStyle, .otpAuth)
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
        XCTAssertEqual(entry.customFields.count, 2)
        XCTAssertTrue(entry.customFields.contains(where: { $0.key == "tier" && $0.value == "gold" && !$0.isProtected }))
        XCTAssertTrue(entry.customFields.contains(where: { $0.key == "token" && $0.value == "secret" && $0.isProtected }))
        XCTAssertEqual(entry.otp?.digits, 8)
        XCTAssertEqual(entry.otp?.period, 45)
        XCTAssertEqual(entry.otp?.algorithm, .sha512)
        XCTAssertEqual(entry.otpStorageStyle, .native)
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
        XCTAssertFalse(afterDelete.entries.contains(where: { $0.id == existing.id }))

        let persisted = try await KeePassKitVaultLoader().loadVault(
            from: vaultURL,
            masterPassword: password,
            keyFileURL: nil
        )
        XCTAssertFalse(persisted.entries.contains(where: { $0.id == existing.id }))
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
