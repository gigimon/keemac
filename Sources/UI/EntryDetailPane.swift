import AppKit
import Domain
import SwiftUI

struct EntryDetailPane: View {
    enum Style {
        case grouped
        case form
    }

    let entry: VaultEntry
    let style: Style
    let isFavorite: Bool
    let groupDisplay: String
    var externalChange: AppViewModel.ExternalChange? = nil
    var previousGroupDisplay: String? = nil
    let isBusy: Bool
    let onToggleFavorite: () -> Void
    let onMoveToTrash: () -> Void
    let onEdit: () -> Void
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void
    let onUsed: () -> Void
    let onShowHistory: (() -> Void)?
    /// HOTP only: moves the entry to its next code.
    var onNextOTP: (() -> Void)? = nil
    var supportsTypes: Bool = false
    /// Title of the entry a `{REF:…}` points to.
    var referenceTitle: (UUID) -> String? = { _ in nil }
    var onOpenReference: (UUID) -> Void = { _ in }
    var sshDefaultConfirmation: VaultSSHConfirmation = .oncePerUnlock
    /// "Used by ssh for prod.example.com · 5 min ago".
    var sshLastUse: String?
    /// Turns on the SSH agent for a key attachment (the suggestion banner).
    var onUseInSSHAgent: ((VaultAttachment) -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var revealPassword = false
    @State private var revealedFieldKeys: Set<String> = []
    @State private var now: Date = .now
    @State private var preview: AttachmentPreviewRequest?
    @State private var hidesSSHSuggestion = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if style == .form {
                    formBody
                        .padding(.top, 22)
                } else {
                    groupedBody
                        .padding(.top, 24)
                }

                footer
                    .padding(.top, 26)
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .onReceive(timer) { now = $0 }
        .onChange(of: entry.id) { _, _ in
            revealPassword = false
            revealedFieldKeys = []
            preview = nil
            hidesSSHSuggestion = false
        }
        .sheet(item: $preview) { request in
            AttachmentPreviewSheet(attachments: entry.attachments, index: request.index) {
                preview = nil
            }
        }
    }

    @ViewBuilder
    private var sshSection: some View {
        if entry.sshAgent != nil {
            SSHKeyDetailCard(entry: entry, defaultConfirmation: sshDefaultConfirmation, lastUse: sshLastUse)
        } else if !hidesSSHSuggestion, let onUseInSSHAgent, !entry.isTrashed, let key = entry.suggestedSSHKeyAttachment {
            SSHKeySuggestionBanner(attachment: key) {
                onUseInSSHAgent(key)
            } onDismiss: {
                hidesSSHSuggestion = true
            }
        }
    }

    private var groupedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            sshSection

            if entryType == .login {
                credentialsCard

                if let url = entry.url {
                    websiteCard(url)
                }
            } else if !typedRows.isEmpty {
                typedFieldsCard
            }

            if let notes = entry.notes, !notes.isEmpty {
                notesCard(notes)
            }

            if !visibleCustomFields.isEmpty {
                customFieldsCard
            }

            if !entry.attachments.isEmpty {
                attachmentsCard
            }

            if !entry.tags.isEmpty {
                TagFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        KMTagChip(tag: tag)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            sshSection
                .padding(.bottom, 10)
            if entryType == .login {
                formRow(L("username")) {
                    Text(entry.username ?? "—")
                    .accessibilityIdentifier("detail.username")
                        .lineLimit(1)
                        .textSelection(.enabled)
                } trailing: {
                    referenceBadge(VaultEntryReferences.username)
                    if let username = entry.username, !username.isEmpty {
                        QRCodeButton(value: username, label: L("Username"), size: 28, iconSize: 12)
                        copyButton(username, label: L("Username"), identifier: "detail.copyUsername", size: 28)
                    }
                }

                formRow(L("password")) {
                    passwordText
                } trailing: {
                    referenceBadge(VaultEntryReferences.password)
                    if let password = entry.password, !password.isEmpty {
                        if let strength = PasswordStrength.evaluate(password) {
                            Text(strength.level.label)
                                .font(.system(size: 11))
                                .foregroundStyle(strength.level.color)
                        }
                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 7))
                        .iconHelp(revealPassword ? L("Hide password") : L("Show password"))
                        .accessibilityIdentifier("detail.revealPassword")
                        QRCodeButton(value: password, label: L("Password"), size: 28, iconSize: 12)
                        copyButton(password, label: L("Password"), identifier: "detail.copyPassword", size: 28)
                    }
                }

