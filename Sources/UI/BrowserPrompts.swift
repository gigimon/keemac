import AppKit
import Domain
import SwiftUI

struct BrowserAccessAnswer: Sendable {
    let allowed: Set<UUID>
    let remember: Bool
}

/// The questions `BrowserIntegrationController` asks the user.
@MainActor
protocol BrowserPrompting: AnyObject {
    func askConnectionName(databaseName: String, existingNames: Set<String>) async -> String?
    func askAccess(site: String, entries: [VaultBrowserCandidate]) async -> BrowserAccessAnswer?
    func confirmUpdate(site: String, target: VaultBrowserLoginTarget, newUsername: String?, changesPassword: Bool) async -> Bool
    func confirmNewGroup(path: String) async -> Bool
    func askUnlock(viewModel: AppViewModel) async -> Bool
    func generatePassword() async -> String?
    func cancelAll()
}

/// Shows browser requests one at a time in a floating window, even while KeeMac is in the background.
@MainActor
final class BrowserPromptPresenter: NSObject, NSWindowDelegate, BrowserPrompting {
    private var window: NSWindow?
    private var cancelCurrent: (() -> Void)?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Bumped by `cancelAll()` so requests queued before it don't show up afterwards.
    private var generation = 0
    /// KeeMac was in the background when the first prompt opened; hide it again afterwards so the browser gets focus back.
    private var hidesWhenDone = false

    func askConnectionName(databaseName: String, existingNames: Set<String>) async -> String? {
        await present(title: L("Connect Browser"), cancelValue: nil) { resolve in
            BrowserAssociationPromptView(databaseName: databaseName, existingNames: existingNames, resolve: resolve)
        }
    }

    func askAccess(site: String, entries: [VaultBrowserCandidate]) async -> BrowserAccessAnswer? {
        await present(title: L("Browser Access"), cancelValue: nil) { resolve in
            BrowserAccessPromptView(site: site, entries: entries, resolve: resolve)
        }
    }

    func confirmUpdate(site: String, target: VaultBrowserLoginTarget, newUsername: String?, changesPassword: Bool) async -> Bool {
        var changes: [String] = []
        if let newUsername {
            changes.append(L("Username: \(target.username.isEmpty ? L("empty") : target.username) → \(newUsername.isEmpty ? L("empty") : newUsername)"))
        }
        if changesPassword {
            changes.append(L("Password: a new password. The old one stays in the entry’s history."))
        }
        return await present(title: L("Update Login"), cancelValue: false) { resolve in
            BrowserConfirmPromptView(
                symbol: "key.fill",
                title: L("Update “\(target.title.isEmpty ? site : target.title)”?"),
                message: L("KeePassXC-Browser asks to save a changed login for \(site)."),
                details: changes,
                confirmTitle: L("Update"),
                resolve: resolve
            )
        }
    }

    func confirmNewGroup(path: String) async -> Bool {
        await present(title: L("New Group"), cancelValue: false) { resolve in
            BrowserConfirmPromptView(
                symbol: "folder.badge.plus",
                title: L("Create group “\(path)”?"),
                message: L("KeePassXC-Browser asks for this group to save logins in."),
                details: [],
                confirmTitle: L("Create"),
                resolve: resolve
            )
        }
    }

    func askUnlock(viewModel: AppViewModel) async -> Bool {
        await present(title: L("Unlock KeeMac"), cancelValue: false) { resolve in
            BrowserUnlockPromptView(viewModel: viewModel, resolve: resolve)
        }
    }

    func generatePassword() async -> String? {
        await present(title: L("Password Generator"), cancelValue: nil) { resolve in
            PasswordGeneratorWindowView(onFill: { resolve($0) })
        }
    }

    func cancelAll() {
        generation += 1
        cancelCurrent?()
        let waiting = waiting
        self.waiting = []
        waiting.forEach { $0.resume() }
    }

    private func present<Value: Sendable, Content: View>(
        title: String,
        cancelValue: Value,
        @ViewBuilder content: (@escaping (Value) -> Void) -> Content
    ) async -> Value {
        let startGeneration = generation
        while window != nil {
            await withCheckedContinuation { waiting.append($0) }
            if generation != startGeneration {
                return cancelValue
            }
        }

        return await withCheckedContinuation { continuation in
            var isResolved = false
            let resolve: (Value) -> Void = { [weak self] value in
                guard !isResolved else {
                    return
                }
                isResolved = true
                continuation.resume(returning: value)
                self?.closeWindow()
            }
            cancelCurrent = { resolve(cancelValue) }

            let window = NSWindow(contentViewController: NSHostingController(rootView: content(resolve)))
            window.title = title
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
            window.center()
            self.window = window
            if !NSApp.isActive {
                hidesWhenDone = true
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelCurrent?()
    }

    private func closeWindow() {
        let closing = window
        window = nil
        cancelCurrent = nil
        closing?.delegate = nil
        closing?.close()
        if !waiting.isEmpty {
            waiting.removeFirst().resume()
        } else if hidesWhenDone {
            hidesWhenDone = false
            NSApp.hide(nil)
        }
    }
}

struct BrowserAssociationPromptView: View {
    let databaseName: String
    let existingNames: Set<String>
    let resolve: (String?) -> Void

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(KM.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Connect KeePassXC-Browser?"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L("The extension asks to fill logins from \(databaseName)."))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Connection name"))
                    .font(.system(size: 12, weight: .medium))
                TextField("chrome-laptop", text: $name)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .kmField(focused: isFocused)
                    .onSubmit(connect)
                Text(existingNames.contains(trimmedName)
                     ? L("A connection with this name exists. Its key will be replaced.")
                     : L("Shown in Settings → Browser. Only connect if you just clicked Connect in the extension."))
                    .font(.system(size: 11))
                    .foregroundStyle(existingNames.contains(trimmedName) ? KM.warning : KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel")) {
                    resolve(nil)
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontSize: 12))
                .keyboardShortcut(.cancelAction)
                Button(L("Connect"), action: connect)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground.ignoresSafeArea())
        .onAppear {
            isFocused = true
        }
    }

    private func connect() {
        guard !trimmedName.isEmpty else {
            return
        }
        resolve(trimmedName)
    }
}

