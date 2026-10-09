@testable import Data
import Domain
import Foundation
import XCTest

final class TrashTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "trash-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Trash.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Trash",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDeletingTrashedEntryRemovesIt() async throws {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Old" }?.id)

        vault = try await loader.deleteEntry(id: id)
        XCTAssertEqual(vault.entries.first { $0.id == id }?.isTrashed, true)

        vault = try await loader.deleteEntry(id: id)
        XCTAssertNil(vault.entries.first { $0.id == id }, "deleting from the trash removes the entry")

        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertNil(reopened.entries.first { $0.id == id })
    }
}

extension TrashTests {
    func testEmptiedTrashStaysEmptyAfterMergeWithAnotherDevice() async throws {
        let mac = KeePassKitVaultLoader()
        _ = try await mac.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        var vault = try await mac.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old"))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Old" }?.id)
        vault = try await mac.deleteEntry(id: id)

        let phone = KeePassKitVaultLoader()
        _ = try await phone.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)

        // KDBX keeps seconds; the deletion has to be newer than the move to the trash to win the merge.
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await mac.deleteEntry(id: id)
        _ = try await phone.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "From Phone"))

        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        XCTAssertTrue(reopened.entries.contains { $0.title == "From Phone" })
        XCTAssertNil(reopened.entries.first { $0.id == id }, "the other device's copy in the trash doesn't come back")
    }
}
