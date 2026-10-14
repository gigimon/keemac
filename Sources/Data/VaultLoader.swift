import Domain
import Foundation

public struct LoadedVault: Sendable, Equatable {
    public let summary: VaultSummary
    public let groups: [VaultGroup]
    public let entries: [VaultEntry]

    public init(summary: VaultSummary, groups: [VaultGroup], entries: [VaultEntry]) {
        self.summary = summary
        self.groups = groups
        self.entries = entries
    }
}

public protocol VaultLoading: Sendable {
    func loadVault(from fileURL: URL, masterPassword: String, keyFileURL: URL?) async throws -> LoadedVault
}

public protocol VaultEditing: Sendable {
    func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws -> LoadedVault
    func updateEntry(id: UUID, form: VaultEntryForm) async throws -> LoadedVault
    func duplicateEntry(id: UUID, referencingCredentials: Bool) async throws -> (vault: LoadedVault, entryID: UUID)
    func moveEntry(id: UUID, toGroupPath groupPath: String?) async throws -> LoadedVault
    func deleteEntry(id: UUID) async throws -> LoadedVault
    /// Removes these entries from the trash for good in one undo step.
    func emptyTrash(ids: [UUID]) async throws -> LoadedVault
    func restoreEntry(id: UUID) async throws -> LoadedVault
    func revertEntry(id: UUID, toHistoryRevisionAt index: Int) async throws -> LoadedVault
    /// Nil `autoType` leaves the group's Auto-Type settings as they are (inherit for a new group).
    func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?, autoType: VaultGroupAutoType?) async throws -> LoadedVault
    func updateGroup(path: String, title: String, iconID: Int?, autoType: VaultGroupAutoType?) async throws -> LoadedVault
    func moveGroup(path: String, toParentPath parentPath: String?) async throws -> LoadedVault
    func deleteGroup(path: String) async throws -> LoadedVault
    func recordEntryUsage(id: UUID) async throws -> LoadedVault
    /// Moves an HOTP entry to its next code; saved right away, without history or undo.
    func advanceHOTPCounter(id: UUID) async throws -> LoadedVault
}

extension VaultEditing {
    public func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?) async throws -> LoadedVault {
        try await createGroup(inParentPath: parentPath, title: title, iconID: iconID, autoType: nil)
    }

    public func updateGroup(path: String, title: String, iconID: Int?) async throws -> LoadedVault {
        try await updateGroup(path: path, title: title, iconID: iconID, autoType: nil)
    }
}

public protocol VaultSessionControlling: Sendable {
    func savePendingChanges() async throws
    func clearLoadedSession() async
}

public struct VaultMergeResult: Sendable, Equatable {
    public let vault: LoadedVault
    public let summary: VaultMergeSummary

    public init(vault: LoadedVault, summary: VaultMergeSummary) {
        self.vault = vault
        self.summary = summary
    }
}

public protocol VaultSynchronizing: Sendable {
    func diskStatus() async -> VaultDiskStatus
    func previewExternalChanges() async throws -> VaultMergeSummary
    func mergeExternalChanges() async throws -> VaultMergeResult
    func takePendingMergeSummary() async -> VaultMergeSummary?
    func takeRestoreSummary() async -> VaultMergeSummary?
    func prepareMerge(from sources: [VaultMergeSource]) async throws -> VaultMergeSummary
    func commitPreparedMerge() async throws -> VaultMergeResult
    func discardPreparedMerge() async
    func discardSnapshot(for fileURL: URL) async
}

public protocol VaultCreating: Sendable {
    func createVault(options: VaultCreationOptions) async throws -> LoadedVault
}

public protocol VaultDatabaseManaging: Sendable {
    func databaseSettings() async throws -> VaultDatabaseSettings
    /// Name, description, templates group, cipher and key derivation.
    func updateDatabaseSettings(_ settings: VaultDatabaseSettings) async throws -> LoadedVault
    func changeMasterKey(newPassword: String, keyFileURL: URL?) async throws
    /// Checks the current key first; returns the key file the database now opens with (nil for none).
    /// A generated key file is written only when the rest of the change can go ahead.
    func changeMasterKey(currentPassword: String, currentKeyFileURL: URL?, newPassword: String?, keyFile: VaultKeyFileChange) async throws -> URL?
    func maintenanceStatus() async throws -> VaultMaintenanceStatus
    /// Turning the bin off without a disposal keeps its contents as a normal group.
    func updateRecycleBin(enabled: Bool, group: VaultRecycleBinGroup, disposal: VaultRecycleBinDisposal?) async throws -> LoadedVault
    /// New limits apply as entries change; existing history isn't trimmed.
    func updateHistoryLimits(_ limits: VaultHistoryLimits) async throws -> LoadedVault
    /// Custom icons no entry, history version or group uses.
    func removeUnusedCustomIcons() async throws -> LoadedVault
}

