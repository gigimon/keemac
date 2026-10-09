import AppKit
import Domain
import SwiftUI

/// New Entry for every type, and editing of typed (non-login) entries.
struct EntryTypeSheet: View {
    enum Mode {
        case create(groupPath: String?, type: VaultEntryType, template: EntryTemplate?)
        case edit(VaultEntry)
    }

    let mode: Mode
    let groupOptions: [GroupOption]
    let rootPath: String
    let templates: [EntryTemplate]
    let supportsTypes: Bool
    let databaseName: String
    let isSaving: Bool
    let onSubmit: (_ groupPath: String?, _ form: VaultEntryForm) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: VaultEntryType
    @State private var template: EntryTemplate?
    @State private var groupPath: String
    @State private var title = ""
    @State private var username = ""
    @State private var password = ""
    @State private var url = ""
    @State private var notes = ""
    @State private var cardNumber = ""
    @State private var cardExpiry = ""
    @State private var cardCVV = ""
    @State private var cardPIN = ""
    @State private var revealCVV = false
    @State private var revealPIN = false
    @State private var wifiSecurity = "WPA3"
    @State private var host = ""
    @State private var port = "22"
    @State private var privateKey: VaultAttachment?
    @State private var sshDraft = SSHKeyDraft()
    @State private var sshEnabled = true
    @State private var sshHosts: [VaultSSHHost] = []
    @State private var sshConfirmation = AppSettingsStore.shared.sshDefaultConfirmation
    @State private var templateValues: [String: String] = [:]
    @FocusState private var focusedField: String?
    /// Focus of completing fields (AppKit text fields), which `@FocusState` can't hold.
    @State private var completingFocus: String?
    @Environment(\.fieldCompletions) private var completions

    /// The last value the generator put into the password field.
    @State private var generatedPassword: String?

    private static let wifiSecurityOptions = ["WPA3", "WPA2", "WEP", "None"]

