import SwiftUI

public struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general
        case security
        case appearance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                return "General"
            case .security:
                return "Security"
            case .appearance:
                return "Appearance"
            }
        }

        var symbol: String {
            switch self {
            case .general:
                return "slider.horizontal.3"
            case .security:
                return "lock"
            case .appearance:
                return "paintpalette"
            }
        }
    }

    @Bindable private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .general

    private let vaultLockTimeoutOptions: [TimeInterval] = [30, 60, 120, 300, 600, 900, 1800, 3600, 0]
    private let clipboardTimeoutOptions: [TimeInterval] = [10, 15, 30, 45, 60, 120, 300, 0]

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("Preferences")
                .font(.headline.weight(.semibold))
                .padding(.top, 10)
                .padding(.bottom, 8)

            tabSelector
                .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if selectedTab == .general || selectedTab == .appearance {
                        sectionTitle("Application")
                        settingsCard {
                            settingRow(
                                title: "Show in Dock",
                                subtitle: "Keep the application icon visible in the Dock even when closed",
                                showDivider: true
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { viewModel.showDockIcon },
                                    set: { viewModel.setShowDockIcon($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            settingRow(
                                title: "Include Subgroups",
                                subtitle: "Show entries from nested folders when a group is selected"
                            ) {
                                Toggle("", isOn: $viewModel.includeSubgroupEntriesInGroupView)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }
                    }

                    if selectedTab == .general || selectedTab == .security {
                        sectionTitle("Security")
                        settingsCard {
                            settingRow(
                                title: "Auto-lock Database",
                                subtitle: "Automatically lock after a period of inactivity",
                                showDivider: true
                            ) {
                                Menu {
                                    ForEach(vaultLockTimeoutOptions, id: \.self) { timeout in
                                        Button(timeoutOptionTitle(timeout, for: .idleLock)) {
                                            viewModel.setIdleLockTimeoutForSelectedVault(timeout)
                                        }
                                    }
                                } label: {
                                    settingsSelectChip {
                                        HStack(spacing: 8) {
                                            Text(timeoutOptionTitle(viewModel.idleLockTimeoutForSelectedVault, for: .idleLock))
                                            Image(systemName: "square.grid.2x2")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "chevron.down")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(viewModel.selectedVaultURL == nil)
                            }

                            settingRow(
                                title: "Clear Clipboard",
                                subtitle: "Remove copied passwords from history",
                                showDivider: true
                            ) {
                                HStack(spacing: 8) {
                                    Menu {
                                        ForEach(clipboardTimeoutOptions, id: \.self) { timeout in
                                            Button(timeoutOptionTitle(timeout, for: .clipboard)) {
                                                viewModel.clipboardAutoClearTimeoutSeconds = timeout
                                            }
                                        }
                                    } label: {
                                        settingsSelectChip(minWidth: 80) {
                                            HStack(spacing: 8) {
                                                Text(clipboardNumericTitle(viewModel.clipboardAutoClearTimeoutSeconds))
                                                Image(systemName: "chevron.down")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .menuStyle(.borderlessButton)

                                    Text(clipboardUnitTitle(viewModel.clipboardAutoClearTimeoutSeconds))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }

                            settingRow(
                                title: "Touch ID Unlock",
                                subtitle: "Use fingerprint to unlock database"
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { viewModel.touchIDEnabledForSelectedVault },
                                    set: { viewModel.setTouchIDEnabledForSelectedVault($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(viewModel.selectedVaultURL == nil)
                            }
                        }
                    }

                    if let selectedVaultURL = viewModel.selectedVaultURL {
                        sectionTitle("Selected Vault")
                        settingsCard {
                            Text(selectedVaultURL.path(percentEncoded: false))
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .keemacBoxedField()
                                .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Changes are saved automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keemacPrimaryActionButton(minWidth: 118)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 760, idealWidth: 760, minHeight: 520, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabSelector: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.75))
        )
    }

    private func settingRow<Trailing: View>(
        title: String,
        subtitle: String,
        showDivider: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 20)
                trailing()
                    .frame(minWidth: 220, maxWidth: 320, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showDivider {
                Divider()
                    .padding(.leading, 14)
            }
        }
    }

    private enum TimeoutKind {
        case idleLock
        case clipboard
    }

    private func timeoutOptionTitle(_ timeout: TimeInterval, for kind: TimeoutKind) -> String {
        if timeout == 0 {
            return kind == .idleLock ? "Never" : "Never clear"
        }
        if timeout < 60 {
            return "\(Int(timeout)) seconds"
        }
        let minutes = Int(timeout / 60)
        return minutes == 1 ? "After 1 minute" : "After \(minutes) minutes"
    }

    private func settingsSelectChip<Content: View>(minWidth: CGFloat = 190, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .frame(minWidth: minWidth, alignment: .trailing)
            .keemacBoxedField()
    }

    private func clipboardNumericTitle(_ timeout: TimeInterval) -> String {
        if timeout == 0 {
            return "Never"
        }
        if timeout < 60 {
            return "\(Int(timeout))"
        }
        return "\(Int(timeout / 60))"
    }

    private func clipboardUnitTitle(_ timeout: TimeInterval) -> String {
        if timeout == 0 {
            return ""
        }
        if timeout < 60 {
            return "seconds"
        }
        let minutes = Int(timeout / 60)
        return minutes == 1 ? "minute" : "minutes"
    }

}
