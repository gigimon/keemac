import Foundation

public enum VaultError: LocalizedError, Equatable, Sendable {
    case invalidPassword
    case unsupportedKDBXVariant
    case parseFailure(details: String? = nil)
    case fileReadFailure(path: String? = nil)
    case missingDependency(name: String)
    case unknown(details: String? = nil)
    /// Changing the master key: the current password (with the current key file) doesn't open the database.
    case wrongCurrentPassword
    /// A master key needs a password, a key file or both.
    case emptyMasterKey
    /// Generating a new key file over the one the database opens with now.
    case keyFileInUse
    /// The remembered hardware key isn't connected.
    case hardwareKeyNotFound(serial: UInt32)
    /// The slot needs a touch and none came in time.
    case hardwareKeyTimedOut
    /// The slot isn't programmed for HMAC-SHA1 challenge-response.
    case hardwareKeySlotNotConfigured(slot: Int)
    /// The user cancelled waiting for the hardware key.
    case hardwareKeyCancelled
    /// Talking to the hardware key failed.
    case hardwareKeyFailed(details: String)
    /// KeePassXC's KDBX 3.1 challenge-response scheme isn't supported.
    case hardwareKeyUnsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return L("Master password is invalid, or this database requires an additional key file.")
        case .unsupportedKDBXVariant:
            return L("This KDBX version is not supported yet.")
        case .parseFailure(let details):
            return details.map { L("Could not parse the vault: \($0)") } ?? L("Could not parse the vault.")
        case .fileReadFailure(let path):
            return path.map { L("Cannot read vault file at path: \($0)") } ?? L("Cannot read vault file.")
        case .missingDependency(let name):
            return L("Required dependency is not configured: \(name).")
        case .unknown(let details):
            return details.map { L("Unexpected vault error: \($0)") } ?? L("Unexpected vault error.")
        case .wrongCurrentPassword:
            return L("The current password is wrong.")
        case .emptyMasterKey:
            return L("Set a password before removing the key file.")
        case .keyFileInUse:
            return L("Choose a different file than the current key file.")
        case .hardwareKeyNotFound(let serial):
            return L("Connect YubiKey \(String(serial)) to unlock this database.")
        case .hardwareKeyTimedOut:
            return L("Timed out waiting for touch.")
        case .hardwareKeySlotNotConfigured(let slot):
            return L("Slot \(slot) isn’t set up for challenge-response.")
        case .hardwareKeyCancelled:
            return L("Cancelled waiting for the hardware key.")
        case .hardwareKeyFailed(let details):
            return L("The hardware key didn’t respond: \(details)")
        case .hardwareKeyUnsupportedFormat:
            return L("Hardware keys are supported for KDBX 4 databases only. Open it in KeePassXC and save it as KDBX 4.")
        }
    }
}
