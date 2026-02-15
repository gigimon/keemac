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
                    }
                )
                    .onAppear {
                        startActivityMonitor()
                        viewModel.registerUserActivity()
                    }
                    .onDisappear {
                        stopActivityMonitor()
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Lock Vault") {
                                viewModel.lockVault(reason: .userInitiated)
                            }
                            .hoverHighlight()
                        }
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
        }
        .onChange(of: viewModel.showDockIcon) { _, showDockIcon in
            if !showDockIcon {
                preferBiometricOnlyUnlock = false
            }
        }
        .background(
            WindowAccessorView { window in
                MainWindowStore.shared.register(window: window)
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
        VStack(alignment: .leading, spacing: 16) {
            header
            if !viewModel.recentVaults.isEmpty {
                recentVaultsSection
            }
            controlsSection
            if let statusMessage, !statusMessage.isEmpty {
                statusBanner(statusMessage: statusMessage, isError: isError)
            }
        }
        .padding(20)
        .frame(width: 760)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.35))
        )
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
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
        VStack(alignment: .leading, spacing: 18) {
            Text("KeeMac")
                .font(.largeTitle.bold())

            Label(viewModel.selectedVaultURL?.lastPathComponent ?? "Saved Vault", systemImage: "externaldrive.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.unlockWithBiometrics()
                    }
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading)
                .hoverHighlight()

                Button("Choose Different Vault") {
                    preferBiometricOnlyUnlock = false
                    viewModel.disableBiometricUnlockScreen()
                    selectFile()
                }
                .buttonStyle(.bordered)
                .hoverHighlight()
            }

            if let statusMessage, !statusMessage.isEmpty {
                statusBanner(statusMessage: statusMessage, isError: isError)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.35))
        )
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KeeMac")
                .font(.largeTitle.bold())
            Text("Unlock your vault")
                .foregroundStyle(.secondary)
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 0) {
            fileChooserRow(
                title: "Database",
                displayedPath: viewModel.selectedVaultURL?.path(percentEncoded: false),
                placeholder: "Select .kdbx file",
                symbol: "externaldrive.fill",
                actionTitle: "Browse",
                action: selectFile,
                clearAction: viewModel.selectedVaultURL == nil ? nil : {
                    viewModel.clearVaultSelection()
                }
            )

            Divider()
                .padding(.horizontal, 14)

            fileChooserRow(
                title: "Key File",
                displayedPath: viewModel.selectedKeyFileURL?.path(percentEncoded: false),
                placeholder: "Optional",
                symbol: "key.fill",
                actionTitle: "Browse",
                action: selectKeyFile,
                clearAction: viewModel.selectedKeyFileURL == nil ? nil : {
                    viewModel.selectKeyFile(url: nil)
                }
            )

            Divider()
                .padding(.horizontal, 14)

            passwordSection
                .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.2))
        )
    }

    private var recentVaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Vaults")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(viewModel.recentVaults) { recentVault in
                    Button(recentVault.title) {
                        selectRecentVault(recentVault)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .help(recentVault.vaultURL.path(percentEncoded: false))
                    .hoverHighlight()
                }
            }
        }
    }

    private func fileChooserRow(
        title: String,
        displayedPath: String?,
        placeholder: String,
        symbol: String,
        actionTitle: String,
        action: @escaping () -> Void,
        clearAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(width: 110, alignment: .leading)

            Text(displayedPath ?? placeholder)
                .font(.callout.monospaced())
                .foregroundStyle(displayedPath == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .hoverHighlight()

            if let clearAction {
                Button {
                    clearAction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear \(title.lowercased())")
                .hoverHighlight()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Master Password", systemImage: "lock.fill")
                .font(.headline)

            HStack(spacing: 10) {
                SecureField("Enter your password", text: $masterPassword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($isMasterPasswordFocused)
                    .onSubmit {
                        unlockVault()
                    }

                Button("Unlock Vault") {
                    unlockVault()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.selectedVaultURL == nil || (masterPassword.isEmpty && viewModel.selectedKeyFileURL == nil) || isLoading)
                .hoverHighlight()

                if canUseBiometricUnlock {
                    Button {
                        Task {
                            await viewModel.unlockWithBiometrics()
                        }
                    } label: {
                        Label("Open by Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading || viewModel.selectedVaultURL == nil)
                    .hoverHighlight()
                }
            }
        }
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
        preferBiometricOnlyUnlock && canUseBiometricUnlock
    }

    private var minimumWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 980
        }
        return 760
    }

    private var idealWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 1100
        }
        return 800
    }

    private var minimumWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 680
        }
        return 380
    }

    private var idealWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 760
        }
        return 420
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

}
