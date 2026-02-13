import Foundation
import OSLog

enum SecureLogger {
    private static let logger = Logger(subsystem: "com.keemac.app", category: "security")

    static func logUnlockFailure(_ error: Error) {
        let nsError = error as NSError
        logger.error(
            "Unlock failed (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))"
        )
    }

    static func logVaultLocked(reason: String) {
        logger.notice("Vault locked (reason: \(reason, privacy: .public))")
    }
}
