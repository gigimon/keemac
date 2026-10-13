import Foundation

/// The window Auto-Type types into.
public struct AutoTypeWindow: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let title: String
    /// The address of the browser tab, when the browser shows it to Accessibility.
    public let url: String?

    public init(appName: String, bundleIdentifier: String? = nil, title: String, url: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.url = url
    }

    /// What the picker shows after the app name: the site's host, else the window title.
    public var place: String {
        if let url, let host = BrowserURLMatcher.host(of: url), !host.isEmpty {
            return host
        }
        return title
    }
}

/// Why an entry matched, strongest first.
public enum AutoTypeMatchReason: Int, Comparable, Sendable {
    /// One of the entry's window associations.
    case window
    /// An entry URL matches the browser tab.
    case url
    /// The window title contains the entry's title.
    case title

    public static func < (lhs: AutoTypeMatchReason, rhs: AutoTypeMatchReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AutoTypeMatch: Equatable, Sendable, Identifiable {
    public let entry: VaultEntry
    public let reason: AutoTypeMatchReason
    /// The sequence to type into this window.
    public let sequence: String

    public var id: UUID {
        entry.id
    }

    public init(entry: VaultEntry, reason: AutoTypeMatchReason, sequence: String) {
        self.entry = entry
        self.reason = reason
        self.sequence = sequence
    }
}

/// Picks entries for a window like KeePass: window associations, then the entry title in the
/// window title; plus the tab URL in browsers that expose it.
public enum AutoTypeMatcher {
    /// Shortest entry title matched inside window titles, so "Go" doesn't match every window.
    static let minimumTitleLength = 3

    /// Entries Auto-Type may type: logins (the type whose editor has Auto-Type settings) that are on
    /// for themselves and their groups, outside the trash.
    public static func candidates(in entries: [VaultEntry]) -> [VaultEntry] {
        entries.filter { entry in
            !entry.isTrashed && entry.isAutoTypeEnabled && entry.entryType == .login
        }
    }

    /// Matching entries, best first (association, URL, title; then most used).
    public static func matches(in entries: [VaultEntry], window: AutoTypeWindow) -> [AutoTypeMatch] {
        candidates(in: entries)
            .compactMap { match($0, window: window) }
            .sorted { lhs, rhs in
                if lhs.reason != rhs.reason {
                    return lhs.reason < rhs.reason
                }
                if lhs.entry.usageCount != rhs.entry.usageCount {
                    return lhs.entry.usageCount > rhs.entry.usageCount
                }
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
    }

    public static func match(_ entry: VaultEntry, window: AutoTypeWindow) -> AutoTypeMatch? {
        if let association = entry.autoType.associations.first(where: { $0.matches(windowTitle: window.title) }) {
            let sequence = association.sequence.trimmingCharacters(in: .whitespaces).isEmpty
                ? entry.effectiveAutoTypeSequence
                : association.sequence
            return AutoTypeMatch(entry: entry, reason: .window, sequence: sequence)
        }
        if let url = window.url, matchesURL(entry, siteURL: url) {
            return AutoTypeMatch(entry: entry, reason: .url, sequence: entry.effectiveAutoTypeSequence)
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count >= minimumTitleLength, window.title.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return AutoTypeMatch(entry: entry, reason: .title, sequence: entry.effectiveAutoTypeSequence)
        }
        return nil
    }

    /// The sequence for an entry picked by hand: its association for this window if any, else its own.
    public static func sequence(for entry: VaultEntry, window: AutoTypeWindow?) -> String {
        if let window, let match = match(entry, window: window), match.reason == .window {
            return match.sequence
        }
        return entry.effectiveAutoTypeSequence
    }

    static func matchesURL(_ entry: VaultEntry, siteURL: String) -> Bool {
        let additional = entry.customFields
            .filter { $0.key.hasPrefix("KP2A_URL") }
            .map(\.value)
        let urls = ([entry.url?.absoluteString].compactMap { $0 } + additional).filter { !$0.isEmpty }
        return urls.contains { BrowserURLMatcher.matches(entryURL: $0, siteURL: siteURL, formURL: siteURL) }
    }
}
