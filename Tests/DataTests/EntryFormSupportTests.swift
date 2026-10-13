import Domain
import Foundation
@testable import UI
import XCTest

final class EntryFormValidationTests: XCTestCase {
    func testValidFormPasses() {
        var form = VaultEntryForm(title: "Mail")
        form.customFields = [VaultCustomFieldForm(key: "PIN", value: "", isProtected: true)]
        form.otp = VaultOTPForm(secret: "JBSWY3DPEHPK3PXP", digits: 9, period: 1)
        XCTAssertNil(EntryFormValidation.validate(form))
    }

    func testTitleIsRequired() {
        XCTAssertEqual(EntryFormValidation.validate(VaultEntryForm(title: " \n")), "Title is required.")
    }

    func testCustomFieldNames() {
        var form = VaultEntryForm(title: "Mail")
        form.customFields = [VaultCustomFieldForm(key: "  ", value: "x", isProtected: false)]
        XCTAssertEqual(EntryFormValidation.validate(form), "Custom field name cannot be empty.")

        form.customFields = [
            VaultCustomFieldForm(key: "Recovery", value: "1", isProtected: false),
            VaultCustomFieldForm(key: " recovery ", value: "2", isProtected: false)
        ]
        XCTAssertEqual(EntryFormValidation.validate(form), "Custom field names must be unique.", "names are compared trimmed and case-insensitively")
    }

    func testOTPSettings() {
        var form = VaultEntryForm(title: "Mail")
        form.otp = VaultOTPForm(secret: " ")
        XCTAssertEqual(EntryFormValidation.validate(form), "One-time password secret is required.")
        form.otp = VaultOTPForm(secret: "ABC", digits: 5)
        XCTAssertEqual(EntryFormValidation.validate(form), "TOTP digits must be between 6 and 9.")
        form.otp = VaultOTPForm(secret: "ABC", digits: 10)
        XCTAssertEqual(EntryFormValidation.validate(form), "TOTP digits must be between 6 and 9.")
        form.otp = VaultOTPForm(secret: "ABC", digits: 6, period: 0)
        XCTAssertEqual(EntryFormValidation.validate(form), "TOTP period must be positive.")
    }

    func testParseTags() {
        XCTAssertEqual(EntryFormValidation.parseTags("work, Mail;personal ,, ;WORK"), ["work", "Mail", "personal"])
        XCTAssertEqual(EntryFormValidation.parseTags(""), [])
        XCTAssertEqual(EntryFormValidation.parseTags(" ; , "), [])
        XCTAssertEqual(EntryFormValidation.parseTags("two words, x"), ["two words", "x"])
    }
}

final class OTPInputParserTests: XCTestCase {
    func testBlankInputClearsOTP() {
        XCTAssertNil(OTPInputParser.apply("  \n", to: VaultOTPForm(secret: "OLD")))
    }

    func testRawSecretKeepsOtherSettings() {
        let existing = VaultOTPForm(secret: "OLD", digits: 8, period: 60, algorithm: .sha256, storageStyle: .native)
        let result = OTPInputParser.apply("  JBSWY3DPEHPK3PXP ", to: existing)
        XCTAssertEqual(result, VaultOTPForm(secret: "JBSWY3DPEHPK3PXP", digits: 8, period: 60, algorithm: .sha256, storageStyle: .native))
        XCTAssertEqual(OTPInputParser.apply("ABC", to: nil), VaultOTPForm(secret: "ABC"))
    }

    func testOTPAuthURI() {
        let uri = "otpauth://totp/Example:anna@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA512&digits=8&period=60"
        XCTAssertEqual(
            OTPInputParser.apply(uri, to: nil),
            VaultOTPForm(secret: "JBSWY3DPEHPK3PXP", digits: 8, period: 60, algorithm: .sha512)
        )
        let sha256 = OTPInputParser.apply("OTPAUTH://totp/x?SECRET=AAA&Algorithm=sha256", to: nil)
        XCTAssertEqual(sha256?.secret, "AAA", "parameter names are case-insensitive")
        XCTAssertEqual(sha256?.algorithm, .sha256)

        let back = OTPInputParser.apply("otpauth://totp/x?secret=BBB&algorithm=SHA1&digits=abc", to: VaultOTPForm(secret: "", digits: 7, algorithm: .sha512))
        XCTAssertEqual(back?.algorithm, .sha1)
        XCTAssertEqual(back?.digits, 7, "unreadable numbers keep the current value")

        let unknown = OTPInputParser.apply("otpauth://totp/x?secret=CCC&algorithm=MD5", to: VaultOTPForm(secret: "", algorithm: .sha256))
        XCTAssertEqual(unknown?.algorithm, .sha256)
        XCTAssertEqual(OTPInputParser.apply("otpauth://totp/x?issuer=Example", to: nil)?.secret, "", "a URI without a secret leaves it empty for validation")
        XCTAssertEqual(OTPInputParser.apply("otpauth://totp/x?secret=FIRST&secret=SECOND", to: nil)?.secret, "FIRST")
    }
}

