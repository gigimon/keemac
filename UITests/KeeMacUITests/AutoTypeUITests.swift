import XCTest

/// The global shortcut is off in UI tests; Vault → "Perform Auto-Type" stands in for it with a
/// made-up Safari window, and what would be typed lands on the test pasteboard (keys as `{TAB}`).
final class AutoTypeUITests: KeeMacUITestCase {
    private func performAutoType() {
        app.menuBars.menuBarItems["Vault"].click()
        app.menuItems["Perform Auto-Type"].click()
    }

    /// The editor's Auto-Type section sits below the fold; macOS UI tests don't scroll by themselves.
    private func scrollIntoView(_ element: XCUIElement) {
        let scrollView = app.scrollViews.containing(.any, identifier: "editor.title").firstMatch
        for _ in 0..<12 where !element.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -200)
        }
    }

    /// The entry's password, copied from the detail view.
    private func password(of title: String) -> String {
        selectEntry(title)
        element("detail.copyPassword").click()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let value = Self.pasteboard.string(forType: .string), !value.isEmpty {
                Self.pasteboard.clearContents()
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("couldn't copy the password of \(title)")
        return ""
    }

    func testTypesTheOnlyMatchingEntry() {
        app.launchEnvironment["KEEMAC_UI_TEST_AUTOTYPE_TITLE"] = "Sign in to GitHub"
        launchUnlocked()
        let password = password(of: "GitHub")

        performAutoType()
        waitForPasteboard("octocat{TAB}\(password){ENTER}")
    }

    func testPickerTypesAnEntryFoundBySearch() {
        app.launchEnvironment["KEEMAC_UI_TEST_AUTOTYPE_TITLE"] = "Sign in"
        launchUnlocked()
        let password = password(of: "Mail")

        performAutoType()
        XCTAssertTrue(element("autoType.target").waitForExistence(timeout: 5), "Quick Access opens in Auto-Type mode")
        XCTAssertTrue(element("autoType.empty").exists, "nothing matches the window")
        let search = element("autoType.search")
        search.typeText("Mail")
        XCTAssertTrue(element("autoType.entry.Mail").waitForExistence(timeout: 5))
        search.typeText("\r")

        let deadline = Date().addingTimeInterval(5)
        var typed = ""
        while Date() < deadline {
            typed = Self.pasteboard.string(forType: .string) ?? ""
            if typed.hasSuffix("{ENTER}") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(typed.hasSuffix("{TAB}\(password){ENTER}"), "got \(typed)")
    }

    func testCustomSequenceAndAssociationsInTheEditor() {
        app.launchEnvironment["KEEMAC_UI_TEST_AUTOTYPE_TITLE"] = "Corporate VPN"
        launchUnlocked()
        selectEntry("Jira")
        element("detail.edit").click()
        let section = element("editor.autoType.toggleSection")
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        scrollIntoView(section)
        section.click()
        let custom = element("editor.autoType.mode.custom")
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "the section opens")
        scrollIntoView(custom)
        custom.click()

        let sequence = element("editor.autoType.sequence")
        XCTAssertTrue(sequence.waitForExistence(timeout: 5))
        replaceText(of: sequence, with: "{USERNAME}{ENTER}{PASWORD}")
        XCTAssertTrue(element("editor.autoType.error").waitForExistence(timeout: 5), "an unknown command is flagged")
        replaceText(of: sequence, with: "{USERNAME}{ENTER}")
        XCTAssertEqual(sequence.value as? String, "{USERNAME}{ENTER}")
        XCTAssertTrue(waitForDisappearance(element("editor.autoType.error")))

        scrollIntoView(element("editor.autoType.addAssociation"))
        element("editor.autoType.addAssociation").click()
        let pattern = element("editor.autoType.association.0.title")
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        pattern.click()
        pattern.typeText("Corporate*")
        element("editor.save").click()

        XCTAssertTrue(element("detail.edit").waitForExistence(timeout: 5))
        let summary = text("detail.autoType") ?? ""
        XCTAssertTrue(summary.contains("{USERNAME}{ENTER}"), "got \(summary)")
        XCTAssertTrue(summary.contains("1 window association"), "got \(summary)")

        performAutoType()
        waitForPasteboard("octocat@example.com{ENTER}", timeout: 5)
    }

    func testGroupCanTurnAutoTypeOff() {
        launchUnlocked()
        let work = element("sidebar.group.Sample.Work")
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.rightClick()
        app.menuItems["Edit Group…"].click()
        let off = element("groupEditor.autoType.enabled.off")
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.click()
        element("groupEditor.submit").click()
        XCTAssertTrue(waitForDisappearance(off))

        selectEntry("GitHub")
        let summary = text("detail.autoType") ?? ""
        XCTAssertTrue(summary.contains("turned off by group “Work”"), "got \(summary)")
    }

    func testWithoutAccessibilityAsksForIt() {
        app.launchEnvironment["KEEMAC_UI_TEST_AUTOTYPE_PERMISSION"] = "denied"
        launchUnlocked()
        performAutoType()
        let notNow = element("autoType.notNow")
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "the notice asks for Accessibility")
        XCTAssertTrue(element("autoType.openSystemSettings").exists)
        notNow.click()
        XCTAssertTrue(waitForDisappearance(notNow))

        openSettings(tab: "Auto-Type")
        XCTAssertEqual(text("settings.autoType.permission"), "Not granted")
        closeSettings(tab: "Auto-Type")
    }

    func testSettingsTab() {
        launchUnlocked()
        openSettings(tab: "Auto-Type")
        XCTAssertEqual(text("settings.autoType.permission"), "Granted")
        XCTAssertTrue(element("settings.autoType.enabled").exists)
        XCTAssertTrue(element("settings.autoType.delay").exists)
        closeSettings(tab: "Auto-Type")
    }
}
