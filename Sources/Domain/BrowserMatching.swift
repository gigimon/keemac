import Foundation

/// An entry as browser autofill sees it: resolved fields plus the KeePassXC-Browser options
/// stored in the entry's and its groups' CustomData.
public struct VaultBrowserCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    /// Values of `KP2A_URL*` fields.
    public let additionalURLs: [String]
    public let groupTitle: String
    public let isExpired: Bool
    public let onlyHTTPAuth: Bool
    public let notHTTPAuth: Bool
    public let omitWWW: Bool
    /// Nil when neither the entry nor its groups set it.
    public let skipAutoSubmit: Bool?
    public let access: BrowserAccessConfig?
    /// `KPH: ` fields, sent to the extension as extra form values.
    public let kphFields: [VaultCustomField]
    public let otp: VaultOTPConfiguration?

    public init(
        id: UUID,
        title: String,
        username: String,
        password: String,
        url: String,
        additionalURLs: [String],
        groupTitle: String,
        isExpired: Bool,
        onlyHTTPAuth: Bool = false,
        notHTTPAuth: Bool = false,
        omitWWW: Bool = false,
        skipAutoSubmit: Bool? = nil,
        access: BrowserAccessConfig? = nil,
        kphFields: [VaultCustomField] = [],
        otp: VaultOTPConfiguration? = nil
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.additionalURLs = additionalURLs
        self.groupTitle = groupTitle
        self.isExpired = isExpired
        self.onlyHTTPAuth = onlyHTTPAuth
        self.notHTTPAuth = notHTTPAuth
        self.omitWWW = omitWWW
        self.skipAutoSubmit = skipAutoSubmit
        self.access = access
        self.kphFields = kphFields
        self.otp = otp
    }
}

/// KeePassXC's per-entry `KeePassXC-Browser Settings` CustomData: hosts the user allowed or denied.
public struct BrowserAccessConfig: Codable, Sendable, Equatable {
    public static let customDataKey = "KeePassXC-Browser Settings"

    public var allowedHosts: [String]
    public var deniedHosts: [String]
    public var realm: String

    private enum CodingKeys: String, CodingKey {
        case allowedHosts = "Allow"
        case deniedHosts = "Deny"
        case realm = "Realm"
    }

    public init(allowedHosts: [String] = [], deniedHosts: [String] = [], realm: String = "") {
        self.allowedHosts = allowedHosts
        self.deniedHosts = deniedHosts
        self.realm = realm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedHosts = try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        deniedHosts = try container.decodeIfPresent([String].self, forKey: .deniedHosts) ?? []
        realm = try container.decodeIfPresent(String.self, forKey: .realm) ?? ""
    }

    public init?(json: String?) {
        guard let data = json?.data(using: .utf8),
              let config = try? JSONDecoder().decode(BrowserAccessConfig.self, from: data) else {
            return nil
        }
        self = config
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func isAllowed(_ host: String) -> Bool {
        allowedHosts.contains(host)
    }

    public func isDenied(_ host: String) -> Bool {
        deniedHosts.contains(host)
    }

    public mutating func allow(_ host: String) {
        if !allowedHosts.contains(host) {
            allowedHosts.append(host)
        }
        deniedHosts.removeAll { $0 == host }
    }

    public mutating func deny(_ host: String) {
        if !deniedHosts.contains(host) {
            deniedHosts.append(host)
        }
        allowedHosts.removeAll { $0 == host }
    }
}

/// Entries for a page, split by whether the user already allowed them there.
public struct BrowserLoginMatch: Sendable, Equatable {
    public var allowed: [VaultBrowserCandidate]
    public var needConfirmation: [VaultBrowserCandidate]

    public init(allowed: [VaultBrowserCandidate] = [], needConfirmation: [VaultBrowserCandidate] = []) {
        self.allowed = allowed
        self.needConfirmation = needConfirmation
    }
}

/// KeePassXC-Browser's rules for picking and ordering logins for a page (KeePassXC `BrowserService`).
public enum BrowserURLMatcher {
    /// Stands in for `*` while a wildcard URL is parsed.
    private static let wildcardToken = "1kpxcwc1"

    /// Two-label public suffixes, so `example.co.uk` isn't treated as a subdomain of `co.uk`.
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "com.br", "net.br", "org.br", "com.cn", "net.cn", "org.cn",
        "com.tw", "com.hk", "com.sg", "com.my", "co.in", "net.in", "org.in", "co.id",
        "co.za", "com.mx", "com.ar", "com.tr", "com.ua", "co.il", "com.pl",
        "msk.ru", "spb.ru", "com.ru", "net.ru", "org.ru",
        "github.io", "gitlab.io", "herokuapp.com", "appspot.com", "blogspot.com",
        "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com"
    ]

