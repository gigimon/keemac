import Foundation

/// What an entry represents. Stored in the entry's KDBX 4 CustomData so other KeePass clients
/// keep it; the type's values live in standard fields and plain custom fields.
public enum VaultEntryType: String, Sendable, CaseIterable, Equatable {
    case login
    case card
    case wifi
    case server
    /// A private SSH key for KeeMac's SSH agent.
    case sshKey
    case note
    /// Created from an entry in the database's templates group.
    case template

    /// CustomData key holding the type.
    public static let customDataKey = "KeeMac.EntryType"
    /// CustomData key holding the template's title for `.template` entries.
    public static let templateCustomDataKey = "KeeMac.Template"
}

/// Custom field names used by the built-in entry types.
public enum VaultTypedField {
    /// Card expiry as MM/YY.
    public static let expiry = "Expiry"
    public static let cvv = "CVV"
    public static let pin = "PIN"
    /// Wi-Fi security: WPA3, WPA2, WEP or None.
    public static let security = "Security"

    public static func keys(for type: VaultEntryType) -> Set<String> {
        switch type {
        case .card: return [expiry, cvv, pin]
        case .wifi: return [security]
        case .login, .server, .sshKey, .note, .template: return []
        }
    }
}
