import CryptoKit
import Data
import Domain
import Foundation

struct DatabaseReport {
    struct Stat: Identifiable {
        let label: String
        let value: String
        let detail: String

        var id: String { label }
    }

    struct EntryIssue: Identifiable {
        enum Severity {
            case critical
            case warning
            case neutral
        }

        let entry: VaultEntry
        let detail: String
        let meta: String
        let severity: Severity

        var id: String { "\(entry.id.uuidString)-\(meta)" }
    }

    struct Coverage: Identifiable {
        let symbol: String
        let label: String
        let detail: String
        let count: Int

        var id: String { label }
    }

    struct MasterKeyStatus {
        let changedAt: Date?
        let ageDays: Int?
        let recommendedDays: Int?
        let isOverdue: Bool
    }

    let stats: [Stat]
    let masterKey: MasterKeyStatus
    let coverage: [Coverage]
    let mostUsed: [EntryIssue]
    let stale: [EntryIssue]
    let expiring: [EntryIssue]
    let reused: [EntryIssue]
    let weak: [EntryIssue]
    let qualityCheckSkipped: [VaultEntry]
    let old: [EntryIssue]
    let uniquePasswordCount: Int

    var issueCount: Int {
        expiring.filter { $0.severity == .critical }.count + reused.count + weak.count + old.count + (masterKey.isOverdue ? 1 : 0)
    }

    static let staleDays = 180

