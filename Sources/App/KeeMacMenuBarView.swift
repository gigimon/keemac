import AppKit
import SwiftUI
import UI

struct KeeMacMenuBarView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
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
                viewModel.lockVault(reason: .userInitiated)
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
        if !MainWindowStore.shared.focusWindow() {
            openWindow(id: "main")
        }
        focusBurst()
    }

    private func postCommandRequiringMainWindow(_ command: Notification.Name) {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: command, object: nil)
        }
    }

    private func focusMainWindow(retries: Int) {
        if MainWindowStore.shared.focusWindow() {
            return
        }

        guard retries > 0 else {
            return
        }

        if retries == 10 || retries == 6 {
            openWindow(id: "main")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusMainWindow(retries: retries - 1)
        }
    }

    private func focusBurst() {
        let delays: [Double] = [0.0, 0.08, 0.18, 0.35, 0.65, 1.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                focusMainWindow(retries: 12)
            }
        }
    }
}
