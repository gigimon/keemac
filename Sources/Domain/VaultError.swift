import Foundation

public enum VaultError: LocalizedError, Equatable, Sendable {
    case invalidPassword
    case unsupportedKDBXVariant
    case parseFailure(details: String? = nil)
    case fileReadFailure(path: String? = nil)
    case missingDependency(name: String)
    case unknown(details: String? = nil)

    public var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Master password is invalid, or this database requires an additional key file."
        case .unsupportedKDBXVariant:
            return "This KDBX version is not supported yet."
        case .parseFailure(let details):
            return details.map { "Could not parse the vault: \($0)" } ?? "Could not parse the vault."
        case .fileReadFailure(let path):
            return path.map { "Cannot read vault file at path: \($0)" } ?? "Cannot read vault file."
        case .missingDependency(let name):
            return "Required dependency is not configured: \(name)."
        case .unknown(let details):
            return details.map { "Unexpected vault error: \($0)" } ?? "Unexpected vault error."
        }
    }
}
