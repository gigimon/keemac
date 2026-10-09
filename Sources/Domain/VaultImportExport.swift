import Foundation

/// Files KeeMac can import.
public enum VaultImportFormat: String, CaseIterable, Sendable, Identifiable {
    /// KeePass 1 database (`.kdb`), read with its password and imported like KeePass XML.
    case keePass1
    case keePassXML
    case bitwarden
    case onePassword
    case chrome
    case firefox
    case safari
    case lastPass
    case keePassXC

    public var id: String { rawValue }

    public var isCSV: Bool {
        self != .keePassXML && self != .keePass1
    }
}

/// One entry read from an imported file, before it is added to the database.
public struct VaultImportItem: Sendable, Equatable {
    public var title: String
    public var username: String
    public var password: String
    public var url: String
    public var notes: String
    /// `otpauth://` URI or a bare Base32 secret.
    public var otp: String
    public var tags: [String]
    public var customFields: [VaultCustomField]
    /// Folder titles below the file's top level (`["Work", "Servers"]`).
    public var folder: [String]
    public var isSecureNote: Bool

    public init(
        title: String,
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        otp: String = "",
        tags: [String] = [],
        customFields: [VaultCustomField] = [],
        folder: [String] = [],
        isSecureNote: Bool = false
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.otp = otp
        self.tags = tags
        self.customFields = customFields
        self.folder = folder
        self.isSecureNote = isSecureNote
    }

    /// Entries count as duplicates when title, username and URL match, ignoring case and spacing.
    public var duplicateKey: String {
        VaultImportItem.duplicateKey(title: title, username: username, url: url)
    }

    public static func duplicateKey(title: String, username: String, url: String) -> String {
        [title, username, url]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1F}")
    }
}

/// A file read for import: what it holds and the rows that couldn't be read.
public struct VaultImportFile: Sendable, Equatable {
    public let format: VaultImportFormat
    public let items: [VaultImportItem]
    /// 1-based line numbers of CSV rows that were skipped.
    public let skippedLines: [Int]
    /// The original file for KeePass XML, which is imported node by node to keep history and attachments.
    public let xmlData: Data?

    public init(format: VaultImportFormat, items: [VaultImportItem], skippedLines: [Int] = [], xmlData: Data? = nil) {
        self.format = format
        self.items = items
        self.skippedLines = skippedLines
        self.xmlData = xmlData
    }

    public var folderCount: Int {
        Set(items.compactMap { $0.folder.first }).count
    }
}

public enum VaultImportError: Error, Equatable, Sendable {
    /// A CSV whose columns match none of the supported apps.
    case unrecognizedCSV
    /// Not a readable CSV or KeePass XML (encrypted, damaged or another file type).
    case unreadable
    /// A CSV was read with a format whose columns it doesn't have.
    case formatMismatch
    /// A KeePass 1 database: read it again with `VaultImporter.readKeePass1` and its password or key file.
    case keePass1Locked
    /// The password or key file doesn't open the KeePass 1 database.
    case wrongKey
    /// A KeePass 1 database KeePassKit can't read (damaged, unsupported cipher or not a `.kdb`).
    case unreadableKeePass1
}

public enum VaultImportDestination: Sendable, Equatable {
    /// A new group at the root with this title.
    case newGroup(title: String)
    /// An existing group by path.
    case group(path: String)
}

public struct VaultImportOptions: Sendable, Equatable {
    public let destination: VaultImportDestination
    public let keepsFolders: Bool
    public let skipsDuplicates: Bool

    public init(destination: VaultImportDestination, keepsFolders: Bool, skipsDuplicates: Bool) {
        self.destination = destination
        self.keepsFolders = keepsFolders
        self.skipsDuplicates = skipsDuplicates
    }
}

public struct VaultImportResult: Sendable, Equatable {
    public let importedCount: Int
    /// The group that received the entries.
    public let groupPath: String
    public let entryIDs: [UUID]

    public init(importedCount: Int, groupPath: String, entryIDs: [UUID]) {
        self.importedCount = importedCount
        self.groupPath = groupPath
        self.entryIDs = entryIDs
    }
}

public enum VaultExportFormat: String, CaseIterable, Sendable {
    case keePassXML
    /// KeePassXC's CSV columns, which most password managers import.
    case csv

    public var fileExtension: String {
        self == .csv ? "csv" : "xml"
    }
}

public struct VaultExportOptions: Sendable, Equatable {
    public let format: VaultExportFormat
    /// Nil exports the whole database; otherwise this group with its subgroups.
    public let groupPath: String?
    public let includesTrash: Bool
    public let includesHistory: Bool
    public let includesAttachments: Bool

    public init(format: VaultExportFormat, groupPath: String?, includesTrash: Bool, includesHistory: Bool, includesAttachments: Bool) {
        self.format = format
        self.groupPath = groupPath
        self.includesTrash = includesTrash
        self.includesHistory = includesHistory
        self.includesAttachments = includesAttachments
    }
}
