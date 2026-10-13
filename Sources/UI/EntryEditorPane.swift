import AppKit
import Domain
import SwiftUI
import UniformTypeIdentifiers

struct EntryEditorPane: View {
    let entry: VaultEntry
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (VaultEntryForm) -> Void
    /// Title of the entry a `{REF:…}` points to.
    let referenceTitle: (UUID) -> String?
    /// Shows the shared confirm dialog: title, message, confirm button title, action.
    let onConfirm: (_ title: String, _ message: String, _ confirmTitle: String, _ action: @escaping () -> Void) -> Void
    /// Entries of the database, for "Insert Reference".
    let referenceEntries: [VaultEntry]
    /// Leaves the editor and shows another entry ("Go to Entry" on a linked field).
    let onOpenEntry: (UUID) -> Void
    private let initialForm: VaultEntryForm

    private struct ReferencePickerRequest: Identifiable {
        let field: VaultFieldReference.Field
        let current: VaultFieldReference?
        var id: String { field.rawValue }
    }

    @State private var referencePicker: ReferencePickerRequest?
    /// Field under the pointer, to show its "Insert Reference" button.
    @State private var hoveredReferenceField: VaultFieldReference.Field?

    @State private var form: VaultEntryForm
    @State private var tagsText: String
    @State private var otpInput: String
    @State private var showOTPOptions = false
    /// Several one-time passwords in one QR image: the user picks one.
    @State private var qrCodeChoices: [OTPQRCode] = []
    @State private var isOTPDropTargeted = false
    @State private var showAppearance = false
    @State private var revealPassword = true
    @State private var validationMessage: String?
    @State private var baselineModifiedAt: Date?
    @State private var isConflictNoticeDismissed = false
    @State private var showTheirVersion = false
    @State private var attachmentStatus: [String: AttachmentEditStatus] = [:]
    @State private var renamingAttachment: String?
    @State private var renameText = ""
    @State private var isDropTargeted = false
    @FocusState private var isRenameFocused: Bool
    @FocusState private var focusedField: Field?
    /// Focus of completing fields (AppKit text fields), which `@FocusState` can't hold.
    @State private var completingFocus: Field?
    @Environment(\.fieldCompletions) private var completions

    /// The last value the generator put into the password field.
    @State private var generatedPassword: String?

    private enum Field: Hashable {
        case title
        case username
        case password
        case url
        case otp
        case tags
        case notes
    }

    init(
        entry: VaultEntry,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (VaultEntryForm) -> Void,
        referenceTitle: @escaping (UUID) -> String? = { _ in nil },
        referenceEntries: [VaultEntry] = [],
        onOpenEntry: @escaping (UUID) -> Void = { _ in },
        onConfirm: @escaping (_ title: String, _ message: String, _ confirmTitle: String, _ action: @escaping () -> Void) -> Void
    ) {
        self.referenceEntries = referenceEntries
        self.onOpenEntry = onOpenEntry
        self.entry = entry
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        self.referenceTitle = referenceTitle
        self.onConfirm = onConfirm
        let form = VaultEntryForm(entry: entry)
        initialForm = form
        _form = State(initialValue: form)
        _tagsText = State(initialValue: form.tags.joined(separator: ", "))
        _otpInput = State(initialValue: form.otp?.secret ?? "")
        _showOTPOptions = State(initialValue: (form.otp?.kind ?? .totp) != .totp)
        _baselineModifiedAt = State(initialValue: entry.modifiedAt)
    }

