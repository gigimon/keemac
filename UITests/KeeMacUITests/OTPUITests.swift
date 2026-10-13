import XCTest

final class OTPUITests: KeeMacUITestCase {
    func testHOTPCodeMovesOnOnlyWithNextCode() {
        launchUnlocked()
        selectEntry("Jira")
        element("detail.edit").click()
        let secret = element("editor.otpSecret")
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        replaceText(of: secret, with: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        element("editor.otpOptions").click()
        let hotp = element("editor.otpKind.hotp")
        XCTAssertTrue(hotp.waitForExistence(timeout: 5))
        hotp.click()
        let counter = element("editor.otpCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "HOTP has a counter instead of a period")
        // Tab commits the number field.
        replaceText(of: counter, with: "5\t")
        element("editor.save").click()

        XCTAssertTrue(element("detail.edit").waitForExistence(timeout: 5))
        XCTAssertEqual(text("detail.otpCounter"), "Counter 5")
        XCTAssertEqual(text("detail.otpCode"), "254 676", "RFC 4226 code for counter 5")

        element("detail.copyOTP").click()
        waitForPasteboard("254676")
        XCTAssertEqual(text("detail.otpCounter"), "Counter 5", "copying doesn't use the code up")

        element("detail.nextOTP").click()
        XCTAssertTrue(app.staticTexts["Counter 6"].waitForExistence(timeout: 5))
        XCTAssertEqual(text("detail.otpCode"), "287 922")

        element("toolbar.lock").click()
        reopenMainWindow()
        unlock(with: Self.samplePassword)
        selectEntry("Jira")
        XCTAssertEqual(text("detail.otpCounter"), "Counter 6", "the counter was saved")
    }

    func testSteamEntryShowsFiveCharacterCode() {
        launchUnlocked()
        selectEntry("Mail")
        element("detail.edit").click()
        let secret = element("editor.otpSecret")
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        replaceText(of: secret, with: "JBSWY3DPEHPK3PXP")
        element("editor.otpOptions").click()
        let steam = element("editor.otpKind.steam")
        XCTAssertTrue(steam.waitForExistence(timeout: 5))
        steam.click()
        element("editor.save").click()

        XCTAssertTrue(element("detail.edit").waitForExistence(timeout: 5))
        let code = text("detail.otpCode") ?? ""
        XCTAssertEqual(code.count, 5, "got \(code)")
        XCTAssertTrue(code.allSatisfy { "23456789BCDFGHJKMNPQRTVWXY".contains($0) }, "got \(code)")
        XCTAssertFalse(element("detail.otpCounter").exists, "Steam codes run on time")
    }
}
