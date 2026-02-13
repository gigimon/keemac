import AppKit
import SwiftUI
import UI

final class KeeMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct KeeMacApp: App {
    @NSApplicationDelegateAdaptor(KeeMacAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowResizability(.contentSize)
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
