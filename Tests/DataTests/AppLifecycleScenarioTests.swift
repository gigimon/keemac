@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AppLifecycleScenarioTests: XCTestCase {
    func testCreateLockUnlockAndRelaunch() async throws {
        let app = try AppScenario(self)

        try await app.createVault()
        XCTAssertTrue(app.model.loadState.isUnlocked)
        XCTAssertEqual(app.model.selectedVaultURL, app.url)
        XCTAssertEqual(app.model.recentVaults.map(\.vaultURL.standardizedFileURL), [app.url.standardizedFileURL])
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "me", password: "secret"))

        await app.lock()
        XCTAssertEqual(app.model.loadState, .locked(L("Vault was locked.")))
        XCTAssertFalse(app.model.hasPendingLock)

        await app.model.unlock(masterPassword: "wrong")
        guard case .failed = app.model.loadState else {
            return XCTFail("a wrong password must fail, got \(app.model.loadState)")
        }

        await app.model.unlock(masterPassword: app.password)
        XCTAssertEqual(try app.entry(titled: "Mail").password, "secret")

        await app.relaunch()
        XCTAssertEqual(app.model.loadState, .idle)
        XCTAssertEqual(app.model.selectedVaultURL?.standardizedFileURL, app.url.standardizedFileURL, "the last database is selected after relaunch")
        XCTAssertEqual(app.model.recentVaults.count, 1)
        await app.model.unlock(masterPassword: app.password)
        XCTAssertEqual(try app.entry(titled: "Mail").username, "me")
    }

    func testLockReasonsAndNotification() async throws {
        let app = try AppScenario(self)
        try await app.createVault()

        var states: [Bool] = []
        let observer = NotificationCenter.default.addObserver(forName: AppCommand.vaultLockStateChanged, object: app.model, queue: nil) { note in
            states.append(note.userInfo?[AppCommand.vaultUnlockedUserInfoKey] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await app.lock(reason: .idleTimeout)
        XCTAssertEqual(app.model.loadState, .locked(L("Vault was locked after inactivity timeout.")))
        app.model.lockVault(reason: .screenLocked)
        XCTAssertEqual(app.model.loadState, .locked(L("Vault was locked after inactivity timeout.")), "locking a locked database changes nothing")

        await app.model.unlock(masterPassword: app.password)
        await app.lock(reason: .systemSleep)
        XCTAssertEqual(app.model.loadState, .locked(L("Vault was locked because the system is going to sleep.")))
        XCTAssertEqual(states, [false, true, false])
    }

    func testEditingWhileLockedFails() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        await app.lock()

        do {
            try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Nope"))
            XCTFail("editing a locked database must throw")
        } catch {}
        do {
            try await app.model.changeMasterPassword(newPassword: "new")
            XCTFail("changing the key of a locked database must throw")
        } catch {}
        let disk = try await app.readFromDisk()
        XCTAssertTrue(disk.entries.isEmpty)
    }

    func testIdleTimeoutLocks() async throws {
        let app = try AppScenario(self)
        try await app.createVault()

        app.model.setIdleLockTimeoutForSelectedVault(1)
        XCTAssertEqual(app.model.idleLockTimeoutForSelectedVault, 5, "timeouts under five seconds are raised to five")
        await waitUntil(timeout: .seconds(8), "the database locks after the idle timeout") {
            !app.model.loadState.isUnlocked
        }
        XCTAssertEqual(app.model.loadState, .locked(L("Vault was locked after inactivity timeout.")))
    }

    func testNoIdleLockWhenTimeoutIsOff() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        app.model.setIdleLockTimeoutForSelectedVault(0)
        XCTAssertEqual(app.model.idleLockTimeoutForSelectedVault, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.model.loadState.isUnlocked)
    }

    func testChangeMasterPassword() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        try await app.model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank"))

        try await app.model.changeMasterPassword(newPassword: "n3w")
        let newKeyWorks = await app.model.verifyMasterKey(password: "n3w")
        let oldKeyWorks = await app.model.verifyMasterKey(password: app.password)
        XCTAssertTrue(newKeyWorks)
        XCTAssertFalse(oldKeyWorks)
        await app.lock()

        await app.model.unlock(masterPassword: app.password)
        XCTAssertFalse(app.model.loadState.isUnlocked, "the old password no longer opens the database")
        await app.model.unlock(masterPassword: "n3w")
        XCTAssertNoThrow(try app.entry(titled: "Bank"))
        let disk = try await app.readFromDisk(password: "n3w")
        XCTAssertEqual(disk.entries.map(\.title), ["Bank"])
    }

    func testDatabaseSettingsAreSaved() async throws {
        let app = try AppScenario(self)
        try await app.createVault(name: "Before")

        var settings = try await app.model.loadDatabaseSettings()
        XCTAssertEqual(settings.name, "Before")
        settings.name = "After"
        settings.details = "Family passwords"
        try await app.model.updateDatabaseSettings(settings)

        await app.relaunch()
        await app.model.unlock(masterPassword: app.password)
        let reloaded = try await app.model.loadDatabaseSettings()
        XCTAssertEqual(reloaded.name, "After")
        XCTAssertEqual(reloaded.details, "Family passwords")
    }

    func testRecentVaultsKeepThreeNewestFirst() async throws {
        let first = try AppScenario(self, fileName: "One.kdbx")
        try await first.createVault()
        let model = first.model

        var others: [URL] = []
        for name in ["Two", "Three", "Four"] {
            let url = first.directory.appendingPathComponent("\(name).kdbx")
            first.settings.setTouchIDEnabled(false, for: url)
            first.settings.setExpiryNotificationsEnabled(false, for: url)
            try await model.createVault(options: VaultCreationOptions(fileURL: url, name: name, masterPassword: "pw", keyDerivation: AppScenario.fastKDF))
            others.append(url.standardizedFileURL)
        }
        XCTAssertEqual(model.recentVaults.map(\.vaultURL.standardizedFileURL), others.reversed())

        let two = try XCTUnwrap(model.recentVaults.last)
        model.removeRecentVault(two)
        XCTAssertEqual(model.recentVaults.map(\.title), ["Four.kdbx", "Three.kdbx"])

        model.selectRecentVault(try XCTUnwrap(model.recentVaults.last))
        XCTAssertEqual(model.loadState, .idle, "picking another database locks the open one")
        XCTAssertEqual(model.selectedVaultURL?.lastPathComponent, "Three.kdbx")
    }

    func testClearSelectionForgetsDatabase() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        await app.lock()

        app.model.clearVaultSelection()
        XCTAssertNil(app.model.selectedVaultURL)
        await app.model.unlock(masterPassword: app.password)
        XCTAssertEqual(app.model.loadState, .failed(L("Select a .kdbx file first.")))

        await app.relaunch()
        XCTAssertNil(app.model.selectedVaultURL)
    }

    func testDeletedFileIsNotRestoredAfterRelaunch() async throws {
        let app = try AppScenario(self)
        try await app.createVault()
        await app.lock()
        try FileManager.default.removeItem(at: app.url)

        await app.relaunch()
        XCTAssertNil(app.model.selectedVaultURL)
        XCTAssertTrue(app.model.recentVaults.isEmpty)
    }
}
