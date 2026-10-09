import CryptoKit
@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

final class DatabaseReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private func makeReport() -> (DatabaseReport, [String: VaultEntry]) {
        let otp = VaultOTPConfiguration(secret: Data("x".utf8), digits: 6, period: 30, timeBase: 0, algorithm: .sha1)
        let bank = VaultEntry(
            groupPath: "Root.Work",
            accessedAt: daysAgo(200),
            usageCount: 10,
            expiresAt: daysAgo(3),
            passwordChangedAt: daysAgo(400),
            title: "Bank",
            password: "Tr0ub4dor&3xyz",
            url: URL(string: "https://bank.example.com"),
            attachments: [VaultAttachment(name: "a.pdf", data: Data(count: 1024))],
            otp: otp
        )
        let mail = VaultEntry(
            accessedAt: daysAgo(10),
            usageCount: 3,
            expiresAt: daysAgo(-5),
            passwordChangedAt: daysAgo(800),
            title: "Mail",
            password: "shared-Secret-42!",
            url: URL(string: "https://mail.example.com")
        )
        let forum = VaultEntry(expiresAt: daysAgo(-60), title: "Forum", password: "shared-Secret-42!", url: URL(string: "https://forum.example.com"))
        let note = VaultEntry(title: "Note")
        let weak = VaultEntry(expiresAt: now.addingTimeInterval(-3600), title: "Weak", password: "password1")
        let skipped = VaultEntry(expiresAt: now.addingTimeInterval(3600), checksPasswordQuality: false, title: "Skipped", password: "123")
        let reference = VaultEntry(
            usageCount: 1,
            title: "Ref",
            password: "Tr0ub4dor&3xyz",
            references: VaultEntryReferences(rawValues: [VaultEntryReferences.password: "{REF:P@I:…}"], sources: [VaultEntryReferences.password: bank.id])
        )
        let low = VaultEntry(title: "Low", password: "qwrtzuio")
        let trashed = VaultEntry(groupPath: "Root.Recycle Bin", isTrashed: true, title: "Old", password: "password1", attachments: [VaultAttachment(name: "b", data: Data(count: 2048))])

        let entries = [bank, mail, forum, note, weak, skipped, reference, low, trashed]
        let vault = LoadedVault(
            summary: VaultSummary(fileName: "Test.kdbx", groupCount: 5, entryCount: entries.count, masterKeyChangedAt: daysAgo(100), masterKeyChangeRecommendationDays: 90),
            groups: [
                VaultGroup(title: "Root", path: "Root"),
                VaultGroup(title: "Work", path: "Root.Work"),
                VaultGroup(title: "Servers", path: "Root.Work.Servers"),
                VaultGroup(title: "Home", path: "Root.Home"),
                VaultGroup(title: "Recycle Bin", path: "Root.Recycle Bin", isTrash: true)
            ],
            entries: entries
        )
        let report = DatabaseReport(vault: vault, rootPath: "Root", favoriteEntryIDs: [bank.id], expiringWithinDays: 30, oldAfterDays: 365, now: now)
        return (report, Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) }))
    }

    func testStats() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.stats.map(\.label), ["Entries", "Groups", "In Trash", "Attachments"])
        XCTAssertEqual(report.stats.map(\.value), ["8", "3", "1", "2"])
        XCTAssertEqual(report.stats[0].detail, "1 favorite")
        XCTAssertEqual(report.stats[1].detail, "2 top-level")
        XCTAssertEqual(report.stats[2].detail, "Not yet emptied")
        XCTAssertEqual(report.stats[3].detail, "\(DatabaseReport.byteCount(3072)) total", "trashed entries' attachments count too")
    }

    func testMasterKeyAndIssueCount() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.masterKey.ageDays, 100)
        XCTAssertEqual(report.masterKey.recommendedDays, 90)
        XCTAssertTrue(report.masterKey.isOverdue)
        // 2 expired + 2 reused + 2 weak + 2 old + overdue master key; expiring-soon entries are not issues.
        XCTAssertEqual(report.issueCount, 9)
    }

    func testCoverage() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.coverage.map(\.count), [1, 7, 1, 5])
        XCTAssertEqual(report.coverage[0].detail, "13% of entries have TOTP configured")
        XCTAssertEqual(report.coverage[1].detail, "Mail, Forum, Note and 4 more")
        XCTAssertEqual(report.coverage[2].detail, "Note")
        XCTAssertEqual(report.coverage[3].detail, "Note, Weak, Skipped and 2 more")
    }

    func testUsageAndStaleEntries() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.mostUsed.map(\.entry.title), ["Bank", "Mail", "Ref"])
        XCTAssertEqual(report.mostUsed.map(\.meta), ["10 uses", "3 uses", "1 use"])
        XCTAssertEqual(report.stale.map(\.entry.title), ["Bank"])
        XCTAssertEqual(report.stale.first?.meta, "7 months ago")
    }

    func testExpiringEntries() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.expiring.map(\.entry.title), ["Bank", "Weak", "Skipped", "Mail"])
        XCTAssertEqual(report.expiring.map(\.meta), ["Expired 3 days ago", "Expired today", "Expires today", "Expires in 5 days"])
        XCTAssertEqual(report.expiring.map(\.severity), [.critical, .critical, .warning, .warning])
    }

    func testReusedWeakAndOldPasswords() {
        let (report, _) = makeReport()
        XCTAssertEqual(report.uniquePasswordCount, 5, "a referenced password belongs to its source entry")
        XCTAssertEqual(Set(report.reused.map(\.entry.title)), ["Mail", "Forum"])
        XCTAssertEqual(report.reused.first { $0.entry.title == "Mail" }?.detail, "Same as Forum")
        XCTAssertEqual(report.reused.first?.meta, "Used 2×")

        XCTAssertEqual(report.weak.map(\.entry.title), ["Weak", "Low"])
        XCTAssertEqual(report.weak.map(\.meta), ["Common word", "Low entropy"])
        XCTAssertEqual(report.qualityCheckSkipped.map(\.title), ["Skipped"])

        XCTAssertEqual(report.old.map(\.entry.title), ["Mail", "Bank"])
        XCTAssertEqual(report.old.map(\.meta), ["\(oneDecimal(800.0 / 365)) years", "13 months"], "years use the region's decimal separator")
        XCTAssertEqual(report.old.last?.detail, "Password last changed 13 months ago")
    }

    func testEmptyVault() {
        let vault = LoadedVault(summary: VaultSummary(fileName: "Empty.kdbx", groupCount: 1, entryCount: 0), groups: [VaultGroup(title: "Root", path: "Root")], entries: [])
        let report = DatabaseReport(vault: vault, rootPath: "Root", favoriteEntryIDs: [], expiringWithinDays: 7, oldAfterDays: 365, now: now)
        XCTAssertEqual(report.stats.map(\.value), ["0", "0", "0", "0"])
        XCTAssertEqual(report.stats[2].detail, "Empty")
        XCTAssertEqual(report.coverage[0].detail, "0% of entries have TOTP configured")
        XCTAssertEqual(report.coverage[1].detail, "None")
        XCTAssertFalse(report.masterKey.isOverdue)
        XCTAssertNil(report.masterKey.ageDays)
        XCTAssertEqual(report.issueCount, 0)
    }

    func testFormattingHelpers() {
        XCTAssertEqual(DatabaseReport.formatAge(0), "0 days")
        XCTAssertEqual(DatabaseReport.formatAge(1), "1 day")
        XCTAssertEqual(DatabaseReport.formatAge(59), "59 days")
        XCTAssertEqual(DatabaseReport.formatAge(60), "2 months")
        XCTAssertEqual(DatabaseReport.formatAge(729), "24 months")
        XCTAssertEqual(DatabaseReport.formatAge(730), "\(oneDecimal(2)) years")
        XCTAssertEqual(DatabaseReport.days(from: now, to: now.addingTimeInterval(86_400 * 2.9)), 2)
        XCTAssertEqual(DatabaseReport.days(from: now, to: daysAgo(5)), 0, "never negative")
        XCTAssertEqual(DatabaseReport.names([]), "None")
        XCTAssertEqual(DatabaseReport.names([VaultEntry(title: "A"), VaultEntry(title: "B")]), "A, B")
        XCTAssertEqual(DatabaseReport.byteCount(0), "0 bytes")
    }
}

