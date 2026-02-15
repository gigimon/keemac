import AppKit
import SwiftUI
import UI

@MainActor
final class KeeMacAppDelegate: NSObject, NSApplicationDelegate {
    private var dockIconVisibilityObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy(showDockIcon: AppSettingsStore.shared.showDockIcon)

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

        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let dockIconVisibilityObserver {
            NotificationCenter.default.removeObserver(dockIconVisibilityObserver)
            self.dockIconVisibilityObserver = nil
        }
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
            self.lockObserver = nil
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
        let viewModel = AppViewModel()
        self.viewModel = viewModel
        MainWindowController.shared.configure(viewModel: viewModel)
    }

    var body: some Scene {
        MenuBarExtra {
            KeeMacMenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: menuBarSymbolName)
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Vault") {
                Button("Open Vault...") {
                    postCommandRequiringMainWindow(AppCommand.openVault)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Select Key File...") {
                    postCommandRequiringMainWindow(AppCommand.selectKeyFile)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Clear Key File") {
                    postCommandRequiringMainWindow(AppCommand.clearKeyFile)
                }

                Divider()

                Button("Lock Vault") {
                    postCommand(AppCommand.lockVault)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }
    }

    private var menuBarSymbolName: String {
        if case .loaded = viewModel.loadState {
            return "lock.open.fill"
        }
        return "lock.fill"
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
