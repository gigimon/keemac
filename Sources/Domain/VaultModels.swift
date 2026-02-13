import Foundation

public struct VaultSummary: Equatable, Sendable {
    public let fileName: String
    public let groupCount: Int
    public let entryCount: Int

    public init(fileName: String, groupCount: Int, entryCount: Int) {
        self.fileName = fileName
        self.groupCount = groupCount
        self.entryCount = entryCount
    }
}

public struct VaultGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let iconPNGData: Data?
    public let iconID: Int?

    public init(id: UUID = UUID(), title: String, path: String, iconPNGData: Data? = nil, iconID: Int? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.iconPNGData = iconPNGData
        self.iconID = iconID
    }
}

public struct VaultEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let groupPath: String
    public let title: String
    public let username: String?
    public let password: String?
    public let url: URL?
    public let notes: String?
    public let customFields: [VaultCustomField]
    public let iconPNGData: Data?
    public let iconID: Int?
    public let otp: VaultOTPConfiguration?
    public let otpStorageStyle: VaultOTPStorageStyle?

    public init(
        id: UUID = UUID(),
        groupPath: String = "",
        title: String,
        username: String? = nil,
        password: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        customFields: [VaultCustomField] = [],
        iconPNGData: Data? = nil,
        iconID: Int? = nil,
        otp: VaultOTPConfiguration? = nil,
        otpStorageStyle: VaultOTPStorageStyle? = nil
    ) {
        self.id = id
        self.groupPath = groupPath
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.customFields = customFields
        self.iconPNGData = iconPNGData
        self.iconID = iconID
        self.otp = otp
        self.otpStorageStyle = otpStorageStyle
    }
}

public enum VaultOTPAlgorithm: String, Equatable, Sendable {
    case sha1
    case sha256
    case sha512
}

public struct VaultOTPConfiguration: Equatable, Sendable {
    public let secret: Data
    public let digits: Int
    public let period: Int
    public let timeBase: TimeInterval
    public let algorithm: VaultOTPAlgorithm

    public init(secret: Data, digits: Int, period: Int, timeBase: TimeInterval, algorithm: VaultOTPAlgorithm) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.timeBase = timeBase
        self.algorithm = algorithm
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
