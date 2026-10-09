import Foundation
@testable import UI
import XCTest

final class PasswordStrengthTests: XCTestCase {
    func testEmptyPasswordHasNoStrength() {
        XCTAssertNil(PasswordStrength.evaluate(""))
        XCTAssertNil(PasswordStrength.weaknessReason(""))
    }

    func testWeaknessReasons() throws {
        let digits = try XCTUnwrap(PasswordStrength.evaluate("12345678901234567890"))
        XCTAssertEqual(digits.weakness, "Digits only")
        XCTAssertEqual(digits.level, .weak, "a weakness makes the password weak whatever its length")

        XCTAssertEqual(PasswordStrength.weaknessReason("Ab1!xy"), "Too short")
        XCTAssertEqual(PasswordStrength.weaknessReason("Correct-Horse-Admin-9"), "Common word")
        XCTAssertEqual(PasswordStrength.weaknessReason("MySUMMER2031!xyz"), "Common word", "common words match case-insensitively")
        XCTAssertNil(PasswordStrength.weaknessReason("k7mzp2xwv9"))
    }

    func testLevelsFollowEntropy() throws {
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("abcdefgh")).level, .weak)
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("k7mzp2xwv9")).level, .fair)
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("kQ7mZp2xWv9r")).level, .good)
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("Tr0ub4dor&3xyz")).level, .excellent)
    }

    func testEntropyEstimate() throws {
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("abcdefgh")).entropyBits, 8 * log2(26), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("abcd efgh")).entropyBits, 9 * log2(27), accuracy: 0.0001, "a space adds one character")
        XCTAssertEqual(try XCTUnwrap(PasswordStrength.evaluate("aB3!")).entropyBits, 4 * log2(95), accuracy: 0.0001)

        let repeated = try XCTUnwrap(PasswordStrength.evaluate("aaaaaaaaaaaa"))
        XCTAssertEqual(repeated.entropyBits, 12 * log2(26) * (0.5 + 1.0 / 12), accuracy: 0.0001, "low variety is penalized")
        XCTAssertEqual(repeated.level, .weak)
    }

    func testFraction() throws {
        XCTAssertEqual(PasswordStrength.forEntropy(0).fraction, 0.04, accuracy: 0.0001)
        XCTAssertEqual(PasswordStrength.forEntropy(64).fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PasswordStrength.forEntropy(500).fraction, 1)
        let weak = try XCTUnwrap(PasswordStrength.evaluate("12345678901234567890123456789012"))
        XCTAssertGreaterThan(weak.entropyBits / 128, 0.22)
        XCTAssertEqual(weak.fraction, 0.22, accuracy: 0.0001, "a known weakness caps the bar")
    }

    func testForEntropyThresholds() {
        XCTAssertEqual(PasswordStrength.forEntropy(39.9).level, .weak)
        XCTAssertEqual(PasswordStrength.forEntropy(40).level, .fair)
        XCTAssertEqual(PasswordStrength.forEntropy(60).level, .good)
        XCTAssertEqual(PasswordStrength.forEntropy(80).level, .excellent)
        XCTAssertNil(PasswordStrength.forEntropy(80).weakness)
    }

    func testLevelOrderAndLabels() {
        XCTAssertLessThan(PasswordStrength.Level.weak, .fair)
        XCTAssertLessThan(PasswordStrength.Level.good, .excellent)
        XCTAssertEqual([PasswordStrength.Level.weak, .fair, .good, .excellent].map(\.label), ["Weak", "Fair", "Good", "Excellent"])
    }
}

final class PasswordGeneratorOptionsTests: XCTestCase {
    func testSeparators() {
        var options = PasswordGeneratorOptions()
        let expected: [PasswordGeneratorOptions.Separator: String] = [.hyphen: "-", .space: " ", .dot: ".", .underscore: "_", .none: ""]
        for (separator, string) in expected {
            options.separator = separator
            XCTAssertEqual(options.separatorString, string)
        }
        options.separator = .custom
        options.customSeparator = "~~"
        XCTAssertEqual(options.separatorString, "~~")
        XCTAssertEqual(PasswordGeneratorOptions.Separator.allCases.map(\.title), ["Hyphen", "Space", "Dot", "Underscore", "None", "Custom"])
        XCTAssertEqual(PasswordGeneratorOptions.Mode.allCases.map(\.title), ["Password", "Passphrase"])
    }

    func testEnabledClassCount() {
        var options = PasswordGeneratorOptions()
        XCTAssertEqual(options.enabledClassCount, 4)
        options.symbols = false
        options.uppercase = false
        XCTAssertEqual(options.enabledClassCount, 2)
    }

