import AppKit
import Data
import Domain
import Foundation
import SwiftUI
@testable import UI
import XCTest

final class CardNumberTests: XCTestCase {
    func testDigitsAndBrand() {
        XCTAssertEqual(CardNumber.digits("4111 1111-1111 1111"), "4111111111111111")
        XCTAssertEqual(CardNumber.digits(String(repeating: "1", count: 25)).count, 19, "card numbers have at most 19 digits")
        XCTAssertEqual(CardNumber.brand("378282246310005"), "Amex")
        XCTAssertEqual(CardNumber.brand("341111111111111"), "Amex")
        XCTAssertEqual(CardNumber.brand("4111111111111111"), "Visa")
        XCTAssertEqual(CardNumber.brand("5555555555554444"), "Mastercard")
        XCTAssertEqual(CardNumber.brand("2223000048400011"), "Mastercard")
        XCTAssertEqual(CardNumber.brand("6011111111111117"), "Discover")
        XCTAssertEqual(CardNumber.brand("6511111111111111"), "Discover")
        XCTAssertNil(CardNumber.brand("3530111333300000"))
        XCTAssertNil(CardNumber.brand(""))
    }

    func testFormattingAndMasking() {
        XCTAssertEqual(CardNumber.formatted("4111111111111111"), "4111 1111 1111 1111")
        XCTAssertEqual(CardNumber.formatted("3782 822463 10005"), "3782 822463 10005")
        XCTAssertEqual(CardNumber.formatted("378282246310005"), "3782 822463 10005")
        XCTAssertEqual(CardNumber.formatted("4111111111111111123"), "4111 1111 1111 1111 123")
        XCTAssertEqual(CardNumber.formatted("41111"), "4111 1")
        XCTAssertEqual(CardNumber.formatted(""), "")

        XCTAssertEqual(CardNumber.masked("4111111111111111"), "•••• •••• •••• 1111")
        XCTAssertEqual(CardNumber.masked("378282246310005"), "•••• •••••• •0005")
        XCTAssertEqual(CardNumber.masked("123"), "123", "nothing is hidden when there are only four digits or fewer")
    }

    func testLuhn() {
        XCTAssertTrue(CardNumber.passesLuhn("4111111111111111"))
        XCTAssertTrue(CardNumber.passesLuhn("378282246310005"))
        XCTAssertTrue(CardNumber.passesLuhn("79927398713"))
        XCTAssertFalse(CardNumber.passesLuhn("4111111111111112"))
        XCTAssertFalse(CardNumber.passesLuhn("4111 1111"), "only digits are accepted")
    }
}

