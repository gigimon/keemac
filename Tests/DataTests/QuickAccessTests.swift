import AppKit
import Carbon.HIToolbox
@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class QuickAccessTests: XCTestCase {
    func testSettingsDefaultsAndPersistence() throws {
        let suiteName = "KeeMacQuickAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: defaults)
        XCTAssertTrue(settings.quickAccessEnabled)
        XCTAssertEqual(settings.quickAccessShortcut, .default)
        XCTAssertEqual(settings.quickAccessUnlockDuration, .untilAutoLock)

        let shortcut = QuickAccessShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue,
            keyName: "Space"
        )
        settings.quickAccessEnabled = false
        settings.quickAccessShortcut = shortcut
        settings.quickAccessUnlockDuration = .singleUse

        let reloaded = AppSettingsStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.quickAccessEnabled)
        XCTAssertEqual(reloaded.quickAccessShortcut, shortcut)
        XCTAssertEqual(reloaded.quickAccessUnlockDuration, .singleUse)
    }

    func testShortcutDisplayAndMenuEquivalent() {
        XCTAssertEqual(QuickAccessShortcut.default.displayString, "⌥⌘K")
        let shortcut = QuickAccessShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: NSEvent.ModifierFlags([.command, .shift, .control]).rawValue,
            keyName: "Space"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⇧⌘Space")
        XCTAssertEqual(shortcut.keyboardShortcut?.key, .space)
        XCTAssertNil(QuickAccessShortcut(keyCode: UInt32(kVK_F5), modifiers: 0, keyName: "F5").keyboardShortcut)
    }

    func testUnlockDurationRelockDelay() {
        XCTAssertEqual(QuickAccessUnlockDuration.singleUse.relockDelay, 0)
        XCTAssertEqual(QuickAccessUnlockDuration.fiveMinutes.relockDelay, 300)
        XCTAssertNil(QuickAccessUnlockDuration.untilAutoLock.relockDelay)
    }

    func testResultsSuggestFrontmostAppAndSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Quick.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(fileURL: url, name: "Quick", masterPassword: "pw", keyDerivation: kdf))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "me", password: "one"))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Team", password: "two", url: "https://slack.com"))
        _ = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank", password: "three"))

        let suiteName = "KeeMacQuickAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        let model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: url)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)

        let actions = QuickAccessModel.Actions(close: {}, didUnlock: {}, refocus: {}, showInMainWindow: { _ in }, autoType: { _ in })
        let quickAccess = QuickAccessModel(viewModel: model, suggestionAppName: "Slack", actions: actions)
        XCTAssertTrue(quickAccess.hasAppSuggestions)
        XCTAssertEqual(quickAccess.suggestionCount, 1)
        XCTAssertEqual(quickAccess.results.map(\.title), ["Team", "Bank", "Mail"], "suggestions for the app in front, then every entry by title")

        quickAccess.query = "ma"
        XCTAssertEqual(quickAccess.results.map(\.title), ["Mail"])
        XCTAssertEqual(quickAccess.selectedEntry.flatMap { quickAccess.value(of: .username, in: $0) }, "me")

        quickAccess.query = "-mail"
        XCTAssertEqual(Set(quickAccess.results.map(\.title)), ["Team", "Bank"], "search operators work as in the main window")

        await model.lockForQuit()
    }
}