struct BrowserAccessPromptView: View {
    let site: String
    let entries: [VaultBrowserCandidate]
    let resolve: (BrowserAccessAnswer?) -> Void

    @State private var selected: Set<UUID>
    @State private var remember = true

    init(site: String, entries: [VaultBrowserCandidate], resolve: @escaping (BrowserAccessAnswer?) -> Void) {
        self.site = site
        self.entries = entries
        self.resolve = resolve
        _selected = State(initialValue: Set(entries.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 22))
                    .foregroundStyle(KM.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(site) wants to fill a login"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(L("Choose the entries this site may use."))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry, isFirst: index == 0)
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.insetFill))

            Toggle(L("Remember for \(site)"), isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Deny")) {
                    resolve(BrowserAccessAnswer(allowed: [], remember: remember))
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontSize: 12))
                .keyboardShortcut(.cancelAction)
                Button(selected.count == entries.count ? L("Allow") : L("Allow Selected")) {
                    resolve(BrowserAccessAnswer(allowed: selected, remember: remember))
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground.ignoresSafeArea())
    }

    private func entryRow(_ entry: VaultBrowserCandidate, isFirst: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(entry.id) },
            set: { isOn in
                if isOn {
                    selected.insert(entry.id)
                } else {
                    selected.remove(entry.id)
                }
            }
        )) {
            HStack(spacing: 10) {
                LetterTile(title: entry.title, size: 26, cornerRadius: 7, fontSize: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title.isEmpty ? L("Untitled") : entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(entry.username.isEmpty ? entry.groupTitle : "\(entry.username) · \(entry.groupTitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(KM.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
            }
        }
    }
}

struct BrowserConfirmPromptView: View {
    let symbol: String
    let title: String
    let message: String
    let details: [String]
    let confirmTitle: String
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(KM.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.insetFill))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel")) {
                    resolve(false)
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontSize: 12))
                .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    resolve(true)
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground.ignoresSafeArea())
    }
}

/// Unlock asked for by the browser: Touch ID right away when it is set up, otherwise the master password.
struct BrowserUnlockPromptView: View {
    @Bindable var viewModel: AppViewModel
    let resolve: (Bool) -> Void

    @State private var password = ""
    @State private var triedTouchID = false
    @FocusState private var isPasswordFocused: Bool

    private var databaseName: String {
        viewModel.selectedVaultURL?.lastPathComponent ?? L("Database")
    }

    private var isLoading: Bool {
        viewModel.loadState == .loading
    }

    private var canUseTouchID: Bool {
        viewModel.showBiometricUnlockScreen && viewModel.touchIDEnabledForSelectedVault
    }

    private var canUnlock: Bool {
        !isLoading && (!password.isEmpty || viewModel.selectedKeyFileURL != nil)
    }

    private var errorMessage: String? {
        if case .failed(let message) = viewModel.loadState {
            return message
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(KM.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Unlock \(databaseName)"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L("The browser asks for a login."))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                }
            }

            SecureField(L("Master Password"), text: $password)
                .textFieldStyle(.plain)
                .focused($isPasswordFocused)
                .onSubmit(unlock)
                .kmField(focused: isPasswordFocused)
                .disabled(isLoading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if canUseTouchID {
                    Button {
                        unlockWithTouchID()
                    } label: {
                        Image(systemName: "touchid")
                            .font(.system(size: 15))
                            .foregroundStyle(KM.touchID)
                    }
                    .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 14, tint: KM.touchID, filled: true))
                    .iconHelp(L("Unlock with Touch ID"))
                    .disabled(isLoading)
                }
                Spacer(minLength: 0)
                Button(L("Cancel")) {
                    resolve(false)
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontSize: 12))
                .keyboardShortcut(.cancelAction)
                Button(isLoading ? L("Unlocking…") : L("Unlock"), action: unlock)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canUnlock)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground.ignoresSafeArea())
        .onAppear {
            isPasswordFocused = true
            if canUseTouchID && !triedTouchID {
                unlockWithTouchID()
            }
        }
        .onChange(of: viewModel.loadState.isUnlocked) { _, isUnlocked in
            if isUnlocked {
                resolve(true)
            }
        }
    }

    private func unlock() {
        guard canUnlock else {
            return
        }
        let entered = password
        password = ""
        Task {
            await viewModel.unlock(masterPassword: entered)
        }
    }

    private func unlockWithTouchID() {
        triedTouchID = true
        Task {
            await viewModel.unlockWithBiometrics()
        }
    }
}
