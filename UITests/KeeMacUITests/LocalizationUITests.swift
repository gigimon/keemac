import XCTest

final class LocalizationUITests: KeeMacUITestCase {
    func testRussianInterface() {
        launch(language: "ru")
        let unlock = element("unlock.unlock")
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        XCTAssertEqual(unlock.label, "Разблокировать")

        self.unlock(with: Self.samplePassword)
        XCTAssertTrue(element("toolbar.search").waitForExistence(timeout: 10))
        XCTAssertEqual(element("toolbar.search").placeholderValue, "Поиск")
        let count = text("list.count") ?? ""
        XCTAssertTrue(count.hasPrefix("3 "), count)
        XCTAssertFalse(count.contains("entries"), "the count is translated: \(count)")
    }
}
