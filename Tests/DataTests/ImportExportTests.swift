@testable import Data
@testable import UI
import Domain
import Foundation
import XCTest

final class CSVReaderTests: XCTestCase {
    func testQuotesCommasAndLineBreaks() {
        let text = "a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"line1\nline2\"\n1,,3\n"
        let rows = CSVReader.rows(in: text)
        XCTAssertEqual(rows.map(\.fields), [["a", "b", "c"], ["x, y", "say \"hi\"", "line1\nline2"], ["1", "", "3"]])
        XCTAssertEqual(rows.map(\.line), [1, 2, 4])
        XCTAssertEqual(CSVReader.line(["a\"b", "c,d"]), "\"a\"\"b\",\"c,d\"")
    }
}

final class VaultImporterTests: XCTestCase {
    private func read(_ csv: String, format: VaultImportFormat? = nil) throws -> VaultImportFile {
        try VaultImporter.read(Data(csv.utf8), format: format)
    }

    func testDetectsEveryCSVFormat() throws {
        let headers: [(String, VaultImportFormat)] = [
            ("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp", .bitwarden),
            ("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes", .onePassword),
            ("name,url,username,password,note", .chrome),
            ("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\",\"timeCreated\",\"timeLastUsed\",\"timePasswordChanged\"", .firefox),
            ("Title,URL,Username,Password,Notes,OTPAuth", .safari),
            ("url,username,password,totp,extra,name,grouping,fav", .lastPass),
            ("\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\",\"Icon\",\"Last Modified\",\"Created\"", .keePassXC)
        ]
        for (header, format) in headers {
            XCTAssertEqual(try read("\u{FEFF}" + header + "\n").format, format, header)
        }
    }

