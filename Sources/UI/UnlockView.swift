import AppKit
import Data
import Domain
import SwiftUI
import UniformTypeIdentifiers

enum VaultFilePicker {
    @MainActor
    static func chooseVault(prompt: String = L("Open Database")) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseKeyFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L("Choose Key File")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct UnlockView: View {
    @Bindable var viewModel: AppViewModel
    let statusMessage: String?
    let isError: Bool
    let onCreateDatabase: () -> Void

    @State private var password = ""
    @State private var revealPassword = false
    @State private var isDatabaseMenuOpen = false
    @State private var fileInfo: VaultFileInfo?
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        ZStack {
            KM.unlockBackground
                .ignoresSafeArea()
                .overlay(WindowDragRegion())
                .onTapGesture {
                    isDatabaseMenuOpen = false
                }

            VStack(spacing: 0) {
                AppIconImage(size: 76)

                Text(headline)
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.2)
                    .lineLimit(1)
                    .padding(.top, 16)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(KM.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                databasePicker
                    .padding(.top, 22)
                    .zIndex(10)

                passwordField
                    .padding(.top, 12)

                keyFileRow
                    .padding(.top, 8)

                HardwareKeyPicker(
                    selected: viewModel.selectedHardwareKey,
                    connected: viewModel.connectedHardwareKeys,
                    isScanning: viewModel.isScanningHardwareKeys,
                    scanError: viewModel.hardwareKeyScanError,
                    isDisabled: isLoading,
                    identifierPrefix: "unlock.hardwareKey",
                    onSelect: { viewModel.selectHardwareKey($0) },
                    onRefresh: { Task { await viewModel.refreshHardwareKeys() } }
                )
                .padding(.top, 8)

                if isError, let statusMessage, !statusMessage.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(statusMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(KM.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("unlock.error")
                    .padding(.top, 10)
                }

                Button(action: unlock) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isLoading ? L("Unlocking…") : L("Unlock"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 38, fullWidth: true, fontWeight: .semibold, fontSize: 14))
                .keyboardShortcut(.defaultAction)
                .disabled(!canUnlock)
                .accessibilityIdentifier("unlock.unlock")
                .padding(.top, 18)

                if canUseTouchID {
                    Button {
                        Task {
                            await viewModel.unlockWithBiometrics()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "touchid")
                                .font(.system(size: 17))
                                .foregroundStyle(KM.touchID)
                            VStack(spacing: 0) {
                                Text(L("Unlock with Touch ID"))
                                if viewModel.selectedHardwareKey != nil && !viewModel.touchIDSkipsHardwareKeyForSelectedVault {
                                    Text(L("Touch ID + YubiKey"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(KM.textSecondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 38, fullWidth: true, fontSize: 14))
                    .disabled(isLoading)
                    .accessibilityIdentifier("unlock.touchID")
                    .padding(.top, 8)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text(fileInfo?.summary ?? L("KeePass KDBX database"))
                }
                .font(.system(size: 11))
                .foregroundStyle(KM.textTertiary)
                .padding(.top, 22)
            }
            .padding(.horizontal, 40)
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(width: 440)
        }
        .onAppear {
            isPasswordFocused = true
        }
        .onChange(of: viewModel.loadState) { _, newState in
            switch newState {
            case .idle, .locked, .failed:
                isPasswordFocused = true
            case .loading, .loaded:
                break
            }
        }
        .onExitCommand {
            isDatabaseMenuOpen = false
        }
        .task(id: viewModel.selectedVaultURL) {
            fileInfo = nil
            guard let url = viewModel.selectedVaultURL else {
                return
            }
            if viewModel.selectedHardwareKey != nil {
                await viewModel.refreshHardwareKeys()
            }
            fileInfo = await Task.detached(priority: .utility) {
                KDBXHeaderReader.read(from: url)
            }.value
        }
    }

    private var headline: String {
        guard let url = viewModel.selectedVaultURL else {
            return L("Welcome to KeeMac")
        }
        return L("Unlock \(url.deletingPathExtension().lastPathComponent)")
    }

    private var subtitle: String {
        if viewModel.selectedVaultURL == nil {
            return L("Choose a KeePass database to get started.")
        }
        if !isError, let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return L("Enter the master key for this database.")
    }

    private var databasePicker: some View {
        Button {
            isDatabaseMenuOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 17))
                    .foregroundStyle(KM.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.selectedVaultURL?.lastPathComponent ?? L("Choose a Database…"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KM.textPrimary)
                        .lineLimit(1)
                    if let url = viewModel.selectedVaultURL {
                        Text(Self.displayDirectory(of: url))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KM.textSecondary)
            }
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(KM.raisedFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(KM.softBorder, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("unlock.databasePicker")
        .overlay(alignment: .topLeading) {
            if isDatabaseMenuOpen {
                databaseMenu
                    .offset(y: 52)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDatabaseMenuOpen)
    }

    private var databaseMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !viewModel.recentVaults.isEmpty {
                Text(L("Recent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KM.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(viewModel.recentVaults) { recent in
                    DatabaseMenuItem(
                        title: recent.title,
                        subtitle: Self.displayDirectory(of: recent.vaultURL),
                        isChecked: recent.vaultURL.standardizedFileURL == viewModel.selectedVaultURL?.standardizedFileURL,
                        usesTouchID: viewModel.isTouchIDEnabled(for: recent.vaultURL),
                        onRemove: { viewModel.removeRecentVault(recent) }
                    ) {
                        isDatabaseMenuOpen = false
                        viewModel.selectRecentVault(recent)
                        password = ""
                        isPasswordFocused = true
                    }
                }

                Rectangle()
                    .fill(KM.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            DatabaseMenuItem(title: L("Open Other Database…"), subtitle: nil, isChecked: false) {
                isDatabaseMenuOpen = false
                chooseVault()
            }
            .accessibilityIdentifier("unlock.openOther")
            DatabaseMenuItem(title: L("New Database…"), subtitle: nil, isChecked: false) {
                isDatabaseMenuOpen = false
                onCreateDatabase()
            }
            .accessibilityIdentifier("unlock.newDatabase")
        }
        .padding(5)
        .frame(width: 360)
        .kmFloatingPanel(cornerRadius: 12, background: KM.menuBackground)
    }

    private var passwordField: some View {
        HStack(spacing: 0) {
            Group {
                if revealPassword {
                    TextField(L("Master Password"), text: $password)
                } else {
                    SecureField(L("Master Password"), text: $password)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isPasswordFocused)
            .onSubmit(unlock)
            .accessibilityIdentifier("unlock.password")

            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
                    .font(.system(size: 14))
            }
            .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 7))
            .iconHelp(revealPassword ? L("Hide password") : L("Show password"))
            .accessibilityIdentifier("unlock.revealPassword")
        }
        .kmField(
            focused: isPasswordFocused,
            height: 38,
            cornerRadius: 10,
            background: KM.raisedFieldBackground,
            horizontalPadding: 12
        )
        .padding(.trailing, 0)
        .disabled(isLoading)
    }

    @ViewBuilder
    private var keyFileRow: some View {
        if let keyFileURL = viewModel.selectedKeyFileURL {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 15))
                    .foregroundStyle(KM.accent)
                Text(keyFileURL.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Key file"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                Button {
                    viewModel.selectKeyFile(url: nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 7))
                .iconHelp(L("Remove key file"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(light: .black(0.04), dark: .white(0.05)))
            )
            .help(keyFileURL.path(percentEncoded: false))
            .disabled(isLoading)
        } else {
            Button {
                chooseKeyFile()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                    Text(L("No key file"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("Choose…"))
                        .fontWeight(.medium)
                        .foregroundStyle(KM.accent)
                }
                .font(.system(size: 13))
                .foregroundStyle(KM.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color(light: .black(0.2), dark: .white(0.2)))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var isLoading: Bool {
        viewModel.loadState == .loading
    }

    private var canUnlock: Bool {
        viewModel.selectedVaultURL != nil
            && (!password.isEmpty || viewModel.selectedKeyFileURL != nil || viewModel.selectedHardwareKey != nil)
            && !isLoading
    }

    private var canUseTouchID: Bool {
        viewModel.showBiometricUnlockScreen
            && viewModel.selectedVaultURL != nil
            && viewModel.touchIDEnabledForSelectedVault
    }

    private func unlock() {
        guard canUnlock else {
            return
        }
        let enteredPassword = password
        password = ""
        Task {
            await viewModel.unlock(masterPassword: enteredPassword)
        }
    }

    private func chooseVault() {
        viewModel.disableBiometricUnlockScreen()
        if let url = VaultFilePicker.chooseVault() {
            viewModel.selectVault(url: url)
            password = ""
        }
        isPasswordFocused = true
    }

    private func chooseKeyFile() {
        if let url = VaultFilePicker.chooseKeyFile() {
            viewModel.selectKeyFile(url: url)
        }
        isPasswordFocused = true
    }

    static func displayDirectory(of url: URL) -> String {
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var result = directory
        if result.hasPrefix(home) {
            result = "~/" + result.dropFirst(home.count)
        }
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

private struct DatabaseMenuItem: View {
    let title: String
    let subtitle: String?
    let isChecked: Bool
    var usesTouchID: Bool = false
    /// Shown as an × on hover and in the context menu for recent databases.
    var onRemove: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .opacity(0.65)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if usesTouchID {
                    Image(systemName: "touchid")
                        .font(.system(size: 14))
                        .opacity(0.65)
                        .iconHelp(L("Touch ID enabled"))
                }
                if let onRemove, isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .iconHelp(L("Remove from Recent"))
                }
            }
            .foregroundStyle(isHovered ? Color.white : KM.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? KM.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let onRemove {
                Button(L("Remove from Recent"), action: onRemove)
            }
        }
        .accessibilityActions {
            if let onRemove {
                Button(L("Remove from Recent"), action: onRemove)
            }
        }
    }
}
