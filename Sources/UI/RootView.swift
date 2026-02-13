import AppKit
import Data
import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @State private var viewModel = AppViewModel(vaultLoader: KeePassKitVaultLoader())
    @State private var masterPassword: String = ""
    @State private var activityMonitorToken: Any?
    @FocusState private var isMasterPasswordFocused: Bool

    public init() {}

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loaded(let vault):
                VaultBrowserView(
                    vault: vault,
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
                        }
                    }
            case .loading:
                loadingView
            case .idle:
                unlockView(statusMessage: "Ready")
            case .locked(let message):
                unlockView(statusMessage: message)
            case .failed(let message):
                unlockView(statusMessage: message, isError: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.loadState)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            viewModel.lockVault(reason: .systemSleep)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openVault)) { _ in
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
        .onChange(of: viewModel.loadState) { _, newState in
            switch newState {
            case .idle, .locked, .failed:
                isMasterPasswordFocused = true
            case .loading, .loaded:
                break
            }
        }
        .frame(
            minWidth: minimumWindowWidth,
            idealWidth: idealWindowWidth,
            minHeight: minimumWindowHeight,
            idealHeight: idealWindowHeight
        )
    }

    @ViewBuilder
    private func unlockView(statusMessage: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            chooserSection(compact: false)
            passwordSection
            statusBanner(statusMessage: statusMessage, isError: isError)
        }
        .padding(24)
        .frame(width: 820)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KeeMac")
                .font(.largeTitle.bold())
            Text("Unlock your vault")
                .foregroundStyle(.secondary)
        }
    }

    private func chooserSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if compact {
                    VStack(spacing: 10) {
                        fileChooserCard(
                            title: "Database",
                            subtitle: viewModel.selectedVaultURL?.lastPathComponent ?? "Select .kdbx file",
                            symbol: "externaldrive.fill",
                            actionTitle: "Choose Database",
                            action: selectFile,
                            clearAction: viewModel.selectedVaultURL == nil ? nil : {
                                viewModel.clearVaultSelection()
                            }
                        )

                        fileChooserCard(
                            title: "Key File",
                            subtitle: viewModel.selectedKeyFileURL?.lastPathComponent ?? "Optional",
                            symbol: "key.fill",
                            actionTitle: "Choose Key File",
                            action: selectKeyFile,
                            clearAction: viewModel.selectedKeyFileURL == nil ? nil : {
                                viewModel.selectKeyFile(url: nil)
                            }
                        )
                    }
                } else {
                    HStack(spacing: 12) {
                        fileChooserCard(
                            title: "Database",
                            subtitle: viewModel.selectedVaultURL?.lastPathComponent ?? "Select .kdbx file",
                            symbol: "externaldrive.fill",
                            actionTitle: "Choose Database",
                            action: selectFile,
                            clearAction: viewModel.selectedVaultURL == nil ? nil : {
                                viewModel.clearVaultSelection()
                            }
                        )

                        fileChooserCard(
                            title: "Key File",
                            subtitle: viewModel.selectedKeyFileURL?.lastPathComponent ?? "Optional",
                            symbol: "key.fill",
                            actionTitle: "Choose Key File",
                            action: selectKeyFile,
                            clearAction: viewModel.selectedKeyFileURL == nil ? nil : {
                                viewModel.selectKeyFile(url: nil)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let path = viewModel.selectedVaultURL?.path(percentEncoded: false) {
                filePathBadge(path: path)
            }
            if let path = viewModel.selectedKeyFileURL?.path(percentEncoded: false) {
                filePathBadge(path: path)
            }
        }
    }

    private func fileChooserCard(
        title: String,
        subtitle: String,
        symbol: String,
        actionTitle: String,
        action: @escaping () -> Void,
        clearAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let clearAction {
                    Button("Clear") {
                        clearAction()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.25))
        )
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
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.25))
        )
    }

    private func filePathBadge(path: String) -> some View {
        Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.background.opacity(0.55))
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

    private var minimumWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 980
        }
        return 820
    }

    private var idealWindowWidth: CGFloat {
        if case .loaded = viewModel.loadState {
            return 1100
        }
        return 860
    }

    private var minimumWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 680
        }
        return 420
    }

    private var idealWindowHeight: CGFloat {
        if case .loaded = viewModel.loadState {
            return 760
        }
        return 480
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
