import Foundation

public enum VaultOTPStorageStyle: String, Equatable, Sendable, CaseIterable {
    case otpAuth
    case native
}

public struct VaultCustomFieldForm: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String
    public var isProtected: Bool

    public init(id: UUID = UUID(), key: String, value: String, isProtected: Bool) {
        self.id = id
        self.key = key
        self.value = value
        self.isProtected = isProtected
    }
}

public struct VaultOTPForm: Equatable, Sendable {
    public var secret: String
    public var digits: Int
    public var period: Int
    public var algorithm: VaultOTPAlgorithm
    public var storageStyle: VaultOTPStorageStyle
    public var kind: VaultOTPKind
    /// HOTP only: the counter of the next code.
    public var counter: Int

    public init(
        secret: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: VaultOTPAlgorithm = .sha1,
        storageStyle: VaultOTPStorageStyle = .otpAuth,
        kind: VaultOTPKind = .totp,
        counter: Int = 0
    ) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.storageStyle = storageStyle
        self.kind = kind
        self.counter = counter
    }
}

public struct VaultEntryForm: Equatable, Sendable {
    public var title: String
    public var username: String
    public var password: String
    public var url: String
    public var notes: String
    public var tags: [String]
    public var foregroundColorHex: String?
    public var backgroundColorHex: String?
    public var iconID: Int?
    public var customFields: [VaultCustomFieldForm]
    public var attachments: [VaultAttachment]
    public var otp: VaultOTPForm?
    public var expiresAt: Date?
    public var checksPasswordQuality: Bool
    public var entryType: VaultEntryType
    public var templateName: String?
    /// Nil removes the entry's SSH agent settings.
    public var sshAgent: VaultSSHAgentSettings?
    /// Nil leaves the entry's Auto-Type settings as they are (defaults for a new entry).
    public var autoType: VaultAutoTypeSettings?

    public init(
        title: String,
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        tags: [String] = [],
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        iconID: Int? = nil,
        customFields: [VaultCustomFieldForm] = [],
        attachments: [VaultAttachment] = [],
        otp: VaultOTPForm? = nil,
        expiresAt: Date? = nil,
        checksPasswordQuality: Bool = true,
        entryType: VaultEntryType = .login,
        templateName: String? = nil,
        sshAgent: VaultSSHAgentSettings? = nil,
        autoType: VaultAutoTypeSettings? = nil
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.tags = tags
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.iconID = iconID
        self.customFields = customFields
        self.attachments = attachments
        self.otp = otp
        self.expiresAt = expiresAt
        self.checksPasswordQuality = checksPasswordQuality
        self.entryType = entryType
        self.templateName = templateName
        self.sshAgent = sshAgent
        self.autoType = autoType
    }
}

/// What an undo step does; the UI turns it into "Undo Move to Trash".
public enum VaultUndoAction: String, Sendable, Equatable {
    case newEntry
    case editEntry
    case duplicateEntry
    case moveEntry
    case moveToTrash
    case deletePermanently
    case emptyTrash
    case restoreEntry
    case revertEntry
    case newGroup
    case editGroup
    case moveGroup
    case deleteGroup
    case saveLogin
    case updateLogin
    case importEntries
    /// Entries moved or copied in from another open database.
    case receiveEntries
    /// Entries moved out to another open database (they went to this database's trash).
    case sendEntries
}

public struct VaultUndoState: Sendable, Equatable {
    public let undoAction: VaultUndoAction?
    public let redoAction: VaultUndoAction?

    public init(undoAction: VaultUndoAction? = nil, redoAction: VaultUndoAction? = nil) {
        self.undoAction = undoAction
        self.redoAction = redoAction
    }

    public static let empty = VaultUndoState()
}

/// `otpauth://` URIs: `totp`, `hotp` (with `counter`) and Steam, written by KeePassXC as
/// `otpauth://totp/…&encoder=steam` (some apps use the `steam` host).
public enum VaultOTPURI {
    public static let steamDigits = 5
    public static let steamPeriod = 30

    /// The URI's settings as a form; nil when the text isn't an `otpauth://` URI.
    /// Settings missing from the URI or unreadable keep their values from `base`.
    public static func parse(_ text: String, base: VaultOTPForm? = nil) -> VaultOTPForm? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: trimmed) else {
            return nil
        }

        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        var form = base ?? VaultOTPForm(secret: "")
        form.secret = (items["secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        form.kind = .totp
        if let digits = items["digits"].flatMap(Int.init) {
            form.digits = digits
        }
        if let period = items["period"].flatMap(Int.init) {
            form.period = period
        }
        switch items["algorithm"]?.uppercased() {
        case "SHA256":
            form.algorithm = .sha256
        case "SHA512":
            form.algorithm = .sha512
        case "SHA1":
            form.algorithm = .sha1
        default:
            break
        }

        let host = components.host?.lowercased()
        if host == "hotp" {
            form.kind = .hotp
            // Counters past Int.max stay as high as the form can hold rather than going back to 0.
            let counter = items["counter"].map { $0.trimmingCharacters(in: .whitespaces) }
            form.counter = counter.flatMap(UInt64.init).map { Int(clamping: $0) } ?? 0
        } else if host == "steam" || items["encoder"]?.lowercased() == "steam" {
            form.kind = .steam
            form.digits = steamDigits
            form.period = steamPeriod
            form.algorithm = .sha1
        } else if base?.kind == .steam {
            // Steam's fixed settings don't carry over to a TOTP URI that leaves them out.
            form.digits = items["digits"].flatMap(Int.init) ?? 6
            form.period = items["period"].flatMap(Int.init) ?? 30
        }
        return form
    }

    /// Builds the URI for a Base32 secret.
    public static func make(
        kind: VaultOTPKind,
        secret: String,
        label: String,
        digits: Int,
        period: Int,
        algorithm: VaultOTPAlgorithm,
        counter: UInt64
    ) -> String {
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        let algorithmName = algorithm.rawValue.uppercased()
        switch kind {
        case .totp:
            return "otpauth://totp/\(encodedLabel)?secret=\(secret)&algorithm=\(algorithmName)&digits=\(digits)&period=\(period)"
        case .hotp:
            return "otpauth://hotp/\(encodedLabel)?secret=\(secret)&algorithm=\(algorithmName)&digits=\(digits)&counter=\(counter)"
        case .steam:
            return "otpauth://totp/\(encodedLabel)?secret=\(secret)&period=\(steamPeriod)&digits=\(steamDigits)&issuer=Steam&encoder=steam"
        }
    }
}
