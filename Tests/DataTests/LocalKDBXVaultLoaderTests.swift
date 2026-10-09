import Data
import Domain
import Foundation
import XCTest

final class LocalKDBXVaultLoaderTests: XCTestCase {
    func testLoadVaultFailsWhenVaultFileDoesNotExist() async {
        let loader = LocalKDBXVaultLoader()
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("kdbx")

        do {
            _ = try await loader.loadVault(from: missingURL, masterPassword: "password", keyFileURL: nil)
            XCTFail("Expected failure for missing vault file.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .fileReadFailure(path: missingURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultFailsWhenKeyFileDoesNotExist() async throws {
        let loader = LocalKDBXVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        let missingKeyFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("keyx")
        defer { TestSupport.removeIfExists(vaultURL) }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "password", keyFileURL: missingKeyFileURL)
            XCTFail("Expected failure for missing key file.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .fileReadFailure(path: missingKeyFileURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultFailsWhenNoPasswordAndNoKeyFileProvided() async throws {
        let loader = LocalKDBXVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        defer { TestSupport.removeIfExists(vaultURL) }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "", keyFileURL: nil)
            XCTFail("Expected invalid password error.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .invalidPassword)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultReturnsMissingDependencyAfterValidationPasses() async throws {
        let loader = LocalKDBXVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        defer { TestSupport.removeIfExists(vaultURL) }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "password", keyFileURL: nil)
            XCTFail("Expected missing dependency error.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .missingDependency(name: "KeePassiumLib adapter"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadVaultAcceptsKeyFileOnlyUnlockBeforeDependencyFailure() async throws {
        let loader = LocalKDBXVaultLoader()
        let vaultURL = try TestSupport.makeTemporaryFile(fileExtension: "kdbx")
        let keyFileURL = try TestSupport.makeTemporaryFile(fileExtension: "key")
        defer {
            TestSupport.removeIfExists(vaultURL)
            TestSupport.removeIfExists(keyFileURL)
        }

        do {
            _ = try await loader.loadVault(from: vaultURL, masterPassword: "", keyFileURL: keyFileURL)
            XCTFail("Expected missing dependency error.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .missingDependency(name: "KeePassiumLib adapter"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
