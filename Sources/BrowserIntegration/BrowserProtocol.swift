import Domain
import Foundation

/// Constants of the KeePassXC-Browser native messaging protocol.
public enum BrowserProtocol {
    /// Native messaging host name; the extension only talks to this one.
    public static let hostName = "org.keepassxc.keepassxc_browser"
    /// Reported to the extension. 2.7.x turns on TOTP and the current message flow,
    /// 2.7.7 would turn on passkeys, which KeeMac doesn't support.
    public static let compatibleVersion = "2.7.6"
    /// Messages larger than this are dropped (Chrome sends at most 64 MB, real requests are a few KB).
    public static let maximumMessageSize = 1 << 20

    /// The socket `keemac-proxy` connects to, in the per-user temporary directory.
    public static var socketPath: String {
        socketPath(named: "KeeMac.BrowserServer")
    }

    /// A socket of that name in the per-user temporary directory ("KeeMac Dev" uses its own).
    public static func socketPath(named name: String) -> String {
        temporaryDirectory + name
    }

    private static var temporaryDirectory: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else {
            return NSTemporaryDirectory()
        }
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("/") ? path : path + "/"
    }
}

public enum BrowserAction {
    static let changePublicKeys = "change-public-keys"
    static let getDatabaseHash = "get-databasehash"
    static let associate = "associate"
    static let testAssociate = "test-associate"
    static let getLogins = "get-logins"
    static let getTOTP = "get-totp"
    static let lockDatabase = "lock-database"
    static let setLogin = "set-login"
    static let getDatabaseGroups = "get-database-groups"
    static let createNewGroup = "create-new-group"
    static let generatePassword = "generate-password"
    public static let databaseLocked = "database-locked"
    public static let databaseUnlocked = "database-unlocked"
}

/// Error codes the extension understands (KeePassXC `BrowserMessageBuilder.h`).
public enum BrowserErrorCode: Int, Sendable {
    case databaseNotOpened = 1
    case databaseHashNotReceived = 2
    case clientPublicKeyNotReceived = 3
    case cannotDecryptMessage = 4
    case actionCancelledOrDenied = 6
    case cannotEncryptMessage = 7
    case associationFailed = 8
    case encryptionKeyUnrecognized = 10
    case incorrectAction = 12
    case emptyMessageReceived = 13
    case noURLProvided = 14
    case noLoginsFound = 15
    case noGroupsFound = 16
    case cannotCreateNewGroup = 17
    case noValidUUIDProvided = 18
    case cannotUseReferences = 34

    var message: String {
        switch self {
        case .databaseNotOpened: return "Database not opened"
        case .databaseHashNotReceived: return "Database hash not available"
        case .clientPublicKeyNotReceived: return "Client public key not received"
        case .cannotDecryptMessage: return "Cannot decrypt message"
        case .actionCancelledOrDenied: return "Action cancelled or denied"
        case .cannotEncryptMessage: return "Message encryption failed."
        case .associationFailed: return "KeePassXC association failed, try again"
        case .encryptionKeyUnrecognized: return "Encryption key is not recognized"
        case .incorrectAction: return "Incorrect action"
        case .emptyMessageReceived: return "Empty message received"
        case .noURLProvided: return "No URL provided"
        case .noLoginsFound: return "No logins found"
        case .noGroupsFound: return "No groups found"
        case .cannotCreateNewGroup: return "Cannot create new group"
        case .noValidUUIDProvided: return "No valid UUID provided"
        case .cannotUseReferences: return "Username or password cannot contain references"
        }
    }
}

/// What a page asks logins for.
public struct BrowserLoginQuery: Sendable, Equatable {
    public let siteURL: String
    public let formURL: String
    public let httpAuth: Bool

    public init(siteURL: String, formURL: String, httpAuth: Bool) {
        self.siteURL = siteURL
        self.formURL = formURL
        self.httpAuth = httpAuth
    }
}

/// One login sent to the extension.
public struct BrowserLogin: Sendable, Equatable {
    public let login: String
    public let password: String
    public let name: String
    public let uuid: UUID
    public let group: String
    public let totp: String?
    public let isExpired: Bool
    public let skipAutoSubmit: Bool?
    /// `KPH: ` fields, in entry order.
    public let stringFields: [BrowserStringField]

    public init(
        login: String,
        password: String,
        name: String,
        uuid: UUID,
        group: String,
        totp: String?,
        isExpired: Bool,
        skipAutoSubmit: Bool?,
        stringFields: [BrowserStringField]
    ) {
        self.login = login
        self.password = password
        self.name = name
        self.uuid = uuid
        self.group = group
        self.totp = totp
        self.isExpired = isExpired
        self.skipAutoSubmit = skipAutoSubmit
        self.stringFields = stringFields
    }
}

/// A login the extension asks to save, from its "Save credentials" banner.
public struct BrowserSaveRequest: Sendable, Equatable {
    public let siteURL: String
    public let formURL: String
    public let login: String
    public let password: String
    /// Set when the user chose to update this entry.
    public let entryID: UUID?
    /// Set when the user picked a group in the extension.
    public let groupID: UUID?
    /// The extension's "Download favicon after saving" option, for new entries.
    public let downloadFavicon: Bool

    public init(siteURL: String, formURL: String, login: String, password: String, entryID: UUID?, groupID: UUID?, downloadFavicon: Bool = false) {
        self.siteURL = siteURL
        self.formURL = formURL
        self.login = login
        self.password = password
        self.entryID = entryID
        self.groupID = groupID
        self.downloadFavicon = downloadFavicon
    }
}

public struct BrowserStringField: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// The open database as the browser integration sees it. Implemented by the UI layer.
@MainActor
public protocol BrowserVaultProviding: AnyObject, Sendable {
    var isVaultUnlocked: Bool { get }
    /// Hex SHA-256 of the root group UUID; the extension keys its associations by it.
    func browserDatabaseHash() async -> String?
    func browserAssociationKey(for id: String) async -> String?
    /// Asks the user to name a new connection and stores its identification key. Nil when declined.
    func associateBrowser(identificationKey: String) async -> String?
    func browserLogins(for query: BrowserLoginQuery) async -> [BrowserLogin]
    func browserTOTP(forEntry id: UUID) async -> String?
    func browserGroups() async -> VaultBrowserGroup?
    /// Finds or, after asking the user, creates the group at a `/`-separated path below the root.
    func createBrowserGroup(path: String) async -> VaultBrowserGroup?
    /// Adds a new entry or, after asking the user, updates an existing one. False when declined or failed.
    func saveBrowserLogin(_ request: BrowserSaveRequest) async -> Bool
    /// Shows the password generator and returns the password the user picked, nil when cancelled.
    func generateBrowserPassword() async -> String?
    func lockForBrowser()
    func showUnlockForBrowser()
}

extension UUID {
    /// 32 lowercase hex digits without dashes, KeePassXC's `uuidToHex`.
    public var browserHex: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public init?(browserHex: String) {
        var hex = browserHex.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        for index in [8, 13, 18, 23] {
            hex.insert("-", at: hex.index(hex.startIndex, offsetBy: index))
        }
        self.init(uuidString: hex)
    }
}
