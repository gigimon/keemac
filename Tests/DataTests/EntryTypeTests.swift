@testable import Data
import Domain
import Foundation
import XCTest

final class EntryTypeTests: XCTestCase {
    private var directory: URL!
    private let password = "types-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVault(_ name: String, kdf: VaultDatabaseSettings, cipher: VaultCipher = .chacha20) async throws -> (KeePassKitVaultLoader, URL) {
        let url = directory.appendingPathComponent(name)
        let loader = KeePassKitVaultLoader()
        var options = VaultCreationOptions(fileURL: url, name: name, masterPassword: password, keyDerivation: kdf)
        options.cipher = cipher
        _ = try await loader.createVault(options: options)
        return (loader, url)
    }

    func testTypeAndTemplateNameRoundTrip() async throws {
        let (loader, url) = try await makeVault(
            "Types.kdbx",
            kdf: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        )
        var card = VaultEntryForm(title: "Revolut Visa", username: "Anna", password: "4111111111111111", entryType: .card)
        card.customFields = [
            VaultCustomFieldForm(key: VaultTypedField.expiry, value: "09/29", isProtected: false),
            VaultCustomFieldForm(key: VaultTypedField.cvv, value: "123", isProtected: true)
        ]
        _ = try await loader.createEntry(inGroupPath: nil, form: card)
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Passport", entryType: .template, templateName: "Passport"))
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Plain"))
        XCTAssertTrue(created.summary.supportsEntryTypes)

        let reopened = try await KeePassKitVaultLoader().loadVault(from: url, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(reopened.entries.first { $0.title == "Revolut Visa" }?.entryType, .card)
        let passport = reopened.entries.first { $0.title == "Passport" }
        XCTAssertEqual(passport?.entryType, .template)
        XCTAssertEqual(passport?.templateName, "Passport")
        XCTAssertEqual(reopened.entries.first { $0.title == "Plain" }?.entryType, .login)
    }

    func testChangingTypeBackToLoginClearsMarker() async throws {
        let (loader, _) = try await makeVault(
            "Back.kdbx",
            kdf: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        )
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Router", entryType: .wifi))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Router" }?.id)
        let updated = try await loader.updateEntry(id: id, form: VaultEntryForm(title: "Router"))
        XCTAssertEqual(updated.entries.first { $0.id == id }?.entryType, .login)
    }

    func testKDBX3DoesNotSupportTypes() async throws {
        let (loader, _) = try await makeVault(
            "Old.kdbx",
            kdf: VaultDatabaseSettings(kdf: .aes, aesRounds: 1_000),
            cipher: .aes256
        )
        let vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail"))
        XCTAssertFalse(vault.summary.supportsEntryTypes)
    }

    func testTemplatesGroupIsStoredInMetadata() async throws {
        let (loader, url) = try await makeVault(
            "Templates.kdbx",
            kdf: VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        )
        let withGroup = try await loader.createGroup(inParentPath: nil, title: "Templates", iconID: nil)
        let path = try XCTUnwrap(withGroup.groups.first { $0.title == "Templates" }?.path)

        var settings = try await loader.databaseSettings()
        XCTAssertNil(settings.templatesGroupPath)
        settings.templatesGroupPath = path
        let updated = try await loader.updateDatabaseSettings(settings)
        XCTAssertEqual(updated.summary.templatesGroupPath, path)

        let reopened = try await KeePassKitVaultLoader().loadVault(from: url, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(reopened.summary.templatesGroupPath, path)

        settings.templatesGroupPath = nil
        let cleared = try await loader.updateDatabaseSettings(settings)
        XCTAssertNil(cleared.summary.templatesGroupPath)
    }
}
