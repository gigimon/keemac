import Domain
import SwiftUI

/// What the selection panel shows about where the selected entries live.
struct EntrySelectionLocation: Equatable {
    let databaseName: String
    /// The common group (or the Trash), nil when the entries are in several groups.
    let groupSymbol: String?
    let groupPath: String?
}

/// Replaces the entry card while several entries are selected: a fan of their tiles, who they are,
/// and the bulk actions.
struct EntrySelectionPanel: View {
    let entries: [VaultEntry]
    let supportsTypes: Bool
    let layout: KMLayout
    let location: EntrySelectionLocation
    let isTrash: Bool
    /// Favorites exist only for the main database.
    let showsFavorite: Bool
    let allFavorite: Bool
    let usesRecycleBin: Bool
    let isBusy: Bool
    @Binding var tagEditor: BulkTagEditor?
    let knownTags: [String]
    let onMove: () -> Void
    let onOpenTags: () -> Void
    let onApplyTags: (BulkTagEditor) -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    private var isCompact: Bool { layout == .compact }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                tileFan
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .accessibilityIdentifier("selection.count")
                Text(Self.names(entries.map { $0.title.isEmpty ? L("Untitled") : $0.title }))
                    .font(.system(size: 13))
                    .foregroundStyle(KM.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .accessibilityIdentifier("selection.names")
                locationLine
                    .padding(.top, 10)
                buttons
                    .padding(.top, 24)
                Text(L("⌘-click to add or remove, ⇧-click to select a range, Esc to clear"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
            .frame(maxWidth: 460)
            .padding(isCompact ? EdgeInsets(top: 24, leading: 24, bottom: 28, trailing: 24) : EdgeInsets(top: 44, leading: 36, bottom: 36, trailing: 36))
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("selection.panel")
    }

    private var title: String {
        isTrash ? L("\(entries.count) entries in Trash") : L("\(entries.count) entries selected")
    }

    /// "GitHub, Jira and Mail" / "GitHub, Jira, Mail and 2 more".
    static func names(_ titles: [String]) -> String {
        guard titles.count > 1 else {
            return titles.first ?? ""
        }
        if titles.count <= 3 {
            return L("\(titles.dropLast().joined(separator: ", ")) and \(titles[titles.count - 1])")
        }
        return L("\(titles.prefix(3).joined(separator: ", ")) and \(titles.count - 3) more")
    }

    private var tileFan: some View {
        let fan = Array(entries.prefix(4))
        let center = Double(fan.count - 1) / 2
        return ZStack {
            ForEach(Array(fan.enumerated()), id: \.element.id) { index, entry in
                EntryTile(entry: entry, supportsTypes: supportsTypes, size: 56, cornerRadius: 14, fontSize: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(KM.windowBackground, lineWidth: 2)
                            .padding(-1)
                    )
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 4)
                    .rotationEffect(.degrees((Double(index) - center) * 7))
                    .offset(x: (Double(index) - center) * 26)
                    .zIndex(Double(index))
            }
        }
        .frame(width: 220, height: 84)
        .accessibilityHidden(true)
    }

    private var locationLine: some View {
        HStack(spacing: 12) {
            Label(location.databaseName, systemImage: "cylinder.split.1x2")
            if let path = location.groupPath {
                Label(path, systemImage: location.groupSymbol ?? "folder")
            }
        }
        .labelStyle(SelectionLocationLabelStyle())
        .font(.system(size: 12))
        .foregroundStyle(KM.textSecondary)
        .lineLimit(1)
    }

    private var buttons: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            if isTrash {
                actionButton(L("Restore"), symbol: "arrow.uturn.backward", id: "selection.restore", action: onRestore)
                actionButton(L("Delete Permanently"), symbol: "trash.slash", id: "selection.delete", isDanger: true, action: onDelete)
            } else {
                actionButton(L("Move to Group…"), symbol: "folder", id: "selection.move", action: onMove)
                actionButton(L("Tags…"), symbol: "tag", id: "selection.tags", action: onOpenTags)
                    .popover(isPresented: Binding(get: { tagEditor != nil }, set: { if !$0 { tagEditor = nil } }), arrowEdge: .bottom) {
                        if let editor = tagEditor {
                            TagSelectionPopover(
                                editor: editor,
                                knownTags: knownTags,
                                onCancel: { tagEditor = nil },
                                onDone: { result in
                                    tagEditor = nil
                                    onApplyTags(result)
                                }
                            )
                        }
                    }
                if showsFavorite {
                    actionButton(
                        allFavorite ? L("Remove from Favorites") : L("Add to Favorites"),
                        symbol: allFavorite ? "star.fill" : "star",
                        id: "selection.favorite",
                        tint: allFavorite ? KM.warning : nil,
                        action: onFavorite
                    )
                }
                actionButton(
                    usesRecycleBin ? L("Move to Trash") : L("Delete Permanently"),
                    symbol: usesRecycleBin ? "trash" : "trash.slash",
                    id: "selection.delete",
                    isDanger: true,
                    action: onDelete
                )
            }
        }
        .disabled(isBusy)
    }

    private func actionButton(_ title: String, symbol: String, id: String, isDanger: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isCompact {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).font(.system(size: 15))
                        Text(title)
                    }
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 19))
                        Text(title)
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(isDanger ? KM.danger : (tint ?? KM.textPrimary))
            .frame(maxWidth: .infinity, minHeight: isCompact ? 36 : 64)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectionActionButtonStyle(layout: layout, isDanger: isDanger))
        .accessibilityIdentifier(id)
    }
}