/// Answers HaveIBeenPwned range requests from a table instead of the network.
private final class PwnedRangeStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ newReplies: [String: Reply]) {
        lock.withLock {
            replies = newReplies
            requests = []
        }
    }

    static var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let prefix = request.url?.lastPathComponent ?? ""
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[prefix] ?? Reply(status: 200, body: "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class BreachCheckerTests: XCTestCase {
    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PwnedRangeStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    func testReportsBreachedEntriesAndSendsOnlyThePrefix() async throws {
        XCTAssertEqual(sha1Hex("password"), "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8")
        let unique = sha1Hex("unique-pw-7")
        PwnedRangeStubProtocol.install([
            "5BAA6": .init(status: 200, body: "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1e4c9b93f3f0682250b6cf8331b7ee68fd8:3861493\r\n"),
            String(unique.prefix(5)): .init(status: 200, body: "\(unique.dropFirst(5)):0\r\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:12\r\n")
        ])
        let first = VaultEntry(title: "A", password: "password")
        let second = VaultEntry(title: "B", password: "password")
        let safe = VaultEntry(title: "C", password: "unique-pw-7")
        let entries = [first, second, safe, VaultEntry(isTrashed: true, title: "T", password: "trashed"), VaultEntry(title: "E", password: "")]

        var progress: [[Int]] = []
        let result = try await BreachChecker.check(entries: entries, session: stubSession()) { done, total in
            progress.append([done, total])
        }

        XCTAssertEqual(result.checkedPasswordCount, 2, "one request per distinct password; trashed and empty ones are skipped")
        XCTAssertEqual(result.breachedEntries, [first.id: 3_861_493, second.id: 3_861_493], "a zero count is padding, not a breach")
        XCTAssertEqual(progress, [[0, 2], [1, 2], [2, 2]])

        let requests = PwnedRangeStubProtocol.recordedRequests
        XCTAssertEqual(Set(requests.compactMap { $0.url?.absoluteString }), [
            "https://api.pwnedpasswords.com/range/5BAA6",
            "https://api.pwnedpasswords.com/range/\(unique.prefix(5))"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Add-Padding") == "true" })
        XCTAssertFalse(requests.contains { $0.url?.absoluteString.contains("1E4C9B93") == true })
    }

    func testServerErrorThrows() async {
        PwnedRangeStubProtocol.install(["5BAA6": .init(status: 503, body: "")])
        do {
            _ = try await BreachChecker.check(entries: [VaultEntry(title: "A", password: "password")], session: stubSession()) { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testNothingToCheck() async throws {
        PwnedRangeStubProtocol.install([:])
        let result = try await BreachChecker.check(entries: [VaultEntry(title: "Empty")], session: stubSession()) { _, _ in }
        XCTAssertEqual(result, BreachChecker.Result(checkedPasswordCount: 0, breachedEntries: [:]))
        XCTAssertTrue(PwnedRangeStubProtocol.recordedRequests.isEmpty)
    }
}
