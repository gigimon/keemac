import AppKit
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// Changes the password and/or key file in one go. The current password is always asked for;
/// a generated key file is only written when the change is confirmed.
struct ChangeMasterKeySheet: View {
    @Bindable var viewModel: AppViewModel
    /// The current master key includes a password.
    let hasPassword: Bool
    /// The hardware key the current master key includes.
    var hardwareKey: VaultHardwareKey?
    /// Called after the change with the name of a generated key file, if one was created.
    let onChanged: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum KeyFileMode: Hashable {
        case keep
        case choose
        case generate
        case remove
    }

    private enum HardwareKeyMode: Hashable {
        /// Keep the current one, or stay without one ("None").
        case keep
        /// Pick another one, or add one ("Add").
        case choose
        case remove
    }

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var revealsPassword = false
    @State private var mode: KeyFileMode = .keep
    /// The file picked with Choose…, or where Generate… will write the new one.
    @State private var keyFileURL: URL?
    @State private var hardwareMode: HardwareKeyMode = .keep
    @State private var chosenHardwareKey: VaultHardwareKey?
    @State private var currentPasswordError: String?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focusesCurrentPassword: Bool

    private var mismatch: Bool {
        !confirmPassword.isEmpty && newPassword != confirmPassword
    }

    /// The new master key keeps a hardware key.
    private var keepsHardwareKey: Bool {
        switch hardwareMode {
        case .keep:
            return hardwareKey != nil
        case .choose:
            return true
        case .remove:
            return false
        }
    }

    /// Removing the key file leaves only a password (and maybe a hardware key), so there must be one.
    private var removeNeedsPassword: Bool {
        mode == .remove && !hasPassword && newPassword.isEmpty && !keepsHardwareKey
    }

    /// Removing the hardware key mustn't leave the database without any key.
    private var removeHardwareKeyLeavesNoKey: Bool {
        hardwareMode == .remove && !hasPassword && newPassword.isEmpty
            && (mode == .remove || (mode == .keep && viewModel.selectedKeyFileURL == nil))
    }

    private var changesNothing: Bool {
        newPassword.isEmpty && mode == .keep && hardwareMode == .keep
    }