    func testBitwarden() throws {
        let csv = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work/Servers,,login,GitHub,My notes,"PIN: 1234
        Recovery: abc",0,https://github.com,anna,s3cret,JBSWY3DPEHPK3PXP
        ,,note,Wi-Fi codes,Guest 1234,,0,,,,
        ,,card,Visa,,,0,,,,
        """
        let file = try read(csv)
        XCTAssertEqual(file.items.count, 2)
        XCTAssertEqual(file.skippedLines, [5], "cards aren't imported from CSV")
        let github = file.items[0]
        XCTAssertEqual(github.title, "GitHub")
        XCTAssertEqual(github.folder, ["Work", "Servers"])
        XCTAssertEqual(github.customFields.map(\.key), ["PIN", "Recovery"])
        XCTAssertEqual(github.otp, "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(file.items[1].isSecureNote)
    }

    func testLastPassFirefoxAndKeePassXC() throws {
        let lastPass = try read("url,username,password,totp,extra,name,grouping,fav\nhttp://sn,,,,Note body,Alarm code,Home\\Codes,0\n")
        XCTAssertEqual(lastPass.items.first?.isSecureNote, true)
        XCTAssertEqual(lastPass.items.first?.folder, ["Home", "Codes"])
        XCTAssertEqual(lastPass.items.first?.url, "")

        let firefox = try read("url,username,password,httpRealm,formActionOrigin,guid\nhttps://www.example.com,anna,pw,,https://www.example.com,{1}\n")
        XCTAssertEqual(firefox.items.first?.title, "example.com")

        let keePassXC = try read("Group,Title,Username,Password,URL,Notes,TOTP\nRoot/Work,Mail,anna,pw,https://mail.example.com,,\n")
        XCTAssertEqual(keePassXC.items.first?.folder, ["Work"])
    }

    func testErrors() {
        XCTAssertThrowsError(try read("foo,bar\n1,2\n")) { XCTAssertEqual($0 as? VaultImportError, .unrecognizedCSV) }
        XCTAssertThrowsError(try VaultImporter.read(Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB]))) { XCTAssertEqual($0 as? VaultImportError, .unreadable) }
        XCTAssertThrowsError(try read("name,url,username,password\n", format: .bitwarden)) { XCTAssertEqual($0 as? VaultImportError, .formatMismatch) }
        XCTAssertThrowsError(try VaultImporter.read(Data("<?xml version=\"1.0\"?><nonsense".utf8))) { XCTAssertEqual($0 as? VaultImportError, .unreadable) }
    }

    func testDamagedRowsAreSkippedWithLineNumbers() throws {
        let file = try read("name,url,username,password\nA,https://a.com,u,p\nbroken\n\nB,https://b.com,u,p\n")
        XCTAssertEqual(file.items.map(\.title), ["A", "B"])
        XCTAssertEqual(file.skippedLines, [3])
    }
}

final class VaultTransferTests: XCTestCase {
    private var directory: URL!
    private let password = "transfer-test"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVault(_ name: String) async throws -> (KeePassKitVaultLoader, URL) {
        let url = directory.appendingPathComponent("\(name).kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(fileURL: url, name: name, masterPassword: password, keyDerivation: fastKDF))
        let loader = KeePassKitVaultLoader()
        _ = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        return (loader, url)
    }

    func testImportCSVWithFoldersDuplicatesAndUndo() async throws {
        let (loader, _) = try await makeVault("Main")
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "GitHub", username: "anna", url: "https://github.com"))
        let file = try VaultImporter.read(Data("""
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,,login,GitHub,,,0,https://github.com,anna,pw,
        Work,,login,Figma,,,0,https://figma.com,anna,pw2,JBSWY3DPEHPK3PXP
        ,,login,Netflix,,,0,https://netflix.com,anna,pw3,
        """.utf8))

        let (vault, result) = try await loader.importEntries(file, options: VaultImportOptions(
            destination: .newGroup(title: "Imported from Bitwarden"), keepsFolders: true, skipsDuplicates: true
        ))
        XCTAssertEqual(result.importedCount, 2, "GitHub already exists")
        let figma = try XCTUnwrap(vault.entries.first { $0.title == "Figma" })
        XCTAssertTrue(figma.groupPath.hasSuffix("Imported from Bitwarden.Work"))
        XCTAssertNotNil(figma.otp, "the Base32 secret becomes a working TOTP")
        XCTAssertTrue(vault.entries.first { $0.title == "Netflix" }?.groupPath.hasSuffix("Imported from Bitwarden") ?? false)
        let state = await loader.undoState()
        XCTAssertEqual(state.undoAction, .importEntries)

        let undone = try await loader.undo()
        XCTAssertFalse(undone.entries.contains { $0.title == "Figma" })
        XCTAssertFalse(undone.groups.contains { $0.title == "Imported from Bitwarden" })
    }

    func testXMLExportRoundTripKeepsHistoryAndAttachments() async throws {
        let (source, _) = try await makeVault("Source")
        var vault = try await source.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "Server", username: "root", password: "old",
            attachments: [VaultAttachment(name: "id_rsa.pub", data: Data("ssh-ed25519 AAAA".utf8), isProtected: false)]
        ))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Server" }?.id)
        vault = try await source.updateEntry(id: id, form: VaultEntryForm(
            title: "Server", username: "root", password: "new",
            attachments: [VaultAttachment(name: "id_rsa.pub", data: Data("ssh-ed25519 AAAA".utf8), isProtected: false)]
        ))
        let export = try await source.exportDatabase(VaultExportOptions(format: .keePassXML, groupPath: nil, includesTrash: false, includesHistory: true, includesAttachments: true))
        XCTAssertEqual(export.entryCount, 1)

        let file = try VaultImporter.read(export.data)
        XCTAssertEqual(file.format, .keePassXML)
        let (target, _) = try await makeVault("Target")
        let (imported, _) = try await target.importEntries(file, options: VaultImportOptions(destination: .newGroup(title: "From XML"), keepsFolders: true, skipsDuplicates: true))
        let server = try XCTUnwrap(imported.entries.first { $0.title == "Server" })
        XCTAssertEqual(server.password, "new")
        XCTAssertEqual(server.history.count, 1)
        XCTAssertEqual(server.attachments.first?.data, Data("ssh-ed25519 AAAA".utf8))

        let plain = try await source.exportDatabase(VaultExportOptions(format: .keePassXML, groupPath: nil, includesTrash: false, includesHistory: false, includesAttachments: false))
        let stripped = try VaultImporter.read(plain.data)
        let (other, _) = try await makeVault("Other")
        let (otherVault, _) = try await other.importEntries(stripped, options: VaultImportOptions(destination: .newGroup(title: "Plain"), keepsFolders: true, skipsDuplicates: true))
        let plainServer = try XCTUnwrap(otherVault.entries.first { $0.title == "Server" })
        XCTAssertTrue(plainServer.history.isEmpty)
        XCTAssertTrue(plainServer.attachments.isEmpty)
    }

    func testCSVExportScopeTrashAndRoundTrip() async throws {
        let (loader, _) = try await makeVault("Main")
        var vault = try await loader.createGroup(inParentPath: nil, title: "Work", iconID: nil)
        let workPath = try XCTUnwrap(vault.groups.first { $0.title == "Work" }?.path)
        _ = try await loader.createEntry(inGroupPath: workPath, form: VaultEntryForm(title: "Jira, \"cloud\"", username: "anna", password: "pw", url: "https://jira.example.com"))
        vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Old", password: "x"))
        let oldID = try XCTUnwrap(vault.entries.first { $0.title == "Old" }?.id)
        _ = try await loader.deleteEntry(id: oldID)

        let all = try await loader.exportDatabase(VaultExportOptions(format: .csv, groupPath: nil, includesTrash: false, includesHistory: false, includesAttachments: false))
        XCTAssertEqual(all.entryCount, 1)
        let text = String(decoding: all.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\"Group\",\"Title\",\"Username\",\"Password\",\"URL\""))
        XCTAssertTrue(text.contains("\"Jira, \"\"cloud\"\"\""))

        let withTrash = try await loader.exportDatabase(VaultExportOptions(format: .csv, groupPath: nil, includesTrash: true, includesHistory: false, includesAttachments: false))
        XCTAssertEqual(withTrash.entryCount, 2)

        let scoped = try await loader.exportDatabase(VaultExportOptions(format: .keePassXML, groupPath: workPath, includesTrash: false, includesHistory: true, includesAttachments: true))
        XCTAssertEqual(scoped.entryCount, 1)
        XCTAssertEqual(try VaultImporter.read(scoped.data).items.map(\.title), ["Jira, \"cloud\""])

        let back = try VaultImporter.read(all.data)
        XCTAssertEqual(back.format, .keePassXC)
        XCTAssertEqual(back.items.first?.title, "Jira, \"cloud\"")
        XCTAssertEqual(back.items.first?.folder, ["Work"])
    }

    func testVerifyMasterKey() async throws {
        let (loader, _) = try await makeVault("Main")
        let right = await loader.verifyMasterKey(password: password, keyFileURL: nil)
        let wrong = await loader.verifyMasterKey(password: "nope", keyFileURL: nil)
        let empty = await loader.verifyMasterKey(password: "", keyFileURL: nil)
        XCTAssertTrue(right)
        XCTAssertFalse(wrong)
        XCTAssertFalse(empty)
    }
}

final class ImportPlanTests: XCTestCase {
    func testCountsMatchWhatTheLoaderImports() {
        let file = VaultImportFile(format: .chrome, items: [
            VaultImportItem(title: "Mail", username: "anna", password: "pw", url: "https://mail.com"),
            VaultImportItem(title: "Mail", username: "anna", password: "pw", url: "https://mail.com"),
            VaultImportItem(title: "Bank", username: "anna", url: "https://bank.com", otp: "JBSWY3DPEHPK3PXP"),
            VaultImportItem(title: "GitHub", username: "anna", password: "pw", url: "https://github.com")
        ])
        let existing = [VaultEntry(id: UUID(), groupPath: "Root", title: "GitHub", username: "anna", url: URL(string: "https://github.com"))]

        let skipping = ImportPlan(file: file, existing: existing, skipsDuplicates: true)
        XCTAssertEqual(skipping.newCount, 2)
        XCTAssertEqual(skipping.duplicates, 2, "the repeated Mail and the existing GitHub")
        XCTAssertEqual(skipping.withoutPassword, 1)
        XCTAssertEqual(skipping.withTOTP, 1)

        let all = ImportPlan(file: file, existing: existing, skipsDuplicates: false)
        XCTAssertEqual(all.newCount, 4)
    }
}
