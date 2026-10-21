import XCTest

final class SettingsUITests: KeeMacUITestCase {
    func testTouchIDUnlockAfterPasswordUnlock() {
        launch()
        XCTAssertFalse(element("unlock.touchID").waitForExistence(timeout: 2), "Touch ID needs one password unlock first")
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))

        element("toolbar.lock").click()
        reopenMainWindow()
        let touchID = element("unlock.touchID")
        XCTAssertTrue(touchID.waitForExistence(timeout: 5))
        touchID.click()
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))
    }

    func testTurningTouchIDOffHidesIt() {
        launchUnlocked()
        openSettings(tab: "Security")
        let toggle = element("settings.touchID")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 1, "on by default")
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        closeSettings(tab: "Security")

        element("toolbar.lock").click()
        reopenMainWindow()
        XCTAssertFalse(element("unlock.touchID").waitForExistence(timeout: 2))
    }

    func testLayoutsKeepListAndDetailWorking() {
        launchUnlocked()
        for layout in ["compact", "classic", "tahoe"] {
            openSettings(tab: "General")
            let segment = element("settings.layout.\(layout)")
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "no \(layout) layout")
            // On a small screen the General tab scrolls and the layout picker is below the fold.
            scrollIntoView(segment, in: app.windows["General"].scrollViews.firstMatch)
            segment.click()
            closeSettings(tab: "General")

            selectEntry("Mail")
            XCTAssertEqual(text("detail.title"), "Mail", layout)
            element("detail.copyPassword").click()
            waitForPasteboard("red-Pill-3")
            Self.pasteboard.clearContents()
        }
    }

    func testPasswordGeneratorCopiesAndRegenerates() {
        launch()
        app.menuBarItems["KeeMac"].click()
        app.menuBars.menuItems["Generate Password..."].firstMatch.click()
        let result = element("generator.result")
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let first = text("generator.result") ?? ""
        XCTAssertGreaterThanOrEqual(first.count, 12)

        element("generator.copy").click()
        waitForPasteboard(first)

        element("generator.regenerate").click()
        let changed = expectation(for: NSPredicate(format: "value != %@", first), evaluatedWith: result)
        wait(for: [changed], timeout: 5)

        element("generator.mode.passphrase").click()
        let hyphenated = expectation(for: NSPredicate(format: "value MATCHES %@", "^[a-z]+(-[a-z]+){3,}$"), evaluatedWith: result)
        wait(for: [hyphenated], timeout: 5)
    }
}
