import AppKit
import SwiftUI
import UI

@MainActor
final class KeeMacAppDelegate: NSObject, NSApplicationDelegate {
    private var dockIconVisibilityObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var passwordHealthObserver: NSObjectProtocol?
    private var showWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy(showDockIcon: AppSettingsStore.shared.showDockIcon)
        ExpiryNotifier.shared.activate()

        if let icon = loadAppIcon() {
            NSApp.applicationIconImage = icon
        }

        dockIconVisibilityObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.dockIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { notification in
            guard let showDockIcon = notification.userInfo?[AppCommand.dockIconVisibilityUserInfoKey] as? Bool else {
                return
            }
            Task { @MainActor in
                Self.applyActivationPolicy(showDockIcon: showDockIcon)
            }
        }

        lockObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.lockVault,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MainWindowController.shared.hide()
            }
        }

        passwordHealthObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.openPasswordHealth,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                MainWindowController.shared.show()
            }
        }

        showWindowObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.showMainWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                MainWindowController.shared.show()
            }
        }

        if AppSettingsStore.shared.startMinimized {
            // Launch quietly into the menu bar without opening the main window.
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.shared.show()
        }
        return true
    }

    /// Set by `KeeMacApp`; the delegate locks the open database before quitting.
    static weak var viewModel: AppViewModel?

    /// Quitting, logging out or shutting down locks the database first so pending changes are saved.
    /// The wait is capped so KeeMac never blocks a logout.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel = Self.viewModel, viewModel.loadState.isUnlocked || viewModel.hasPendingLock else {
            return .terminateNow
        }
        Task { @MainActor in
            let lock = Task { await viewModel.lockForQuit() }
            let timeout = Task { try? await Task.sleep(for: .seconds(5)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await lock.value }
                group.addTask { await timeout.value }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        SensitiveClipboard.shared.clearSensitiveContents()
        BrowserIntegrationController.shared.shutdown()
        SSHAgentController.shared.shutdown()
        UITesting.cleanUp()
        if let dockIconVisibilityObserver {
            NotificationCenter.default.removeObserver(dockIconVisibilityObserver)
            self.dockIconVisibilityObserver = nil
        }
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
            self.lockObserver = nil
        }
        if let passwordHealthObserver {
            NotificationCenter.default.removeObserver(passwordHealthObserver)
            self.passwordHealthObserver = nil
        }
        if let showWindowObserver {
            NotificationCenter.default.removeObserver(showWindowObserver)
            self.showWindowObserver = nil
        }
    }

    private func loadAppIcon() -> NSImage? {
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }

        return nil
    }

    private static func applyActivationPolicy(showDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

@main
struct KeeMacApp: App {
    @NSApplicationDelegateAdaptor(KeeMacAppDelegate.self) private var appDelegate
    private let viewModel: AppViewModel

    init() {
        UITesting.prepare()
        LegacySettingsMigration.migrateIfNeeded()
        let viewModel = AppViewModel()
        self.viewModel = viewModel
        MainWindowController.shared.configure(viewModel: viewModel)
        BrowserIntegrationController.shared.configure(viewModel: viewModel)
        QuickAccessController.shared.configure(viewModel: viewModel)
        AutoTypeController.shared.configure(viewModel: viewModel)
        SSHAgentController.shared.configure(viewModel: viewModel)
        KeeMacAppDelegate.viewModel = viewModel
        if let vaultURL = UITesting.vaultURL {
            viewModel.selectVault(url: vaultURL)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            KeeMacMenuBarView(viewModel: viewModel)
        } label: {
            Image(nsImage: isUnlocked ? MenuBarIcon.unlocked : MenuBarIcon.locked)
                .accessibilityLabel(isUnlocked ? L("KeeMac, unlocked") : L("KeeMac, locked"))
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }

            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .undoRedo) {
                Button(undoTitle) {
                    undoOrRedo(redo: false)
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button(redoTitle) {
                    undoOrRedo(redo: true)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appSettings) {
                Button(L("Generate Password...")) {
                    PasswordGeneratorWindowController.shared.show()
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
            }

            CommandMenu(L("Vault")) {
                Button(L("New Database...")) {
                    postCommandRequiringMainWindow(AppCommand.newVault)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(L("Open Vault...")) {
                    postCommandRequiringMainWindow(AppCommand.openVault)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(L("Select Key File...")) {
                    postCommandRequiringMainWindow(AppCommand.selectKeyFile)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button(L("Clear Key File")) {
                    postCommandRequiringMainWindow(AppCommand.clearKeyFile)
                }

                Divider()

                Button(L("Merge Database...")) {
                    postCommandRequiringMainWindow(AppCommand.mergeDatabase)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button(L("Import...")) {
                    postCommandRequiringMainWindow(AppCommand.importData)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(L("Export...")) {
                    postCommandRequiringMainWindow(AppCommand.exportData)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(L("Database Settings...")) {
                    postCommandRequiringMainWindow(AppCommand.openDatabaseSettings)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])

                Button(L("Lock Vault")) {
                    postCommand(AppCommand.lockVault)
                }
                .keyboardShortcut("l", modifiers: [.command])

                if UITesting.isActive {
                    // The global shortcut is off in UI tests; this stands in for it.
                    Button("Perform Auto-Type") {
                        AutoTypeController.shared.performForUITesting()
                    }
                }
            }
        }
    }

    private var isUnlocked: Bool {
        if case .loaded = viewModel.loadState {
            return true
        }
        return false
    }

    private var undoTitle: String {
        viewModel.undoState.undoAction.map { L("Undo \($0.title)") } ?? L("Undo")
    }

    private var redoTitle: String {
        viewModel.undoState.redoAction.map { L("Redo \($0.title)") } ?? L("Redo")
    }

    /// While a text field is being edited ⌘Z undoes typing there; otherwise it undoes the last database change.
    /// The items stay enabled so text fields keep their own undo.
    private func undoOrRedo(redo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
            return
        }
        postCommand(redo ? AppCommand.redo : AppCommand.undo)
    }

    private func postCommand(_ command: Notification.Name) {
        NotificationCenter.default.post(name: command, object: nil)
    }

    private func postCommandRequiringMainWindow(_ command: Notification.Name) {
        MainWindowController.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postCommand(command)
        }
    }
}

/// KeeMac → About KeeMac opens Settings → About: the version, licenses and source link live there.
private struct AboutMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L("About KeeMac")) {
            SettingsNavigation.shared.showsAbout = true
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
