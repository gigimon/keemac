import Domain
import Foundation

public struct LocalKDBXVaultLoader: VaultLoading {
    public init() {}

    public func loadVault(from fileURL: URL, masterPassword: String, keyFileURL: URL?) async throws -> LoadedVault {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultError.fileReadFailure(path: fileURL.path)
        }

        if let keyFileURL {
            guard FileManager.default.fileExists(atPath: keyFileURL.path) else {
                throw VaultError.fileReadFailure(path: keyFileURL.path)
            }
        }

        guard !masterPassword.isEmpty || keyFileURL != nil else {
            throw VaultError.invalidPassword
        }

        // Step 1 intentionally keeps integration thin. Real KDBX parsing will be wired
        // in Step 2 through a concrete KeePassium adapter.
        throw VaultError.missingDependency(name: "KeePassiumLib adapter")
    }
}
