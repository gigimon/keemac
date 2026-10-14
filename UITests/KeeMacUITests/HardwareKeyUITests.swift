import XCTest

/// A software YubiKey (`KEEMAC_UI_TEST_HARDWARE_KEY`) stands in for USB: serial 12345678, slot 2.
final class HardwareKeyUITests: KeeMacUITestCase {
    private static let secret = "0102030405060708090a0b0c0d0e0f1011121314"
    private static let keyLabel = "YubiKey 5 NFC (12345678) · Slot 2"

    private func launchWithHardwareKey(touch: String? = nil, keepDefaults: Bool = false) {
        app.launchEnvironment["KEEMAC_UI_TEST_HARDWARE_KEY"] = Self.secret
        app.launchEnvironment["KEEMAC_UI_TEST_HARDWARE_KEY_TOUCH"] = touch ?? ""
        launch(keepDefaults: keepDefaults)
    }

    private func scrollIntoView(_ target: XCUIElement) {
        let scrollView = app.scrollViews.containing(.any, identifier: "dbSettings.name").firstMatch
        for _ in 0..<15 where !target.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -200)
        }
    }

    /// Adds the software key to the sample database through Change Master Key.
    private func addHardwareKey() {
        app.typeKey(",", modifierFlags: [.command, .shift])
        let change = element("dbSettings.changeMasterKey")
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        scrollIntoView(change)
        XCTAssertEqual(text("dbSettings.hardwareKey"), "None")
        change.click()

        let current = element("changeKey.current")
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        element("changeKey.hardwareKey.choose").click()
        let menu = element("changeKey.hardwareKeyPicker.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "connected keys are listed")
        XCTAssertFalse(element("changeKey.submit").isEnabled, "a key must be picked first")
        menu.click()
        app.menuItems[Self.keyLabel].click()
        XCTAssertEqual(text("changeKey.hardwareKeyPicker.chip"), Self.keyLabel)

        current.click()
        current.typeText(Self.samplePassword)
        element("changeKey.submit").click()
        let toast = element("dbSettings.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "no confirmation")
        scrollIntoView(element("dbSettings.hardwareKey"))
        XCTAssertEqual(text("dbSettings.hardwareKey"), "YubiKey 12345678 · Slot 2")
        XCTAssertTrue(element("dbSettings.hardwareKeyTouchID").exists, "the Touch ID option appears with a key")
        element("dbSettings.close").click()
    }

    func testAddHardwareKeyAndUnlockWithIt() {
        launchWithHardwareKey()
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))
        addHardwareKey()

        element("toolbar.lock").click()
        reopenMainWindow()
        XCTAssertEqual(text("unlock.hardwareKey.chip"), Self.keyLabel, "the key is remembered for this database")
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10), "password and key open it")

        element("toolbar.lock").click()
        reopenMainWindow()
        element("unlock.hardwareKey.remove").click()
        XCTAssertTrue(element("unlock.hardwareKey.add").waitForExistence(timeout: 5))
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("unlock.error").waitForExistence(timeout: 10), "the password alone isn't enough")
    }

    func testTouchPanelCanBeCancelled() {
        launchWithHardwareKey()
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))
        addHardwareKey()
        app.terminate()

        // A slot that waits for a touch that never comes.
        launchWithHardwareKey(touch: "timeout", keepDefaults: true)
        unlock(with: Self.samplePassword)
        let title = element("hardwareKey.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the touch panel shows")
        XCTAssertEqual(text("hardwareKey.title"), "Touch your YubiKey")
        element("hardwareKey.cancel").click()
        XCTAssertTrue(waitForDisappearance(title))
        XCTAssertFalse(element("toolbar.search").exists)
        XCTAssertFalse(element("unlock.error").exists, "cancelling isn't an error")
        app.terminate()

        // A touch after a moment.
        launchWithHardwareKey(touch: "1", keepDefaults: true)
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("hardwareKey.title").waitForExistence(timeout: 10))
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 15), "unlocks after the touch")
    }

    func testUnlockScreenPicker() {
        launchWithHardwareKey()
        let add = element("unlock.hardwareKey.add")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let menu = element("unlock.hardwareKey.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems[Self.keyLabel].click()
        XCTAssertEqual(text("unlock.hardwareKey.chip"), Self.keyLabel)
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("unlock.error").waitForExistence(timeout: 10), "the sample database has no hardware key")
    }
}
