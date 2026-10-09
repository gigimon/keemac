import XCTest

final class DatabaseUITests: KeeMacUITestCase {
    func testCreateDatabaseWithWizard() {
        app.launchEnvironment["KEEMAC_UI_TEST_NEW_DATABASE_DIRECTORY"] = workDirectory.path
        launch()
        element("unlock.databasePicker").click()
        let newDatabase = element("unlock.newDatabase")
        XCTAssertTrue(newDatabase.waitForExistence(timeout: 5))
        newDatabase.click()

        let name = element("newDatabase.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Family")
        element("newDatabase.next").click()

        let password = element("newDatabase.password")
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.click()
        password.typeText("family-Pass-1")
        let confirmation = element("newDatabase.confirmation")
        confirmation.click()
        confirmation.typeText("typo")
        element("newDatabase.next").click()
        XCTAssertTrue(element("newDatabase.error").waitForExistence(timeout: 5), "mismatched passwords are caught")

        replaceText(of: confirmation, with: "family-Pass-1")
        element("newDatabase.next").click()
        XCTAssertTrue(waitForDisappearance(password), "on to the encryption step")
        element("newDatabase.next").click()

        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 30), "the new database opens")
        XCTAssertEqual(text("list.count"), "0 entries")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDirectory.appendingPathComponent("Family.kdbx").path))

        element("toolbar.lock").click()
        reopenMainWindow()
        unlock(with: "family-Pass-1")
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10), "the new database opens with its password")
    }

    func testWizardRequiresName() {
        launch()
        element("unlock.databasePicker").click()
        element("unlock.newDatabase").click()
        let next = element("newDatabase.next")
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()
        XCTAssertTrue(element("newDatabase.error").waitForExistence(timeout: 5))

        element("newDatabase.back").click()
        XCTAssertTrue(element("unlock.password").waitForExistence(timeout: 5), "Cancel goes back to unlocking")
    }

    func testWrongThenRightPassword() {
        launch()
        unlock(with: "wrong")
        XCTAssertTrue(element("unlock.error").waitForExistence(timeout: 10))
        let field = element("unlock.password")
        replaceText(of: field, with: Self.samplePassword)
        field.typeText("\r")
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))
    }

    func testNoDatabaseSelected() {
        launch(selectingVault: false)
        XCTAssertTrue(element("unlock.databasePicker").waitForExistence(timeout: 10))
        XCTAssertFalse(element("unlock.unlock").isEnabled)
    }

    func testRecentDatabaseIsRememberedAcrossLaunches() {
        launchUnlocked()
        app.terminate()

        launch(selectingVault: false, keepDefaults: true)
        unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10), "the last database is selected again")
    }
}
