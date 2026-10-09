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

    public init(
        secret: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: VaultOTPAlgorithm = .sha1,
        storageStyle: VaultOTPStorageStyle = .otpAuth
    ) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.storageStyle = storageStyle
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
        sshAgent: VaultSSHAgentSettings? = nil
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
