import Domain
import Foundation
import Observation

/// What KeeMac does when the open database file changes on disk.
public enum VaultSyncMode: String, CaseIterable, Codable, Sendable {
    case automatic
    case ask
    case off

    public var title: String {
        switch self {
        case .automatic:
            return L("Merge automatically")
        case .ask:
            return L("Ask")
        case .off:
            return L("Don’t watch")
        }
    }
}

/// An additional database remembered for a main one: bookmarks to the file and its key file. Stored on this Mac only.
public struct StoredAdditionalDatabase: Codable, Equatable, Sendable {
    /// Stable within the list; namespaces the database's entries and groups in the browser.
    public let key: String
    public var vaultBookmark: Data
    public var keyFileBookmark: Data?
    /// Shown when the bookmark no longer resolves ("File not found").
    public var lastKnownPath: String

    public init(key: String, vaultBookmark: Data, keyFileBookmark: Data?, lastKnownPath: String) {
        self.key = key
        self.vaultBookmark = vaultBookmark
        self.keyFileBookmark = keyFileBookmark
        self.lastKnownPath = lastKnownPath
    }
}

@MainActor
@Observable
public final class AppSettingsStore {
    private enum Key {
        static let clipboardTimeoutSeconds = "keemac.settings.clipboard.timeout.seconds"
        static let defaultIdleLockTimeoutSeconds = "keemac.settings.vault.idlelock.default.seconds"
        static let perVaultSettingsData = "keemac.settings.vault.pervault.data"
        static let showDockIcon = "keemac.settings.appearance.showDockIcon"
        static let startMinimized = "keemac.settings.appearance.startMinimized"
        static let includeSubgroupEntries = "keemac.settings.browser.includeSubgroupEntries"
        static let lookForConflictCopies = "keemac.settings.sync.lookForConflictCopies"
        static let lockOnScreenLock = "keemac.settings.security.lockOnScreenLock"
        static let browserIntegrationEnabled = "keemac.settings.browserIntegration.enabled"
        static let browserAlwaysAllowAccess = "keemac.settings.browserIntegration.alwaysAllowAccess"
        static let browserAllowExpired = "keemac.settings.browserIntegration.allowExpired"
        static let browserAlwaysAllowUpdate = "keemac.settings.browserIntegration.alwaysAllowUpdate"
        static let quickAccessEnabled = "keemac.settings.quickAccess.enabled"
        static let quickAccessShortcut = "keemac.settings.quickAccess.shortcut"
        static let quickAccessUnlockDuration = "keemac.settings.quickAccess.unlockDuration"
        static let autoTypeEnabled = "keemac.settings.autoType.enabled"
        static let autoTypeShortcut = "keemac.settings.autoType.shortcut"
        static let autoTypeKeyDelay = "keemac.settings.autoType.keyDelay"
        static let sshAgentEnabled = "keemac.settings.sshAgent.enabled"
        static let sshPickKeysByHost = "keemac.settings.sshAgent.pickByHost"
        static let sshLearnHosts = "keemac.settings.sshAgent.learnHosts"
        static let sshDefaultConfirmation = "keemac.settings.sshAgent.defaultConfirmation"
        static let sshAskForwarded = "keemac.settings.sshAgent.askForwarded"
    }

    private struct VaultSettings: Codable {
        var touchIDEnabled: Bool = true
        var idleLockTimeoutSeconds: TimeInterval = 300
        var sidebarSelectionID: String?
        var expandedGroupPaths: [String]?
        var syncMode: VaultSyncMode?
        var expiryNotifications: Bool?
        var expiryWarnDays: Int?
        var expiryBanner: Bool?
        var additionalDatabases: [StoredAdditionalDatabase]?
        /// The YubiKey slot that is part of this database's master key (the file doesn't say).
        var hardwareKey: VaultHardwareKey?
        /// Touch ID unlocks with the stored YubiKey response instead of asking the key.
        var touchIDSkipsHardwareKey: Bool?

