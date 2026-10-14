import AppKit
import Domain
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

    /// Accessibility as Auto-Type sees it; `KEEMAC_UI_TEST_AUTOTYPE_PERMISSION=denied` takes it away.
    static var autoTypePermissionGranted: Bool {
        environment("KEEMAC_UI_TEST_AUTOTYPE_PERMISSION") != "denied"
    }

    /// The window Auto-Type pretends is in front (`KEEMAC_UI_TEST_AUTOTYPE_TITLE`, `…_URL`).
    static var autoTypeWindow: AutoTypeWindow {
        AutoTypeWindow(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: environment("KEEMAC_UI_TEST_AUTOTYPE_TITLE") ?? "Sign in",
            url: environment("KEEMAC_UI_TEST_AUTOTYPE_URL")
        )
    }

    /// Stands in for the open and save panels of the Change Master Key sheet (`KEEMAC_UI_TEST_KEY_FILE`).
    static var keyFileURL: URL? {
        environment("KEEMAC_UI_TEST_KEY_FILE").map { URL(fileURLWithPath: $0) }
    }

    /// A software YubiKey 12345678, slot 2, instead of USB (`KEEMAC_UI_TEST_HARDWARE_KEY=<hex secret>`).
    /// `KEEMAC_UI_TEST_HARDWARE_KEY_TOUCH=1` makes it wait 1.5 s for a "touch", `=timeout` never gets one.
    static let hardwareKey: SoftwareHardwareKey? = {
        guard let hex = environment("KEEMAC_UI_TEST_HARDWARE_KEY") else {
            return nil
        }
        let secret = Data(stride(from: 0, to: hex.count - 1, by: 2).compactMap { offset -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        })
        let touch = environment("KEEMAC_UI_TEST_HARDWARE_KEY_TOUCH")
        let key = VaultHardwareKey(serial: 12_345_678, slot: 2, model: "YubiKey 5 NFC", requiresTouch: touch != nil)
        guard let touch else {
            return SoftwareHardwareKey(secret: secret, key: key)
        }
        return SoftwareHardwareKey(secret: secret, key: key) { isCancelled in
            let deadline = Date().addingTimeInterval(touch == "timeout" ? 30 : 1.5)
            while Date() < deadline {
                if isCancelled() {
                    return false
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return touch != "timeout"
        }
    }()

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

    private var responses: [String: VaultHardwareKeyResponse] = [:]

    func saveHardwareKeyResponse(_ response: VaultHardwareKeyResponse, for vaultURL: URL) throws {
        responses[vaultURL.standardizedFileURL.path] = response
    }

    func loadHardwareKeyResponse(for vaultURL: URL) -> VaultHardwareKeyResponse? {
        responses[vaultURL.standardizedFileURL.path]
    }

    func deleteHardwareKeyResponse(for vaultURL: URL) {
        responses[vaultURL.standardizedFileURL.path] = nil
    }
}
