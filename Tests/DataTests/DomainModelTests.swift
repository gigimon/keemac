import Domain
import Foundation
import XCTest

final class VaultErrorTests: XCTestCase {
    func testDescriptions() {
        let expected: [(VaultError, String)] = [
            (.invalidPassword, "Master password is invalid, or this database requires an additional key file."),
            (.unsupportedKDBXVariant, "This KDBX version is not supported yet."),
            (.parseFailure(), "Could not parse the vault."),
            (.parseFailure(details: "bad XML"), "Could not parse the vault: bad XML"),
            (.fileReadFailure(), "Cannot read vault file."),
            (.fileReadFailure(path: "/tmp/a.kdbx"), "Cannot read vault file at path: /tmp/a.kdbx"),
            (.missingDependency(name: "KeePassKit"), "Required dependency is not configured: KeePassKit."),
            (.unknown(), "Unexpected vault error."),
            (.unknown(details: "boom"), "Unexpected vault error: boom")
        ]
        for (error, description) in expected {
            XCTAssertEqual(error.errorDescription, description)
            XCTAssertEqual((error as Error).localizedDescription, description)
        }
        XCTAssertEqual(VaultError.parseFailure(details: "a"), .parseFailure(details: "a"))
        XCTAssertNotEqual(VaultError.parseFailure(details: "a"), .parseFailure())
    }
}

final class VaultImportExportModelTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(VaultImportFormat.allCases.filter { !$0.isCSV }, [.keePass1, .keePassXML])
        XCTAssertEqual(VaultImportFormat.bitwarden.id, "bitwarden")
        XCTAssertEqual(VaultExportFormat.csv.fileExtension, "csv")
        XCTAssertEqual(VaultExportFormat.keePassXML.fileExtension, "xml")
    }

    func testDuplicateKeyIgnoresCaseAndSpacing() {
        let item = VaultImportItem(title: " GitHub ", username: "Anna", url: "https://github.com\n")
        XCTAssertEqual(item.duplicateKey, VaultImportItem.duplicateKey(title: "github", username: "anna ", url: "HTTPS://GITHUB.COM"))
        XCTAssertNotEqual(item.duplicateKey, VaultImportItem.duplicateKey(title: "GitHub", username: "", url: "annahttps://github.com"), "fields are kept apart")
        XCTAssertNotEqual(item.duplicateKey, VaultImportItem(title: "GitHub", username: "bob", url: "https://github.com").duplicateKey)
    }

    func testFolderCountUsesTopLevelFolders() {
        let file = VaultImportFile(format: .bitwarden, items: [
            VaultImportItem(title: "A", folder: ["Work", "Servers"]),
            VaultImportItem(title: "B", folder: ["Work"]),
            VaultImportItem(title: "C", folder: ["Home"]),
            VaultImportItem(title: "D")
        ])
        XCTAssertEqual(file.folderCount, 2)
        XCTAssertEqual(file.skippedLines, [])
        XCTAssertNil(file.xmlData)
    }
}

final class VaultSyncModelTests: XCTestCase {
    func testMergeSummaryCounts() {
        let a = UUID(), b = UUID(), c = UUID()
        let summary = VaultMergeSummary(changes: [
            VaultMergeChange(entryID: a, kind: .added, title: "A", groupPath: "Root"),
            VaultMergeChange(entryID: b, kind: .updated, title: "B", groupPath: "Root", changedFields: ["password"], isConflict: true),
            VaultMergeChange(entryID: c, kind: .deleted, title: "C", groupPath: "Root"),
            VaultMergeChange(entryID: b, kind: .moved, title: "B", groupPath: "Root.Work", previousGroupPath: "Root")
        ])
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.conflictCount, 1)
        XCTAssertEqual(summary.changedEntryIDs, [a, b], "deleted entries are not highlighted")
        XCTAssertEqual(summary.count(of: .added), 1)
        XCTAssertEqual(summary.count(of: .deleted), 1)
        XCTAssertEqual(summary.changes[1].id, "updated-\(b.uuidString)")
        XCTAssertTrue(VaultMergeSummary().isEmpty)
    }

    func testFingerprintCodableAndConflictCopyID() throws {
        let fingerprint = VaultFileFingerprint(sha256: "abc", size: 42)
        XCTAssertEqual(try JSONDecoder().decode(VaultFileFingerprint.self, from: JSONEncoder().encode(fingerprint)), fingerprint)

        let copy = VaultConflictCopy(fileURL: URL(fileURLWithPath: "/tmp/x/../Vault (conflict).kdbx"), provider: .dropbox, modifiedAt: nil)
        XCTAssertEqual(copy.id, "/tmp/Vault (conflict).kdbx")
        XCTAssertEqual(VaultConflictCopy.Provider.iCloud.rawValue, "iCloud")

        let source = VaultMergeSource(fileURL: URL(fileURLWithPath: "/tmp/a.kdbx"))
        XCTAssertNil(source.masterPassword)
        XCTAssertNil(source.keyFileURL)
    }
}