        init(
            touchIDEnabled: Bool = true,
            idleLockTimeoutSeconds: TimeInterval = 300,
            sidebarSelectionID: String? = nil,
            expandedGroupPaths: [String]? = nil
        ) {
            self.touchIDEnabled = touchIDEnabled
            self.idleLockTimeoutSeconds = idleLockTimeoutSeconds
            self.sidebarSelectionID = sidebarSelectionID
            self.expandedGroupPaths = expandedGroupPaths
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            touchIDEnabled = try container.decodeIfPresent(Bool.self, forKey: .touchIDEnabled) ?? true
            idleLockTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleLockTimeoutSeconds) ?? 300
            sidebarSelectionID = try container.decodeIfPresent(String.self, forKey: .sidebarSelectionID)
            expandedGroupPaths = try container.decodeIfPresent([String].self, forKey: .expandedGroupPaths)
            syncMode = try? container.decodeIfPresent(VaultSyncMode.self, forKey: .syncMode)
            expiryNotifications = try container.decodeIfPresent(Bool.self, forKey: .expiryNotifications)
            expiryWarnDays = try container.decodeIfPresent(Int.self, forKey: .expiryWarnDays)
            expiryBanner = try container.decodeIfPresent(Bool.self, forKey: .expiryBanner)
            additionalDatabases = try? container.decodeIfPresent([StoredAdditionalDatabase].self, forKey: .additionalDatabases)
            hardwareKey = try? container.decodeIfPresent(VaultHardwareKey.self, forKey: .hardwareKey)
            touchIDSkipsHardwareKey = try container.decodeIfPresent(Bool.self, forKey: .touchIDSkipsHardwareKey)
        }
    }

    public static let shared = AppSettingsStore()

    public var clipboardAutoClearTimeoutSeconds: TimeInterval {
        didSet {
            let normalized = Self.normalizeTimeout(clipboardAutoClearTimeoutSeconds)
            if normalized != clipboardAutoClearTimeoutSeconds {
                clipboardAutoClearTimeoutSeconds = normalized
                return
            }
            userDefaults.set(clipboardAutoClearTimeoutSeconds, forKey: Key.clipboardTimeoutSeconds)
        }
    }

    public var defaultIdleLockTimeoutSeconds: TimeInterval {
        didSet {
            let normalized = Self.normalizeTimeout(defaultIdleLockTimeoutSeconds)
            if normalized != defaultIdleLockTimeoutSeconds {
                defaultIdleLockTimeoutSeconds = normalized
                return
            }
            userDefaults.set(defaultIdleLockTimeoutSeconds, forKey: Key.defaultIdleLockTimeoutSeconds)
        }
    }

    public var showDockIcon: Bool {
        didSet {
            userDefaults.set(showDockIcon, forKey: Key.showDockIcon)
        }
    }

    public var startMinimized: Bool {
        didSet {
            userDefaults.set(startMinimized, forKey: Key.startMinimized)
        }
    }

    public var includeSubgroupEntries: Bool {
        didSet {
            userDefaults.set(includeSubgroupEntries, forKey: Key.includeSubgroupEntries)
        }
    }

    public var lookForConflictCopies: Bool {
        didSet {
            userDefaults.set(lookForConflictCopies, forKey: Key.lookForConflictCopies)
        }
    }

    public var lockOnScreenLock: Bool {
        didSet {
            userDefaults.set(lockOnScreenLock, forKey: Key.lockOnScreenLock)
        }
    }

    /// Serve KeePassXC-Browser through `keemac-proxy`.
    public var browserIntegrationEnabled: Bool {
        didSet {
            userDefaults.set(browserIntegrationEnabled, forKey: Key.browserIntegrationEnabled)
        }
    }

    /// Send matching logins without asking the first time a site requests them.
    public var browserAlwaysAllowAccess: Bool {
        didSet {
            userDefaults.set(browserAlwaysAllowAccess, forKey: Key.browserAlwaysAllowAccess)
        }
    }

    public var browserAllowExpired: Bool {
        didSet {
            userDefaults.set(browserAllowExpired, forKey: Key.browserAllowExpired)
        }
    }

    /// Save changed logins from the browser without asking first.
    public var browserAlwaysAllowUpdate: Bool {
        didSet {
            userDefaults.set(browserAlwaysAllowUpdate, forKey: Key.browserAlwaysAllowUpdate)
        }
    }

    /// Open Quick Access with a global shortcut.
    public var quickAccessEnabled: Bool {
        didSet {
            userDefaults.set(quickAccessEnabled, forKey: Key.quickAccessEnabled)
        }
    }

    public var quickAccessShortcut: QuickAccessShortcut {
        didSet {
            userDefaults.set(try? JSONEncoder().encode(quickAccessShortcut), forKey: Key.quickAccessShortcut)
        }
    }

    public var quickAccessUnlockDuration: QuickAccessUnlockDuration {
        didSet {
            userDefaults.set(quickAccessUnlockDuration.rawValue, forKey: Key.quickAccessUnlockDuration)
        }
    }

    /// Type the matching entry into the frontmost window with a global shortcut.
    public var autoTypeEnabled: Bool {
        didSet { userDefaults.set(autoTypeEnabled, forKey: Key.autoTypeEnabled) }
    }

    public var autoTypeShortcut: QuickAccessShortcut {
        didSet { userDefaults.set(try? JSONEncoder().encode(autoTypeShortcut), forKey: Key.autoTypeShortcut) }
    }

    /// Pause between Auto-Type keystrokes in milliseconds (0…1000).
    public var autoTypeKeyDelay: Int {
        didSet { userDefaults.set(autoTypeKeyDelay, forKey: Key.autoTypeKeyDelay) }
    }

    /// Serve the main database's SSH keys on the agent socket.
    public var sshAgentEnabled: Bool {
        didSet { userDefaults.set(sshAgentEnabled, forKey: Key.sshAgentEnabled) }
    }

    /// Offer only the keys that match the server; all of them when nothing matches.
    public var sshPickKeysByHost: Bool {
        didSet { userDefaults.set(sshPickKeysByHost, forKey: Key.sshPickKeysByHost) }
    }

    /// Remember a server on a key the first time the server accepts it.
    public var sshLearnHosts: Bool {
        didSet { userDefaults.set(sshLearnHosts, forKey: Key.sshLearnHosts) }
    }

    /// Confirmation for keys that don't set their own.
    public var sshDefaultConfirmation: VaultSSHConfirmation {
        didSet { userDefaults.set(sshDefaultConfirmation.rawValue, forKey: Key.sshDefaultConfirmation) }
    }

    /// Ask for forwarded requests (`ssh -A`) even when the key doesn't need confirmation.
    public var sshAskForwarded: Bool {
        didSet { userDefaults.set(sshAskForwarded, forKey: Key.sshAskForwarded) }
    }

    private var perVaultSettings: [String: VaultSettings] {
        didSet {
            persistPerVaultSettings()
        }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let rawClipboardTimeout = userDefaults.object(forKey: Key.clipboardTimeoutSeconds) as? TimeInterval ?? 30
        clipboardAutoClearTimeoutSeconds = Self.normalizeTimeout(rawClipboardTimeout)

        let rawDefaultIdleLockTimeout = userDefaults.object(forKey: Key.defaultIdleLockTimeoutSeconds) as? TimeInterval ?? 300
        defaultIdleLockTimeoutSeconds = Self.normalizeTimeout(rawDefaultIdleLockTimeout)

        if let persistedShowDockIcon = userDefaults.object(forKey: Key.showDockIcon) as? Bool {
            showDockIcon = persistedShowDockIcon
        } else {
            showDockIcon = true
        }

        startMinimized = userDefaults.object(forKey: Key.startMinimized) as? Bool ?? false

        if let persistedIncludeSubgroupEntries = userDefaults.object(forKey: Key.includeSubgroupEntries) as? Bool {
            includeSubgroupEntries = persistedIncludeSubgroupEntries
        } else {
            includeSubgroupEntries = false
        }

        lookForConflictCopies = userDefaults.object(forKey: Key.lookForConflictCopies) as? Bool ?? true
        lockOnScreenLock = userDefaults.object(forKey: Key.lockOnScreenLock) as? Bool ?? true
        browserIntegrationEnabled = userDefaults.object(forKey: Key.browserIntegrationEnabled) as? Bool ?? false
        browserAlwaysAllowAccess = userDefaults.object(forKey: Key.browserAlwaysAllowAccess) as? Bool ?? false
        browserAllowExpired = userDefaults.object(forKey: Key.browserAllowExpired) as? Bool ?? false
        browserAlwaysAllowUpdate = userDefaults.object(forKey: Key.browserAlwaysAllowUpdate) as? Bool ?? false
        quickAccessEnabled = userDefaults.object(forKey: Key.quickAccessEnabled) as? Bool ?? true
        quickAccessShortcut = userDefaults.data(forKey: Key.quickAccessShortcut)
            .flatMap { try? JSONDecoder().decode(QuickAccessShortcut.self, from: $0) } ?? .default
        quickAccessUnlockDuration = (userDefaults.object(forKey: Key.quickAccessUnlockDuration) as? Int)
            .flatMap(QuickAccessUnlockDuration.init(rawValue:)) ?? .untilAutoLock
        autoTypeEnabled = userDefaults.object(forKey: Key.autoTypeEnabled) as? Bool ?? true
        autoTypeShortcut = userDefaults.data(forKey: Key.autoTypeShortcut)
            .flatMap { try? JSONDecoder().decode(QuickAccessShortcut.self, from: $0) } ?? .autoTypeDefault
        autoTypeKeyDelay = min(max(userDefaults.object(forKey: Key.autoTypeKeyDelay) as? Int ?? 10, 0), 1000)
        sshAgentEnabled = userDefaults.object(forKey: Key.sshAgentEnabled) as? Bool ?? true
        sshPickKeysByHost = userDefaults.object(forKey: Key.sshPickKeysByHost) as? Bool ?? true
        sshLearnHosts = userDefaults.object(forKey: Key.sshLearnHosts) as? Bool ?? true
        sshDefaultConfirmation = userDefaults.string(forKey: Key.sshDefaultConfirmation)
            .flatMap(VaultSSHConfirmation.init(rawValue:)) ?? .oncePerUnlock
        sshAskForwarded = userDefaults.object(forKey: Key.sshAskForwarded) as? Bool ?? true

        if let data = userDefaults.data(forKey: Key.perVaultSettingsData),
           let decoded = try? JSONDecoder().decode([String: VaultSettings].self, from: data) {
            perVaultSettings = decoded
        } else {
            perVaultSettings = [:]
        }
    }

    public func isTouchIDEnabled(for vaultURL: URL?) -> Bool {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return true
        }
        return perVaultSettings[identity]?.touchIDEnabled ?? true
    }

    public func setTouchIDEnabled(_ enabled: Bool, for vaultURL: URL?) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return
        }

        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        settings.touchIDEnabled = enabled
        perVaultSettings[identity] = settings
    }

    public func hardwareKey(for vaultURL: URL?) -> VaultHardwareKey? {
        vaultIdentity(for: vaultURL).flatMap { perVaultSettings[$0]?.hardwareKey }
    }

    public func setHardwareKey(_ key: VaultHardwareKey?, for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.hardwareKey = key }
    }

    public func touchIDSkipsHardwareKey(for vaultURL: URL?) -> Bool {
        vaultIdentity(for: vaultURL).flatMap { perVaultSettings[$0]?.touchIDSkipsHardwareKey } ?? false
    }

    public func setTouchIDSkipsHardwareKey(_ skips: Bool, for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.touchIDSkipsHardwareKey = skips }
    }

    public func idleLockTimeoutSeconds(for vaultURL: URL?) -> TimeInterval {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return defaultIdleLockTimeoutSeconds
        }
        return perVaultSettings[identity]?.idleLockTimeoutSeconds ?? defaultIdleLockTimeoutSeconds
    }

    public func setIdleLockTimeoutSeconds(_ seconds: TimeInterval, for vaultURL: URL?) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            defaultIdleLockTimeoutSeconds = seconds
            return
        }

        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        settings.idleLockTimeoutSeconds = Self.normalizeTimeout(seconds)
        perVaultSettings[identity] = settings
    }

    public func sidebarSelectionID(for vaultURL: URL?) -> String? {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return nil
        }
        return perVaultSettings[identity]?.sidebarSelectionID
    }

    public func setSidebarSelectionID(_ id: String?, for vaultURL: URL?) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return
        }
        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        settings.sidebarSelectionID = id
        perVaultSettings[identity] = settings
    }

    public func expandedGroupPaths(for vaultURL: URL?) -> Set<String> {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return []
        }
        return Set(perVaultSettings[identity]?.expandedGroupPaths ?? [])
    }

    public func setExpandedGroupPaths(_ paths: Set<String>, for vaultURL: URL?) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return
        }
        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        settings.expandedGroupPaths = paths.sorted()
        perVaultSettings[identity] = settings
    }

    public func syncMode(for vaultURL: URL?) -> VaultSyncMode {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return .automatic
        }
        return perVaultSettings[identity]?.syncMode ?? .automatic
    }

    public func setSyncMode(_ mode: VaultSyncMode, for vaultURL: URL?) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return
        }
        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        settings.syncMode = mode
        perVaultSettings[identity] = settings
    }

    public static let expiryWarnDayOptions = [7, 14, 30]

    public func expiryNotificationsEnabled(for vaultURL: URL?) -> Bool {
        vaultSettings(for: vaultURL)?.expiryNotifications ?? true
    }

    public func setExpiryNotificationsEnabled(_ enabled: Bool, for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.expiryNotifications = enabled }
    }

    public func expiryWarnDays(for vaultURL: URL?) -> Int {
        vaultSettings(for: vaultURL)?.expiryWarnDays ?? 7
    }

    public func setExpiryWarnDays(_ days: Int, for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.expiryWarnDays = days }
    }

    public func expiryBannerEnabled(for vaultURL: URL?) -> Bool {
        vaultSettings(for: vaultURL)?.expiryBanner ?? true
    }

    public func setExpiryBannerEnabled(_ enabled: Bool, for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.expiryBanner = enabled }
    }

    private func vaultSettings(for vaultURL: URL?) -> VaultSettings? {
        vaultIdentity(for: vaultURL).flatMap { perVaultSettings[$0] }
    }

    public func additionalDatabases(for vaultURL: URL?) -> [StoredAdditionalDatabase] {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return []
        }
        return perVaultSettings[identity]?.additionalDatabases ?? []
    }

    public func setAdditionalDatabases(_ databases: [StoredAdditionalDatabase], for vaultURL: URL?) {
        updateVaultSettings(for: vaultURL) { $0.additionalDatabases = databases.isEmpty ? nil : databases }
    }

    private func updateVaultSettings(for vaultURL: URL?, _ change: (inout VaultSettings) -> Void) {
        guard let identity = vaultIdentity(for: vaultURL) else {
            return
        }
        var settings = perVaultSettings[identity] ?? VaultSettings(
            touchIDEnabled: true,
            idleLockTimeoutSeconds: defaultIdleLockTimeoutSeconds
        )
        change(&settings)
        perVaultSettings[identity] = settings
    }

    private static func normalizeTimeout(_ value: TimeInterval) -> TimeInterval {
        if value <= 0 {
            return 0
        }
        return max(5, value)
    }

    private func persistPerVaultSettings() {
        guard let data = try? JSONEncoder().encode(perVaultSettings) else {
            return
        }
        userDefaults.set(data, forKey: Key.perVaultSettingsData)
    }

    private func vaultIdentity(for vaultURL: URL?) -> String? {
        guard let vaultURL else {
            return nil
        }
        return vaultURL.standardizedFileURL.path
    }
}
