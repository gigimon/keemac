import Foundation
@testable import UI
import XCTest

final class LocalizationTests: XCTestCase {
    func testRussianLookupAndPlurals() throws {
        let bundle = try XCTUnwrap(UIResources.localizationBundle(for: "ru"))
        XCTAssertEqual(bundle.localizedString(forKey: "Unlock", value: nil, table: nil), "Разблокировать")
        let format = bundle.localizedString(forKey: "%lld entries", value: nil, table: nil)
        let russian = Locale(identifier: "ru")
        XCTAssertEqual(String(format: format, locale: russian, 1), "1 запись")
        XCTAssertEqual(String(format: format, locale: russian, 3), "3 записи")
        XCTAssertEqual(String(format: format, locale: russian, 11), "11 записей")
        XCTAssertEqual(String(format: format, locale: russian, 21), "21 запись")

        let en = try XCTUnwrap(UIResources.localizationBundle(for: "en"))
        XCTAssertEqual(String.localizedStringWithFormat(en.localizedString(forKey: "%lld entries", value: nil, table: nil), 1), "1 entry")
    }

    /// A translation with other format specifiers than its key crashes or prints garbage at runtime.
    func testTranslationsKeepFormatSpecifiers() throws {
        let bundle = try XCTUnwrap(UIResources.localizationBundle(for: "ru"))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertGreaterThan(table.count, 700)
        for (key, value) in table {
            XCTAssertEqual(Self.specifiers(in: value), Self.specifiers(in: key), "\(key) → \(value)")
        }
    }

    func testRussianPluralsHaveAllForms() throws {
        let bundle = try XCTUnwrap(UIResources.localizationBundle(for: "ru"))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "stringsdict"))
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: [String: Any]])
        XCTAssertFalse(table.isEmpty)
        for (key, entry) in table {
            let forms = try XCTUnwrap(entry["n"] as? [String: String], key)
            for category in ["one", "few", "many", "other"] {
                XCTAssertNotNil(forms[category], "\(key) lacks \(category)")
            }
        }
    }

    /// Specifier types in order of their argument position (`%2$@` counts as the second argument).
    private static func specifiers(in format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|@|d|ld|f|lf)")
        let matches = regex.matches(in: format, range: NSRange(format.startIndex..., in: format))
        var sequential = 0
        return matches.map { match -> (Int, String) in
            let type = String(format[Range(match.range(at: 2), in: format)!])
            if let positionRange = Range(match.range(at: 1), in: format), let position = Int(format[positionRange]) {
                return (position, type)
            }
            sequential += 1
            return (sequential, type)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }
}
