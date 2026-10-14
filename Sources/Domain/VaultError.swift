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
        }
    }
}