    /// Splits candidates for a page into allowed and to-confirm, dropping denied ones; both lists are sorted best match first.
    public static func match(
        _ candidates: [VaultBrowserCandidate],
        siteURL: String,
        formURL: String,
        httpAuth: Bool,
        alwaysAllowAccess: Bool,
        allowExpired: Bool
    ) -> BrowserLoginMatch {
        let siteHost = host(of: siteURL) ?? ""
        let formHost = host(of: formURL) ?? ""
        var result = BrowserLoginMatch()

        for candidate in candidates where includes(candidate, siteURL: siteURL, formURL: formURL) {
            if !httpAuth && candidate.onlyHTTPAuth {
                continue
            }
            if httpAuth && candidate.notHTTPAuth {
                continue
            }
            if candidate.isExpired && !allowExpired {
                continue
            }
            if httpAuth {
                result.needConfirmation.append(candidate)
                continue
            }
            switch access(candidate.access, siteHost: siteHost, formHost: formHost) {
            case .allowed:
                result.allowed.append(candidate)
            case .denied:
                continue
            case .unknown:
                if alwaysAllowAccess {
                    result.allowed.append(candidate)
                } else {
                    result.needConfirmation.append(candidate)
                }
            }
        }

        result.allowed = sorted(result.allowed, siteURL: siteURL, formURL: formURL)
        result.needConfirmation = sorted(result.needConfirmation, siteURL: siteURL, formURL: formURL)
        return result
    }

