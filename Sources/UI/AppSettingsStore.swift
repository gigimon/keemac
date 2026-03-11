import Foundation
import Observation

@MainActor
@Observable
public final class AppSettingsStore {
    private enum Key {
        static let clipboardTimeoutSeconds = "keemac.settings.clipboard.timeout.seconds"
        static let defaultIdleLockTimeoutSeconds = "keemac.settings.vault.idlelock.default.seconds"
        static let perVaultSettingsData = "keemac.settings.vault.pervault.data"
        static let showDockIcon = "keemac.settings.appearance.showDockIcon"
        static let includeSubgroupEntries = "keemac.settings.browser.includeSubgroupEntries"
    }

    private struct VaultSettings: Codable {
        var touchIDEnabled: Bool = true
        var idleLockTimeoutSeconds: TimeInterval = 300
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

    public var includeSubgroupEntries: Bool {
        didSet {
            userDefaults.set(includeSubgroupEntries, forKey: Key.includeSubgroupEntries)
        }
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

        if let persistedIncludeSubgroupEntries = userDefaults.object(forKey: Key.includeSubgroupEntries) as? Bool {
            includeSubgroupEntries = persistedIncludeSubgroupEntries
        } else {
            includeSubgroupEntries = false
        }

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
