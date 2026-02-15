import AppKit
import SwiftUI
import UI

struct KeeMacMenuBarView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button("Open KeeMac") {
                openMainWindow()
            }

            if canUseBiometricUnlock {
                Button("Open by Touch ID") {
                    openMainWindow()
                    Task {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        await viewModel.unlockWithBiometrics()
                        openMainWindow()
                    }
                }
            }

            Divider()

            Button("Open Vault...") {
                postCommandRequiringMainWindow(AppCommand.openVault)
            }

            Button("Select Key File...") {
                postCommandRequiringMainWindow(AppCommand.selectKeyFile)
            }
            .disabled(viewModel.selectedVaultURL == nil)

            Button("Clear Key File") {
                postCommandRequiringMainWindow(AppCommand.clearKeyFile)
            }
            .disabled(viewModel.selectedKeyFileURL == nil)

            Divider()

            Button("Lock Vault") {
                NotificationCenter.default.post(name: AppCommand.lockVault, object: nil)
            }
            .disabled(!isVaultLoaded)

            Button("Settings...") {
                openSettings()
                openMainWindow()
            }

            Divider()

            Button("Quit KeeMac") {
                NSApp.terminate(nil)
            }
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
