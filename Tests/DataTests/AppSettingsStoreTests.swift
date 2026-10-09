import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let vaultURL = URL(fileURLWithPath: "/tmp/KeeMacSettingsTests/Personal.kdbx")
    private let otherURL = URL(fileURLWithPath: "/tmp/KeeMacSettingsTests/Work.kdbx")

    override func setUp() async throws {
        suiteName = "KeeMacAppSettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(userDefaults: defaults)
    }

    func testGlobalDefaults() {
        let settings = makeStore()
        XCTAssertEqual(settings.clipboardAutoClearTimeoutSeconds, 30)
        XCTAssertEqual(settings.defaultIdleLockTimeoutSeconds, 300)
        XCTAssertTrue(settings.showDockIcon)
        XCTAssertFalse(settings.startMinimized)
        XCTAssertFalse(settings.includeSubgroupEntries)
        XCTAssertTrue(settings.lookForConflictCopies)
        XCTAssertTrue(settings.lockOnScreenLock)
        XCTAssertFalse(settings.browserIntegrationEnabled)
        XCTAssertFalse(settings.browserAlwaysAllowAccess)
        XCTAssertFalse(settings.browserAllowExpired)
        XCTAssertFalse(settings.browserAlwaysAllowUpdate)
        XCTAssertTrue(settings.sshAgentEnabled)
        XCTAssertTrue(settings.sshPickKeysByHost)
        XCTAssertTrue(settings.sshLearnHosts)
        XCTAssertEqual(settings.sshDefaultConfirmation, .oncePerUnlock)
        XCTAssertTrue(settings.sshAskForwarded)
    }

    func testGlobalSettingsPersist() {
        let settings = makeStore()
        settings.clipboardAutoClearTimeoutSeconds = 90
        settings.defaultIdleLockTimeoutSeconds = 600
        settings.showDockIcon = false
        settings.startMinimized = true
        settings.includeSubgroupEntries = true
        settings.lookForConflictCopies = false
        settings.lockOnScreenLock = false
        settings.browserIntegrationEnabled = true
        settings.browserAlwaysAllowAccess = true
        settings.browserAllowExpired = true
        settings.browserAlwaysAllowUpdate = true
        settings.sshAgentEnabled = false
        settings.sshPickKeysByHost = false
        settings.sshLearnHosts = false
        let confirmation = VaultSSHConfirmation.allCases.first { $0 != .oncePerUnlock }!
        settings.sshDefaultConfirmation = confirmation
        settings.sshAskForwarded = false

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.clipboardAutoClearTimeoutSeconds, 90)
        XCTAssertEqual(reloaded.defaultIdleLockTimeoutSeconds, 600)
        XCTAssertFalse(reloaded.showDockIcon)
        XCTAssertTrue(reloaded.startMinimized)
        XCTAssertTrue(reloaded.includeSubgroupEntries)
        XCTAssertFalse(reloaded.lookForConflictCopies)
        XCTAssertFalse(reloaded.lockOnScreenLock)
        XCTAssertTrue(reloaded.browserIntegrationEnabled)
        XCTAssertTrue(reloaded.browserAlwaysAllowAccess)
        XCTAssertTrue(reloaded.browserAllowExpired)
        XCTAssertTrue(reloaded.browserAlwaysAllowUpdate)
        XCTAssertFalse(reloaded.sshAgentEnabled)
        XCTAssertFalse(reloaded.sshPickKeysByHost)
        XCTAssertFalse(reloaded.sshLearnHosts)
        XCTAssertEqual(reloaded.sshDefaultConfirmation, confirmation)
        XCTAssertFalse(reloaded.sshAskForwarded)
    }

    func testTimeoutsAreNormalized() {
        let settings = makeStore()
        settings.clipboardAutoClearTimeoutSeconds = 2
        XCTAssertEqual(settings.clipboardAutoClearTimeoutSeconds, 5, "anything below five seconds becomes five")
        settings.clipboardAutoClearTimeoutSeconds = -10
        XCTAssertEqual(settings.clipboardAutoClearTimeoutSeconds, 0, "zero or less turns the timeout off")
        settings.defaultIdleLockTimeoutSeconds = 1
        XCTAssertEqual(settings.defaultIdleLockTimeoutSeconds, 5)
        XCTAssertEqual(makeStore().clipboardAutoClearTimeoutSeconds, 0)
        XCTAssertEqual(makeStore().defaultIdleLockTimeoutSeconds, 5)

        defaults.set(3.0, forKey: "keemac.settings.clipboard.timeout.seconds")
        XCTAssertEqual(makeStore().clipboardAutoClearTimeoutSeconds, 5, "stored values are normalized on load")
    }

    func testDamagedStoredValuesFallBackToDefaults() {
        defaults.set("not a confirmation", forKey: "keemac.settings.sshAgent.defaultConfirmation")
        defaults.set(Data("{".utf8), forKey: "keemac.settings.quickAccess.shortcut")
        defaults.set(99, forKey: "keemac.settings.quickAccess.unlockDuration")
        defaults.set(Data("[]".utf8), forKey: "keemac.settings.vault.pervault.data")
        let settings = makeStore()
        XCTAssertEqual(settings.sshDefaultConfirmation, .oncePerUnlock)
        XCTAssertEqual(settings.quickAccessShortcut, .default)
        XCTAssertEqual(settings.quickAccessUnlockDuration, .untilAutoLock)
        XCTAssertTrue(settings.isTouchIDEnabled(for: vaultURL))
    }

    func testPerVaultDefaults() {
        let settings = makeStore()
        for url in [vaultURL, nil] {
            XCTAssertTrue(settings.isTouchIDEnabled(for: url))
            XCTAssertEqual(settings.idleLockTimeoutSeconds(for: url), 300)
            XCTAssertNil(settings.sidebarSelectionID(for: url))
            XCTAssertEqual(settings.expandedGroupPaths(for: url), [])
            XCTAssertEqual(settings.syncMode(for: url), .automatic)
            XCTAssertTrue(settings.expiryNotificationsEnabled(for: url))
            XCTAssertEqual(settings.expiryWarnDays(for: url), 7)
            XCTAssertTrue(settings.expiryBannerEnabled(for: url))
            XCTAssertEqual(settings.additionalDatabases(for: url), [])
        }
        XCTAssertEqual(AppSettingsStore.expiryWarnDayOptions, [7, 14, 30])
    }

    func testPerVaultSettingsPersistSeparately() {
        let settings = makeStore()
        let additional = StoredAdditionalDatabase(key: "a1", vaultBookmark: Data([1, 2]), keyFileBookmark: Data([3]), lastKnownPath: "/tmp/Backup.kdbx")
        settings.setTouchIDEnabled(false, for: vaultURL)
        settings.setIdleLockTimeoutSeconds(120, for: vaultURL)
        settings.setSidebarSelectionID("group:Root.Work", for: vaultURL)
        settings.setExpandedGroupPaths(["Root.Work", "Root"], for: vaultURL)
        settings.setSyncMode(.ask, for: vaultURL)
        settings.setExpiryNotificationsEnabled(false, for: vaultURL)
        settings.setExpiryWarnDays(30, for: vaultURL)
        settings.setExpiryBannerEnabled(false, for: vaultURL)
        settings.setAdditionalDatabases([additional], for: vaultURL)

        let reloaded = makeStore()
        let sameFile = URL(fileURLWithPath: "/tmp/KeeMacSettingsTests/./Sub/../Personal.kdbx")
        XCTAssertFalse(reloaded.isTouchIDEnabled(for: sameFile), "paths are standardized")
        XCTAssertEqual(reloaded.idleLockTimeoutSeconds(for: vaultURL), 120)
        XCTAssertEqual(reloaded.sidebarSelectionID(for: vaultURL), "group:Root.Work")
        XCTAssertEqual(reloaded.expandedGroupPaths(for: vaultURL), ["Root", "Root.Work"])
        XCTAssertEqual(reloaded.syncMode(for: vaultURL), .ask)
        XCTAssertFalse(reloaded.expiryNotificationsEnabled(for: vaultURL))
        XCTAssertEqual(reloaded.expiryWarnDays(for: vaultURL), 30)
        XCTAssertFalse(reloaded.expiryBannerEnabled(for: vaultURL))
        XCTAssertEqual(reloaded.additionalDatabases(for: vaultURL), [additional])

        XCTAssertTrue(reloaded.isTouchIDEnabled(for: otherURL))
        XCTAssertEqual(reloaded.syncMode(for: otherURL), .automatic)
        XCTAssertEqual(reloaded.additionalDatabases(for: otherURL), [])

        reloaded.setAdditionalDatabases([], for: vaultURL)
        reloaded.setSidebarSelectionID(nil, for: vaultURL)
        XCTAssertEqual(makeStore().additionalDatabases(for: vaultURL), [])
        XCTAssertNil(makeStore().sidebarSelectionID(for: vaultURL))
    }

    func testNewVaultEntryUsesCurrentDefaultTimeout() {
        let settings = makeStore()
        settings.defaultIdleLockTimeoutSeconds = 900
        settings.setTouchIDEnabled(false, for: vaultURL)
        XCTAssertEqual(settings.idleLockTimeoutSeconds(for: vaultURL), 900)
        XCTAssertEqual(settings.idleLockTimeoutSeconds(for: otherURL), 900)

        settings.setIdleLockTimeoutSeconds(1, for: otherURL)
        XCTAssertEqual(settings.idleLockTimeoutSeconds(for: otherURL), 5)
        settings.setIdleLockTimeoutSeconds(0, for: otherURL)
        XCTAssertEqual(settings.idleLockTimeoutSeconds(for: otherURL), 0)

        settings.setIdleLockTimeoutSeconds(45, for: nil)
        XCTAssertEqual(settings.defaultIdleLockTimeoutSeconds, 45, "without a database the default changes")
    }

    func testSettersWithoutVaultDoNothing() {
        let settings = makeStore()
        settings.setTouchIDEnabled(false, for: nil)
        settings.setSidebarSelectionID("x", for: nil)
        settings.setExpandedGroupPaths(["Root"], for: nil)
        settings.setSyncMode(.off, for: nil)
        settings.setExpiryWarnDays(30, for: nil)
        settings.setAdditionalDatabases([StoredAdditionalDatabase(key: "k", vaultBookmark: Data(), keyFileBookmark: nil, lastKnownPath: "")], for: nil)
        XCTAssertNil(defaults.data(forKey: "keemac.settings.vault.pervault.data"))
        XCTAssertTrue(settings.isTouchIDEnabled(for: nil))
        XCTAssertEqual(settings.syncMode(for: nil), .automatic)
    }

    func testOlderPerVaultDataLoads() throws {
        let path = vaultURL.standardizedFileURL.path
        let json = #"{"\#(path)":{"touchIDEnabled":false,"syncMode":"sometimes","additionalDatabases":"broken"}}"#
        defaults.set(Data(json.utf8), forKey: "keemac.settings.vault.pervault.data")
        let settings = makeStore()
        XCTAssertFalse(settings.isTouchIDEnabled(for: vaultURL))
        XCTAssertEqual(settings.idleLockTimeoutSeconds(for: vaultURL), 300)
        XCTAssertEqual(settings.syncMode(for: vaultURL), .automatic, "an unknown sync mode is ignored")
        XCTAssertEqual(settings.additionalDatabases(for: vaultURL), [])
        XCTAssertEqual(settings.expiryWarnDays(for: vaultURL), 7)
    }

    func testSyncModeTitles() {
        XCTAssertEqual(VaultSyncMode.allCases.map(\.title), ["Merge automatically", "Ask", "Don’t watch"])
    }
}
