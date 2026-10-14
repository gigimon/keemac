import Data
import Domain
import Foundation

/// Keeps additional databases apart from the main one in the browser, which sees all of them as one vault.
/// Their group paths get a prefix no title contains, and their entry and group IDs are XORed with a per-session salt,
/// so a backup copy of the main database (same UUIDs, same paths) never collides with it.
public enum DatabaseScope {
    public static let start: Character = "\u{E000}"
    static let end: Character = "\u{E001}"

    /// `Root.Work` of database `k1` → `k1` prefix + `Root.Work`. The first component still has no ".".
    public static func path(_ localPath: String, in key: String) -> String {
        "\(start)\(key)\(end)\(localPath)"
    }

    /// The additional database a scoped path belongs to; nil for the main database.
    public static func key(of path: String?) -> String? {
        split(path)?.key
    }

    static func split(_ path: String?) -> (key: String, localPath: String)? {
        guard let path, path.first == start, let close = path.firstIndex(of: end) else {
            return nil
        }
        let key = String(path[path.index(after: path.startIndex)..<close])
        return (key, String(path[path.index(after: close)...]))
    }

    /// Bijective: applying it twice with the same salt gives the original ID back.
    static func mapID(_ id: UUID, salt: UUID) -> UUID {
        var a = id.uuid
        let b = salt.uuid
        withUnsafeMutableBytes(of: &a) { bytes in
            withUnsafeBytes(of: b) { saltBytes in
                for index in 0..<16 {
                    bytes[index] ^= saltBytes[index]
                }
            }
        }
        return UUID(uuid: a)
    }
}

/// A database attached to the main one, shown under it in the sidebar.
public struct AdditionalDatabase: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case locked
        case unlocked
        case missing
    }

    public let id: String
    /// Nil when the file can't be found any more.
    public let url: URL?
    public let path: String
    public let keyFileURL: URL?
    public var state: State

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var name: String {
        (fileName as NSString).deletingPathExtension
    }
}

/// The last move or copy between databases, for the toast's Undo.
struct CompletedTransfer {
    let targetKey: String?
    let sourceKey: String?
    let isCopy: Bool
}

/// Entries or a group about to travel to another database; the browser shows its conflicts before committing.
public struct PreparedTransfer: Identifiable {
    public let id = UUID()
    public let sourceKey: String?
    public let targetKey: String?
    /// Target group in the browser's (scoped) paths; nil is the main database's root.
    public let targetGroupPath: String?
    public let isCopy: Bool
    let payload: VaultTransferPayload
    /// Source entries in the browser's IDs, and the group when a whole group travels.
    public let entryIDs: [UUID]
    public let groupPath: String?
    public let conflicts: [VaultTransferConflict]

    public var entryCount: Int { payload.entryIDs.count }
    public var groupTitle: String? { payload.groupTitle }
    public var linkedFieldCount: Int { payload.linkedFieldCount }
}

public enum AdditionalDatabaseError: LocalizedError {
    case alreadyOpen
    case notUnlocked

    public var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            return L("This database is already open.")
        case .notUnlocked:
            return L("Unlock the database first.")
        }
    }
}

extension AppViewModel {
    // MARK: - The browser's view

    /// The main database with every unlocked additional one, IDs and paths namespaced. Nil while locked.
    public var browserVault: LoadedVault? {
        guard case .loaded(let main) = loadState else {
            return nil
        }
        guard !additionalVaults.isEmpty else {
            return main
        }
        var groups = main.groups
        var entries = main.entries
        for database in additionalDatabases {
            guard let vault = additionalVaults[database.id], let salt = additionalSalts[database.id] else {
                continue
            }
            groups += vault.groups.map { $0.relabeled(id: DatabaseScope.mapID($0.id, salt: salt), path: DatabaseScope.path($0.path, in: database.id)) }
            entries += vault.entries.map { entry in
                let references = entry.references.map { references in
                    VaultEntryReferences(
                        rawValues: references.rawValues,
                        sources: references.sources.mapValues { DatabaseScope.mapID($0, salt: salt) },
                        brokenFields: references.brokenFields
                    )
                }
                return entry.relabeled(
                    id: DatabaseScope.mapID(entry.id, salt: salt),
                    groupPath: DatabaseScope.path(entry.groupPath, in: database.id),
                    references: references
                )
            }
        }
        return LoadedVault(summary: main.summary, groups: groups, entries: entries)
    }

    /// The root group of an unlocked additional database, in the browser's paths.
    public func additionalRootPath(_ key: String) -> String? {
        guard let vault = additionalVaults[key],
              let root = vault.groups.first(where: { !$0.path.contains(".") }) else {
            return nil
        }
        return DatabaseScope.path(root.path, in: key)
    }

