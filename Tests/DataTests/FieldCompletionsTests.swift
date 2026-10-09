import Domain
import Foundation
@testable import UI
import XCTest

final class FieldCompletionsTests: XCTestCase {
    func testSuggestionsSkipProtectedTrashedAndReferences() {
        let completions = FieldCompletions(entries: [
            VaultEntry(title: "GitHub", username: "anna@example.com", tags: ["work", "code"],
                       customFields: [
                           VaultCustomField(key: "Team", value: "Platform", isProtected: false),
                           VaultCustomField(key: "API token", value: "secret-value", isProtected: true)
                       ]),
            VaultEntry(title: "GitLab", username: "anna@example.com", tags: ["work"]),
            VaultEntry(title: "Bank", username: "anna.k"),
            VaultEntry(isTrashed: true, title: "Old", username: "old-login")
        ].map { $0 })
        XCTAssertEqual(completions.usernames, ["anna@example.com", "anna.k"])
        XCTAssertEqual(completions.tags, ["work", "code"])
        XCTAssertEqual(completions.customValues["Team"], ["Platform"])
        XCTAssertNil(completions.customValues["API token"])
    }

    func testCompleteKeepsTypedCaseAndPrefersFrequent() {
        let suggestions = ["anna@example.com", "anna.k", "Anton"]
        XCTAssertEqual(FieldCompletions.complete("an", from: suggestions), "anna@example.com")
        XCTAssertEqual(FieldCompletions.complete("ANNA.", from: suggestions), "ANNA.k")
        XCTAssertEqual(FieldCompletions.complete("anto", from: suggestions), "anton")
        XCTAssertNil(FieldCompletions.complete("anna.k", from: suggestions))
        XCTAssertNil(FieldCompletions.complete("", from: suggestions))
        XCTAssertNil(FieldCompletions.complete("zz", from: suggestions))
    }

    func testCompleteTagSkipsTagsAlreadyListed() {
        let tags = ["work", "wifi", "finance"]
        XCTAssertEqual(FieldCompletions.completeTag("w", from: tags), "work")
        XCTAssertEqual(FieldCompletions.completeTag("work, w", from: tags), "work, wifi")
        XCTAssertEqual(FieldCompletions.completeTag("work,fi", from: tags), "work,finance")
        XCTAssertNil(FieldCompletions.completeTag("work, ", from: tags))
    }
}