    init(
        vault: LoadedVault,
        rootPath: String,
        favoriteEntryIDs: Set<UUID>,
        expiringWithinDays: Int,
        oldAfterDays: Int,
        now: Date = .now
    ) {
        let live = vault.entries.filter { !$0.isTrashed }
        let trash = vault.entries.filter(\.isTrashed)
        let groups = vault.groups.filter { !$0.isTrash && $0.path != rootPath && !$0.path.isEmpty }
        let topLevelGroups = groups.filter { GroupPathFormatter.relativeComponents($0.path, rootPath: rootPath).count == 1 }
        let attachments = vault.entries.flatMap(\.attachments)
        let attachmentBytes = attachments.reduce(0) { $0 + $1.size }

        stats = [
            Stat(label: L("Entries"), value: "\(live.count)", detail: L("\(live.filter { favoriteEntryIDs.contains($0.id) }.count) favorites")),
            Stat(label: L("Groups"), value: "\(groups.count)", detail: L("\(topLevelGroups.count) top-level")),
            Stat(label: L("In Trash"), value: "\(trash.count)", detail: trash.isEmpty ? L("Empty") : L("Not yet emptied")),
            Stat(
                label: L("Attachments"),
                value: "\(attachments.count)",
                detail: L("\(Self.byteCount(attachmentBytes)) total")
            )
        ]

        let summary = vault.summary
        let keyAge = summary.masterKeyChangedAt.map { Self.days(from: $0, to: now) }
        masterKey = MasterKeyStatus(
            changedAt: summary.masterKeyChangedAt,
            ageDays: keyAge,
            recommendedDays: summary.masterKeyChangeRecommendationDays,
            isOverdue: {
                guard let keyAge, let limit = summary.masterKeyChangeRecommendationDays else {
                    return false
                }
                return keyAge > limit
            }()
        )

        let withOTP = live.filter { $0.otp != nil }
        let withoutOTP = live.filter { $0.otp == nil }
        let withoutPassword = live.filter { ($0.password ?? "").isEmpty }
        let withoutURL = live.filter { $0.url == nil }
        let otpShare = live.isEmpty ? 0 : Int((Double(withOTP.count) / Double(live.count) * 100).rounded())
        coverage = [
            Coverage(symbol: "number", label: L("With one-time codes"), detail: L("\(otpShare)% of entries have TOTP configured"), count: withOTP.count),
            Coverage(symbol: "lock.open", label: L("Without one-time codes"), detail: Self.names(withoutOTP), count: withoutOTP.count),
            Coverage(symbol: "key.slash", label: L("Without password"), detail: Self.names(withoutPassword), count: withoutPassword.count),
            Coverage(symbol: "link.badge.plus", label: L("Without URL"), detail: Self.names(withoutURL), count: withoutURL.count)
        ]

        mostUsed = live
            .filter { $0.usageCount > 0 }
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(5)
            .map { EntryIssue(entry: $0, detail: "", meta: L("\($0.usageCount) uses"), severity: .neutral) }

        stale = live
            .compactMap { entry -> (VaultEntry, Int)? in
                guard let accessedAt = entry.accessedAt else {
                    return nil
                }
                let age = Self.days(from: accessedAt, to: now)
                return age > Self.staleDays ? (entry, age) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { EntryIssue(entry: $0.0, detail: "", meta: L("\(Self.formatAge($0.1)) ago"), severity: .neutral) }

        let expired = live
            .compactMap { entry -> (VaultEntry, Int)? in
                guard let expiresAt = entry.expiresAt, expiresAt < now else {
                    return nil
                }
                return (entry, Self.days(from: expiresAt, to: now))
            }
            .sorted { $0.1 > $1.1 }
            .map { EntryIssue(entry: $0.0, detail: "", meta: $0.1 == 0 ? L("Expired today") : L("Expired \($0.1) days ago"), severity: .critical) }
        let expiringSoon = live
            .compactMap { entry -> (VaultEntry, Int)? in
                guard let expiresAt = entry.expiresAt, expiresAt >= now else {
                    return nil
                }
                let remaining = Self.days(from: now, to: expiresAt)
                return remaining <= expiringWithinDays ? (entry, remaining) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map { EntryIssue(entry: $0.0, detail: "", meta: $0.1 == 0 ? L("Expires today") : L("Expires in \($0.1) days"), severity: .warning) }
        expiring = expired + expiringSoon

        // A password that is a {REF:…} to another entry is that entry's password, checked there.
        let ownPasswords = live.filter { $0.references?.isReference(VaultEntryReferences.password) != true }
        var byPassword: [String: [VaultEntry]] = [:]
        for entry in ownPasswords {
            if let password = entry.password, !password.isEmpty {
                byPassword[password, default: []].append(entry)
            }
        }
        uniquePasswordCount = byPassword.count
        reused = byPassword.values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
            .flatMap { group in
                group.map { entry in
                    let others = group.filter { $0.id != entry.id }.map(\.title).joined(separator: ", ")
                    return EntryIssue(entry: entry, detail: L("Same as \(others)"), meta: L("Used \(group.count)×"), severity: .warning)
                }
            }

        let withPassword = ownPasswords.filter { !($0.password ?? "").isEmpty }
        qualityCheckSkipped = withPassword.filter { !$0.checksPasswordQuality }
        weak = withPassword
            .filter(\.checksPasswordQuality)
            .compactMap { entry -> EntryIssue? in
                guard let password = entry.password,
                      let strength = PasswordStrength.evaluate(password),
                      strength.level == .weak else {
                    return nil
                }
                return EntryIssue(entry: entry, detail: "", meta: strength.weakness ?? L("Low entropy"), severity: .critical)
            }

        old = withPassword
            .compactMap { entry -> (VaultEntry, Int)? in
                guard let changedAt = entry.passwordChangedAt else {
                    return nil
                }
                let age = Self.days(from: changedAt, to: now)
                return age > oldAfterDays ? (entry, age) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map {
                EntryIssue(
                    entry: $0.0,
                    detail: L("Password last changed \(Self.formatAge($0.1)) ago"),
                    meta: Self.formatAge($0.1),
                    severity: .warning
                )
            }
    }

    static func byteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func days(from start: Date, to end: Date) -> Int {
        max(Int(end.timeIntervalSince(start) / 86_400), 0)
    }

    static func formatAge(_ days: Int) -> String {
        if days < 60 {
            return L("\(days) days")
        }
        if days < 730 {
            return L("\(Int((Double(days) / 30).rounded())) months")
        }
        let years = (Double(days) / 365).formatted(.number.precision(.fractionLength(1)).grouping(.never))
        return L("\(years) years")
    }

    static func names(_ entries: [VaultEntry]) -> String {
        guard !entries.isEmpty else {
            return L("None")
        }
        let shown = entries.prefix(3).map(\.title).joined(separator: ", ")
        return entries.count > 3 ? L("\(shown) and \(entries.count - 3) more") : shown
    }
}

/// Checks passwords against Have I Been Pwned using the k-anonymity range API:
/// only the first five hex characters of each SHA-1 hash leave the Mac.
enum BreachChecker {
    struct Result: Equatable {
        let checkedPasswordCount: Int
        /// Entry ID → number of times the password was seen in breaches.
        let breachedEntries: [UUID: Int]
    }

    static func check(
        entries: [VaultEntry],
        session: URLSession = .shared,
        progress: @MainActor (_ done: Int, _ total: Int) -> Void
    ) async throws -> Result {
        var entriesByPassword: [String: [UUID]] = [:]
        for entry in entries where !entry.isTrashed {
            if let password = entry.password, !password.isEmpty {
                entriesByPassword[password, default: []].append(entry.id)
            }
        }

        let passwords = Array(entriesByPassword.keys)
        var breached: [UUID: Int] = [:]
        await progress(0, passwords.count)

        for (index, password) in passwords.enumerated() {
            try Task.checkCancellation()
            let hash = Insecure.SHA1.hash(data: Data(password.utf8))
                .map { String(format: "%02X", $0) }
                .joined()
            let prefix = String(hash.prefix(5))
            let suffix = String(hash.dropFirst(5))

            var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
            request.setValue("true", forHTTPHeaderField: "Add-Padding")
            request.setValue("KeeMac", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }

            let body = String(decoding: data, as: UTF8.self)
            for line in body.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":")
                guard parts.count == 2, parts[0].uppercased() == suffix else {
                    continue
                }
                let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                if count > 0 {
                    for id in entriesByPassword[password] ?? [] {
                        breached[id] = count
                    }
                }
                break
            }
            await progress(index + 1, passwords.count)
        }

        return Result(checkedPasswordCount: passwords.count, breachedEntries: breached)
    }
}
