import AppKit
import SwiftUI
import UI

@MainActor
final class KeeMacAppDelegate: NSObject, NSApplicationDelegate {
    private var dockIconVisibilityObserver: NSObjectProtocol?

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

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let dockIconVisibilityObserver {
            NotificationCenter.default.removeObserver(dockIconVisibilityObserver)
            self.dockIconVisibilityObserver = nil
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
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        Window("KeeMac", id: "main") {
            RootView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)

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
                    postCommand(AppCommand.openVault)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Select Key File...") {
                    postCommand(AppCommand.selectKeyFile)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Clear Key File") {
                    postCommand(AppCommand.clearKeyFile)
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
}