    private var canSubmit: Bool {
        !isSaving && !mismatch && !removeNeedsPassword && !removeHardwareKeyLeavesNoKey && !changesNothing
            && (newPassword.isEmpty || newPassword == confirmPassword)
            && (mode == .keep || mode == .remove || keyFileURL != nil)
            && (hardwareMode != .choose || chosenHardwareKey != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(KM.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Change Master Key"))
                        .font(.system(size: 15, weight: .bold))
                    Text(viewModel.selectedVaultURL?.lastPathComponent ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                field(L("Current password")) {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(L("Required"), text: $currentPassword)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusesCurrentPassword)
                            .accessibilityIdentifier("changeKey.current")
                            .kmField(focused: focusesCurrentPassword, invalid: currentPasswordError != nil)
                            .onChange(of: currentPassword) { currentPasswordError = nil }
                        if let currentPasswordError {
                            Label(currentPasswordError, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(KM.danger)
                                .accessibilityIdentifier("changeKey.currentError")
                        }
                    }
                }

                field(L("New password")) {
                    HStack(spacing: 6) {
                        Group {
                            if revealsPassword {
                                TextField("", text: $newPassword)
                            } else {
                                SecureField("", text: $newPassword)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("changeKey.new")
                        .kmField()
                        Button {
                            revealsPassword.toggle()
                        } label: {
                            Image(systemName: revealsPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 7, filled: true))
                        .iconHelp(revealsPassword ? L("Hide password") : L("Show password"))
                    }
                }

                field(L("Confirm new password")) {
                    Group {
                        if revealsPassword {
                            TextField("", text: $confirmPassword)
                        } else {
                            SecureField("", text: $confirmPassword)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityIdentifier("changeKey.confirm")
                    .kmField(invalid: mismatch)
                }

                field(nil) {
                    HStack(spacing: 8) {
                        if let strength = PasswordStrength.evaluate(newPassword) {
                            StrengthMeter(strength: strength)
                            Text(strength.level.label)
                                .foregroundStyle(strength.level.color)
                            Text(L("~\(Int(strength.entropyBits)) bits"))
                                .foregroundStyle(KM.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if mismatch {
                            Text(L("Passwords don’t match"))
                                .foregroundStyle(KM.danger)
                        } else if !confirmPassword.isEmpty {
                            Label(L("Match"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(KM.success)
                        }
                    }
                    .font(.system(size: 11))
                }

                field(nil) {
                    Text(L("Leave empty to keep the current password."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }

                field(L("Key file")) {
                    VStack(alignment: .leading, spacing: 6) {
                        KMSegmentedControl(
                            options: [
                                (KeyFileMode.keep, L("keyFile.keep", default: "Keep")),
                                (KeyFileMode.choose, L("Choose…")),
                                (KeyFileMode.generate, L("Generate…")),
                                (KeyFileMode.remove, L("Remove"))
                            ],
                            selection: Binding(get: { mode }, set: { select($0) }),
                            identifierPrefix: "changeKey.keyFile"
                        )
                        keyFileDetails
                    }
                }

                field(L("Hardware key")) {
                    VStack(alignment: .leading, spacing: 6) {
                        KMSegmentedControl(
                            options: hardwareKey == nil
                                ? [(HardwareKeyMode.keep, L("hardwareKey.none", default: "None")), (HardwareKeyMode.choose, L("hardwareKey.add", default: "Add"))]
                                : [
                                    (HardwareKeyMode.keep, L("keyFile.keep", default: "Keep")),
                                    (HardwareKeyMode.choose, L("hardwareKey.choose", default: "Choose")),
                                    (HardwareKeyMode.remove, L("Remove"))
                                ],
                            selection: Binding(get: { hardwareMode }, set: { selectHardwareMode($0) }),
                            identifierPrefix: "changeKey.hardwareKey"
                        )
                        hardwareKeyDetails
                    }
                }
            }
            .padding(.top, 18)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14))
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("changeKey.cancel")
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.mini)
                        }
                        Text(isSaving ? L("Re-encrypting…") : L("Change Master Key"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("changeKey.submit")
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 500)
        .background(KM.sheetBackground)
        .onAppear {
            focusesCurrentPassword = true
        }
    }

    @ViewBuilder
    private var keyFileDetails: some View {
        switch mode {
        case .keep:
            Text(viewModel.selectedKeyFileURL.map { L("Keeps \($0.lastPathComponent).") }
                 ?? L("No key file. The database opens with the password only."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        case .choose, .generate:
            if let keyFileURL {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal")
                            .foregroundStyle(KM.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(keyFileURL.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .accessibilityIdentifier("changeKey.fileName")
                            Text(fileLocation(keyFileURL) + (mode == .generate ? L(" — will be created") : ""))
                                .font(.system(size: 11))
                                .foregroundStyle(KM.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button(L("Change")) {
                            select(mode, force: true)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(KM.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KM.insetFill))
                    if mode == .generate {
                        Label(L("Back up this file: without it the database can’t be opened."), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(KM.warning)
                    }
                }
            }
        case .remove:
            if removeNeedsPassword {
                Label(L("Set a password before removing the key file."), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
            } else {
                Text(L("The database will open with the password only."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var hardwareKeyDetails: some View {
        switch hardwareMode {
        case .keep:
            Text(hardwareKey.map { L("Keeps \($0.shortLabel).") } ?? L("No hardware key."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        case .choose:
            VStack(alignment: .leading, spacing: 6) {
                HardwareKeyPicker(
                    selected: chosenHardwareKey,
                    connected: viewModel.connectedHardwareKeys,
                    isScanning: viewModel.isScanningHardwareKeys,
                    height: 34,
                    cornerRadius: 8,
                    alwaysExpanded: true,
                    isDisabled: isSaving,
                    identifierPrefix: "changeKey.hardwareKey",
                    onSelect: { chosenHardwareKey = $0 },
                    onRefresh: { Task { await viewModel.refreshHardwareKeys() } }
                )
                Label(L("Make sure you have a backup YubiKey programmed with the same secret, or another way to unlock."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .remove:
            if removeHardwareKeyLeavesNoKey {
                Label(L("Set a password before removing the hardware key."), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
            } else {
                Text(L("The database will open without the hardware key."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
        }
    }

    private func selectHardwareMode(_ newMode: HardwareKeyMode) {
        hardwareMode = newMode
        chosenHardwareKey = nil
        if newMode == .choose {
            Task { await viewModel.refreshHardwareKeys() }
        }
    }

    private func field<Content: View>(_ label: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label ?? "")
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 132, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileLocation(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        return FileManager.default.displayName(atPath: folder.path)
    }

    /// Choose… and Generate… ask for a file right away; cancelling the panel keeps the previous choice.
    private func select(_ newMode: KeyFileMode, force: Bool = false) {
        guard newMode != mode || force else {
            return
        }
        switch newMode {
        case .keep, .remove:
            mode = newMode
            keyFileURL = nil
        case .choose:
            if let url = chooseKeyFile() {
                mode = .choose
                keyFileURL = url
            }
        case .generate:
            if let url = askWhereToSaveKeyFile() {
                mode = .generate
                keyFileURL = url
            }
        }
    }

    private func chooseKeyFile() -> URL? {
        if UITesting.isActive, let url = UITesting.keyFileURL {
            return url
        }
        let panel = NSOpenPanel()
        panel.title = L("Choose a key file")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func askWhereToSaveKeyFile() -> URL? {
        if UITesting.isActive, let url = UITesting.keyFileURL {
            return url
        }
        let panel = NSSavePanel()
        panel.title = L("Save the new key file")
        let base = viewModel.selectedVaultURL?.deletingPathExtension().lastPathComponent ?? "KeeMac"
        panel.nameFieldStringValue = "\(base).keyx"
        panel.allowedContentTypes = [UTType(filenameExtension: "keyx") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func submit() async {
        guard canSubmit else {
            return
        }
        guard !currentPassword.isEmpty || viewModel.selectedKeyFileURL != nil || hardwareKey != nil else {
            currentPasswordError = L("Enter the current password.")
            return
        }
        let change: VaultKeyFileChange
        switch mode {
        case .keep:
            change = .keep
        case .remove:
            change = .remove
        case .choose:
            guard let keyFileURL else { return }
            change = .use(keyFileURL)
        case .generate:
            guard let keyFileURL else { return }
            change = .generate(keyFileURL)
        }

        isSaving = true
        errorMessage = nil
        do {
            let hardwareChange: VaultHardwareKeyChange
            switch hardwareMode {
            case .keep:
                hardwareChange = .keep
            case .choose:
                guard let chosenHardwareKey else { return }
                hardwareChange = .use(chosenHardwareKey)
            case .remove:
                hardwareChange = .remove
            }
            try await viewModel.changeMasterKey(
                currentPassword: currentPassword,
                newPassword: newPassword,
                keyFile: change,
                hardwareKey: hardwareChange
            )
            isSaving = false
            onChanged(mode == .generate ? keyFileURL?.lastPathComponent : nil)
            dismiss()
        } catch VaultError.wrongCurrentPassword {
            isSaving = false
            currentPasswordError = VaultError.wrongCurrentPassword.errorDescription
        } catch VaultError.hardwareKeyCancelled {
            isSaving = false
        } catch {
            isSaving = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Operation failed.")
        }
    }
}
