import AppKit
import SwiftUI
import UI

struct KeeMacMenuBarView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button(L("Open KeeMac")) {
                openMainWindow()
            }

            if canUseBiometricUnlock {
                Button(L("Open by Touch ID")) {
                    openMainWindow()
                    Task {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        await viewModel.unlockWithBiometrics()
                        openMainWindow()
                    }
                }
            }

            quickAccessButton

            Divider()

            Button(L("Open Vault...")) {
                postCommandRequiringMainWindow(AppCommand.openVault)
            }

            Button(L("Select Key File...")) {
                postCommandRequiringMainWindow(AppCommand.selectKeyFile)
            }
            .disabled(viewModel.selectedVaultURL == nil)

            Button(L("Clear Key File")) {
                postCommandRequiringMainWindow(AppCommand.clearKeyFile)
            }
            .disabled(viewModel.selectedKeyFileURL == nil)

            Divider()

            Button(L("Database Settings...")) {
                postCommandRequiringMainWindow(AppCommand.openDatabaseSettings)
            }
            .disabled(!isVaultLoaded)

            Button(L("Lock Vault")) {
                NotificationCenter.default.post(name: AppCommand.lockVault, object: nil)
            }
            .disabled(!isVaultLoaded)

            Button(L("Generate Password...")) {
                PasswordGeneratorWindowController.shared.show()
            }

            Button(L("Settings...")) {
                openSettings()
                openMainWindow()
            }

            Divider()

            Button(L("Quit KeeMac")) {
                NSApp.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var quickAccessButton: some View {
        let settings = AppSettingsStore.shared
        let button = Button(L("Quick Access")) {
            QuickAccessController.shared.show()
        }
        if settings.quickAccessEnabled, let shortcut = settings.quickAccessShortcut.keyboardShortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private var isVaultLoaded: Bool {
        if case .loaded = viewModel.loadState {
            return true
        }
        return false
    }

    private var canUseBiometricUnlock: Bool {
        viewModel.showBiometricUnlockScreen && viewModel.selectedVaultURL != nil
    }

    private func openMainWindow() {
        MainWindowController.shared.show()
    }

    private func postCommandRequiringMainWindow(_ command: Notification.Name) {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: command, object: nil)
        }
    }

}