final class GroupPathFormatterTests: XCTestCase {
    func testDisplayAndComponents() {
        XCTAssertEqual(GroupPathFormatter.display("Root.Work.Servers", rootPath: "Root"), "Work › Servers")
        XCTAssertEqual(GroupPathFormatter.display("Root", rootPath: "Root"), "Root")
        XCTAssertEqual(GroupPathFormatter.display("", rootPath: "Root"), "Root")
        XCTAssertEqual(GroupPathFormatter.relativeComponents("Root.Work", rootPath: "Root"), ["Work"])
        XCTAssertEqual(GroupPathFormatter.relativeComponents("Rooted.Work", rootPath: "Root"), ["Rooted", "Work"], "only a whole root component is stripped")
        XCTAssertEqual(GroupPathFormatter.relativeComponents("Other.Work", rootPath: ""), ["Other", "Work"])
    }

    func testTitleAndDepth() {
        XCTAssertEqual(GroupPathFormatter.title(of: "Root.Work.Servers"), "Servers")
        XCTAssertEqual(GroupPathFormatter.title(of: "Root"), "Root")
        XCTAssertEqual(GroupPathFormatter.title(of: ""), "")
        XCTAssertEqual(GroupPathFormatter.depth(of: "Root", rootPath: "Root"), 0)
        XCTAssertEqual(GroupPathFormatter.depth(of: "Root.Work", rootPath: "Root"), 0)
        XCTAssertEqual(GroupPathFormatter.depth(of: "Root.Work.Servers.Linux", rootPath: "Root"), 2)
    }
}

final class RelativeDateFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(hours: Double) -> String {
        RelativeDateFormatter.modified(now.addingTimeInterval(-hours * 3600), now: now)
    }

    func testModified() {
        XCTAssertEqual(RelativeDateFormatter.modified(nil, now: now), "unknown")
        XCTAssertEqual(ago(hours: 0.5), "just now")
        XCTAssertEqual(ago(hours: -5), "just now", "dates in the future read as now")
        XCTAssertEqual(ago(hours: 1), "1 hour ago")
        XCTAssertEqual(ago(hours: 23.9), "23 hours ago")
        XCTAssertEqual(ago(hours: 24), "yesterday")
        XCTAssertEqual(ago(hours: 47), "yesterday")
        XCTAssertEqual(ago(hours: 48), "2 days ago")
        XCTAssertEqual(ago(hours: 24 * 10 + 13), "11 days ago", "days are rounded")
    }

    func testAbsolute() {
        XCTAssertEqual(RelativeDateFormatter.absolute(nil), "unknown")
        XCTAssertEqual(RelativeDateFormatter.absolute(now), now.formatted(date: .abbreviated, time: .omitted))
    }
}

final class EntryFormFromEntryTests: XCTestCase {
    func testFormKeepsStoredReferencesAndEncodesOTP() {
        let source = UUID()
        let reference = "{REF:P@I:\(source.uuidString.replacingOccurrences(of: "-", with: ""))}"
        let entry = VaultEntry(
            title: "Mail",
            username: "anna",
            password: "resolved",
            url: URL(string: "https://mail.example.com"),
            notes: "n",
            tags: ["a"],
            foregroundColorHex: "#FF0000",
            customFields: [
                VaultCustomField(key: "PIN", value: "1234", isProtected: true),
                VaultCustomField(key: "Copy", value: "resolved", isProtected: false)
            ],
            iconID: 7,
            otp: VaultOTPConfiguration(secret: Data("foobar".utf8), digits: 8, period: 60, timeBase: 0, algorithm: .sha256),
            entryType: .card,
            templateName: "Visa",
            references: VaultEntryReferences(
                rawValues: [VaultEntryReferences.password: reference, "Copy": "{USERNAME}"],
                sources: [VaultEntryReferences.password: source]
            )
        )
        let form = VaultEntryForm(entry: entry)
        XCTAssertEqual(form.title, "Mail")
        XCTAssertEqual(form.username, "anna")
        XCTAssertEqual(form.password, reference)
        XCTAssertEqual(form.url, "https://mail.example.com")
        XCTAssertEqual(form.customFields.map(\.value), ["1234", "{USERNAME}"])
        XCTAssertEqual(form.customFields.map(\.isProtected), [true, false])
        XCTAssertEqual(form.otp, VaultOTPForm(secret: "MZXW6YTBOI", digits: 8, period: 60, algorithm: .sha256, storageStyle: .otpAuth))
        XCTAssertEqual(form.entryType, .card)
        XCTAssertEqual(form.templateName, "Visa")
        XCTAssertEqual(form.iconID, 7)
        XCTAssertEqual(form.foregroundColorHex, "#FF0000")

        let plain = VaultEntryForm(entry: VaultEntry(title: "Empty"))
        XCTAssertEqual(plain.username, "")
        XCTAssertEqual(plain.url, "")
        XCTAssertNil(plain.otp)
    }
}
