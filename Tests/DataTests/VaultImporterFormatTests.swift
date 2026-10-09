@testable import Data
import Domain
import Foundation
import XCTest

final class VaultImporterFormatTests: XCTestCase {
    private func read(_ csv: String, format: VaultImportFormat? = nil) throws -> VaultImportFile {
        try VaultImporter.read(Data(csv.utf8), format: format)
    }

    private func assertError(_ expected: VaultImportError, _ expression: @autoclosure () throws -> VaultImportFile, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { XCTAssertEqual($0 as? VaultImportError, expected, line: line) }
    }

    func testOnePasswordVariants() throws {
        let website = try read("Title,Website,Username,Password,Notes,Tags\nGitHub,https://github.com,anna,pw,My notes,\"work, dev ,\"\n")
        XCTAssertEqual(website.format, .onePassword)
        let item = try XCTUnwrap(website.items.first)
        XCTAssertEqual(item.url, "https://github.com")
        XCTAssertEqual(item.notes, "My notes")
        XCTAssertEqual(item.tags, ["work", "dev"])

        let plain = try read("title,url,username,password,notesPlain,otpauth\nBank,https://bank.example,me,pw,PIN 1234,otpauth://totp/x?secret=AAA\n")
        XCTAssertEqual(plain.format, .onePassword)
        XCTAssertEqual(plain.items.first?.notes, "PIN 1234")
        XCTAssertEqual(plain.items.first?.otp, "otpauth://totp/x?secret=AAA")
    }

    func testSafariAndChrome() throws {
        let safari = try read("Title,URL,Username,Password,Notes,OTPAuth\nMail,https://mail.example.com,anna,pw,n,otpauth://totp/m?secret=BBB\n")
        XCTAssertEqual(safari.format, .safari)
        XCTAssertEqual(safari.items, [VaultImportItem(title: "Mail", username: "anna", password: "pw", url: "https://mail.example.com", notes: "n", otp: "otpauth://totp/m?secret=BBB")])

        let chrome = try read("name,url,username,password,note\nForum,https://forum.example,bob,pw,hello\n")
        XCTAssertEqual(chrome.format, .chrome)
        XCTAssertEqual(chrome.items.first?.notes, "hello")
    }

    func testMissingTitlesAreFilledIn() throws {
        let file = try read("""
        name,url,username,password,note
        ,https://www.site.example/login,,pw,
        ,https://shop.example,,pw,
        ,,anna,pw,
        ,,,pw,
        ,,,,just a note
        ,not a url,,,
        """)
        XCTAssertEqual(file.items.map(\.title), ["site.example", "shop.example", "anna", "Untitled", "Untitled"])
        XCTAssertEqual(file.skippedLines, [7], "a row with nothing worth keeping is skipped")
    }

    func testFirefoxSkipsBrowserInternalLogins() throws {
        let file = try read("url,username,password,httpRealm,formActionOrigin,guid\nchrome://FirefoxAccounts,me,pw,,,{1}\nhttps://example.com,me,pw,,,{2}\n")
        XCTAssertEqual(file.format, .firefox)
        XCTAssertEqual(file.items.map(\.title), ["example.com"])
        XCTAssertEqual(file.skippedLines, [2])
    }

    func testBitwardenDetails() throws {
        let csv = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        ,,login,Multi,,"no colon here
        : empty key
        Answer : 42",0,"https://a.example,https://b.example",anna,pw,
        ,,identity,Me,,,0,,,,
        ,,,Untyped,,,0,https://c.example,u,p,
        """
        let file = try read(csv)
        XCTAssertEqual(file.items.map(\.title), ["Multi", "Untyped"])
        XCTAssertEqual(file.items.first?.url, "https://a.example")
        XCTAssertEqual(file.items.first?.customFields, [VaultCustomField(key: "Answer", value: "42", isProtected: false)])
        XCTAssertEqual(file.items.first?.folder, [])
        XCTAssertEqual(file.skippedLines, [5], "identities aren't imported")
    }

    func testExplicitFormats() throws {
        XCTAssertEqual(try read("name,url,username,password\nA,https://a.example,u,p\n", format: .chrome).items.count, 1)
        assertError(.formatMismatch, try self.read("just one column\nvalue\n", format: .chrome))
        assertError(.unreadable, try self.read("just one column\nvalue\n"))
        assertError(.unreadable, try self.read("", format: nil))
        assertError(.unreadable, try self.read("name,url,username,password\n", format: .keePassXML))
        assertError(.unreadableKeePass1, try self.read("name,url\n", format: .keePass1))
        assertError(.keePass1Locked, try VaultImporter.read(Data([0x03, 0xD9, 0xA2, 0x9A, 0x65, 0xFB, 0x4B, 0xB5, 0, 0])))
        assertError(.unreadable, try VaultImporter.read(Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5]) + Data("a,b\n1,2\n".utf8)))
        XCTAssertTrue(VaultImporter.isKeePass1(Data([0x03, 0xD9, 0xA2, 0x9A, 0x65, 0xFB, 0x4B, 0xB5])))
        XCTAssertFalse(VaultImporter.isKeePass1(Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])))
    }

    func testTextEncodings() throws {
        let text = "name,url,username,password\nCafé,https://cafe.example,anna,pw\n"
        let utf16 = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(try VaultImporter.read(utf16).items.first?.title, "Café")

        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        XCTAssertEqual(try VaultImporter.read(bom).format, .chrome)

        let windows = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertNil(String(data: windows, encoding: .utf8))
        XCTAssertEqual(try VaultImporter.read(windows).items.first?.title, "Café")
    }

    func testKeePassXMLFoldersAndOTP() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <KeePassFile>
          <Meta><Generator>KeeMacTests</Generator></Meta>
          <Root>
            <Group>
              <UUID>EBESExQVFhcYGRobHB0eHw==</UUID>
              <Name>Root</Name>
              <Entry>
                <UUID>ICEiIyQlJicoKSorLC0uLw==</UUID>
                <String><Key>Title</Key><Value>Top</Value></String>
              </Entry>
              <Group>
                <UUID>MDEyMzQ1Njc4OTo7PD0+Pw==</UUID>
                <Name>Work</Name>
                <Entry>
                  <UUID>QEFCQ0RFRkdISUpLTE1OTw==</UUID>
                  <String><Key>Title</Key><Value>Mail</Value></String>
                  <String><Key>UserName</Key><Value>anna</Value></String>
                  <String><Key>Password</Key><Value>pw</Value></String>
                  <String><Key>URL</Key><Value>https://mail.example.com</Value></String>
                  <String><Key>Notes</Key><Value>n</Value></String>
                  <String><Key>otp</Key><Value>otpauth://totp/m?secret=CCC</Value></String>
                </Entry>
              </Group>
            </Group>
          </Root>
        </KeePassFile>
        """
        let file = try VaultImporter.read(Data(xml.utf8))
        XCTAssertEqual(file.format, .keePassXML)
        XCTAssertNotNil(file.xmlData)
        let byTitle = Dictionary(uniqueKeysWithValues: file.items.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Top"]?.folder, [])
        XCTAssertEqual(byTitle["Mail"], VaultImportItem(
            title: "Mail",
            username: "anna",
            password: "pw",
            url: "https://mail.example.com",
            notes: "n",
            otp: "otpauth://totp/m?secret=CCC",
            folder: ["Work"]
        ))
    }
}
