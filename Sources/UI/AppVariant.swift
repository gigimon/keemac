import BrowserIntegration
import Foundation
import SSHAgent

/// "KeeMac Dev" (a bundle ID ending in `.dev`, built by `build_app.sh` without `--release`) runs next to
/// the installed KeeMac: its own settings and keychain item come from the bundle ID, and here it gets its own
/// sockets. It never edits `~/.ssh/config` and doesn't repoint browser manifests on its own.
public enum AppVariant {
    public static let isDevelopment = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    /// The browser socket name; `keemac-proxy` picks the same one from the bundle it lives in.
    static let browserSocketName = isDevelopment ? "KeeMacDev.BrowserServer" : "KeeMac.BrowserServer"

    static var browserSocketPath: String {
        BrowserProtocol.socketPath(named: browserSocketName)
    }

    static var sshAgentSocketPath: String {
        isDevelopment ? NSHomeDirectory() + "/.keemac-dev/agent.sock" : SSHAgentServer.defaultSocketPath
    }
}

/// KeeMac's packaged builds used the bundle ID `com.keemac.local` before signing; its settings
/// (recent databases, per-database settings, favorites…) move to the signed app once.
public enum LegacySettingsMigration {
    public static let legacyDomain = "com.keemac.local"
    static let migratedKey = "keemac.migration.legacySettings.v1"

    /// Call first thing at launch, before anything reads the settings.
    /// "KeeMac Dev" and the UI test build start with their own settings.
    public static func migrateIfNeeded(
        into defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyDomain: String = legacyDomain
    ) {
        guard let bundleIdentifier, bundleIdentifier != legacyDomain,
              !bundleIdentifier.hasSuffix(".dev"), !bundleIdentifier.hasSuffix(".uitests"),
              !defaults.bool(forKey: migratedKey) else {
            return
        }
        defaults.set(true, forKey: migratedKey)
        // Only into a fresh install: an app that already has KeeMac settings keeps its own.
        let current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        guard !current.keys.contains(where: { $0.hasPrefix("keemac.") && $0 != migratedKey }),
              let legacy = defaults.persistentDomain(forName: legacyDomain) else {
            return
        }
        for (key, value) in legacy where key.hasPrefix("keemac.") {
            defaults.set(value, forKey: key)
        }
    }
}