final class CardExpiryTests: XCTestCase {
    private func date(year: Int, month: Int, day: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    func testState() throws {
        let now = try date(year: 2026, month: 6, day: 15)
        XCTAssertEqual(CardExpiry.state("05/26", now: now), .expired)
        XCTAssertEqual(CardExpiry.state("12/25", now: now), .expired)
        XCTAssertEqual(CardExpiry.state("06/26", now: now), .soon, "the card works until the end of its month")
        XCTAssertEqual(CardExpiry.state("08/26", now: now), .soon)
        XCTAssertEqual(CardExpiry.state("09/26", now: now), .ok)
        XCTAssertEqual(CardExpiry.state("01/27", now: now), .ok)
        XCTAssertNil(CardExpiry.state(nil, now: now))
        XCTAssertNil(CardExpiry.state("13/26", now: now))
        XCTAssertNil(CardExpiry.state("00/26", now: now))
        XCTAssertNil(CardExpiry.state("6/26", now: now))
        XCTAssertNil(CardExpiry.state("06-26", now: now))
        XCTAssertNil(CardExpiry.state("ab/cd", now: now))
    }

    func testFormatInput() {
        XCTAssertEqual(CardExpiry.formatInput(""), "")
        XCTAssertEqual(CardExpiry.formatInput("1"), "1")
        XCTAssertEqual(CardExpiry.formatInput("12"), "12")
        XCTAssertEqual(CardExpiry.formatInput("123"), "12/3")
        XCTAssertEqual(CardExpiry.formatInput("12/34"), "12/34")
        XCTAssertEqual(CardExpiry.formatInput("123456"), "12/34")
        XCTAssertEqual(CardExpiry.formatInput("ab"), "")
    }
}

final class EntryTypePresentationTests: XCTestCase {
    func testBuiltInTypes() {
        XCTAssertEqual(VaultEntryType.builtIns, [.login, .card, .wifi, .server, .sshKey, .note])
        XCTAssertEqual(VaultEntryType.allCases.map(\.label), ["Login", "Credit Card", "Wi-Fi", "Server / SSH", "SSH Key", "Secure Note", "Entry"])
        for type in VaultEntryType.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil), type.symbol)
            XCTAssertFalse(type.titlePlaceholder.isEmpty)
        }
    }

    func testCompatibilityNotes() {
        XCTAssertNil(VaultEntryType.login.compatibilityNote(templateName: nil))
        for type in VaultEntryType.allCases where type != .login {
            XCTAssertNotNil(type.compatibilityNote(templateName: nil), type.rawValue)
        }
        XCTAssertEqual(
            VaultEntryType.template.compatibilityNote(templateName: "Passport"),
            "Fields come from the “Passport” template and are saved as custom fields."
        )
        XCTAssertEqual(
            VaultEntryType.template.compatibilityNote(templateName: nil),
            "Fields come from the “template” template and are saved as custom fields."
        )
    }

    func testTypedFieldKeys() {
        XCTAssertEqual(VaultTypedField.keys(for: .card), ["Expiry", "CVV", "PIN"])
        XCTAssertEqual(VaultTypedField.keys(for: .wifi), ["Security"])
        for type in [VaultEntryType.login, .server, .sshKey, .note, .template] {
            XCTAssertEqual(VaultTypedField.keys(for: type), [])
        }
    }
}

final class TypedEntrySubtitleTests: XCTestCase {
    private func entry(
        _ type: VaultEntryType,
        username: String? = nil,
        password: String? = nil,
        url: String? = nil,
        notes: String? = nil,
        fields: [String: String] = [:],
        templateName: String? = nil
    ) -> VaultEntry {
        VaultEntry(
            title: "Entry",
            username: username,
            password: password,
            url: url.flatMap(URL.init(string:)),
            notes: notes,
            customFields: fields.sorted { $0.key < $1.key }.map { VaultCustomField(key: $0.key, value: $0.value, isProtected: false) },
            entryType: type,
            templateName: templateName
        )
    }

    func testOldDatabasesShowEverythingAsLogins() {
        let card = entry(.card, password: "4111111111111111")
        XCTAssertEqual(card.effectiveType(supportsTypes: true), .card)
        XCTAssertEqual(card.effectiveType(supportsTypes: false), .login)
        XCTAssertNil(card.typedSubtitle(supportsTypes: false))
        XCTAssertNil(entry(.login, username: "anna").typedSubtitle(supportsTypes: true))
    }

    func testCardSubtitle() {
        let expired = entry(.card, password: "4111 1111 1111 1111", fields: [VaultTypedField.expiry: "01/20"])
        XCTAssertEqual(expired.typedSubtitle(supportsTypes: true), "Visa •••• 1111 · Expired")
        let unknown = entry(.card, password: "9999000011112222", fields: [VaultTypedField.expiry: "12/99"])
        XCTAssertEqual(unknown.typedSubtitle(supportsTypes: true), "Card •••• 2222")
        XCTAssertEqual(unknown.customValue(VaultTypedField.expiry), "12/99")
        XCTAssertNil(unknown.customValue(VaultTypedField.cvv))
    }

    func testWifiSubtitle() {
        XCTAssertEqual(entry(.wifi, username: "Home", fields: [VaultTypedField.security: "None"]).typedSubtitle(supportsTypes: true), "Home · Open network")
        XCTAssertEqual(entry(.wifi, username: "Home", fields: [VaultTypedField.security: "WPA3"]).typedSubtitle(supportsTypes: true), "Home · WPA3")
    }