    init(
        mode: Mode,
        groupOptions: [GroupOption],
        rootPath: String,
        templates: [EntryTemplate],
        supportsTypes: Bool,
        databaseName: String,
        isSaving: Bool,
        onSubmit: @escaping (_ groupPath: String?, _ form: VaultEntryForm) -> Void
    ) {
        self.mode = mode
        self.groupOptions = groupOptions
        self.rootPath = rootPath
        self.templates = templates
        self.supportsTypes = supportsTypes
        self.databaseName = databaseName
        self.isSaving = isSaving
        self.onSubmit = onSubmit

        switch mode {
        case .create(let groupPath, let type, let template):
            _type = State(initialValue: type)
            _template = State(initialValue: template)
            _groupPath = State(initialValue: groupPath ?? "")
        case .edit(let entry):
            let type = entry.effectiveType(supportsTypes: supportsTypes)
            _type = State(initialValue: type)
            _template = State(initialValue: type == .template ? EntryTemplate(entry: entry) : nil)
            _groupPath = State(initialValue: entry.groupPath == rootPath ? "" : entry.groupPath)
            let stored = VaultEntryForm(entry: entry)
            _title = State(initialValue: stored.title)
            _username = State(initialValue: stored.username)
            _password = State(initialValue: stored.password)
            _url = State(initialValue: stored.url)
            _notes = State(initialValue: stored.notes)
            _cardNumber = State(initialValue: CardNumber.formatted(entry.password ?? ""))
            _cardExpiry = State(initialValue: entry.customValue(VaultTypedField.expiry) ?? "")
            _cardCVV = State(initialValue: entry.customValue(VaultTypedField.cvv) ?? "")
            _cardPIN = State(initialValue: entry.customValue(VaultTypedField.pin) ?? "")
            _wifiSecurity = State(initialValue: entry.customValue(VaultTypedField.security) ?? "WPA2")
            _host = State(initialValue: entry.serverAddress.host)
            _port = State(initialValue: entry.serverAddress.port)
            _privateKey = State(initialValue: type == .server ? entry.attachments.first : nil)
            if let settings = entry.sshAgent {
                _sshEnabled = State(initialValue: settings.isEnabled)
                _sshHosts = State(initialValue: settings.hosts)
                _sshConfirmation = State(initialValue: settings.confirmation ?? AppSettingsStore.shared.sshDefaultConfirmation)
            }
            if type == .sshKey, let key = entry.sshKeyAttachment {
                _sshDraft = State(initialValue: SSHKeyDraft.reading(key.data, name: key.name, passphrase: entry.password ?? ""))
            }
            _templateValues = State(initialValue: Dictionary(
                entry.customFields.map { ($0.key, entry.rawValue($0.key) ?? $0.value) },
                uniquingKeysWith: { first, _ in first }
            ))
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private var typeLabel: String {
        type == .template ? (template?.title ?? L("Entry")) : type.label
    }

    /// Wi-Fi and servers fall back to the network name or host when the title is empty.
    private var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch type {
        case .wifi: return username.trimmingCharacters(in: .whitespacesAndNewlines)
        case .server: return host.trimmingCharacters(in: .whitespacesAndNewlines)
        case .sshKey:
            if let comment = sshDraft.publicKey?.comment, !comment.isEmpty {
                return comment
            }
            return sshDraft.attachment?.name ?? ""
        default: return ""
        }
    }

    /// Templates without custom fields behave like logins.
    private var usesLoginFields: Bool {
        type == .login || (type == .template && (template?.fields.isEmpty ?? true))
    }

    private var hasPassword: Bool {
        usesLoginFields || type == .server || (type == .wifi && wifiSecurity != "None")
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 10) {
                row(L("Title")) {
                    CompletingTextField(type.titlePlaceholder, text: $title, suggestions: completions.titles, isFocused: focusBinding("title"))
                        .fieldIdentifier("newEntry.title")
                        .kmField(focused: isFieldFocused("title"), background: KM.raisedFieldBackground)
                }
                typeFields
                if hasPassword {
                    passwordRow
                }
                if usesLoginFields {
                    row(L("Website")) {
                        CompletingTextField("example.com", text: $url, suggestions: completions.urls, isFocused: focusBinding("url"))
                            .fieldIdentifier("newEntry.url")
                            .kmField(focused: isFieldFocused("url"), background: KM.raisedFieldBackground)
                    }
                }
                if type == .server {
                    privateKeyRow
                }
                row(L("Group")) {
                    Picker("", selection: $groupPath) {
                        Text(GroupPathFormatter.title(of: rootPath)).tag("")
                        ForEach(groupOptions) { option in
                            Text(String(repeating: "    ", count: option.depth + 1) + option.title)
                                .tag(option.path)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row(type == .note ? L("Note") : L("Notes"), alignTop: true) {
                    TextEditor(text: $notes)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: "notes")
                        .padding(.vertical, 6)
                        .frame(height: type == .note ? 200 : 66)
                        .kmField(focused: focusedField == "notes", height: nil, background: KM.raisedFieldBackground, horizontalPadding: 6)
                }
            }
            .padding(.top, 18)

            if supportsTypes, let note = type.compatibilityNote(templateName: template?.title) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .padding(.top, 14)
                .padding(.leading, 102)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("newEntry.cancel")

                Button(isEditing ? L("Save") : L("Create"), action: submit)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newEntry.create")
                    .disabled(effectiveTitle.isEmpty || isSaving || (type == .sshKey && !sshDraft.isReady))
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 540)
        .background(KM.sheetBackground)
        .onChange(of: cardNumber) { _, value in
            let formatted = CardNumber.formatted(value)
            if formatted != value { cardNumber = formatted }
        }
        .onChange(of: cardExpiry) { _, value in
            let formatted = CardExpiry.formatInput(value)
            if formatted != value { cardExpiry = formatted }
        }
        .onChange(of: cardCVV) { _, value in
            let digits = Self.digits(value, limit: 4)
            if digits != value { cardCVV = digits }
        }
        .onChange(of: cardPIN) { _, value in
            let digits = Self.digits(value, limit: 8)
            if digits != value { cardPIN = digits }
        }
        .onChange(of: port) { _, value in
            let digits = Self.digits(value, limit: 5)
            if digits != value { port = digits }
        }
        .onAppear {
            if password.isEmpty, !isEditing {
                regenerate()
            }
            completingFocus = "title"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if type == .login {
                LetterTile(title: effectiveTitle, size: 40, cornerRadius: 10, fontSize: 18)
            } else {
                EntryTypeTile(
                    symbol: type == .template ? (template?.symbol ?? type.symbol) : type.symbol,
                    color: type.tileColor,
                    size: 40,
                    cornerRadius: 10
                )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditing ? L("Edit \(typeLabel)") : L("New \(typeLabel)"))
                    .font(.system(size: 15, weight: .bold))
                Text(L("Saved to \(GroupPathFormatter.display(groupPath.isEmpty ? rootPath : groupPath, rootPath: rootPath))"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if supportsTypes, !isEditing {
                typeMenu
            }
        }
    }

    private var typeMenu: some View {
        Menu {
            ForEach(VaultEntryType.builtIns, id: \.self) { candidate in
                Button {
                    switchType(to: candidate, template: nil)
                } label: {
                    Label {
                        Text(candidate.label)
                    } icon: {
                        Image(nsImage: EntryTypeTile.menuImage(symbol: candidate.symbol, color: candidate.tileColor))
                    }
                }
            }
            if !templates.isEmpty {
                Section(L("From \(databaseName)")) {
                    ForEach(templates) { candidate in
                        Button {
                            switchType(to: .template, template: candidate)
                        } label: {
                            Label {
                                Text(candidate.title)
                            } icon: {
                                Image(nsImage: EntryTypeTile.menuImage(symbol: candidate.symbol, color: VaultEntryType.template.tileColor))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: type == .template ? (template?.symbol ?? type.symbol) : type.symbol)
                    .font(.system(size: 11))
                Text(typeLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KM.textSecondary)
            }
            .font(.system(size: 12))
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(KM.raisedButtonBackground))
            .overlay(Capsule(style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help(L("Entry type"))
    }

    private func switchType(to newType: VaultEntryType, template newTemplate: EntryTemplate?) {
        type = newType
        template = newTemplate
        templateValues = [:]
        if hasPassword, password.isEmpty {
            regenerate()
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var typeFields: some View {
        switch type {
        case .login:
            usernameRow(placeholder: "name@example.com")
        case .card:
            cardFields
        case .wifi:
            row(L("Network")) {
                CompletingTextField(L("Network name (SSID)"), text: $username, suggestions: completions.usernames, isFocused: focusBinding("ssid"))
                    .kmField(focused: isFieldFocused("ssid"), background: KM.raisedFieldBackground)
            }
            row(L("Security")) {
                KMSegmentedControl(
                    options: Self.wifiSecurityOptions.map { ($0, $0 == "None" ? L("None") : $0) },
                    selection: $wifiSecurity,
                    fontSize: 12,
                    horizontalPadding: 12
                )
            }
        case .server:
            row(L("Host")) {
                HStack(spacing: 10) {
                    CompletingTextField(L("Hostname or IP address"), text: $host, suggestions: completions.hosts, isFocused: focusBinding("host"))
                        .kmField(focused: isFieldFocused("host"), background: KM.raisedFieldBackground)
                    Text(L("Port"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    TextField("22", text: $port)
                        .focused($focusedField, equals: "port")
                        .kmField(focused: focusedField == "port", background: KM.raisedFieldBackground)
                        .frame(width: 70)
                }
            }
            usernameRow(placeholder: "root")
        case .sshKey:
            row(L("Private key"), alignTop: true) {
                SSHKeyPicker(draft: $sshDraft) { publicKey in
                    let comment = publicKey?.comment ?? ""
                    if title.trimmingCharacters(in: .whitespaces).isEmpty, !comment.isEmpty {
                        title = comment
                    }
                    if username.trimmingCharacters(in: .whitespaces).isEmpty, let user = comment.split(separator: "@").first, comment.contains("@") {
                        username = String(user)
                    }
                }
            }
            usernameRow(placeholder: "git")
            row(L("SSH agent"), alignTop: true) {
                SSHAgentOptions(isEnabled: $sshEnabled, hosts: $sshHosts, confirmation: $sshConfirmation)
                    .padding(.top, 4)
            }
        case .note:
            EmptyView()
        case .template:
            if usesLoginFields {
                usernameRow(placeholder: "name@example.com")
            } else {
                ForEach(template?.fields ?? [], id: \.key) { field in
                    row(field.key) {
                        Group {
                            if field.isProtected {
                                SecureField("", text: templateBinding(field.key))
                                    .font(.system(size: 13, design: .monospaced))
                            } else {
                                CompletingTextField(
                                    "",
                                    text: templateBinding(field.key),
                                    suggestions: completions.customValues[field.key] ?? [],
                                    isFocused: focusBinding("tpl:\(field.key)")
                                )
                            }
                        }
                        .focused($focusedField, equals: "tpl:\(field.key)")
                        .kmField(focused: isFieldFocused("tpl:\(field.key)"), background: KM.raisedFieldBackground)
                    }
                }
            }
        }
    }

    /// Focus for completing fields (AppKit text fields), kept in sync with `focusedField`.
    private func focusBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { completingFocus == key },
            set: { isFocused in
                if isFocused {
                    completingFocus = key
                } else if completingFocus == key {
                    completingFocus = nil
                }
            }
        )
    }

    private func isFieldFocused(_ field: String) -> Bool {
        focusedField == field || completingFocus == field
    }

    private func usernameRow(placeholder: String) -> some View {
        row(L("Username")) {
            CompletingTextField(placeholder, text: $username, suggestions: completions.usernames, isFocused: focusBinding("username"))
                .fieldIdentifier("newEntry.username")
                .kmField(focused: isFieldFocused("username"), background: KM.raisedFieldBackground)
        }
    }

    @ViewBuilder
    private var cardFields: some View {
        let digits = CardNumber.digits(cardNumber)
        let expiryState = CardExpiry.state(cardExpiry)
        row(L("Cardholder")) {
            CompletingTextField(L("Name as shown on the card"), text: $username, suggestions: completions.usernames, isFocused: focusBinding("holder"))
                .kmField(focused: isFieldFocused("holder"), background: KM.raisedFieldBackground)
        }
        row(L("Number"), alignTop: digits.count >= 13 && !CardNumber.passesLuhn(digits)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("1234 5678 9012 3456", text: $cardNumber)
                    .font(.system(size: 13, design: .monospaced))
                    if let brand = CardNumber.brand(digits) {
                        Text(brand)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KM.textSecondary)
                    }
                }
                .focused($focusedField, equals: "number")
                .kmField(focused: focusedField == "number", background: KM.raisedFieldBackground)
                if digits.count >= 13, !CardNumber.passesLuhn(digits) {
                    Label(L("This number doesn’t pass the card check. Look for a typo."), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
                }
            }
        }
        row(L("Expires")) {
            HStack(spacing: 10) {
                TextField(L("MM/YY"), text: $cardExpiry)
                .font(.system(size: 13, design: .monospaced))
                .focused($focusedField, equals: "expiry")
                .kmField(focused: focusedField == "expiry", background: KM.raisedFieldBackground)
                .frame(width: 80)
                Text("CVV")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                secretField("123", text: $cardCVV, reveal: $revealCVV, key: "cvv")
                    .frame(width: 96)
                Spacer(minLength: 0)
                if expiryState == .expired {
                    statusBadge(L("Expired"), color: KM.danger)
                } else if expiryState == .soon {
                    statusBadge(L("Expires soon"), color: Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
                }
            }
        }
        row("PIN") {
            secretField(L("Optional"), text: $cardPIN, reveal: $revealPIN, key: "pin")
                .frame(width: 140)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func secretField(_ placeholder: String, text: Binding<String>, reveal: Binding<Bool>, key: String) -> some View {
        HStack(spacing: 0) {
            Group {
                if reveal.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            Button {
                reveal.wrappedValue.toggle()
            } label: {
                Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(KM.textSecondary)
            .iconHelp(L("Show"))
        }
        .focused($focusedField, equals: key)
        .kmField(focused: focusedField == key, background: KM.raisedFieldBackground)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
    }

    private var passwordRow: some View {
        row(L("Password"), alignTop: true) {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    TextField("", text: $password)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: "password")
                        .accessibilityIdentifier("newEntry.password")
                        .kmField(focused: focusedField == "password", background: KM.raisedFieldBackground)
                    Button(action: regenerate) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(KMIconButtonStyle(cornerRadius: 7, tint: KM.textPrimary, filled: true))
                    .iconHelp(L("Regenerate"))
                }
                PasswordGeneratorPanel(
                    password: password,
                    isGenerated: password == generatedPassword
                ) { value in
                    password = value
                    generatedPassword = value
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(KM.insetFill)
            )
        }
    }

    private var privateKeyRow: some View {
        row(L("Private key")) {
            if let privateKey {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
                    Text(privateKey.name)
                        .font(.system(size: 13))
                    Text(AttachmentInfo.size(privateKey))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        self.privateKey = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
                    .iconHelp(L("Remove"))
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.insetFill))
            } else {
                HStack(spacing: 10) {
                    Button(action: choosePrivateKey) {
                        Label(L("Choose Key File…"), systemImage: "paperclip")
                    }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                    Text(L("Saved as an attachment"))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, alignTop: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(width: 90, alignment: .trailing)
                .padding(.top, alignTop ? 8 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Keeps only digits; done in onChange because a TextField doesn't redraw a transformed binding while it is focused.
    private static func digits(_ value: String, limit: Int) -> String {
        String(value.filter(\.isNumber).prefix(limit))
    }

    private func templateBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { templateValues[key] ?? "" },
            set: { templateValues[key] = $0 }
        )
    }

    // MARK: Actions

    private func regenerate() {
        password = PasswordGeneratorSettings.shared.generate()
        generatedPassword = password
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.title = L("Choose Private Key")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else {
            return
        }
        privateKey = VaultAttachment(name: url.lastPathComponent, data: data)
    }

    private func submit() {
        guard !effectiveTitle.isEmpty else {
            return
        }
        onSubmit(groupPath.isEmpty ? nil : groupPath, makeForm())
    }

    /// Writes the type's values into standard and custom fields; anything else the entry had is kept.
    private func makeForm() -> VaultEntryForm {
        var form: VaultEntryForm
        if case .edit(let entry) = mode {
            form = VaultEntryForm(entry: entry)
        } else {
            form = VaultEntryForm(title: effectiveTitle)
            if type == .template {
                form.iconID = template?.iconID
            }
        }
        form.title = effectiveTitle
        form.notes = notes
        form.entryType = supportsTypes ? type : .login
        form.templateName = type == .template ? template?.title : nil

        var typeKeys = VaultTypedField.keys(for: type)
        var typeFields: [VaultCustomFieldForm] = []

        switch type {
        case .login:
            form.username = username
            form.password = password
            form.url = url
        case .card:
            form.username = username
            form.password = CardNumber.digits(cardNumber)
            typeFields.append(VaultCustomFieldForm(key: VaultTypedField.expiry, value: cardExpiry, isProtected: false))
            typeFields.append(VaultCustomFieldForm(key: VaultTypedField.cvv, value: cardCVV, isProtected: true))
            if !cardPIN.isEmpty {
                typeFields.append(VaultCustomFieldForm(key: VaultTypedField.pin, value: cardPIN, isProtected: true))
            }
        case .wifi:
            form.username = username
            form.password = wifiSecurity == "None" ? "" : password
            typeFields.append(VaultCustomFieldForm(key: VaultTypedField.security, value: wifiSecurity, isProtected: false))
        case .server:
            form.username = username
            form.password = password
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            form.url = trimmedHost.isEmpty ? "" : "ssh://\(trimmedHost):\(port.isEmpty ? "22" : port)"
            if case .edit(let entry) = mode, let previous = entry.attachments.first, previous.name != privateKey?.name {
                form.attachments.removeAll { $0.name == previous.name }
            }
            if let privateKey {
                form.attachments.removeAll { $0.name == privateKey.name }
                form.attachments.insert(privateKey, at: 0)
            }
        case .sshKey:
            form.username = username
            if sshDraft.passphraseState == .saved {
                form.password = sshDraft.passphrase
            } else if sshDraft.passphraseState == .notNeeded, !isEditing {
                form.password = ""
            }
            let previousKey: String?
            if case .edit(let entry) = mode {
                previousKey = entry.sshAgent?.keyAttachmentName
            } else {
                previousKey = nil
            }
            if let previousKey, previousKey != sshDraft.attachment?.name {
                form.attachments.removeAll { $0.name == previousKey }
            }
            if let key = sshDraft.attachment {
                form.attachments.removeAll { $0.name == key.name }
                form.attachments.insert(key, at: 0)
            }
            var settings = form.sshAgent ?? VaultSSHAgentSettings()
            settings.isEnabled = sshEnabled
            settings.keyAttachmentName = sshDraft.attachment?.name
            settings.keyFilePath = nil
            settings.hosts = sshHosts
            settings.confirmation = sshConfirmation
            form.sshAgent = settings
        case .note:
            break
        case .template:
            if usesLoginFields {
                form.username = username
                form.password = password
                form.url = url
            } else {
                for field in template?.fields ?? [] {
                    typeKeys.insert(field.key)
                    typeFields.append(VaultCustomFieldForm(key: field.key, value: templateValues[field.key] ?? "", isProtected: field.isProtected))
                }
            }
        }

        form.customFields.removeAll { typeKeys.contains($0.key) }
        form.customFields.insert(contentsOf: typeFields, at: 0)
        return form
    }
}
