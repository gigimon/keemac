import AppKit
import Data
import Domain
import SwiftUI

// MARK: - Type presentation

extension VaultEntryType {
    static let builtIns: [VaultEntryType] = [.login, .card, .wifi, .server, .sshKey, .note]

    var label: String {
        switch self {
        case .login: return L("Login")
        case .card: return L("Credit Card")
        case .wifi: return L("Wi-Fi")
        case .server: return L("Server / SSH")
        case .sshKey: return L("SSH Key")
        case .note: return L("Secure Note")
        case .template: return L("Entry")
        }
    }

    var symbol: String {
        switch self {
        case .login: return "key.fill"
        case .card: return "creditcard.fill"
        case .wifi: return "wifi"
        case .server: return "terminal.fill"
        case .sshKey: return "key.horizontal.fill"
        case .note: return "note.text"
        case .template: return "doc.text.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .login: return KM.oklch(lightness: 0.6, chroma: 0.14, hue: 250)
        case .card: return KM.oklch(lightness: 0.5, chroma: 0.15, hue: 280)
        case .wifi: return KM.oklch(lightness: 0.62, chroma: 0.12, hue: 215)
        case .server: return KM.oklch(lightness: 0.43, chroma: 0.02, hue: 260)
        case .sshKey: return KM.oklch(lightness: 0.58, chroma: 0.12, hue: 170)
        case .note: return KM.oklch(lightness: 0.72, chroma: 0.15, hue: 70)
        case .template: return KM.oklch(lightness: 0.58, chroma: 0.14, hue: 330)
        }
    }

    var titlePlaceholder: String {
        switch self {
        case .login: return L("e.g. Dropbox")
        case .card: return L("e.g. Revolut Visa")
        case .wifi: return L("Defaults to the network name")
        case .server: return L("Defaults to the host")
        case .sshKey: return L("Defaults to the key’s comment")
        case .note: return L("e.g. Door codes")
        case .template: return L("Title")
        }
    }

    /// How the type maps to KeePass fields, shown under the New Entry form.
    func compatibilityNote(templateName: String?) -> String? {
        switch self {
        case .login:
            return nil
        case .card:
            return L("Cardholder and card number use the standard Username and Password fields. Expiry, CVV and PIN are saved as custom fields, so any KeePass app can read them.")
        case .wifi:
            return L("Network name and password use the standard Username and Password fields. Security is saved as a custom field.")
        case .server:
            return L("Host and port are saved in the URL field as ssh://host:port. The private key is saved as an attachment.")
        case .sshKey:
            return L("The private key is saved as an attachment with KeeAgent settings, like KeePassXC stores SSH keys. Its passphrase is the entry’s password.")
        case .note:
            return L("Saved as a regular KeePass entry with only a title and notes.")
        case .template:
            return L("Fields come from the “\(templateName ?? L("template"))” template and are saved as custom fields.")
        }
    }
}

/// An entry in the database's templates group, offered as a type in New Entry.
struct EntryTemplate: Identifiable, Equatable {
    let id: UUID
    let title: String
    let iconID: Int?
    /// Custom field names and whether they are protected. Empty means login-style fields.
    let fields: [(key: String, isProtected: Bool)]

    init(entry: VaultEntry) {
        id = entry.id
        title = entry.title
        iconID = entry.iconID
        fields = entry.customFields.map { ($0.key, $0.isProtected) }
    }

    static func == (lhs: EntryTemplate, rhs: EntryTemplate) -> Bool {
        lhs.id == rhs.id
    }

    var symbol: String {
        if let iconID, iconID != 0, let symbol = DefaultKeePassIconMapper.symbolName(for: iconID) {
            return symbol
        }
        return VaultEntryType.template.symbol
    }

    static func all(in vault: LoadedVault) -> [EntryTemplate] {
        guard vault.summary.supportsEntryTypes, let path = vault.summary.templatesGroupPath else {
            return []
        }
        return vault.entries
            .filter { !$0.isTrashed && $0.groupPath == path }
            .map(EntryTemplate.init(entry:))
    }
}

extension VaultEntry {
    /// Types are only honoured on KDBX 4 databases; older files show every entry as a login.
    func effectiveType(supportsTypes: Bool) -> VaultEntryType {
        supportsTypes ? entryType : .login
    }

    func customValue(_ key: String) -> String? {
        customFields.first { $0.key == key }?.value
    }

    /// Host and port from an `ssh://host:port` URL.
    var serverAddress: (host: String, port: String) {
        guard let url, url.scheme?.lowercased() == "ssh" else {
            return (url?.host() ?? "", "22")
        }
        return (url.host() ?? "", url.port.map(String.init) ?? "22")
    }

