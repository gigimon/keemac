import Domain
import Foundation
import XCTest

final class VaultEntrySearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private lazy var github = VaultEntry(
        groupPath: "Root.Work.Dev",
        expiresAt: now.addingTimeInterval(5 * 86_400),
        title: "GitHub",
        username: "anna",
        password: "123",
        url: URL(string: "https://github.com"),
        notes: "Recovery codes in the safe",
        tags: ["code"],
        customFields: [
            VaultCustomField(key: "Team", value: "Platform", isProtected: false),
            VaultCustomField(key: "API token", value: "secret-value", isProtected: true)
        ],
        attachments: [VaultAttachment(name: "recovery.txt", data: Data())],
        otp: VaultOTPConfiguration(secret: Data([1, 2, 3]), digits: 6, period: 30, timeBase: 0, algorithm: .sha1)
    )

    private lazy var bank = VaultEntry(
        groupPath: "Root.Finance",
        expiresAt: now.addingTimeInterval(-86_400),
        title: "Bank",
        username: "anna.k",
        password: "Vq8!mT2#zR6wLp4Xe9",
        notes: "Card PIN in the drawer"
    )

    private var context: VaultEntrySearch.Context {
        VaultEntrySearch.Context(
            now: now,
            expiringWithinDays: 30,
            rootPath: "Root",
            isWeakPassword: { $0.count < 8 },
            isFavorite: { _ in false }
        )
    }

    private func titles(_ query: String) -> [String] {
        let search = VaultEntrySearch(query)
        return [github, bank].filter { search.matches($0, context: context) }.map(\.title)
    }

    func testPlainWordsMatchAnyFieldAndAllMustMatch() {
        XCTAssertEqual(titles("anna"), ["GitHub", "Bank"])
        XCTAssertEqual(titles("recovery"), ["GitHub"])
        XCTAssertEqual(titles("drawer"), ["Bank"])
        XCTAssertEqual(titles("platform"), ["GitHub"])
        XCTAssertEqual(titles("anna drawer"), ["Bank"])
        XCTAssertEqual(titles("finance"), ["Bank"])
    }

    func testProtectedValuesAndRootGroupAreNotSearched() {
        XCTAssertEqual(titles("secret-value"), [])
        XCTAssertEqual(titles("group:root"), [])
    }

    func testFieldOperatorsPhrasesAndNegation() {
        XCTAssertEqual(titles("user:anna.k"), ["Bank"])
        XCTAssertEqual(titles("title:git"), ["GitHub"])
        XCTAssertEqual(titles("group:work"), ["GitHub"])
        XCTAssertEqual(titles("tag:code"), ["GitHub"])
        XCTAssertEqual(titles("field:team"), ["GitHub"])
        XCTAssertEqual(titles("\"in the safe\""), ["GitHub"])
        XCTAssertEqual(titles("notes:\"the drawer\""), ["Bank"])
        XCTAssertEqual(titles("anna -github"), ["Bank"])
    }

    func testFlags() {
        XCTAssertEqual(titles("is:otp"), ["GitHub"])
        XCTAssertEqual(titles("is:expired"), ["Bank"])
        XCTAssertEqual(titles("is:expiring"), ["GitHub"])
        XCTAssertEqual(titles("is:weak"), ["GitHub"])
        XCTAssertEqual(titles("has:attachment"), ["GitHub"])
        XCTAssertEqual(titles("-is:otp"), ["Bank"])
        XCTAssertEqual(titles("is:unknown"), [])
    }

    func testEmptyQuery() {
        XCTAssertTrue(VaultEntrySearch("   ").isEmpty)
        XCTAssertTrue(VaultEntrySearch("-").isEmpty)
    }
}
