@testable import Data
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
final class AppTouchIDScenarioTests: XCTestCase {
    func testPasswordUnlockStoresCredentialForTouchID() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        XCTAssertFalse(app.biometrics.hasSavedMasterPassword(for: app.url), "creating a database doesn't store its password")
        await app.lock()
        XCTAssertFalse(app.model.showBiometricUnlockScreen)

        await app.model.unlock(masterPassword: app.password)
        XCTAssertTrue(app.biometrics.hasSavedMasterPassword(for: app.url))
        await app.lock()
        XCTAssertTrue(app.model.showBiometricUnlockScreen)

        await app.model.unlockWithBiometrics()
        XCTAssertTrue(app.model.loadState.isUnlocked)
        XCTAssertEqual(app.biometrics.loadCount, 1)

        await app.relaunch()
        XCTAssertTrue(app.model.showBiometricUnlockScreen, "Touch ID is offered after relaunch")
    }

    func testCancelledTouchIDReturnsToIdle() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        await app.lock()
        await app.model.unlock(masterPassword: app.password)
        await app.lock()

        app.biometrics.loadError = .userCancelled
        await app.model.unlockWithBiometrics()
        XCTAssertEqual(app.model.loadState, .idle)
        XCTAssertTrue(app.model.showBiometricUnlockScreen)
    }

    func testMissingCredentialHidesTouchID() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        await app.lock()
        await app.model.unlock(masterPassword: app.password)
        await app.lock()

        app.biometrics.passwords.removeAll()
        await app.model.unlockWithBiometrics()
        XCTAssertEqual(app.model.loadState, .failed(BiometricCredentialError.credentialNotFound.localizedDescription))
        XCTAssertFalse(app.model.showBiometricUnlockScreen)
    }

    func testStaleCredentialFailsUnlock() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        await app.lock()
        app.biometrics.passwords[app.url.standardizedFileURL.path] = "outdated"

        await app.model.unlockWithBiometrics()
        guard case .failed = app.model.loadState else {
            return XCTFail("a wrong stored password must fail, got \(app.model.loadState)")
        }
    }

    func testDisablingTouchIDDeletesCredential() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        await app.lock()
        await app.model.unlock(masterPassword: app.password)
        XCTAssertTrue(app.model.touchIDEnabledForSelectedVault)

        app.model.setTouchIDEnabledForSelectedVault(false)
        XCTAssertFalse(app.biometrics.hasSavedMasterPassword(for: app.url))
        XCTAssertFalse(app.model.touchIDEnabledForSelectedVault)
        await app.lock()
        XCTAssertFalse(app.model.showBiometricUnlockScreen)
    }

    func testChangingMasterPasswordUpdatesCredential() async throws {
        let app = try AppScenario(self, touchID: true)
        try await app.createVault()
        try await app.model.changeMasterPassword(newPassword: "rotated")
        XCTAssertEqual(app.biometrics.passwords[app.url.standardizedFileURL.path], "rotated")

        await app.lock()
        await app.model.unlockWithBiometrics()
        XCTAssertTrue(app.model.loadState.isUnlocked)
    }

    func testTouchIDOffNeverStoresPassword() async throws {
        let app = try AppScenario(self, touchID: false)
        try await app.createVault()
        await app.lock()
        await app.model.unlock(masterPassword: app.password)
        XCTAssertTrue(app.biometrics.passwords.isEmpty)
        await app.lock()
        XCTAssertFalse(app.model.showBiometricUnlockScreen)
    }
}
