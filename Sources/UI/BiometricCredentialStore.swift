import Foundation
import LocalAuthentication
import Security

@MainActor
protocol BiometricCredentialStoring {
    func hasSavedMasterPassword(for vaultURL: URL) -> Bool
    func saveMasterPassword(_ password: String, for vaultURL: URL) throws
    func loadMasterPassword(for vaultURL: URL, prompt: String) async throws -> String
    func deleteMasterPassword(for vaultURL: URL)
}

enum BiometricCredentialError: LocalizedError {
    case unavailable(reason: String?)
    case credentialNotFound
    case userCancelled
    case authenticationFailed
    case invalidCredentialData
    case unexpected(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason ?? "Touch ID is not available on this Mac."
        case .credentialNotFound:
            return "Touch ID unlock is not configured for this vault yet."
        case .userCancelled:
            return "Touch ID authentication was cancelled."
        case .authenticationFailed:
            return "Touch ID authentication failed."
        case .invalidCredentialData:
            return "Saved vault credentials are invalid."
        case .unexpected(let status):
            return "Touch ID failed with Keychain status: \(status)."
        }
    }
}

@MainActor
final class KeychainBiometricCredentialStore: BiometricCredentialStoring {
    private static let service = "com.keemac.master-password.biometric"

    func hasSavedMasterPassword(for vaultURL: URL) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        var query = baseQuery(for: vaultURL)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        // For biometrically-protected items Keychain can report "interaction not allowed"
        // when probing without UI; this still means the credential exists.
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return true
        }
        return false
    }

    func saveMasterPassword(_ password: String, for vaultURL: URL) throws {
        guard !password.isEmpty else {
            return
        }

        guard let passwordData = password.data(using: .utf8), !passwordData.isEmpty else {
            throw BiometricCredentialError.invalidCredentialData
        }

        deleteMasterPassword(for: vaultURL)

        let fallbackFlags: [SecAccessControlCreateFlags] = [.biometryCurrentSet, .biometryAny, .userPresence]
        var lastError: BiometricCredentialError?
        var sawMissingEntitlement = false

        for flags in fallbackFlags {
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                flags,
                &accessControlError
            ) else {
                let reason = accessControlError?.takeRetainedValue().localizedDescription
                lastError = .unavailable(reason: reason)
                continue
            }

            var addQuery = baseQuery(for: vaultURL)
            addQuery[kSecAttrAccessControl as String] = accessControl
            addQuery[kSecValueData as String] = passwordData

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecSuccess {
                return
            }
            if status == errSecMissingEntitlement {
                sawMissingEntitlement = true
            }
            lastError = mapStatus(status)
        }

        if sawMissingEntitlement {
            try saveWithoutAccessControl(passwordData: passwordData, for: vaultURL)
            return
        }

        throw lastError ?? .unexpected(status: errSecInternalError)
    }

    func loadMasterPassword(for vaultURL: URL, prompt: String) async throws -> String {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            throw BiometricCredentialError.unavailable(reason: policyError?.localizedDescription)
        }

        try await evaluateBiometricPolicy(using: context, prompt: prompt)

        var query = baseQuery(for: vaultURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }

        guard
            let data = item as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            throw BiometricCredentialError.invalidCredentialData
        }

        return password
    }

    func deleteMasterPassword(for vaultURL: URL) {
        let query = baseQuery(for: vaultURL)
        _ = SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for vaultURL: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultURL.standardizedFileURL.path
        ]
    }

    private func mapStatus(_ status: OSStatus) -> BiometricCredentialError {
        switch status {
        case errSecItemNotFound:
            return .credentialNotFound
        case errSecUserCanceled:
            return .userCancelled
        case errSecAuthFailed:
            return .authenticationFailed
        case errSecInteractionNotAllowed:
            return .unavailable(reason: "Touch ID interaction is currently not allowed.")
        case errSecMissingEntitlement:
            return .unavailable(reason: "Keychain entitlement is missing for this app run.")
        default:
            return .unexpected(status: status)
        }
    }

    private func saveWithoutAccessControl(passwordData: Data, for vaultURL: URL) throws {
        var addQuery = baseQuery(for: vaultURL)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecValueData as String] = passwordData

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    private func evaluateBiometricPolicy(using context: LAContext, prompt: String) async throws {
        do {
            let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: prompt) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }

            if !success {
                throw BiometricCredentialError.authenticationFailed
            }
        } catch {
            if let laError = error as? LAError {
                switch laError.code {
                case .userCancel, .appCancel, .systemCancel:
                    throw BiometricCredentialError.userCancelled
                case .authenticationFailed:
                    throw BiometricCredentialError.authenticationFailed
                case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                    throw BiometricCredentialError.unavailable(reason: laError.localizedDescription)
                default:
                    throw BiometricCredentialError.unavailable(reason: laError.localizedDescription)
                }
            }
            throw error
        }
    }

}
