import AppKit
import Foundation
@testable import UI
import XCTest

@MainActor
final class SensitiveClipboardTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    private var settings: AppSettingsStore!

    override func setUp() async throws {
        suiteName = "KeeMacSensitiveClipboardTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettingsStore(userDefaults: defaults)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("KeeMacTests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suiteName)
        CopyFeedbackCenter.shared.dismiss()
    }

    private func makeClipboard() -> SensitiveClipboard {
        SensitiveClipboard(pasteboard: pasteboard, settingsStore: settings)
    }

    func testCopyPutsSecretOnPasteboardAndDescribesTimeout() {
        let clipboard = makeClipboard()
        defer { clipboard.clearSensitiveContents() }
        XCTAssertEqual(clipboard.copySensitiveText("s3cret", label: "Password", showsToast: false), "Password copied · clears in 30 seconds")
        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")

        settings.clipboardAutoClearTimeoutSeconds = 90
        XCTAssertEqual(clipboard.copySensitiveText("x", showsToast: false), "Copied · clears in 1 minute")
        settings.clipboardAutoClearTimeoutSeconds = 300
        XCTAssertEqual(clipboard.copySensitiveText("x", label: "PIN", showsToast: false), "PIN copied · clears in 5 minutes")
        settings.clipboardAutoClearTimeoutSeconds = 0
        XCTAssertEqual(clipboard.copySensitiveText("x", label: "PIN", showsToast: false), "PIN copied")
    }

    func testCopyShowsToastUnlessAskedNotTo() {
        let clipboard = makeClipboard()
        defer { clipboard.clearSensitiveContents() }
        CopyFeedbackCenter.shared.dismiss()
        clipboard.copySensitiveText("a", label: "Password", showsToast: false)
        XCTAssertNil(CopyFeedbackCenter.shared.currentMessage)
        clipboard.copySensitiveText("a", label: "Password")
        XCTAssertEqual(CopyFeedbackCenter.shared.currentMessage, "Password copied · clears in 30 seconds")
    }

    func testClearRemovesOnlyOurSecret() {
        let clipboard = makeClipboard()
        clipboard.copySensitiveText("s3cret", showsToast: false)
        clipboard.clearSensitiveContents()
        XCTAssertNil(pasteboard.string(forType: .string))

        clipboard.copySensitiveText("s3cret", showsToast: false)
        pasteboard.clearContents()
        pasteboard.setString("copied by someone else", forType: .string)
        clipboard.clearSensitiveContents()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied by someone else")
    }

    func testPlainTextIsNotCleared() {
        let clipboard = makeClipboard()
        clipboard.copyPlainText("anna", label: "Username")
        XCTAssertEqual(pasteboard.string(forType: .string), "anna")
        XCTAssertEqual(CopyFeedbackCenter.shared.currentMessage, "Username copied", "plain text never mentions clearing")
        clipboard.clearSensitiveContents()
        XCTAssertEqual(pasteboard.string(forType: .string), "anna")
    }

    func testAutoClearAfterTimeout() async throws {
        settings.clipboardAutoClearTimeoutSeconds = 5
        let clipboard = makeClipboard()
        clipboard.copySensitiveText("s3cret", showsToast: false)
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testNoAutoClearWhenTimeoutIsOff() async throws {
        settings.clipboardAutoClearTimeoutSeconds = 0
        let clipboard = makeClipboard()
        clipboard.copySensitiveText("s3cret", showsToast: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")
        clipboard.clearSensitiveContents()
        XCTAssertNil(pasteboard.string(forType: .string), "locking still clears it")
    }
}

@MainActor
final class CopyFeedbackCenterTests: XCTestCase {
    override func tearDown() async throws {
        CopyFeedbackCenter.shared.dismiss()
    }

    func testShowAndDismiss() throws {
        let center = CopyFeedbackCenter.shared
        center.show()
        let toast = try XCTUnwrap(center.current)
        XCTAssertEqual(toast.message, "Copied")
        XCTAssertEqual(toast.style, .success)
        XCTAssertNil(toast.actionTitle)

        center.show("Saved", style: .synced, actionTitle: "Undo")
        XCTAssertEqual(center.currentMessage, "Saved")
        XCTAssertNil(center.current?.actionTitle, "a title without an action is not shown")
        XCTAssertNotEqual(center.current, toast, "every toast is a new one")

        center.dismiss()
        XCTAssertNil(center.current)
        XCTAssertNil(center.currentMessage)
    }

    func testRunActionDismissesAndCallsAction() {
        let center = CopyFeedbackCenter.shared
        var calls = 0
        center.show("Restored", style: .restored, actionTitle: "Undo") { calls += 1 }
        XCTAssertEqual(center.current?.actionTitle, "Undo")
        center.runAction()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(center.current)
        center.runAction()
        XCTAssertEqual(calls, 1, "the action runs once")
    }

    func testToastDismissesItself() async throws {
        let center = CopyFeedbackCenter.shared
        center.show("Short", style: .success, duration: 0.1)
        XCTAssertEqual(center.currentMessage, "Short")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(center.current)

        center.show("First", style: .success, duration: 0.2)
        center.show("Second", style: .success, duration: 5)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(center.currentMessage, "Second", "a new toast cancels the previous timer")
    }
}
