import AppKit
import CryptoKit
import Domain
import Foundation
import KeePassKit
import UndoSupport

public actor KeePassKitVaultLoader: VaultLoading, VaultEditing, VaultSessionControlling, VaultDatabaseManaging, VaultCreating, VaultSynchronizing, VaultBrowserAccessing, VaultUndoing, VaultTransferring, VaultTransferringBetweenDatabases {
    private final class TreeEditingDelegate: NSObject, KPKTreeDelegate {
        let undoStack: KMUndoStack
        /// Set while merging: KeePassKit gets a throwaway manager, so merges never touch the user's undo steps.
        var mergeStack: KMUndoStack?

        init(undoStack: KMUndoStack) {
            self.undoStack = undoStack
        }

        func shouldEdit(_ tree: KPKTree) -> Bool {
            true
        }

        func undoManager(for tree: KPKTree) -> UndoManager {
            (mergeStack ?? undoStack).manager
        }

        func withoutUndo<T>(_ body: () throws -> T) rethrows -> T {
            mergeStack = KMUndoStack.discarding()
            defer { mergeStack = nil }
            return try body()
        }
    }

    private struct Session {
        let fileURL: URL
        let key: KPKCompositeKey
        let format: KPKDatabaseFormat
        let tree: KPKTree
        let editingDelegate: TreeEditingDelegate
    }

    private struct ResolvedOTP {
        let configuration: VaultOTPConfiguration
        let storageStyle: VaultOTPStorageStyle
    }

    private var session: Session?
    private var hasPendingUsageChanges = false
    /// What the file on disk looked like when KeeMac last read or wrote it.
    private var diskFingerprint: VaultFileFingerprint?
    /// The key the file on disk is encrypted with (differs from the session key while a master key change is being saved).
    private var diskKey: KPKCompositeKey?
    /// Changes merged in from disk during the last save, for the UI to report.
    private var pendingMergeSummary: VaultMergeSummary?

    /// Copies of the last file KeeMac wrote, used to undo overwrites made while the database was closed.
    /// `nil` disables snapshots (tests and helper instances).
    private let snapshotDirectory: URL?
    /// Changes restored from the snapshot during the last unlock, for the UI to report.
    private var pendingRestoreSummary: VaultMergeSummary?
    /// Other databases read by `prepareMerge(from:)`, waiting for the user to confirm the preview.
    /// `keepsMetadata` is set for other databases (opened with their own key): their name,
    /// encryption and other settings must not replace this database's.
    private var preparedMerge: [(tree: KPKTree, keepsMetadata: Bool)]?

    /// KeePassKit registers the inverse of every tree change here. Registration is off except inside
    /// `beginUndo`/`endUndo`, so merges, usage counts and browser settings never become undo steps.
    private let undoStack: KMUndoStack = {
        let stack = KMUndoStack(levels: 50)
        stack.disableRegistration()
        return stack
    }()
    /// Set when a save merged someone else's changes: inverse steps recorded before may no longer fit the tree.
    private var undoStackIsStale = false

    public static var defaultSnapshotDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KeeMac/Snapshots", isDirectory: true)
    }

    public init(snapshotDirectory: URL? = nil) {
        self.snapshotDirectory = snapshotDirectory
    }

    public func clearLoadedSession() async {
        undoStack.removeAllActions()
        session = nil
        hasPendingUsageChanges = false
        diskFingerprint = nil
        diskKey = nil
        pendingMergeSummary = nil
        pendingRestoreSummary = nil
        preparedMerge = nil
    }

    // MARK: - Synchronization

    public func diskStatus() async -> VaultDiskStatus {
        guard let currentSession = session else {
            return .unchanged
        }
        return currentDiskStatus(of: currentSession.fileURL)
    }

    /// Changes the file on disk would bring in, without applying them.
    public func previewExternalChanges() async throws -> VaultMergeSummary {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let (external, _, _) = try readTree(at: currentSession.fileURL, key: diskKey ?? currentSession.key)
        return VaultMergeDiff.predicted(
            local: Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL).entries,
            external: Self.mapTree(external, fileURL: currentSession.fileURL).entries,
            externalDeletedIDs: Set(external.deletedObjects.keys)
        )
    }

    /// Merges the file on disk into the open database and writes the result back when the disk copy lacks local changes.
    public func mergeExternalChanges() async throws -> VaultMergeResult {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard currentDiskStatus(of: currentSession.fileURL) == .changed else {
            return VaultMergeResult(vault: Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL), summary: VaultMergeSummary())
        }

        let merge = try mergeFromDisk(into: currentSession)
        clearUndoIfStale()
        if merge.diskLacksLocalChanges {
            try write(session: currentSession)
        } else {
            storeSnapshot(merge.diskData, for: currentSession.fileURL)
        }
        return VaultMergeResult(vault: Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL), summary: merge.summary)
    }

    /// Reads other databases and predicts what merging them would change. The files are kept
    /// in memory until `commitPreparedMerge()` or `discardPreparedMerge()`, so the KDF runs once.
    public func prepareMerge(from sources: [VaultMergeSource]) async throws -> VaultMergeSummary {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        preparedMerge = nil
        var prepared: [(tree: KPKTree, keepsMetadata: Bool)] = []
        for source in sources {
            let isOtherDatabase = source.masterPassword != nil || source.keyFileURL != nil
            let key: KPKCompositeKey
            if isOtherDatabase {
                key = try makeCompositeKey(masterPassword: source.masterPassword ?? "", keyFileURL: source.keyFileURL)
            } else {
                key = currentSession.key
            }
            prepared.append((try readTree(at: source.fileURL, key: key).0, isOtherDatabase))
        }
        preparedMerge = prepared
        let trees = prepared.map(\.tree)

        let combined = Self.newestEntries(in: trees, fileURL: currentSession.fileURL)
        return VaultMergeDiff.predicted(
            local: Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL).entries,
            external: combined,
            externalDeletedIDs: Set(trees.flatMap { $0.deletedObjects.keys })
        )
    }

    /// Merges the databases read by `prepareMerge(from:)` and saves the result.
    public func commitPreparedMerge() async throws -> VaultMergeResult {
        guard let currentSession = session, let prepared = preparedMerge else {
            throw VaultError.parseFailure(details: "Nothing is prepared to merge.")
        }
        preparedMerge = nil

        let before = Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
        let external = Self.newestEntries(in: prepared.map(\.tree), fileURL: currentSession.fileURL)
        for (tree, keepsMetadata) in prepared {
            let metadata = keepsMetadata ? currentSession.tree.metaData.map(MetadataSnapshot.init) : nil
            currentSession.editingDelegate.withoutUndo {
                currentSession.tree.synchronize(with: tree, mode: .synchronize, options: [])
                Self.keepHighestHOTPCounters(in: currentSession.tree, from: tree)
            }
            if let metadata, let meta = currentSession.tree.metaData {
                metadata.restore(into: meta)
            }
            Self.adoptRecycleBin(from: tree, into: currentSession.tree)
        }
        let after = Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
        let summary = VaultMergeDiff.applied(before: before.entries, after: after.entries, external: external)

        if !summary.isEmpty || Self.contentSignature(after) != Self.contentSignature(before) {
            undoStack.removeAllActions()
            try save(session: currentSession)
        }
        return VaultMergeResult(vault: Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL), summary: summary)
    }

    public func discardPreparedMerge() async {
        preparedMerge = nil
    }

    /// The latest version of every entry across several databases, as a merge of all of them would keep it.
    private static func newestEntries(in trees: [KPKTree], fileURL: URL) -> [VaultEntry] {
        var newest: [UUID: VaultEntry] = [:]
        for tree in trees {
            for entry in mapTree(tree, fileURL: fileURL).entries {
                if let current = newest[entry.id],
                   (current.modifiedAt ?? .distantPast) >= (entry.modifiedAt ?? .distantPast) {
                    continue
                }
                newest[entry.id] = entry
            }
        }
        return Array(newest.values)
    }

    /// Returns and clears the changes merged in while saving the last edit.
    public func takePendingMergeSummary() async -> VaultMergeSummary? {
        defer { pendingMergeSummary = nil }
        return pendingMergeSummary
    }

    private func currentDiskStatus(of fileURL: URL) -> VaultDiskStatus {
        guard let current = Self.fingerprint(ofFileAt: fileURL) else {
            return .missing
        }
        guard let known = diskFingerprint else {
            return .unchanged
        }
        return current == known ? .unchanged : .changed
    }

    private func mergeFromDisk(into session: Session) throws -> (summary: VaultMergeSummary, diskLacksLocalChanges: Bool, diskData: Data) {
        let (external, fingerprint, data) = try readTree(at: session.fileURL, key: diskKey ?? session.key)
        let before = Self.mapTree(session.tree, fileURL: session.fileURL)
        let externalVault = Self.mapTree(external, fileURL: session.fileURL)

        session.editingDelegate.withoutUndo {
            session.tree.synchronize(with: external, mode: .synchronize, options: [])
            Self.keepHighestHOTPCounters(in: session.tree, from: external)
            Self.adoptRecycleBin(from: external, into: session.tree)
        }

        let after = Self.mapTree(session.tree, fileURL: session.fileURL)
        if Self.contentSignature(after) != Self.contentSignature(before) {
            undoStackIsStale = true
        }
        diskFingerprint = fingerprint
        return (
            VaultMergeDiff.applied(before: before.entries, after: after.entries, external: externalVault.entries),
            Self.contentSignature(after) != Self.contentSignature(externalVault),
            data
        )
    }

    /// Synchronize merges nodes but not the metadata pointer to the recycle bin; take it over when
    /// the other device created the bin, otherwise entries it deleted look like plain moves.
    private static func adoptRecycleBin(from external: KPKTree, into tree: KPKTree) {
        guard let meta = tree.metaData, let externalMeta = external.metaData else {
            return
        }
        guard externalMeta.useTrash, let externalTrash = externalMeta.trashUuid else {
            return
        }
        let localTrashExists = meta.trashUuid.map { uuid in tree.allGroups.contains { $0.uuid == uuid } } ?? false
        guard !localTrashExists, tree.allGroups.contains(where: { $0.uuid == externalTrash }) else {
            return
        }
        meta.useTrash = true
        meta.trashUuid = externalTrash
    }

    /// Cheap structural identity used to decide whether a merged tree still differs from the disk copy.
    private static func contentSignature(_ vault: LoadedVault) -> Set<String> {
        var signature = Set(vault.groups.map { "g|\($0.id)|\($0.path)" })
        for entry in vault.entries {
            let modified = Int(entry.modifiedAt?.timeIntervalSince1970 ?? 0)
            signature.insert("e|\(entry.id)|\(modified)|\(entry.groupPath)|\(entry.isTrashed)")
        }
        return signature
    }

    private nonisolated static func fingerprint(ofFileAt fileURL: URL) -> VaultFileFingerprint? {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.uncached]) else {
            return nil
        }
        return fingerprint(of: data)
    }

    nonisolated static func fingerprint(of data: Data) -> VaultFileFingerprint {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return VaultFileFingerprint(sha256: digest, size: Int64(data.count))
    }

    /// Bumps the usage counter and last-access date in memory only. The change is
    /// written with the next save or by `savePendingChanges()` (called on lock).
    public func recordEntryUsage(id: UUID) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry was not found.")
        }

        entry.timeInfo.usageCount += 1
        entry.timeInfo.accessDate = Date()
        hasPendingUsageChanges = true
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    /// Moves an HOTP entry to its next code and saves. The counter isn't an edit the user
    /// would want back: no history version, no undo step.
    public func advanceHOTPCounter(id: UUID) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard let entry = Self.findEntry(in: currentSession.tree, id: id),
              let otp = Self.makeOTPConfiguration(from: entry)?.configuration,
              otp.kind == .hotp else {
            throw VaultError.parseFailure(details: "Entry has no counter-based one-time password.")
        }

        Self.setHOTPCounter(otp.counter + 1, on: entry)
        entry.timeInfo.modificationDate = Date()
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func savePendingChanges() async throws {
        guard hasPendingUsageChanges, let currentSession = session else {
            return
        }
        try save(session: currentSession)
    }

    public func loadVault(from fileURL: URL, masterPassword: String, keyFileURL: URL?) async throws -> LoadedVault {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultError.fileReadFailure(path: fileURL.path)
        }

        if let keyFileURL {
            guard FileManager.default.fileExists(atPath: keyFileURL.path) else {
                throw VaultError.fileReadFailure(path: keyFileURL.path)
            }
        }

        guard !masterPassword.isEmpty || keyFileURL != nil else {
            throw VaultError.invalidPassword
        }

        let compositeKey = try makeCompositeKey(masterPassword: masterPassword, keyFileURL: keyFileURL)

        let (tree, fingerprint, diskData) = try readTree(at: fileURL, key: compositeKey)
        undoStack.removeAllActions()

        let editingDelegate = TreeEditingDelegate(undoStack: undoStack)
        tree.delegate = editingDelegate

        let format = Self.preferredSaveFormat(for: fileURL, minimumVersionFormat: tree.minimumVersion.format)
        let loadedSession = Session(
            fileURL: fileURL,
            key: compositeKey,
            format: format,
            tree: tree,
            editingDelegate: editingDelegate
        )
        session = loadedSession
        diskFingerprint = fingerprint
        diskKey = compositeKey
        pendingMergeSummary = nil
        pendingRestoreSummary = nil

        if try !restoreFromSnapshot(into: loadedSession, diskFingerprint: fingerprint, key: compositeKey) {
            storeSnapshot(diskData, for: fileURL)
        }

        return Self.mapTree(tree, fileURL: fileURL)
    }

    public func takeRestoreSummary() async -> VaultMergeSummary? {
        defer { pendingRestoreSummary = nil }
        return pendingRestoreSummary
    }

    /// If the file was rewritten since KeeMac last saved it, merges KeeMac's last saved copy back in
    /// so entries another client overwrote come back. Returns true when the result was written.
    private func restoreFromSnapshot(into session: Session, diskFingerprint: VaultFileFingerprint, key: KPKCompositeKey) throws -> Bool {
        guard let snapshotURL = snapshotURL(for: session.fileURL),
              let snapshotData = try? Data(contentsOf: snapshotURL),
              Self.fingerprint(of: snapshotData) != diskFingerprint,
              let snapshotTree = try? KPKTree(data: snapshotData, key: key) else {
            return false
        }

        let before = Self.mapTree(session.tree, fileURL: session.fileURL)
        let snapshotVault = Self.mapTree(snapshotTree, fileURL: session.fileURL)
        session.editingDelegate.withoutUndo {
            session.tree.synchronize(with: snapshotTree, mode: .synchronize, options: [])
            Self.keepHighestHOTPCounters(in: session.tree, from: snapshotTree)
        }
        Self.adoptRecycleBin(from: snapshotTree, into: session.tree)
        let after = Self.mapTree(session.tree, fileURL: session.fileURL)

        guard Self.contentSignature(after) != Self.contentSignature(before) else {
            return false
        }
        let summary = VaultMergeDiff.applied(before: before.entries, after: after.entries, external: snapshotVault.entries)
        try write(session: session)
        if !summary.isEmpty {
            pendingRestoreSummary = summary
        }
        return true
    }

    private func snapshotURL(for fileURL: URL) -> URL? {
        guard let snapshotDirectory else {
            return nil
        }
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        let name = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return snapshotDirectory.appendingPathComponent(name).appendingPathExtension("kdbx")
    }

    /// Deletes KeeMac's copy of the last save, e.g. when the database is removed from the recent list.
    public func discardSnapshot(for fileURL: URL) async {
        guard let url = snapshotURL(for: fileURL) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Best effort: a missing snapshot only weakens protection, it must never block saving.
    private func storeSnapshot(_ data: Data, for fileURL: URL) {
        guard let snapshotDirectory, let url = snapshotURL(for: fileURL) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: snapshotDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    public func createVault(options: VaultCreationOptions) async throws -> LoadedVault {
        let fileURL = options.fileURL
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultError.parseFailure(details: "A file named “\(fileURL.lastPathComponent)” already exists in this folder.")
        }

        let compositeKey = try makeCompositeKey(masterPassword: options.masterPassword, keyFileURL: options.keyFileURL)
        let editingDelegate = TreeEditingDelegate(undoStack: undoStack)
        let tree = KPKTree(templateContents: ())
        tree.delegate = editingDelegate

        let trimmedName = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root = tree.root, !trimmedName.isEmpty {
            root.title = trimmedName
        }

        guard let meta = tree.metaData else {
            throw VaultError.parseFailure(details: "Database metadata is unavailable.")
        }
        meta.databaseName = trimmedName
        meta.databaseDescription = options.details
        meta.useTrash = options.useTrash
        meta.historyMaxItems = options.historyMaxItems
        meta.masterKeyChanged = Date()
        meta.compressionAlgorithm = options.compress ? KPKCompression.gzip.rawValue : KPKCompression.none.rawValue
        meta.cipherUUID = Self.cipherUUID(for: options.cipher)
        meta.keyDerivationParameters = try Self.makeKeyDerivationParameters(from: options.keyDerivation)

        let session = Session(
            fileURL: fileURL,
            key: compositeKey,
            format: Self.preferredSaveFormat(for: fileURL, minimumVersionFormat: tree.minimumVersion.format),
            tree: tree,
            editingDelegate: editingDelegate
        )
        try writeNewFile(session: session)
        self.session = session
        hasPendingUsageChanges = false
        diskKey = compositeKey
        diskFingerprint = Self.fingerprint(ofFileAt: fileURL)
        pendingMergeSummary = nil
        pendingRestoreSummary = nil
        if let data = try? Data(contentsOf: fileURL) {
            storeSnapshot(data, for: fileURL)
        }
        return Self.mapTree(tree, fileURL: fileURL)
    }

    /// Writes a random KeePass XML (v2) key file.
    public nonisolated static func generateKeyFile(at url: URL) throws {
        guard let data = NSData.kpk_generateKeyfileData(of: .xmlVersion2) else {
            throw VaultError.parseFailure(details: "Could not generate a key file.")
        }
        try data.write(to: url, options: [.atomic])
    }

    /// Picks KDF work factors so that unlocking takes roughly `seconds` on this Mac.
    public nonisolated static func calibrate(_ settings: VaultDatabaseSettings, targetSeconds: Double) throws -> VaultDatabaseSettings {
        var probe = settings
        let sample = Data(repeating: 0x5A, count: 32)
        var result = settings

        switch settings.kdf {
        case .argon2d, .argon2id:
            probe.argonIterations = 2
            let elapsed = try measureDerivation(of: sample, settings: probe)
            let perIteration = max(elapsed / 2, 0.000_1)
            result.argonIterations = UInt64(max((targetSeconds / perIteration).rounded(), 1))
        case .aes:
            probe.aesRounds = 200_000
            let elapsed = try measureDerivation(of: sample, settings: probe)
            let perRound = max(elapsed / 200_000, 0.000_000_001)
            result.aesRounds = UInt64(max((targetSeconds / perRound).rounded(), 1_000))
        }
        return result
    }

    private nonisolated static func measureDerivation(of sample: Data, settings: VaultDatabaseSettings) throws -> Double {
        let parameters = try makeKeyDerivationParameters(from: settings)
        let start = Date()
        _ = KPKKeyDerivation.deriveData(sample, withParameters: parameters)
        return Date().timeIntervalSince(start)
    }

    private static func cipherUUID(for cipher: VaultCipher) -> UUID {
        switch cipher {
        case .aes256:
            return KPKAESCipher.uuid()
        case .chacha20:
            return KPKChaCha20Cipher.uuid()
        case .twofish:
            return KPKTwofishCipher.uuid()
        }
    }

    private func writeNewFile(session: Session) throws {
        let directory = session.fileURL.deletingLastPathComponent()
        let accessed = directory.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        let encryptedData: Data
        do {
            encryptedData = try session.tree.encrypt(with: session.key, format: session.format)
        } catch {
            throw Self.mapKeePassError(error as NSError)
        }

        do {
            try encryptedData.write(to: session.fileURL, options: [.withoutOverwriting])
        } catch {
            throw VaultError.fileReadFailure(path: session.fileURL.path)
        }
    }

    public func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.newEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let parentGroup = Self.findGroup(in: currentSession.tree, path: groupPath) else {
            throw VaultError.parseFailure(details: "Cannot find target group for new entry.")
        }

        let entry = currentSession.tree.createEntry(parentGroup)
        entry.add(to: parentGroup)
        try Self.apply(form: form, to: entry)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    /// Copies an entry into the same group with a new UUID and no history. Returns the copy's ID.
    /// With `referencingCredentials` the copy's username and password are `{REF:…}` to the original,
    /// so changing the original's password updates the copy too.
    public func duplicateEntry(id: UUID, referencingCredentials: Bool = false) async throws -> (vault: LoadedVault, entryID: UUID) {
        beginUndo()
        defer { endUndo(.duplicateEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard let entry = Self.findEntry(in: currentSession.tree, id: id), let parent = entry.parent else {
            throw VaultError.parseFailure(details: "Entry was not found.")
        }
        guard !entry.isTrashed else {
            throw VaultError.parseFailure(details: "Restore the entry before duplicating it.")
        }

        let options: KPKCopyOptions = referencingCredentials ? [.referenceUsername, .referencePassword] : []
        guard let copy = entry.copy(withTitle: "\(entry.title ?? "") copy", options: options) else {
            throw VaultError.parseFailure(details: "Entry could not be copied.")
        }
        copy.add(to: parent)

        try save(session: currentSession)
        return (Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL), copy.uuid)
    }

    public func updateEntry(id: UUID, form: VaultEntryForm) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.editEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to update was not found.")
        }

        entry.pushHistory()
        try Self.apply(form: form, to: entry)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func moveEntry(id: UUID, toGroupPath groupPath: String?) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.moveEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to move was not found.")
        }

        guard let targetGroup = Self.findGroup(in: currentSession.tree, path: groupPath) else {
            throw VaultError.parseFailure(details: "Target group for move was not found.")
        }

        if entry.parent === targetGroup {
            return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
        }

        entry.move(to: targetGroup)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func deleteEntry(id: UUID) async throws -> LoadedVault {
        var undoAction = VaultUndoAction.moveToTrash
        beginUndo()
        defer { endUndo(undoAction) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to delete was not found.")
        }

        // KeePassKit's trashOrRemove moves an entry that is already in the trash back into it.
        if entry.isTrashed {
            undoAction = .deletePermanently
            entry.remove()
        } else {
            entry.trashOrRemove()
        }

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func emptyTrash(ids: [UUID]) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.emptyTrash) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        for id in ids {
            if let entry = Self.findEntry(in: currentSession.tree, id: id), entry.isTrashed {
                entry.remove()
            }
        }
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func restoreEntry(id: UUID) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.restoreEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to restore was not found.")
        }
        guard entry.isTrashed else {
            throw VaultError.parseFailure(details: "Only trashed entries can be restored.")
        }

        let targetGroup = Self.resolveRestoreGroup(for: entry, in: currentSession.tree)
        entry.move(to: targetGroup)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func revertEntry(id: UUID, toHistoryRevisionAt index: Int) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.revertEntry) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
            throw VaultError.parseFailure(details: "Entry to revert was not found.")
        }

        let sortedHistory = Self.sortedHistoryEntries(from: entry)
        guard sortedHistory.indices.contains(index) else {
            throw VaultError.parseFailure(details: "History revision to revert was not found.")
        }

        entry.revert(to: sortedHistory[index])

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.newGroup) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Group title cannot be empty.")
        }

        guard let parentGroup = Self.findGroup(in: currentSession.tree, path: parentPath) else {
            throw VaultError.parseFailure(details: "Cannot find parent group for new group.")
        }

        let group = currentSession.tree.createGroup(parentGroup)
        group.add(to: parentGroup)
        group.title = normalizedTitle
        group.iconId = iconID ?? Int(KPKEntry.defaultIcon())

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func updateGroup(path: String, title: String, iconID: Int?) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.editGroup) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw VaultError.parseFailure(details: "Cannot edit root group.")
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Group title cannot be empty.")
        }

        guard let group = Self.findGroup(in: currentSession.tree, path: normalizedPath) else {
            throw VaultError.parseFailure(details: "Group to edit was not found.")
        }

        group.title = normalizedTitle
        group.iconId = iconID ?? Int(KPKEntry.defaultIcon())

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func moveGroup(path: String, toParentPath parentPath: String?) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.moveGroup) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw VaultError.parseFailure(details: "Cannot move root group.")
        }

        guard let group = Self.findGroup(in: currentSession.tree, path: normalizedPath) else {
            throw VaultError.parseFailure(details: "Group to move was not found.")
        }
        guard group.parent != nil else {
            throw VaultError.parseFailure(details: "Cannot move root group.")
        }

        guard let targetParent = Self.findGroup(in: currentSession.tree, path: parentPath) else {
            throw VaultError.parseFailure(details: "Target parent group was not found.")
        }

        if group.parent === targetParent {
            return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
        }

        var ancestor: KPKGroup? = targetParent
        while let current = ancestor {
            if current === group {
                throw VaultError.parseFailure(details: "Cannot move a group into one of its own descendants.")
            }
            ancestor = current.parent
        }

        group.move(to: targetParent)

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func deleteGroup(path: String) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.deleteGroup) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw VaultError.parseFailure(details: "Cannot delete root group.")
        }

        guard let group = Self.findGroup(in: currentSession.tree, path: normalizedPath) else {
            throw VaultError.parseFailure(details: "Group to delete was not found.")
        }
        guard group.parent != nil else {
            throw VaultError.parseFailure(details: "Cannot delete root group.")
        }

        if group.isTrashed {
            group.remove()
        } else {
            group.trashOrRemove()
        }

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func databaseSettings() async throws -> VaultDatabaseSettings {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        return Self.readDatabaseSettings(from: currentSession.tree)
    }

    public func updateDatabaseSettings(_ settings: VaultDatabaseSettings) async throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        guard let meta = currentSession.tree.metaData else {
            throw VaultError.parseFailure(details: "Database metadata is unavailable.")
        }
        meta.databaseName = settings.name
        meta.databaseDescription = settings.details
        meta.keyDerivationParameters = try Self.makeKeyDerivationParameters(from: settings)
        if let path = settings.templatesGroupPath, let group = Self.findGroup(in: currentSession.tree, path: path) {
            meta.entryTemplatesGroupUuid = group.uuid
        } else {
            meta.entryTemplatesGroupUuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }

        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func changeMasterKey(newPassword: String, keyFileURL: URL?) async throws {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }

        let newKey = try makeCompositeKey(masterPassword: newPassword, keyFileURL: keyFileURL)
        currentSession.tree.metaData?.masterKeyChanged = Date()

        let updatedSession = Session(
            fileURL: currentSession.fileURL,
            key: newKey,
            format: currentSession.format,
            tree: currentSession.tree,
            editingDelegate: currentSession.editingDelegate
        )
        session = updatedSession

        do {
            try save(session: updatedSession)
        } catch {
            // Roll back to the previous key so the in-memory session stays usable.
            session = currentSession
            throw error
        }
    }

    // MARK: - Import and export

    public func importEntries(_ file: VaultImportFile, options: VaultImportOptions) async throws -> (vault: LoadedVault, result: VaultImportResult) {
        beginUndo()
        defer { endUndo(.importEntries) }
        guard let currentSession = session, let root = currentSession.tree.root else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let tree = currentSession.tree

        let target: KPKGroup
        switch options.destination {
        case .newGroup(let title):
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            target = tree.createGroup(root)
            target.add(to: root)
            target.title = name.isEmpty ? "Imported" : name
            target.iconId = Int(KPKGroup.defaultIcon())
        case .group(let path):
            guard let group = Self.findGroup(in: tree, path: path), !group.isTrash, !group.isTrashed else {
                throw VaultError.parseFailure(details: "Cannot find the group to import into.")
            }
            target = group
        }

        var existing = Set(tree.allEntries.filter { !$0.isHistory && !$0.isMeta && !$0.isTrashed }.map { entry in
            let resolver = ReferenceResolver(entry: entry)
            return VaultImportItem.duplicateKey(
                title: resolver.resolve(entry.title ?? "", field: VaultEntryReferences.title),
                username: resolver.resolve(entry.username ?? "", field: VaultEntryReferences.username),
                url: resolver.resolve(entry.url ?? "", field: VaultEntryReferences.url)
            )
        })
        func shouldSkip(_ key: String) -> Bool {
            if options.skipsDuplicates && existing.contains(key) {
                return true
            }
            existing.insert(key)
            return false
        }
        func folderGroup(_ folder: [String]) -> KPKGroup {
            guard options.keepsFolders else {
                return target
            }
            var group = target
            for title in folder where !title.isEmpty {
                if let child = group.groups.first(where: { $0.title == title }) {
                    group = child
                } else {
                    let child = tree.createGroup(group)
                    child.add(to: group)
                    child.title = title
                    child.iconId = Int(KPKGroup.defaultIcon())
                    group = child
                }
            }
            return group
        }

        var ids: [UUID] = []
        // KeePass XML, and KeePass 1 databases converted to it, import node by node.
        if let xml = file.xmlData {
            let source: KPKTree
            do {
                source = try KPKTree(xmlData: xml)
            } catch {
                throw VaultError.parseFailure(details: "The KeePass XML file can’t be read.")
            }
            if let sourceMeta = source.metaData, let meta = tree.metaData {
                for icon in sourceMeta.customIcons where !meta.customIcons.contains(where: { $0.uuid == icon.uuid }) {
                    meta.addCustomIcon(icon)
                }
            }
            for entry in source.allEntries where !entry.isHistory && !entry.isMeta && !entry.isTrashed {
                guard !shouldSkip(VaultImportItem.duplicateKey(title: entry.title ?? "", username: entry.username ?? "", url: entry.url ?? "")) else {
                    continue
                }
                var folder: [String] = []
                var parent = entry.parent
                while let group = parent, group.parent != nil {
                    folder.insert(group.title ?? "", at: 0)
                    parent = group.parent
                }
                // A nil title would make KeePassKit append " copy".
                guard let copy = entry.copy(withTitle: entry.title ?? "", options: .copyHistory) else {
                    continue
                }
                copy.add(to: folderGroup(folder))
                ids.append(UUID(uuidString: copy.uuid.uuidString) ?? UUID())
            }
        } else {
            for item in file.items where !shouldSkip(item.duplicateKey) {
                let group = folderGroup(item.folder)
                let entry = tree.createEntry(group)
                entry.add(to: group)
                entry.title = item.title
                entry.username = item.username
                entry.password = item.password
                entry.url = item.url
                entry.notes = item.notes
                if !item.tags.isEmpty {
                    entry.tags = Self.normalizedTags(from: item.tags)
                }
                for field in item.customFields {
                    Self.upsertCustomAttribute(on: entry, key: field.key, value: field.value, protect: field.isProtected)
                }
                if let otp = Self.otpAuthURI(from: item.otp, title: item.title) {
                    if let form = VaultOTPURI.parse(otp), form.kind == .hotp {
                        try? Self.applyOTP(form, to: entry, title: item.title)
                    } else {
                        Self.upsertCustomAttribute(on: entry, key: kKPKAttributeKeyOTPOAuthURL, value: otp, protect: true)
                    }
                }
                if item.isSecureNote {
                    entry.setCustomData(VaultEntryType.note.rawValue, forKey: VaultEntryType.customDataKey)
                }
                ids.append(UUID(uuidString: entry.uuid.uuidString) ?? UUID())
            }
        }

        try save(session: currentSession)
        return (
            Self.mapTree(tree, fileURL: currentSession.fileURL),
            VaultImportResult(importedCount: ids.count, groupPath: target.breadcrumb, entryIDs: ids)
        )
    }

    public func exportDatabase(_ options: VaultExportOptions) async throws -> (data: Data, entryCount: Int) {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded.")
        }
        let delegate = TreeEditingDelegate(undoStack: KMUndoStack.discarding())
        let export: KPKTree
        do {
            export = try KPKTree(xmlData: currentSession.tree.xmlData)
        } catch {
            throw VaultError.parseFailure(details: "The database can’t be exported.")
        }
        export.delegate = delegate

        if !options.includesTrash, let trash = export.trash {
            trash.remove()
        }
        if let path = options.groupPath {
            // A new tree with copies, so the export doesn't list everything else as deleted objects.
            guard let scope = Self.findGroup(in: export, path: path) else {
                throw VaultError.parseFailure(details: "Cannot find the group to export.")
            }
            let scoped = KPKTree()
            scoped.delegate = delegate
            let root = KPKGroup()
            scoped.root = root
            root.title = export.root?.title ?? "Root"
            if let meta = scoped.metaData {
                meta.databaseName = export.metaData?.databaseName ?? ""
                for icon in export.metaData?.customIcons ?? [] {
                    meta.addCustomIcon(icon)
                }
            }
            scope.copy(withTitle: scope.title ?? "", options: .copyHistory).add(to: root)
            return try finishExport(scoped, options: options, delegate: delegate)
        }
        return try finishExport(export, options: options, delegate: delegate)
    }

    private func finishExport(_ tree: KPKTree, options: VaultExportOptions, delegate: TreeEditingDelegate) throws -> (data: Data, entryCount: Int) {
        let entries = tree.allEntries.filter { !$0.isHistory && !$0.isMeta && (options.includesTrash || !$0.isTrashed) }
        if !options.includesHistory || options.format == .csv {
            entries.forEach { $0.clearHistory() }
        }
        if !options.includesAttachments {
            for entry in entries {
                entry.binaries.forEach(entry.removeBinary)
            }
        }
        switch options.format {
        case .keePassXML:
            return (tree.xmlData, entries.count)
        case .csv:
            var lines = [CSVReader.line(["Group", "Title", "Username", "Password", "URL", "Notes", "TOTP", "Icon", "Last Modified", "Created"])]
            let dates = ISO8601DateFormatter()
            for entry in entries {
                let resolver = ReferenceResolver(entry: entry)
                var path: [String] = []
                var parent = entry.parent
                while let group = parent {
                    path.insert(group.title ?? "", at: 0)
                    parent = group.parent
                }
                lines.append(CSVReader.line([
                    path.joined(separator: "/"),
                    resolver.resolve(entry.title ?? "", field: VaultEntryReferences.title),
                    resolver.resolve(entry.username ?? "", field: VaultEntryReferences.username),
                    resolver.resolve(entry.password ?? "", field: VaultEntryReferences.password),
                    resolver.resolve(entry.url ?? "", field: VaultEntryReferences.url),
                    resolver.resolve(entry.notes ?? "", field: VaultEntryReferences.notes),
                    Self.otpAuthURI(for: entry) ?? "",
                    String(entry.iconId),
                    entry.timeInfo.modificationDate.map(dates.string(from:)) ?? "",
                    entry.timeInfo.creationDate.map(dates.string(from:)) ?? ""
                ]))
            }
            withExtendedLifetime(delegate) {}
            return (Data((lines.joined(separator: "\n") + "\n").utf8), entries.count)
        }
    }

    public func verifyMasterKey(password: String, keyFileURL: URL?) async -> Bool {
        guard let currentSession = session, !password.isEmpty || keyFileURL != nil,
              let candidate = try? makeCompositeKey(masterPassword: password, keyFileURL: keyFileURL) else {
            return false
        }
        return currentSession.key.isEqual(to: candidate)
    }

    // MARK: - Transfer between open databases

    /// Packs entries (or one group with its subgroups) for another open database.
    /// The nodes keep their UUIDs, history and attachments; references become plain values.
    public func makeTransferPayload(entryIDs: [UUID], groupPath: String?) async throws -> VaultTransferPayload {
        guard let currentSession = session, let xml = currentSession.tree.xmlData else {
            throw VaultError.parseFailure(details: "Vault is not loaded.")
        }
        let delegate = TreeEditingDelegate(undoStack: KMUndoStack.discarding())
        // A full copy (same UUIDs), so references still resolve while the values are filled in.
        let source = try KPKTree(xmlData: xml)
        source.delegate = delegate

        let payload = KPKTree()
        payload.delegate = delegate
        let root = KPKGroup()
        payload.root = root
        root.title = source.root?.title ?? "Root"
        for icon in source.metaData?.customIcons ?? [] {
            payload.metaData?.addCustomIcon(icon)
        }

        var nodes: [KPKNode] = []
        var entries: [KPKEntry] = []
        var groupTitle: String?
        if let groupPath {
            guard let group = Self.findGroup(in: source, path: groupPath), group.parent != nil, !group.isTrashed else {
                throw VaultError.parseFailure(details: "Group to transfer was not found.")
            }
            nodes = [group]
            entries = Self.descendantEntries(of: group)
            groupTitle = group.title ?? ""
        } else {
            for id in entryIDs {
                guard let entry = Self.findEntry(in: source, id: id), !entry.isTrashed else {
                    continue
                }
                nodes.append(entry)
                entries.append(entry)
            }
        }

        var linked = 0
        for entry in entries {
            for attribute in entry.attributes where attribute.value?.range(of: "{REF:", options: .caseInsensitive) != nil {
                let value = attribute.value ?? ""
                let resolved = value.kpk_finalValue(for: entry, options: [.skipUserInteraction, .readOnly]) ?? value
                if resolved.range(of: "{REF:", options: .caseInsensitive) == nil {
                    attribute.value = resolved
                    linked += 1
                }
            }
        }
        for node in nodes {
            if let group = node as? KPKGroup {
                Self.transplant(group, into: root, usedIDs: [])
            } else {
                node.remove()
                node.add(to: root)
            }
        }
        guard let data = payload.xmlData else {
            throw VaultError.parseFailure(details: "Entries can’t be packed for another database.")
        }
        withExtendedLifetime(delegate) {}
        return VaultTransferPayload(
            xmlData: data,
            entryIDs: entries.compactMap { UUID(uuidString: $0.uuid.uuidString) },
            groupTitle: groupTitle,
            linkedFieldCount: linked
        )
    }

    /// Incoming entries this database already has: the same entry (same UUID) or one with the same title and username.
    public func transferConflicts(for payload: VaultTransferPayload) async throws -> [VaultTransferConflict] {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded.")
        }
        let incoming = try KPKTree(xmlData: payload.xmlData)
        let existing = currentSession.tree.allEntries.filter { !$0.isHistory && !$0.isMeta && !$0.isTrashed }
        func key(_ entry: KPKEntry) -> String {
            (entry.title ?? "").trimmingCharacters(in: .whitespaces).lowercased() + "\u{1F}" + (entry.username ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        let byKey = Dictionary(existing.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })

        var conflicts: [VaultTransferConflict] = []
        for entry in incoming.allEntries where !entry.isHistory && !entry.isMeta {
            guard let id = UUID(uuidString: entry.uuid.uuidString) else {
                continue
            }
            let sameEntry = Self.findEntry(in: currentSession.tree, id: id).flatMap { $0.isTrashed ? nil : $0 }
            guard let match = sameEntry ?? byKey[key(entry)], let matchID = UUID(uuidString: match.uuid.uuidString) else {
                continue
            }
            conflicts.append(VaultTransferConflict(
                id: id,
                existingID: matchID,
                isSameEntry: sameEntry != nil,
                title: entry.title ?? "",
                username: entry.username ?? "",
                incomingModifiedAt: entry.timeInfo.modificationDate,
                existingTitle: match.title ?? "",
                existingUsername: match.username ?? "",
                existingModifiedAt: match.timeInfo.modificationDate
            ))
        }
        return conflicts
    }

    /// Adds the payload under `groupPath` as one undo step. Conflicts without a decision keep both.
    public func receiveTransfer(
        _ payload: VaultTransferPayload,
        toGroupPath groupPath: String?,
        decisions: [UUID: VaultTransferDecision]
    ) async throws -> (vault: LoadedVault, result: VaultTransferResult) {
        beginUndo()
        defer { endUndo(.receiveEntries) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let tree = currentSession.tree
        guard let target = Self.findGroup(in: tree, path: groupPath), !target.isTrashed else {
            throw VaultError.parseFailure(details: "Target group for transfer was not found.")
        }
        let delegate = TreeEditingDelegate(undoStack: KMUndoStack.discarding())
        let incoming: KPKTree
        do {
            incoming = try KPKTree(xmlData: payload.xmlData)
        } catch {
            throw VaultError.parseFailure(details: "Entries from the other database can’t be read.")
        }
        incoming.delegate = delegate
        if let meta = tree.metaData {
            for icon in incoming.metaData?.customIcons ?? [] where !meta.customIcons.contains(where: { $0.uuid == icon.uuid }) {
                meta.addCustomIcon(icon)
            }
        }

        let conflicts = try await transferConflicts(for: payload)
        let conflictsByID = Dictionary(conflicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var received: [UUID] = []

        // Settle conflicts inside the payload first, so what is left can be added as it is.
        for entry in incoming.allEntries where !entry.isHistory && !entry.isMeta {
            guard let id = UUID(uuidString: entry.uuid.uuidString) else {
                continue
            }
            guard let conflict = conflictsByID[id] else {
                received.append(id)
                continue
            }
            switch decisions[id] ?? .keepBoth {
            case .skip:
                entry.remove()
            case .replace:
                guard let existing = Self.findEntry(in: tree, id: conflict.existingID) else {
                    continue
                }
                if conflict.isSameEntry {
                    existing.pushHistory()
                    Self.copyContents(of: entry, to: existing)
                    entry.remove()
                } else {
                    existing.trashOrRemove()
                }
                received.append(id)
            case .keepBoth:
                received.append(id)
            }
        }

        // Nodes whose UUID this database already uses (even in its trash or history) get new ones.
        let usedIDs = Set(tree.allEntries.compactMap { $0.uuid } + tree.allGroups.compactMap { $0.uuid })
        var addedGroup: KPKGroup?
        for group in incoming.root?.groups ?? [] {
            addedGroup = Self.transplant(group, into: target, usedIDs: usedIDs)
        }
        for entry in incoming.root?.entries ?? [] {
            if usedIDs.contains(entry.uuid) {
                entry.copy(withTitle: entry.title ?? "", options: .copyHistory).add(to: target)
            } else {
                entry.remove()
                entry.add(to: target)
            }
        }
        withExtendedLifetime(delegate) {}

        try save(session: currentSession)
        return (
            Self.mapTree(tree, fileURL: currentSession.fileURL),
            VaultTransferResult(receivedEntryIDs: received, groupPath: addedGroup?.breadcrumb)
        )
    }

    /// After a move: the entries (or the whole group) that reached the other database go to this one's trash, as one undo step.
    public func trashTransferredEntries(_ entryIDs: [UUID], groupPath: String?) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.sendEntries) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        if let groupPath {
            if let group = Self.findGroup(in: currentSession.tree, path: groupPath), group.parent != nil, !group.isTrashed {
                group.trashOrRemove()
            }
        } else {
            for id in entryIDs {
                if let entry = Self.findEntry(in: currentSession.tree, id: id), !entry.isTrashed {
                    entry.trashOrRemove()
                }
            }
        }
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    private static func descendantEntries(of group: KPKGroup) -> [KPKEntry] {
        group.entries + group.groups.flatMap(descendantEntries)
    }

    /// Rebuilds a group with its subgroups and entries under `parent`, which may be in another tree.
    /// Moving the group node itself across trees loses its children. Nodes keep their UUIDs unless `usedIDs` has them.
    @discardableResult
    private static func transplant(_ group: KPKGroup, into parent: KPKGroup, usedIDs: Set<UUID>) -> KPKGroup {
        let copy = (usedIDs.contains(group.uuid) ? nil : KPKGroup(uuid: group.uuid)) ?? KPKGroup()
        copy.title = group.title ?? ""
        copy.notes = group.notes ?? ""
        copy.iconId = group.iconId
        copy.iconUUID = group.iconUUID
        copy.add(to: parent)
        for entry in Array(group.entries) {
            if usedIDs.contains(entry.uuid) {
                entry.copy(withTitle: entry.title ?? "", options: .copyHistory).add(to: copy)
            } else {
                entry.remove()
                entry.add(to: copy)
            }
        }
        for subgroup in Array(group.groups) {
            transplant(subgroup, into: copy, usedIDs: usedIDs)
        }
        return copy
    }

    /// "Replace" for the same entry: the incoming version's fields over the existing entry, which keeps its UUID, place and history.
    private static func copyContents(of source: KPKEntry, to target: KPKEntry) {
        target.title = source.title ?? ""
        target.username = source.username ?? ""
        target.password = source.password ?? ""
        target.url = source.url ?? ""
        target.notes = source.notes ?? ""
        target.tags = source.tags
        target.iconId = source.iconId
        target.iconUUID = source.iconUUID
        target.foregroundColor = source.foregroundColor
        target.backgroundColor = source.backgroundColor
        target.overrideURL = source.overrideURL
        for attribute in target.customAttributes {
            target.removeCustomAttribute(attribute)
        }
        for attribute in source.customAttributes {
            target.addCustomAttribute(KPKAttribute(key: attribute.key, value: attribute.value, isProtected: attribute.protect))
        }
        for binary in target.binaries {
            target.removeBinary(binary)
        }
        for binary in source.binaries {
            if let copy = binary.copy() as? KPKBinary {
                target.addBinary(copy)
            }
        }
        target.clearCustomData()
        for (key, value) in source.customData {
            target.setCustomData(value, forKey: key)
        }
        target.timeInfo.expires = source.timeInfo.expires
        target.timeInfo.expirationDate = source.timeInfo.expirationDate
    }

    /// A bare Base32 secret becomes an `otpauth://` URI; URIs are kept.
    private static func otpAuthURI(from value: String, title: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return trimmed
        }
        let secret = trimmed.replacingOccurrences(of: " ", with: "").uppercased()
        let label = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "KeeMac"
        return "otpauth://totp/\(label)?secret=\(secret)"
    }

    /// The entry's one-time password as an `otpauth://` URI, for CSV export.
    private static func otpAuthURI(for entry: KPKEntry) -> String? {
        guard let otp = makeOTPConfiguration(from: entry)?.configuration else {
            return nil
        }
        if otp.kind != .hotp,
           let uri = entry.customAttributes?.first(where: { $0.key == kKPKAttributeKeyOTPOAuthURL })?.value,
           uri.lowercased().hasPrefix("otpauth://") {
            return uri
        }
        return VaultOTPURI.make(
            kind: otp.kind,
            secret: encodeBase32(otp.secret),
            label: entry.title ?? "",
            digits: otp.digits,
            period: otp.period,
            algorithm: otp.algorithm,
            counter: otp.counter
        )
    }

    // MARK: - Undo

    public func undoState() async -> VaultUndoState {
        guard session != nil else {
            return .empty
        }
        return VaultUndoState(
            undoAction: undoStack.canUndo ? VaultUndoAction(rawValue: undoStack.undoActionName) : nil,
            redoAction: undoStack.canRedo ? VaultUndoAction(rawValue: undoStack.redoActionName) : nil
        )
    }

    public func undo() async throws -> LoadedVault {
        try performUndoStep(redo: false)
    }

    public func redo() async throws -> LoadedVault {
        try performUndoStep(redo: true)
    }

    private func performUndoStep(redo: Bool) throws -> LoadedVault {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard redo ? undoStack.canRedo : undoStack.canUndo else {
            return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
        }
        // Undoing an edit brings back the entry's old fields, but not its old HOTP counter.
        let counters = Self.hotpCounters(in: currentSession.tree)
        // Undoing registers the redo step (and the other way round), which needs registration on.
        undoStack.enableRegistration()
        if redo {
            undoStack.redo()
        } else {
            undoStack.undo()
        }
        undoStack.disableRegistration()
        currentSession.editingDelegate.withoutUndo {
            Self.raiseHOTPCounters(in: currentSession.tree, to: counters)
        }
        defer { clearUndoIfStale() }
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    /// Opens an undo group for one user action; pair with `endUndo` in a `defer`.
    private func beginUndo() {
        undoStack.enableRegistration()
        undoStack.beginGroup()
    }

    private func endUndo(_ action: VaultUndoAction) {
        undoStack.endGroup(withActionName: action.rawValue)
        undoStack.disableRegistration()
        clearUndoIfStale()
    }

    private func clearUndoIfStale() {
        if undoStackIsStale {
            undoStackIsStale = false
            undoStack.removeAllActions()
        }
    }

    // MARK: - Browser integration

    private static let browserKeyPrefix = "KPXC_BROWSER_"
    private static let browserCreatedPrefix = "_CREATED_"
    private static let browserAdditionalURLPrefix = "KP2A_URL"
    private static let browserFieldPrefix = "KPH: "

    private enum BrowserOption {
        static let hideEntry = "BrowserHideEntry"
        static let skipAutoSubmit = "BrowserSkipAutoSubmit"
        static let onlyHTTPAuth = "BrowserOnlyHttpAuth"
        static let notHTTPAuth = "BrowserNotHttpAuth"
        static let omitWWW = "BrowserOmitWww"
    }

    public func browserDatabaseHash() async -> String? {
        guard let root = session?.tree.root else {
            return nil
        }
        let hex = root.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return SHA256.hash(data: Data(hex.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func browserAssociations() async -> [VaultBrowserAssociation] {
        guard let meta = session?.tree.metaData else {
            return []
        }
        return meta.customData
            .compactMap { key, value -> VaultBrowserAssociation? in
                guard key.hasPrefix(Self.browserKeyPrefix) else {
                    return nil
                }
                let id = String(key.dropFirst(Self.browserKeyPrefix.count))
                return VaultBrowserAssociation(
                    id: id,
                    key: value.value,
                    created: meta.value(forCustomDataKey: Self.browserCreatedPrefix + id)
                )
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    public func storeBrowserAssociation(id: String, key: String, created: String) async throws -> LoadedVault {
        guard let currentSession = session, let meta = currentSession.tree.metaData else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        meta.setValue(key, forCustomDataKey: Self.browserKeyPrefix + id)
        meta.setValue(created, forCustomDataKey: Self.browserCreatedPrefix + id)
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func removeBrowserAssociation(id: String) async throws -> LoadedVault {
        guard let currentSession = session, let meta = currentSession.tree.metaData else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        meta.removeCustomData(forKey: Self.browserKeyPrefix + id)
        meta.removeCustomData(forKey: Self.browserCreatedPrefix + id)
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func browserCandidates() async -> [VaultBrowserCandidate] {
        guard let tree = session?.tree else {
            return []
        }
        return tree.allEntries.compactMap { entry in
            guard !entry.isHistory, !entry.isMeta, !entry.isTrashed, let group = entry.parent else {
                return nil
            }
            let groupHides = Self.browserOption(BrowserOption.hideEntry, in: group)
            if groupHides == true || (groupHides == nil && entry.customData[BrowserOption.hideEntry] == "true") {
                return nil
            }
            return Self.browserCandidate(entry, group: group)
        }
    }

    public func rememberBrowserAccess(allowed: [UUID], denied: [UUID], hosts: [String]) async throws -> LoadedVault? {
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let hosts = hosts.filter { !$0.isEmpty }
        guard !hosts.isEmpty else {
            return nil
        }
        var changed = false
        for (ids, allows) in [(allowed, true), (denied, false)] {
            for id in ids {
                guard let entry = Self.findEntry(in: currentSession.tree, id: id) else {
                    continue
                }
                var config = BrowserAccessConfig(json: entry.customData[BrowserAccessConfig.customDataKey]) ?? BrowserAccessConfig()
                for host in hosts {
                    allows ? config.allow(host) : config.deny(host)
                }
                entry.setCustomData(config.json, forKey: BrowserAccessConfig.customDataKey)
                entry.timeInfo.modificationDate = Date()
                changed = true
            }
        }
        guard changed else {
            return nil
        }
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    private static let browserGroupTitle = "KeePassXC-Browser Passwords"
    /// KeePassXC's icon for entries and groups it creates from the browser.
    private static let browserIconID = 1

    public func browserGroupTree() async -> VaultBrowserGroup? {
        guard let tree = session?.tree, let root = tree.root else {
            return nil
        }
        return Self.browserGroup(root, trash: tree.trash)
    }

    public func browserGroup(atPath titles: [String]) async -> VaultBrowserGroup? {
        guard let tree = session?.tree, let group = Self.group(atPath: titles, in: tree) else {
            return nil
        }
        return Self.browserGroup(group, trash: tree.trash)
    }

    public func createBrowserGroup(atPath titles: [String]) async throws -> (vault: LoadedVault, group: VaultBrowserGroup) {
        beginUndo()
        defer { endUndo(.newGroup) }
        guard let currentSession = session, let root = currentSession.tree.root else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let titles = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !titles.isEmpty, !titles.contains(where: \.isEmpty) else {
            throw VaultError.parseFailure(details: "Group title cannot be empty.")
        }
        var parent = root
        for title in titles {
            if let existing = parent.groups.first(where: { $0.title == title && !$0.isTrash }) {
                parent = existing
                continue
            }
            let group = currentSession.tree.createGroup(parent)
            group.add(to: parent)
            group.title = title
            group.iconId = Self.browserIconID
            group.setCustomData("false", forKey: BrowserOption.hideEntry)
            parent = group
        }
        try save(session: currentSession)
        return (Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL), Self.browserGroup(parent, trash: currentSession.tree.trash))
    }

    public func addBrowserLogin(_ login: VaultBrowserNewLogin) async throws -> (vault: LoadedVault, entryID: UUID) {
        beginUndo()
        defer { endUndo(.saveLogin) }
        guard let currentSession = session, let root = currentSession.tree.root else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        let tree = currentSession.tree
        let chosen = login.groupID.flatMap { id in
            ([root] + tree.allGroups).first { $0.uuid == id && !$0.isTrashed && !$0.isTrash }
        }
        let group: KPKGroup
        if let chosen {
            group = chosen
        } else if let existing = tree.allGroups.first(where: { $0.title == Self.browserGroupTitle && !$0.isTrashed && !$0.isTrash }) {
            group = existing
        } else {
            group = tree.createGroup(root)
            group.add(to: root)
            group.title = Self.browserGroupTitle
            group.iconId = Self.browserIconID
        }

        let entry = tree.createEntry(group)
        entry.add(to: group)
        entry.title = login.title
        entry.url = login.url
        entry.username = login.username
        entry.password = login.password
        entry.iconId = Self.browserIconID
        var access = BrowserAccessConfig()
        for host in login.allowedHosts where !host.isEmpty {
            access.allow(host)
        }
        if !access.allowedHosts.isEmpty {
            entry.setCustomData(access.json, forKey: BrowserAccessConfig.customDataKey)
        }

        try save(session: currentSession)
        return (Self.mapTree(tree, fileURL: currentSession.fileURL), UUID(uuidString: entry.uuid.uuidString) ?? UUID())
    }

    public func browserLoginTarget(for id: UUID) async -> VaultBrowserLoginTarget? {
        guard let tree = session?.tree, let entry = Self.passwordSource(of: id, in: tree) else {
            return nil
        }
        let resolver = ReferenceResolver(entry: entry)
        let rawUsername = entry.username ?? ""
        return VaultBrowserLoginTarget(
            id: UUID(uuidString: entry.uuid.uuidString) ?? id,
            title: resolver.resolve(entry.title ?? "", field: VaultEntryReferences.title),
            username: resolver.resolve(rawUsername, field: VaultEntryReferences.username),
            password: entry.password ?? "",
            usernameIsReference: rawUsername.range(of: "{REF:", options: .caseInsensitive) != nil
        )
    }

    public func updateBrowserLogin(id: UUID, username: String, password: String) async throws -> LoadedVault {
        beginUndo()
        defer { endUndo(.updateLogin) }
        guard let currentSession = session else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard let entry = Self.passwordSource(of: id, in: currentSession.tree) else {
            throw VaultError.parseFailure(details: "Entry to update was not found.")
        }
        entry.pushHistory()
        if (entry.username ?? "").range(of: "{REF:", options: .caseInsensitive) == nil {
            entry.username = username
        }
        entry.password = password
        entry.timeInfo.modificationDate = Date()
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    public func setBrowserEntryIcon(id: UUID, imageData: Data) async throws -> LoadedVault? {
        guard let currentSession = session, let meta = currentSession.tree.metaData else {
            throw VaultError.parseFailure(details: "Vault is not loaded for editing.")
        }
        guard let entry = Self.findEntry(in: currentSession.tree, id: id), !entry.isTrashed else {
            return nil
        }
        let encoded = imageData.base64EncodedString()
        let icon: KPKIcon
        if let existing = meta.customIcons.first(where: { $0.encodedString == encoded }) {
            icon = existing
        } else {
            icon = KPKIcon(imageData: imageData)
            meta.addCustomIcon(icon)
        }
        entry.iconUUID = icon.uuid
        try save(session: currentSession)
        return Self.mapTree(currentSession.tree, fileURL: currentSession.fileURL)
    }

    /// The entry itself, or the entry its password `{REF:P@I:…}` points to (followed a few levels deep).
    private static func passwordSource(of id: UUID, in tree: KPKTree) -> KPKEntry? {
        guard var entry = findEntry(in: tree, id: id), !entry.isTrashed else {
            return nil
        }
        for _ in 0..<8 {
            let password = (entry.password ?? "").trimmingCharacters(in: .whitespaces)
            guard password.uppercased().hasPrefix("{REF:P@I:"),
                  let source = ReferenceResolver.source(of: password),
                  let next = findEntry(in: tree, id: source) else {
                break
            }
            entry = next
        }
        return entry
    }

    private static func group(atPath titles: [String], in tree: KPKTree) -> KPKGroup? {
        guard var group = tree.root else {
            return nil
        }
        for title in titles {
            guard let child = group.groups.first(where: { $0.title == title && !$0.isTrash }) else {
                return nil
            }
            group = child
        }
        return group
    }

    private static func browserGroup(_ group: KPKGroup, trash: KPKGroup?) -> VaultBrowserGroup {
        VaultBrowserGroup(
            id: UUID(uuidString: group.uuid.uuidString) ?? UUID(),
            title: group.title ?? "",
            children: group.groups
                .filter { !$0.isTrash && $0 !== trash }
                .map { browserGroup($0, trash: trash) }
        )
    }

    /// KeePassXC's tri-state group options: "true" / "false" on the nearest group that sets it, nil when none does.
    private static func browserOption(_ key: String, in group: KPKGroup) -> Bool? {
        var current: KPKGroup? = group
        while let node = current {
            switch node.customData[key] {
            case "true": return true
            case "false": return false
            default: current = node.parent
            }
        }
        return nil
    }

    private static func browserCandidate(_ entry: KPKEntry, group: KPKGroup) -> VaultBrowserCandidate {
        let resolver = ReferenceResolver(entry: entry)
        let attributes = entry.customAttributes ?? []
        let additionalURLs = attributes
            .filter { $0.key.hasPrefix(browserAdditionalURLPrefix) && !$0.value.isEmpty }
            .map { resolver.resolve($0.value, field: $0.key) }
        let kphFields = attributes
            .filter { $0.key.hasPrefix(browserFieldPrefix) }
            .map { VaultCustomField(key: $0.key, value: resolver.resolve($0.value, field: $0.key), isProtected: $0.protect) }

        let skipAutoSubmit = browserOption(BrowserOption.skipAutoSubmit, in: group)
            ?? entry.customData[BrowserOption.skipAutoSubmit].map { $0 == "true" }

        return VaultBrowserCandidate(
            id: UUID(uuidString: entry.uuid.uuidString) ?? UUID(),
            title: resolver.resolve(entry.title ?? "", field: VaultEntryReferences.title),
            username: resolver.resolve(entry.username ?? "", field: VaultEntryReferences.username),
            password: resolver.resolve(entry.password ?? "", field: VaultEntryReferences.password),
            url: resolver.resolve(entry.url ?? "", field: VaultEntryReferences.url),
            additionalURLs: additionalURLs,
            groupTitle: group.title ?? "",
            isExpired: entry.timeInfo.isExpired,
            onlyHTTPAuth: entry.customData[BrowserOption.onlyHTTPAuth] == "true" || browserOption(BrowserOption.onlyHTTPAuth, in: group) == true,
            notHTTPAuth: entry.customData[BrowserOption.notHTTPAuth] == "true" || browserOption(BrowserOption.notHTTPAuth, in: group) == true,
            omitWWW: browserOption(BrowserOption.omitWWW, in: group) == true,
            skipAutoSubmit: skipAutoSubmit,
            access: BrowserAccessConfig(json: entry.customData[BrowserAccessConfig.customDataKey]),
            kphFields: kphFields,
            otp: makeOTPConfiguration(from: entry)?.configuration
        )
    }

    private static func readDatabaseSettings(from tree: KPKTree) -> VaultDatabaseSettings {
        guard let meta = tree.metaData else {
            return VaultDatabaseSettings()
        }
        var settings = VaultDatabaseSettings(
            name: meta.databaseName ?? "",
            details: meta.databaseDescription ?? "",
            templatesGroupPath: templatesGroup(in: tree)?.breadcrumb
        )

        let parameters = meta.keyDerivationParameters ?? [:]
        let kdf = KPKKeyDerivation(parameters: parameters)

        if let argon = kdf as? KPKArgon2DKeyDerivation {
            settings.kdf = (kdf is KPKArgon2IDKeyDerivation) ? .argon2id : .argon2d
            settings.argonIterations = argon.iterations
            settings.argonMemoryMiB = max(argon.memory / (1024 * 1024), 1)
            settings.argonParallelism = argon.threads
        } else if let aes = kdf as? KPKAESKeyDerivation {
            settings.kdf = .aes
            settings.aesRounds = aes.rounds
        }

        return settings
    }

    private nonisolated static func makeKeyDerivationParameters(from settings: VaultDatabaseSettings) throws -> [AnyHashable: Any] {
        switch settings.kdf {
        case .argon2d, .argon2id:
            let defaults = settings.kdf == .argon2id
                ? KPKArgon2IDKeyDerivation.defaultParameters()
                : KPKArgon2DKeyDerivation.defaultParameters()
            let derivation: KPKArgon2DKeyDerivation? = settings.kdf == .argon2id
                ? KPKArgon2IDKeyDerivation(parameters: defaults) as? KPKArgon2IDKeyDerivation
                : KPKArgon2DKeyDerivation(parameters: defaults) as? KPKArgon2DKeyDerivation
            guard let argon = derivation else {
                throw VaultError.parseFailure(details: "Could not configure Argon2 key derivation.")
            }
            argon.randomize()
            argon.iterations = max(settings.argonIterations, 1)
            argon.memory = max(settings.argonMemoryMiB, 1) * 1024 * 1024
            argon.threads = max(settings.argonParallelism, 1)
            return argon.parameters

        case .aes:
            let defaults = KPKAESKeyDerivation.defaultParameters()
            guard let aes = KPKAESKeyDerivation(parameters: defaults) as? KPKAESKeyDerivation else {
                throw VaultError.parseFailure(details: "Could not configure AES key derivation.")
            }
            aes.randomize()
            aes.rounds = max(settings.aesRounds, 1)
            return aes.parameters
        }
    }

    private func makeCompositeKey(masterPassword: String, keyFileURL: URL?) throws -> KPKCompositeKey {
        var keyParts: [KPKKey] = []

        if !masterPassword.isEmpty {
            guard let passwordKey = KPKPasswordKey(password: masterPassword) else {
                throw VaultError.invalidPassword
            }
            keyParts.append(passwordKey)
        }

        if let keyFileURL {
            let keyFileData: Data
            do {
                keyFileData = try Data(contentsOf: keyFileURL, options: [.uncached])
            } catch {
                throw VaultError.fileReadFailure(path: keyFileURL.path)
            }

            guard let fileKey = KPKFileKey(keyFileData: keyFileData) else {
                throw VaultError.invalidPassword
            }
            keyParts.append(fileKey)
        }

        guard !keyParts.isEmpty else {
            throw VaultError.invalidPassword
        }

        return KPKCompositeKey(keys: keyParts)
    }

    private func readTree(at fileURL: URL, key: KPKCompositeKey) throws -> (KPKTree, VaultFileFingerprint, Data) {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.uncached])
        } catch {
            throw VaultError.fileReadFailure(path: fileURL.path)
        }

        do {
            let tree = try KPKTree(data: data, key: key)
            return (tree, Self.fingerprint(of: data), data)
        } catch {
            throw Self.mapKeePassError(error as NSError)
        }
    }

    /// Saves the session, first merging in anything another device wrote since KeeMac last touched the file.
    private func save(session: Session) throws {
        if currentDiskStatus(of: session.fileURL) == .changed {
            let merge = try mergeFromDisk(into: session)
            if !merge.summary.isEmpty {
                let previous = pendingMergeSummary?.changes ?? []
                pendingMergeSummary = VaultMergeSummary(changes: previous + merge.summary.changes)
            }
        }
        try write(session: session)
    }

    private func write(session: Session) throws {
        hasPendingUsageChanges = false
        let accessed = session.fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                session.fileURL.stopAccessingSecurityScopedResource()
            }
        }

        try createBackup(for: session.fileURL)

        let encryptedData: Data
        do {
            encryptedData = try session.tree.encrypt(with: session.key, format: session.format)
        } catch {
            throw Self.mapKeePassError(error as NSError)
        }

        let directory = session.fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(session.fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try encryptedData.write(to: temporaryURL, options: [.atomic])

        do {
            _ = try FileManager.default.replaceItemAt(
                session.fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VaultError.fileReadFailure(path: session.fileURL.path)
        }

        diskFingerprint = Self.fingerprint(of: encryptedData)
        diskKey = session.key
        storeSnapshot(encryptedData, for: session.fileURL)
    }

    private func createBackup(for fileURL: URL) throws {
        let backupURL = URL(fileURLWithPath: fileURL.path + ".bak")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private static func mapTree(_ tree: KPKTree, fileURL: URL) -> LoadedVault {
        let allGroups = ([tree.root].compactMap { $0 } + tree.allGroups)
            .filter { !$0.isTrashed }

        let groups = allGroups
            .map {
                VaultGroup(
                    id: UUID(uuidString: $0.uuid.uuidString) ?? UUID(),
                    title: $0.title,
                    path: $0.breadcrumb,
                    iconPNGData: iconData(from: $0.icon),
                    iconID: normalizedIconID($0.iconId),
                    isTrash: $0.isTrash
                )
            }
            .sorted { lhs, rhs in
                lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

        let allEntries = tree.allEntries.filter { !$0.isHistory && !$0.isMeta }
        var entries: [VaultEntry] = []
        entries.reserveCapacity(allEntries.count)

        for entry in allEntries {
            entries.append(
                mapEntry(entry)
            )
        }

        entries.sort { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return LoadedVault(
            summary: VaultSummary(
                fileName: fileURL.lastPathComponent,
                groupCount: groups.count,
                entryCount: entries.filter { !$0.isTrashed }.count,
                masterKeyChangedAt: knownDate(tree.metaData?.masterKeyChanged),
                masterKeyChangeRecommendationDays: positiveDays(tree.metaData?.masterKeyChangeRecommendationInterval),
                masterKeyChangeEnforcementDays: positiveDays(tree.metaData?.masterKeyChangeEnforcementInterval),
                supportsEntryTypes: supportsEntryTypes(tree),
                templatesGroupPath: templatesGroup(in: tree)?.breadcrumb
            ),
            groups: groups,
            entries: entries
        )
    }

    /// KeePassKit writes the lowest version the tree needs; entry CustomData needs KDBX 4.
    private static func supportsEntryTypes(_ tree: KPKTree) -> Bool {
        let version = tree.minimumVersion
        return version.format.rawValue == 2 && version.version >= UInt(kKPKKdbxFileVersion4)
    }

    private static func templatesGroup(in tree: KPKTree) -> KPKGroup? {
        guard let uuid = tree.metaData?.entryTemplatesGroupUuid, uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            return nil
        }
        return tree.allGroups.first { $0.uuid == uuid && !$0.isTrashed }
    }

    private static func findGroup(in tree: KPKTree, path: String?) -> KPKGroup? {
        guard let path, !path.isEmpty else {
            return tree.root
        }

        let groups = [tree.root].compactMap { $0 } + tree.allGroups
        return groups.first { $0.breadcrumb == path }
    }

    private static func findEntry(in tree: KPKTree, id: UUID) -> KPKEntry? {
        tree.allEntries.first { $0.uuid.uuidString.lowercased() == id.uuidString.lowercased() }
    }

    private static func mapEntry(_ entry: KPKEntry) -> VaultEntry {
        let otp = makeOTPConfiguration(from: entry)
        let history = sortedHistoryEntries(from: entry)
            .map(mapRevision)
            .sorted { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.id.uuidString > rhs.id.uuidString
                }
            }

        let resolver = ReferenceResolver(entry: entry)
        let title = resolver.resolve(entry.title ?? "", field: VaultEntryReferences.title)
        let username = resolver.resolve(entry.username ?? "", field: VaultEntryReferences.username)
        let password = resolver.resolve(entry.password ?? "", field: VaultEntryReferences.password)
        let url = resolver.resolve(entry.url ?? "", field: VaultEntryReferences.url)
        let notes = resolver.resolve(entry.notes ?? "", field: VaultEntryReferences.notes)
        let fields = customFields(from: entry).map { field in
            VaultCustomField(key: field.key, value: resolver.resolve(field.value, field: field.key), isProtected: field.isProtected)
        }

        return VaultEntry(
            id: UUID(uuidString: entry.uuid.uuidString) ?? UUID(),
            groupPath: entry.parent?.breadcrumb ?? "",
            isTrashed: entry.isTrashed,
            modifiedAt: entry.timeInfo.modificationDate,
            createdAt: entry.timeInfo.creationDate,
            accessedAt: entry.timeInfo.accessDate,
            usageCount: Int(entry.timeInfo.usageCount),
            expiresAt: entry.timeInfo.expires ? entry.timeInfo.expirationDate : nil,
            passwordChangedAt: passwordChangedAt(for: entry),
            checksPasswordQuality: entry.checkPasswordQuality,
            title: title,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            url: normalizedURL(from: url),
            notes: notes.isEmpty ? nil : notes,
            tags: normalizedTags(from: entry.tags),
            foregroundColorHex: hexString(from: entry.foregroundColor),
            backgroundColorHex: hexString(from: entry.backgroundColor),
            customFields: fields,
            attachments: attachments(from: entry),
            iconPNGData: iconData(from: entry.icon),
            iconID: normalizedIconID(entry.iconId),
            otp: otp?.configuration,
            otpStorageStyle: otp?.storageStyle,
            history: history,
            entryType: entry.customData[VaultEntryType.customDataKey].flatMap(VaultEntryType.init(rawValue:)) ?? .login,
            templateName: entry.customData[VaultEntryType.templateCustomDataKey],
            references: resolver.references,
            sshAgent: sshAgentSettings(from: entry)
        )
    }

    private static func hexString(from color: NSColor?) -> String? {
        guard let color, let rgb = color.usingColorSpace(.sRGB) else {
            return nil
        }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func color(fromHex hex: String?) -> NSColor? {
        guard let hex else {
            return nil
        }
        var normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        guard normalized.count == 6, let value = UInt32(normalized, radix: 16) else {
            return nil
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// KeePass writes the reference date (2001-01-01) when a timestamp was never set.
    private static func knownDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate > 86_400 else {
            return nil
        }
        return date
    }

    private static func positiveDays(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }

    /// The date the current password was set: the oldest revision in the most
    /// recent run of history entries that share the current password.
    private static func passwordChangedAt(for entry: KPKEntry) -> Date? {
        var changedAt = entry.timeInfo.modificationDate
        for revision in sortedHistoryEntries(from: entry) {
            guard revision.password == entry.password else {
                return changedAt
            }
            changedAt = revision.timeInfo.modificationDate ?? changedAt
        }
        return entry.timeInfo.creationDate ?? changedAt
    }

    private static func mapRevision(_ entry: KPKEntry) -> VaultEntryRevision {
        let otp = makeOTPConfiguration(from: entry)
        return VaultEntryRevision(
            id: UUID(uuidString: entry.uuid.uuidString) ?? UUID(),
            modifiedAt: entry.timeInfo.modificationDate,
            groupPath: entry.parent?.breadcrumb ?? "",
            title: entry.title,
            username: entry.username.isEmpty ? nil : entry.username,
            password: entry.password.isEmpty ? nil : entry.password,
            url: normalizedURL(from: entry.url),
            notes: entry.notes.isEmpty ? nil : entry.notes,
            tags: normalizedTags(from: entry.tags),
            customFields: customFields(from: entry),
            attachments: attachments(from: entry),
            iconID: normalizedIconID(entry.iconId),
            otp: otp?.configuration,
            otpStorageStyle: otp?.storageStyle
        )
    }

    private static func normalizedTags(from tags: [String]?) -> [String] {
        guard let tags else {
            return []
        }
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private static func normalizedURL(from value: String) -> URL? {
        guard !value.isEmpty else {
            return nil
        }
        return URL(string: value)
    }

    private static func customFields(from entry: KPKEntry) -> [VaultCustomField] {
        entry.customAttributes
            .filter { !isSystemCustomFieldKey($0.key) }
            .map {
                VaultCustomField(
                    key: $0.key,
                    value: $0.value,
                    isProtected: $0.protect
                )
            }
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
    }

    /// The entry's files, without `KeeAgent.settings` (shown as the entry's SSH agent settings instead).
    private static func attachments(from entry: KPKEntry) -> [VaultAttachment] {
        entry.binaries
            .filter { $0.name != VaultSSHAgentSettings.attachmentName }
            .map {
                VaultAttachment(name: $0.name, data: $0.data, isProtected: $0.protect)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func sortedHistoryEntries(from entry: KPKEntry) -> [KPKEntry] {
        entry.history.sorted { lhs, rhs in
            switch (lhs.timeInfo.modificationDate, rhs.timeInfo.modificationDate) {
            case let (lhsDate?, rhsDate?):
                return lhsDate > rhsDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.uuid.uuidString > rhs.uuid.uuidString
            }
        }
    }

    private static func resolveRestoreGroup(for entry: KPKEntry, in tree: KPKTree) -> KPKGroup {
        if let previousParent = entry.previousParent,
           let restoredGroup = tree.root?.forUUID(previousParent),
           restoredGroup !== tree.trash {
            return restoredGroup
        }

        if let currentParent = entry.parent, currentParent !== tree.trash {
            return currentParent
        }

        if let root = tree.root {
            return root
        }

        let root = tree.createGroup(nil)
        root.title = "Root"
        tree.root = root
        return root
    }

    private static func apply(form: VaultEntryForm, to entry: KPKEntry) throws {
        let normalizedTitle = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw VaultError.parseFailure(details: "Entry title cannot be empty.")
        }

        entry.title = normalizedTitle
        entry.username = form.username
        entry.password = form.password
        entry.url = form.url
        entry.notes = form.notes
        entry.tags = normalizedTags(from: form.tags)
        entry.foregroundColor = color(fromHex: form.foregroundColorHex)
        entry.backgroundColor = color(fromHex: form.backgroundColorHex)
        entry.iconId = form.iconID ?? Int(KPKEntry.defaultIcon())
        entry.checkPasswordQuality = form.checksPasswordQuality
        if let expiresAt = form.expiresAt {
            entry.timeInfo.expirationDate = expiresAt
            entry.timeInfo.expires = true
        } else {
            entry.timeInfo.expires = false
        }

        try applyCustomFields(form.customFields, to: entry)
        applyAttachments(form.attachments, to: entry)
        try applyOTP(form.otp, to: entry, title: normalizedTitle)
        applyEntryType(form, to: entry)
        applySSHAgent(form.sshAgent, to: entry)
    }

    private static func sshAgentSettings(from entry: KPKEntry) -> VaultSSHAgentSettings? {
        guard let file = entry.binaries.first(where: { $0.name == VaultSSHAgentSettings.attachmentName }),
              var settings = VaultSSHAgentSettings(keeAgentData: file.data) else {
            return nil
        }
        settings.applyCustomData(entry.customData[VaultSSHAgentSettings.customDataKey])
        return settings
    }

    /// `applyAttachments` already dropped the old `KeeAgent.settings`; nil settings leave it out.
    private static func applySSHAgent(_ settings: VaultSSHAgentSettings?, to entry: KPKEntry) {
        if let existing = entry.binaries.first(where: { $0.name == VaultSSHAgentSettings.attachmentName }) {
            entry.removeBinary(existing)
        }
        guard let settings else {
            entry.removeCustomData(forKey: VaultSSHAgentSettings.customDataKey)
            return
        }
        if let binary = KPKBinary(name: VaultSSHAgentSettings.attachmentName, data: settings.keeAgentData) {
            entry.addBinary(binary)
        }
        if let value = settings.customDataValue {
            entry.setCustomData(value, forKey: VaultSSHAgentSettings.customDataKey)
        } else {
            entry.removeCustomData(forKey: VaultSSHAgentSettings.customDataKey)
        }
    }

    private static func applyEntryType(_ form: VaultEntryForm, to entry: KPKEntry) {
        if form.entryType == .login {
            entry.removeCustomData(forKey: VaultEntryType.customDataKey)
        } else {
            entry.setCustomData(form.entryType.rawValue, forKey: VaultEntryType.customDataKey)
        }
        if form.entryType == .template, let templateName = form.templateName, !templateName.isEmpty {
            entry.setCustomData(templateName, forKey: VaultEntryType.templateCustomDataKey)
        } else {
            entry.removeCustomData(forKey: VaultEntryType.templateCustomDataKey)
        }
    }

    private static func applyCustomFields(_ customFields: [VaultCustomFieldForm], to entry: KPKEntry) throws {
        var seenKeys = Set<String>()
        for field in customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw VaultError.parseFailure(details: "Custom field key cannot be empty.")
            }
            let normalized = key.lowercased()
            guard !seenKeys.contains(normalized) else {
                throw VaultError.parseFailure(details: "Custom field keys must be unique.")
            }
            seenKeys.insert(normalized)
        }

        for attribute in entry.customAttributes where !isSystemCustomFieldKey(attribute.key) {
            entry.removeCustomAttribute(attribute)
        }

        for field in customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let attribute = KPKAttribute(key: key, value: field.value, isProtected: field.isProtected)
            entry.addCustomAttribute(attribute)
        }
    }

    private static func applyAttachments(_ attachments: [VaultAttachment], to entry: KPKEntry) {
        for binary in entry.binaries {
            entry.removeBinary(binary)
        }

        for attachment in attachments {
            let binary = KPKBinary(name: attachment.name, data: attachment.data)
            binary?.protect = attachment.isProtected
            if let binary {
                entry.addBinary(binary)
            }
        }
    }

    private static func applyOTP(_ otp: VaultOTPForm?, to entry: KPKEntry, title: String) throws {
        clearOTPAttributes(on: entry)

        guard let otp else {
            return
        }

        let secret = encodeBase32(try decodeOTPSecretInput(otp.secret))
        let clampedDigits = min(max(otp.digits, 6), 9)
        let period = max(otp.period, 1)
        let counter = UInt64(max(otp.counter, 0))

        switch (otp.kind, otp.storageStyle) {
        case (.hotp, _):
            // KeePass stores HOTP natively; its fields have no digits or algorithm, so other
            // settings also go into an `otpauth://hotp` URI.
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyHmacOTPSecretBase32, value: secret, protect: true)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyHmacOTPCounter, value: String(counter), protect: false)
            if clampedDigits != 6 || otp.algorithm != .sha1 {
                let uri = VaultOTPURI.make(kind: .hotp, secret: secret, label: title, digits: clampedDigits, period: period, algorithm: otp.algorithm, counter: counter)
                upsertCustomAttribute(on: entry, key: kKPKAttributeKeyOTPOAuthURL, value: uri, protect: false)
            }

        case (.steam, .native):
            // KeeOtp's format, also read by KeePassXC.
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSeed, value: secret, protect: true)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSettings, value: "\(VaultOTPURI.steamPeriod);S", protect: false)

        case (.steam, .otpAuth), (.totp, .otpAuth):
            let uri = VaultOTPURI.make(kind: otp.kind, secret: secret, label: title, digits: clampedDigits, period: period, algorithm: otp.algorithm, counter: 0)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyOTPOAuthURL, value: uri, protect: false)

        case (.totp, .native):
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSecretBase32, value: secret, protect: true)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPLength, value: String(clampedDigits), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPPeriod, value: String(period), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPAlgorithm, value: otpAlgorithmValue(otp.algorithm), protect: false)
            upsertCustomAttribute(on: entry, key: kKPKAttributeKeyTimeOTPSettings, value: "period=\(period);digits=\(clampedDigits)", protect: false)
        }
    }

    /// Stores the HOTP counter of the next code, in the native field and in an `otpauth://hotp` URI if there is one.
    private static func setHOTPCounter(_ counter: UInt64, on entry: KPKEntry) {
        upsertCustomAttribute(on: entry, key: kKPKAttributeKeyHmacOTPCounter, value: String(counter), protect: false)
        guard let attribute = entry.customAttribute(withKey: kKPKAttributeKeyOTPOAuthURL),
              var components = URLComponents(string: attribute.value ?? ""),
              components.host?.lowercased() == "hotp" else {
            return
        }
        var items = (components.queryItems ?? []).filter { $0.name.lowercased() != "counter" }
        items.append(URLQueryItem(name: "counter", value: String(counter)))
        components.queryItems = items
        if let uri = components.string {
            attribute.value = uri
        }
    }

    /// A merge keeps the newer entry, but an HOTP counter must never go back: a lower one
    /// would hand out codes the server has already seen.
    private static func keepHighestHOTPCounters(in target: KPKTree, from source: KPKTree) {
        raiseHOTPCounters(in: target, to: hotpCounters(in: source))
    }

    private struct HOTPCounter {
        let secret: Data
        let counter: UInt64
    }

    private static func hotpCounters(in tree: KPKTree) -> [UUID: HOTPCounter] {
        var counters: [UUID: HOTPCounter] = [:]
        for entry in tree.allEntries where !entry.isHistory {
            if let otp = makeOTPConfiguration(from: entry)?.configuration, otp.kind == .hotp {
                counters[entry.uuid] = HOTPCounter(secret: otp.secret, counter: otp.counter)
            }
        }
        return counters
    }

    private static func raiseHOTPCounters(in tree: KPKTree, to counters: [UUID: HOTPCounter]) {
        guard !counters.isEmpty else {
            return
        }
        for entry in tree.allEntries where !entry.isHistory {
            guard let known = counters[entry.uuid],
                  let otp = makeOTPConfiguration(from: entry)?.configuration,
                  otp.kind == .hotp,
                  otp.secret == known.secret,
                  otp.counter < known.counter else {
                continue
            }
            setHOTPCounter(known.counter, on: entry)
        }
    }

    private static func decodeOTPSecretInput(_ value: String) throws -> Data {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw VaultError.parseFailure(details: "OTP secret cannot be empty.")
        }

        if let base32 = decodeBase32(normalized), !base32.isEmpty {
            return base32
        }
        if let base64 = Data(base64Encoded: normalized), !base64.isEmpty {
            return base64
        }
        if let hex = decodeHex(normalized), !hex.isEmpty {
            return hex
        }

        throw VaultError.parseFailure(details: "OTP secret must be valid Base32, Base64, or Hex.")
    }

    private static func clearOTPAttributes(on entry: KPKEntry) {
        for key in otpReservedCustomKeys {
            if let attribute = entry.customAttribute(withKey: key) {
                entry.removeCustomAttribute(attribute)
            }
        }
    }

    private static func upsertCustomAttribute(on entry: KPKEntry, key: String, value: String, protect: Bool) {
        if let existing = entry.customAttribute(withKey: key) {
            existing.value = value
            existing.protect = protect
            return
        }

        let attribute = KPKAttribute(key: key, value: value, isProtected: protect)
        entry.addCustomAttribute(attribute)
    }

    private static func otpAlgorithmValue(_ algorithm: VaultOTPAlgorithm) -> String {
        switch algorithm {
        case .sha1:
            return kKPKAttributeValueTimeOTPHmacSha1
        case .sha256:
            return kKPKAttributeValueTimeOTPHmacSha256
        case .sha512:
            return kKPKAttributeValueTimeOTPHmacSha512
        }
    }

    private static let otpReservedCustomKeys: Set<String> = [
        kKPKAttributeKeyOTPOAuthURL,
        kKPKAttributeKeyHmacOTPSecret,
        kKPKAttributeKeyHmacOTPSecretHex,
        kKPKAttributeKeyHmacOTPSecretBase32,
        kKPKAttributeKeyHmacOTPSecretBase64,
        kKPKAttributeKeyHmacOTPCounter,
        kKPKAttributeKeyTimeOTPSecret,
        kKPKAttributeKeyTimeOTPSecretHex,
        kKPKAttributeKeyTimeOTPSecretBase32,
        kKPKAttributeKeyTimeOTPSecretBase64,
        kKPKAttributeKeyTimeOTPLength,
        kKPKAttributeKeyTimeOTPPeriod,
        kKPKAttributeKeyTimeOTPAlgorithm,
        kKPKAttributeKeyTimeOTPSeed,
        kKPKAttributeKeyTimeOTPSettings
    ]

    private static func isSystemCustomFieldKey(_ key: String) -> Bool {
        otpReservedCustomKeys.contains(key)
    }

    private static func normalizedDatabaseFormat(_ format: KPKDatabaseFormat) -> KPKDatabaseFormat {
        if format.rawValue == 0 {
            return KPKDatabaseFormat(rawValue: 2) ?? format
        }
        return format
    }

    private static func preferredSaveFormat(for fileURL: URL, minimumVersionFormat: KPKDatabaseFormat) -> KPKDatabaseFormat {
        let normalizedMinimum = normalizedDatabaseFormat(minimumVersionFormat)

        if fileURL.pathExtension.lowercased() == "kdbx" {
            return KPKDatabaseFormat(rawValue: 2) ?? normalizedMinimum
        }
        return normalizedMinimum
    }

    static func mapKeePassError(_ error: NSError?) -> VaultError {
        guard let error else {
            return .unknown(details: nil)
        }

        if error.domain == KPKErrorDomain {
            let normalized = error.localizedDescription.lowercased()

            if normalized.contains("password")
                || normalized.contains("keyfile")
                || normalized.contains("header hash") {
                return .invalidPassword
            }
            if normalized.contains("unsupported") {
                return .unsupportedKDBXVariant
            }
            return .parseFailure(details: error.localizedDescription)
        }

        return .unknown(details: error.localizedDescription)
    }

    private static func makeOTPConfiguration(from entry: KPKEntry) -> ResolvedOTP? {
        let fromURI = parseOTPAuthConfiguration(from: entry)
        if let hotp = parseHmacOTPConfiguration(from: entry, uri: fromURI?.configuration) {
            return hotp
        }
        if let fromURI {
            return fromURI
        }
        guard entry.hasTimeOTP else {
            return nil
        }
        return parseNativeTimeOTPConfiguration(from: entry, isSteam: entry.hasSteamOTP)
    }

    private static func iconData(from icon: KPKIcon?) -> Data? {
        guard
            let encodedString = icon?.encodedString,
            !encodedString.isEmpty
        else {
            return nil
        }
        return Data(base64Encoded: encodedString)
    }

    private static func normalizedIconID(_ rawValue: Int) -> Int? {
        guard rawValue >= 0 else {
            return nil
        }
        return rawValue
    }

    private static func parseOTPAuthConfiguration(from entry: KPKEntry) -> ResolvedOTP? {
        guard let uri = entry.valueForAttribute(withKey: kKPKAttributeKeyOTPOAuthURL),
              let form = VaultOTPURI.parse(uri),
              !form.secret.isEmpty,
              let secret = decodeBase32(form.secret) ?? Data(base64Encoded: form.secret) else {
            return nil
        }

        return ResolvedOTP(
            configuration: VaultOTPConfiguration(
                secret: secret,
                digits: form.kind == .steam ? VaultOTPURI.steamDigits : clampDigits(form.digits),
                period: max(form.period, 1),
                timeBase: 0,
                algorithm: form.algorithm,
                kind: form.kind,
                counter: UInt64(form.counter)
            ),
            storageStyle: .otpAuth
        )
    }

    /// KeePass 2.47 `HmacOtp-*` fields. Digits and algorithm come from an `otpauth://hotp` URI when there is one;
    /// the native counter wins because it is what KeePass advances.
    private static func parseHmacOTPConfiguration(from entry: KPKEntry, uri: VaultOTPConfiguration?) -> ResolvedOTP? {
        let secret = decodeHmacOTPSecret(from: entry)
        guard !secret.isEmpty else {
            return nil
        }
        let uri = uri?.kind == .hotp ? uri : nil
        let counter = UInt64(entry.valueForAttribute(withKey: kKPKAttributeKeyHmacOTPCounter)?
            .trimmingCharacters(in: .whitespaces) ?? "") ?? uri?.counter ?? 0

        return ResolvedOTP(
            configuration: VaultOTPConfiguration(
                secret: secret,
                digits: uri?.digits ?? 6,
                period: 30,
                timeBase: 0,
                algorithm: uri?.algorithm ?? .sha1,
                kind: .hotp,
                counter: counter
            ),
            storageStyle: .native
        )
    }

    /// `HmacOtp-Secret` holds the key's UTF-8 text; the suffixed fields are encodings.
    private static func decodeHmacOTPSecret(from entry: KPKEntry) -> Data {
        if let base32 = entry.valueForAttribute(withKey: kKPKAttributeKeyHmacOTPSecretBase32), let secret = decodeBase32(base32) {
            return secret
        }
        if let base64 = entry.valueForAttribute(withKey: kKPKAttributeKeyHmacOTPSecretBase64), let secret = Data(base64Encoded: base64) {
            return secret
        }
        if let hex = entry.valueForAttribute(withKey: kKPKAttributeKeyHmacOTPSecretHex), let secret = decodeHex(hex) {
            return secret
        }
        if let text = entry.valueForAttribute(withKey: kKPKAttributeKeyHmacOTPSecret), !text.isEmpty {
            return Data(text.utf8)
        }
        return Data()
    }

    private static func parseNativeTimeOTPConfiguration(from entry: KPKEntry, isSteam: Bool) -> ResolvedOTP? {
        let secret = decodeTimeOTPSecret(from: entry)
        guard !secret.isEmpty else {
            return nil
        }

        let settingsValues = parseSettings(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSettings))
        let periodFromSettings = settingsValues.first
        let digitsFromSettings = settingsValues.dropFirst().first

        let period = max(
            Int(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPPeriod) ?? "")
                ?? periodFromSettings
                ?? 30,
            1
        )
        let digits = clampDigits(
            Int(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPLength) ?? "")
                ?? digitsFromSettings
        )
        let algorithm = parseOTPAlgorithm(entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPAlgorithm))

        return ResolvedOTP(
            configuration: VaultOTPConfiguration(
                secret: secret,
                digits: isSteam ? VaultOTPURI.steamDigits : digits,
                period: period,
                timeBase: 0,
                algorithm: isSteam ? .sha1 : algorithm,
                kind: isSteam ? .steam : .totp
            ),
            storageStyle: .native
        )
    }

    private static func decodeTimeOTPSecret(from entry: KPKEntry) -> Data {
        if let base32 = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretBase32),
           let secret = decodeBase32(base32) {
            return secret
        }
        if let base64 = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretBase64),
           let secret = Data(base64Encoded: base64) {
            return secret
        }
        if let hex = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecretHex),
           let secret = decodeHex(hex) {
            return secret
        }
        if let seed = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSeed),
           let secret = decodeBase32(seed) {
            return secret
        }
        if let generic = entry.valueForAttribute(withKey: kKPKAttributeKeyTimeOTPSecret) {
            if let secret = decodeBase32(generic) {
                return secret
            }
            if let secret = Data(base64Encoded: generic) {
                return secret
            }
            if let secret = decodeHex(generic) {
                return secret
            }
        }
        return Data()
    }

    private static func parseOTPAlgorithm(_ value: String?) -> VaultOTPAlgorithm {
        guard let value else {
            return .sha1
        }

        let normalized = value.lowercased()
        if normalized == kKPKAttributeValueTimeOTPHmacSha256.lowercased() || normalized.contains("256") {
            return .sha256
        }
        if normalized == kKPKAttributeValueTimeOTPHmacSha512.lowercased() || normalized.contains("512") {
            return .sha512
        }
        return .sha1
    }

    private static func parseSettings(_ value: String?) -> [Int] {
        guard let value else {
            return []
        }

        return value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func clampDigits(_ value: Int?) -> Int {
        min(max(value ?? 6, 1), 9)
    }

    private static func decodeHex(_ value: String) -> Data? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func decodeBase32(_ value: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            lookup[char] = UInt8(index)
        }

        let normalized = value.uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "=" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        guard !normalized.isEmpty else {
            return nil
        }

        var buffer: UInt64 = 0
        var bitsLeft = 0
        var result = Data()

        for character in normalized {
            guard let v = lookup[character] else {
                return nil
            }

            buffer = (buffer << 5) | UInt64(v)
            bitsLeft += 5

            while bitsLeft >= 8 {
                let byte = UInt8((buffer >> UInt64(bitsLeft - 8)) & 0xff)
                result.append(byte)
                bitsLeft -= 8
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func encodeBase32(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}

/// Database settings that a merge with another database must not take over.
private struct MetadataSnapshot {
    let databaseName: String?
    let databaseDescription: String?
    let defaultUserName: String?
    let color: NSColor?
    let keyDerivationParameters: [AnyHashable: Any]?
    let cipherUUID: UUID?
    let compressionAlgorithm: UInt32
    let masterKeyChanged: Date?
    let masterKeyChangeRecommendationInterval: Int
    let masterKeyChangeEnforcementInterval: Int
    let enforceMasterKeyChangeOnce: Bool
    let maintenanceHistoryDays: Int
    let historyMaxItems: Int
    let historyMaxSize: Int
    let useTrash: Bool
    let trashUuid: UUID?
    let entryTemplatesGroupUuid: UUID?

    init(_ meta: KPKMetaData) {
        databaseName = meta.databaseName
        databaseDescription = meta.databaseDescription
        defaultUserName = meta.defaultUserName
        color = meta.color
        keyDerivationParameters = meta.keyDerivationParameters
        cipherUUID = meta.cipherUUID
        compressionAlgorithm = meta.compressionAlgorithm
        masterKeyChanged = meta.masterKeyChanged
        masterKeyChangeRecommendationInterval = meta.masterKeyChangeRecommendationInterval
        masterKeyChangeEnforcementInterval = meta.masterKeyChangeEnforcementInterval
        enforceMasterKeyChangeOnce = meta.enforceMasterKeyChangeOnce
        maintenanceHistoryDays = meta.maintenanceHistoryDays
        historyMaxItems = meta.historyMaxItems
        historyMaxSize = meta.historyMaxSize
        useTrash = meta.useTrash
        trashUuid = meta.trashUuid
        entryTemplatesGroupUuid = meta.entryTemplatesGroupUuid
    }

    func restore(into meta: KPKMetaData) {
        if meta.databaseName != databaseName { meta.databaseName = databaseName }
        if meta.databaseDescription != databaseDescription { meta.databaseDescription = databaseDescription }
        if meta.defaultUserName != defaultUserName { meta.defaultUserName = defaultUserName }
        meta.color = color
        meta.keyDerivationParameters = keyDerivationParameters
        meta.cipherUUID = cipherUUID
        meta.compressionAlgorithm = compressionAlgorithm
        meta.masterKeyChanged = masterKeyChanged
        meta.masterKeyChangeRecommendationInterval = masterKeyChangeRecommendationInterval
        meta.masterKeyChangeEnforcementInterval = masterKeyChangeEnforcementInterval
        meta.enforceMasterKeyChangeOnce = enforceMasterKeyChangeOnce
        meta.maintenanceHistoryDays = maintenanceHistoryDays
        meta.historyMaxItems = historyMaxItems
        meta.historyMaxSize = historyMaxSize
        meta.useTrash = useTrash
        if meta.trashUuid != trashUuid { meta.trashUuid = trashUuid }
        if meta.entryTemplatesGroupUuid != entryTemplatesGroupUuid { meta.entryTemplatesGroupUuid = entryTemplatesGroupUuid }
    }
}

/// Resolves KeePass references and placeholders in an entry's fields with KeePassKit,
/// remembering the stored text so the editor can keep it.
private final class ReferenceResolver {
    private static let options: KPKCommandEvaluationOptions = [.skipUserInteraction, .readOnly]
    /// `{REF:P@I:4F3A…}`: the referenced entry's UUID, with or without dashes.
    private static let uuidReference = try? NSRegularExpression(pattern: "^\\{REF:[TUPANI]@I:([0-9A-Fa-f-]{32,36})\\}$", options: [.caseInsensitive])

    private let entry: KPKEntry
    private var rawValues: [String: String] = [:]
    private var sources: [String: UUID] = [:]
    private var brokenFields: Set<String> = []

    init(entry: KPKEntry) {
        self.entry = entry
    }

    var references: VaultEntryReferences? {
        rawValues.isEmpty ? nil : VaultEntryReferences(rawValues: rawValues, sources: sources, brokenFields: brokenFields)
    }

    func resolve(_ value: String, field: String) -> String {
        guard value.contains("{") else {
            return value
        }
        let resolved = value.kpk_finalValue(for: entry, options: Self.options) ?? value
        let isBroken = resolved.range(of: "{REF:", options: .caseInsensitive) != nil
        guard resolved != value || isBroken else {
            return value
        }
        rawValues[field] = value
        if isBroken {
            brokenFields.insert(field)
        } else if let source = Self.source(of: value) {
            sources[field] = source
        }
        return resolved
    }

    fileprivate static func source(of value: String) -> UUID? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = uuidReference?.firstMatch(in: trimmed, range: range),
              let idRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        var hex = trimmed[idRange].replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else {
            return nil
        }
        for index in [8, 13, 18, 23] {
            hex.insert("-", at: hex.index(hex.startIndex, offsetBy: index))
        }
        return UUID(uuidString: hex)
    }
}
