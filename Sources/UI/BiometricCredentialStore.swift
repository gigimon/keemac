import Domain
import Foundation
import LocalAuthentication
import Security

@MainActor
protocol BiometricCredentialStoring {
    func hasSavedMasterPassword(for vaultURL: URL) -> Bool
    func saveMasterPassword(_ password: String, for vaultURL: URL) throws
    func loadMasterPassword(for vaultURL: URL, prompt: String) async throws -> String
    func deleteMasterPassword(for vaultURL: URL)
    /// The YubiKey response that lets Touch ID unlock without the key, stored like the password.
    func saveHardwareKeyResponse(_ response: VaultHardwareKeyResponse, for vaultURL: URL) throws
    /// Read right after `loadMasterPassword`, reusing its Touch ID authentication.
    func loadHardwareKeyResponse(for vaultURL: URL) -> VaultHardwareKeyResponse?
    func deleteHardwareKeyResponse(for vaultURL: URL)
    /// Forgets the Touch ID authentication `loadMasterPassword` left for `loadHardwareKeyResponse`.
    func endAuthentication()
}

extension BiometricCredentialStoring {
    func endAuthentication() {}
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
            return reason ?? L("Touch ID is not available on this Mac.")
        case .credentialNotFound:
            return L("Touch ID unlock is not configured for this vault yet.")
        case .userCancelled:
            return L("Touch ID authentication was cancelled.")
        case .authenticationFailed:
            return L("Touch ID authentication failed.")
        case .invalidCredentialData:
            return L("Saved vault credentials are invalid.")
        case .unexpected(let status):
            return L("Touch ID failed with Keychain status: \(Int(status)).")
        }
    }
}

@MainActor
final class KeychainBiometricCredentialStore: BiometricCredentialStoring {
    /// "KeeMac Dev" keeps its own items, so an ad-hoc dev build never replaces the installed app's.
    private static let suffix = AppVariant.isDevelopment ? ".dev" : ""
    private static let service = "com.keemac.master-password.biometric" + suffix
    private static let responseService = "com.keemac.hardware-key-response.biometric" + suffix
    /// The context Touch ID was evaluated with by the last `loadMasterPassword`.
    private var authenticatedContext: LAContext?

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
        try saveProtected(passwordData, query: baseQuery(for: vaultURL))
    }

    func saveHardwareKeyResponse(_ response: VaultHardwareKeyResponse, for vaultURL: URL) throws {
        guard let data = try? JSONEncoder().encode(response) else {
            throw BiometricCredentialError.invalidCredentialData
        }
        deleteHardwareKeyResponse(for: vaultURL)
        try saveProtected(data, query: baseQuery(for: vaultURL, service: Self.responseService))
    }

    func loadHardwareKeyResponse(for vaultURL: URL) -> VaultHardwareKeyResponse? {
        guard let context = authenticatedContext else {
            return nil
        }
        var query = baseQuery(for: vaultURL, service: Self.responseService)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(VaultHardwareKeyResponse.self, from: data)
    }

    func deleteHardwareKeyResponse(for vaultURL: URL) {
        _ = SecItemDelete(baseQuery(for: vaultURL, service: Self.responseService) as CFDictionary)
    }

    func endAuthentication() {
        authenticatedContext?.invalidate()
        authenticatedContext = nil
    }

    private func saveProtected(_ passwordData: Data, query: [String: Any]) throws {
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

            var addQuery = query
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
            try saveWithoutAccessControl(passwordData: passwordData, query: query)
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

        endAuthentication()
        try await evaluateBiometricPolicy(using: context, prompt: prompt)
        authenticatedContext = context

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

    /// A build signed with a provisioning profile has `keychain-access-groups`: its items live in the data
    /// protection keychain, where Touch ID access control works without keychain password prompts.
    /// Ad-hoc builds keep using the legacy file keychain.
    static let usesDataProtectionKeychain: Bool = {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else {
            return false
        }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }()

    private func baseQuery(for vaultURL: URL, service: String = service) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultURL.standardizedFileURL.path
        ]
        if Self.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
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
            return .unavailable(reason: L("Touch ID interaction is currently not allowed."))
        case errSecMissingEntitlement:
            return .unavailable(reason: L("Keychain entitlement is missing for this app run."))
        default:
            return .unexpected(status: status)
        }
    }

    private func saveWithoutAccessControl(passwordData: Data, query: [String: Any]) throws {
        var addQuery = query
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
