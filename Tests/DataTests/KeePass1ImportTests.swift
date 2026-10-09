@testable import Data
import Domain
import Foundation
import KeePassKit
import XCTest

final class KeePass1ImportTests: XCTestCase {
    private final class EditingDelegate: NSObject, KPKTreeDelegate {
        func shouldEdit(_ tree: KPKTree) -> Bool { true }
    }

    private let password = "kdb-password"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A KeePass 1 file as KeePass 1 writes it: entries live in groups, "Backup" is the trash.
    private func makeKeePass1Data(keyFileData: Data? = nil) throws -> Data {
        let tree = KPKTree()
        let delegate = EditingDelegate()
        tree.delegate = delegate
        let root = tree.createGroup(nil)
        root.title = "Root"
        tree.root = root

        let general = tree.createGroup(root)
        general.add(to: root)
        general.title = "General"
        let mail = tree.createEntry(general)
        mail.add(to: general)
        mail.title = "Mail"
        mail.username = "anna"
        mail.password = "secret"
        mail.url = "https://mail.example.com"
        mail.notes = "Main account"
        mail.addBinary(KPKBinary(name: "recovery.txt", data: Data("codes".utf8)))

        let servers = tree.createGroup(general)
        servers.add(to: general)
        servers.title = "Servers"
        let ssh = tree.createEntry(servers)
        ssh.add(to: servers)
        ssh.title = "SSH"
        ssh.username = "root"
        ssh.password = "toor"

        let backup = tree.createGroup(root)
        backup.add(to: root)
        backup.title = "Backup"
        let old = tree.createEntry(backup)
        old.add(to: backup)
        old.title = "Old Mail"

        var keys: [KPKKey] = [try XCTUnwrap(KPKPasswordKey(password: password))]
        if let keyFileData {
            keys.append(try XCTUnwrap(KPKFileKey(keyFileData: keyFileData)))
        }
        return try tree.encrypt(with: KPKCompositeKey(keys: keys), format: .kdb)
    }

    func testDetectsKeePass1AndAsksForThePassword() throws {
        let data = try makeKeePass1Data()
        XCTAssertTrue(VaultImporter.isKeePass1(data))
        XCTAssertThrowsError(try VaultImporter.read(data)) { error in
            XCTAssertEqual(error as? VaultImportError, .keePass1Locked)
        }
        XCTAssertThrowsError(try VaultImporter.read(Data("title,username\na,b".utf8), format: .keePass1)) { error in
            XCTAssertEqual(error as? VaultImportError, .unreadableKeePass1, "picking KeePass 1 for another file")
        }
    }

    func testWrongPasswordAndDamagedFile() throws {
        let data = try makeKeePass1Data()
        XCTAssertThrowsError(try VaultImporter.readKeePass1(data, password: "nope", keyFileData: nil)) { error in
            XCTAssertEqual(error as? VaultImportError, .wrongKey)
        }
        XCTAssertThrowsError(try VaultImporter.readKeePass1(data, password: "", keyFileData: nil)) { error in
            XCTAssertEqual(error as? VaultImportError, .wrongKey, "no key at all")
        }
        // The header is cut off: nothing to try a password against.
        XCTAssertThrowsError(try VaultImporter.readKeePass1(Data(data.prefix(60)), password: password, keyFileData: nil)) { error in
            XCTAssertEqual(error as? VaultImportError, .unreadableKeePass1)
        }
    }

    func testReadsEntriesWithoutTheBackupGroup() throws {
        let file = try VaultImporter.readKeePass1(try makeKeePass1Data(), password: password, keyFileData: nil)
        XCTAssertEqual(file.format, .keePass1)
        XCTAssertNotNil(file.xmlData)
        XCTAssertEqual(Set(file.items.map(\.title)), ["Mail", "SSH"])
        XCTAssertEqual(file.items.first { $0.title == "SSH" }?.folder, ["General", "Servers"])
    }

    func testKeyFile() throws {
        let keyFile = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let data = try makeKeePass1Data(keyFileData: keyFile)
        XCTAssertThrowsError(try VaultImporter.readKeePass1(data, password: password, keyFileData: nil)) { error in
            XCTAssertEqual(error as? VaultImportError, .wrongKey, "the key file is missing")
        }
        let file = try VaultImporter.readKeePass1(data, password: password, keyFileData: keyFile)
        XCTAssertEqual(file.items.count, 2)
    }

    func testImportKeepsGroupsAttachmentsAndNotes() async throws {
        let url = directory.appendingPathComponent("Main.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(fileURL: url, name: "Main", masterPassword: "pw", keyDerivation: fastKDF))
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: url, masterPassword: "pw", keyFileURL: nil)

        let file = try VaultImporter.readKeePass1(try makeKeePass1Data(), password: password, keyFileData: nil)
        let (vault, result) = try await loader.importEntries(file, options: VaultImportOptions(
            destination: .newGroup(title: "From KeePass 1"), keepsFolders: true, skipsDuplicates: true
        ))
        XCTAssertEqual(result.importedCount, 2)
        let mail = try XCTUnwrap(vault.entries.first { $0.title == "Mail" })
        XCTAssertTrue(mail.groupPath.hasSuffix("From KeePass 1.General"))
        XCTAssertEqual(mail.password, "secret")
        XCTAssertEqual(mail.notes, "Main account")
        XCTAssertEqual(mail.attachments.first?.data, Data("codes".utf8))
        XCTAssertTrue(vault.entries.first { $0.title == "SSH" }?.groupPath.hasSuffix("From KeePass 1.General.Servers") ?? false)
        XCTAssertFalse(vault.entries.contains { $0.title == "Old Mail" })
    }
}

