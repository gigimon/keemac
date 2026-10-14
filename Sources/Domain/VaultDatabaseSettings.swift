import Foundation

public enum VaultKDFAlgorithm: String, Sendable, CaseIterable, Equatable {
    case argon2d
    case argon2id
    case aes

    public var displayName: String {
        switch self {
        case .argon2d: return "Argon2d"
        case .argon2id: return "Argon2id"
        case .aes: return "AES-KDF"
        }
    }

    public var isArgon: Bool {
        self == .argon2d || self == .argon2id
    }
}

/// Database-level settings backed by the KDBX `Meta` section and key derivation
/// parameters. Password/key-file changes are handled separately.
public struct VaultDatabaseSettings: Sendable, Equatable {
    public var name: String
    public var details: String
    public var kdf: VaultKDFAlgorithm
    public var argonIterations: UInt64
    public var argonMemoryMiB: UInt64
    public var argonParallelism: UInt32
    public var aesRounds: UInt64
    /// Entry templates group; nil when none is set.
    public var templatesGroupPath: String?
    /// The cipher that encrypts the file's content; applied together with the key derivation.
    public var cipher: VaultCipher

    public init(
        name: String = "",
        details: String = "",
        kdf: VaultKDFAlgorithm = .argon2id,
        argonIterations: UInt64 = 10,
        argonMemoryMiB: UInt64 = 64,
        argonParallelism: UInt32 = 2,
        aesRounds: UInt64 = 600_000,
        templatesGroupPath: String? = nil,
        cipher: VaultCipher = .chacha20
    ) {
        self.name = name
        self.details = details
        self.kdf = kdf
        self.argonIterations = argonIterations
        self.argonMemoryMiB = argonMemoryMiB
        self.argonParallelism = argonParallelism
        self.aesRounds = aesRounds
        self.templatesGroupPath = templatesGroupPath
        self.cipher = cipher
    }
}

/// How many versions each entry keeps in its history; nil is unlimited.
public struct VaultHistoryLimits: Sendable, Equatable {
    public var maxItems: Int?
    /// Megabytes of history per entry.
    public var maxSizeMB: Int?

    public init(maxItems: Int? = 10, maxSizeMB: Int? = 6) {
        self.maxItems = maxItems
        self.maxSizeMB = maxSizeMB
    }
}

/// Which group serves as the recycle bin.
public enum VaultRecycleBinGroup: Sendable, Equatable {
    /// The group the database already uses (KeePassKit creates one on the first delete if there is none).
    case current
    case existing(path: String)
    /// A new "Recycle Bin" group under the root.
    case new
}

/// What happens to the recycle bin's contents when it is turned off.
public enum VaultRecycleBinDisposal: Sendable, Equatable {
    /// Deletes everything in it for good, and the group itself.
    case empty
    /// It becomes an ordinary group with everything still in it.
    case keepAsGroup
}

/// What the maintenance cards show besides the editable settings.
public struct VaultMaintenanceStatus: Sendable, Equatable {
    public var usesRecycleBin: Bool
    /// The recycle bin group; nil when there is none yet.
    public var recycleBinPath: String?
    /// Entries in the recycle bin, including those in its subgroups.
    public var recycleBinEntryCount: Int
    public var history: VaultHistoryLimits
    public var unusedIconCount: Int
    public var unusedIconBytes: Int
    public var masterKeyChangedAt: Date?
    /// The master key includes a password (it may be a key file alone).
    public var hasPassword: Bool

    public init(
        usesRecycleBin: Bool = true,
        recycleBinPath: String? = nil,
        recycleBinEntryCount: Int = 0,
        history: VaultHistoryLimits = VaultHistoryLimits(),
        unusedIconCount: Int = 0,
        unusedIconBytes: Int = 0,
        masterKeyChangedAt: Date? = nil,
        hasPassword: Bool = true
    ) {
        self.usesRecycleBin = usesRecycleBin
        self.recycleBinPath = recycleBinPath
        self.recycleBinEntryCount = recycleBinEntryCount
        self.history = history
        self.unusedIconCount = unusedIconCount
        self.unusedIconBytes = unusedIconBytes
        self.masterKeyChangedAt = masterKeyChangedAt
        self.hasPassword = hasPassword
    }
}

/// The key file part of a new master key.
public enum VaultKeyFileChange: Sendable, Equatable {
    /// The key file the database is open with (or none).
    case keep
    /// An existing key file.
    case use(URL)
    /// A new key file written to this place when the change is applied.
    case generate(URL)
    /// No key file; the password alone opens the database.
    case remove
}

public enum VaultCipher: String, Sendable, CaseIterable, Equatable {
    case aes256
    case chacha20
    case twofish

    public var displayName: String {
        switch self {
        case .aes256: return "AES-256"
        case .chacha20: return "ChaCha20"
        case .twofish: return "Twofish"
        }
    }
}

/// Everything needed to create a new KDBX file.
public struct VaultCreationOptions: Sendable, Equatable {
    public var fileURL: URL
    public var name: String
    public var details: String
    public var masterPassword: String
    public var keyFileURL: URL?
    public var useTrash: Bool
    public var historyMaxItems: Int
    public var cipher: VaultCipher
    public var keyDerivation: VaultDatabaseSettings
    public var compress: Bool

    public init(
        fileURL: URL,
        name: String,
        details: String = "",
        masterPassword: String,
        keyFileURL: URL? = nil,
        useTrash: Bool = true,
        historyMaxItems: Int = 10,
        cipher: VaultCipher = .chacha20,
        keyDerivation: VaultDatabaseSettings = VaultDatabaseSettings(),
        compress: Bool = true
    ) {
        self.fileURL = fileURL
        self.name = name
        self.details = details
        self.masterPassword = masterPassword
        self.keyFileURL = keyFileURL
        self.useTrash = useTrash
        self.historyMaxItems = historyMaxItems
        self.cipher = cipher
        self.keyDerivation = keyDerivation
        self.compress = compress
    }
}

/// Unencrypted facts read from a KDBX file header before unlocking.
public struct VaultFileInfo: Sendable, Equatable {
    public let majorVersion: Int
    public let minorVersion: Int
    public let cipher: VaultCipher?
    public let kdf: VaultKDFAlgorithm?

    public init(majorVersion: Int, minorVersion: Int, cipher: VaultCipher?, kdf: VaultKDFAlgorithm?) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.cipher = cipher
        self.kdf = kdf
    }

    public var formatName: String {
        "KDBX \(majorVersion).\(minorVersion)"
    }

    public var summary: String {
        [formatName, kdf?.displayName, cipher?.displayName].compactMap { $0 }.joined(separator: " · ")
    }
}