    /// Second line in the entry list for typed entries.
    func typedSubtitle(supportsTypes: Bool) -> String? {
        switch effectiveType(supportsTypes: supportsTypes) {
        case .login:
            return nil
        case .card:
            let digits = CardNumber.digits(password ?? "")
            var text = "\(CardNumber.brand(digits) ?? L("Card")) •••• \(digits.suffix(4))"
            if CardExpiry.state(customValue(VaultTypedField.expiry)) == .expired {
                text += " · " + L("Expired")
            }
            return text
        case .wifi:
            let security = customValue(VaultTypedField.security) ?? ""
            return "\(username ?? "") · \(security == "None" ? L("Open network") : security)"
        case .server:
            let address = serverAddress
            let user = (username ?? "").isEmpty ? "" : "\(username ?? "")@"
            return user + address.host + (address.port == "22" ? "" : ":\(address.port)")
        case .sshKey:
            return sshKeySummary ?? username
        case .note:
            let firstLine = (notes ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return firstLine.isEmpty ? L("Empty note") : firstLine
        case .template:
            return templateName
        }
    }
}

// MARK: - Cards

enum CardNumber {
    static func digits(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(19))
    }

    static func brand(_ digits: String) -> String? {
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "Amex" }
        if digits.hasPrefix("4") { return "Visa" }
        if let two = Int(digits.prefix(2)), (51...55).contains(two) || (22...27).contains(two) { return "Mastercard" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") { return "Discover" }
        return nil
    }

    /// Groups of four, or 4-6-5 for Amex.
    static func formatted(_ value: String) -> String {
        let digits = digits(value)
        let groups: [Int] = digits.hasPrefix("34") || digits.hasPrefix("37") ? [4, 6, 5] : Array(repeating: 4, count: 5)
        var result: [String] = []
        var rest = Substring(digits)
        for size in groups where !rest.isEmpty {
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return result.joined(separator: " ")
    }

    /// Every digit hidden except the last four.
    static func masked(_ value: String) -> String {
        let formatted = formatted(value)
        let total = formatted.filter(\.isNumber).count
        var seen = 0
        return String(formatted.map { character in
            guard character.isNumber else {
                return character
            }
            seen += 1
            return seen <= total - 4 ? "•" : character
        })
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else {
                return false
            }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}

enum CardExpiry {
    enum State {
        case ok
        case soon
        case expired
    }

    /// MM/YY; "soon" means within two months.
    static func state(_ value: String?, now: Date = Date()) -> State? {
        guard let value, value.count == 5, value.dropFirst(2).first == "/",
              let month = Int(value.prefix(2)), let year = Int(value.suffix(2)), (1...12).contains(month) else {
            return nil
        }
        let calendar = Calendar.current
        let current = calendar.dateComponents([.year, .month], from: now)
        let difference = (2000 + year - (current.year ?? 0)) * 12 + (month - (current.month ?? 0))
        if difference < 0 { return .expired }
        return difference <= 2 ? .soon : .ok
    }

    /// Typing helper: digits only, a slash after the month.
    static func formatInput(_ value: String) -> String {
        let digits = String(value.filter(\.isNumber).prefix(4))
        guard digits.count >= 3 else {
            return digits
        }
        return "\(digits.prefix(2))/\(digits.dropFirst(2))"
    }
}

// MARK: - Tiles

/// Colored square with the type's symbol.
struct EntryTypeTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 9

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color)
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(.white)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Letter tile for logins, type tile for typed entries.
struct EntryTile: View {
    let entry: VaultEntry
    let supportsTypes: Bool
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 9
    var fontSize: CGFloat = 15

    var body: some View {
        let type = entry.effectiveType(supportsTypes: supportsTypes)
        if type == .login || entry.iconPNGData != nil {
            LetterTile(
                title: entry.title,
                size: size,
                cornerRadius: cornerRadius,
                fontSize: fontSize,
                colorHex: entry.backgroundColorHex,
                iconPNGData: entry.iconPNGData,
                iconID: entry.iconID
            )
        } else {
            let symbol = type == .template
                ? EntryTemplate(entry: entry).symbol
                : type.symbol
            EntryTypeTile(symbol: symbol, color: type.tileColor, size: size, cornerRadius: cornerRadius)
        }
    }
}

extension EntryTypeTile {
    /// Rendered tile for NSMenu items, which can't host SwiftUI views.
    @MainActor
    static func menuImage(symbol: String, color: Color) -> NSImage {
        let renderer = ImageRenderer(content: EntryTypeTile(symbol: symbol, color: color, size: 18, cornerRadius: 5))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
    }
}
