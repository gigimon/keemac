import AppKit
import Data
import SwiftUI
import UniformTypeIdentifiers

private struct WindowAccessorView: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

public struct RootView: View {
    @Bindable private var viewModel: AppViewModel
    @State private var masterPassword: String = ""
    @State private var revealMasterPassword: Bool = false
    @State private var useKeyFileForUnlock: Bool = false
    @State private var rememberDatabaseSelection: Bool = true
    @State private var activityMonitorToken: Any?
    @State private var preferBiometricOnlyUnlock: Bool = false
    @FocusState private var isMasterPasswordFocused: Bool

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loaded(let vault):
                VaultBrowserView(
                    vault: vault,
                    favoriteEntryIDs: viewModel.favoriteEntryIDs,
                    recentViewedEntryIDs: viewModel.recentViewedEntryIDs,
                    includeSubgroupEntries: viewModel.includeSubgroupEntriesInGroupView,
                    onCreateGroup: { parentPath, title, iconID in
                        try await viewModel.createGroup(inParentPath: parentPath, title: title, iconID: iconID)
                    },
                    onUpdateGroup: { path, title, iconID in
                        try await viewModel.updateGroup(path: path, title: title, iconID: iconID)
                    },
                    onDeleteGroup: { path in
                        try await viewModel.deleteGroup(path: path)
                    },
                    onCreateEntry: { groupPath, form in
                        try await viewModel.createEntry(inGroupPath: groupPath, form: form)
                    },
                    onUpdateEntry: { id, form in
                        try await viewModel.updateEntry(id: id, form: form)
                    },
                    onDeleteEntry: { id in
                        try await viewModel.deleteEntry(id: id)
                    },
                    onRestoreEntry: { id in
                        try await viewModel.restoreEntry(id: id)
                    },
                    onRevertEntry: { id, index in
                        try await viewModel.revertEntry(id: id, toHistoryRevisionAt: index)
                    },
                    onToggleFavorite: { id in
                        viewModel.toggleFavorite(entryID: id)
                    },
                    onEntryViewed: { id in
                        viewModel.markEntryViewed(id)
                    },
                    onLockVault: {
                        NotificationCenter.default.post(name: AppCommand.lockVault, object: nil)
                    }
                )
                    .onAppear {
                        startActivityMonitor()
                        viewModel.registerUserActivity()
                    }
                    .onDisappear {
                        stopActivityMonitor()
                    }
            case .loading:
                loadingView
            case .idle:
                unlockView()
            case .locked(let message):
                if shouldShowBiometricOnlyUnlock {
                    biometricUnlockView(statusMessage: message)
                } else {
                    unlockView(statusMessage: message)
                }
            case .failed(let message):
                if shouldShowBiometricOnlyUnlock {
                    biometricUnlockView(statusMessage: message, isError: true)
                } else {
                    unlockView(statusMessage: message, isError: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.loadState)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            viewModel.lockVault(reason: .systemSleep)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openVault)) { _ in
            preferBiometricOnlyUnlock = false
            viewModel.disableBiometricUnlockScreen()
            selectFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.selectKeyFile)) { _ in
            selectKeyFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.clearKeyFile)) { _ in
            viewModel.selectKeyFile(url: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.lockVault)) { _ in
            viewModel.lockVault(reason: .userInitiated)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow else {
                return
            }
            guard MainWindowStore.shared.isMainWindow(window) else {
                return
            }
            viewModel.lockVault(reason: .userInitiated)
            MainWindowStore.shared.clearIfMainWindow(window)
        }
        .onChange(of: viewModel.loadState) { _, newState in
            switch newState {
            case .idle:
                preferBiometricOnlyUnlock = false
                isMasterPasswordFocused = true
            case .locked:
                preferBiometricOnlyUnlock = viewModel.showDockIcon
                isMasterPasswordFocused = true
            case .failed:
                isMasterPasswordFocused = true
            case .loaded:
                preferBiometricOnlyUnlock = false
            case .loading:
                break
            }
            applyWindowLayout(for: newState)
        }
        .onChange(of: viewModel.showDockIcon) { _, showDockIcon in
            if !showDockIcon {
                preferBiometricOnlyUnlock = false
            }
        }
        .onChange(of: viewModel.selectedKeyFileURL) { _, selectedKeyFileURL in
            useKeyFileForUnlock = selectedKeyFileURL != nil
        }
        .background(
            WindowAccessorView { window in
                MainWindowStore.shared.register(window: window)
                applyWindowLayout(for: viewModel.loadState)
            }
        )
        .frame(
            minWidth: minimumWindowWidth,
            idealWidth: idealWindowWidth,
            minHeight: minimumWindowHeight,
            idealHeight: idealWindowHeight
        )
    }

    @ViewBuilder
    private func unlockView(statusMessage: String? = nil, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.95), Color.blue.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: .blue.opacity(0.24), radius: 10, y: 4)
                        Image(systemName: "lock")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.top, 4)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Database Location")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button {
                        selectFile()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive.badge.checkmark")
                                .foregroundStyle(.blue)
                            Text(viewModel.selectedVaultURL?.path(percentEncoded: false) ?? "Select .kdbx file")
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(viewModel.selectedVaultURL == nil ? .secondary : .primary)
                            Spacer(minLength: 8)
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                        .keemacBoxedField()
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()

                    if !viewModel.recentVaults.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(viewModel.recentVaults) { recentVault in
                                    Button(recentVault.title) {
                                        selectRecentVault(recentVault)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .lineLimit(1)
                                    .help(recentVault.vaultURL.path(percentEncoded: false))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Master Password")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .foregroundStyle(.secondary)

                        Group {
                            if revealMasterPassword {
                                TextField("Enter password", text: $masterPassword)
                                    .focused($isMasterPasswordFocused)
                            } else {
                                SecureField("Enter password", text: $masterPassword)
                                    .focused($isMasterPasswordFocused)
                            }
                        }
                        .textFieldStyle(.plain)
                        .onSubmit {
                            unlockVault()
                        }

                        Button {
                            revealMasterPassword.toggle()
                        } label: {
                            Image(systemName: revealMasterPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(revealMasterPassword ? "Hide password" : "Reveal password")
                        .hoverHighlight()
                    }
                    .keemacBoxedField()
                }

                Toggle("Use Key File", isOn: $useKeyFileForUnlock)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: useKeyFileForUnlock) { _, isEnabled in
                        if !isEnabled {
                            viewModel.selectKeyFile(url: nil)
                        }
                    }

                if useKeyFileForUnlock {
                    HStack(spacing: 8) {
                        Button {
                            selectKeyFile()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.blue)
                                Text(viewModel.selectedKeyFileURL?.path(percentEncoded: false) ?? "Select key file")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(viewModel.selectedKeyFileURL == nil ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .keemacBoxedField()
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()

                        if viewModel.selectedKeyFileURL != nil {
                            Button {
                                viewModel.selectKeyFile(url: nil)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear key file")
                            .hoverHighlight(tint: .red)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Toggle("Remember Database", isOn: $rememberDatabaseSelection)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .disabled(true)
                        .opacity(0.95)

                    Spacer()

                    if canUseBiometricUnlock {
                        Button {
                            Task {
                                await viewModel.unlockWithBiometrics()
                            }
                        } label: {
                            Image(systemName: "touchid")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    Circle().strokeBorder(.quaternary)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open by Touch ID")
                        .disabled(isLoading || viewModel.selectedVaultURL == nil)
                        .hoverHighlight()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    unlockVault()
                } label: {
                    Text("Unlock Database")
                        .frame(maxWidth: .infinity)
                }
                .keemacPrimaryActionButton()
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.selectedVaultURL == nil || (masterPassword.isEmpty && viewModel.selectedKeyFileURL == nil) || isLoading)

                if let statusMessage, !statusMessage.isEmpty {
                    statusBanner(statusMessage: statusMessage, isError: isError)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(width: 460)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            useKeyFileForUnlock = viewModel.selectedKeyFileURL != nil
            isMasterPasswordFocused = true
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView("Loading vault...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func biometricUnlockView(statusMessage: String? = nil, isError: Bool = false) -> some View {
        let touchIDEnabledForVault = viewModel.touchIDEnabledForSelectedVault
        let touchIDActionAvailable = canUseBiometricUnlock && touchIDEnabledForVault && !isLoading

        VStack {
            VStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(.secondary)
                    Image(systemName: "lock.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .offset(x: 2, y: 2)
                }
                .padding(.top, 8)

                VStack(spacing: 8) {
                    Text("\(viewModel.selectedVaultURL?.lastPathComponent ?? "Saved Vault") is Locked")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(lockedScreenSubtitle(statusMessage: statusMessage, isError: isError))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    guard touchIDActionAvailable else {
                        return
                    }
                    Task {
                        await viewModel.unlockWithBiometrics()
                    }
                } label: {
                    Image(systemName: "touchid")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.blue)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            Circle().strokeBorder(.quaternary)
                        )
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .keyboardShortcut(.defaultAction)
                .disabled(!touchIDActionAvailable)

                Text(touchIDActionLabel(touchIDEnabledForVault: touchIDEnabledForVault))
                    .font(.headline)
                    .foregroundStyle(touchIDEnabledForVault ? .primary : .secondary)

                Button("Use Password...") {
                    preferBiometricOnlyUnlock = false
                    isMasterPasswordFocused = true
                }
                .keemacSecondaryActionButton(minWidth: 220)
                .frame(maxWidth: 220)

                Button("Open other database") {
                    preferBiometricOnlyUnlock = false
                    viewModel.disableBiometricUnlockScreen()
                    selectFile()
                }
                .buttonStyle(.link)
                .hoverHighlight(cornerRadius: 6)

                if let statusMessage, !statusMessage.isEmpty, isError {
                    statusBanner(statusMessage: statusMessage, isError: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35))
            )
        }
        .frame(width: 460)
        .padding(24)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private func statusBanner(statusMessage: String, isError: Bool) -> some View {
        Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .foregroundStyle(isError ? .red : .secondary)
            .font(.callout)
    }

    private var isLoading: Bool {
        if case .loading = viewModel.loadState {
            return true
        }
        return false
    }

    private var canUseBiometricUnlock: Bool {
        viewModel.showBiometricUnlockScreen && viewModel.selectedVaultURL != nil
    }

    private var shouldShowBiometricOnlyUnlock: Bool {
        preferBiometricOnlyUnlock && viewModel.selectedVaultURL != nil
    }

    private func touchIDActionLabel(touchIDEnabledForVault: Bool) -> String {
        if !touchIDEnabledForVault {
            return "Touch ID is disabled for this vault"
        }
        if !canUseBiometricUnlock {
            return "Touch ID is not configured for this vault"
        }
        return "Touch ID for \"KeeMac\""
    }

    private func lockedScreenSubtitle(statusMessage: String?, isError: Bool) -> String {
        if isError, let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return "This database was locked. Use Touch ID to unlock it quickly."
    }

    private var minimumWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 980
        }
        return 460
    }

    private var idealWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 1100
        }
        return 480
    }

    private var minimumWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 680
        }
        return 500
    }

    private var idealWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 760
        }
        return 540
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        let kdbxType = UTType(filenameExtension: "kdbx") ?? .data
        panel.allowedContentTypes = [kdbxType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open Vault"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            viewModel.selectVault(url: selectedURL)
            isMasterPasswordFocused = true
        }
    }

    private func selectKeyFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open Key File"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            viewModel.selectKeyFile(url: selectedURL)
            useKeyFileForUnlock = true
            isMasterPasswordFocused = true
        }
    }

    private func unlockVault() {
        Task {
            let password = masterPassword
            masterPassword = ""
            await viewModel.unlock(masterPassword: password)
        }
    }

    private func selectRecentVault(_ recentVault: AppViewModel.RecentVault) {
        viewModel.selectRecentVault(recentVault)
        useKeyFileForUnlock = recentVault.keyFileURL != nil
        isMasterPasswordFocused = true
    }

    private func startActivityMonitor() {
        guard activityMonitorToken == nil else {
            return
        }
        let model = viewModel
        activityMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved, .scrollWheel]
        ) { event in
            model.registerUserActivity()
            return event
        }
    }

    private func stopActivityMonitor() {
        guard let activityMonitorToken else {
            return
        }
        NSEvent.removeMonitor(activityMonitorToken)
        self.activityMonitorToken = nil
    }

    private func applyWindowLayout(for state: AppViewModel.LoadState) {
        guard let window = MainWindowStore.shared.window else {
            return
        }

        switch state {
        case .loaded(let vault):
            window.title = vault.summary.fileName
            window.titleVisibility = .hidden
        case .idle, .loading, .locked, .failed:
            window.title = "KeeMac"
            window.titleVisibility = .visible
        }

        switch state {
        case .loaded:
            let minSize = NSSize(width: 980, height: 680)
            window.minSize = minSize
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

            let currentSize = window.contentRect(forFrameRect: window.frame).size
            if currentSize.width < minSize.width || currentSize.height < minSize.height {
                let targetSize = NSSize(
                    width: max(currentSize.width, 1100),
                    height: max(currentSize.height, 760)
                )
                window.setContentSize(targetSize)
            }

        case .idle, .loading, .locked, .failed:
            let minSize = NSSize(width: 460, height: 500)
            let maxSize = NSSize(width: 520, height: 620)
            let targetSize = NSSize(width: 460, height: 540)

            window.minSize = minSize
            window.maxSize = maxSize

            let currentSize = window.contentRect(forFrameRect: window.frame).size
            let shouldResize = abs(currentSize.width - targetSize.width) > 1 || abs(currentSize.height - targetSize.height) > 1
            if shouldResize {
                window.setContentSize(targetSize)
            }
        }
    }

}