    public func additionalSupportsEntryTypes(_ key: String) -> Bool {
        additionalVaults[key]?.summary.supportsEntryTypes ?? false
    }

    public func additionalUsesRecycleBin(_ key: String) -> Bool {
        additionalVaults[key]?.summary.usesRecycleBin ?? true
    }

    /// Which database an entry of the browser belongs to; nil is the main one.
    public func databaseKey(ofEntry id: UUID) -> String? {
        additionalTarget(forEntry: id)?.key
    }

    // MARK: - List

    /// Reads the list for the selected main database; any open additional database is locked first.
    func reloadAdditionalDatabases() {
        lockAllAdditionalDatabases()
        additionalDatabases = settingsStore.additionalDatabases(for: selectedVaultURL).map(makeAdditionalDatabase)
        activeDatabaseKey = nil
    }

    /// Notices files that disappeared or came back since the list was read.
    func refreshAdditionalDatabaseAvailability() {
        let stored = settingsStore.additionalDatabases(for: selectedVaultURL)
        additionalDatabases = stored.map { item in
            var database = makeAdditionalDatabase(item)
            if additionalVaults[item.key] != nil {
                database.state = .unlocked
            }
            return database
        }
    }

    private func makeAdditionalDatabase(_ stored: StoredAdditionalDatabase) -> AdditionalDatabase {
        let url = restoreURL(fromBookmarkData: stored.vaultBookmark)
        return AdditionalDatabase(
            id: stored.key,
            url: url,
            path: url?.path ?? stored.lastKnownPath,
            keyFileURL: stored.keyFileBookmark.flatMap(restoreURL(fromBookmarkData:)),
            state: url == nil ? .missing : .locked
        )
    }

    private func persistAdditionalDatabases(_ change: (inout [StoredAdditionalDatabase]) -> Void) {
        var stored = settingsStore.additionalDatabases(for: selectedVaultURL)
        change(&stored)
        settingsStore.setAdditionalDatabases(stored, for: selectedVaultURL)
    }

