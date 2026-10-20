import Foundation
@testable import UI
import XCTest

final class LegacySettingsMigrationTests: XCTestCase {
    private var legacyName = ""
    private var appName = ""

    override func setUp() {
        legacyName = "KeeMacLegacyTests.\(UUID().uuidString)"
        appName = "KeeMacAppTests.\(UUID().uuidString)"
        UserDefaults().setPersistentDomain(
            ["keemac.settings.browserIntegration.enabled": true, "keemac.entries.favorites.v1": Data([1, 2]), "NSWindow Frame": "1 2 3 4"],
            forName: legacyName
        )
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: legacyName)
        UserDefaults().removePersistentDomain(forName: appName)
    }

    private func defaults(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    func testFreshInstallCopiesKeeMacSettingsOnce() {
        let target = defaults(appName)
        LegacySettingsMigration.migrateIfNeeded(into: target, bundleIdentifier: appName, legacyDomain: legacyName)
        XCTAssertTrue(target.bool(forKey: "keemac.settings.browserIntegration.enabled"))
        XCTAssertEqual(target.data(forKey: "keemac.entries.favorites.v1"), Data([1, 2]))
        XCTAssertNil(target.object(forKey: "NSWindow Frame"), "only KeeMac's own keys")

        target.set(false, forKey: "keemac.settings.browserIntegration.enabled")
        LegacySettingsMigration.migrateIfNeeded(into: target, bundleIdentifier: appName, legacyDomain: legacyName)
        XCTAssertFalse(target.bool(forKey: "keemac.settings.browserIntegration.enabled"), "it runs once")
    }

    func testExistingSettingsAreKept() {
        let target = defaults(appName)
        target.set(false, forKey: "keemac.settings.browserIntegration.enabled")
        LegacySettingsMigration.migrateIfNeeded(into: target, bundleIdentifier: appName, legacyDomain: legacyName)
        XCTAssertFalse(target.bool(forKey: "keemac.settings.browserIntegration.enabled"))
        XCTAssertNil(target.data(forKey: "keemac.entries.favorites.v1"))
    }

    func testDevAndUITestBuildsStartClean() {
        for suffix in [".dev", ".uitests"] {
            let name = appName + suffix
            let target = defaults(name)
            LegacySettingsMigration.migrateIfNeeded(into: target, bundleIdentifier: name, legacyDomain: legacyName)
            XCTAssertNil(target.object(forKey: "keemac.settings.browserIntegration.enabled"), suffix)
            UserDefaults().removePersistentDomain(forName: name)
        }
    }
}