    func testServerAddressAndSubtitle() {
        let server = entry(.server, username: "root", url: "ssh://db.example.com:2222")
        XCTAssertEqual(server.serverAddress.host, "db.example.com")
        XCTAssertEqual(server.serverAddress.port, "2222")
        XCTAssertEqual(server.typedSubtitle(supportsTypes: true), "root@db.example.com:2222")

        let defaultPort = entry(.server, url: "SSH://db.example.com")
        XCTAssertEqual(defaultPort.serverAddress.port, "22")
        XCTAssertEqual(defaultPort.typedSubtitle(supportsTypes: true), "db.example.com")

        let web = entry(.server, url: "https://example.com:8443")
        XCTAssertEqual(web.serverAddress.host, "example.com")
        XCTAssertEqual(web.serverAddress.port, "22", "only ssh:// URLs carry the port")
        XCTAssertEqual(entry(.server).serverAddress.host, "")
    }

    func testNoteTemplateAndKeySubtitles() {
        XCTAssertEqual(entry(.note, notes: "Door: 1234\nGarage: 5678").typedSubtitle(supportsTypes: true), "Door: 1234")
        XCTAssertEqual(entry(.note, notes: "").typedSubtitle(supportsTypes: true), "Empty note")
        XCTAssertEqual(entry(.note).typedSubtitle(supportsTypes: true), "Empty note")
        XCTAssertEqual(entry(.template, templateName: "Passport").typedSubtitle(supportsTypes: true), "Passport")
        XCTAssertEqual(entry(.sshKey, username: "git").typedSubtitle(supportsTypes: true), "git", "without a readable key the username is shown")
    }
}

final class EntryTemplateTests: XCTestCase {
    private func vault(supportsTypes: Bool, templatesPath: String?, entries: [VaultEntry]) -> LoadedVault {
        LoadedVault(
            summary: VaultSummary(fileName: "T.kdbx", groupCount: 2, entryCount: entries.count, supportsEntryTypes: supportsTypes, templatesGroupPath: templatesPath),
            groups: [],
            entries: entries
        )
    }

    func testTemplatesComeFromTheTemplatesGroup() throws {
        let passport = VaultEntry(
            groupPath: "Root.Templates",
            title: "Passport",
            customFields: [VaultCustomField(key: "Number", value: "", isProtected: true), VaultCustomField(key: "Country", value: "", isProtected: false)],
            iconID: 1
        )
        let plain = VaultEntry(groupPath: "Root.Templates", title: "Plain", iconID: 0)
        let trashed = VaultEntry(groupPath: "Root.Templates", isTrashed: true, title: "Old")
        let elsewhere = VaultEntry(groupPath: "Root", title: "Mail")
        let entries = [passport, plain, trashed, elsewhere]

        let templates = EntryTemplate.all(in: vault(supportsTypes: true, templatesPath: "Root.Templates", entries: entries))
        XCTAssertEqual(templates.map(\.title), ["Passport", "Plain"])
        let first = try XCTUnwrap(templates.first)
        XCTAssertEqual(first.fields.map(\.key), ["Number", "Country"])
        XCTAssertEqual(first.fields.map(\.isProtected), [true, false])
        XCTAssertEqual(first.symbol, "network")
        XCTAssertEqual(templates[1].symbol, "doc.text.fill", "the default key icon shows the template symbol")
        XCTAssertEqual(first, EntryTemplate(entry: VaultEntry(id: passport.id, title: "Renamed")), "templates are the same by ID")

        XCTAssertEqual(EntryTemplate.all(in: vault(supportsTypes: false, templatesPath: "Root.Templates", entries: entries)), [])
        XCTAssertEqual(EntryTemplate.all(in: vault(supportsTypes: true, templatesPath: nil, entries: entries)), [])
    }
}

