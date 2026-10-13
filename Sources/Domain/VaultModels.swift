import Foundation

public struct VaultSummary: Equatable, Sendable {
    public let fileName: String
    public let groupCount: Int
    public let entryCount: Int
    public let masterKeyChangedAt: Date?
    /// Days after which KeePass recommends changing the master key; nil when disabled.
    public let masterKeyChangeRecommendationDays: Int?
    /// Days after which KeePass forces a master key change; nil when disabled.
    public let masterKeyChangeEnforcementDays: Int?
    /// Entry types and templates need KDBX 4 (entry CustomData); older files show plain fields.
    public let supportsEntryTypes: Bool
    /// The database's entry templates group, if one is set.
    public let templatesGroupPath: String?

    public init(
        fileName: String,
        groupCount: Int,
        entryCount: Int,
        masterKeyChangedAt: Date? = nil,
        masterKeyChangeRecommendationDays: Int? = nil,
        masterKeyChangeEnforcementDays: Int? = nil,
        supportsEntryTypes: Bool = false,
        templatesGroupPath: String? = nil
    ) {
        self.fileName = fileName
        self.groupCount = groupCount
        self.entryCount = entryCount
        self.masterKeyChangedAt = masterKeyChangedAt
        self.masterKeyChangeRecommendationDays = masterKeyChangeRecommendationDays
        self.masterKeyChangeEnforcementDays = masterKeyChangeEnforcementDays
        self.supportsEntryTypes = supportsEntryTypes
        self.templatesGroupPath = templatesGroupPath
    }
}

public struct VaultGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let iconPNGData: Data?
    public let iconID: Int?
    public let isTrash: Bool

    public init(id: UUID = UUID(), title: String, path: String, iconPNGData: Data? = nil, iconID: Int? = nil, isTrash: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.iconPNGData = iconPNGData
        self.iconID = iconID
        self.isTrash = isTrash
    }

    /// The same group under another ID and path, for showing several databases side by side.
    public func relabeled(id: UUID, path: String) -> VaultGroup {
        VaultGroup(id: id, title: title, path: path, iconPNGData: iconPNGData, iconID: iconID, isTrash: isTrash)
    }
}

public struct VaultEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let groupPath: String
    public let isTrashed: Bool
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let accessedAt: Date?
    public let usageCount: Int
    public let expiresAt: Date?
    public let passwordChangedAt: Date?
    public let checksPasswordQuality: Bool
    public let title: String
    public let username: String?
    public let password: String?
    public let url: URL?
    public let notes: String?
    public let tags: [String]
    public let foregroundColorHex: String?
    public let backgroundColorHex: String?
    public let customFields: [VaultCustomField]
    public let attachments: [VaultAttachment]
    public let iconPNGData: Data?
    public let iconID: Int?
    public let otp: VaultOTPConfiguration?
    public let otpStorageStyle: VaultOTPStorageStyle?
    public let history: [VaultEntryRevision]
    public let entryType: VaultEntryType
    public let templateName: String?
    /// nil when no field uses references or placeholders.
    public let references: VaultEntryReferences?
    /// Nil when the entry has no SSH agent settings.
    public let sshAgent: VaultSSHAgentSettings?

    public init(
        id: UUID = UUID(),
        groupPath: String = "",
        isTrashed: Bool = false,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        accessedAt: Date? = nil,
        usageCount: Int = 0,
        expiresAt: Date? = nil,
        passwordChangedAt: Date? = nil,
        checksPasswordQuality: Bool = true,
        title: String,
        username: String? = nil,
        password: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        tags: [String] = [],
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        customFields: [VaultCustomField] = [],
        attachments: [VaultAttachment] = [],
        iconPNGData: Data? = nil,
        iconID: Int? = nil,
        otp: VaultOTPConfiguration? = nil,
        otpStorageStyle: VaultOTPStorageStyle? = nil,
        history: [VaultEntryRevision] = [],
        entryType: VaultEntryType = .login,
        templateName: String? = nil,
        references: VaultEntryReferences? = nil,
        sshAgent: VaultSSHAgentSettings? = nil
    ) {
        self.id = id
        self.groupPath = groupPath
        self.isTrashed = isTrashed
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.accessedAt = accessedAt
        self.usageCount = usageCount
        self.expiresAt = expiresAt
        self.passwordChangedAt = passwordChangedAt
        self.checksPasswordQuality = checksPasswordQuality
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.tags = tags
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.customFields = customFields
        self.attachments = attachments
        self.iconPNGData = iconPNGData
        self.iconID = iconID
        self.otp = otp
        self.otpStorageStyle = otpStorageStyle
        self.history = history
        self.entryType = entryType
        self.templateName = templateName
        self.references = references
        self.sshAgent = sshAgent
    }

    /// What is stored in a field: the reference text if there is one, otherwise the value.
    public func rawValue(_ field: String) -> String? {
        references?.rawValues[field]
    }

    /// The same entry under another ID and group path, for showing several databases side by side.
    public func relabeled(id: UUID, groupPath: String, references: VaultEntryReferences?) -> VaultEntry {
        VaultEntry(
            id: id,
            groupPath: groupPath,
            isTrashed: isTrashed,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            accessedAt: accessedAt,
            usageCount: usageCount,
            expiresAt: expiresAt,
            passwordChangedAt: passwordChangedAt,
            checksPasswordQuality: checksPasswordQuality,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            tags: tags,
            foregroundColorHex: foregroundColorHex,
            backgroundColorHex: backgroundColorHex,
            customFields: customFields,
            attachments: attachments,
            iconPNGData: iconPNGData,
            iconID: iconID,
            otp: otp,
            otpStorageStyle: otpStorageStyle,
            history: history,
            entryType: entryType,
            templateName: templateName,
            references: references,
            sshAgent: sshAgent
        )
    }
}