/// Master keys with a hardware key part (YubiKey HMAC-SHA1 challenge-response, KeePassXC's KDBX 4 scheme).
public protocol VaultHardwareKeyManaging: Sendable {
    /// `knownResponse` (stored for Touch ID) answers the challenge when it still matches the file's KDF seed.
    func loadVault(
        from fileURL: URL,
        masterPassword: String,
        keyFileURL: URL?,
        hardwareKey: VaultHardwareKey?,
        knownResponse: VaultHardwareKeyResponse?
    ) async throws -> LoadedVault
    func changeMasterKey(
        currentPassword: String,
        currentKeyFileURL: URL?,
        newPassword: String?,
        keyFile: VaultKeyFileChange,
        hardwareKey: VaultHardwareKeyChange
    ) async throws -> URL?
    /// The answer for the seed the file is written with; nil without a hardware key.
    func hardwareKeyResponse() async -> VaultHardwareKeyResponse?
    func currentHardwareKey() async -> VaultHardwareKey?
}

/// Data KeePassXC-Browser needs, stored the way KeePassXC stores it.
public protocol VaultBrowserAccessing: Sendable {
    /// Hex SHA-256 of the root group UUID (32 lowercase hex digits), KeePassXC's database hash.
    func browserDatabaseHash() async -> String?
    func browserAssociations() async -> [VaultBrowserAssociation]
    func storeBrowserAssociation(id: String, key: String, created: String) async throws -> LoadedVault
    func removeBrowserAssociation(id: String) async throws -> LoadedVault
    /// Entries outside the recycle bin that aren't hidden from the browser.
    func browserCandidates() async -> [VaultBrowserCandidate]
    /// Saves the user's answer to an access request into each entry's `KeePassXC-Browser Settings`.
    /// Nil when nothing had to be written.
    func rememberBrowserAccess(allowed: [UUID], denied: [UUID], hosts: [String]) async throws -> LoadedVault?
    /// The root group and its subgroups without the recycle bin.
    func browserGroupTree() async -> VaultBrowserGroup?
    /// A group by titles below the root (`["Web", "Shops"]`), nil when it doesn't exist.
    func browserGroup(atPath titles: [String]) async -> VaultBrowserGroup?
    /// Creates the missing groups along the path and returns the last one.
    func createBrowserGroup(atPath titles: [String]) async throws -> (vault: LoadedVault, group: VaultBrowserGroup)
    func addBrowserLogin(_ login: VaultBrowserNewLogin) async throws -> (vault: LoadedVault, entryID: UUID)
    /// Follows a password `{REF:P@I:…}` to the entry that holds the password.
    func browserLoginTarget(for id: UUID) async -> VaultBrowserLoginTarget?
    /// Sets the target's password (and username unless it is a reference), keeping the old values in history.
    func updateBrowserLogin(id: UUID, username: String, password: String) async throws -> LoadedVault
    /// Sets a downloaded site icon as the entry's custom icon, reusing an identical one. Nil when the entry is gone.
    func setBrowserEntryIcon(id: UUID, imageData: Data) async throws -> LoadedVault?
}

/// Import from and export to files of other password managers.
public protocol VaultTransferring: Sendable {
    /// Adds what was read from a file as one undo step.
    func importEntries(_ file: VaultImportFile, options: VaultImportOptions) async throws -> (vault: LoadedVault, result: VaultImportResult)
    /// The unencrypted file and how many entries it holds.
    func exportDatabase(_ options: VaultExportOptions) async throws -> (data: Data, entryCount: Int)
    /// True when the password (with the key file) is this database's master key.
    func verifyMasterKey(password: String, keyFileURL: URL?) async -> Bool
}

/// Moving and copying entries between two open databases, each with its own loader.
/// The source packs a payload, the target reports conflicts and receives it; after a move the source trashes the originals.
public protocol VaultTransferringBetweenDatabases: Sendable {
    func makeTransferPayload(entryIDs: [UUID], groupPath: String?) async throws -> VaultTransferPayload
    func transferConflicts(for payload: VaultTransferPayload) async throws -> [VaultTransferConflict]
    func receiveTransfer(
        _ payload: VaultTransferPayload,
        toGroupPath groupPath: String?,
        decisions: [UUID: VaultTransferDecision]
    ) async throws -> (vault: LoadedVault, result: VaultTransferResult)
    func trashTransferredEntries(_ entryIDs: [UUID], groupPath: String?) async throws -> LoadedVault
}

/// Values Auto-Type needs from KeePassKit.
public protocol VaultAutoTyping: Sendable {
    /// Evaluates a placeholder such as `{REF:U@I:…}` for an entry; nil when it can't be resolved.
    func resolveAutoTypePlaceholder(_ placeholder: String, entryID: UUID) async -> String?
}

/// Undo and redo of the user's own changes in the open database (not merges, usage counts or browser settings).
public protocol VaultUndoing: Sendable {
    func undoState() async -> VaultUndoState
    func undo() async throws -> LoadedVault
    func redo() async throws -> LoadedVault
}
