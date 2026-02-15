import SwiftUI

public struct SettingsView: View {
    @Bindable private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private let vaultLockTimeoutOptions: [TimeInterval] = [30, 60, 120, 300, 600, 900, 1800, 3600, 0]
    private let clipboardTimeoutOptions: [TimeInterval] = [10, 15, 30, 45, 60, 120, 300, 0]

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Selected Vault") {
                    if let selectedVaultURL = viewModel.selectedVaultURL {
                        Text(selectedVaultURL.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("No vault selected. Select a database in the main window to configure per-vault settings.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Security") {
                    Toggle(
                        "Enable Touch ID for selected vault",
                        isOn: Binding(
                            get: { viewModel.touchIDEnabledForSelectedVault },
                            set: { viewModel.setTouchIDEnabledForSelectedVault($0) }
                        )
                    )
                    .disabled(viewModel.selectedVaultURL == nil)

                    Picker(
                        "Auto-lock timeout",
                        selection: Binding(
                            get: { viewModel.idleLockTimeoutForSelectedVault },
                            set: { viewModel.setIdleLockTimeoutForSelectedVault($0) }
                        )
                    ) {
                        ForEach(vaultLockTimeoutOptions, id: \.self) { timeout in
                            Text(timeoutTitle(timeout)).tag(timeout)
                        }
                    }
                    .disabled(viewModel.selectedVaultURL == nil)
                }

                Section("Appearance") {
                    Toggle(
                        "Show Dock icon",
                        isOn: Binding(
                            get: { viewModel.showDockIcon },
                            set: { viewModel.setShowDockIcon($0) }
                        )
                    )
                }

                Section("Clipboard") {
                    Picker(
                        "Auto-clear copied secrets",
                        selection: Binding(
                            get: { viewModel.clipboardAutoClearTimeoutSeconds },
                            set: { viewModel.clipboardAutoClearTimeoutSeconds = $0 }
                        )
                    ) {
                        ForEach(clipboardTimeoutOptions, id: \.self) { timeout in
                            Text(timeoutTitle(timeout)).tag(timeout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Text("Changes are saved automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .hoverHighlight()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 360, idealHeight: 420)
    }

    private func timeoutTitle(_ timeout: TimeInterval) -> String {
        if timeout == 0 {
            return "Never"
        }
        if timeout < 60 {
            return "\(Int(timeout)) sec"
        }
        if timeout.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(timeout / 60)
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }
        return String(format: "%.0f sec", timeout)
    }
}
