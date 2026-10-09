import XCTest

final class EntryUITests: KeeMacUITestCase {
    func testEditEntryKeepsChangeAfterRelock() {
        launchUnlocked()
        selectEntry("GitHub")
        XCTAssertEqual(text("detail.username"), "octocat")

        element("detail.edit").click()
        let username = element("editor.username")
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        replaceText(of: username, with: "hubber")
        element("editor.save").click()

        XCTAssertTrue(element("detail.edit").waitForExistence(timeout: 5), "back to the detail view")
        XCTAssertEqual(text("detail.username"), "hubber")

        element("toolbar.lock").click()
        reopenMainWindow()
        unlock(with: Self.samplePassword)
        selectEntry("GitHub")
        XCTAssertEqual(text("detail.username"), "hubber")
    }

    func testCancelEditingChangesNothing() {
        launchUnlocked()
        selectEntry("Jira")
        element("detail.edit").click()
        replaceText(of: element("editor.username"), with: "someone-else")
        element("editor.cancel").click()
        XCTAssertTrue(element("detail.edit").waitForExistence(timeout: 5))
        XCTAssertEqual(text("detail.username"), "octocat@example.com")
    }

    func testRevealPassword() {
        launchUnlocked()
        selectEntry("Mail")
        XCTAssertFalse(element("detail.password").exists, "hidden until revealed")
        element("detail.revealPassword").click()
        XCTAssertEqual(text("detail.password"), "red-Pill-3")
    }

    func testCopyUsernameURLAndOneTimeCode() {
        launchUnlocked()
        selectEntry("GitHub")
        element("detail.copyUsername").click()
        waitForPasteboard("octocat")
        element("detail.copyURL").click()
        waitForPasteboard("https://github.com")

        element("detail.copyOTP").click()
        let deadline = Date().addingTimeInterval(5)
        var code = ""
        while Date() < deadline {
            code = Self.pasteboard.string(forType: .string) ?? ""
            if code.count == 6 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(code.count == 6 && code.allSatisfy(\.isNumber), "a six-digit TOTP code, got \(code)")
    }

    func testFavoritesListsStarredEntries() {
        launchUnlocked()
        selectEntry("GitHub")
        element("detail.favorite").click()

        selectSidebar("library.favorites")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(entryRow("Jira")))
        XCTAssertFalse(entryRow("Mail").exists)

        selectEntry("GitHub")
        element("detail.favorite").click()
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")), "unstarred entries leave Favorites")
    }

    func testTrashRestoreAndDeletePermanently() {
        launchUnlocked()
        selectEntry("Jira")
        element("detail.moveToTrash").click()
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("Jira")))

        selectSidebar("library.trash")
        selectEntry("Jira")
        element("detail.restore").click()
        XCTAssertTrue(waitForDisappearance(entryRow("Jira")), "restored entries leave the trash")
        selectSidebar("library.all")
        XCTAssertTrue(entryRow("Jira").waitForExistence(timeout: 5))

        selectEntry("Jira")
        element("detail.moveToTrash").click()
        confirm()
        selectSidebar("library.trash")
        selectEntry("Jira")
        element("detail.deletePermanently").click()
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("Jira")))
        selectSidebar("library.all")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertFalse(entryRow("Jira").exists)
    }

    func testUndoBringsBackTrashedEntry() {
        launchUnlocked()
        selectEntry("Mail")
        element("detail.moveToTrash").click()
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("Mail")))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(entryRow("Mail").waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForDisappearance(entryRow("Mail")), "redo trashes it again")
    }

    func testDuplicateEntry() {
        launchUnlocked()
        XCTAssertEqual(text("list.count"), "3 entries")
        selectEntry("GitHub")
        app.typeKey("d", modifierFlags: .command)
        let count = element("list.count")
        let four = expectation(for: NSPredicate(format: "value == '4 entries'"), evaluatedWith: count)
        wait(for: [four], timeout: 5)
    }
}
