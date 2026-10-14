import XCTest

final class DatabaseMaintenanceUITests: KeeMacUITestCase {
    private func openDatabaseSettings() {
        app.typeKey(",", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("dbSettings.close").waitForExistence(timeout: 10), "the Database Settings sheet opens")
    }

    /// The cards below the fold; macOS UI tests don't scroll by themselves.
    private func scrollIntoView(_ target: XCUIElement) {
        let scrollView = app.scrollViews.containing(.any, identifier: "dbSettings.name").firstMatch
        for _ in 0..<15 where !target.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -200)
        }
    }

    private func waitForToast(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element("dbSettings.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "no confirmation", file: file, line: line)
        let label = (toast.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? toast.label
        XCTAssertTrue(label.contains(text), "got \(label)", file: file, line: line)
    }

    func testHistoryLimitsAreSaved() {
        launchUnlocked()
        openDatabaseSettings()
        let increment = element("dbSettings.history.increment")
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        scrollIntoView(increment)
        XCTAssertEqual(text("dbSettings.history.items"), "10 versions")
        increment.click()
        increment.click()
        XCTAssertEqual(text("dbSettings.history.items"), "12 versions")
        element("dbSettings.history.save").click()
        waitForToast("History limits saved")

        element("dbSettings.close").click()
        openDatabaseSettings()
        scrollIntoView(element("dbSettings.history.items"))
        XCTAssertEqual(text("dbSettings.history.items"), "12 versions", "read back from the database")
    }

    func testTurningOffTheRecycleBinKeepsItsEntries() {
        launchUnlocked()
        selectEntry("Jira")
        element("detail.moveToTrash").click()
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("Jira")))

        openDatabaseSettings()
        let toggle = element("dbSettings.recycleBin.enabled")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        scrollIntoView(toggle)
        toggle.click()
        let keep = element("confirm.secondary")
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "turning off a bin with entries asks first")
        keep.click()
        waitForToast("kept as a group")
        element("dbSettings.close").click()

        selectSidebar("library.all")
        XCTAssertTrue(entryRow("Jira").waitForExistence(timeout: 5), "the former bin's entries are normal entries again")
        selectEntry("GitHub")
        element("detail.moveToTrash").click()
        XCTAssertEqual(element("confirm.confirm").label, "Delete Permanently", "deleting is permanent now")
    }

    func testChangeMasterKeyToAGeneratedKeyFile() throws {
        let keyFile = workDirectory.appendingPathComponent("Sample.keyx")
        app.launchEnvironment["KEEMAC_UI_TEST_KEY_FILE"] = keyFile.path
        launchUnlocked()
        openDatabaseSettings()
        let change = element("dbSettings.changeMasterKey")
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        scrollIntoView(change)
        change.click()

        let current = element("changeKey.current")
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertFalse(element("changeKey.submit").isEnabled, "nothing to change yet")
        element("changeKey.keyFile.generate").click()
        XCTAssertEqual(text("changeKey.fileName"), "Sample.keyx")

        current.click()
        current.typeText("wrong")
        element("changeKey.submit").click()
        XCTAssertTrue(element("changeKey.currentError").waitForExistence(timeout: 10), "a wrong current password is flagged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path), "nothing is written for a failed change")

        replaceText(of: current, with: Self.samplePassword)
        element("changeKey.submit").click()
        waitForToast("Sample.keyx created")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertEqual(text("dbSettings.keyFile"), "Sample.keyx")
        element("dbSettings.close").click()

        element("toolbar.lock").click()
        reopenMainWindow()
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10), "the remembered key file and the password open it")
    }
}
