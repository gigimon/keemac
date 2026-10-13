import Domain
import SwiftUI

struct GroupOption: Identifiable, Hashable {
    let path: String
    let title: String
    let depth: Int

    var id: String { path }
}

enum GroupEditorMode: Identifiable {
    case create(parentPath: String?)
    case edit(path: String, title: String, iconID: Int?)

    var id: String {
        switch self {
        case .create(let parentPath):
            return "create-group:\(parentPath ?? "root")"
        case .edit(let path, _, _):
            return "edit-group:\(path)"
        }
    }

    var title: String {
        switch self {
        case .create(let parentPath):
            return parentPath == nil ? L("New Group") : L("New Subgroup")
        case .edit:
            return L("Edit Group")
        }
    }

    var parentPath: String? {
        switch self {
        case .create(let parentPath):
            return parentPath
        case .edit(let path, _, _):
            let components = path.split(separator: ".").map(String.init)
            guard components.count > 1 else {
                return nil
            }
            return components.dropLast().joined(separator: ".")
        }
    }

    var initialTitle: String {
        switch self {
        case .create:
            return ""
        case .edit(_, let title, _):
            return title
        }
    }

    var initialIconID: Int? {
        switch self {
        case .create:
            return 48
        case .edit(_, _, let iconID):
            return iconID
        }
    }

    var submitTitle: String {
        switch self {
        case .create:
            return L("Create")
        case .edit:
            return L("Save")
        }
    }
}