    var body: some View {
        editorContent
            .sheet(item: $referencePicker) { request in
                ReferencePickerSheet(
                    entries: referenceEntries,
                    currentEntryID: entry.id,
                    currentTitle: form.title.isEmpty ? entry.title : form.title,
                    targetField: request.field,
                    initial: request.current
                ) { reference in
                    setFormValue(reference.text, for: request.field)
                }
            }
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if changedElsewhere && !isConflictNoticeDismissed {
                    conflictNotice
                        .padding(.top, 18)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(KM.danger)
                        .padding(.top, 12)
                        .padding(.leading, 76)
                }

                VStack(alignment: .leading, spacing: 10) {
                    row(L("username")) {
                        if let reference = VaultFieldReference(form.username) {
                            linkedField(.username, reference: reference)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                CompletingTextField("", text: $form.username, suggestions: completions.usernames, isFocused: focusBinding(.username))
                                    .fieldIdentifier("editor.username")
                                    .padding(.trailing, 22)
                                    .kmField(focused: isFieldFocused(.username))
                                    .overlay(alignment: .trailing) {
                                        insertReferenceButton(.username, size: 24, revealsOnHover: true)
                                            .padding(.trailing, 3)
                                    }
                                    .onHover { hoveredReferenceField = $0 ? .username : nil }
                                referenceHint(VaultEntryReferences.username, value: form.username)
                            }
                        }
                    }

                    row(L("password")) {
                        if let reference = VaultFieldReference(form.password) {
                            linkedField(.password, reference: reference)
                        } else {
                        HStack(spacing: 6) {
                            Group {
                                if revealPassword {
                                    TextField("", text: $form.password)
                                } else {
                                    SecureField("", text: $form.password)
                                }
                            }
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusedField, equals: .password)
                            .accessibilityIdentifier("editor.password")
                            .kmField(focused: focusedField == .password)

                            Button {
                                revealPassword.toggle()
                            } label: {
                                Image(systemName: revealPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(KMIconButtonStyle(cornerRadius: 7, tint: KM.textPrimary, filled: true))
                            .iconHelp(revealPassword ? L("Hide password") : L("Show password"))

                            Button {
                                regeneratePassword()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(KMIconButtonStyle(cornerRadius: 7, tint: KM.textPrimary, filled: true))
                            .iconHelp(L("Generate password"))

                            insertReferenceButton(.password, size: 30, revealsOnHover: false)
                        }
                        }
                    }

                    if entry.references?.rawValues[VaultEntryReferences.password] == form.password, VaultFieldReference(form.password) == nil {
                        row(nil) {
                            referenceHint(VaultEntryReferences.password, value: form.password)
                        }
                    }

                    if VaultFieldReference(form.password) == nil {
                        row(nil) {
                            PasswordGeneratorPanel(
                                password: strengthPassword,
                                isGenerated: form.password == generatedPassword
                            ) { value in
                                form.password = value
                                generatedPassword = value
                                revealPassword = true
                            }
                        }
                    }

                    row(L("website")) {
                        if let reference = VaultFieldReference(form.url) {
                            linkedField(.url, reference: reference)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                CompletingTextField("example.com", text: $form.url, suggestions: completions.urls, isFocused: focusBinding(.url))
                                    .fieldIdentifier("editor.url")
                                    .padding(.trailing, 22)
                                    .kmField(focused: isFieldFocused(.url))
                                    .overlay(alignment: .trailing) {
                                        insertReferenceButton(.url, size: 24, revealsOnHover: true)
                                            .padding(.trailing, 3)
                                    }
                                    .onHover { hoveredReferenceField = $0 ? .url : nil }
                                referenceHint(VaultEntryReferences.url, value: form.url)
                            }
                        }
                    }

                    row(L("TOTP secret")) {
                        HStack(spacing: 6) {
                            TextField(L("Base32 secret or otpauth:// URI"), text: $otpInput)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($focusedField, equals: .otp)
                                .kmField(focused: focusedField == .otp)
                                .onChange(of: otpInput) { _, newValue in
                                    form.otp = OTPInputParser.apply(newValue, to: form.otp)
                                    if let kind = form.otp?.kind, kind != .totp {
                                        showOTPOptions = true
                                    }
                                    if newValue.lowercased().hasPrefix("otpauth://"), let secret = form.otp?.secret {
                                        otpInput = secret
                                    }
                                }

                            qrCodeMenu

                            Button {
                                showOTPOptions.toggle()
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(KMIconButtonStyle(cornerRadius: 7, tint: showOTPOptions ? KM.accent : KM.textPrimary, filled: true))
                            .iconHelp(L("TOTP options"))
                            .disabled(form.otp == nil)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(KM.accent, lineWidth: isOTPDropTargeted ? 2 : 0)
                                .padding(-3)
                        )
                        .onDrop(of: [.image, .fileURL], isTargeted: $isOTPDropTargeted, perform: readDroppedQRCode)
                    }
                    .confirmationDialog(
                        L("Several one-time passwords were found"),
                        isPresented: Binding(get: { !qrCodeChoices.isEmpty }, set: { if !$0 { qrCodeChoices = [] } })
                    ) {
                        ForEach(qrCodeChoices) { code in
                            Button(code.label.isEmpty ? code.uri : code.label) {
                                useQRCode(code)
                            }
                        }
                    } message: {
                        Text(L("Choose the account for this entry."))
                    }

                    if showOTPOptions, form.otp != nil {
                        row(nil) {
                            otpOptions
                        }
                    }

                    row(L("tags")) {
                        CompletingTextField(
                            text: $tagsText,
                            placeholder: L("Comma separated"),
                            completer: { [tags = completions.tags] in FieldCompletions.completeTag($0, from: tags) },
                            isFocused: focusBinding(.tags)
                        )
                        .kmField(focused: isFieldFocused(.tags))
                    }

                    row(L("expires")) {
                        HStack(spacing: 10) {
                            KMCheckbox(title: L("Expires on"), isOn: Binding(
                                get: { form.expiresAt != nil },
                                set: { isOn in
                                    form.expiresAt = isOn
                                        ? Calendar.current.date(byAdding: .year, value: 1, to: .now)
                                        : nil
                                }
                            ))
                            if form.expiresAt != nil {
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { form.expiresAt ?? .now },
                                        set: { form.expiresAt = $0 }
                                    ),
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .fixedSize()
                            }
                        }
                    }

                    row(L("health check")) {
                        KMCheckbox(title: L("Include this password in the password health report"), isOn: $form.checksPasswordQuality)
                    }

                    row(L("notes"), alignTop: VaultFieldReference(form.notes) == nil) {
                        if let reference = VaultFieldReference(form.notes) {
                            linkedField(.notes, reference: reference)
                        } else {
                            TextEditor(text: $form.notes)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .focused($focusedField, equals: .notes)
                                .padding(.vertical, 6)
                                .frame(minHeight: 96)
                                .kmField(focused: focusedField == .notes, height: nil, horizontalPadding: 6)
                                .overlay(alignment: .topTrailing) {
                                    insertReferenceButton(.notes, size: 24, revealsOnHover: true)
                                        .padding(3)
                                }
                                .onHover { hoveredReferenceField = $0 ? .notes : nil }
                        }
                    }

                    row(L("attachments"), alignTop: !form.attachments.isEmpty) {
                        attachmentsEditor
                    }

                    row(L("ssh agent"), alignTop: true) {
                        SSHAgentEditorSection(form: $form)
                    }

                    row(L("custom fields"), alignTop: !form.customFields.isEmpty) {
                        customFieldsEditor
                    }

                    row(L("appearance"), alignTop: showAppearance) {
                        appearanceEditor
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            completingFocus = .title
        }
    }

    /// The entry was rewritten by a merge from another device after editing started.
    private var changedElsewhere: Bool {
        guard let current = entry.modifiedAt, let baseline = baselineModifiedAt else {
            return false
        }
        return abs(current.timeIntervalSince(baseline)) >= 1
    }

    private var conflictNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
            Text(L("This entry was changed on another device. Saving keeps your version; the other one goes to history."))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Show Their Version")) {
                showTheirVersion.toggle()
            }
            .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontSize: 12))
            .popover(isPresented: $showTheirVersion, arrowEdge: .bottom) {
                theirVersion
            }
            Button {
                isConflictNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 12))
            .iconHelp(L("Dismiss"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KM.warning.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(KM.warning.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var theirVersion: some View {
        let rows: [(label: String, yours: String, theirs: String, masked: Bool)] = [
            (L("username"), form.username, entry.username ?? "", false),
            (L("password"), form.password, entry.password ?? "", true),
            (L("website"), form.url, entry.url?.absoluteString ?? "", false),
            (L("notes"), form.notes, entry.notes ?? "", false)
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 76, height: 1)
                Text(L("Yours (unsaved)")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Theirs · \(RelativeDateFormatter.modified(entry.modifiedAt))")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(KM.textSecondary)
            .padding(.bottom, 6)

            ForEach(rows, id: \.label) { row in
                let differs = row.yours != row.theirs
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(differs ? KM.warning : Color.clear)
                            .frame(width: 6, height: 6)
                        Text(row.label)
                    }
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 76, alignment: .leading)
                    Text(display(row.yours, masked: row.masked))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(display(row.theirs, masked: row.masked))
                        .fontWeight(differs ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .lineLimit(3)
                .padding(.vertical, 6)
                .overlay(alignment: .top) {
                    Rectangle().fill(KM.hairline).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 440)
    }

    private func display(_ value: String, masked: Bool) -> String {
        if value.isEmpty {
            return "—"
        }
        return masked ? String(repeating: "•", count: 12) : value
    }

    private var header: some View {
        HStack(spacing: 16) {
            LetterTile(
                title: form.title,
                size: 60,
                cornerRadius: 15,
                fontSize: 26,
                colorHex: form.backgroundColorHex,
                iconPNGData: form.iconID == entry.iconID ? entry.iconPNGData : nil,
                iconID: form.iconID
            )

            CompletingTextField(
                L("Title"),
                text: $form.title,
                suggestions: completions.titles,
                font: .systemFont(ofSize: 22, weight: .bold),
                isFocused: focusBinding(.title)
            )
                .fieldIdentifier("editor.title")
                .kmField(
                    focused: isFieldFocused(.title),
                    height: 40,
                    cornerRadius: 9,
                    background: Color(light: .black(0.04), dark: .white(0.06))
                )
                .padding(.leading, -10)

            Button(L("Cancel"), action: onCancel)
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 32, horizontalPadding: 14))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor.cancel")

            Button(L("Save"), action: submit)
                .buttonStyle(KMButtonStyle(kind: .primary, height: 32, horizontalPadding: 18, fontWeight: .semibold))
                .accessibilityIdentifier("editor.save")
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isSaving)
        }
    }

    private var otpOptions: some View {
        let kind = form.otp?.kind ?? .totp
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                KMSegmentedControl(
                    options: [(VaultOTPKind.totp, "TOTP"), (.hotp, "HOTP"), (.steam, "Steam")],
                    selection: otpKindBinding,
                    fontSize: 11,
                    horizontalPadding: 10,
                    identifierPrefix: "editor.otpKind"
                )

                Spacer(minLength: 0)

                // HOTP is always stored in KeePass's own fields.
                if kind != .hotp {
                    Picker("", selection: otpBinding(\.storageStyle, default: .otpAuth)) {
                        Text(L("otpauth URL")).tag(VaultOTPStorageStyle.otpAuth)
                        Text(L("Native TimeOTP")).tag(VaultOTPStorageStyle.native)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            // Steam Guard codes have fixed settings.
            if kind != .steam {
                HStack(spacing: 12) {
                    Picker("", selection: otpBinding(\.algorithm, default: .sha1)) {
                        Text("SHA-1").tag(VaultOTPAlgorithm.sha1)
                        Text("SHA-256").tag(VaultOTPAlgorithm.sha256)
                        Text("SHA-512").tag(VaultOTPAlgorithm.sha512)
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    Stepper(L("\(form.otp?.digits ?? 6) digits"), value: otpBinding(\.digits, default: 6), in: 6...9)
                    if kind == .hotp {
                        HStack(spacing: 6) {
                            Text(L("Counter"))
                            TextField("", value: otpBinding(\.counter, default: 0), format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 64)
                                .accessibilityIdentifier("editor.otpCounter")
                            Stepper("", value: otpBinding(\.counter, default: 0), in: 0...Int.max)
                                .labelsHidden()
                        }
                    } else {
                        Stepper(L("\(form.otp?.period ?? 30)s"), value: otpBinding(\.period, default: 30), in: 1...120)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KM.insetFill)
        )
    }

    /// Leaving Steam brings back the usual settings; its own are fixed.
    private var otpKindBinding: Binding<VaultOTPKind> {
        Binding(
            get: { form.otp?.kind ?? .totp },
            set: { kind in
                guard var otp = form.otp, otp.kind != kind else {
                    return
                }
                if otp.kind == .steam {
                    otp.digits = 6
                    otp.period = 30
                }
                otp.kind = kind
                form.otp = otp
            }
        )
    }

    /// A password that still is the stored reference is rated by the value it points to.
    private var strengthPassword: String {
        if let reference = VaultFieldReference(form.password) {
            return referenceEntries.first { $0.id == reference.entryID }?.value(of: reference.field) ?? ""
        }
        if form.password == entry.rawValue(VaultEntryReferences.password) {
            return entry.password ?? ""
        }
        return form.password
    }

    // MARK: - References

    private func formValue(_ field: VaultFieldReference.Field) -> String {
        switch field {
        case .title: return form.title
        case .username: return form.username
        case .password: return form.password
        case .url: return form.url
        case .notes: return form.notes
        }
    }

    private func setFormValue(_ value: String, for field: VaultFieldReference.Field) {
        switch field {
        case .title: form.title = value
        case .username: form.username = value
        case .password: form.password = value
        case .url: form.url = value
        case .notes: form.notes = value
        }
    }

    /// The link button that opens "Insert Reference" for a field.
    private func insertReferenceButton(_ field: VaultFieldReference.Field, size: CGFloat, revealsOnHover: Bool) -> some View {
        Button {
            referencePicker = ReferencePickerRequest(field: field, current: nil)
        } label: {
            Image(systemName: "link")
                .font(.system(size: 13))
        }
        .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size >= 30 ? 7 : 6, tint: revealsOnHover ? KM.textSecondary : KM.textPrimary, filled: !revealsOnHover))
        .iconHelp(L("Insert Reference…"))
        .opacity(!revealsOnHover || hoveredReferenceField == field ? 1 : 0)
        .disabled(referenceEntries.count < 2)
    }

    /// A field that mirrors another entry: where it comes from, the value, and what can be done with it.
    @ViewBuilder
    private func linkedField(_ field: VaultFieldReference.Field, reference: VaultFieldReference) -> some View {
        if let source = referenceEntries.first(where: { $0.id == reference.entryID }) {
            let value = source.value(of: reference.field)
            HStack(spacing: 8) {
                Button {
                    goToEntry(source.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("From “\(source.title)” · \(reference.field.title)"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KM.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule(style: .continuous).fill(KM.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(L("Go to Entry"))
                Text(field == .password ? String(repeating: "•", count: 12) : (value.components(separatedBy: .newlines).first ?? ""))
                    .font(.system(size: 13, design: field == .password ? .monospaced : .default))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button(L("Go to Entry")) {
                        goToEntry(source.id)
                    }
                    Button(L("Change Reference…")) {
                        referencePicker = ReferencePickerRequest(field: field, current: reference)
                    }
                    Divider()
                    Button(L("Unlink")) {
                        setFormValue(value, for: field)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .iconHelp(L("Reference"))
            }
            .padding(.leading, 4)
            .kmField(horizontalPadding: 4)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(KM.warning)
                Text(L("Linked entry is missing"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Unlink")) {
                    setFormValue("", for: field)
                }
                .buttonStyle(KMButtonStyle(kind: .raised, height: 22, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.warning.opacity(0.12)))
        }
    }

    /// Leaves the editor for the linked entry, asking first when there are unsaved changes.
    private func goToEntry(_ id: UUID) {
        guard form != initialForm else {
            onOpenEntry(id)
            return
        }
        onConfirm(
            L("Discard changes?"),
            L("Your changes to “\(entry.title)” aren’t saved."),
            L("Discard")
        ) {
            onOpenEntry(id)
        }
    }

    /// "Uses the value from “Mail”" under a field that still holds its stored reference.
    @ViewBuilder
    private func referenceHint(_ field: String, value: String) -> some View {
        if let references = entry.references, value == references.rawValues[field], VaultFieldReference(value) == nil {
            let text: String = {
                if references.brokenFields.contains(field) {
                    return L("Broken reference: the entry it points to no longer exists")
                }
                if let source = references.sources[field] {
                    return L("Uses the value from “\(referenceTitle(source) ?? L("another entry"))”. Typing replaces the reference.")
                }
                return L("Contains placeholders, filled in when shown or copied")
            }()
            Label(text, systemImage: references.brokenFields.contains(field) ? "exclamationmark.triangle" : "arrow.up.right")
                .font(.system(size: 11))
                .foregroundStyle(references.brokenFields.contains(field) ? KM.danger : KM.textSecondary)
        }
    }

    /// Focus for completing fields (AppKit text fields), kept in sync with `focusedField`.
    private func focusBinding(_ field: Field) -> Binding<Bool> {
        Binding(
            get: { completingFocus == field },
            set: { isFocused in
                if isFocused {
                    completingFocus = field
                } else if completingFocus == field {
                    completingFocus = nil
                }
            }
        )
    }

    private func isFieldFocused(_ field: Field) -> Bool {
        focusedField == field || completingFocus == field
    }

    // MARK: - QR codes

    private var qrCodeMenu: some View {
        Menu {
            Button {
                ScreenQRCodeScanner.scan { outcome in
                    switch outcome {
                    case .image(let image):
                        readQRCode(in: image)
                    case .cancelled:
                        break
                    case .needsPermission:
                        onConfirm(
                            L("Allow KeeMac to read the screen"),
                            L("To select a QR code on screen, turn on KeeMac in System Settings → Privacy & Security → Screen Recording, then reopen KeeMac. The selected area stays on this Mac and is deleted right after reading."),
                            L("Open System Settings")
                        ) {
                            ScreenQRCodeScanner.openPrivacySettings()
                        }
                    }
                }
            } label: {
                Label(L("Select QR Code on Screen…"), systemImage: "viewfinder")
            }
            Button {
                if let image = OTPQRCodeReader.imageFromPasteboard() {
                    readQRCode(in: image)
                }
            } label: {
                Label(L("Paste QR Code Image"), systemImage: "doc.on.clipboard")
            }
            .disabled(!OTPQRCodeReader.pasteboardHasImage)
            Button {
                if let image = OTPQRCodeReader.chooseImage() {
                    readQRCode(in: image)
                }
            } label: {
                Label(L("Choose Image…"), systemImage: "photo")
            }
        } label: {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 13))
                .foregroundStyle(KM.textPrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.subtleFill))
                .contentShape(Rectangle())
                .accessibilityLabel(L("Add from QR Code"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .iconHelp(L("Add from QR Code — or drop an image here"))
    }

    private func readQRCode(in image: CGImage) {
        switch OTPQRCodeReader.read(image) {
        case .found(let codes):
            if codes.count == 1, let code = codes.first {
                useQRCode(code)
            } else {
                qrCodeChoices = codes
            }
        case .authenticatorExport:
            validationMessage = L("This is a Google Authenticator export with several accounts. Importing exports isn't supported yet.")
        case .nothingFound:
            validationMessage = L("No one-time password QR code found.")
        }
    }

    private func useQRCode(_ code: OTPQRCode) {
        qrCodeChoices = []
        validationMessage = nil
        otpInput = code.uri
        if form.username.trimmingCharacters(in: .whitespaces).isEmpty, let account = code.account {
            form.username = account
        }
        CopyFeedbackCenter.shared.show(L("One-time password added from QR code"), duration: 2.4)
    }

    private func readDroppedQRCode(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    return
                }
                Task { @MainActor in
                    if let image = OTPQRCodeReader.image(from: data) {
                        readQRCode(in: image)
                    } else {
                        validationMessage = L("No one-time password QR code found.")
                    }
                }
            }
            return true
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else {
                return
            }
            Task { @MainActor in
                if let image = OTPQRCodeReader.image(from: data) {
                    readQRCode(in: image)
                }
            }
        }
        return true
    }

    private var attachmentsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(form.attachments) { attachment in
                attachmentEditorRow(attachment)
            }

            HStack(spacing: 10) {
                Button {
                    importAttachments()
                } label: {
                    Label(L("Add File…"), systemImage: "paperclip")
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                Text(isDropTargeted ? L("Drop to attach") : L("or drop files here"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDropTargeted ? KM.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isDropTargeted ? KM.accent : KM.fieldBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else {
                            return
                        }
                        Task { @MainActor in
                            addAttachments(from: [url])
                        }
                    }
                }
                return true
            }
        }
    }

    private func attachmentEditorRow(_ attachment: VaultAttachment) -> some View {
        HStack(spacing: 10) {
            AttachmentTile(attachment: attachment, width: 24, height: 28, symbolSize: 13)
            if renamingAttachment == attachment.name {
                TextField("", text: $renameText)
                    .focused($isRenameFocused)
                    .onSubmit { commitRename(of: attachment) }
                    .onExitCommand { renamingAttachment = nil }
                    .kmField(focused: true, height: 26, cornerRadius: 6, horizontalPadding: 8)
                Text(L("Return to rename"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(attachment.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let status = attachmentStatus[attachment.name] {
                            Text(status.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(KM.accent)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule(style: .continuous).fill(KM.accent.opacity(0.12)))
                        }
                    }
                    Text(AttachmentInfo.meta(attachment))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    renameText = attachment.name
                    renamingAttachment = attachment.name
                    isRenameFocused = true
                } label: {
                    Image(systemName: "pencil").font(.system(size: 13))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 8))
                .iconHelp(L("Rename"))
                Button {
                    replaceAttachment(attachment)
                } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 12))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 8))
                .iconHelp(L("Replace with Another File…"))
                Button {
                    onConfirm(
                        L("Remove “\(attachment.name)”?"),
                        L("The file is removed from this entry when you save."),
                        L("Remove")
                    ) {
                        form.attachments.removeAll { $0.name == attachment.name }
                        attachmentStatus[attachment.name] = nil
                    }
                } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 8))
                .iconHelp(L("Remove"))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minHeight: 42)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(KM.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(KM.softBorder, lineWidth: 0.5)
        )
    }

    private func commitRename(of attachment: VaultAttachment) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingAttachment = nil
        guard !newName.isEmpty, newName != attachment.name else {
            return
        }
        guard !form.attachments.contains(where: { $0.name == newName }) else {
            validationMessage = L("An attachment named “\(newName)” already exists.")
            return
        }
        guard let index = form.attachments.firstIndex(where: { $0.name == attachment.name }) else {
            return
        }
        form.attachments[index] = VaultAttachment(name: newName, data: attachment.data, isProtected: attachment.isProtected)
        let previous = attachmentStatus.removeValue(forKey: attachment.name)
        attachmentStatus[newName] = previous == .new ? .new : (previous ?? .renamed)
    }

    private func replaceAttachment(_ attachment: VaultAttachment) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L("Replace “\(attachment.name)”")
        guard panel.runModal() == .OK, let url = panel.url,
              let index = form.attachments.firstIndex(where: { $0.name == attachment.name }) else {
            return
        }
        do {
            let data = try Self.readFile(url)
            form.attachments[index] = VaultAttachment(name: attachment.name, data: data, isProtected: attachment.isProtected)
            if attachmentStatus[attachment.name] != .new {
                attachmentStatus[attachment.name] = .replaced
            }
        } catch {
            validationMessage = L("Failed to read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    private var customFieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($form.customFields) { $field in
                HStack(spacing: 6) {
                    TextField(L("Name"), text: $field.key)
                        .kmField()
                        .frame(width: 130)
                    Group {
                        if field.isProtected {
                            SecureField(L("Value"), text: $field.value)
                        } else {
                            CompletingTextField(L("Value"), text: $field.value, suggestions: completions.customValues[field.key] ?? [])
                        }
                    }
                    .kmField()
                    Button {
                        field.isProtected.toggle()
                    } label: {
                        Image(systemName: field.isProtected ? "lock.fill" : "lock.open")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 28, tint: field.isProtected ? KM.accent : KM.textSecondary))
                    .iconHelp(field.isProtected ? L("Protected") : L("Not protected"))
                    Button {
                        let id = field.id
                        form.customFields.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 24, tint: KM.danger))
                    .iconHelp(L("Remove field"))
                }
            }

            Button {
                form.customFields.append(VaultCustomFieldForm(key: "", value: "", isProtected: false))
            } label: {
                Label(L("Add Field"), systemImage: "plus")
            }
            .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
        }
    }

    @ViewBuilder
    private var appearanceEditor: some View {
        if showAppearance {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(L("Tile"))
                        .foregroundStyle(KM.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    ColorSwatchPicker(title: L("Tile color"), selectionHex: $form.backgroundColorHex)
                }
                HStack(spacing: 12) {
                    Text(L("Title"))
                        .foregroundStyle(KM.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    ColorSwatchPicker(title: L("Title color"), selectionHex: $form.foregroundColorHex)
                }
                HStack(spacing: 12) {
                    Text(L("Icon"))
                        .foregroundStyle(KM.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    Button(L("Letter")) {
                        form.iconID = nil
                    }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    .disabled(form.iconID == nil || form.iconID == 0)
                }
                IconPalettePicker(selectedIconID: $form.iconID)
            }
            .font(.system(size: 12))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(KM.insetFill)
            )
        } else {
            Button(L("Icon and Colors…")) {
                showAppearance = true
            }
            .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
        }
    }

    private func row<Content: View>(_ label: String?, alignTop: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 14) {
            Text(label ?? "")
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 110, alignment: .trailing)
                .padding(.top, alignTop ? 7 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func otpBinding<Value>(_ keyPath: WritableKeyPath<VaultOTPForm, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { form.otp?[keyPath: keyPath] ?? defaultValue },
            set: { form.otp?[keyPath: keyPath] = $0 }
        )
    }

    private func regeneratePassword() {
        form.password = PasswordGeneratorSettings.shared.generate()
        generatedPassword = form.password
        revealPassword = true
    }

    private func submit() {
        var result = form
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = EntryFormValidation.parseTags(tagsText)
        result.otp = OTPInputParser.apply(otpInput, to: form.otp)
        // The counter may have moved on (browser fill) while the editor was open; an untouched
        // field mustn't take it back.
        if var otp = result.otp, otp.kind == .hotp, otp.counter == initialForm.otp?.counter,
           let current = entry.otp, current.kind == .hotp, current.counter > UInt64(max(otp.counter, 0)) {
            otp.counter = Int(clamping: current.counter)
            result.otp = otp
        }
        result.customFields = result.customFields.map {
            VaultCustomFieldForm(id: $0.id, key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), value: $0.value, isProtected: $0.isProtected)
        }

        validationMessage = EntryFormValidation.validate(result)
        guard validationMessage == nil else {
            return
        }
        onSave(result)
    }

    private func importAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L("Add Attachments")

        guard panel.runModal() == .OK else {
            return
        }
        addAttachments(from: panel.urls)
    }

    private func addAttachments(from urls: [URL]) {
        do {
            for url in urls {
                let data = try Self.readFile(url)
                let name = url.lastPathComponent
                let existed = form.attachments.contains { $0.name == name }
                form.attachments.removeAll { $0.name == name }
                form.attachments.append(VaultAttachment(name: name, data: data))
                if !existed || attachmentStatus[name] == .new {
                    attachmentStatus[name] = .new
                } else {
                    attachmentStatus[name] = .replaced
                }
            }
            form.attachments.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            validationMessage = L("Failed to import attachment: \(error.localizedDescription)")
        }
    }

    private static func readFile(_ url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

private enum AttachmentEditStatus {
    case new
    case replaced
    case renamed

    var title: String {
        switch self {
        case .new: return L("New")
        case .replaced: return L("Replaced")
        case .renamed: return L("Renamed")
        }
    }
}
