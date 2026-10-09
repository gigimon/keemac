@testable import Data
@testable import UI
import Domain
import Foundation
import XCTest

final class FieldReferenceBuilderTests: XCTestCase {
    func testParsesAndWritesReferences() throws {
        let id = UUID()
        let reference = VaultFieldReference(field: .password, entryID: id)
        XCTAssertEqual(reference.text, "{REF:P@I:\(id.uuidString.replacingOccurrences(of: "-", with: ""))}")
        XCTAssertEqual(VaultFieldReference(reference.text), reference)
        XCTAssertEqual(VaultFieldReference("{ref:a@i:\(id.uuidString.lowercased())}"), VaultFieldReference(field: .url, entryID: id), "dashes and lowercase are accepted")
        XCTAssertNil(VaultFieldReference("{REF:P@T:Google}"), "only references by UUID")
        XCTAssertNil(VaultFieldReference("x{REF:P@I:\(id.uuidString)}"), "the whole value must be the reference")
        XCTAssertNil(VaultFieldReference("{USERNAME}"))
    }

    func testDetectsLinksBack() {
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [
            VaultEntry(id: a, groupPath: "Root", title: "A"),
            VaultEntry(id: b, groupPath: "Root", title: "B", references: VaultEntryReferences(rawValues: ["Password": "…"], sources: ["Password": a])),
            VaultEntry(id: c, groupPath: "Root", title: "C", references: VaultEntryReferences(rawValues: ["UserName": "…"], sources: ["UserName": b]))
        ]
        XCTAssertTrue(entries[1].references(a, in: entries))
        XCTAssertTrue(entries[2].references(a, in: entries), "through B")
        XCTAssertFalse(entries[0].references(c, in: entries))
    }

    func testInsertedReferenceResolvesAfterSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Refs.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let loader = KeePassKitVaultLoader()
        _ = try await loader.createVault(options: VaultCreationOptions(fileURL: url, name: "Refs", masterPassword: "pw", keyDerivation: kdf))
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Google", username: "anna", password: "sso-secret"))
        let google = try XCTUnwrap(vault.entries.first { $0.title == "Google" })
        vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Jira", username: "anna", password: "old"))
        let jira = try XCTUnwrap(vault.entries.first { $0.title == "Jira" })

        var form = VaultEntryForm(entry: jira)
        form.password = VaultFieldReference(field: .password, entryID: google.id).text
        vault = try await loader.updateEntry(id: jira.id, form: form)

        let linked = try XCTUnwrap(vault.entries.first { $0.id == jira.id })
        XCTAssertEqual(linked.password, "sso-secret")
        XCTAssertEqual(linked.references?.sources[VaultEntryReferences.password], google.id)
        XCTAssertEqual(VaultEntryForm(entry: linked).password, form.password, "the editor gets the reference back")
    }
}
