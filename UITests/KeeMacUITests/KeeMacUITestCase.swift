import AppKit
import Carbon.HIToolbox
import XCTest

/// Launches the UI test build of KeeMac (`scripts/build_app.sh --ui-testing`) against a copy of
/// `Fixtures/Sample.kdbx`. The app runs in `UITesting` mode: its own defaults, sockets and
/// pasteboard, no keychain, no global shortcut.
@MainActor
class KeeMacUITestCase: XCTestCase {
    static let samplePassword = "sample-password"
    /// Where KeeMac copies secrets in UI testing mode.
    static let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.keemac.uitests"))

    private(set) var app: XCUIApplication!
    private(set) var workDirectory: URL!
    private(set) var vaultURL: URL!
    /// The user's layout before the first test; selecting another one is asynchronous, so a later
    /// test could otherwise mistake U.S. for the user's choice.
    private static var originalInputSource: TISInputSource?

    override func setUp() async throws {
        continueAfterFailure = false
        selectUSKeyboardLayout()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KeeMacUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(
            Bundle(for: KeeMacUITestCase.self).url(forResource: "Sample", withExtension: "kdbx", subdirectory: "Fixtures"),
            "Fixtures/Sample.kdbx is missing from the test bundle"
        )
        vaultURL = workDirectory.appendingPathComponent("Sample.kdbx")
        try FileManager.default.copyItem(at: fixture, to: vaultURL)
        Self.pasteboard.clearContents()
        app = XCUIApplication(url: try Self.appURL())
    }

    override func tearDown() async throws {
        app?.terminate()
        if let original = Self.originalInputSource {
            TISSelectInputSource(original)
        }
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    /// `typeText` turns characters into key codes of the current layout, so Latin text can't be typed
    /// with a Russian layout selected. Switches to U.S. for the test and back afterwards.
    private func selectUSKeyboardLayout() {
        if Self.originalInputSource == nil {
            Self.originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        }
        let properties = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource],
              let us = sources.first else {
            return
        }
        TISSelectInputSource(us)
    }

    /// `KEEMAC_APP_PATH` (or `TEST_RUNNER_KEEMAC_APP_PATH` passed to xcodebuild) wins over the default build output.
    static func appURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["KEEMAC_APP_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/uitest-dist/KeeMac.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Build the app first: scripts/build_app.sh --ui-testing")
        }
        return url
    }

    /// Starts KeeMac with the sample database selected, in English unless a test asks otherwise.
    func launch(selectingVault: Bool = true, keepDefaults: Bool = false, language: String = "en") {
        app.launchEnvironment["KEEMAC_UI_TESTING"] = "1"
        app.launchEnvironment["KEEMAC_UI_TEST_VAULT"] = selectingVault ? vaultURL.path : ""
        app.launchEnvironment["KEEMAC_UI_TEST_KEEP_DEFAULTS"] = keepDefaults ? "1" : "0"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        app.launch()
        app.activate()
    }

    /// Launches and unlocks the sample database.
    func launchUnlocked() {
        launch()
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10), "the database didn't open")
    }

    func unlock(with password: String) {
        let field = element("unlock.password")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no unlock screen")
        field.click()
        field.typeText(password)
        field.typeText("\r")
    }

    /// Locking hides the main window; brings it back like a user would, from the menu bar icon.
    func reopenMainWindow() {
        app.activate()
        if element("unlock.password").waitForExistence(timeout: 2) {
            return
        }
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no menu bar icon")
        statusItem.click()
        app.menuItems["Open KeeMac"].click()
        XCTAssertTrue(element("unlock.password").waitForExistence(timeout: 5), "the main window didn't come back")
    }

    /// Replaces a field's text (new entries start with a generated password).
    func replaceText(of element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    func selectEntry(_ title: String) {
        let row = entryRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no entry \(title)")
        row.click()
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 5))
    }

    func selectSidebar(_ id: String) {
        let row = element("sidebar.\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row \(id)")
        row.click()
    }

    /// Answers the in-window confirmation dialog.
    func confirm() {
        let button = element("confirm.confirm")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no confirmation dialog")
        button.click()
    }

    /// Text of a SwiftUI `Text`, which XCUITest reports as the static text's value.
    func text(_ identifier: String) -> String? {
        let element = element(identifier)
        guard element.waitForExistence(timeout: 5) else {
            return nil
        }
        return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// The Settings window is titled after its selected tab.
    func openSettings(tab: String) {
        app.typeKey(",", modifierFlags: .command)
        let button = app.windows.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no settings tab \(tab)")
        button.click()
        XCTAssertTrue(app.windows[tab].waitForExistence(timeout: 5))
    }

    /// Closes Settings with its own close button; ⌘W could hit the main window instead.
    func closeSettings(tab: String) {
        let window = app.windows[tab]
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitForDisappearance(window))
    }

    /// Scrolls `target` well clear of the scroll view's and the screen's bottom edge: macOS UI tests don't
    /// scroll by themselves, and a click near the bottom of the screen can land on an auto-hiding Dock.
    func scrollIntoView(_ target: XCUIElement, in scrollView: XCUIElement) {
        let screenBottom = NSScreen.screens.first.map { $0.frame.height - $0.visibleFrame.minY } ?? .greatestFiniteMagnitude
        let margin: CGFloat = 120
        guard target.waitForExistence(timeout: 5) else {
            return
        }
        var previous: CGRect?
        for _ in 0..<20 {
            let frame = target.frame
            let bottom = min(scrollView.frame.maxY, screenBottom) - margin
            if target.isHittable, frame.maxY <= bottom {
                return
            }
            if frame == previous {
                return
            }
            previous = frame
            scrollView.scroll(byDeltaX: 0, deltaY: -100)
        }
    }

    /// Any element by accessibility identifier, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func entryRow(_ title: String) -> XCUIElement {
        element("entry.\(title)")
    }

    func waitForPasteboard(_ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.pasteboard.string(forType: .string) == expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("pasteboard has \(String(describing: Self.pasteboard.string(forType: .string))), expected \(expected)", file: file, line: line)
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
