import Domain
import SwiftUI

/// Inherit / Custom sequence: the inherited one read-only with where it comes from, or a field with
/// an Insert menu and validation. Shared by the entry and group editors.
struct AutoTypeSequenceEditor: View {
    @Binding var sequence: String?
    let inherited: String
    /// "From group Work" / "Default".
    let inheritedSource: String
    let identifierPrefix: String

    private enum Mode: Hashable {
        case inherit
        case custom
    }

    private var mode: Binding<Mode> {
        Binding(
            get: { sequence == nil ? .inherit : .custom },
            set: { newMode in
                switch newMode {
                case .inherit:
                    sequence = nil
                case .custom:
                    if sequence == nil {
                        sequence = inherited
                    }
                }
            }
        )
    }

    private var text: Binding<String> {
        Binding(
            get: { sequence ?? "" },
            set: { sequence = $0 }
        )
    }

    private var error: AutoTypeSequenceError? {
        sequence.flatMap(AutoTypeSequence.validate)
    }

    private static let insertItems: [(String, String)] = [
        (L("Username"), "{USERNAME}"),
        (L("Password"), "{PASSWORD}"),
        (L("TOTP"), "{TOTP}"),
        (L("Tab"), "{TAB}"),
        (L("Enter"), "{ENTER}"),
        (L("Delay…"), "{DELAY 500}")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KMSegmentedControl(
                options: [(Mode.inherit, L("Inherit")), (Mode.custom, L("Custom"))],
                selection: mode,
                fontSize: 12,
                horizontalPadding: 12,
                identifierPrefix: "\(identifierPrefix).mode"
            )
            if sequence == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(inherited)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(identifierPrefix).inherited")
                    Text(inheritedSource)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(KM.insetFill)
                )
            } else {
                HStack(spacing: 6) {
                    TextField("", text: text)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("\(identifierPrefix).sequence")
                        .kmField(invalid: error != nil)
                    Menu {
                        ForEach(Self.insertItems, id: \.1) { item in
                            Button("\(item.0)  \(item.1)") {
                                sequence = (sequence ?? "") + item.1
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(L("Insert"))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 12))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
                    .fixedSize()
                    .accessibilityIdentifier("\(identifierPrefix).insert")
                }
                if let error {
                    Label(error.message, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.danger)
                        .accessibilityIdentifier("\(identifierPrefix).error")
                }
            }
        }
    }
}

/// The entry editor's Auto-Type section: a one-line summary that opens into the settings.
struct AutoTypeEditorSection: View {
    @Binding var settings: VaultAutoTypeSettings
    let inheritance: VaultAutoTypeInheritance
    @Binding var isExpanded: Bool

    private var isGroupOff: Bool {
        !inheritance.isEnabled
    }

    private var hasError: Bool {
        settings.sequence.flatMap(AutoTypeSequence.validate) != nil
    }

    var summary: String {
        if isGroupOff {
            return L("Off · turned off by group “\(inheritance.enabledSource ?? "")”")
        }
        guard settings.isEnabled else {
            return L("autoType.summary.off", default: "Off")
        }
        var text: String
        if hasError {
            text = L("Custom sequence has an error")
        } else if settings.sequence != nil {
            text = L("On · custom sequence")
        } else if let group = inheritance.sequenceSource {
            text = L("On · sequence from group \(group)")
        } else {
            text = L("On · default sequence")
        }
        let count = settings.associations.count
        if count > 0 {
            text += " · " + L("\(count) window associations")
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(hasError && settings.isEnabled && !isGroupOff ? KM.danger : (settings.isEnabled && !isGroupOff ? KM.textPrimary : KM.textSecondary))
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(KM.textSecondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("editor.autoType.toggleSection")

            if isExpanded {
                expanded
            }
        }
    }

    @ViewBuilder
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled && !isGroupOff },
                    set: { settings.isEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(KM.success)
                .accessibilityIdentifier("editor.autoType.enabled")
                Text(L("Enable Auto-Type for this entry"))
                    .font(.system(size: 13))
            }
            .opacity(isGroupOff ? 0.45 : 1)
            .disabled(isGroupOff)
            if isGroupOff {
                Label(L("Turned off by group “\(inheritance.enabledSource ?? "")”"), systemImage: "nosign")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
        }

        AutoTypeSequenceEditor(
            sequence: $settings.sequence,
            inherited: inheritance.sequence,
            inheritedSource: inheritance.sequenceSource.map { L("From group \($0)") } ?? L("autoType.source.default", default: "Default"),
            identifierPrefix: "editor.autoType"
        )

        associations
    }

    private var associations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Window associations"), systemImage: "macwindow.on.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KM.textSecondary)

            if settings.associations.isEmpty {
                Text(L("Matched by window title and website URL. Add an association for apps whose window title doesn't contain the entry title."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(L("Window title"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("Sequence"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 24, height: 1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KM.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)

                    ForEach(Array($settings.associations.enumerated()), id: \.element.id) { index, $association in
                        associationRow($association, index: index)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(KM.insetFill)
                )
            }

            Button {
                settings.associations.append(VaultAutoTypeAssociation(windowTitle: ""))
            } label: {
                Label(L("Add Association"), systemImage: "plus")
            }
            .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
            .accessibilityIdentifier("editor.autoType.addAssociation")
        }
        .padding(.top, 4)
    }

    private func associationRow(_ association: Binding<VaultAutoTypeAssociation>, index: Int) -> some View {
        let sequence = association.wrappedValue.sequence
        let error = sequence.trimmingCharacters(in: .whitespaces).isEmpty ? nil : AutoTypeSequence.validate(sequence)
        return HStack(spacing: 6) {
            TextField("*Steam*", text: association.windowTitle)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("editor.autoType.association.\(index).title")
                .kmField(height: 26)
            TextField(L("Use entry sequence"), text: association.sequence)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("editor.autoType.association.\(index).sequence")
                .kmField(invalid: error != nil, height: 26)
                .help(error?.message ?? "")
            Button {
                settings.associations.removeAll { $0.id == association.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
            .iconHelp(L("Remove"))
            .accessibilityIdentifier("editor.autoType.association.\(index).remove")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }
}

/// The entry card's Auto-Type line, shown only when the settings aren't the default ones.
struct AutoTypeDetailSummary: View {
    let entry: VaultEntry

    static func isShown(for entry: VaultEntry) -> Bool {
        entry.entryType == .login && (!entry.isAutoTypeEnabled || entry.autoType.sequence != nil || !entry.autoType.associations.isEmpty)
    }

    var body: some View {
        HStack(spacing: 8) {
            if entry.isAutoTypeEnabled {
                Text(entry.effectiveAutoTypeSequence)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                let count = entry.autoType.associations.count
                if count > 0 {
                    Label(L("\(count) window associations"), systemImage: "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(KM.subtleFill))
                        .fixedSize()
                }
            } else {
                Text(entry.autoTypeInheritance.isEnabled
                     ? L("autoType.summary.off", default: "Off")
                     : L("Off · turned off by group “\(entry.autoTypeInheritance.enabledSource ?? "")”"))
                    .font(.system(size: 13))
                    .foregroundStyle(KM.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.autoType")
    }
}