private struct SelectionLocationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 12))
            configuration.title
        }
    }
}

/// Tahoe: soft filled tiles; Classic: white raised buttons; Compact: a smaller row style.
private struct SelectionActionButtonStyle: ButtonStyle {
    let layout: KMLayout
    let isDanger: Bool

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = layout == .classic ? 7 : (layout == .compact ? 8 : 14)
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .shadow(color: layout == .classic ? .black.opacity(0.08) : .clear, radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(layout == .classic ? KM.hairline : .clear, lineWidth: 0.5)
            )
    }

    private var fill: Color {
        if layout == .classic {
            return KM.raisedButtonBackground
        }
        return isDanger ? KM.danger.opacity(0.1) : KM.insetFill.opacity(1.3)
    }
}

/// Tags of the selection with tri-state checkboxes, plus a field that adds a tag to all of them.
struct TagSelectionPopover: View {
    @State var editor: BulkTagEditor
    let knownTags: [String]
    let onCancel: () -> Void
    let onDone: (BulkTagEditor) -> Void
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let suggestions = editor.suggestions(for: query, knownTags: knownTags)
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    TextField(L("New tag"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isFieldFocused)
                        .onSubmit { pickFirst(suggestions) }
                        .accessibilityIdentifier("tagPicker.field")
                }
                .kmField(height: 28)
                if !suggestions.tags.isEmpty || suggestions.canCreate {
                    suggestionList(suggestions)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10))

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(editor.tags, id: \.self) { tag in
                        tagRow(tag)
                    }
                    if editor.tags.isEmpty {
                        Text(L("No tags yet"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 6, trailing: 4))
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack(spacing: 8) {
                Text(editor.changeCount > 0 ? L("\(editor.changeCount) changes") : "")
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tagPicker.changes")
                Button(L("Cancel"), action: onCancel)
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("tagPicker.cancel")
                Button(L("Done")) { onDone(editor) }
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 24, horizontalPadding: 14, fontSize: 12))
                    .accessibilityIdentifier("tagPicker.done")
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        }
        .frame(width: 280)
        .onAppear {
            // The popover's window isn't key yet on appear.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private func pickFirst(_ suggestions: (tags: [String], canCreate: Bool)) {
        if let first = suggestions.tags.first {
            editor.add(first)
        } else if suggestions.canCreate {
            editor.add(query)
        }
        query = ""
    }

    private func suggestionList(_ suggestions: (tags: [String], canCreate: Bool)) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [(label: String, symbol: String, tag: String)] =
            suggestions.tags.map { ($0, "tag", $0) } + (suggestions.canCreate ? [(L("Create “\(trimmed)”"), "plus", trimmed)] : [])
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    editor.add(item.tag)
                    query = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.system(size: 11))
                        Text(item.label)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index == 0 {
                            Text("↩").font(.system(size: 11)).opacity(0.75)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(index == 0 ? Color.white : KM.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(index == 0 ? KM.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tagPicker.suggestion.\(item.tag)")
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KM.insetFill)
        )
    }

    private func tagRow(_ tag: String) -> some View {
        let state = editor.state(of: tag)
        let isChanged = editor.isChanged(tag)
        return Button {
            editor.cycle(tag)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(state == .none ? KM.raisedFieldBackground : KM.accent)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(state == .none ? Color.primary.opacity(0.3) : .clear, lineWidth: 0.5)
                    if state != .none {
                        Image(systemName: state == .all ? "checkmark" : "minus")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                Circle()
                    .fill(KM.tagColor(tag))
                    .frame(width: 8, height: 8)
                Text(tag)
                    .font(.system(size: 13, weight: isChanged ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state == .some, editor.originalState(of: tag) == .some {
                    Text(L("\(editor.count(of: tag)) of \(editor.entryCount)"))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                }
                Circle()
                    .fill(isChanged ? KM.accent : .clear)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag)
        .accessibilityValue(state == .all ? L("tagState.all", default: "All") : (state == .some ? L("tagState.some", default: "Some") : L("tagState.none", default: "None")))
        .accessibilityIdentifier("tagPicker.tag.\(tag)")
    }
}

/// Picks the group to move the selection to: the groups of its database, searchable.
struct MoveToGroupSheet: View {
    let entryCount: Int
    let databaseName: String
    /// The database's root first (depth 0), then its groups.
    let options: [GroupOption]
    /// Groups that already hold some of the selected entries.
    let currentPaths: Set<String>
    let onMove: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var target: String?

    private var filtered: [GroupOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return options
        }
        return options.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Moving is possible once a group is picked that doesn't already hold every selected entry.
    private var canMove: Bool {
        guard let target else {
            return false
        }
        return !(currentPaths == [target])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Move to Group"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("\(entryCount) entries · \(databaseName)"))
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                TextField(L("Search"), text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .accessibilityIdentifier("movePicker.search")
            }
            .kmField(height: 28)
            .padding(.top, 12)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(filtered) { option in
                        row(option)
                    }
                    if filtered.isEmpty {
                        Text(L("No groups match"))
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                            .padding(10)
                    }
                }
                .padding(4)
            }
            .frame(height: 260)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KM.insetFill)
            )
            .padding(.top, 10)

            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 14, fontWeight: .regular, fontSize: 13))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("movePicker.cancel")
                Button(L("Move \(entryCount) Entries")) {
                    if let target, canMove {
                        onMove(target)
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontSize: 13))
                .disabled(!canMove)
                .accessibilityIdentifier("movePicker.move")
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        if target == nil, filtered.count == 1 {
            target = filtered[0].path
        } else if let target, canMove {
            onMove(target)
        }
    }

    private func row(_ option: GroupOption) -> some View {
        let isTarget = option.path == target
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            Image(systemName: option.depth == 0 && option.path == options.first?.path ? "cylinder.split.1x2" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(isTarget ? Color.white : KM.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(option.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if currentPaths.contains(option.path) {
                Text(L("Current"))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isTarget ? Color.white.opacity(0.22) : KM.controlFill))
                    .foregroundStyle(isTarget ? Color.white : KM.textSecondary)
            }
        }
        .foregroundStyle(isTarget ? Color.white : KM.textPrimary)
        .padding(.leading, 8 + (isSearching ? 0 : CGFloat(option.depth) * 18))
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTarget ? KM.accent : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            target = option.path
            if canMove {
                onMove(option.path)
            }
        }
        .onTapGesture {
            target = option.path
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTarget ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("movePicker.group.\(option.title)")
    }
}

