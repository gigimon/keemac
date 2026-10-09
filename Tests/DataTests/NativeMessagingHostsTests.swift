import BrowserIntegration
import Foundation
import XCTest

final class NativeMessagingHostsTests: XCTestCase {
    private var directory: URL!
    private let proxy = URL(fileURLWithPath: "/Applications/KeeMac.app/Contents/MacOS/keemac-proxy")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeHosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBrowserFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
    }

    private func manifest(for browser: BrowserKind) throws -> [String: Any] {
        let data = try Data(contentsOf: NativeMessagingHosts.manifestURL(for: browser, in: directory))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeManifest(_ object: Any, for browser: BrowserKind) throws {
        let url = NativeMessagingHosts.manifestURL(for: browser, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func testDefaultDirectoryIsApplicationSupport() {
        XCTAssertTrue(NativeMessagingHosts.defaultDirectory.path.hasSuffix("/Library/Application Support"))
        XCTAssertEqual(
            NativeMessagingHosts.manifestURL(for: .chrome).path,
            NativeMessagingHosts.defaultDirectory.path + "/Google/Chrome/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json"
        )
    }

    func testManifestLocations() {
        let expected: [BrowserKind: String] = [
            .chrome: "Google/Chrome",
            .chromium: "Chromium",
            .brave: "BraveSoftware/Brave-Browser",
            .edge: "Microsoft Edge",
            .vivaldi: "Vivaldi",
            .firefox: "Mozilla"
        ]
        for browser in BrowserKind.allCases {
            let url = NativeMessagingHosts.manifestURL(for: browser, in: directory)
            XCTAssertEqual(url.path, directory.path + "/" + (expected[browser] ?? "?") + "/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json")
            XCTAssertFalse(browser.title.isEmpty)
        }
    }

    func testStateWithoutBrowserOrManifest() throws {
        XCTAssertEqual(NativeMessagingHosts.state(for: .chrome, proxyURL: proxy, in: directory), .browserNotFound)
        try makeBrowserFolder("Google/Chrome")
        XCTAssertEqual(NativeMessagingHosts.state(for: .chrome, proxyURL: proxy, in: directory), .notInstalled)
        XCTAssertEqual(NativeMessagingHosts.state(for: .edge, proxyURL: proxy, in: directory), .browserNotFound)
    }

    func testInstallChromiumFamilyManifest() throws {
        try makeBrowserFolder("Google/Chrome")
        try NativeMessagingHosts.install(for: .chrome, proxyURL: proxy, in: directory)

        let manifest = try manifest(for: .chrome)
        XCTAssertEqual(manifest["name"] as? String, "org.keepassxc.keepassxc_browser")
        XCTAssertEqual(manifest["path"] as? String, proxy.path)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertEqual(manifest["allowed_origins"] as? [String], [
            "chrome-extension://oboonakemofpalcgghocfoadofidjkkk/",
            "chrome-extension://pdffhmdngciaglkoonimfcmckehcpafo/"
        ])
        XCTAssertNil(manifest["allowed_extensions"])
        let text = try String(contentsOf: NativeMessagingHosts.manifestURL(for: .chrome, in: directory), encoding: .utf8)
        XCTAssertTrue(text.contains("\"path\" : \"/Applications/KeeMac.app/Contents/MacOS/keemac-proxy\""), "slashes aren't escaped")
        XCTAssertEqual(NativeMessagingHosts.state(for: .chrome, proxyURL: proxy, in: directory), .installed)
    }

    func testInstallFirefoxManifest() throws {
        try makeBrowserFolder("Mozilla")
        try NativeMessagingHosts.install(for: .firefox, proxyURL: proxy, in: directory)

        let manifest = try manifest(for: .firefox)
        XCTAssertEqual(manifest["allowed_extensions"] as? [String], ["keepassxc-browser@keepassxc.org"])
        XCTAssertNil(manifest["allowed_origins"])
        XCTAssertEqual(NativeMessagingHosts.state(for: .firefox, proxyURL: proxy, in: directory), .installed)
    }

    func testMovedProxyIsOutdatedAndReinstallFixesIt() throws {
        try makeBrowserFolder("Vivaldi")
        let oldProxy = URL(fileURLWithPath: "/Users/me/Downloads/KeeMac.app/Contents/MacOS/keemac-proxy")
        try NativeMessagingHosts.install(for: .vivaldi, proxyURL: oldProxy, in: directory)

        XCTAssertEqual(NativeMessagingHosts.state(for: .vivaldi, proxyURL: proxy, in: directory), .outdated)
        XCTAssertEqual(NativeMessagingHosts.state(for: .vivaldi, proxyURL: nil, in: directory), .outdated)
        try NativeMessagingHosts.install(for: .vivaldi, proxyURL: proxy, in: directory)
        XCTAssertEqual(NativeMessagingHosts.state(for: .vivaldi, proxyURL: proxy, in: directory), .installed)
    }

    func testUninstallRemovesOnlyKeeMacsManifest() throws {
        try makeBrowserFolder("BraveSoftware/Brave-Browser")
        try NativeMessagingHosts.install(for: .brave, proxyURL: URL(fileURLWithPath: "/old/keemac-proxy"), in: directory)
        try NativeMessagingHosts.uninstall(for: .brave, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NativeMessagingHosts.manifestURL(for: .brave, in: directory).path), "an outdated KeeMac manifest is removed")
        XCTAssertEqual(NativeMessagingHosts.state(for: .brave, proxyURL: proxy, in: directory), .notInstalled)

        let keePassXC = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-proxy"
        try writeManifest(["name": "org.keepassxc.keepassxc_browser", "path": keePassXC, "type": "stdio"], for: .brave)
        XCTAssertEqual(NativeMessagingHosts.state(for: .brave, proxyURL: proxy, in: directory), .otherProgram(path: keePassXC))
        try NativeMessagingHosts.uninstall(for: .brave, in: directory)
        XCTAssertEqual(try manifest(for: .brave)["path"] as? String, keePassXC, "KeePassXC's manifest stays")

        try NativeMessagingHosts.install(for: .brave, proxyURL: proxy, in: directory)
        XCTAssertEqual(NativeMessagingHosts.state(for: .brave, proxyURL: proxy, in: directory), .installed, "installing on request overwrites it")

        try NativeMessagingHosts.uninstall(for: .chromium, in: directory)
        try NativeMessagingHosts.uninstall(for: .edge, in: directory)
    }

    func testUnreadableManifestBelongsToAnotherProgram() throws {
        try makeBrowserFolder("Chromium")
        let url = NativeMessagingHosts.manifestURL(for: .chromium, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(NativeMessagingHosts.state(for: .chromium, proxyURL: proxy, in: directory), .otherProgram(path: ""))

        try writeManifest(["name": "org.keepassxc.keepassxc_browser"], for: .chromium)
        XCTAssertEqual(NativeMessagingHosts.state(for: .chromium, proxyURL: proxy, in: directory), .otherProgram(path: ""))
        try NativeMessagingHosts.uninstall(for: .chromium, in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testInstallCreatesManifestFolder() throws {
        try makeBrowserFolder("Microsoft Edge")
        let folder = NativeMessagingHosts.manifestURL(for: .edge, in: directory).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try NativeMessagingHosts.install(for: .edge, proxyURL: proxy, in: directory)
        XCTAssertEqual(NativeMessagingHosts.state(for: .edge, proxyURL: proxy, in: directory), .installed)
    }
}
