import Foundation

/// Entries (or one group with its subgroups) on their way from one open database to another.
/// Field references are already replaced by their values: links only work inside one database.
public struct VaultTransferPayload: Sendable, Equatable {
    /// A KeePass XML tree holding the nodes with their original UUIDs, history and attachments.
    public let xmlData: Data
    /// Entries that travel, by their UUIDs in the source database.
    public let entryIDs: [UUID]
    /// Set when a whole group travels.
    public let groupTitle: String?
    /// Fields that were references and now hold plain values.
    public let linkedFieldCount: Int

    public init(xmlData: Data, entryIDs: [UUID], groupTitle: String?, linkedFieldCount: Int) {
        self.xmlData = xmlData
        self.entryIDs = entryIDs
        self.groupTitle = groupTitle
        self.linkedFieldCount = linkedFieldCount
    }
}

/// The target database already has an entry like an incoming one.
public struct VaultTransferConflict: Sendable, Equatable, Identifiable {
    /// The incoming entry's UUID in the source database.
    public let id: UUID
    /// The entry already in the target database.
    public let existingID: UUID
    /// Same UUID: a copy of the same entry (a backup of the same database). Otherwise only title and username match.
    public let isSameEntry: Bool
    public let title: String
    public let username: String
    public let incomingModifiedAt: Date?
    public let existingTitle: String
    public let existingUsername: String
    public let existingModifiedAt: Date?

    public init(
        id: UUID,
        existingID: UUID,
        isSameEntry: Bool,
        title: String,
        username: String,
        incomingModifiedAt: Date?,
        existingTitle: String,
        existingUsername: String,
        existingModifiedAt: Date?
    ) {
        self.id = id
        self.existingID = existingID
        self.isSameEntry = isSameEntry
        self.title = title
        self.username = username
        self.incomingModifiedAt = incomingModifiedAt
        self.existingTitle = existingTitle
        self.existingUsername = existingUsername
        self.existingModifiedAt = existingModifiedAt
    }
}

public enum VaultTransferDecision: String, Sendable, Equatable {
    /// Same entry: update it, keeping the current version in its history. Different entry: move it to the trash.
    case replace
    /// Add the incoming entry next to the existing one (with a new UUID if they share one).
    case keepBoth
    /// Leave the incoming entry where it is.
    case skip
}

public struct VaultTransferResult: Sendable, Equatable {
    /// Incoming entries that were added or replaced something, by their source UUIDs.
    public let receivedEntryIDs: [UUID]
    /// The group created in the target database when a whole group travelled.
    public let groupPath: String?

    public init(receivedEntryIDs: [UUID], groupPath: String?) {
        self.receivedEntryIDs = receivedEntryIDs
        self.groupPath = groupPath
    }
}