/// Bulk actions the browser hands to the view model; every call works on entries of one database.
public struct EntryBulkActions {
    public var move: @Sendable (_ ids: [UUID], _ groupPath: String?) async throws -> Void
    public var delete: @Sendable (_ ids: [UUID]) async throws -> Void
    public var restore: @Sendable (_ ids: [UUID]) async throws -> Void
    public var updateTags: @Sendable (_ ids: [UUID], _ adding: [String], _ removing: [String]) async throws -> Void
    public var setFavorite: (_ isFavorite: Bool, _ ids: [UUID]) -> Void

    public init(
        move: @escaping @Sendable (_ ids: [UUID], _ groupPath: String?) async throws -> Void = { _, _ in },
        delete: @escaping @Sendable (_ ids: [UUID]) async throws -> Void = { _ in },
        restore: @escaping @Sendable (_ ids: [UUID]) async throws -> Void = { _ in },
        updateTags: @escaping @Sendable (_ ids: [UUID], _ adding: [String], _ removing: [String]) async throws -> Void = { _, _, _ in },
        setFavorite: @escaping (_ isFavorite: Bool, _ ids: [UUID]) -> Void = { _, _ in }
    ) {
        self.move = move
        self.delete = delete
        self.restore = restore
        self.updateTags = updateTags
        self.setFavorite = setFavorite
    }
}