    /// Opens a database that isn't in the list yet; it is added only once it unlocks.
    public func addAdditionalDatabase(url: URL, password: String, keyFileURL: URL?) async throws {
        let identity = vaultIdentity(for: url)
        let isMain = selectedVaultURL.map(vaultIdentity) == identity
        let isListed = additionalDatabases.contains { $0.url.map(vaultIdentity) == identity }
        guard !isMain, !isListed else {
            throw AdditionalDatabaseError.alreadyOpen
        }
        guard let bookmark = bookmarkData(for: url) else {
            throw VaultError.fileReadFailure(path: url.path)
        }
        let key = "d" + UUID().uuidString.prefix(8).lowercased()
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: keyFileURL)
        persistAdditionalDatabases {
            $0.append(StoredAdditionalDatabase(
                key: key,
                vaultBookmark: bookmark,
                keyFileBookmark: keyFileURL.flatMap(bookmarkData(for:)),
                lastKnownPath: url.path
            ))
        }
        additionalDatabases.append(AdditionalDatabase(id: key, url: url, path: url.path, keyFileURL: keyFileURL, state: .unlocked))
        open(vault, loader: loader, key: key)
    }

    /// Unlocks a listed database with its password (Touch ID is never offered for additional databases).
    /// A different key file replaces the remembered one.
    public func unlockAdditionalDatabase(_ key: String, password: String, keyFileURL: URL?) async throws {
        guard let index = additionalDatabases.firstIndex(where: { $0.id == key }), let url = additionalDatabases[index].url else {
            throw VaultError.fileReadFailure(path: additionalDatabases.first { $0.id == key }?.path ?? "")
        }
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: keyFileURL)
        if keyFileURL != additionalDatabases[index].keyFileURL {
            persistAdditionalDatabases { list in
                if let stored = list.firstIndex(where: { $0.key == key }) {
                    list[stored].keyFileBookmark = keyFileURL.flatMap(bookmarkData(for:))
                }
            }
        }
        additionalDatabases[index] = AdditionalDatabase(id: key, url: url, path: url.path, keyFileURL: keyFileURL, state: .unlocked)
        open(vault, loader: loader, key: key)
    }

    private func open(_ vault: LoadedVault, loader: KeePassKitVaultLoader, key: String) {
        additionalLoaders[key] = loader
        additionalSalts[key] = UUID()
        additionalVaults[key] = vault
        registerUserActivity()
    }

    /// Locks one additional database; its pending changes (usage counts) are saved first.
    public func lockAdditionalDatabase(_ key: String) {
        guard let loader = additionalLoaders.removeValue(forKey: key) else {
            return
        }
        additionalVaults[key] = nil
        additionalSalts[key] = nil
        if activeDatabaseKey == key {
            activeDatabaseKey = nil
        }
        if let index = additionalDatabases.firstIndex(where: { $0.id == key }), additionalDatabases[index].state == .unlocked {
            additionalDatabases[index].state = .locked
        }
        lastTransfer = nil
        additionalLockTasks.append(Task {
            do {
                try await loader.savePendingChanges()
            } catch {
                SecureLogger.logUnlockFailure(error)
            }
            await loader.clearLoadedSession()
        })
    }

    func lockAllAdditionalDatabases() {
        for key in Array(additionalLoaders.keys) {
            lockAdditionalDatabase(key)
        }
    }

    func finishAdditionalLocks() async {
        let tasks = additionalLockTasks
        additionalLockTasks = []
        for task in tasks {
            await task.value
        }
    }

    /// Forgets a database: the file stays where it is.
    public func removeAdditionalDatabase(_ key: String) {
        lockAdditionalDatabase(key)
        additionalDatabases.removeAll { $0.id == key }
        persistAdditionalDatabases { $0.removeAll { $0.key == key } }
    }

    /// Points a missing database at the file the user found.
    public func locateAdditionalDatabase(_ key: String, at url: URL) throws {
        let identity = vaultIdentity(for: url)
        guard selectedVaultURL.map(vaultIdentity) != identity,
              !additionalDatabases.contains(where: { $0.id != key && $0.url.map(vaultIdentity) == identity }) else {
            throw AdditionalDatabaseError.alreadyOpen
        }
        guard let bookmark = bookmarkData(for: url) else {
            throw VaultError.fileReadFailure(path: url.path)
        }
        persistAdditionalDatabases { list in
            if let index = list.firstIndex(where: { $0.key == key }) {
                list[index].vaultBookmark = bookmark
                list[index].lastKnownPath = url.path
            }
        }
        refreshAdditionalDatabaseAvailability()
    }

    // MARK: - Routing edits

    func additionalTarget(forEntry id: UUID) -> (key: String, localID: UUID)? {
        for (key, vault) in additionalVaults {
            guard let salt = additionalSalts[key] else {
                continue
            }
            let local = DatabaseScope.mapID(id, salt: salt)
            if vault.entries.contains(where: { $0.id == local }) {
                return (key, local)
            }
        }
        return nil
    }

    /// `additionalTarget(forEntry:)` for many IDs, with one index per database instead of a scan per ID.
    func additionalTargets(forEntries ids: [UUID]) -> [(key: String, localID: UUID)?] {
        let indexes = additionalVaults.compactMap { key, vault in
            additionalSalts[key].map { (key: key, salt: $0, ids: Set(vault.entries.map(\.id))) }
        }
        return ids.map { id in
            for index in indexes {
                let local = DatabaseScope.mapID(id, salt: index.salt)
                if index.ids.contains(local) {
                    return (index.key, local)
                }
            }
            return nil
        }
    }

    func additionalTarget(forPath path: String?) -> (key: String, localPath: String)? {
        DatabaseScope.split(path)
    }

    func scopedEntryID(_ localID: UUID, in key: String) -> UUID {
        additionalSalts[key].map { DatabaseScope.mapID(localID, salt: $0) } ?? localID
    }

    /// Runs an edit in an additional database and shows its result.
    func editAdditional(_ key: String, _ edit: (KeePassKitVaultLoader) async throws -> LoadedVault) async throws {
        guard let loader = additionalLoaders[key] else {
            throw AdditionalDatabaseError.notUnlocked
        }
        let vault = try await edit(loader)
        guard additionalLoaders[key] != nil else {
            return
        }
        additionalVaults[key] = vault
        registerUserActivity()
        await refreshUndoState()
    }

    func performAdditionalUndoStep(_ key: String, redo: Bool) async {
        guard let loader = additionalLoaders[key] else {
            return
        }
        let state = await loader.undoState()
        guard let action = redo ? state.redoAction : state.undoAction else {
            return
        }
        do {
            try await editAdditional(key) { try await redo ? $0.redo() : $0.undo() }
            CopyFeedbackCenter.shared.show(redo ? L("Redone: \(action.title)") : L("Undone: \(action.title)"), duration: 2.4)
        } catch {
            SecureLogger.logUnlockFailure(error)
            CopyFeedbackCenter.shared.show(L("Couldn’t undo: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"), duration: 3)
        }
    }

    // MARK: - Moving and copying between databases

    private func transferLoader(_ key: String?) throws -> any VaultTransferringBetweenDatabases {
        if let key {
            guard let loader = additionalLoaders[key] else {
                throw AdditionalDatabaseError.notUnlocked
            }
            return loader
        }
        guard let loader = vaultLoader as? any VaultTransferringBetweenDatabases, loadState.isUnlocked else {
            throw AdditionalDatabaseError.notUnlocked
        }
        return loader
    }

    /// Packs entries (or a group) of one database for another and finds what the target already has.
    /// `entryIDs` and paths are the browser's; nil keys are the main database.
    public func prepareTransfer(entryIDs: [UUID], groupPath: String?, toGroupPath targetPath: String?, isCopy: Bool) async throws -> PreparedTransfer {
        let sourceKey = groupPath.flatMap(DatabaseScope.key(of:)) ?? entryIDs.first.flatMap { databaseKey(ofEntry: $0) }
        let targetKey = DatabaseScope.key(of: targetPath)
        let localIDs = entryIDs.map { id in additionalTarget(forEntry: id)?.localID ?? id }
        let localGroup = groupPath.map { DatabaseScope.split($0)?.localPath ?? $0 }
        let payload = try await transferLoader(sourceKey).makeTransferPayload(entryIDs: localIDs, groupPath: localGroup)
        let conflicts = try await transferLoader(targetKey).transferConflicts(for: payload)
        return PreparedTransfer(
            sourceKey: sourceKey,
            targetKey: targetKey,
            targetGroupPath: targetPath,
            isCopy: isCopy,
            payload: payload,
            entryIDs: entryIDs,
            groupPath: groupPath,
            conflicts: conflicts
        )
    }

    /// Adds the entries to the target and, for a move, sends the originals to the source's trash.
    /// Returns how many entries arrived.
    @discardableResult
    public func commitTransfer(_ transfer: PreparedTransfer, decisions: [UUID: VaultTransferDecision]) async throws -> Int {
        let targetLocalPath = transfer.targetGroupPath.map { DatabaseScope.split($0)?.localPath ?? $0 }
        let target = try transferLoader(transfer.targetKey)
        let (vault, result) = try await target.receiveTransfer(transfer.payload, toGroupPath: targetLocalPath, decisions: decisions)
        apply(vault, to: transfer.targetKey)

        if !transfer.isCopy {
            let skipped = Set(decisions.filter { $0.value == .skip }.map(\.key))
            let localGroup = transfer.groupPath.map { DatabaseScope.split($0)?.localPath ?? $0 }
            let sent = transfer.payload.entryIDs.filter { !skipped.contains($0) }
            // A group goes to the trash whole only when every entry left it.
            let source = try transferLoader(transfer.sourceKey)
            let sourceVault = try await source.trashTransferredEntries(sent, groupPath: skipped.isEmpty ? localGroup : nil)
            apply(sourceVault, to: transfer.sourceKey)
        }
        lastTransfer = CompletedTransfer(targetKey: transfer.targetKey, sourceKey: transfer.sourceKey, isCopy: transfer.isCopy)
        registerUserActivity()
        await refreshUndoState()
        return result.receivedEntryIDs.count
    }

    /// The toast's Undo: takes the transfer back in both databases, but only while it is still the last change in each.
    public func undoLastTransfer() async {
        guard let transfer = lastTransfer else {
            return
        }
        lastTransfer = nil
        do {
            let target = try undoLoader(transfer.targetKey)
            guard await target.undoState().undoAction == .receiveEntries else {
                return
            }
            if !transfer.isCopy {
                let source = try undoLoader(transfer.sourceKey)
                guard await source.undoState().undoAction == .sendEntries else {
                    return
                }
                apply(try await source.undo(), to: transfer.sourceKey)
            }
            apply(try await target.undo(), to: transfer.targetKey)
            await refreshUndoState()
            CopyFeedbackCenter.shared.show(L("Undone: \((transfer.isCopy ? L("Copy") : L("Move")))"), duration: 2.4)
        } catch {
            SecureLogger.logUnlockFailure(error)
            CopyFeedbackCenter.shared.show(L("Couldn’t undo: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"), duration: 3)
        }
    }

    /// Whether the toast's Undo can still take the last transfer back.
    public var canUndoLastTransfer: Bool {
        lastTransfer != nil
    }

    private func undoLoader(_ key: String?) throws -> any VaultUndoing {
        if let key {
            guard let loader = additionalLoaders[key] else {
                throw AdditionalDatabaseError.notUnlocked
            }
            return loader
        }
        guard let loader = vaultLoader as? any VaultUndoing else {
            throw AdditionalDatabaseError.notUnlocked
        }
        return loader
    }

    private func apply(_ vault: LoadedVault, to key: String?) {
        if let key {
            if additionalLoaders[key] != nil {
                additionalVaults[key] = vault
            }
        } else if loadState.isUnlocked {
            applyMainVault(vault)
        }
    }
}