    func testSummary() {
        var options = PasswordGeneratorOptions()
        XCTAssertEqual(PasswordGenerator.summary(options), "a–z, A–Z, 0–9, symbols")
        options.uppercase = false
        options.symbols = false
        options.avoidLookAlikes = true
        XCTAssertEqual(PasswordGenerator.summary(options), "a–z, 0–9 · no look-alikes")
        options.lowercase = false
        XCTAssertEqual(PasswordGenerator.summary(options), "Digits only (PIN)")

        var phrase = PasswordGeneratorOptions()
        phrase.mode = .passphrase
        XCTAssertEqual(PasswordGenerator.summary(phrase), "Hyphen")
        phrase.separator = .custom
        phrase.customSeparator = "+"
        phrase.capitalize = true
        phrase.addNumber = true
        XCTAssertEqual(PasswordGenerator.summary(phrase), "Custom “+” · Capitalized · With a number")
        phrase.customSeparator = ""
        phrase.capitalize = false
        phrase.addNumber = false
        XCTAssertEqual(PasswordGenerator.summary(phrase), "Custom")
    }

    func testEntropyEdgeCases() {
        var none = PasswordGeneratorOptions()
        none.lowercase = false
        none.uppercase = false
        none.digits = false
        none.symbols = false
        XCTAssertEqual(PasswordGenerator.entropyBits(none), 0)
        XCTAssertEqual(PasswordGenerator.generate(none), "", "nothing to pick from")
        XCTAssertFalse(PasswordGenerator.isPIN(none))

        var phrase = PasswordGeneratorOptions()
        phrase.mode = .passphrase
        phrase.words = 4
        phrase.addNumber = true
        XCTAssertEqual(PasswordGenerator.entropyBits(phrase), 4 * log2(7776) + log2(40), accuracy: 0.0001)
        XCTAssertFalse(PasswordGenerator.isPIN(phrase))

        var pinWithSymbols = PasswordGeneratorOptions()
        pinWithSymbols.lowercase = false
        pinWithSymbols.uppercase = false
        pinWithSymbols.symbolSet = "abc"
        XCTAssertTrue(PasswordGenerator.isPIN(pinWithSymbols), "symbols on but none usable still makes a PIN")
    }

    func testShortLengthStillHasEveryClass() {
        var options = PasswordGeneratorOptions()
        options.length = 2
        let password = PasswordGenerator.generate(options)
        XCTAssertEqual(password.count, 4)
        XCTAssertTrue(password.contains { $0.isLowercase })
        XCTAssertTrue(password.contains { $0.isUppercase })
        XCTAssertTrue(password.contains { $0.isNumber })

        var phrase = PasswordGeneratorOptions()
        phrase.mode = .passphrase
        phrase.words = 0
        phrase.separator = .space
        XCTAssertEqual(PasswordGenerator.generate(phrase).split(separator: " ").count, 1)
    }

    func testEncodingRoundTrip() throws {
        var options = PasswordGeneratorOptions()
        options.mode = .passphrase
        options.separator = .custom
        options.customSeparator = "|"
        options.capitalize = true
        options.length = 33
        let decoded = try JSONDecoder().decode(PasswordGeneratorOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        let damaged = try JSONDecoder().decode(PasswordGeneratorOptions.self, from: Data(#"{"mode":"pin","length":"long","digits":false}"#.utf8))
        XCTAssertEqual(damaged.mode, .password, "unknown values fall back to defaults")
        XCTAssertEqual(damaged.length, 20)
        XCTAssertFalse(damaged.digits)
    }
}

@MainActor
final class PasswordGeneratorSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "KeeMacGeneratorSettingsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let settings = PasswordGeneratorSettings(userDefaults: defaults)
        XCTAssertTrue(settings.rememberOptions)
        XCTAssertEqual(settings.defaultMode, .password)
        XCTAssertEqual(settings.defaultLength, 20)
        XCTAssertEqual(settings.defaultWords, 5)
        XCTAssertEqual(settings.options, PasswordGeneratorOptions())
        XCTAssertEqual(settings.generate().count, 20)
    }

    func testRememberedOptionsSurviveRestart() {
        let settings = PasswordGeneratorSettings(userDefaults: defaults)
        settings.options.length = 32
        settings.options.symbols = false
        let reloaded = PasswordGeneratorSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.options.length, 32)
        XCTAssertFalse(reloaded.options.symbols)
    }

    func testWithoutRememberingStartsFromDefaults() {
        let settings = PasswordGeneratorSettings(userDefaults: defaults)
        settings.options.length = 40
        settings.rememberOptions = false
        settings.defaultMode = .passphrase
        settings.defaultLength = 16
        settings.defaultWords = 7
        settings.options.length = 50

        let reloaded = PasswordGeneratorSettings(userDefaults: defaults)
        XCTAssertFalse(reloaded.rememberOptions)
        XCTAssertEqual(reloaded.defaultMode, .passphrase)
        XCTAssertEqual(reloaded.options.mode, .passphrase)
        XCTAssertEqual(reloaded.options.length, 16)
        XCTAssertEqual(reloaded.options.words, 7)

        reloaded.options.length = 24
        reloaded.rememberOptions = true
        XCTAssertEqual(PasswordGeneratorSettings(userDefaults: defaults).options.length, 24, "turning remembering on saves the current options")
    }
}
