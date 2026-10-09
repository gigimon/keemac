import Foundation
@testable import UI
import XCTest

final class PasswordGeneratorTests: XCTestCase {
    func testWordListIsTheFullEFFList() {
        XCTAssertEqual(PasswordGenerator.words.count, 7776)
        XCTAssertEqual(Set(PasswordGenerator.words).count, 7776)
        XCTAssertEqual(PasswordGenerator.words.first, "abacus")
    }

    func testPasswordHasLengthAndEveryEnabledClass() {
        var options = PasswordGeneratorOptions()
        options.length = 12
        for _ in 0..<200 {
            let password = PasswordGenerator.generate(options)
            XCTAssertEqual(password.count, 12)
            XCTAssertTrue(password.contains { $0.isLowercase })
            XCTAssertTrue(password.contains { $0.isUppercase })
            XCTAssertTrue(password.contains { $0.isNumber })
            XCTAssertTrue(password.contains { PasswordGeneratorOptions.defaultSymbols.contains($0) })
        }
    }

    func testPINAndLookAlikesAndCustomSymbols() {
        var pin = PasswordGeneratorOptions()
        pin.lowercase = false
        pin.uppercase = false
        pin.symbols = false
        pin.length = 8
        XCTAssertTrue(PasswordGenerator.isPIN(pin))
        XCTAssertTrue(PasswordGenerator.generate(pin).allSatisfy(\.isNumber))
        XCTAssertEqual(PasswordGenerator.entropyBits(pin), 8 * log2(10), accuracy: 0.001)

        var avoid = PasswordGeneratorOptions()
        avoid.avoidLookAlikes = true
        avoid.symbolSet = "|!"
        avoid.length = 64
        for _ in 0..<50 {
            XCTAssertTrue(PasswordGenerator.generate(avoid).allSatisfy { !"0Oo1lI|".contains($0) })
        }
        XCTAssertEqual(PasswordGenerator.effectiveSymbols(avoid), ["!"])

        var lettersOnly = PasswordGeneratorOptions()
        lettersOnly.symbolSet = "abc 12"
        XCTAssertTrue(PasswordGenerator.effectiveSymbols(lettersOnly).isEmpty)
        XCTAssertEqual(PasswordGenerator.pools(lettersOnly).count, 3)
    }

    func testPassphrase() {
        var options = PasswordGeneratorOptions()
        options.mode = .passphrase
        options.words = 5
        let phrase = PasswordGenerator.generate(options)
        let words = phrase.split(separator: "-")
        XCTAssertEqual(words.count, 5)
        XCTAssertTrue(words.allSatisfy { PasswordGenerator.words.contains(String($0)) })
        XCTAssertEqual(PasswordGenerator.entropyBits(options), 5 * log2(7776), accuracy: 0.001)

        options.separator = .custom
        options.customSeparator = "+"
        options.capitalize = true
        options.addNumber = true
        let fancy = PasswordGenerator.generate(options)
        let parts = fancy.split(separator: "+")
        XCTAssertEqual(parts.count, 5)
        XCTAssertTrue(parts.allSatisfy { $0.first?.isUppercase == true })
        XCTAssertEqual(fancy.filter(\.isNumber).count, 1)
    }

    func testOldSavedOptionsDecodeWithDefaults() throws {
        let decoded = try JSONDecoder().decode(PasswordGeneratorOptions.self, from: Data(#"{"mode":"passphrase","words":7}"#.utf8))
        XCTAssertEqual(decoded.mode, .passphrase)
        XCTAssertEqual(decoded.words, 7)
        XCTAssertEqual(decoded.length, 20)
        XCTAssertEqual(decoded.symbolSet, PasswordGeneratorOptions.defaultSymbols)
    }
}