                if let otp = otpState {
                    formRow(L("one-time code")) {
                        HStack(spacing: 10) {
                            Text(formattedOTP(otp.code))
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                .kerning(1)
                                .foregroundStyle(KM.accent)
                                .accessibilityIdentifier("detail.otpCode")
                            otpProgress(otp, ringSize: 18)
                        }
                    } trailing: {
                        HStack(spacing: 4) {
                            if otp.isCounterBased {
                                nextOTPButton(size: 28)
                            }
                            copyButton(otp.code, label: L("One-time code"), identifier: "detail.copyOTP", size: 28)
                        }
                    }
                }
            } else {
                ForEach(typedRows) { row in
                    formRow(row.label) {
                        typedValue(row)
                    } trailing: {
                        typedActions(row, size: 28)
                    }
                }
            }

            Rectangle()
                .fill(KM.separator)
                .frame(height: 0.5)
                .padding(.vertical, 8)

            if entryType == .login, let url = entry.url {
                formRow(L("website")) {
                    Button {
                        openURL(url)
                        onUsed()
                    } label: {
                        Text(url.absoluteString)
                            .foregroundStyle(KM.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                } trailing: {
                    referenceBadge(VaultEntryReferences.url)
                    QRCodeButton(value: url.absoluteString, label: L("URL"), size: 28, iconSize: 12)
                    copyButton(url.absoluteString, label: L("URL"), identifier: "detail.copyURL", sensitive: false, size: 28)
                }
            }

            if !entry.tags.isEmpty {
                formRow(L("tags")) {
                    TagFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            KMTagChip(tag: tag, height: 22)
                        }
                    }
                }
            }

            if let notes = entry.notes, !notes.isEmpty {
                formRow(L("notes"), alignTop: true) {
                    Text(notes)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } trailing: {
                    referenceBadge(VaultEntryReferences.notes)
                }
            }

            ForEach(visibleCustomFields) { field in
                let isRevealed = !field.isProtected || revealedFieldKeys.contains(field.key)
                formRow(field.key) {
                    Text(isRevealed ? (field.value.isEmpty ? "—" : field.value) : String(repeating: "•", count: 12))
                        .accessibilityLabel(isRevealed ? (field.value.isEmpty ? L("Empty") : field.value) : L("Hidden"))
                        .lineLimit(3)
                        .textSelection(.enabled)
                } trailing: {
                    referenceBadge(field.key)
                    if field.isProtected {
                        Button {
                            if revealedFieldKeys.contains(field.key) {
                                revealedFieldKeys.remove(field.key)
                            } else {
                                revealedFieldKeys.insert(field.key)
                            }
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 7))
                        .iconHelp(isRevealed ? L("Hide \(field.key)") : L("Show \(field.key)"))
                    }
                    if !field.value.isEmpty {
                        QRCodeButton(value: field.value, label: field.key, size: 28, iconSize: 12)
                        copyButton(field.value, label: field.key, sensitive: field.isProtected, size: 28)
                    }
                }
            }

            if !entry.attachments.isEmpty {
                formRow(L("attachments"), alignTop: true) {
                    attachmentRows
                        .padding(.leading, 12)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.separator).frame(height: 0.5)
        }
    }

    private func formRow<Content: View>(_ label: String, alignTop: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        formRow(label, alignTop: alignTop, content: content) {
            EmptyView()
        }
    }

    private func formRow<Content: View, Trailing: View>(
        _ label: String,
        alignTop: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 16) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
                .padding(.top, alignTop ? 2 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 32)
        .padding(.vertical, alignTop ? 4 : 0)
    }

    private var header: some View {
        HStack(spacing: 16) {
            EntryTile(entry: entry, supportsTypes: supportsTypes, size: 60, cornerRadius: 15, fontSize: 26)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .accessibilityIdentifier("detail.title")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.3)
                    .lineLimit(1)
                    .foregroundStyle(EntryColor.color(fromHex: entry.foregroundColorHex) ?? KM.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: entry.isTrashed ? "trash" : "folder")
                        .font(.system(size: 11))
                    Text(entry.isTrashed ? L("Trash · was in \(groupDisplay)") : groupDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)

                if let externalChange {
                    syncLine(externalChange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isTrashed {
                HStack(spacing: 6) {
                    Button(action: onDeletePermanently) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 32, cornerRadius: 16, tint: KM.danger, filled: true))
                    .iconHelp(L("Delete Permanently"))
                    .accessibilityIdentifier("detail.deletePermanently")

                    Button(L("Restore"), action: onRestore)
                        .buttonStyle(KMButtonStyle(kind: .primary, height: 32))
                        .accessibilityIdentifier("detail.restore")
                }
                .disabled(isBusy)
            } else {
                HStack(spacing: 6) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 32, cornerRadius: 16, tint: isFavorite ? KM.warning : KM.textPrimary, filled: true))
                    .iconHelp(isFavorite ? L("Remove from Favorites") : L("Add to Favorites"))
                    .accessibilityIdentifier("detail.favorite")

                    Button(action: onMoveToTrash) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 32, cornerRadius: 16, tint: KM.textPrimary, filled: true))
                    .iconHelp(L("Move to Trash"))
                    .accessibilityIdentifier("detail.moveToTrash")

                    Button(L("Edit"), action: onEdit)
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 32))
                        .accessibilityIdentifier("detail.edit")
                        .keyboardShortcut("e", modifiers: [.command])
                }
                .disabled(isBusy)
            }
        }
    }

    private func syncLine(_ change: AppViewModel.ExternalChange) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .font(.system(size: 12))
            Text(syncLineText(change))
                .lineLimit(1)
            if (change.isConflict || change.isRestored), let onShowHistory {
                Button(L("Show History"), action: onShowHistory)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .padding(.leading, 4)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(KM.accent)
        .padding(.top, 2)
    }

    private func syncLineText(_ change: AppViewModel.ExternalChange) -> String {
        if change.isRestored {
            return L("Restored your version · the other device’s version is in History")
        }
        if change.isConflict {
            return L("Updated on another device · your previous version is in History")
        }
        let ago = RelativeDateFormatter.modified(change.date, now: now)
        if let previousGroupDisplay {
            return L("Moved on another device from \(previousGroupDisplay) · \(ago)")
        }
        return L("Updated on another device · \(ago)")
    }

    private var credentialsCard: some View {
        VStack(spacing: 0) {
            fieldRow(label: L("username"), accessory: referenceBadge(VaultEntryReferences.username)) {
                Text(entry.username ?? "—")
                    .accessibilityIdentifier("detail.username")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .textSelection(.enabled)
            } actions: {
                if let username = entry.username, !username.isEmpty {
                    QRCodeButton(value: username, label: L("Username"))
                    copyButton(username, label: L("Username"), identifier: "detail.copyUsername")
                }
            }

            rowSeparator

            fieldRow(label: L("password"), accessory: combined(passwordStrengthAccessory, referenceBadge(VaultEntryReferences.password))) {
                passwordText
            } actions: {
                if let password = entry.password, !password.isEmpty {
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(KMIconButtonStyle())
                    .iconHelp(revealPassword ? L("Hide password") : L("Show password"))
                    .accessibilityIdentifier("detail.revealPassword")
                    QRCodeButton(value: password, label: L("Password"))
                    copyButton(password, label: L("Password"), identifier: "detail.copyPassword")
                }
            }

            if let otp = otpState {
                rowSeparator
                fieldRow(label: L("one-time password")) {
                    HStack(spacing: 10) {
                        Text(formattedOTP(otp.code))
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .kerning(1)
                            .foregroundStyle(KM.accent)
                            .accessibilityIdentifier("detail.otpCode")
                        otpProgress(otp, ringSize: nil)
                    }
                } actions: {
                    if otp.isCounterBased {
                        nextOTPButton(size: 30)
                    }
                    copyButton(otp.code, label: L("One-time code"), identifier: "detail.copyOTP")
                }
            }
        }
        .kmCard()
    }

    private var passwordStrengthAccessory: AnyView? {
        guard let password = entry.password, let strength = PasswordStrength.evaluate(password) else {
            return nil
        }
        return AnyView(
            HStack(spacing: 5) {
                StrengthMeter(strength: strength)
                Text(strength.level.label)
                    .foregroundStyle(strength.level.color)
            }
        )
    }

    @ViewBuilder
    private var passwordText: some View {
        if let password = entry.password, !password.isEmpty {
            if revealPassword {
                Text(Self.colorized(password))
                    .accessibilityIdentifier("detail.password")
                    .font(.system(size: 13, design: .monospaced))
                    .kerning(0.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(repeating: "•", count: 16))
                    .font(.system(size: 13, design: .monospaced))
                    .kerning(0.5)
                    .accessibilityLabel(L("Hidden"))
            }
        } else {
            Text("—")
                .font(.system(size: 13))
        }
    }

    private func websiteCard(_ url: URL) -> some View {
        fieldRow(label: L("website"), accessory: referenceBadge(VaultEntryReferences.url)) {
            Text(url.absoluteString)
                .font(.system(size: 13))
                .foregroundStyle(KM.accent)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } actions: {
            QRCodeButton(value: url.absoluteString, label: L("URL"))
            copyButton(url.absoluteString, label: L("URL"), identifier: "detail.copyURL", sensitive: false)
            Button {
                openURL(url)
                onUsed()
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 14))
            }
            .buttonStyle(KMIconButtonStyle())
            .iconHelp(L("Open website"))
        }
        .kmCard()
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                KMSectionLabel(text: L("notes"))
                referenceBadge(VaultEntryReferences.notes)
            }
            Text(notes)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .kmCard()
    }

    private var customFieldsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleCustomFields.enumerated()), id: \.element.id) { index, field in
                if index > 0 {
                    rowSeparator
                }
                let isRevealed = !field.isProtected || revealedFieldKeys.contains(field.key)
                fieldRow(label: field.key, accessory: referenceBadge(field.key)) {
                    Text(isRevealed ? (field.value.isEmpty ? "—" : field.value) : String(repeating: "•", count: 12))
                        .accessibilityLabel(isRevealed ? (field.value.isEmpty ? L("Empty") : field.value) : L("Hidden"))
                        .font(.system(size: 13, design: field.isProtected ? .monospaced : .default))
                        .lineLimit(3)
                        .textSelection(.enabled)
                } actions: {
                    if field.isProtected {
                        Button {
                            if revealedFieldKeys.contains(field.key) {
                                revealedFieldKeys.remove(field.key)
                            } else {
                                revealedFieldKeys.insert(field.key)
                            }
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(KMIconButtonStyle())
                        .iconHelp(isRevealed ? L("Hide \(field.key)") : L("Show \(field.key)"))
                    }
                    if !field.value.isEmpty {
                        QRCodeButton(value: field.value, label: field.key)
                        copyButton(field.value, label: field.key, sensitive: field.isProtected)
                    }
                }
            }
        }
        .kmCard()
    }

    // MARK: - Typed entries

    private var entryType: VaultEntryType {
        entry.effectiveType(supportsTypes: supportsTypes)
    }

    /// Custom fields the type already shows in its own card are not listed again.
    private var visibleCustomFields: [VaultCustomField] {
        if entryType == .template {
            return []
        }
        let typeKeys = VaultTypedField.keys(for: entryType)
        return entry.customFields.filter { !typeKeys.contains($0.key) }
    }

    private struct TypedRow: Identifiable {
        /// Stable English name the view logic checks ("card number"); `label` is what is shown.
        let key: String
        let label: String
        var labelExtra: String?
        let value: String
        var secret: Bool = false
        var monospaced: Bool = false
        var large: Bool = false
        var badge: (text: String, color: Color)?
        var copyValue: String?
        var copyLabel: String = ""
        var showsStrength: Bool = false
        var openAction: (title: String, symbol: String, action: () -> Void)?
        /// A code that is more than the copied value, with its own help and caption (Wi-Fi join code).
        var joinQR: (value: String, help: String, caption: String)?

        var id: String { key }
    }

    private var typedRows: [TypedRow] {
        let username = entry.username ?? ""
        let password = entry.password ?? ""
        let passwordRow = TypedRow(
            key: "password",
            label: L("password"),
            value: password,
            secret: true,
            monospaced: true,
            copyValue: password,
            copyLabel: L("Password"),
            showsStrength: true
        )
        switch entryType {
        case .login, .note:
            return []
        case .sshKey:
            var rows = [TypedRow(key: "username", label: L("username"), value: username, copyValue: username, copyLabel: L("Username"))]
            if !password.isEmpty {
                rows.append(TypedRow(key: "password", label: L("passphrase"), value: password, secret: true, monospaced: true, copyValue: password, copyLabel: L("Passphrase")))
            }
            return rows
        case .card:
            let expiry = entry.customValue(VaultTypedField.expiry) ?? ""
            let cvv = entry.customValue(VaultTypedField.cvv) ?? ""
            let pin = entry.customValue(VaultTypedField.pin) ?? ""
            var badge: (String, Color)?
            switch CardExpiry.state(expiry, now: now) {
            case .expired: badge = (L("Expired"), KM.danger)
            case .soon: badge = (L("Expires soon"), Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
            default: break
            }
            var rows = [
                TypedRow(key: "cardholder", label: L("cardholder"), value: username, copyValue: username, copyLabel: L("Cardholder")),
                TypedRow(
                    key: "card number",
                    label: L("card number"),
                    labelExtra: CardNumber.brand(CardNumber.digits(password)),
                    value: password,
                    secret: true,
                    monospaced: true,
                    large: true,
                    copyValue: CardNumber.digits(password),
                    copyLabel: L("Card number")
                ),
                TypedRow(key: "expires", label: L("expires"), value: expiry, monospaced: true, badge: badge, copyValue: expiry, copyLabel: L("Expiry date")),
                TypedRow(key: "security code", label: L("security code"), value: cvv, secret: true, monospaced: true, copyValue: cvv, copyLabel: L("Security code"))
            ]
            if !pin.isEmpty {
                rows.append(TypedRow(key: "PIN", label: L("PIN"), value: pin, secret: true, monospaced: true, copyValue: pin, copyLabel: L("PIN")))
            }
            return rows
        case .wifi:
            let security = entry.customValue(VaultTypedField.security) ?? ""
            let labels = ["WPA3": "WPA3 Personal", "WPA2": "WPA2 Personal", "WEP": "WEP", "None": L("None (open network)")]
            var networkRow = TypedRow(key: "network name", label: L("network name"), value: username, copyValue: username, copyLabel: L("Network name"))
            if let payload = WiFiQRPayload.make(networkName: username, security: security, password: password) {
                networkRow.joinQR = (
                    payload,
                    L("Show QR Code to Join the Network"),
                    L("Scan with your phone’s camera to join the network. Anyone who can see the screen can scan it too.")
                )
            }
            var rows = [networkRow]
            if security != "None" {
                rows.append(passwordRow)
            }
            rows.append(TypedRow(key: "security", label: L("security"), value: labels[security] ?? security))
            return rows
        case .server:
            let address = entry.serverAddress
            return [
                TypedRow(
                    key: "host",
                    label: L("host"),
                    value: address.host,
                    monospaced: true,
                    copyValue: address.host,
                    copyLabel: L("Host"),
                    openAction: (L("Open in Terminal"), "terminal", openInTerminal)
                ),
                TypedRow(key: "port", label: L("port"), value: address.port, monospaced: true),
                TypedRow(key: "username", label: L("username"), value: username, copyValue: username, copyLabel: L("Username")),
                passwordRow
            ]
        case .template:
            return entry.customFields.map { field in
                TypedRow(
                    key: field.key,
                    label: field.key.lowercased(),
                    value: field.value,
                    secret: field.isProtected,
                    monospaced: field.isProtected,
                    copyValue: field.value,
                    copyLabel: field.key
                )
            }
        }
    }

    private var typedFieldsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(typedRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    rowSeparator
                }
                fieldRow(label: row.labelExtra.map { "\(row.label) · \($0)" } ?? row.label, accessory: row.showsStrength ? passwordStrengthAccessory : nil) {
                    typedValue(row)
                } actions: {
                    typedActions(row, size: 30)
                }
            }
        }
        .kmCard()
    }

    private func typedValue(_ row: TypedRow) -> some View {
        let revealed = !row.secret || revealedFieldKeys.contains(row.id)
        var text = row.value.isEmpty ? "—" : row.value
        if row.key == "card number" {
            text = revealed ? CardNumber.formatted(row.value) : CardNumber.masked(row.value)
        } else if !revealed, !row.value.isEmpty {
            text = String(repeating: "•", count: row.key == "PIN" ? 4 : (row.key == "security code" ? max(row.value.count, 3) : 16))
        }
        return HStack(spacing: 8) {
            Text(text)
                .accessibilityLabel(revealed || row.value.isEmpty ? (row.value.isEmpty ? L("Empty") : text) : (row.key == "card number" ? L("Hidden, ending in \(String(row.value.suffix(4)))") : L("Hidden")))
                .font(.system(size: row.large ? 15 : 13, design: row.monospaced ? .monospaced : .default))
                .kerning(row.monospaced ? 0.5 : 0)
                .textSelection(.enabled)
                .lineLimit(3)
            if let badge = row.badge {
                Text(badge.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule(style: .continuous).fill(badge.color.opacity(0.14)))
            }
        }
    }

    @ViewBuilder
    private func typedActions(_ row: TypedRow, size: CGFloat) -> some View {
        if let open = row.openAction, !row.value.isEmpty {
            Button(action: open.action) {
                Image(systemName: open.symbol).font(.system(size: 13))
            }
            .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size == 30 ? 8 : 7))
            .iconHelp(open.title)
        }
        if row.secret, !row.value.isEmpty {
            Button {
                if revealedFieldKeys.contains(row.id) {
                    revealedFieldKeys.remove(row.id)
                } else {
                    revealedFieldKeys.insert(row.id)
                }
            } label: {
                Image(systemName: revealedFieldKeys.contains(row.id) ? "eye.slash" : "eye")
                    .font(.system(size: 13))
            }
            .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size == 30 ? 8 : 7))
            .iconHelp(revealedFieldKeys.contains(row.id) ? L("Hide \(row.label)") : L("Show \(row.label)"))
        }
        if let joinQR = row.joinQR {
            QRCodeButton(value: joinQR.value, label: row.copyLabel, size: size, iconSize: size == 30 ? 13 : 12, help: joinQR.help, caption: joinQR.caption)
        } else if let copyValue = row.copyValue, !copyValue.isEmpty {
            QRCodeButton(value: copyValue, label: row.copyLabel, size: size, iconSize: size == 30 ? 13 : 12)
        }
        if let copyValue = row.copyValue, !copyValue.isEmpty {
            copyButton(copyValue, label: row.copyLabel, sensitive: row.secret || row.key == "card number", size: size)
        }
    }

    /// Opens `ssh user@host -p port` through the system's ssh:// handler (Terminal).
    private func openInTerminal() {
        let address = entry.serverAddress
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = address.host
        components.port = Int(address.port)
        if let username = entry.username, !username.isEmpty {
            components.user = username
        }
        guard let url = components.url else {
            return
        }
        NSWorkspace.shared.open(url)
        onUsed()
    }

    // MARK: - References

    /// "↗ Corporate account" for a field that mirrors another entry, "Broken reference" when that entry is gone.
    private func referenceBadge(_ field: String) -> AnyView? {
        guard let references = entry.references else {
            return nil
        }
        if references.brokenFields.contains(field) {
            return AnyView(
                Label(L("Broken reference"), systemImage: "link.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KM.danger)
                    .help(L("The entry this field points to no longer exists. Stored value: \(references.rawValues[field] ?? "")"))
            )
        }
        guard let source = references.sources[field] else {
            return nil
        }
        let title = referenceTitle(source) ?? L("another entry")
        return AnyView(
            Button {
                onOpenReference(source)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(title)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KM.accent)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule(style: .continuous).fill(KM.accent.opacity(0.12)))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L("This field uses the value from “\(title)”. Click to open it."))
        )
    }

    private func combined(_ first: AnyView?, _ second: AnyView?) -> AnyView? {
        switch (first, second) {
        case (nil, nil): return nil
        case (let view?, nil), (nil, let view?): return view
        case (let first?, let second?): return AnyView(HStack(spacing: 8) { first; second })
        }
    }

    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                KMSectionLabel(text: L("attachments"))
                Spacer()
                Text(String(entry.attachments.count))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .padding(.trailing, 8)
            .padding(.bottom, 4)
            attachmentRows
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .kmCard()
    }

    private var attachmentRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.attachments.enumerated()), id: \.element.id) { index, attachment in
                AttachmentRow(attachment: attachment) {
                    preview = AttachmentPreviewRequest(index: index)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text(L("Modified \(RelativeDateFormatter.modified(entry.modifiedAt, now: now))"))
            Text(L("Created \(RelativeDateFormatter.absolute(entry.createdAt))"))
            if let expiresAt = entry.expiresAt {
                Text(expiresAt < now
                     ? L("Expired \(RelativeDateFormatter.absolute(expiresAt))")
                     : L("Expires \(RelativeDateFormatter.absolute(expiresAt))"))
                    .foregroundStyle(expiresAt < now ? KM.danger : KM.textTertiary)
            }
            if let onShowHistory {
                Button {
                    onShowHistory()
                } label: {
                    Text(L("\(entry.history.count) earlier versions · Show History"))
                        .foregroundStyle(KM.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(KM.textTertiary)
        .frame(maxWidth: .infinity)
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(KM.separator)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func fieldRow<Content: View, Actions: View>(
        label: String,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(label)
                    if let accessory {
                        accessory
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private func copyButton(_ value: String, label: String, identifier: String? = nil, sensitive: Bool = true, size: CGFloat = 30) -> some View {
        Button {
            if sensitive {
                SensitiveClipboard.shared.copySensitiveText(value, label: label)
            } else {
                SensitiveClipboard.shared.copyPlainText(value, label: label)
            }
            onUsed()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
        }
        .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size == 30 ? 8 : 7))
        .iconHelp(L("Copy \(label)"))
        .accessibilityIdentifier(identifier ?? "detail.copy.\(label)")
    }

    /// Time left for TOTP and Steam codes, the counter for HOTP.
    @ViewBuilder
    private func otpProgress(_ otp: OTPCodeState, ringSize: CGFloat?) -> some View {
        if otp.isCounterBased {
            Text(L("Counter \(Int(clamping: otp.counter ?? 0))"))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(KM.textSecondary)
                .accessibilityIdentifier("detail.otpCounter")
        } else {
            if let ringSize {
                OTPRing(remaining: otp.remainingSeconds, period: otp.period, size: ringSize)
            } else {
                OTPRing(remaining: otp.remainingSeconds, period: otp.period)
            }
            Text(L("\(otp.remainingSeconds)s"))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(KM.textSecondary)
        }
    }

    private func nextOTPButton(size: CGFloat) -> some View {
        Button {
            onNextOTP?()
        } label: {
            Image(systemName: "arrow.forward.circle")
                .font(.system(size: 13))
        }
        .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size == 30 ? 8 : 7))
        .iconHelp(L("Next code"))
        .accessibilityIdentifier("detail.nextOTP")
        .disabled(onNextOTP == nil || isBusy)
    }

    private var otpState: OTPCodeState? {
        guard let otp = entry.otp else {
            return nil
        }
        return OTPCodeGenerator.makeCodeState(from: otp, now: now)
    }

    private func formattedOTP(_ code: String) -> String {
        guard code.count >= 6 else {
            return code
        }
        let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
        return String(code[..<midpoint]) + " " + String(code[midpoint...])
    }

    static func colorized(_ password: String) -> AttributedString {
        var result = AttributedString()
        for character in password {
            var piece = AttributedString(String(character))
            if character.isNumber {
                piece.foregroundColor = KM.accent
            } else if !character.isLetter {
                piece.foregroundColor = KM.symbolChar
            }
            result.append(piece)
        }
        return result
    }
}

private struct AttachmentPreviewRequest: Identifiable {
    let id = UUID()
    let index: Int
}

struct KMTagChip: View {
    let tag: String
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(KM.tagColor(tag))
                .frame(width: 7, height: 7)
            Text(tag)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(
            Capsule(style: .continuous)
                .fill(KM.subtleFill)
        )
    }
}
