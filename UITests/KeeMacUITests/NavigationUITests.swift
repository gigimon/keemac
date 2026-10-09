import XCTest

final class NavigationUITests: KeeMacUITestCase {
    func testGroupShowsItsEntries() {
        launchUnlocked()
        selectSidebar("group.Sample.Work")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(entryRow("Jira").exists)
        XCTAssertTrue(waitForDisappearance(entryRow("Mail")))
        XCTAssertEqual(text("list.count"), "2 entries")

        selectSidebar("library.all")
        XCTAssertTrue(entryRow("Mail").waitForExistence(timeout: 5))
    }

    func testSearchOperators() {
        launchUnlocked()
        let search = element("toolbar.search")

        search.click()
        search.typeText("user:neo")
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))
        XCTAssertTrue(entryRow("Mail").exists)
        XCTAssertFalse(entryRow("Jira").exists)

        replaceText(of: search, with: "is:otp")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(entryRow("Mail")))
        XCTAssertFalse(entryRow("Jira").exists)

        replaceText(of: search, with: "nothing-matches-this")
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))
        XCTAssertEqual(text("list.count"), "0 entries")
    }

    func testKeyboardShortcuts() {
        launchUnlocked()

        app.typeKey("f", modifierFlags: .command)
        app.typeText("mail")
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")), "⌘F focuses search")
        XCTAssertTrue(entryRow("Mail").exists)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(element("newEntry.title").waitForExistence(timeout: 5), "⌘N opens a new entry")
        element("newEntry.cancel").click()
        XCTAssertTrue(waitForDisappearance(element("newEntry.title")))

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(element("toolbar.search")), "⌘L locks")
    }

    func testCreateGroupFromSidebar() {
        launchUnlocked()
        element("sidebar.library.all").rightClick()
        app.menuItems["New Group"].click()

        let name = element("groupEditor.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Servers")
        element("groupEditor.submit").click()

        XCTAssertTrue(element("sidebar.group.Sample.Servers").waitForExistence(timeout: 5))
        selectSidebar("group.Sample.Servers")
        XCTAssertEqual(text("list.count"), "0 entries")
    }

    func testNewEntryGoesToSelectedGroup() {
        launchUnlocked()
        selectSidebar("group.Sample.Work")
        element("toolbar.newEntry").click()
        let title = element("newEntry.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Wiki")
        element("newEntry.create").click()

        XCTAssertTrue(entryRow("Wiki").waitForExistence(timeout: 5))
        XCTAssertEqual(text("list.count"), "3 entries")
    }
}