public struct VaultEntryRevision: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let modifiedAt: Date?
    public let groupPath: String
    public let title: String
    public let username: String?
    public let password: String?
    public let url: URL?
    public let notes: String?
    public let tags: [String]
    public let customFields: [VaultCustomField]
    public let attachments: [VaultAttachment]
    public let iconID: Int?
    public let otp: VaultOTPConfiguration?
    public let otpStorageStyle: VaultOTPStorageStyle?

    public init(
        id: UUID = UUID(),
        modifiedAt: Date? = nil,
        groupPath: String = "",
        title: String,
        username: String? = nil,
        password: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        tags: [String] = [],
        customFields: [VaultCustomField] = [],
        attachments: [VaultAttachment] = [],
        iconID: Int? = nil,
        otp: VaultOTPConfiguration? = nil,
        otpStorageStyle: VaultOTPStorageStyle? = nil
    ) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.groupPath = groupPath
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.tags = tags
        self.customFields = customFields
        self.attachments = attachments
        self.iconID = iconID
        self.otp = otp
        self.otpStorageStyle = otpStorageStyle
    }
}

public struct VaultAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let data: Data
    public let isProtected: Bool

    public var size: Int {
        data.count
    }

    public init(name: String, data: Data, isProtected: Bool = false) {
        self.id = name
        self.name = name
        self.data = data
        self.isProtected = isProtected
    }
}

public enum VaultOTPAlgorithm: String, Equatable, Sendable {
    case sha1
    case sha256
    case sha512
}

/// Time-based (RFC 6238), counter-based (RFC 4226) or Steam Guard codes.
public enum VaultOTPKind: String, Equatable, Sendable, CaseIterable {
    case totp
    case hotp
    case steam

    public var isCounterBased: Bool {
        self == .hotp
    }
}

public struct VaultOTPConfiguration: Equatable, Sendable {
    public let secret: Data
    public let digits: Int
    public let period: Int
    public let timeBase: TimeInterval
    public let algorithm: VaultOTPAlgorithm
    public let kind: VaultOTPKind
    /// The HOTP counter of the next code; 0 for time-based kinds.
    public let counter: UInt64

    public init(
        secret: Data,
        digits: Int,
        period: Int,
        timeBase: TimeInterval,
        algorithm: VaultOTPAlgorithm,
        kind: VaultOTPKind = .totp,
        counter: UInt64 = 0
    ) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.timeBase = timeBase
        self.algorithm = algorithm
        self.kind = kind
        self.counter = counter
    }
}

