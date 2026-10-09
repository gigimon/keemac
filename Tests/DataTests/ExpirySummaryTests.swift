import Domain
import Foundation
@testable import UI
import XCTest

final class ExpirySummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ title: String, expiresInDays days: Double?, trashed: Bool = false) -> VaultEntry {
        VaultEntry(isTrashed: trashed, expiresAt: days.map { now.addingTimeInterval($0 * 86_400) }, title: title)
    }

    func testCountsExpiredAndExpiringWithinWindow() {
        let summary = ExpirySummary(entries: [
            entry("Old", expiresInDays: -3),
            entry("Soon", expiresInDays: 5),
            entry("Later", expiresInDays: 20),
            entry("Never", expiresInDays: nil),
            entry("Trashed", expiresInDays: -1, trashed: true)
        ], warnDays: 7, now: now)
        XCTAssertEqual(summary.expired, 1)
        XCTAssertEqual(summary.expiringSoon, 1)
        XCTAssertEqual(ExpirySummary(entries: [entry("Later", expiresInDays: 20)], warnDays: 30, now: now).expiringSoon, 1)
    }

    func testTextsShowCountsOnly() {
        let summary = ExpirySummary(entries: [
            entry("Bank", expiresInDays: -3),
            entry("Mail", expiresInDays: -1),
            entry("GitHub", expiresInDays: 2)
        ], warnDays: 7, now: now)
        let content = summary.notificationContent(databaseName: "Personal.kdbx")
        XCTAssertEqual(content.title, "Passwords expired")
        XCTAssertEqual(content.body, "2 passwords in Personal.kdbx have expired, and 1 more expires this week.")
        XCTAssertFalse(content.body.contains("GitHub"))
        XCTAssertEqual(summary.bannerText, "2 passwords have expired · 1 expires this week")

        let soonOnly = ExpirySummary(entries: [entry("GitHub", expiresInDays: 2)], warnDays: 14, now: now)
        XCTAssertEqual(soonOnly.notificationContent(databaseName: "Personal.kdbx").title, "Passwords expiring soon")
        XCTAssertEqual(soonOnly.bannerText, "1 password expires in the next 2 weeks")
    }
}
