import AppKit
import Foundation

/// Launch mode for the XCUITest suite (`UITests/`), turned on with `KEEMAC_UI_TESTING=1`.
///
/// The UI test build has its own bundle identifier (`scripts/build_app.sh --ui-testing`), so its
/// defaults never mix with a real KeeMac's. On top of that the mode keeps the app away from
/// everything shared with the user's own KeeMac: the keychain (Touch ID is kept in memory),
/// the browser and SSH agent sockets, browser manifests, `~/.ssh/known_hosts`, the global
/// shortcut, notifications, the general pasteboard and the snapshot folder.
public enum UITesting {
    public static let isActive = ProcessInfo.processInfo.environment["KEEMAC_UI_TESTING"] == "1"

    /// A database selected at launch, so tests don't have to go through the open panel.
    public static var vaultURL: URL? {
        environment("KEEMAC_UI_TEST_VAULT").map { URL(fileURLWithPath: $0) }
    }

    /// Where "New Database" saves by default, instead of Documents.
    static var newDatabaseDirectory: URL? {
        environment("KEEMAC_UI_TEST_NEW_DATABASE_DIRECTORY").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Secrets are copied here instead of the general pasteboard; tests read it by name.
    public static let pasteboardName = NSPasteboard.Name("com.keemac.uitests")

    @MainActor static var pasteboard: NSPasteboard { NSPasteboard(name: pasteboardName) }

    /// Short enough for `sockaddr_un`. UI tests run one app at a time; each launch starts it empty,
    /// because XCUITest kills the app without `applicationWillTerminate`.
    static let directory = URL(fileURLWithPath: "/tmp/keemac-uitests", isDirectory: true)

    static var browserSocketPath: String { directory.appendingPathComponent("browser.sock").path }
    static var sshAgentSocketPath: String { directory.appendingPathComponent("agent.sock").path }
    static var manifestDirectory: URL { directory.appendingPathComponent("NativeMessaging", isDirectory: true) }
    static var knownHostsURL: URL { directory.appendingPathComponent("known_hosts") }

    /// Call first thing at launch: starts from clean settings unless the test relaunches the app on purpose.
    public static func prepare() {
        guard isActive, let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.hasSuffix(".uitests") else {
            return
        }
        if environment("KEEMAC_UI_TEST_KEEP_DEFAULTS") != "1" {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func cleanUp() {
        guard isActive else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func environment(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Touch ID for UI tests: remembers the password for this launch only.
@MainActor
final class InMemoryBiometricCredentialStore: BiometricCredentialStoring {
    private var passwords: [String: String] = [:]

    func hasSavedMasterPassword(for vaultURL: URL) -> Bool {
        passwords[vaultURL.standardizedFileURL.path] != nil
    }

    func saveMasterPassword(_ password: String, for vaultURL: URL) throws {
        passwords[vaultURL.standardizedFileURL.path] = password
    }

    func loadMasterPassword(for vaultURL: URL, prompt: String) async throws -> String {
        guard let password = passwords[vaultURL.standardizedFileURL.path] else {
            throw BiometricCredentialError.credentialNotFound
        }
        return password
    }

    func deleteMasterPassword(for vaultURL: URL) {
        passwords[vaultURL.standardizedFileURL.path] = nil
    }
}
