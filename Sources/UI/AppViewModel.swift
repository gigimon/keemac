import Data
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class AppViewModel {
    private enum PersistedSelectionKey {
        static let vaultBookmark = "keemac.selection.vault.bookmark"
        static let keyFileBookmark = "keemac.selection.keyfile.bookmark"
        static let biometricVaultPath = "keemac.selection.biometric.vault.path"
        static let recentVaults = "keemac.selection.recent.v1"
        static let favoriteEntries = "keemac.entries.favorites.v1"
    }

    public enum LockReason: String, Sendable {
        case userInitiated
        case idleTimeout
        case systemSleep
        case screenLocked
        case sessionSwitched
        case appQuit
        /// Locked again after Quick Access unlocked the database for a moment.
        case quickAccess

        var message: String {
            switch self {
            case .userInitiated:
                return L("Vault was locked.")
            case .idleTimeout:
                return L("Vault was locked after inactivity timeout.")
            case .systemSleep:
                return L("Vault was locked because the system is going to sleep.")
            case .screenLocked:
                return L("Vault was locked because the screen was locked.")
            case .sessionSwitched:
                return L("Vault was locked because you switched users.")
            case .appQuit, .quickAccess:
                return L("Vault was locked.")
            }
        }
    }

    public enum SyncStatus: Equatable {
        case idle
        case merging
        case synced(Date)
        case changedOnDisk
        case notWatching
        case failed(String)
    }

    public enum MergeSheetKind: Equatable, Sendable {
        /// Ask mode: preview what the file on disk would bring in.
        case diskChanges
        /// "Merge Database…": pick another file and its key.
        case database
        case conflictCopies([VaultConflictCopy])
    }

    /// Asks the browser to open Database Report → Password Health with the given expiry window.
    public struct PasswordHealthRequest: Equatable, Sendable {
        public let id = UUID()
        public let warnDays: Int
    }

    public struct MergeSheetRequest: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let kind: MergeSheetKind
    }

    public enum SyncAlert: Identifiable, Equatable, Sendable {
        case conflictCopies([VaultConflictCopy])
        case trashCopies([VaultConflictCopy])

        public var id: String {
            switch self {
            case .conflictCopies:
                return "conflictCopies"
            case .trashCopies:
                return "trashCopies"
            }
        }
    }

    /// What happened to an entry on another device, for the "updated on another device" markers.
    public struct ExternalChange: Equatable, Sendable {
        public let date: Date
        public let isConflict: Bool
        public let isRestored: Bool
        public let previousGroupPath: String?
    }

    /// Asks the browser to bring entries into view (toast "Show" action).
    public struct RevealRequest: Equatable, Sendable {
        public let id = UUID()
        public let entryIDs: [UUID]
        /// Selects this group in the sidebar instead of the "changed elsewhere" list (after an import).
        public var groupPath: String?
        /// Opens the entry's editor with the Auto-Type section expanded (after an Auto-Type error).
        public var editsAutoType = false
    }

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded(LoadedVault)
        case locked(String)
        case failed(String)

        public var isUnlocked: Bool {
            if case .loaded = self {
                return true
            }
            return false
        }
    }

    public struct RecentVault: Identifiable, Equatable {
        public let vaultURL: URL
        public let keyFileURL: URL?

        public var id: String {
            vaultURL.standardizedFileURL.path
        }

        public var title: String {
            vaultURL.lastPathComponent
        }
    }

    private struct PersistedRecentVault: Codable {
        let vaultBookmark: Data
        let keyFileBookmark: Data?
    }

    private struct PersistedFavoriteEntries: Codable {
        let vaultPath: String
        let entryIDs: [String]
    }

    public var selectedVaultURL: URL?
    public var selectedKeyFileURL: URL?
    /// The YubiKey slot used with the selected database (remembered per database after a successful unlock).
    public private(set) var selectedHardwareKey: VaultHardwareKey?
    /// Slots of the connected YubiKeys, from the last `refreshHardwareKeys()`.
    public private(set) var connectedHardwareKeys: [VaultHardwareKey] = []
    public private(set) var isScanningHardwareKeys = false
    /// Why the last scan found nothing usable (no access, hidden serial number); nil when it worked.
    public private(set) var hardwareKeyScanError: String?
    public var loadState: LoadState = .idle {
        didSet {
            if loadState.isUnlocked {
                Task { await refreshUndoState() }
            } else {
                undoState = .empty
            }
            if oldValue.isUnlocked != loadState.isUnlocked {
                NotificationCenter.default.post(
                    name: AppCommand.vaultLockStateChanged,
                    object: self,
                    userInfo: [AppCommand.vaultUnlockedUserInfoKey: loadState.isUnlocked]
                )
            }
        }
    }
    public private(set) var showBiometricUnlockScreen: Bool = false
    public private(set) var recentVaults: [RecentVault] = []
    public private(set) var favoriteEntryIDs: Set<UUID> = []
    public private(set) var recentViewedEntryIDs: [UUID] = []
    public private(set) var syncStatus: SyncStatus = .idle
    public var showsImportSheet = false
    public var showsExportSheet = false
    /// What ⌘Z and ⇧⌘Z would undo or redo in the open database.
    public private(set) var undoState: VaultUndoState = .empty
    /// Entries changed by another device since they were last viewed here.
    public private(set) var externalChanges: [UUID: ExternalChange] = [:]
    public private(set) var lastMergeSummary: VaultMergeSummary?
    public private(set) var revealRequest: RevealRequest?
    /// Set when merging changes from disk failed; drives the error dialog.
    public private(set) var syncFailureMessage: String?
    public private(set) var mergeSheet: MergeSheetRequest?
    /// One-line reminder above the list after unlocking when passwords expired or expire soon.
    public private(set) var showsExpiryBanner = false
    public private(set) var passwordHealthRequest: PasswordHealthRequest?
    public private(set) var syncAlert: SyncAlert?
    private var hasPendingDiskChange = false
    private var isDiskChangeBannerHidden = false

    // Additional databases (AdditionalDatabases.swift).
    /// Databases attached to the main one: always listed, opened with their own password for this session only.
    public internal(set) var additionalDatabases: [AdditionalDatabase] = []
    /// Unlocked additional databases by key, with their own IDs and paths.
    var additionalVaults: [String: LoadedVault] = [:]
    @ObservationIgnored var additionalLoaders: [String: KeePassKitVaultLoader] = [:]
    /// Per-session salt that keeps each additional database's entry IDs apart from the main one's (backups share UUIDs).
    @ObservationIgnored var additionalSalts: [String: UUID] = [:]
    @ObservationIgnored var lastTransfer: CompletedTransfer?
    @ObservationIgnored var additionalLockTasks: [Task<Void, Never>] = []
    /// The database of the browser's selection; ⌘Z and the undo menu follow it. Nil is the main database.
    public var activeDatabaseKey: String? {
        didSet {
            if oldValue != activeDatabaseKey {
                Task { await refreshUndoState() }
            }
        }
    }

    public var externallyChangedEntryIDs: Set<UUID> {
        Set(externalChanges.keys)
    }
    public var clipboardAutoClearTimeoutSeconds: TimeInterval {
        get { settingsStore.clipboardAutoClearTimeoutSeconds }
        set { settingsStore.clipboardAutoClearTimeoutSeconds = newValue }
    }

    public var touchIDEnabledForSelectedVault: Bool {
        settingsStore.isTouchIDEnabled(for: selectedVaultURL)
    }

    public func isTouchIDEnabled(for vaultURL: URL) -> Bool {
        settingsStore.isTouchIDEnabled(for: vaultURL)
    }

    public var idleLockTimeoutForSelectedVault: TimeInterval {
        settingsStore.idleLockTimeoutSeconds(for: selectedVaultURL)
    }

    public var showDockIcon: Bool {
        settingsStore.showDockIcon
    }

    public var startMinimized: Bool {
        get { settingsStore.startMinimized }
        set { settingsStore.startMinimized = newValue }
    }

    public var includeSubgroupEntriesInGroupView: Bool {
        get { settingsStore.includeSubgroupEntries }
        set { settingsStore.includeSubgroupEntries = newValue }
    }

    let vaultLoader: any VaultLoading
    private let vaultEditor: (any VaultEditing)?
    private let sessionController: (any VaultSessionControlling)?
    private let databaseManager: (any VaultDatabaseManaging)?
    private let vaultCreator: (any VaultCreating)?
    private let synchronizer: (any VaultSynchronizing)?
    private let undoer: (any VaultUndoing)?
    private let transfer: (any VaultTransferring)?
    private let autoTyper: (any VaultAutoTyping)?
    private let hardwareKeyManager: (any VaultHardwareKeyManaging)?
    private let hardwareKeyDevice: any HardwareKeyChallenging
    /// The response last written for Touch ID, so unchanged ones aren't written again on every save.
    @ObservationIgnored private var storedHardwareKeyResponse: VaultHardwareKeyResponse?
    private var fileWatcher: VaultFileWatcher?
    private var isCheckingDisk = false
    private let biometricCredentialStore: any BiometricCredentialStoring
    let settingsStore: AppSettingsStore
    private let userDefaults: UserDefaults
    private var idleLockTask: Task<Void, Never>?
    /// Bumped on every lock: a long save that finishes after the database locked mustn't open it again.
    private var lockGeneration = 0
    private var pendingLockTask: Task<Void, Never>?
    private var launchAtLoginState: LoginItemService.State = LoginItemService.state

    public convenience init(
        vaultLoader: any VaultLoading = KeePassKitVaultLoader(
            snapshotDirectory: UITesting.isActive ? nil : KeePassKitVaultLoader.defaultSnapshotDirectory,
            hardwareKeys: HardwareKeys.prompting
        ),
        settingsStore: AppSettingsStore = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.init(
            vaultLoader: vaultLoader,
            settingsStore: settingsStore,
            userDefaults: userDefaults,
            biometricCredentialStore: UITesting.isActive ? InMemoryBiometricCredentialStore() : KeychainBiometricCredentialStore(),
            hardwareKeyDevice: HardwareKeys.device
        )
    }

    init(
        vaultLoader: any VaultLoading,
        settingsStore: AppSettingsStore,
        userDefaults: UserDefaults,
        biometricCredentialStore: any BiometricCredentialStoring,
        hardwareKeyDevice: any HardwareKeyChallenging = HardwareKeys.device
    ) {
        self.vaultLoader = vaultLoader
        self.vaultEditor = vaultLoader as? any VaultEditing
        self.sessionController = vaultLoader as? any VaultSessionControlling
        self.databaseManager = vaultLoader as? any VaultDatabaseManaging
        self.vaultCreator = vaultLoader as? any VaultCreating
        self.synchronizer = vaultLoader as? any VaultSynchronizing
        self.undoer = vaultLoader as? any VaultUndoing
        self.transfer = vaultLoader as? any VaultTransferring
        self.autoTyper = vaultLoader as? any VaultAutoTyping
        self.hardwareKeyManager = vaultLoader as? any VaultHardwareKeyManaging
        self.hardwareKeyDevice = hardwareKeyDevice
        self.biometricCredentialStore = biometricCredentialStore
        self.settingsStore = settingsStore
        self.userDefaults = userDefaults
        restorePersistedSelections()
        restoreRecentVaults()
        refreshBiometricUnlockAvailability()
        reloadAdditionalDatabases()
    }

    public func selectVault(url: URL) {
        selectedVaultURL = url
        selectedHardwareKey = settingsStore.hardwareKey(for: url)
        reloadAdditionalDatabases()
        persistSelection(url, key: PersistedSelectionKey.vaultBookmark)
        restoreFavoriteEntries()
        recentViewedEntryIDs = []
        refreshBiometricUnlockAvailability()
        loadState = .idle
    }

    public func clearVaultSelection() {
        selectedVaultURL = nil
        selectedHardwareKey = nil
        reloadAdditionalDatabases()
        favoriteEntryIDs = []
        recentViewedEntryIDs = []
        userDefaults.removeObject(forKey: PersistedSelectionKey.vaultBookmark)
        showBiometricUnlockScreen = false
        loadState = .idle
    }

    public func selectKeyFile(url: URL?) {
        selectedKeyFileURL = url
        if let url {
            persistSelection(url, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }
        loadState = .idle
    }

    /// Forgets a database: drops it from the recent list, deletes KeeMac's copy of its last save
    /// and the password stored for Touch ID. The database file itself is not touched.
    public func removeRecentVault(_ recentVault: RecentVault) {
        if case .loaded = loadState, selectedVaultURL.map(vaultIdentity) == vaultIdentity(for: recentVault.vaultURL) {
            return
        }
        let identity = vaultIdentity(for: recentVault.vaultURL)
        recentVaults.removeAll { vaultIdentity(for: $0.vaultURL) == identity }
        persistRecentVaults()

        biometricCredentialStore.deleteMasterPassword(for: recentVault.vaultURL)
        biometricCredentialStore.deleteHardwareKeyResponse(for: recentVault.vaultURL)
        clearBiometricCredentialMarker(for: recentVault.vaultURL)
        if let synchronizer {
            Task {
                await synchronizer.discardSnapshot(for: recentVault.vaultURL)
            }
        }

        if selectedVaultURL.map(vaultIdentity) == identity {
            selectedKeyFileURL = nil
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
            clearVaultSelection()
        }
        refreshBiometricUnlockAvailability()
    }

    public func selectRecentVault(_ recentVault: RecentVault) {
        selectedVaultURL = recentVault.vaultURL
        selectedKeyFileURL = recentVault.keyFileURL
        selectedHardwareKey = settingsStore.hardwareKey(for: recentVault.vaultURL)
        reloadAdditionalDatabases()

        persistSelection(recentVault.vaultURL, key: PersistedSelectionKey.vaultBookmark)
        if let keyFileURL = recentVault.keyFileURL {
            persistSelection(keyFileURL, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }

        restoreFavoriteEntries()
        recentViewedEntryIDs = []
        refreshBiometricUnlockAvailability()
        loadState = .idle
    }

    public func unlock(masterPassword: String) async {
        guard let selectedVaultURL else {
            loadState = .failed(L("Select a .kdbx file first."))
            return
        }

        cancelIdleLockTimer()
        let hardwareKey = selectedHardwareKey
        let keyFileURL = selectedKeyFileURL
        loadState = .loading
        if let hardwareKey {
            await refreshHardwareKeys()
            guard connectedHardwareKeys.contains(where: { $0.isSameSlot(as: hardwareKey) }) else {
                loadState = .failed(VaultError.hardwareKeyNotFound(serial: hardwareKey.serial).errorDescription ?? "")
                return
            }
        }

        do {
            let loadedVault = try await loadVault(
                at: selectedVaultURL,
                masterPassword: masterPassword,
                keyFileURL: keyFileURL,
                hardwareKey: hardwareKey,
                knownResponse: nil
            )

            let touchIDEnabled = settingsStore.isTouchIDEnabled(for: selectedVaultURL)
            if touchIDEnabled && !masterPassword.isEmpty {
                do {
                    try biometricCredentialStore.saveMasterPassword(masterPassword, for: selectedVaultURL)
                    markBiometricCredentialAvailable(for: selectedVaultURL)
                } catch {
                    SecureLogger.logUnlockFailure(error)
                }
            } else if !touchIDEnabled {
                biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
                clearBiometricCredentialMarker(for: selectedVaultURL)
            }
            await rememberHardwareKey(hardwareKey, for: selectedVaultURL, storedResponse: nil)

            recordRecentVaultUsage(vaultURL: selectedVaultURL, keyFileURL: selectedKeyFileURL)
            restoreFavoriteEntries()
            syncEntryCollections(with: loadedVault)
            refreshBiometricUnlockAvailability()
            loadState = .loaded(loadedVault)
            startWatchingVault()
            remindAboutExpiry(in: loadedVault)
            refreshAdditionalDatabaseAvailability()
            registerUserActivity()
        } catch VaultError.hardwareKeyCancelled {
            loadState = .idle
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? L("Unknown error")
            loadState = .failed(message)
        }
    }

    /// Opens a database with its key file and, when one is chosen, its hardware key. The caller captures
    /// the selection first: it can change while hardware keys are scanned.
    private func loadVault(
        at vaultURL: URL,
        masterPassword: String,
        keyFileURL: URL?,
        hardwareKey: VaultHardwareKey?,
        knownResponse: VaultHardwareKeyResponse?
    ) async throws -> LoadedVault {
        if let hardwareKey {
            guard let hardwareKeyManager else {
                throw VaultError.missingDependency(name: "Hardware key support")
            }
            return try await hardwareKeyManager.loadVault(
                from: vaultURL,
                masterPassword: masterPassword,
                keyFileURL: keyFileURL,
                hardwareKey: hardwareKey,
                knownResponse: knownResponse
            )
        }
        return try await vaultLoader.loadVault(from: vaultURL, masterPassword: masterPassword, keyFileURL: keyFileURL)
    }

    /// After an unlock or a master key change: remembers the hardware key for this database (or forgets it
    /// when the database opens without one) and keeps the Touch ID copy of its response current.
    private func rememberHardwareKey(_ hardwareKey: VaultHardwareKey?, for vaultURL: URL, storedResponse: VaultHardwareKeyResponse?) async {
        settingsStore.setHardwareKey(hardwareKey, for: vaultURL)
        guard hardwareKey != nil,
              settingsStore.isTouchIDEnabled(for: vaultURL),
              settingsStore.touchIDSkipsHardwareKey(for: vaultURL) else {
            biometricCredentialStore.deleteHardwareKeyResponse(for: vaultURL)
            storedHardwareKeyResponse = nil
            return
        }
        guard let response = await hardwareKeyManager?.hardwareKeyResponse(),
              response != (storedResponse ?? storedHardwareKeyResponse) else {
            return
        }
        storedHardwareKeyResponse = response
        do {
            try biometricCredentialStore.saveHardwareKeyResponse(response, for: vaultURL)
        } catch {
            SecureLogger.logUnlockFailure(error)
        }
    }

    // MARK: - Hardware keys

    /// Chooses the hardware key for the next unlock (nil: none).
    public func selectHardwareKey(_ key: VaultHardwareKey?) {
        selectedHardwareKey = key
        if case .failed = loadState {
            loadState = .idle
        }
    }

    public var isSelectedHardwareKeyConnected: Bool {
        guard let selectedHardwareKey else {
            return false
        }
        return connectedHardwareKeys.contains { $0.isSameSlot(as: selectedHardwareKey) }
    }

    /// Looks for connected YubiKeys (off the main thread; USB requests take a moment).
    public func refreshHardwareKeys() async {
        isScanningHardwareKeys = true
        defer { isScanningHardwareKeys = false }
        let device = hardwareKeyDevice
        let keys: [VaultHardwareKey]
        do {
            keys = try await Task.detached { try device.connectedKeys() }.value
            hardwareKeyScanError = nil
        } catch {
            keys = []
            hardwareKeyScanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        connectedHardwareKeys = keys
        // Pick up the model name and touch setting of the remembered slot.
        if let selected = selectedHardwareKey, let current = keys.first(where: { $0.isSameSlot(as: selected) }), current != selected {
            selectedHardwareKey = current
        }
    }

    public var touchIDSkipsHardwareKeyForSelectedVault: Bool {
        settingsStore.touchIDSkipsHardwareKey(for: selectedVaultURL)
    }

    /// Touch ID without the hardware key: stores the open database's response in the keychain (or deletes it).
    public func setTouchIDSkipsHardwareKey(_ skips: Bool) async {
        guard let selectedVaultURL else {
            return
        }
        settingsStore.setTouchIDSkipsHardwareKey(skips, for: selectedVaultURL)
        await rememberHardwareKey(selectedHardwareKey, for: selectedVaultURL, storedResponse: nil)
    }

    /// The KDF seed may have changed (new encryption settings, a merge with another client's save):
    /// refreshes the response Touch ID keeps for unlocking without the key.
    func refreshStoredHardwareKeyResponse() async {
        guard let selectedVaultURL, selectedHardwareKey != nil, case .loaded = loadState else {
            return
        }
        await rememberHardwareKey(selectedHardwareKey, for: selectedVaultURL, storedResponse: nil)
    }

    /// Creates a new database file and opens it right away.
    public func createVault(options: VaultCreationOptions) async throws {
        guard let vaultCreator else {
            throw VaultError.missingDependency(name: "Vault creation service")
        }
        if case .loaded = loadState {
            lockVault(reason: .userInitiated)
        }

        let createdVault = try await vaultCreator.createVault(options: options)

        selectedVaultURL = options.fileURL
        reloadAdditionalDatabases()
        persistSelection(options.fileURL, key: PersistedSelectionKey.vaultBookmark)
        selectedKeyFileURL = options.keyFileURL
        if let keyFileURL = options.keyFileURL {
            persistSelection(keyFileURL, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }

        selectedHardwareKey = options.hardwareKey
        settingsStore.setHardwareKey(options.hardwareKey, for: options.fileURL)
        recordRecentVaultUsage(vaultURL: options.fileURL, keyFileURL: options.keyFileURL)
        restoreFavoriteEntries()
        recentViewedEntryIDs = []
        syncEntryCollections(with: createdVault)
        refreshBiometricUnlockAvailability()
        loadState = .loaded(createdVault)
        startWatchingVault()
        registerUserActivity()
    }

    public func unlockWithBiometrics() async {
        guard let selectedVaultURL else {
            loadState = .failed(L("Select a .kdbx file first."))
            return
        }
        cancelIdleLockTimer()
        loadState = .loading

        do {
            let prompt = L("Unlock \(selectedVaultURL.lastPathComponent)")
            let hardwareKey = selectedHardwareKey
            let keyFileURL = selectedKeyFileURL
            let password = try await biometricCredentialStore.loadMasterPassword(for: selectedVaultURL, prompt: prompt)
            // Only a response from the chosen slot stands in for it.
            let storedResponse = hardwareKey.flatMap { key in
                settingsStore.touchIDSkipsHardwareKey(for: selectedVaultURL)
                    ? biometricCredentialStore.loadHardwareKeyResponse(for: selectedVaultURL).flatMap { $0.belongs(to: key) ? $0 : nil }
                    : nil
            }
            biometricCredentialStore.endAuthentication()

            let loadedVault = try await loadVault(
                at: selectedVaultURL,
                masterPassword: password,
                keyFileURL: keyFileURL,
                hardwareKey: hardwareKey,
                knownResponse: storedResponse
            )
            await rememberHardwareKey(hardwareKey, for: selectedVaultURL, storedResponse: storedResponse)
            recordRecentVaultUsage(vaultURL: selectedVaultURL, keyFileURL: selectedKeyFileURL)
            restoreFavoriteEntries()
            syncEntryCollections(with: loadedVault)
            refreshBiometricUnlockAvailability()
            loadState = .loaded(loadedVault)
            startWatchingVault()
            remindAboutExpiry(in: loadedVault)
            refreshAdditionalDatabaseAvailability()
            registerUserActivity()
        } catch let biometricError as BiometricCredentialError {
            SecureLogger.logUnlockFailure(biometricError)
            switch biometricError {
            case .credentialNotFound:
                clearBiometricCredentialMarker(for: selectedVaultURL)
                refreshBiometricUnlockAvailability()
                loadState = .failed(biometricError.localizedDescription)
            case .userCancelled:
                loadState = .idle
            default:
                loadState = .failed(biometricError.localizedDescription)
            }
        } catch VaultError.hardwareKeyCancelled {
            loadState = .idle
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? L("Unknown error")
            loadState = .failed(message)
        }
    }

    public func disableBiometricUnlockScreen() {
        showBiometricUnlockScreen = false
    }

    public func setTouchIDEnabledForSelectedVault(_ isEnabled: Bool) {
        guard let selectedVaultURL else {
            return
        }

        settingsStore.setTouchIDEnabled(isEnabled, for: selectedVaultURL)

        if !isEnabled {
            biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
            biometricCredentialStore.deleteHardwareKeyResponse(for: selectedVaultURL)
            clearBiometricCredentialMarker(for: selectedVaultURL)
            showBiometricUnlockScreen = false
        }

        refreshBiometricUnlockAvailability()
    }

    public func setIdleLockTimeoutForSelectedVault(_ timeout: TimeInterval) {
        settingsStore.setIdleLockTimeoutSeconds(timeout, for: selectedVaultURL)
        if case .loaded = loadState {
            registerUserActivity()
        }
    }

    public func setShowDockIcon(_ isVisible: Bool) {
        settingsStore.showDockIcon = isVisible
        NotificationCenter.default.post(
            name: AppCommand.dockIconVisibilityChanged,
            object: nil,
            userInfo: [AppCommand.dockIconVisibilityUserInfoKey: isVisible]
        )
    }

    public var launchAtLogin: Bool {
        launchAtLoginState == .enabled
    }

    public var launchAtLoginRequiresApproval: Bool {
        launchAtLoginState == .requiresApproval
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
        } catch {
            SecureLogger.logLoginItemFailure(error)
        }
        launchAtLoginState = LoginItemService.state
    }

    public func refreshLaunchAtLoginState() {
        launchAtLoginState = LoginItemService.state
    }

    public func openLoginItemsSystemSettings() {
        LoginItemService.openSystemSettings()
    }

    public func registerUserActivity() {
        guard case .loaded = loadState else {
            return
        }
        scheduleIdleLockTimer()
    }

    public func lockVault(reason: LockReason) {
        guard case .loaded = loadState else {
            return
        }

        cancelIdleLockTimer()
        stopWatchingVault()
        lockGeneration += 1
        // A save or merge waiting for the hardware key mustn't hold the lock up.
        HardwareKeyPromptController.shared.cancelCurrent()
        storedHardwareKeyResponse = nil
        AutoTypeController.shared.cancelTyping()
        // Quick Access locks right after copying; the copied secret keeps its own auto-clear timer.
        if reason != .quickAccess {
            SensitiveClipboard.shared.clearSensitiveContents()
        }
        recentViewedEntryIDs = []
        SecureLogger.logVaultLocked(reason: reason.rawValue)
        refreshBiometricUnlockAvailability()
        lockAllAdditionalDatabases()
        loadState = .locked(reason.message)
        if let sessionController {
            pendingLockTask = Task {
                do {
                    try await sessionController.savePendingChanges()
                } catch {
                    SecureLogger.logUnlockFailure(error)
                }
                await sessionController.clearLoadedSession()
            }
        }
    }

    /// A lock is still saving pending changes.
    public var hasPendingLock: Bool {
        pendingLockTask != nil
    }

    /// Waits until the last lock has saved pending changes (usage counts) and cleared the session.
    public func finishPendingLock() async {
        await pendingLockTask?.value
        pendingLockTask = nil
        await finishAdditionalLocks()
    }

    /// Before KeeMac quits (also on logout and shutdown): lock like the user would, so pending changes are saved.
    public func lockForQuit() async {
        lockVault(reason: .appQuit)
        await finishPendingLock()
    }

    public func createEntry(inGroupPath groupPath: String?, form: VaultEntryForm) async throws {
        if let target = additionalTarget(forPath: groupPath) {
            try await editAdditional(target.key) { try await $0.createEntry(inGroupPath: target.localPath, form: form) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.createEntry(inGroupPath: groupPath, form: form)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    /// Copies an entry into its group and returns the copy's ID.
    public func duplicateEntry(id: UUID, referencingCredentials: Bool = false) async throws -> UUID {
        if let target = additionalTarget(forEntry: id) {
            var copyID = UUID()
            try await editAdditional(target.key) { loader in
                let result = try await loader.duplicateEntry(id: target.localID, referencingCredentials: referencingCredentials)
                copyID = result.entryID
                return result.vault
            }
            return scopedEntryID(copyID, in: target.key)
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let result = try await vaultEditor.duplicateEntry(id: id, referencingCredentials: referencingCredentials)
        syncEntryCollections(with: result.vault)
        loadState = .loaded(result.vault)
        await absorbPendingMerge()
        registerUserActivity()
        return result.entryID
    }

    public func updateEntry(id: UUID, form: VaultEntryForm) async throws {
        if let target = additionalTarget(forEntry: id) {
            try await editAdditional(target.key) { try await $0.updateEntry(id: target.localID, form: form) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.updateEntry(id: id, form: form)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func moveEntry(id: UUID, toGroupPath groupPath: String?) async throws {
        let entryTarget = additionalTarget(forEntry: id)
        let pathTarget = additionalTarget(forPath: groupPath)
        guard entryTarget?.key == pathTarget?.key else {
            throw VaultError.parseFailure(details: L("Use Move to for another database."))
        }
        if let entryTarget, let pathTarget {
            try await editAdditional(entryTarget.key) { try await $0.moveEntry(id: entryTarget.localID, toGroupPath: pathTarget.localPath) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.moveEntry(id: id, toGroupPath: groupPath)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func deleteEntry(id: UUID) async throws {
        if let target = additionalTarget(forEntry: id) {
            try await editAdditional(target.key) { try await $0.deleteEntry(id: target.localID) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.deleteEntry(id: id)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func restoreEntry(id: UUID) async throws {
        if let target = additionalTarget(forEntry: id) {
            try await editAdditional(target.key) { try await $0.restoreEntry(id: target.localID) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.restoreEntry(id: id)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func revertEntry(id: UUID, toHistoryRevisionAt index: Int) async throws {
        if let target = additionalTarget(forEntry: id) {
            try await editAdditional(target.key) { try await $0.revertEntry(id: target.localID, toHistoryRevisionAt: index) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.revertEntry(id: id, toHistoryRevisionAt: index)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func createGroup(inParentPath parentPath: String?, title: String, iconID: Int?, autoType: VaultGroupAutoType? = nil) async throws {
        if let target = additionalTarget(forPath: parentPath) {
            try await editAdditional(target.key) {
                try await $0.createGroup(inParentPath: target.localPath, title: title, iconID: iconID, autoType: autoType)
            }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.createGroup(inParentPath: parentPath, title: title, iconID: iconID, autoType: autoType)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func updateGroup(path: String, title: String, iconID: Int?, autoType: VaultGroupAutoType? = nil) async throws {
        if let target = additionalTarget(forPath: path) {
            try await editAdditional(target.key) {
                try await $0.updateGroup(path: target.localPath, title: title, iconID: iconID, autoType: autoType)
            }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.updateGroup(path: path, title: title, iconID: iconID, autoType: autoType)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func moveGroup(path: String, toParentPath parentPath: String?) async throws {
        let groupTarget = additionalTarget(forPath: path)
        let parentTarget = additionalTarget(forPath: parentPath)
        guard groupTarget?.key == parentTarget?.key else {
            throw VaultError.parseFailure(details: L("Use Move to for another database."))
        }
        if let groupTarget, let parentTarget {
            try await editAdditional(groupTarget.key) { try await $0.moveGroup(path: groupTarget.localPath, toParentPath: parentTarget.localPath) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.moveGroup(path: path, toParentPath: parentPath)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func deleteGroup(path: String) async throws {
        if let target = additionalTarget(forPath: path) {
            try await editAdditional(target.key) { try await $0.deleteGroup(path: target.localPath) }
            return
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.deleteGroup(path: path)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func loadDatabaseSettings() async throws -> VaultDatabaseSettings {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        return try await databaseManager.databaseSettings()
    }

    public func updateDatabaseSettings(_ settings: VaultDatabaseSettings) async throws {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let generation = lockGeneration
        let updatedVault = try await databaseManager.updateDatabaseSettings(settings)
        // Re-encrypting with a heavy KDF can take long enough for the database to lock meanwhile.
        guard generation == lockGeneration, case .loaded = loadState else {
            return
        }
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        await refreshStoredHardwareKeyResponse()
        registerUserActivity()
    }

    public func loadMaintenanceStatus() async throws -> VaultMaintenanceStatus {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        return try await databaseManager.maintenanceStatus()
    }

    public func updateRecycleBin(enabled: Bool, group: VaultRecycleBinGroup, disposal: VaultRecycleBinDisposal?) async throws {
        try await applyMaintenance { try await $0.updateRecycleBin(enabled: enabled, group: group, disposal: disposal) }
    }

    public func updateHistoryLimits(_ limits: VaultHistoryLimits) async throws {
        try await applyMaintenance { try await $0.updateHistoryLimits(limits) }
    }

    public func removeUnusedCustomIcons() async throws {
        try await applyMaintenance { try await $0.removeUnusedCustomIcons() }
    }

    private func applyMaintenance(_ change: (any VaultDatabaseManaging) async throws -> LoadedVault) async throws {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        let generation = lockGeneration
        let updatedVault = try await change(databaseManager)
        guard generation == lockGeneration, case .loaded = loadState else {
            return
        }
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await refreshUndoState()
        await absorbPendingMerge()
        registerUserActivity()
    }

    /// Checks the current password, changes the password and/or key file, and remembers the new key file
    /// for this database. The Touch ID password follows a new password.
    public func changeMasterKey(
        currentPassword: String,
        newPassword: String,
        keyFile: VaultKeyFileChange,
        hardwareKey: VaultHardwareKeyChange = .keep
    ) async throws {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState, let selectedVaultURL else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        let keyFileURL: URL?
        if hardwareKey == .keep {
            keyFileURL = try await databaseManager.changeMasterKey(
                currentPassword: currentPassword,
                currentKeyFileURL: selectedKeyFileURL,
                newPassword: newPassword,
                keyFile: keyFile
            )
        } else {
            guard let hardwareKeyManager else {
                throw VaultError.missingDependency(name: "Hardware key support")
            }
            keyFileURL = try await hardwareKeyManager.changeMasterKey(
                currentPassword: currentPassword,
                currentKeyFileURL: selectedKeyFileURL,
                newPassword: newPassword,
                keyFile: keyFile,
                hardwareKey: hardwareKey
            )
            switch hardwareKey {
            case .keep:
                break
            case .use(let key):
                selectedHardwareKey = key
            case .remove:
                selectedHardwareKey = nil
            }
            await rememberHardwareKey(selectedHardwareKey, for: selectedVaultURL, storedResponse: nil)
        }
        // The file is re-encrypted by now: remember its key even if the database locked meanwhile.
        selectedKeyFileURL = keyFileURL
        if let keyFileURL {
            persistSelection(keyFileURL, key: PersistedSelectionKey.keyFileBookmark)
        } else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.keyFileBookmark)
        }
        recordRecentVaultUsage(vaultURL: selectedVaultURL, keyFileURL: keyFileURL)

        let password = newPassword.isEmpty ? currentPassword : newPassword
        if settingsStore.isTouchIDEnabled(for: selectedVaultURL), !password.isEmpty {
            do {
                try biometricCredentialStore.saveMasterPassword(password, for: selectedVaultURL)
                markBiometricCredentialAvailable(for: selectedVaultURL)
            } catch {
                SecureLogger.logUnlockFailure(error)
            }
        } else {
            biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
            clearBiometricCredentialMarker(for: selectedVaultURL)
        }
        refreshBiometricUnlockAvailability()
        registerUserActivity()
    }

    public func changeMasterPassword(newPassword: String) async throws {
        guard let databaseManager else {
            throw VaultError.missingDependency(name: "Database management service")
        }
        guard case .loaded = loadState, let selectedVaultURL else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        try await databaseManager.changeMasterKey(newPassword: newPassword, keyFileURL: selectedKeyFileURL)

        // Keep any stored biometric credential in sync with the new password.
        if settingsStore.isTouchIDEnabled(for: selectedVaultURL), !newPassword.isEmpty {
            do {
                try biometricCredentialStore.saveMasterPassword(newPassword, for: selectedVaultURL)
                markBiometricCredentialAvailable(for: selectedVaultURL)
            } catch {
                SecureLogger.logUnlockFailure(error)
            }
        } else {
            biometricCredentialStore.deleteMasterPassword(for: selectedVaultURL)
            clearBiometricCredentialMarker(for: selectedVaultURL)
        }
        refreshBiometricUnlockAvailability()
        registerUserActivity()
    }

    // MARK: - Expiry reminder

    public var expiryNotificationsForSelectedVault: Bool {
        get { settingsStore.expiryNotificationsEnabled(for: selectedVaultURL) }
        set { settingsStore.setExpiryNotificationsEnabled(newValue, for: selectedVaultURL) }
    }

    public var expiryWarnDaysForSelectedVault: Int {
        get { settingsStore.expiryWarnDays(for: selectedVaultURL) }
        set { settingsStore.setExpiryWarnDays(newValue, for: selectedVaultURL) }
    }

    public var expiryBannerForSelectedVault: Bool {
        get { settingsStore.expiryBannerEnabled(for: selectedVaultURL) }
        set { settingsStore.setExpiryBannerEnabled(newValue, for: selectedVaultURL) }
    }

    public func openPasswordHealth() {
        guard case .loaded = loadState else {
            return
        }
        showsExpiryBanner = false
        passwordHealthRequest = PasswordHealthRequest(warnDays: expiryWarnDaysForSelectedVault)
    }

    public func consumePasswordHealthRequest() {
        passwordHealthRequest = nil
    }

    public func dismissExpiryBanner() {
        showsExpiryBanner = false
    }

    private func remindAboutExpiry(in vault: LoadedVault) {
        let summary = ExpirySummary(entries: vault.entries, warnDays: expiryWarnDaysForSelectedVault)
        guard !summary.isEmpty else {
            return
        }
        if expiryNotificationsForSelectedVault {
            ExpiryNotifier.shared.post(summary, databaseName: vault.summary.fileName)
        }
        showsExpiryBanner = expiryBannerForSelectedVault
    }

    // MARK: - Sync

    public var syncModeForSelectedVault: VaultSyncMode {
        settingsStore.syncMode(for: selectedVaultURL)
    }

    public func setSyncModeForSelectedVault(_ mode: VaultSyncMode) {
        guard mode != syncModeForSelectedVault else {
            return
        }
        settingsStore.setSyncMode(mode, for: selectedVaultURL)
        guard case .loaded = loadState else {
            return
        }
        applySyncMode()
        Task {
            await checkForExternalChanges()
        }
    }

    public var lockOnScreenLock: Bool {
        get { settingsStore.lockOnScreenLock }
        set { settingsStore.lockOnScreenLock = newValue }
    }

    public var lookForConflictCopies: Bool {
        get { settingsStore.lookForConflictCopies }
        set { settingsStore.lookForConflictCopies = newValue }
    }

    /// The "changed on another device" banner shown in Ask mode.
    public var showsDiskChangeBanner: Bool {
        hasPendingDiskChange && !isDiskChangeBannerHidden && syncStatus != .merging
    }

    /// Reacts to the database file changing on disk according to the sync mode.
    public func checkForExternalChanges() async {
        guard let synchronizer, case .loaded = loadState, !isCheckingDisk else {
            return
        }
        let mode = syncModeForSelectedVault
        guard mode != .off else {
            return
        }
        isCheckingDisk = true
        let status = await synchronizer.diskStatus()
        isCheckingDisk = false
        guard status == .changed else {
            return
        }

        if mode == .ask {
            if !hasPendingDiskChange {
                hasPendingDiskChange = true
                isDiskChangeBannerHidden = false
            }
            syncStatus = .changedOnDisk
            return
        }
        await mergeDiskChanges()
    }

    /// Merges what another device wrote to the database file, whatever the sync mode.
    public func mergeDiskChanges() async {
        guard let synchronizer, case .loaded = loadState, !isCheckingDisk else {
            return
        }
        isCheckingDisk = true
        defer { isCheckingDisk = false }

        syncStatus = .merging
        do {
            let result = try await synchronizer.mergeExternalChanges()
            guard case .loaded = loadState else {
                return
            }
            syncEntryCollections(with: result.vault)
            loadState = .loaded(result.vault)
            hasPendingDiskChange = false
            publishMerge(result.summary, from: nil)
            await refreshStoredHardwareKeyResponse()
            syncStatus = .synced(Date())
        } catch {
            SecureLogger.logUnlockFailure(error)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            syncStatus = .failed(message)
            syncFailureMessage = message
        }
    }

    public func ignoreDiskChanges() {
        isDiskChangeBannerHidden = true
    }

    public func showDiskChangeBanner() {
        isDiskChangeBannerHidden = false
    }

    public func retrySync() {
        syncFailureMessage = nil
        Task {
            await mergeDiskChanges()
        }
    }

    public func dismissSyncFailure() {
        syncFailureMessage = nil
    }

    public func requestReveal(_ entryIDs: [UUID], editingAutoType: Bool = false) {
        revealRequest = RevealRequest(entryIDs: entryIDs, editsAutoType: editingAutoType)
    }

    public func consumeRevealRequest() {
        revealRequest = nil
    }

    /// Clears the "changed on another device" marker once the entry has been looked at.
    public func markExternalChangeSeen(_ entryID: UUID) {
        externalChanges.removeValue(forKey: entryID)
    }

    // MARK: Manual merge

    public func showMergeDatabase() {
        guard synchronizer != nil, case .loaded = loadState else {
            return
        }
        mergeSheet = MergeSheetRequest(kind: .database)
    }

    public func showDiskChanges() {
        guard synchronizer != nil, case .loaded = loadState else {
            return
        }
        mergeSheet = MergeSheetRequest(kind: .diskChanges)
    }

    public func dismissMergeSheet() {
        mergeSheet = nil
        guard let synchronizer else {
            return
        }
        Task {
            await synchronizer.discardPreparedMerge()
        }
    }

    public func previewDiskChanges() async throws -> VaultMergeSummary {
        guard let synchronizer else {
            throw VaultError.missingDependency(name: "Synchronization service")
        }
        return try await synchronizer.previewExternalChanges()
    }

    /// Reads other database files and returns what merging them would change.
    public func prepareMerge(from sources: [VaultMergeSource]) async throws -> VaultMergeSummary {
        guard let synchronizer else {
            throw VaultError.missingDependency(name: "Synchronization service")
        }
        return try await synchronizer.prepareMerge(from: sources)
    }

    /// Applies the merge prepared by `prepareMerge(from:)` and saves the database.
    public func commitPreparedMerge(sourceName: String) async throws {
        guard let synchronizer else {
            throw VaultError.missingDependency(name: "Synchronization service")
        }
        let request = mergeSheet
        let result = try await synchronizer.commitPreparedMerge()
        guard case .loaded = loadState else {
            return
        }
        syncEntryCollections(with: result.vault)
        loadState = .loaded(result.vault)
        mergeSheet = nil
        await absorbPendingMerge()
        if result.summary.isEmpty {
            CopyFeedbackCenter.shared.show(L("No new changes in \(sourceName)"), style: .synced, duration: 4)
        } else {
            publishMerge(result.summary, from: sourceName)
        }
        if case .conflictCopies(let copies) = request?.kind {
            syncAlert = .trashCopies(copies)
        }
    }

    public func reviewConflictCopies() {
        guard case .conflictCopies(let copies) = syncAlert else {
            return
        }
        syncAlert = nil
        mergeSheet = MergeSheetRequest(kind: .conflictCopies(copies))
    }

    public func dismissSyncAlert() {
        syncAlert = nil
    }

    public func trashConflictCopies() {
        guard case .trashCopies(let copies) = syncAlert else {
            return
        }
        syncAlert = nil
        var moved = 0
        for copy in copies {
            do {
                try FileManager.default.trashItem(at: copy.fileURL, resultingItemURL: nil)
                moved += 1
            } catch {
                SecureLogger.logUnlockFailure(error)
            }
        }
        if moved > 0 {
            CopyFeedbackCenter.shared.show(L("Moved \(moved) copies to the Trash"))
        }
    }

    private func findConflictCopies() {
        guard settingsStore.lookForConflictCopies, let selectedVaultURL, synchronizer != nil else {
            return
        }
        let copies = VaultConflictCopyFinder.copies(of: selectedVaultURL)
        if !copies.isEmpty {
            syncAlert = .conflictCopies(copies)
        }
    }

    private func startWatchingVault() {
        stopWatchingVault()
        guard synchronizer != nil else {
            return
        }
        applySyncMode()
        Task {
            await absorbRestore()
            findConflictCopies()
        }
    }

    /// Starts or stops the file watcher to match the sync mode of the open database.
    private func applySyncMode() {
        fileWatcher?.stop()
        fileWatcher = nil
        hasPendingDiskChange = false
        guard let selectedVaultURL, syncModeForSelectedVault != .off else {
            syncStatus = .notWatching
            return
        }
        syncStatus = .synced(Date())
        let watcher = VaultFileWatcher(fileURL: selectedVaultURL) { [weak self] in
            Task { @MainActor in
                await self?.checkForExternalChanges()
            }
        }
        watcher.start()
        fileWatcher = watcher
    }

    /// Reports entries brought back from KeeMac's last saved copy during unlock.
    private func absorbRestore() async {
        guard let synchronizer, let summary = await synchronizer.takeRestoreSummary(), !summary.isEmpty else {
            return
        }
        lastMergeSummary = summary
        recordExternalChanges(summary, restored: true)
        let count = summary.changes.count
        let ids = Array(summary.changedEntryIDs)
        CopyFeedbackCenter.shared.show(
            L("Restored \(count) entries that were overwritten on another device"),
            style: .restored,
            duration: 6,
            actionTitle: L("Show"),
            action: { [weak self] in self?.requestReveal(ids) }
        )
    }

    private func stopWatchingVault() {
        fileWatcher?.stop()
        fileWatcher = nil
        syncStatus = .idle
        externalChanges = [:]
        lastMergeSummary = nil
        revealRequest = nil
        syncFailureMessage = nil
        hasPendingDiskChange = false
        isDiskChangeBannerHidden = false
        mergeSheet = nil
        syncAlert = nil
        showsExpiryBanner = false
        passwordHealthRequest = nil
    }

    /// Picks up changes that a save merged in from disk before writing.
    private func absorbPendingMerge() async {
        guard let synchronizer else {
            return
        }
        if let summary = await synchronizer.takePendingMergeSummary() {
            publishMerge(summary, from: nil)
            await refreshStoredHardwareKeyResponse()
        }
        // Every save merges the file on disk first, so nothing is left pending.
        hasPendingDiskChange = false
        if case .loaded = loadState {
            syncStatus = syncModeForSelectedVault == .off ? .notWatching : .synced(Date())
        }
    }

    private func publishMerge(_ summary: VaultMergeSummary, from sourceName: String?) {
        guard !summary.isEmpty else {
            return
        }
        lastMergeSummary = summary
        recordExternalChanges(summary, restored: false)

        let count = summary.changes.count
        let conflicts = summary.conflictCount
        let changes = L("\(count) changes")
        let message: String
        if conflicts > 0 {
            let kept = L("\(conflicts) conflicts kept in history")
            message = L("Merged \(changes) · \(kept)")
        } else {
            let source = sourceName ?? L("another device")
            message = L("Merged \(changes) from \(source)")
        }
        let ids = Array(summary.changedEntryIDs)
        guard !ids.isEmpty else {
            CopyFeedbackCenter.shared.show(message, style: .synced, duration: 4)
            return
        }
        CopyFeedbackCenter.shared.show(message, style: .synced, duration: 6, actionTitle: L("Show")) { [weak self] in
            self?.requestReveal(ids)
        }
    }

    private func recordExternalChanges(_ summary: VaultMergeSummary, restored: Bool) {
        let now = Date()
        for change in summary.changes where change.kind != .deleted {
            externalChanges[change.entryID] = ExternalChange(
                date: now,
                isConflict: change.isConflict,
                isRestored: restored,
                previousGroupPath: change.kind == .moved ? change.previousGroupPath : nil
            )
        }
    }

    /// Records that an entry was used (copied field, opened URL). Kept in memory and saved on lock.
    public func emptyTrash(ids: [UUID]) async throws {
        // The trash of one database at a time, but sort the IDs anyway.
        var mainIDs: [UUID] = []
        var additional: [String: [UUID]] = [:]
        for id in ids {
            if let target = additionalTarget(forEntry: id) {
                additional[target.key, default: []].append(target.localID)
            } else {
                mainIDs.append(id)
            }
        }
        for (key, localIDs) in additional {
            try await editAdditional(key) { try await $0.emptyTrash(ids: localIDs) }
        }
        guard !mainIDs.isEmpty else {
            return
        }
        let ids = mainIDs
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        let updatedVault = try await vaultEditor.emptyTrash(ids: ids)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
    }

    public func showImport() {
        guard case .loaded = loadState else {
            return
        }
        showsImportSheet = true
    }

    public func showExport() {
        guard case .loaded = loadState else {
            return
        }
        showsExportSheet = true
    }

    /// The group selected in the sidebar, for "Export · Current group".
    public var selectedBrowserGroupPath: String? {
        guard let id = browserSidebarSelectionID(for: selectedVaultURL), id.hasPrefix("group.") else {
            return nil
        }
        return String(id.dropFirst("group.".count))
    }

    /// Imports as one undo step, selects the receiving group and offers Undo in a toast.
    @discardableResult
    public func importEntries(_ file: VaultImportFile, options: VaultImportOptions) async throws -> VaultImportResult {
        guard let transfer else {
            throw VaultError.missingDependency(name: "Import service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }
        let (vault, result) = try await transfer.importEntries(file, options: options)
        syncEntryCollections(with: vault)
        loadState = .loaded(vault)
        await absorbPendingMerge()
        registerUserActivity()
        revealRequest = RevealRequest(entryIDs: Array(result.entryIDs.prefix(1)), groupPath: result.groupPath)
        CopyFeedbackCenter.shared.show(L("Imported \(result.importedCount) entries"), style: .success, duration: 6, actionTitle: L("Undo")) {
            NotificationCenter.default.post(name: AppCommand.undo, object: nil)
        }
        return result
    }

    public func exportDatabase(_ options: VaultExportOptions) async throws -> (data: Data, entryCount: Int) {
        guard let transfer else {
            throw VaultError.missingDependency(name: "Export service")
        }
        registerUserActivity()
        return try await transfer.exportDatabase(options)
    }

    /// Checks the master password (with the key file this database was opened with).
    public func verifyMasterKey(password: String) async -> Bool {
        await transfer?.verifyMasterKey(password: password, keyFileURL: selectedKeyFileURL) ?? false
    }

    public func undo() async {
        await performUndoStep(redo: false)
    }

    public func redo() async {
        await performUndoStep(redo: true)
    }

    private func performUndoStep(redo: Bool) async {
        if let key = activeDatabaseKey, additionalLoaders[key] != nil {
            await performAdditionalUndoStep(key, redo: redo)
            return
        }
        guard let undoer, case .loaded = loadState else {
            return
        }
        let state = await undoer.undoState()
        guard let action = redo ? state.redoAction : state.undoAction else {
            return
        }
        do {
            let vault = try await redo ? undoer.redo() : undoer.undo()
            guard case .loaded = loadState else {
                return
            }
            syncEntryCollections(with: vault)
            loadState = .loaded(vault)
            await absorbPendingMerge()
            registerUserActivity()
            CopyFeedbackCenter.shared.show(redo ? L("Redone: \(action.title)") : L("Undone: \(action.title)"), duration: 2.4)
        } catch {
            SecureLogger.logUnlockFailure(error)
            CopyFeedbackCenter.shared.show(L("Couldn’t undo: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"), duration: 3)
        }
    }

    func refreshUndoState() async {
        let state: VaultUndoState
        if let key = activeDatabaseKey, let loader = additionalLoaders[key] {
            state = await loader.undoState()
        } else {
            state = await undoer?.undoState() ?? .empty
        }
        undoState = loadState.isUnlocked ? state : .empty
    }

    /// KeePassXC-Browser data of the open database.
    public var browserAccess: (any VaultBrowserAccessing)? {
        vaultLoader as? any VaultBrowserAccessing
    }

    /// Shows a vault saved by the browser integration, with whatever that save merged in from disk.
    public func applyBrowserSave(_ vault: LoadedVault) async {
        guard case .loaded = loadState else {
            return
        }
        syncEntryCollections(with: vault)
        loadState = .loaded(vault)
        await absorbPendingMerge()
    }

    /// Moves an HOTP entry to its next code. It is saved right away and isn't an undo step.
    /// Returns the counter this call used up (main database only), so callers running at the
    /// same time never hand out the same code.
    @discardableResult
    public func advanceHOTPCounter(entryID id: UUID) async throws -> UInt64? {
        if let target = additionalTarget(forEntry: id) {
            try await editAdditional(target.key) { try await $0.advanceHOTPCounter(id: target.localID) }
            return nil
        }
        guard let vaultEditor else {
            throw VaultError.missingDependency(name: "Vault editing service")
        }
        guard case .loaded = loadState else {
            throw VaultError.parseFailure(details: L("Vault is not unlocked."))
        }

        let updatedVault = try await vaultEditor.advanceHOTPCounter(id: id)
        syncEntryCollections(with: updatedVault)
        loadState = .loaded(updatedVault)
        await absorbPendingMerge()
        registerUserActivity()
        return updatedVault.entries.first { $0.id == id }?.otp.map { $0.counter &- 1 }
    }

    /// Evaluates a placeholder Auto-Type can't fill from the entry itself (`REF:…`), in the main database.
    func resolveAutoTypePlaceholder(_ placeholder: String, entryID: UUID) async -> String? {
        await autoTyper?.resolveAutoTypePlaceholder(placeholder, entryID: entryID)
    }

    public func recordEntryUsage(id: UUID) {
        if let target = additionalTarget(forEntry: id) {
            Task {
                try? await editAdditional(target.key) { try await $0.recordEntryUsage(id: target.localID) }
            }
            return
        }
        guard let vaultEditor, case .loaded = loadState else {
            return
        }
        Task {
            guard let updatedVault = try? await vaultEditor.recordEntryUsage(id: id) else {
                return
            }
            if case .loaded = loadState {
                loadState = .loaded(updatedVault)
            }
        }
    }

    public func toggleFavorite(entryID: UUID) {
        // Favorites belong to the main database.
        guard additionalTarget(forEntry: entryID) == nil else {
            return
        }
        if favoriteEntryIDs.contains(entryID) {
            favoriteEntryIDs.remove(entryID)
        } else {
            favoriteEntryIDs.insert(entryID)
        }
        persistFavoriteEntries()
    }

    public func browserSidebarSelectionID(for vaultURL: URL?) -> String? {
        settingsStore.sidebarSelectionID(for: vaultURL)
    }

    public func setBrowserSidebarSelectionID(_ id: String?, for vaultURL: URL?) {
        settingsStore.setSidebarSelectionID(id, for: vaultURL)
    }

    public func browserExpandedGroupPaths(for vaultURL: URL?) -> Set<String> {
        settingsStore.expandedGroupPaths(for: vaultURL)
    }

    public func setBrowserExpandedGroupPaths(_ paths: Set<String>, for vaultURL: URL?) {
        settingsStore.setExpandedGroupPaths(paths, for: vaultURL)
    }

    public func markEntryViewed(_ entryID: UUID) {
        recentViewedEntryIDs.removeAll { $0 == entryID }
        recentViewedEntryIDs.insert(entryID, at: 0)
        if recentViewedEntryIDs.count > 50 {
            recentViewedEntryIDs = Array(recentViewedEntryIDs.prefix(50))
        }
    }

    private func scheduleIdleLockTimer() {
        cancelIdleLockTimer()

        let timeout = settingsStore.idleLockTimeoutSeconds(for: selectedVaultURL)
        guard timeout > 0 else {
            return
        }

        idleLockTask = Task { [weak self] in
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.lockVault(reason: .idleTimeout)
            }
        }
    }

    private func cancelIdleLockTimer() {
        idleLockTask?.cancel()
        idleLockTask = nil
    }

    private func persistSelection(_ url: URL, key: String) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmarkData, forKey: key)
        } catch {
            SecureLogger.logUnlockFailure(error)
        }
    }

    private func restorePersistedSelections() {
        selectedVaultURL = restoreSelection(for: PersistedSelectionKey.vaultBookmark)
        selectedKeyFileURL = restoreSelection(for: PersistedSelectionKey.keyFileBookmark)
        selectedHardwareKey = settingsStore.hardwareKey(for: selectedVaultURL)
    }

    private func restoreRecentVaults() {
        guard let data = userDefaults.data(forKey: PersistedSelectionKey.recentVaults) else {
            recentVaults = []
            return
        }

        let decoder = JSONDecoder()
        guard let persistedRecentVaults = try? decoder.decode([PersistedRecentVault].self, from: data) else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            recentVaults = []
            return
        }

        var restored: [RecentVault] = []
        var seenVaultPaths = Set<String>()
        for persisted in persistedRecentVaults {
            guard let vaultURL = restoreURL(fromBookmarkData: persisted.vaultBookmark) else {
                continue
            }

            let identity = vaultIdentity(for: vaultURL)
            guard !seenVaultPaths.contains(identity) else {
                continue
            }

            let keyFileURL = persisted.keyFileBookmark.flatMap { bookmarkData in
                restoreURL(fromBookmarkData: bookmarkData)
            }
            restored.append(RecentVault(vaultURL: vaultURL, keyFileURL: keyFileURL))
            seenVaultPaths.insert(identity)

            if restored.count == 3 {
                break
            }
        }

        recentVaults = restored
        persistRecentVaults()
    }

    private func refreshBiometricUnlockAvailability() {
        guard let selectedVaultURL else {
            showBiometricUnlockScreen = false
            return
        }
        guard settingsStore.isTouchIDEnabled(for: selectedVaultURL) else {
            showBiometricUnlockScreen = false
            return
        }

        let vaultPath = vaultIdentity(for: selectedVaultURL)
        if userDefaults.string(forKey: PersistedSelectionKey.biometricVaultPath) == vaultPath {
            showBiometricUnlockScreen = true
            return
        }

        // Fallback path for older runs where marker is missing.
        if biometricCredentialStore.hasSavedMasterPassword(for: selectedVaultURL) {
            markBiometricCredentialAvailable(for: selectedVaultURL)
            showBiometricUnlockScreen = true
            return
        }

        showBiometricUnlockScreen = false
    }

    private func restoreSelection(for key: String) -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: key) else {
            return nil
        }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                userDefaults.removeObject(forKey: key)
                return nil
            }

            if isStale {
                persistSelection(resolvedURL, key: key)
            }

            return resolvedURL
        } catch {
            userDefaults.removeObject(forKey: key)
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    func bookmarkData(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    func restoreURL(fromBookmarkData bookmarkData: Data) -> URL? {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return resolvedURL
    }

    private func recordRecentVaultUsage(vaultURL: URL, keyFileURL: URL?) {
        let identity = vaultIdentity(for: vaultURL)
        recentVaults.removeAll { vaultIdentity(for: $0.vaultURL) == identity }
        recentVaults.insert(RecentVault(vaultURL: vaultURL, keyFileURL: keyFileURL), at: 0)
        if recentVaults.count > 3 {
            recentVaults = Array(recentVaults.prefix(3))
        }
        persistRecentVaults()
    }

    private func persistRecentVaults() {
        guard !recentVaults.isEmpty else {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            return
        }

        let persistedVaults: [PersistedRecentVault] = recentVaults.prefix(3).compactMap { recentVault in
            guard let vaultBookmark = bookmarkData(for: recentVault.vaultURL) else {
                return nil
            }
            let keyFileBookmark = recentVault.keyFileURL.flatMap { keyFileURL in
                bookmarkData(for: keyFileURL)
            }
            return PersistedRecentVault(vaultBookmark: vaultBookmark, keyFileBookmark: keyFileBookmark)
        }

        if persistedVaults.isEmpty {
            userDefaults.removeObject(forKey: PersistedSelectionKey.recentVaults)
            recentVaults = []
            return
        }

        guard let encoded = try? JSONEncoder().encode(persistedVaults) else {
            return
        }
        userDefaults.set(encoded, forKey: PersistedSelectionKey.recentVaults)
    }

    private func restoreFavoriteEntries() {
        guard let selectedVaultURL else {
            favoriteEntryIDs = []
            return
        }

        guard let data = userDefaults.data(forKey: PersistedSelectionKey.favoriteEntries),
              let persisted = try? JSONDecoder().decode([PersistedFavoriteEntries].self, from: data) else {
            favoriteEntryIDs = []
            return
        }

        let vaultPath = vaultIdentity(for: selectedVaultURL)
        let entryIDs = persisted
            .first(where: { $0.vaultPath == vaultPath })?
            .entryIDs
            .compactMap(UUID.init(uuidString:)) ?? []
        favoriteEntryIDs = Set(entryIDs)
    }

    private func persistFavoriteEntries() {
        guard let selectedVaultURL else {
            return
        }

        let vaultPath = vaultIdentity(for: selectedVaultURL)
        var persisted = userDefaults.data(forKey: PersistedSelectionKey.favoriteEntries)
            .flatMap { try? JSONDecoder().decode([PersistedFavoriteEntries].self, from: $0) } ?? []

        persisted.removeAll { $0.vaultPath == vaultPath }

        if !favoriteEntryIDs.isEmpty {
            persisted.append(
                PersistedFavoriteEntries(
                    vaultPath: vaultPath,
                    entryIDs: favoriteEntryIDs.map(\.uuidString).sorted()
                )
            )
        }

        if let encoded = try? JSONEncoder().encode(persisted) {
            userDefaults.set(encoded, forKey: PersistedSelectionKey.favoriteEntries)
        }
    }

    /// Shows a new state of the main database (after a transfer or its undo).
    func applyMainVault(_ vault: LoadedVault) {
        syncEntryCollections(with: vault)
        loadState = .loaded(vault)
    }

    private func syncEntryCollections(with vault: LoadedVault) {
        let availableIDs = Set(vault.entries.map(\.id))
        favoriteEntryIDs = favoriteEntryIDs.intersection(availableIDs)
        recentViewedEntryIDs = recentViewedEntryIDs.filter { availableIDs.contains($0) }
        persistFavoriteEntries()
    }

    private func markBiometricCredentialAvailable(for vaultURL: URL) {
        userDefaults.set(vaultIdentity(for: vaultURL), forKey: PersistedSelectionKey.biometricVaultPath)
    }

    private func clearBiometricCredentialMarker(for vaultURL: URL) {
        let vaultPath = vaultIdentity(for: vaultURL)
        if userDefaults.string(forKey: PersistedSelectionKey.biometricVaultPath) == vaultPath {
            userDefaults.removeObject(forKey: PersistedSelectionKey.biometricVaultPath)
        }
    }

    func vaultIdentity(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
    }
}

extension VaultUndoAction {
    /// The step's name in "Undo …" menu items and toasts.
    public var title: String {
        switch self {
        case .newEntry: return L("New Entry")
        case .editEntry: return L("Edit Entry")
        case .duplicateEntry: return L("Duplicate Entry")
        case .moveEntry: return L("Move Entry")
        case .moveToTrash: return L("Move to Trash")
        case .deletePermanently: return L("Delete Permanently")
        case .emptyTrash: return L("Empty Trash")
        case .restoreEntry: return L("Restore Entry")
        case .revertEntry: return L("Restore Version")
        case .newGroup: return L("New Group")
        case .editGroup: return L("Edit Group")
        case .moveGroup: return L("Move Group")
        case .deleteGroup: return L("Delete Group")
        case .saveLogin: return L("Save Login from Browser")
        case .updateLogin: return L("Update Login from Browser")
        case .importEntries: return L("Import")
        case .receiveEntries: return L("Add from Another Database")
        case .sendEntries: return L("Move to Another Database")
        case .moveEntries: return L("Move Entries")
        case .moveEntriesToTrash: return L("Move Entries to Trash")
        case .deleteEntriesPermanently: return L("Delete Entries Permanently")
        case .restoreEntries: return L("Restore Entries")
        case .editTags: return L("Edit Tags")
        }
    }
}
