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
    public var iconID: Int?
    public var customFields: [VaultCustomFieldForm]
    public var attachments: [VaultAttachment]
    public var otp: VaultOTPForm?

    public init(
        title: String,
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        iconID: Int? = nil,
        customFields: [VaultCustomFieldForm] = [],
        attachments: [VaultAttachment] = [],
        otp: VaultOTPForm? = nil
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.iconID = iconID
        self.customFields = customFields
        self.attachments = attachments
        self.otp = otp
    }
}
