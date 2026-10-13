import AppKit
import CryptoKit
import Domain
import SwiftUI

struct VaultEntryHistorySheet: View {
    let entry: VaultEntry
    let onRevert: @Sendable (_ historyIndex: Int) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revertingRevisionIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Entry History"))
                        .font(.title3.weight(.semibold))
                    Text(entry.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close")) {
                    dismiss()
                }
                .keemacSecondaryActionButton()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if historyChanges.isEmpty {
                        ContentUnavailableView(
                            L("No History"),
                            systemImage: "clock.arrow.circlepath",
                            description: Text(L("This entry does not have saved revisions yet."))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(historyChanges) { change in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(change.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(change.formattedDate)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if let historyIndex = change.historyIndex {
                                        IconActionButton(
                                            systemImage: "arrow.uturn.backward.circle",
                                            helpText: L("Revert to this revision")
                                        ) {
                                            revertingRevisionIndex = historyIndex
                                            Task {
                                                await onRevert(historyIndex)
                                                revertingRevisionIndex = nil
                                            }
                                        }
                                        .disabled(revertingRevisionIndex != nil)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(change.details, id: \.self) { detail in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 6)
                                            Text(detail)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var historyChanges: [HistoryChangeItem] {
        let snapshots = [EntryRevisionSnapshot.current(entry)] + entry.history.enumerated().map(EntryRevisionSnapshot.revision)
        guard !snapshots.isEmpty else {
            return []
        }

        return snapshots.enumerated().map { index, snapshot in
            let olderSnapshot = snapshots.indices.contains(index + 1) ? snapshots[index + 1] : nil
            let details = olderSnapshot.map { snapshot.diffDetails(comparedTo: $0) } ?? [L("Initial recorded revision")]
            return HistoryChangeItem(
                id: historyChangeID(for: snapshot, index: index),
                title: historyChangeTitle(for: index),
                formattedDate: Self.dateFormatter.string(from: snapshot.modifiedAt ?? .distantPast),
                details: details,
                historyIndex: snapshot.historyIndex
            )
        }
    }

    private func historyChangeTitle(for index: Int) -> String {
        switch index {
        case 0:
            return L("Latest change")
        case 1:
            return L("Previous change")
        default:
            return L("Earlier change #\(index + 1)")
        }
    }

    private func historyChangeID(for snapshot: EntryRevisionSnapshot, index: Int) -> String {
        let timestamp = snapshot.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(index)-\(snapshot.id.uuidString)-\(timestamp)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct HistoryChangeItem: Identifiable {
    let id: String
    let title: String
    let formattedDate: String
    let details: [String]
    let historyIndex: Int?
}

struct EntryRevisionSnapshot {
    let id: UUID
    let isCurrent: Bool
    let historyIndex: Int?
    let modifiedAt: Date?
    let groupPath: String
    let title: String
    let username: String?
    let password: String?
    let url: URL?
    let notes: String?
    let customFields: [VaultCustomField]
    let attachments: [VaultAttachment]
    let iconID: Int?
    let otp: VaultOTPConfiguration?
    let otpStorageStyle: VaultOTPStorageStyle?

    static func current(_ entry: VaultEntry) -> EntryRevisionSnapshot {
        EntryRevisionSnapshot(
            id: entry.id,
            isCurrent: true,
            historyIndex: nil,
            modifiedAt: entry.modifiedAt,
            groupPath: entry.groupPath,
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            customFields: entry.customFields,
            attachments: entry.attachments,
            iconID: entry.iconID,
            otp: entry.otp,
            otpStorageStyle: entry.otpStorageStyle
        )
    }

    static func revision(_ item: EnumeratedSequence<[VaultEntryRevision]>.Element) -> EntryRevisionSnapshot {
        let revision = item.element
        return EntryRevisionSnapshot(
            id: revision.id,
            isCurrent: false,
            historyIndex: item.offset,
            modifiedAt: revision.modifiedAt,
            groupPath: revision.groupPath,
            title: revision.title,
            username: revision.username,
            password: revision.password,
            url: revision.url,
            notes: revision.notes,
            customFields: revision.customFields,
            attachments: revision.attachments,
            iconID: revision.iconID,
            otp: revision.otp,
            otpStorageStyle: revision.otpStorageStyle
        )
    }

    func diffDetails(comparedTo older: EntryRevisionSnapshot) -> [String] {
        var details: [String] = []

        if title != older.title {
            details.append(L("Title: \(quoted(older.title)) -> \(quoted(title))"))
        }
        if normalized(username) != normalized(older.username) {
            details.append(L("Username: \(describe(old: older.username, new: username))"))
        }
        if normalized(password) != normalized(older.password) {
            details.append(L("Password updated"))
        }
        if normalizedURL(url) != normalizedURL(older.url) {
            details.append(L("Website: \(describe(old: older.url?.absoluteString, new: url?.absoluteString))"))
        }
        if normalized(groupPath) != normalized(older.groupPath) {
            details.append(L("Moved: \(describe(old: emptyAsDash(older.groupPath), new: emptyAsDash(groupPath)))"))
        }
        if normalized(notes) != normalized(older.notes) {
            details.append(L("Notes updated"))
        }
        if iconID != older.iconID {
            details.append(L("Icon changed"))
        }
        if otpSummary != older.otpSummary {
            details.append(L("One-time password configuration updated"))
        }
        if attachmentSummary != older.attachmentSummary {
            details.append(L("Attachments updated"))
        }

        let customFieldChanges = customFieldDiff(comparedTo: older)
        details.append(contentsOf: customFieldChanges)

        return details
    }

    private var otpSummary: String {
        guard let otp else {
            return "none"
        }
        return "\(otp.kind.rawValue)|\(otp.algorithm.rawValue)|\(otp.digits)|\(otp.period)|\(otp.timeBase)|\(otpStorageStyle?.rawValue ?? "none")|\(otp.secret.base64EncodedString())"
    }

    private var attachmentSummary: String {
        attachments
            .map { "\($0.name)|\($0.data.base64EncodedString())|\($0.isProtected)" }
            .sorted()
            .joined(separator: "||")
    }

    private func customFieldDiff(comparedTo older: EntryRevisionSnapshot) -> [String] {
        let oldFields = Dictionary(uniqueKeysWithValues: older.customFields.map { ($0.key, $0) })
        let newFields = Dictionary(uniqueKeysWithValues: customFields.map { ($0.key, $0) })
        let keys = Set(oldFields.keys).union(newFields.keys).sorted()
        var details: [String] = []

        for key in keys {
            switch (oldFields[key], newFields[key]) {
            case let (nil, newField?):
                details.append(L("Custom field added: \(newField.key)"))
            case let (oldField?, nil):
                details.append(L("Custom field removed: \(oldField.key)"))
            case let (oldField?, newField?):
                if oldField.value != newField.value || oldField.isProtected != newField.isProtected {
                    details.append(L("Custom field updated: \(newField.key)"))
                }
            case (nil, nil):
                break
            }
        }

        return details
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedURL(_ value: URL?) -> String {
        value?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func emptyAsDash(_ value: String) -> String {
        let normalizedValue = normalized(value)
        return normalizedValue.isEmpty ? "-" : normalizedValue
    }

    private func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    private func describe(old: String?, new: String?) -> String {
        "\(quoted(displayValue(old))) -> \(quoted(displayValue(new)))"
    }

    private func displayValue(_ value: String?) -> String {
        let normalizedValue = normalized(value)
        return normalizedValue.isEmpty ? "-" : normalizedValue
    }
}

struct IconActionButton: View {
    let systemImage: String
    let helpText: String
    let tint: Color?
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    private let cornerRadius: CGFloat = 7
    private let size: CGFloat = 28

    init(systemImage: String, helpText: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.helpText = helpText
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(isPressed ? 0.93 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plain)
        .iconHelp(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var hoverTint: Color {
        tint ?? .accentColor
    }

    private var iconColor: Color {
        if let tint {
            return tint
        }
        return isHovered ? .accentColor : .secondary
    }

    private var backgroundFill: Color {
        if isPressed {
            return hoverTint.opacity(0.28)
        }
        if isHovered {
            return hoverTint.opacity(0.18)
        }
        return .clear
    }

    private var borderColor: Color {
        if isHovered || isPressed {
            return hoverTint.opacity(0.32)
        }
        return .clear
    }
}

struct IconPalettePicker: View {
    @Binding var selectedIconID: Int?

    private let columns = [
        GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(DefaultKeePassIconMapper.availableIconIDs, id: \.self) { iconID in
                    Button {
                        selectedIconID = iconID
                    } label: {
                        Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? "questionmark")
                            .frame(width: 18, height: 18)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedIconID == iconID ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selectedIconID == iconID ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .iconHelp(L("Icon \(iconID)"))
                    .hoverHighlight()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 96, maxHeight: 144)
    }
}

enum DefaultKeePassIconMapper {
    static let availableIconIDs = Array(0...68)

    static func symbolName(for iconID: Int?) -> String? {
        guard let iconID else {
            return nil
        }

        switch iconID {
        case 0: return "key.fill"
        case 1: return "network"
        case 2: return "exclamationmark.triangle.fill"
        case 3: return "server.rack"
        case 4: return "paperclip"
        case 5: return "globe"
        case 6: return "externaldrive.fill.badge.minus"
        case 7: return "note.text"
        case 8: return "dot.radiowaves.left.and.right"
        case 9: return "person.crop.circle"
        case 10: return "person.2.fill"
        case 11: return "camera.fill"
        case 12: return "desktopcomputer.trianglebadge.exclamationmark"
        case 13: return "key.horizontal.fill"
        case 14: return "battery.100"
        case 15: return "scanner.fill"
        case 16: return "safari.fill"
        case 17: return "opticaldiscdrive.fill"
        case 18: return "display"
        case 19: return "envelope.fill"
        case 20: return "ellipsis.circle.fill"
        case 21: return "calendar"
        case 22: return "textformat.abc"
        case 23: return "square.grid.3x3.fill"
        case 24: return "link"
        case 25: return "tray.fill"
        case 26: return "square.and.arrow.down.fill"
        case 27: return "externaldrive.fill.badge.minus"
        case 28: return "play.rectangle.fill"
        case 29: return "terminal.fill"
        case 30: return "terminal"
        case 31: return "printer.fill"
        case 32: return "externaldrive.connected.to.line.below.fill"
        case 33: return "play.fill"
        case 34: return "gearshape.fill"
        case 35: return "macwindow"
        case 36: return "archivebox.fill"
        case 37: return "percent"
        case 38: return "network.slash"
        case 39: return "clock.arrow.circlepath"
        case 40: return "envelope.open.fill"
        case 41: return "point.topleft.down.curvedto.point.bottomright.up"
        case 42: return "memorychip.fill"
        case 43: return "trash.fill"
        case 44: return "note.text"
        case 45: return "xmark.circle.fill"
        case 46: return "questionmark.circle.fill"
        case 47: return "shippingbox.fill"
        case 48: return "folder.fill"
        case 49: return "folder"
        case 50: return "archivebox.circle.fill"
        case 51: return "lock.open.fill"
        case 52: return "lock.fill"
        case 53: return "checkmark.circle.fill"
        case 54: return "signature"
        case 55: return "photo.fill"
        case 56: return "book.closed.fill"
        case 57: return "doc.text.fill"
        case 58: return "person.badge.shield.checkmark.fill"
        case 59: return "hammer.fill"
        case 60: return "house.fill"
        case 61: return "square.3.layers.3d"
        case 62: return "lizard.fill"
        case 63: return "leaf.fill"
        case 64: return "apple.logo"
        case 65: return "text.book.closed.fill"
        case 66: return "dollarsign.circle.fill"
        case 67: return "checkmark.seal.fill"
        case 68: return "phone.fill"
        default: return nil
        }
    }
}

struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct OTPCodeState {
    let code: String
    /// Time-based kinds only; 0 for HOTP.
    let remainingSeconds: Int
    let period: Int
    let kind: VaultOTPKind
    /// HOTP only: the counter this code was made for.
    let counter: UInt64?

    var isCounterBased: Bool {
        kind.isCounterBased
    }
}

enum OTPCodeGenerator {
    /// Steam Guard codes use five characters from this alphabet instead of digits.
    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    static func makeCodeState(from config: VaultOTPConfiguration, now: Date) -> OTPCodeState? {
        if config.kind == .hotp {
            guard let code = code(secret: config.secret, counter: config.counter, digits: config.digits, algorithm: config.algorithm) else {
                return nil
            }
            return OTPCodeState(code: code, remainingSeconds: 0, period: 0, kind: .hotp, counter: config.counter)
        }

        let period = max(config.period, 1)
        let seconds = now.timeIntervalSince1970 - config.timeBase
        guard seconds >= 0 else {
            return nil
        }

        let counter = UInt64(floor(seconds / Double(period)))
        let code: String?
        if config.kind == .steam {
            code = steamCode(secret: config.secret, counter: counter)
        } else {
            code = self.code(secret: config.secret, counter: counter, digits: config.digits, algorithm: config.algorithm)
        }
        guard let code else {
            return nil
        }

        let elapsed = Int(floor(seconds))
        let remainder = elapsed % period
        let remaining = remainder == 0 ? period : (period - remainder)

        return OTPCodeState(code: code, remainingSeconds: remaining, period: period, kind: config.kind, counter: nil)
    }

    /// RFC 4226 code for one counter value.
    static func code(secret: Data, counter: UInt64, digits: Int, algorithm: VaultOTPAlgorithm) -> String? {
        guard let value = truncatedValue(secret: secret, counter: counter, algorithm: algorithm) else {
            return nil
        }
        let modulo = decimalModulo(digits: digits)
        return String(value % modulo).leftPadded(to: min(max(digits, 1), 9), with: "0")
    }

    static func steamCode(secret: Data, counter: UInt64) -> String? {
        guard var value = truncatedValue(secret: secret, counter: counter, algorithm: .sha1) else {
            return nil
        }
        var code = ""
        for _ in 0..<5 {
            code.append(steamAlphabet[value % steamAlphabet.count])
            value /= steamAlphabet.count
        }
        return code
    }

    /// Dynamic truncation: 31 bits of the HMAC at the offset given by its last nibble.
    private static func truncatedValue(secret: Data, counter: UInt64, algorithm: VaultOTPAlgorithm) -> Int? {
        let hash = hmac(secret: secret, data: counter.bigEndianData, algorithm: algorithm)
        guard hash.count >= 20 else {
            return nil
        }

        let offset = Int(hash[hash.count - 1] & 0x0f)
        guard hash.count > offset + 3 else {
            return nil
        }

        return
            (Int(hash[offset] & 0x7f) << 24) |
            (Int(hash[offset + 1]) << 16) |
            (Int(hash[offset + 2]) << 8) |
            Int(hash[offset + 3])
    }

    private static func hmac(secret: Data, data: Data, algorithm: VaultOTPAlgorithm) -> Data {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
    }

    private static func decimalModulo(digits: Int) -> Int {
        let clampedDigits = min(max(digits, 1), 9)
        var value = 1
        for _ in 0..<clampedDigits {
            value *= 10
        }
        return value
    }
}

extension UInt64 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else {
            return self
        }
        return String(repeating: String(character), count: length - count) + self
    }
}

enum OTPSecretFormatter {
    static func encodeBase32(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}