public struct VaultCustomField: Identifiable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let isProtected: Bool

    public init(key: String, value: String, isProtected: Bool) {
        self.id = key
        self.key = key
        self.value = value
        self.isProtected = isProtected
    }
}

/// KeePass field references (`{REF:P@I:…}`) and placeholders (`{USERNAME}`) found in an entry.
/// The entry's own fields hold the resolved values; this keeps what is actually stored.
public struct VaultEntryReferences: Equatable, Sendable {
    /// Standard field names, as KeePass stores them.
    public static let title = "Title"
    public static let username = "UserName"
    public static let password = "Password"
    public static let url = "URL"
    public static let notes = "Notes"

    /// Stored text of every field that contains a reference or placeholder, keyed by field name
    /// (standard names above, or the custom field's key).
    public let rawValues: [String: String]
    /// Entry a field's `{REF:…@I:uuid}` points to.
    public let sources: [String: UUID]
    /// Fields whose reference points to an entry that no longer exists.
    public let brokenFields: Set<String>

    public init(rawValues: [String: String], sources: [String: UUID] = [:], brokenFields: Set<String> = []) {
        self.rawValues = rawValues
        self.sources = sources
        self.brokenFields = brokenFields
    }

    /// The whole field is a single reference, so it mirrors another entry.
    public func isReference(_ field: String) -> Bool {
        sources[field] != nil || brokenFields.contains(field)
    }
}

/// A field that mirrors another entry's field: `{REF:P@I:<UUID>}` ("the password of the entry with this UUID").
public struct VaultFieldReference: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case title = "T"
        case username = "U"
        case password = "P"
        case url = "A"
        case notes = "N"

        /// KeePass's name of the field (`VaultEntryReferences.password`…).
        public var storedName: String {
            switch self {
            case .title: return VaultEntryReferences.title
            case .username: return VaultEntryReferences.username
            case .password: return VaultEntryReferences.password
            case .url: return VaultEntryReferences.url
            case .notes: return VaultEntryReferences.notes
            }
        }
    }

    public let field: Field
    public let entryID: UUID

    public init(field: Field, entryID: UUID) {
        self.field = field
        self.entryID = entryID
    }

    /// Reads a value that is exactly one reference by UUID; nil for anything else.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix("{REF:"), trimmed.hasSuffix("}"), trimmed.count > 9 else {
            return nil
        }
        let body = trimmed.dropFirst(5).dropLast()
        let parts = body.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            return nil
        }
        let target = parts[0].split(separator: "@")
        guard target.count == 2, target[1] == "I", let field = Field(rawValue: String(target[0])) else {
            return nil
        }
        var hex = parts[1].replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        for index in [8, 13, 18, 23] {
            hex.insert("-", at: hex.index(hex.startIndex, offsetBy: index))
        }
        guard let id = UUID(uuidString: hex) else {
            return nil
        }
        self.init(field: field, entryID: id)
    }

    /// `{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}`, the form KeePass writes.
    public var text: String {
        "{REF:\(field.rawValue)@I:\(entryID.uuidString.replacingOccurrences(of: "-", with: ""))}"
    }
}

extension VaultEntry {
    /// The shown (resolved) value of a standard field.
    public func value(of field: VaultFieldReference.Field) -> String {
        switch field {
        case .title: return title
        case .username: return username ?? ""
        case .password: return password ?? ""
        case .url: return url?.absoluteString ?? ""
        case .notes: return notes ?? ""
        }
    }

    /// True when this entry, directly or through the entries it references, uses a field of `id`.
    public func references(_ id: UUID, in entries: [VaultEntry]) -> Bool {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = []
        var queue = Array((references?.sources ?? [:]).values)
        while let next = queue.popLast() {
            if next == id {
                return true
            }
            guard visited.insert(next).inserted, let entry = byID[next] else {
                continue
            }
            queue.append(contentsOf: (entry.references?.sources ?? [:]).values)
        }
        return false
    }
}
