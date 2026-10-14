import Domain
import SwiftUI

/// The hardware key row of the unlock screen, New Database and Change Master Key: a collapsed
/// "Add hardware key" link, a picker of connected slots, the chosen key as a chip, or a message
/// when nothing (or not the remembered key) is plugged in.
struct HardwareKeyPicker: View {
    let selected: VaultHardwareKey?
    let connected: [VaultHardwareKey]
    let isScanning: Bool
    var height: CGFloat = 38
    var cornerRadius: CGFloat = 10
    /// Change Master Key shows the picker right away and has no way to collapse it.
    var alwaysExpanded = false
    var isDisabled = false
    let identifierPrefix: String
    let onSelect: (VaultHardwareKey?) -> Void
    let onRefresh: () -> Void

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let selected {
                if isConnected(selected) || isScanning {
                    chip(for: selected)
                } else {
                    message(
                        L("YubiKey \(String(selected.serial)) remembered for this database — not connected"),
                        symbol: "cable.connector",
                        color: KM.warning,
                        closeHelp: L("Remove hardware key")
                    ) {
                        onSelect(nil)
                    }
                }
            } else if isExpanded || alwaysExpanded {
                if connected.isEmpty && !isScanning {
                    message(
                        L("No hardware key detected — plug in your YubiKey"),
                        symbol: "cable.connector.slash",
                        color: KM.textSecondary,
                        closeHelp: alwaysExpanded ? nil : L("Don’t use a hardware key")
                    ) {
                        isExpanded = false
                    }
                } else {
                    picker
                }
            } else {
                collapsed
            }
        }
        .disabled(isDisabled)
    }

    private func isConnected(_ key: VaultHardwareKey) -> Bool {
        connected.contains { $0.isSameSlot(as: key) }
    }

    private var collapsed: some View {
        Button {
            isExpanded = true
            onRefresh()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 14))
                Text(L("No hardware key"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Add hardware key"))
                    .fontWeight(.medium)
                    .foregroundStyle(KM.accent)
            }
            .font(.system(size: 13))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color(light: .black(0.2), dark: .white(0.2)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix).add")
    }

    private var picker: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(connected) { key in
                    Button(key.label) {
                        onSelect(key)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 14))
                        .foregroundStyle(KM.accent)
                    Text(isScanning && connected.isEmpty ? L("Looking for hardware keys…") : L("Choose a hardware key…"))
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KM.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(KM.raisedFieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(KM.softBorder, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("\(identifierPrefix).menu")

            refreshButton
            if !alwaysExpanded {
                closeButton(help: L("Don’t use a hardware key")) {
                    isExpanded = false
                }
            }
        }
    }

    private func chip(for key: VaultHardwareKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 14))
                .foregroundStyle(KM.accent)
            Text(key.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifierPrefix).chip")
            closeButton(help: L("Remove hardware key"), identifier: "remove") {
                onSelect(nil)
                isExpanded = alwaysExpanded
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(light: .black(0.04), dark: .white(0.05)))
        )
    }

    private func message(_ text: String, symbol: String, color: Color, closeHelp: String?, close: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color == KM.textSecondary ? KM.textSecondary : KM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifierPrefix).message")
            refreshButton
            if let closeHelp {
                closeButton(help: closeHelp, action: close)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: height)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(light: .black(0.04), dark: .white(0.05)))
        )
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 7))
        .iconHelp(L("Look for hardware keys"))
        .disabled(isScanning)
        .accessibilityIdentifier("\(identifierPrefix).refresh")
    }

    private func closeButton(help: String, identifier: String = "close", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 7))
        .iconHelp(help)
        .accessibilityIdentifier("\(identifierPrefix).\(identifier)")
    }
}
