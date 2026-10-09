import Foundation

/// Browsers KeePassXC-Browser runs in, with where each looks for native messaging manifests.
public enum BrowserKind: String, CaseIterable, Sendable, Identifiable {
    case chrome
    case chromium
    case brave
    case edge
    case vivaldi
    case firefox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromium: return "Chromium"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .firefox: return "Firefox"
        }
    }

    /// Relative to `NativeMessagingHosts.defaultDirectory`.
    fileprivate var supportDirectory: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .chromium: return "Chromium"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .firefox: return "Mozilla"
        }
    }
}

public enum NativeMessagingHostState: Equatable, Sendable {
    /// The browser's support folder doesn't exist.
    case browserNotFound
    case notInstalled
    case installed
    /// KeeMac's manifest points to a proxy that moved.
    case outdated
    /// The manifest belongs to another program, usually KeePassXC.
    case otherProgram(path: String)
}

/// Writes `org.keepassxc.keepassxc_browser.json` so browsers start `keemac-proxy`.
public enum NativeMessagingHosts {
    public static let proxyName = "keemac-proxy"

    private static let chromiumOrigins = [
        "chrome-extension://oboonakemofpalcgghocfoadofidjkkk/",
        "chrome-extension://pdffhmdngciaglkoonimfcmckehcpafo/"
    ]
    private static let firefoxExtensions = ["keepassxc-browser@keepassxc.org"]

    /// `keemac-proxy` next to the running executable: `Contents/MacOS` in the app, the build folder for `swift run`.
    public static var proxyURL: URL? {
        Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(proxyName)
    }

    /// `~/Library/Application Support`, where browsers keep their support folders.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func state(
        for browser: BrowserKind,
        proxyURL: URL? = proxyURL,
        in directory: URL = defaultDirectory
    ) -> NativeMessagingHostState {
        guard FileManager.default.fileExists(atPath: browserDirectory(for: browser, in: directory).path) else {
            return .browserNotFound
        }
        guard let data = try? Data(contentsOf: manifestURL(for: browser, in: directory)) else {
            return .notInstalled
        }
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = manifest["path"] as? String else {
            return .otherProgram(path: "")
        }
        guard URL(fileURLWithPath: path).lastPathComponent == proxyName else {
            return .otherProgram(path: path)
        }
        return path == proxyURL?.path ? .installed : .outdated
    }

    public static func install(for browser: BrowserKind, proxyURL: URL, in directory: URL = defaultDirectory) throws {
        var manifest: [String: Any] = [
            "name": BrowserProtocol.hostName,
            "description": "KeeMac integration with KeePassXC-Browser",
            "path": proxyURL.path,
            "type": "stdio"
        ]
        if browser == .firefox {
            manifest["allowed_extensions"] = firefoxExtensions
        } else {
            manifest["allowed_origins"] = chromiumOrigins
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = manifestURL(for: browser, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// Removes the manifest only when it is KeeMac's.
    public static func uninstall(for browser: BrowserKind, in directory: URL = defaultDirectory) throws {
        switch state(for: browser, in: directory) {
        case .installed, .outdated:
            try FileManager.default.removeItem(at: manifestURL(for: browser, in: directory))
        case .browserNotFound, .notInstalled, .otherProgram:
            return
        }
    }

    public static func manifestURL(for browser: BrowserKind, in directory: URL = defaultDirectory) -> URL {
        browserDirectory(for: browser, in: directory)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(BrowserProtocol.hostName + ".json")
    }

    private static func browserDirectory(for browser: BrowserKind, in directory: URL) -> URL {
        directory.appendingPathComponent(browser.supportDirectory, isDirectory: true)
    }
}
