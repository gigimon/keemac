@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

final class FieldReferenceTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "reference-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("Refs.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "Refs",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ title: String, in vault: LoadedVault) throws -> VaultEntry {
        try XCTUnwrap(vault.entries.first { $0.title == title })
    }

    func testReferencesAndPlaceholdersResolve() async throws {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let base = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Corporate", username: "anna", password: "s3cret-Pa55"))
        let source = try entry("Corporate", in: base)
        let compact = source.id.uuidString.replacingOccurrences(of: "-", with: "")

        var form = VaultEntryForm(title: "VPN")
        form.username = "{REF:U@I:\(compact)}"
        form.password = "{REF:P@I:\(source.id.uuidString)}"
        form.url = "https://vpn.example.com/?user={USERNAME}"
        form.notes = "Old: {REF:P@I:00000000000000000000000000000000}"
        let vault = try await loader.createEntry(inGroupPath: nil, form: form)
        let vpn = try entry("VPN", in: vault)

        XCTAssertEqual(vpn.username, "anna")
        XCTAssertEqual(vpn.password, "s3cret-Pa55")
        XCTAssertEqual(vpn.url?.absoluteString, "https://vpn.example.com/?user=anna")
        let references = try XCTUnwrap(vpn.references)
        XCTAssertEqual(references.sources[VaultEntryReferences.password], source.id)
        XCTAssertEqual(references.sources[VaultEntryReferences.username], source.id)
        XCTAssertNil(references.sources[VaultEntryReferences.url])
        XCTAssertTrue(references.brokenFields.contains(VaultEntryReferences.notes))
        XCTAssertNil(try entry("Corporate", in: vault).references)

        // The editor works on the stored text, so saving keeps the reference.
        let stored = VaultEntryForm(entry: vpn)
        XCTAssertEqual(stored.password, "{REF:P@I:\(source.id.uuidString)}")
        XCTAssertEqual(stored.url, "https://vpn.example.com/?user={USERNAME}")
        var renamed = stored
        renamed.title = "VPN Office"
        _ = try await loader.updateEntry(id: vpn.id, form: renamed)
        let updated = try await loader.updateEntry(id: source.id, form: VaultEntryForm(title: "Corporate", username: "anna", password: "n3w-Secret"))
        XCTAssertEqual(try entry("VPN Office", in: updated).password, "n3w-Secret")
    }

    func testDuplicateWithReferences() async throws {
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        let created = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna", password: "first-Pass1"))
        let original = try entry("Mail", in: created)

        let result = try await loader.duplicateEntry(id: original.id, referencingCredentials: true)
        let copy = try XCTUnwrap(result.vault.entries.first { $0.id == result.entryID })
        XCTAssertEqual(copy.username, "anna")
        XCTAssertEqual(copy.password, "first-Pass1")
        XCTAssertEqual(copy.references?.sources[VaultEntryReferences.password], original.id)

        let changed = try await loader.updateEntry(id: original.id, form: VaultEntryForm(title: "Mail", username: "anna.k", password: "second-Pass2"))
        let updatedCopy = try XCTUnwrap(changed.entries.first { $0.id == result.entryID })
        XCTAssertEqual(updatedCopy.username, "anna.k")
        XCTAssertEqual(updatedCopy.password, "second-Pass2")

        // A referenced password is checked through its source, not reported as reused.
        let report = DatabaseReport(vault: changed, rootPath: "", favoriteEntryIDs: [], expiringWithinDays: 30, oldAfterDays: 365)
        XCTAssertTrue(report.reused.isEmpty)
    }
}