final class VaultModelTests: XCTestCase {
    func testFieldReferenceParsing() throws {
        let id = try XCTUnwrap(UUID(uuidString: "46C9B1FF-BD4A-BC4B-BB26-0C6190BAD20C"))
        let reference = try XCTUnwrap(VaultFieldReference("{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}"))
        XCTAssertEqual(reference, VaultFieldReference(field: .password, entryID: id))
        XCTAssertEqual(reference.text, "{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}")
        XCTAssertEqual(VaultFieldReference(" {ref:u@i:46c9b1ff-bd4a-bc4b-bb26-0c6190bad20c} "), VaultFieldReference(field: .username, entryID: id))

        for text in [
            "", "{REF:P@I:}", "{REF:P@T:Mail}", "{REF:X@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}",
            "{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20}", "{REF:P@I:ZZC9B1FFBD4ABC4BBB260C6190BAD20C}",
            "x{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}", "{REF:PI46C9B1FFBD4ABC4BBB260C6190BAD20C}"
        ] {
            XCTAssertNil(VaultFieldReference(text), text)
        }
        XCTAssertEqual(VaultFieldReference.Field.allCases.map(\.storedName), ["Title", "UserName", "Password", "URL", "Notes"])
    }

    func testEntryValuesAndRawValues() {
        let entry = VaultEntry(
            title: "Mail",
            username: "anna",
            url: URL(string: "https://mail.example.com"),
            references: VaultEntryReferences(rawValues: ["Password": "{REF:P@I:00}"], brokenFields: ["Password"])
        )
        XCTAssertEqual(entry.value(of: .title), "Mail")
        XCTAssertEqual(entry.value(of: .username), "anna")
        XCTAssertEqual(entry.value(of: .password), "")
        XCTAssertEqual(entry.value(of: .url), "https://mail.example.com")
        XCTAssertEqual(entry.value(of: .notes), "")
        XCTAssertEqual(entry.rawValue("Password"), "{REF:P@I:00}")
        XCTAssertNil(entry.rawValue("Title"))
        XCTAssertTrue(entry.references?.isReference("Password") == true, "a broken reference is still a reference")
        XCTAssertFalse(entry.references?.isReference("Title") == true)
        XCTAssertNil(VaultEntry(title: "Plain").rawValue("Password"))
    }

    func testReferencesFollowChains() {
        let source = VaultEntry(title: "Source")
        let middle = VaultEntry(title: "Middle", references: VaultEntryReferences(rawValues: [:], sources: ["Password": source.id]))
        let top = VaultEntry(title: "Top", references: VaultEntryReferences(rawValues: [:], sources: ["UserName": middle.id]))
        let loopA = UUID(), loopB = UUID()
        let a = VaultEntry(id: loopA, title: "A", references: VaultEntryReferences(rawValues: [:], sources: ["Password": loopB]))
        let b = VaultEntry(id: loopB, title: "B", references: VaultEntryReferences(rawValues: [:], sources: ["Password": loopA]))
        let all = [source, middle, top, a, b]

        XCTAssertTrue(top.references(source.id, in: all))
        XCTAssertTrue(top.references(middle.id, in: all))
        XCTAssertFalse(source.references(top.id, in: all))
        XCTAssertFalse(a.references(source.id, in: all), "reference loops end")
        XCTAssertTrue(a.references(loopA, in: all))
    }

    func testRelabelingKeepsContent() {
        let entry = VaultEntry(groupPath: "Root", usageCount: 4, title: "Mail", password: "pw", tags: ["x"], entryType: .card)
        let id = UUID()
        let relabeled = entry.relabeled(id: id, groupPath: "[Backup] Root", references: nil)
        XCTAssertEqual(relabeled.id, id)
        XCTAssertEqual(relabeled.groupPath, "[Backup] Root")
        XCTAssertEqual(relabeled, VaultEntry(id: id, groupPath: "[Backup] Root", usageCount: 4, title: "Mail", password: "pw", tags: ["x"], entryType: .card))

        let group = VaultGroup(title: "Work", path: "Root.Work", iconID: 3, isTrash: true)
        let moved = group.relabeled(id: id, path: "[Backup] Root.Work")
        XCTAssertEqual(moved, VaultGroup(id: id, title: "Work", path: "[Backup] Root.Work", iconID: 3, isTrash: true))
    }

    func testAttachmentAndFileInfo() {
        let attachment = VaultAttachment(name: "key.pem", data: Data(count: 10))
        XCTAssertEqual(attachment.id, "key.pem")
        XCTAssertEqual(attachment.size, 10)

        XCTAssertEqual(VaultFileInfo(majorVersion: 4, minorVersion: 1, cipher: .chacha20, kdf: .argon2id).summary, "KDBX 4.1 · Argon2id · ChaCha20")
        XCTAssertEqual(VaultFileInfo(majorVersion: 3, minorVersion: 1, cipher: nil, kdf: nil).summary, "KDBX 3.1")
        XCTAssertEqual(VaultKDFAlgorithm.allCases.map(\.displayName), ["Argon2d", "Argon2id", "AES-KDF"])
        XCTAssertEqual(VaultKDFAlgorithm.allCases.filter(\.isArgon), [.argon2d, .argon2id])
        XCTAssertEqual(VaultCipher.allCases.map(\.displayName), ["AES-256", "ChaCha20", "Twofish"])
        XCTAssertEqual(VaultUndoState.empty, VaultUndoState(undoAction: nil, redoAction: nil))
    }
}
