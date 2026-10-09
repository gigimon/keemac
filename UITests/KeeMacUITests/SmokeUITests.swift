import XCTest

final class SmokeUITests: KeeMacUITestCase {
    func testWrongPasswordShowsError() {
        launch()
        unlock(with: "not the password")
        XCTAssertTrue(element("unlock.error").waitForExistence(timeout: 10))
        XCTAssertFalse(element("toolbar.search").exists)
    }

    func testUnlockListsEntriesAndSearchFilters() {
        launchUnlocked()
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(entryRow("Jira").exists)
        XCTAssertTrue(entryRow("Mail").exists)

        let search = element("toolbar.search")
        search.click()
        search.typeText("jira")
        XCTAssertTrue(entryRow("Jira").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))
        XCTAssertFalse(entryRow("Mail").exists)
    }

    func testCopyPasswordFromDetail() {
        launchUnlocked()
        entryRow("GitHub").click()
        let copy = element("detail.copyPassword")
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        waitForPasteboard("gh-Secret-1")
    }

    func testCreateEntryAndFindItAfterRelock() {
        launchUnlocked()
        element("toolbar.newEntry").click()

        let title = element("newEntry.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Router")
        let username = element("newEntry.username")
        username.click()
        username.typeText("admin")
        replaceText(of: element("newEntry.password"), with: "r0uter-Pass")
        element("newEntry.create").click()

        XCTAssertTrue(entryRow("Router").waitForExistence(timeout: 5))
        XCTAssertEqual(element("detail.title").value as? String, "Router")
        element("detail.copyPassword").click()
        waitForPasteboard("r0uter-Pass")

        element("toolbar.lock").click()
        reopenMainWindow()
        unlock(with: Self.samplePassword)
        XCTAssertTrue(entryRow("Router").waitForExistence(timeout: 10), "the new entry was saved to the file")
    }

    func testLockHidesWindowAndUnlocksAgain() {
        launchUnlocked()
        element("toolbar.lock").click()
        XCTAssertTrue(waitForDisappearance(element("toolbar.search")))

        reopenMainWindow()
        XCTAssertFalse(element("toolbar.search").exists)
        unlock(with: Self.samplePassword)
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 10))
    }
}
