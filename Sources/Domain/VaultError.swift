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
    case hardwareKeyFailed(HardwareKeyFailure)
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
        case .hardwareKeyFailed(let failure):
            return failure.message
        case .hardwareKeyUnsupportedFormat:
            return L("Hardware keys are supported for KDBX 4 databases only. Open it in KeePassXC and save it as KDBX 4.")
        }
    }
}

/// Why talking to a hardware key failed, below "not found", "timed out" and "slot not set up".
public enum HardwareKeyFailure: Equatable, Sendable {
    case requestNotAccepted
    case responseCutShort
    case responseTooLong
    case checksumMismatch
    case noResponse
    /// macOS didn't allow opening the key (Input Monitoring).
    case accessDenied
    case openFailed(code: Int32)
    case readFailed(code: Int32)
    case writeFailed(code: Int32)
    /// The key doesn't show its serial number over the API.
    case serialHidden
    /// This KeeMac component has no hardware key support (helper loaders).
    case unavailable

    var message: String {
        switch self {
        case .requestNotAccepted:
            return L("The YubiKey didn’t accept the request.")
        case .responseCutShort:
            return L("The YubiKey’s response was cut short.")
        case .responseTooLong:
            return L("The YubiKey’s response is too long.")
        case .checksumMismatch:
            return L("The YubiKey’s response checksum is wrong.")
        case .noResponse:
            return L("The YubiKey didn’t respond.")
        case .accessDenied:
            return L("macOS didn’t allow access to the YubiKey. Allow KeeMac in System Settings → Privacy & Security → Input Monitoring.")
        case .openFailed(let code):
            return L("Could not open the YubiKey (\(Self.hex(code))).")
        case .readFailed(let code):
            return L("Reading from the YubiKey failed (\(Self.hex(code))).")
        case .writeFailed(let code):
            return L("Writing to the YubiKey failed (\(Self.hex(code))).")
        case .serialHidden:
            return L("The YubiKey hides its serial number. Turn on “Serial number visible” in YubiKey Manager.")
        case .unavailable:
            return L("Hardware keys aren’t available here.")
        }
    }

    private static func hex(_ code: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}
