@testable import Data
import Domain
import Foundation
import XCTest

final class DuplicateEntryTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "duplicate-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Personal.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Personal",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDuplicateCopiesFieldsWithNewIDAndNoHistory() async throws {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "GitHub",
            username: "anna",
            password: "first",
            url: "https://github.com",
            notes: "Recovery codes",
            customFields: [VaultCustomFieldForm(key: "Team", value: "Platform", isProtected: false)]
        ))
        let original = try XCTUnwrap(created.entries.first { $0.title == "GitHub" })
        _ = try await loader.updateEntry(id: original.id, form: VaultEntryForm(title: "GitHub", username: "anna", password: "second"))

        let result = try await loader.duplicateEntry(id: original.id)
        let copy = try XCTUnwrap(result.vault.entries.first { $0.id == result.entryID })
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.title, "GitHub copy")
        XCTAssertEqual(copy.username, "anna")
        XCTAssertEqual(copy.password, "second")
        XCTAssertEqual(copy.groupPath, original.groupPath)
        XCTAssertTrue(copy.history.isEmpty)

        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertEqual(reopened.entries.filter { $0.title.hasPrefix("GitHub") }.count, 2)
    }

    func testTrashedEntryCannotBeDuplicated() async throws {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old"))
        let entry = try XCTUnwrap(created.entries.first { $0.title == "Old" })
        _ = try await loader.deleteEntry(id: entry.id)
        do {
            _ = try await loader.duplicateEntry(id: entry.id)
            XCTFail("A trashed entry must not be duplicated")
        } catch {}
    }
}