struct GroupEditorSheet: View {
    let mode: GroupEditorMode
    let rootPath: String
    /// What the group inherits from the groups above it.
    let autoTypeInheritance: VaultAutoTypeInheritance
    let isSaving: Bool
    let onSubmit: (_ title: String, _ iconID: Int?, _ autoType: VaultGroupAutoType) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var iconID: Int?
    @State private var autoType: VaultGroupAutoType
    @FocusState private var isNameFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    init(
        mode: GroupEditorMode,
        rootPath: String,
        autoType: VaultGroupAutoType = .default,
        autoTypeInheritance: VaultAutoTypeInheritance = .root,
        isSaving: Bool,
        onSubmit: @escaping (_ title: String, _ iconID: Int?, _ autoType: VaultGroupAutoType) -> Void
    ) {
        self.mode = mode
        self.rootPath = rootPath
        self.autoTypeInheritance = autoTypeInheritance
        self.isSaving = isSaving
        self.onSubmit = onSubmit
        _title = State(initialValue: mode.initialTitle)
        _iconID = State(initialValue: mode.initialIconID)
        _autoType = State(initialValue: autoType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? "folder.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(KM.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(KM.accent.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(.system(size: 15, weight: .bold))
                    Text(pathPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 12) {
                Text(L("Name"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                TextField("", text: $title)
                    .focused($isNameFocused)
                    .accessibilityIdentifier("groupEditor.name")
                    .kmField(focused: isNameFocused, background: KM.raisedFieldBackground)
                    .onSubmit(submit)
            }
            .padding(.top, 18)

            HStack(alignment: .top, spacing: 12) {
                Text(L("Icon"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.top, 8)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(DefaultKeePassIconMapper.availableIconIDs, id: \.self) { candidate in
                            iconCell(candidate)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 176)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(KM.insetFill)
                )
            }
            .padding(.top, 14)

            autoTypeSection
                .padding(.top, 16)

            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("groupEditor.cancel")

                Button(mode.submitTitle, action: submit)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("groupEditor.submit")
                    .disabled(trimmedTitle.isEmpty || isSaving || autoTypeError)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 400)
        .background(KM.sheetBackground)
        .onAppear {
            isNameFocused = true
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var autoTypeError: Bool {
        autoType.sequence.flatMap(AutoTypeSequence.validate) != nil
    }

    private var autoTypeSubtitle: String {
        switch autoType.enabled {
        case .inherit:
            let state = autoTypeInheritance.isEnabled ? L("autoType.state.on", default: "on") : L("autoType.state.off", default: "off")
            if let source = autoTypeInheritance.enabledSource {
                return L("Inherited: \(state) from group \(source)")
            }
            return L("Inherited: \(state) (default)")
        case .on:
            return L("On for entries in this group")
        case .off:
            return L("Off for entries in this group")
        }
    }

    private var autoTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Auto-Type"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(autoTypeSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                KMSegmentedControl(
                    options: [
                        (VaultInheritedFlag.inherit, L("Inherit")),
                        (VaultInheritedFlag.on, L("autoType.flag.on", default: "On")),
                        (VaultInheritedFlag.off, L("autoType.flag.off", default: "Off"))
                    ],
                    selection: $autoType.enabled,
                    fontSize: 12,
                    horizontalPadding: 10,
                    identifierPrefix: "groupEditor.autoType.enabled"
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Default sequence"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                AutoTypeSequenceEditor(
                    sequence: $autoType.sequence,
                    inherited: autoTypeInheritance.sequence,
                    inheritedSource: autoTypeInheritance.sequenceSource.map { L("From group \($0)") }
                        ?? L("autoType.source.default", default: "Default"),
                    identifierPrefix: "groupEditor.autoType"
                )
            }
            .opacity(autoType.enabled == .off ? 0.4 : 1)
            .disabled(autoType.enabled == .off)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    private var pathPreview: String {
        let parent = mode.parentPath.map { GroupPathFormatter.display($0, rootPath: rootPath) + " › " } ?? ""
        return parent + (trimmedTitle.isEmpty ? L("Untitled") : trimmedTitle)
    }

    private func iconCell(_ candidate: Int) -> some View {
        let isSelected = iconID == candidate
        return Button {
            iconID = candidate
        } label: {
            Image(systemName: DefaultKeePassIconMapper.symbolName(for: candidate) ?? "questionmark")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.white : KM.textPrimary)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? KM.accent : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .iconHelp(L("Icon \(candidate)"))
    }

    private func submit() {
        guard !trimmedTitle.isEmpty, !isSaving, !autoTypeError else {
            return
        }
        onSubmit(trimmedTitle, iconID, autoType)
    }
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String = L("Cancel")
    var isDestructive: Bool = true
    var badgeSymbol: String = "exclamationmark.triangle.fill"
    var badgeColor: Color = KM.warning
    /// Files the dialog is about (conflicting copies), listed under the message.
    var files: [ConfirmFile] = []
    let action: () -> Void
}

struct ConfirmFile: Identifiable {
    let name: String
    let detail: String

    var id: String { name }
}

struct ConfirmDialog: View {
    let request: ConfirmRequest
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    AppIconImage(size: 56)
                    Image(systemName: request.badgeSymbol)
                        .font(.system(size: 14))
                        .foregroundStyle(request.badgeColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(lightHex: 0xFFFFFF, darkHex: 0x2C2C30)))
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .offset(x: 6, y: 6)
                }

                Text(request.title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                Text(request.message)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                if !request.files.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(request.files.enumerated()), id: \.element.id) { index, file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .font(.system(size: 13))
                                    .foregroundStyle(KM.textSecondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(file.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .truncationMode(.middle)
                                    Text(file.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(KM.textSecondary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle().fill(KM.hairline).frame(height: 0.5)
                                }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KM.insetFill))
                    .padding(.top, 12)
                }

                VStack(spacing: 6) {
                    Button(request.confirmTitle) {
                        request.action()
                    }
                    .buttonStyle(KMButtonStyle(kind: request.isDestructive ? .destructive : .primary, height: 28, fullWidth: true, fontWeight: .semibold))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm.confirm")

                    Button(request.cancelTitle, action: onCancel)
                        .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, fullWidth: true, fontWeight: .regular))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("confirm.cancel")
                }
                .padding(.top, 16)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(width: 270)
            .kmFloatingPanel(cornerRadius: 20, background: KM.dialogBackground)
            .padding(.top, 150)
        }
        .transition(.opacity)
    }
}
