import AppKit
import SwiftUI
import UI

final class KeeMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let icon = loadAppIcon() {
            NSApp.applicationIconImage = icon
        }

        NSApp.activate(ignoringOtherApps: true)
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
}

@main
struct KeeMacApp: App {
    @NSApplicationDelegateAdaptor(KeeMacAppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
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

    private func postCommand(_ command: Notification.Name) {
        NotificationCenter.default.post(name: command, object: nil)
    }
}
