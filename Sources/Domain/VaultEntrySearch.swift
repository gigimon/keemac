import Foundation

/// Parsed entry search query.
///
/// Plain words must all match (in any field). Supported syntax:
/// - `"two words"` — phrase
/// - `title:`, `user:` / `username:`, `url:`, `notes:`, `group:`, `tag:`, `field:` — match one field
/// - `is:otp`, `is:expired`, `is:expiring`, `is:weak`, `is:attachment`, `is:favorite` — flags
/// - `-term` — exclude entries that match the term
public struct VaultEntrySearch: Equatable, Sendable {
    public enum Field: String, Sendable, CaseIterable {
        case title
        case username
        case url
        case notes
        case group
        case tag
        case field
    }

    public enum Flag: String, Sendable, CaseIterable {
        case otp
        case expired
        case expiring
        case weak
        case attachment
        case favorite
    }

    public enum Condition: Equatable, Sendable {
        case text(String)
        case field(Field, String)
        case flag(Flag)
    }

    public struct Term: Equatable, Sendable {
        public let condition: Condition
        public let isNegated: Bool
    }

    /// What the search needs to know beyond the entry itself.
    public struct Context: Sendable {
        public var now: Date
        public var expiringWithinDays: Int
        public var rootPath: String
        public var isWeakPassword: @Sendable (String) -> Bool
        public var isFavorite: @Sendable (UUID) -> Bool

        public init(
            now: Date = Date(),
            expiringWithinDays: Int = 30,
            rootPath: String = "",
            isWeakPassword: @escaping @Sendable (String) -> Bool = { _ in false },
            isFavorite: @escaping @Sendable (UUID) -> Bool = { _ in false }
        ) {
            self.now = now
            self.expiringWithinDays = expiringWithinDays
            self.rootPath = rootPath
            self.isWeakPassword = isWeakPassword
            self.isFavorite = isFavorite
        }
    }

    public let terms: [Term]

    public var isEmpty: Bool { terms.isEmpty }

    public init(_ query: String) {
        terms = Self.tokenize(query).compactMap(Self.term(from:))
    }

    public func matches(_ entry: VaultEntry, context: Context = Context()) -> Bool {
        terms.allSatisfy { term in
            Self.evaluate(term.condition, entry: entry, context: context) != term.isNegated
        }
    }

    // MARK: - Parsing

    private struct Token {
        let text: String
        let isQuoted: Bool
        let isNegated: Bool
    }

    private static let fieldAliases: [String: Field] = [
        "title": .title,
        "user": .username,
        "username": .username,
        "url": .url,
        "notes": .notes,
        "note": .notes,
        "group": .group,
        "tag": .tag,
        "field": .field
    ]

    private static func tokenize(_ query: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false
        var negated = false

        func flush() {
            if !current.isEmpty || wasQuoted {
                tokens.append(Token(text: current, isQuoted: wasQuoted, isNegated: negated))
            }
            current = ""
            wasQuoted = false
            negated = false
        }

        for character in query {
            if character == "\"" {
                if inQuotes {
                    inQuotes = false
                } else {
                    inQuotes = true
                    wasQuoted = true
                }
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else if character == "-" && current.isEmpty && !wasQuoted && !negated && !inQuotes {
                negated = true
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func term(from token: Token) -> Term? {
        let text = token.text
        guard !text.isEmpty else {
            return nil
        }
        if let colon = text.firstIndex(of: ":") {
            let key = text[..<colon].lowercased()
            let value = String(text[text.index(after: colon)...])
            if key == "is" || key == "has", let flag = Flag(rawValue: value.lowercased()) {
                return Term(condition: .flag(flag), isNegated: token.isNegated)
            }
            if let field = fieldAliases[key], !value.isEmpty {
                return Term(condition: .field(field, value.lowercased()), isNegated: token.isNegated)
            }
        }
        return Term(condition: .text(text.lowercased()), isNegated: token.isNegated)
    }

    // MARK: - Matching

    private static func evaluate(_ condition: Condition, entry: VaultEntry, context: Context) -> Bool {
        switch condition {
        case .text(let text):
            return Field.allCases.contains { values(of: $0, entry: entry, context: context).contains { $0.contains(text) } }
        case .field(let field, let text):
            return values(of: field, entry: entry, context: context).contains { $0.contains(text) }
        case .flag(let flag):
            return evaluate(flag, entry: entry, context: context)
        }
    }

    private static func values(of field: Field, entry: VaultEntry, context: Context) -> [String] {
        switch field {
        case .title:
            return [entry.title.lowercased()]
        case .username:
            return [entry.username?.lowercased()].compactMap { $0 }
        case .url:
            return [entry.url?.absoluteString.lowercased()].compactMap { $0 }
        case .notes:
            return [entry.notes?.lowercased()].compactMap { $0 }
        case .group:
            return [displayPath(entry.groupPath, rootPath: context.rootPath).lowercased()]
        case .tag:
            return entry.tags.map { $0.lowercased() }
        case .field:
            // Protected values (passwords, keys) are never searched.
            return entry.customFields.flatMap { field in
                field.isProtected ? [field.key.lowercased()] : [field.key.lowercased(), field.value.lowercased()]
            } + entry.attachments.map { $0.name.lowercased() }
        }
    }

    private static func evaluate(_ flag: Flag, entry: VaultEntry, context: Context) -> Bool {
        switch flag {
        case .otp:
            return entry.otp != nil
        case .expired:
            guard let expiresAt = entry.expiresAt else {
                return false
            }
            return expiresAt < context.now
        case .expiring:
            guard let expiresAt = entry.expiresAt, expiresAt >= context.now else {
                return false
            }
            let limit = context.now.addingTimeInterval(TimeInterval(context.expiringWithinDays) * 86_400)
            return expiresAt <= limit
        case .weak:
            guard let password = entry.password, !password.isEmpty, entry.checksPasswordQuality else {
                return false
            }
            return context.isWeakPassword(password)
        case .attachment:
            return !entry.attachments.isEmpty
        case .favorite:
            return context.isFavorite(entry.id)
        }
    }

    /// Group path without the root group ("Root.Work.Servers" → "Work.Servers"), so `group:root` doesn't match everything.
    private static func displayPath(_ path: String, rootPath: String) -> String {
        guard !rootPath.isEmpty, path.hasPrefix(rootPath) else {
            return path
        }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
