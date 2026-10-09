import Foundation

/// Identity of the database file as last read or written by KeeMac.
/// Every KDBX save re-randomises the header, so a different hash means someone else wrote the file.
public struct VaultFileFingerprint: Equatable, Sendable, Codable {
    public let sha256: String
    public let size: Int64

    public init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

public enum VaultDiskStatus: Equatable, Sendable {
    case unchanged
    case changed
    case missing
}

public struct VaultMergeChange: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case added
        case updated
        case deleted
        case moved
    }

    public let entryID: UUID
    public let kind: Kind
    public let title: String
    public let groupPath: String
    public let previousGroupPath: String?
    public let changedFields: [String]
    /// Both sides edited the entry; the losing version was kept in its history.
    public let isConflict: Bool

    public var id: String { "\(kind.rawValue)-\(entryID.uuidString)" }

    public init(
        entryID: UUID,
        kind: Kind,
        title: String,
        groupPath: String,
        previousGroupPath: String? = nil,
        changedFields: [String] = [],
        isConflict: Bool = false
    ) {
        self.entryID = entryID
        self.kind = kind
        self.title = title
        self.groupPath = groupPath
        self.previousGroupPath = previousGroupPath
        self.changedFields = changedFields
        self.isConflict = isConflict
    }
}

public struct VaultMergeSummary: Equatable, Sendable {
    public let changes: [VaultMergeChange]

    public init(changes: [VaultMergeChange] = []) {
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }

    public var conflictCount: Int {
        changes.filter(\.isConflict).count
    }

    public var changedEntryIDs: Set<UUID> {
        Set(changes.filter { $0.kind != .deleted }.map(\.entryID))
    }

    public func count(of kind: VaultMergeChange.Kind) -> Int {
        changes.filter { $0.kind == kind }.count
    }
}

/// Another database file to merge into the open one.
public struct VaultMergeSource: Equatable, Sendable {
    public let fileURL: URL
    /// `nil` together with `keyFileURL == nil` opens the file with the open database's key
    /// (conflicting copies left by sync services are encrypted with it).
    public let masterPassword: String?
    public let keyFileURL: URL?

    public init(fileURL: URL, masterPassword: String? = nil, keyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.masterPassword = masterPassword
        self.keyFileURL = keyFileURL
    }
}

/// A copy of the database a sync service saved next to it instead of updating the file.
public struct VaultConflictCopy: Equatable, Sendable, Identifiable {
    public enum Provider: String, Sendable {
        case iCloud = "iCloud"
        case dropbox = "Dropbox"
        case syncthing = "Syncthing"
    }

    public let fileURL: URL
    public let provider: Provider
    public let modifiedAt: Date?

    public var id: String { fileURL.standardizedFileURL.path }

    public init(fileURL: URL, provider: Provider, modifiedAt: Date?) {
        self.fileURL = fileURL
        self.provider = provider
        self.modifiedAt = modifiedAt
    }
}
