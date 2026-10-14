import XCTest

/// Sample.kdbx: GitHub and Jira in Work, Mail in EMail.
final class MultiSelectUITests: KeeMacUITestCase {
    private func commandClick(_ title: String) {
        let row = entryRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no entry \(title)")
        XCUIElement.perform(withKeyModifiers: .command) {
            row.click()
        }
    }

    private func shiftClick(_ title: String) {
        let row = entryRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no entry \(title)")
        XCUIElement.perform(withKeyModifiers: .shift) {
            row.click()
        }
    }

    private func waitForText(_ identifier: String, _ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var current: String?
        while Date() < deadline {
            current = text(identifier)
            if current == expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("\(identifier) is \(current ?? "missing"), expected \(expected)", file: file, line: line)
    }

    /// GitHub and Jira, selected in the Work group.
    private func selectWorkEntries() {
        selectSidebar("group.Sample.Work")
        selectEntry("GitHub")
        shiftClick("Jira")
        waitForText("selection.count", "2 entries selected")
    }

    func testCommandShiftClickSelectAllAndEscape() {
        launchUnlocked()
        selectEntry("GitHub")
        commandClick("Mail")
        waitForText("selection.count", "2 entries selected")
        XCTAssertEqual(text("list.count"), "2 selected")
        XCTAssertEqual(text("selection.names"), "GitHub and Mail")

        commandClick("Mail")
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 5), "⌘-click again leaves one entry and its card")

        entryRow("GitHub").click()
        app.typeKey("a", modifierFlags: .command)
        waitForText("selection.count", "3 entries selected")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 5), "Esc goes back to one entry")

        selectWorkEntries()
        XCTAssertEqual(text("selection.names"), "GitHub and Jira")
    }

    func testMoveSelectionToGroupAndUndo() {
        launchUnlocked()
        selectWorkEntries()
        element("selection.move").click()
        let target = element("movePicker.group.EMail")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertFalse(element("movePicker.move").isEnabled, "a group must be picked first")
        target.click()
        element("movePicker.move").click()

        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")), "both left Work")
        XCTAssertFalse(entryRow("Jira").exists)
        selectSidebar("group.Sample.EMail")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(entryRow("Jira").exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")), "one undo moves both back")
        XCTAssertFalse(entryRow("Jira").exists)
    }

    func testDeleteSelectionThenRestoreFromTrash() {
        launchUnlocked()
        selectWorkEntries()
        element("selection.delete").click()
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))
        XCTAssertFalse(entryRow("Jira").exists)

        selectSidebar("library.trash")
        entryRow("GitHub").click()
        app.typeKey("a", modifierFlags: .command)
        waitForText("selection.count", "2 entries in Trash")
        element("selection.restore").click()
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))

        selectSidebar("group.Sample.Work")
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(entryRow("Jira").exists)
    }

    func testCommandDeleteAndUndoTheSelection() {
        launchUnlocked()
        selectWorkEntries()
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
        confirm()
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")))
        XCTAssertFalse(entryRow("Jira").exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(entryRow("GitHub").waitForExistence(timeout: 5), "one undo brings both back")
        XCTAssertTrue(entryRow("Jira").exists)
    }

    func testTagsPopoverAddsAndSetsMixedTags() {
        launchUnlocked()
        selectWorkEntries()
        element("selection.tags").click()
        let field = element("tagPicker.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("shared\r")
        XCTAssertEqual(element("tagPicker.tag.shared").value as? String, "All")
        XCTAssertTrue((text("tagPicker.changes") ?? "").hasPrefix("1 change"))
        element("tagPicker.done").click()

        selectSidebar("tag.shared")
        waitForText("list.count", "2 entries")

        // GitHub has the tag, Mail doesn't: mixed, then a click puts it on both.
        selectSidebar("library.all")
        selectEntry("GitHub")
        commandClick("Mail")
        waitForText("selection.count", "2 entries selected")
        element("selection.tags").click()
        let shared = element("tagPicker.tag.shared")
        XCTAssertTrue(shared.waitForExistence(timeout: 5))
        XCTAssertEqual(shared.value as? String, "Some")
        shared.click()
        XCTAssertEqual(shared.value as? String, "All")
        element("tagPicker.done").click()

        selectSidebar("tag.shared")
        waitForText("list.count", "3 entries")
    }

    func testAddSelectionToFavorites() {
        launchUnlocked()
        selectWorkEntries()
        element("selection.favorite").click()
        selectSidebar("library.favorites")
        waitForText("list.count", "2 entries")

        entryRow("GitHub").click()
        app.typeKey("a", modifierFlags: .command)
        waitForText("selection.count", "2 entries selected")
        element("selection.favorite").click()
        XCTAssertTrue(waitForDisappearance(entryRow("GitHub")), "removed from Favorites")
    }
}