    public static func sorted(_ candidates: [VaultBrowserCandidate], siteURL: String, formURL: String) -> [VaultBrowserCandidate] {
        candidates
            .enumerated()
            .map { (offset: $0.offset, candidate: $0.element, priority: priority(of: [$0.element.url] + $0.element.additionalURLs, siteURL: siteURL, formURL: formURL)) }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.offset < $1.offset }
            .map(\.candidate)
    }

    enum Access {
        case allowed
        case denied
        case unknown
    }

    static func access(_ config: BrowserAccessConfig?, siteHost: String, formHost: String) -> Access {
        guard let config else {
            return .unknown
        }
        if config.isAllowed(siteHost) && (formHost.isEmpty || config.isAllowed(formHost)) {
            return .allowed
        }
        if config.isDenied(siteHost) || (!formHost.isEmpty && config.isDenied(formHost)) {
            return .denied
        }
        return .unknown
    }

    public static func includes(_ candidate: VaultBrowserCandidate, siteURL: String, formURL: String) -> Bool {
        if matches(entryURL: candidate.url, siteURL: siteURL, formURL: formURL, omitWWW: candidate.omitWWW, allowWildcards: false) {
            return true
        }
        return candidate.additionalURLs.contains {
            matches(entryURL: $0, siteURL: siteURL, formURL: formURL, omitWWW: candidate.omitWWW, allowWildcards: true)
        }
    }

    /// KeePassXC `handleURL`: the entry's host is the site's host or a parent domain of it,
    /// with the same scheme (entries without one mean https) and port.
    public static func matches(entryURL: String, siteURL: String, formURL: String, omitWWW: Bool = false, allowWildcards: Bool = false) -> Bool {
        let entryURL = entryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entryURL.isEmpty else {
            return false
        }

        var isWildcard = false
        if allowWildcards {
            if entryURL.count >= 2, entryURL.hasPrefix("\""), entryURL.hasSuffix("\"") {
                return entryURL.dropFirst().dropLast() == siteURL
            }
            isWildcard = entryURL.contains("*")
        }

        if siteURL.lowercased().hasPrefix("file://") {
            return entryURL == formURL
        }
        if entryURL.rangeOfCharacter(from: CharacterSet(charactersIn: "<>^`{|}")) != nil {
            return false
        }

        let parseable = isWildcard ? entryURL.replacingOccurrences(of: "*", with: wildcardToken) : entryURL
        guard let entry = components(of: parseable), var entryHost = entry.host?.lowercased(), !entryHost.isEmpty,
              let site = URLComponents(string: siteURL), let siteHost = site.host?.lowercased() else {
            return false
        }
        if omitWWW && entryHost.hasPrefix("www.") {
            entryHost.removeFirst(4)
        }
        if let port = entry.port, port > 0, port != site.port {
            return false
        }
        if let scheme = entry.scheme, scheme.lowercased() != site.scheme?.lowercased() {
            return false
        }

        if isWildcard {
            return wildcardMatches(pattern: entryHost, value: siteHost, isHost: true)
                && wildcardMatches(pattern: entry.path, value: site.path, isHost: false)
        }

        guard siteHost == entryHost || siteHost.hasSuffix("." + entryHost) else {
            return false
        }
        return baseDomain(of: siteHost) == baseDomain(of: entryHost)
    }

    /// KeePassXC `sortPriority`: 100 for the exact URL down to 50 for a parent domain of the form's host.
    public static func priority(of entryURLs: [String], siteURL: String, formURL: String) -> Int {
        let site = normalized(siteURL)
        let form = normalized(formURL)
        return entryURLs.map { priority(of: $0, site: site, form: form) }.max() ?? 0
    }

    private static func priority(of entryURL: String, site: URLComponents?, form: URLComponents?) -> Int {
        guard let site, var url = components(of: entryURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return 0
        }
        url.fragment = nil
        url.user = nil
        url.password = nil
        if url.path.isEmpty && url.query == nil {
            url.path = "/"
        }
        guard host.contains(".") || host == "localhost", url.scheme?.lowercased() == site.scheme?.lowercased() else {
            return 0
        }

        let candidates = [site, form].compactMap { $0 }
        if candidates.contains(where: { sameURL(url, $0, ignoringQuery: false) }) {
            return 100
        }
        if candidates.contains(where: { sameURL(url, $0, ignoringQuery: true) }) {
            return 90
        }
        if candidates.contains(where: { isParent(url, of: $0) }) {
            return 85
        }
        let siteHost = site.host?.lowercased() ?? ""
        let formHost = form?.host?.lowercased() ?? ""
        if host == siteHost {
            return 80
        }
        if host == formHost {
            return 70
        }
        if siteHost.hasSuffix(host) {
            return 60
        }
        if !formHost.isEmpty && formHost.hasSuffix(host) {
            return 50
        }
        return 0
    }

    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    /// The registrable domain, approximated with a short list of multi-label public suffixes.
    static func baseDomain(of host: String) -> String {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return host
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count > 2 else {
            return host
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let count = multiLabelSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }

    /// Entry URLs without a scheme mean https (KeePassXC with "match URL scheme" on).
    private static func components(of url: String) -> URLComponents? {
        URLComponents(string: url.contains("://") ? url : "https://" + url)
    }

    private static func normalized(_ url: String) -> URLComponents? {
        guard !url.isEmpty, var components = URLComponents(string: url), components.host != nil else {
            return nil
        }
        components.fragment = nil
        components.user = nil
        components.password = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        return components
    }

    private static func sameURL(_ lhs: URLComponents, _ rhs: URLComponents, ignoringQuery: Bool) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && lhs.path == rhs.path
            && (ignoringQuery || lhs.query == rhs.query)
    }

    /// `QUrl::isParentOf`: same scheme, host and port, and the child's path continues the parent's.
    private static func isParent(_ parent: URLComponents, of child: URLComponents) -> Bool {
        guard parent.scheme?.lowercased() == child.scheme?.lowercased(),
              parent.host?.lowercased() == child.host?.lowercased(),
              parent.port == child.port,
              child.path.count > parent.path.count,
              child.path.hasPrefix(parent.path) else {
            return false
        }
        return parent.path.hasSuffix("/") || child.path.dropFirst(parent.path.count).hasPrefix("/")
    }

    /// `*` stands for any text; `*.` in a host for any subdomain. Hosts must match whole,
    /// paths from the start; an entry without a path matches every path.
    private static func wildcardMatches(pattern: String, value: String, isHost: Bool) -> Bool {
        let pattern = pattern.replacingOccurrences(of: wildcardToken, with: "*")
        if pattern == value || (!isHost && (pattern.isEmpty || pattern == "/*")) {
            return true
        }
        guard pattern.contains("*") else {
            return isHost ? false : value.hasPrefix(pattern)
        }
        var regex = NSRegularExpression.escapedPattern(for: pattern)
        if isHost {
            regex = regex.replacingOccurrences(of: "\\*\\.", with: "(?:.*?\\.)?")
        }
        regex = regex.replacingOccurrences(of: "\\*", with: ".*?")
        regex = "^" + regex + (isHost ? "$" : "")
        return value.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// A browser connected to the database, stored as `KPXC_BROWSER_<id>` in the database's CustomData.
public struct VaultBrowserAssociation: Sendable, Equatable, Identifiable {
    public let id: String
    public let key: String
    /// As KeePassXC writes it (`_CREATED_<id>`, a localized short date).
    public let created: String?

    public init(id: String, key: String, created: String?) {
        self.id = id
        self.key = key
        self.created = created
    }
}

/// A group as KeePassXC-Browser lists it for "save to group".
public struct VaultBrowserGroup: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let children: [VaultBrowserGroup]

    public init(id: UUID, title: String, children: [VaultBrowserGroup] = []) {
        self.id = id
        self.title = title
        self.children = children
    }
}

/// A login the browser asks to save as a new entry.
public struct VaultBrowserNewLogin: Sendable, Equatable {
    public let title: String
    public let url: String
    public let username: String
    public let password: String
    /// Nil saves into the "KeePassXC-Browser Passwords" group.
    public let groupID: UUID?
    /// Hosts the new entry is allowed on right away, so the browser doesn't ask about the login it just saved.
    public let allowedHosts: [String]

    public init(title: String, url: String, username: String, password: String, groupID: UUID?, allowedHosts: [String]) {
        self.title = title
        self.url = url
        self.username = username
        self.password = password
        self.groupID = groupID
        self.allowedHosts = allowedHosts
    }
}

/// The entry an update from the browser changes: the entry itself, or the entry its password references.
public struct VaultBrowserLoginTarget: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let username: String
    public let password: String
    /// A username that is a `{REF:…}` is left as it is, like KeePassXC does.
    public let usernameIsReference: Bool

    public init(id: UUID, title: String, username: String, password: String, usernameIsReference: Bool) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.usernameIsReference = usernameIsReference
    }
}