final class EntryColorTests: XCTestCase {
    private func components(_ hex: String?) -> [CGFloat]? {
        guard let color = EntryColor.color(fromHex: hex), let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return nil
        }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { ($0 * 255).rounded() }
    }

    func testParsesHex() {
        XCTAssertEqual(components("#FF8000"), [255, 128, 0])
        XCTAssertEqual(components(" 00ff7f "), [0, 255, 127])
        XCTAssertNil(components("#FFF"))
        XCTAssertNil(components("#GG0000"))
        XCTAssertNil(components(nil))
        for hex in EntryColor.palette {
            XCTAssertNotNil(EntryColor.color(fromHex: hex), hex)
        }
        XCTAssertEqual(Set(EntryColor.palette).count, EntryColor.palette.count)
    }

    func testSameHex() {
        XCTAssertTrue(EntryColor.sameHex("#ff0000", "FF0000"))
        XCTAssertTrue(EntryColor.sameHex(" #E57373", "#e57373"))
        XCTAssertTrue(EntryColor.sameHex(nil, nil))
        XCTAssertFalse(EntryColor.sameHex(nil, "#000000"))
        XCTAssertFalse(EntryColor.sameHex("#000000", "#000001"))
    }
}

final class ExpirySummaryWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(expired: Int = 0, soon: Int = 0, warnDays: Int) -> ExpirySummary {
        let entries = (0..<expired).map { VaultEntry(expiresAt: now.addingTimeInterval(-86_400 - Double($0)), title: "E\($0)") }
            + (0..<soon).map { VaultEntry(expiresAt: now.addingTimeInterval(3600 + Double($0)), title: "S\($0)") }
        return ExpirySummary(entries: entries, warnDays: warnDays, now: now)
    }

    func testWindowBoundaries() {
        let entries = [
            VaultEntry(expiresAt: now, title: "Now"),
            VaultEntry(expiresAt: now.addingTimeInterval(7 * 86_400), title: "Edge"),
            VaultEntry(expiresAt: now.addingTimeInterval(7 * 86_400 + 1), title: "Outside")
        ]
        let result = ExpirySummary(entries: entries, warnDays: 7, now: now)
        XCTAssertEqual(result.expired, 0, "an entry expiring right now is not expired yet")
        XCTAssertEqual(result.expiringSoon, 2)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(ExpirySummary(entries: [VaultEntry(title: "Never")], warnDays: 7, now: now).isEmpty)
    }

    func testWindowTexts() {
        XCTAssertEqual(summary(warnDays: 7).windowText, "this week")
        XCTAssertEqual(summary(warnDays: 14).windowText, "in the next 2 weeks")
        XCTAssertEqual(summary(warnDays: 30).windowText, "in the next 30 days")
        XCTAssertEqual(summary(warnDays: 3).windowText, "in the next 3 days")
        XCTAssertEqual(summary(warnDays: 1).windowText, "in the next 1 day")
    }

    func testSingularTexts() {
        let one = summary(expired: 1, warnDays: 7).notificationContent(databaseName: "Home.kdbx")
        XCTAssertEqual(one.title, "Passwords expired")
        XCTAssertEqual(one.body, "1 password in Home.kdbx has expired.")

        let soon = summary(soon: 2, warnDays: 30).notificationContent(databaseName: "Home.kdbx")
        XCTAssertEqual(soon.title, "Passwords expiring soon")
        XCTAssertEqual(soon.body, "2 passwords in Home.kdbx expire in the next 30 days.")
        XCTAssertEqual(summary(soon: 1, warnDays: 7).notificationContent(databaseName: "Home.kdbx").body, "1 password in Home.kdbx expires this week.")

        XCTAssertEqual(summary(expired: 1, soon: 2, warnDays: 7).bannerText, "1 password has expired · 2 expire this week")
        XCTAssertEqual(summary(expired: 3, soon: 1, warnDays: 14).bannerText, "3 passwords have expired · 1 expires in the next 2 weeks")
        XCTAssertEqual(summary(soon: 1, warnDays: 30).bannerText, "1 password expires in the next 30 days")
    }
}
