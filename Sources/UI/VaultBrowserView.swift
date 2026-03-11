import AppKit
import CryptoKit
import Data
import Domain
import SwiftUI

public struct VaultBrowserView: View {
    private let minSidebarWidth: CGFloat = 220
    private let maxSidebarWidth: CGFloat = 320
    private let minEntriesWidth: CGFloat = 260
    private let maxEntriesWidth: CGFloat = 420
    private let minDetailWidth: CGFloat = 360
    private let dividerWidth: CGFloat = 1

    private struct GroupTreeNode: Identifiable, Hashable {
        let id: String
        let title: String
        let path: String
        let iconPNGData: Data?
        let iconID: Int?
        let children: [GroupTreeNode]?
    }

    private enum LibrarySelection: Hashable {
        case allItems
        case favorites
        case recent
        case trash
        case group(String)

        var id: String {
            switch self {
            case .allItems:
                return "library.all"
            case .favorites:
                return "library.favorites"
            case .recent:
                return "library.recent"
            case .trash:
                return "library.trash"
            case .group(let path):
                return "group.\(path)"
            }
        }

        init?(id: String) {
            switch id {
            case "library.all":
                self = .allItems
            case "library.favorites":
                self = .favorites
            case "library.recent":
                self = .recent
            case "library.trash":
                self = .trash
            default:
                guard id.hasPrefix("group.") else {
                    return nil
                }
                self = .group(String(id.dropFirst("group.".count)))
            }
        }
    }

    public let vault: LoadedVault
    public let favoriteEntryIDs: Set<UUID>
    public let recentViewedEntryIDs: [UUID]
    public let includeSubgroupEntries: Bool
    private let onCreateGroup: @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void
    private let onUpdateGroup: @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void
    private let onDeleteGroup: @Sendable (_ path: String) async throws -> Void
    private let onCreateEntry: @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void
    private let onUpdateEntry: @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void
    private let onDeleteEntry: @Sendable (_ id: UUID) async throws -> Void
    private let onRestoreEntry: @Sendable (_ id: UUID) async throws -> Void
    private let onRevertEntry: @Sendable (_ id: UUID, _ historyIndex: Int) async throws -> Void
    private let onToggleFavorite: (UUID) -> Void
    private let onEntryViewed: (UUID) -> Void
    private let onLockVault: () -> Void
    @Environment(\.openSettings) private var openSettings

    @State private var searchText: String = ""
    @State private var selectedSidebarItemID: String? = LibrarySelection.allItems.id
    @State private var selectedEntryID: VaultEntry.ID?
    @State private var editorMode: EntryEditorMode?
    @State private var groupEditorMode: GroupEditorMode?
    @State private var deletingEntry: VaultEntry?
    @State private var deletingGroupPath: String?
    @State private var historyEntry: VaultEntry?
    @State private var operationErrorMessage: String?
    @State private var isPerformingMutation: Bool = false
    @State private var sidebarWidth: CGFloat = 250
    @State private var entriesWidth: CGFloat = 330
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var entriesDragStartWidth: CGFloat?

    public init(
        vault: LoadedVault,
        favoriteEntryIDs: Set<UUID>,
        recentViewedEntryIDs: [UUID],
        includeSubgroupEntries: Bool,
        onCreateGroup: @escaping @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void,
        onUpdateGroup: @escaping @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void,
        onDeleteGroup: @escaping @Sendable (_ path: String) async throws -> Void,
        onCreateEntry: @escaping @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void,
        onUpdateEntry: @escaping @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void,
        onDeleteEntry: @escaping @Sendable (_ id: UUID) async throws -> Void,
        onRestoreEntry: @escaping @Sendable (_ id: UUID) async throws -> Void,
        onRevertEntry: @escaping @Sendable (_ id: UUID, _ historyIndex: Int) async throws -> Void,
        onToggleFavorite: @escaping (UUID) -> Void,
        onEntryViewed: @escaping (UUID) -> Void,
        onLockVault: @escaping () -> Void
    ) {
        self.vault = vault
        self.favoriteEntryIDs = favoriteEntryIDs
        self.recentViewedEntryIDs = recentViewedEntryIDs
        self.includeSubgroupEntries = includeSubgroupEntries
        self.onCreateGroup = onCreateGroup
        self.onUpdateGroup = onUpdateGroup
        self.onDeleteGroup = onDeleteGroup
        self.onCreateEntry = onCreateEntry
        self.onUpdateEntry = onUpdateEntry
        self.onDeleteEntry = onDeleteEntry
        self.onRestoreEntry = onRestoreEntry
        self.onRevertEntry = onRevertEntry
        self.onToggleFavorite = onToggleFavorite
        self.onEntryViewed = onEntryViewed
        self.onLockVault = onLockVault
    }

    public var body: some View {
        contentView
            .sheet(item: $editorMode) { mode in
                VaultEntryEditorSheet(
                    mode: mode,
                    initialForm: mode.initialForm,
                    isSaving: isPerformingMutation
                ) { form in
                    await performEditorAction(mode: mode, form: form)
                }
            }
            .sheet(item: $groupEditorMode) { mode in
                GroupEditorSheet(mode: mode, isSaving: isPerformingMutation) { title, iconID in
                    await performGroupEditorAction(mode: mode, title: title, iconID: iconID)
                }
            }
            .sheet(item: $historyEntry) { entry in
                VaultEntryHistorySheet(entry: entry) { revisionIndex in
                    await performRevert(entryID: entry.id, historyIndex: revisionIndex)
                }
            }
            .alert("Delete Group?", isPresented: Binding(get: {
                deletingGroupPath != nil
            }, set: { isPresented in
                if !isPresented {
                    deletingGroupPath = nil
                }
            })) {
                Button("Delete", role: .destructive) {
                    guard let deletingGroupPath else {
                        return
                    }
                    Task {
                        await performDeleteGroup(deletingGroupPath)
                    }
                }
                .hoverHighlight(tint: .red)
                Button("Cancel", role: .cancel) {
                    deletingGroupPath = nil
                }
                .hoverHighlight()
            } message: {
                Text("The selected group and all nested entries/subgroups will be moved to Trash or removed, depending on vault settings.")
            }
            .alert("Delete Entry?", isPresented: Binding(get: {
                deletingEntry != nil
            }, set: { isPresented in
                if !isPresented {
                    deletingEntry = nil
                }
            })) {
                Button("Delete", role: .destructive) {
                    guard let deletingEntry else {
                        return
                    }
                    Task {
                        await performDelete(deletingEntry.id)
                    }
                }
                .hoverHighlight(tint: .red)
                Button("Cancel", role: .cancel) {
                    deletingEntry = nil
                }
                .hoverHighlight()
            } message: {
                Text("This operation is saved immediately and cannot be undone in KeeMac.")
            }
            .alert("Save Error", isPresented: Binding(get: {
                operationErrorMessage != nil
            }, set: { isPresented in
                if !isPresented {
                    operationErrorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {
                    operationErrorMessage = nil
                }
                .hoverHighlight()
            } message: {
                Text(operationErrorMessage ?? "Unknown error")
            }
    }

    private var contentView: AnyView {
        AnyView(
            baseContentView
                .toolbar(removing: .title)
        )
    }

    private var baseContentView: some View {
        splitView
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Button {
                            editorMode = .create(groupPath: selectedGroupPathForCreation)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("New entry")
                        .disabled(isPerformingMutation)

                        Button {
                            openSettings()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .help("Preferences")

                        Button {
                            onLockVault()
                        } label: {
                            Image(systemName: "lock")
                        }
                        .help("Lock vault")
                    }
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
            .toolbarRole(.editor)
            .tint(.blue)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                ensureValidSelection()
            }
            .onChange(of: vault.summary.groupCount) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: vault.summary.entryCount) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: selectedSidebarItemID) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: searchText) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: selectedEntryID) { _, newValue in
                guard let newValue else {
                    return
                }
                onEntryViewed(newValue)
            }
    }

    private var splitView: some View {
        GeometryReader { geometry in
            let layout = columnLayout(for: geometry.size.width)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: layout.sidebarWidth)

                resizeDivider
                    .gesture(sidebarResizeGesture(totalWidth: geometry.size.width, currentEntriesWidth: layout.entriesWidth))

                entriesList
                    .frame(width: layout.entriesWidth)

                resizeDivider
                    .gesture(entriesResizeGesture(totalWidth: geometry.size.width, currentSidebarWidth: layout.sidebarWidth))

                entryDetail
                    .frame(width: layout.detailWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var resizeDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.7))
            .frame(width: dividerWidth)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
    }

    private func columnLayout(for totalWidth: CGFloat) -> (sidebarWidth: CGFloat, entriesWidth: CGFloat, detailWidth: CGFloat) {
        let usableWidth = max(totalWidth - (dividerWidth * 2), minSidebarWidth + minEntriesWidth + minDetailWidth)

        let sidebarMax = min(maxSidebarWidth, usableWidth - minEntriesWidth - minDetailWidth)
        let resolvedSidebar = clamp(sidebarWidth, minSidebarWidth, sidebarMax)

        let entriesMax = min(maxEntriesWidth, usableWidth - resolvedSidebar - minDetailWidth)
        let resolvedEntries = clamp(entriesWidth, minEntriesWidth, entriesMax)

        let resolvedDetail = max(minDetailWidth, usableWidth - resolvedSidebar - resolvedEntries)
        return (resolvedSidebar, resolvedEntries, resolvedDetail)
    }

    private func sidebarResizeGesture(totalWidth: CGFloat, currentEntriesWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if sidebarDragStartWidth == nil {
                    sidebarDragStartWidth = columnLayout(for: totalWidth).sidebarWidth
                }

                let startWidth = sidebarDragStartWidth ?? columnLayout(for: totalWidth).sidebarWidth
                let usableWidth = max(totalWidth - (dividerWidth * 2), minSidebarWidth + minEntriesWidth + minDetailWidth)
                let maxWidth = min(maxSidebarWidth, usableWidth - currentEntriesWidth - minDetailWidth)
                sidebarWidth = clamp(startWidth + value.translation.width, minSidebarWidth, maxWidth)
            }
            .onEnded { _ in
                sidebarDragStartWidth = nil
            }
    }

    private func entriesResizeGesture(totalWidth: CGFloat, currentSidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if entriesDragStartWidth == nil {
                    entriesDragStartWidth = columnLayout(for: totalWidth).entriesWidth
                }

                let startWidth = entriesDragStartWidth ?? columnLayout(for: totalWidth).entriesWidth
                let usableWidth = max(totalWidth - (dividerWidth * 2), minSidebarWidth + minEntriesWidth + minDetailWidth)
                let maxWidth = min(maxEntriesWidth, usableWidth - currentSidebarWidth - minDetailWidth)
                entriesWidth = clamp(startWidth + value.translation.width, minEntriesWidth, maxWidth)
            }
            .onEnded { _ in
                entriesDragStartWidth = nil
            }
    }

    private func clamp(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private var sidebar: some View {
        List {
            Section {
                sidebarStaticRow(
                    title: "All Items",
                    symbol: "shippingbox",
                    selection: .allItems
                )
                    .contextMenu {
                        Button("New Entry") {
                            editorMode = .create(groupPath: nil)
                        }

                        Divider()

                        Button("New Group") {
                            groupEditorMode = .create(parentPath: nil)
                        }
                    }

                sidebarStaticRow(title: "Favorites", symbol: "star", selection: .favorites)
                sidebarStaticRow(title: "Recent", symbol: "clock.arrow.circlepath", selection: .recent)
                sidebarStaticRow(title: "Trash", symbol: "trash", selection: .trash)
            } header: {
                Text("Library")
            }

            Section {
                OutlineGroup(groupTree, children: \.children) { node in
                    HStack(spacing: 10) {
                        EntryIconView(
                            iconPNGData: node.iconPNGData,
                            iconID: node.iconID,
                            size: 14,
                            fallbackSystemImage: "folder.fill"
                        )
                        Text(node.title)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectSidebarItem(.group(node.path))
                    }
                    .listRowBackground(sidebarRowBackground(isSelected: currentLibrarySelection == .group(node.path)))
                    .contextMenu {
                        Button("New Entry") {
                            editorMode = .create(groupPath: node.path)
                        }

                        Divider()

                        Button("New Subgroup") {
                            groupEditorMode = .create(parentPath: node.path)
                        }

                        Button("Edit Group") {
                            if let group = vault.groups.first(where: { $0.path == node.path }) {
                                groupEditorMode = .edit(path: group.path, title: group.title, iconID: group.iconID)
                            }
                        }

                        Divider()

                        Button("Delete Group", role: .destructive) {
                            deletingGroupPath = node.path
                        }
                    }
                }
            } header: {
                Text("Folders")
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarStaticRow(title: String, symbol: String, selection: LibrarySelection) -> some View {
        let isSelected = currentLibrarySelection == selection

        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.callout)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectSidebarItem(selection)
        }
        .listRowBackground(sidebarRowBackground(isSelected: isSelected))
    }

    @ViewBuilder
    private func sidebarRowBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    private func selectSidebarItem(_ selection: LibrarySelection) {
        selectedSidebarItemID = selection.id
    }

    private var entriesList: some View {
        List(filteredEntries, selection: $selectedEntryID) { entry in
            HStack(alignment: .top, spacing: 10) {
                EntryIconView(
                    iconPNGData: entry.iconPNGData,
                    iconID: entry.iconID,
                    size: 16,
                    fallbackSystemImage: "key.fill"
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title)
                            .font(.headline)
                            .lineLimit(1)

                        if favoriteEntryIDs.contains(entry.id) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .help("Favorite")
                        }

                        if recentViewedEntryIDs.contains(entry.id) {
                            Image(systemName: "clock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Viewed recently")
                        }

                        Spacer(minLength: 0)
                    }
                    Text(entrySubtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Edit Entry") {
                    editorMode = .edit(entry: entry)
                }

                Button(favoriteEntryIDs.contains(entry.id) ? "Remove from Favorites" : "Add to Favorites") {
                    onToggleFavorite(entry.id)
                }

                Divider()

                if entry.isTrashed {
                    Button("Restore from Trash") {
                        Task {
                            await performRestore(entry.id)
                        }
                    }
                }

                Button("Delete Entry", role: .destructive) {
                    deletingEntry = entry
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredEntries.isEmpty {
                entriesEmptyState
            }
        }
    }

    private func entrySubtitle(_ entry: VaultEntry) -> String {
        let username = entry.username?.isEmpty == false ? entry.username! : nil
        let group = entry.groupPath.isEmpty ? nil : entry.groupPath
        return [username, group].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var entryDetail: some View {
        if let entry = selectedEntry {
            VaultEntryDetailView(
                entry: entry,
                onShowHistory: entry.history.isEmpty ? nil : {
                    historyEntry = entry
                },
                onEdit: isPerformingMutation ? nil : {
                    editorMode = .edit(entry: entry)
                },
                onDelete: nil
            )
        } else {
            ContentUnavailableView(
                "Select an Entry",
                systemImage: "key.viewfinder",
                description: Text(filteredEntries.isEmpty ? "No entries match the current filter." : "Choose an entry from the list.")
            )
        }
    }

    private var selectedEntry: VaultEntry? {
        guard let selectedEntryID else {
            return filteredEntries.first
        }
        return filteredEntries.first(where: { $0.id == selectedEntryID })
    }

    private var filteredEntries: [VaultEntry] {
        let entriesBySelection: [VaultEntry]
        switch currentLibrarySelection {
        case .allItems:
            entriesBySelection = vault.entries
                .filter { !$0.isTrashed }
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
        case .favorites:
            entriesBySelection = vault.entries
                .filter { favoriteEntryIDs.contains($0.id) && !$0.isTrashed }
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
        case .recent:
            let entriesByID = Dictionary(uniqueKeysWithValues: vault.entries.map { ($0.id, $0) })
            entriesBySelection = recentViewedEntryIDs.compactMap { id in
                guard let entry = entriesByID[id], !entry.isTrashed else {
                    return nil
                }
                return entry
            }
        case .trash:
            entriesBySelection = vault.entries
                .filter(\.isTrashed)
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
        case .group(let path):
            entriesBySelection = vault.entries
                .filter { entry in
                    guard !entry.isTrashed else {
                        return false
                    }
                    if includeSubgroupEntries {
                        return entry.groupPath == path || entry.groupPath.hasPrefix("\(path).")
                    }
                    return entry.groupPath == path
                }
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return entriesBySelection
        }

        let normalizedQuery = query.lowercased()
        return entriesBySelection.filter { entry in
            if entry.title.lowercased().contains(normalizedQuery) {
                return true
            }
            if let username = entry.username, username.lowercased().contains(normalizedQuery) {
                return true
            }
            if let urlText = entry.url?.absoluteString.lowercased(), urlText.contains(normalizedQuery) {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private var entriesEmptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No Entries in Scope",
                systemImage: "tray",
                description: Text("The selected group does not contain entries.")
            )
        } else {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text("Try a different title, username, or URL query.")
            )
        }
    }

    private var groupTree: [GroupTreeNode] {
        let groupIconsByPath = Dictionary(
            uniqueKeysWithValues: vault.groups
                .filter { !$0.path.isEmpty }
                .map { ($0.path, ($0.iconPNGData, $0.iconID)) }
        )
        return Self.buildGroupTree(from: Array(groupIconsByPath.keys), iconByPath: groupIconsByPath)
    }

    private func ensureValidSelection() {
        if case .group(let path) = currentLibrarySelection,
           !vault.groups.contains(where: { $0.path == path }) {
            selectedSidebarItemID = LibrarySelection.allItems.id
        }

        if let selectedEntryID, filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = filteredEntries.first?.id
    }

    private var currentLibrarySelection: LibrarySelection {
        guard let selectedSidebarItemID, let selection = LibrarySelection(id: selectedSidebarItemID) else {
            return .allItems
        }
        return selection
    }

    private func performEditorAction(mode: EntryEditorMode, form: VaultEntryForm) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            switch mode {
            case .create(let groupPath):
                try await onCreateEntry(groupPath, form)
            case .edit(let entry):
                try await onUpdateEntry(entry.id, form)
            }
            editorMode = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performDelete(_ id: UUID) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onDeleteEntry(id)
            deletingEntry = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performRestore(_ id: UUID) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onRestoreEntry(id)
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performRevert(entryID: UUID, historyIndex: Int) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onRevertEntry(entryID, historyIndex)
            historyEntry = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performGroupEditorAction(mode: GroupEditorMode, title: String, iconID: Int?) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            switch mode {
            case .create(let parentPath):
                try await onCreateGroup(parentPath, title, iconID)
            case .edit(let path, _, _):
                try await onUpdateGroup(path, title, iconID)
                if currentLibrarySelection == .group(path) {
                    selectedSidebarItemID = LibrarySelection.allItems.id
                }
            }
            groupEditorMode = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performDeleteGroup(_ path: String) async {
        guard !isPerformingMutation else {
            return
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await onDeleteGroup(path)
            if currentLibrarySelection == .group(path) {
                selectedSidebarItemID = LibrarySelection.allItems.id
            }
            deletingGroupPath = nil
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var selectedGroupPathForCreation: String? {
        if case .group(let path) = currentLibrarySelection {
            return path
        }
        return nil
    }

    private static func buildGroupTree(
        from paths: [String],
        iconByPath: [String: (pngData: Data?, iconID: Int?)]
    ) -> [GroupTreeNode] {
        final class Node {
            let title: String
            let path: String
            var iconPNGData: Data?
            var iconID: Int?
            var children: [String: Node] = [:]

            init(title: String, path: String, iconPNGData: Data? = nil, iconID: Int? = nil) {
                self.title = title
                self.path = path
                self.iconPNGData = iconPNGData
                self.iconID = iconID
            }
        }

        let root = Node(title: "", path: "")

        for path in paths.sorted() {
            let parts = path.split(separator: ".").map(String.init)
            guard !parts.isEmpty else {
                continue
            }

            var current = root
            var currentPath = ""

            for part in parts {
                currentPath = currentPath.isEmpty ? part : "\(currentPath).\(part)"
                if current.children[part] == nil {
                    let icon = iconByPath[currentPath]
                    current.children[part] = Node(
                        title: part,
                        path: currentPath,
                        iconPNGData: icon?.pngData ?? nil,
                        iconID: icon?.iconID ?? nil
                    )
                }
                if let next = current.children[part] {
                    let icon = iconByPath[currentPath]
                    if next.iconPNGData == nil {
                        next.iconPNGData = icon?.pngData ?? nil
                    }
                    if next.iconID == nil {
                        next.iconID = icon?.iconID ?? nil
                    }
                    current = next
                }
            }
        }

        func convert(_ node: Node) -> GroupTreeNode {
            let children = node.children.values
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map(convert)

            return GroupTreeNode(
                id: node.path,
                title: node.title,
                path: node.path,
                iconPNGData: node.iconPNGData,
                iconID: node.iconID,
                children: children.isEmpty ? nil : children
            )
        }

        return root.children.values
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(convert)
    }
}

private enum GroupEditorMode: Identifiable {
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
        case .create:
            return "New Group"
        case .edit:
            return "Edit Group"
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

    var submitTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
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
            return nil
        case .edit(_, _, let iconID):
            return iconID
        }
    }

    var targetPath: String? {
        switch self {
        case .create:
            return nil
        case .edit(let path, _, _):
            return path
        }
    }
}

private enum EntryEditorMode: Identifiable {
    case create(groupPath: String?)
    case edit(entry: VaultEntry)

    var id: String {
        switch self {
        case .create(let groupPath):
            return "create:\(groupPath ?? "root")"
        case .edit(let entry):
            return "edit:\(entry.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "New Entry"
        case .edit:
            return "Edit Entry"
        }
    }

    var submitTitle: String {
        switch self {
        case .create:
            return "Create"
        case .edit:
            return "Save"
        }
    }

    var initialForm: VaultEntryForm {
        switch self {
        case .create:
            return VaultEntryForm(title: "")
        case .edit(let entry):
            let customFields = entry.customFields.map {
                VaultCustomFieldForm(
                    key: $0.key,
                    value: $0.value,
                    isProtected: $0.isProtected
                )
            }

            let otpForm: VaultOTPForm?
            if let otp = entry.otp {
                otpForm = VaultOTPForm(
                    secret: OTPSecretFormatter.encodeBase32(otp.secret),
                    digits: otp.digits,
                    period: otp.period,
                    algorithm: otp.algorithm,
                    storageStyle: entry.otpStorageStyle ?? .otpAuth
                )
            } else {
                otpForm = nil
            }

            return VaultEntryForm(
                title: entry.title,
                username: entry.username ?? "",
                password: entry.password ?? "",
                url: entry.url?.absoluteString ?? "",
                notes: entry.notes ?? "",
                iconID: entry.iconID,
                customFields: customFields,
                attachments: entry.attachments,
                otp: otpForm
            )
        }
    }

    var helperText: String {
        switch self {
        case .create:
            return "Select an icon to quickly recognize this entry in the list."
        case .edit:
            return "Update icon and fields for this entry."
        }
    }

    var groupPathHint: String? {
        switch self {
        case .create(let groupPath):
            return groupPath
        case .edit(let entry):
            return entry.groupPath.isEmpty ? nil : entry.groupPath
        }
    }
}

private struct GroupEditorSheet: View {
    let mode: GroupEditorMode
    let isSaving: Bool
    let onSubmit: @Sendable (String, Int?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var iconID: Int?
    @State private var validationMessage: String?

    init(mode: GroupEditorMode, isSaving: Bool, onSubmit: @escaping @Sendable (String, Int?) async -> Void) {
        self.mode = mode
        self.isSaving = isSaving
        self.onSubmit = onSubmit
        _title = State(initialValue: mode.initialTitle)
        _iconID = State(initialValue: mode.initialIconID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title)
                .font(.title3.weight(.semibold))

            if let parentPath = mode.parentPath, !parentPath.isEmpty {
                groupSheetReadOnlyField(title: "Parent", value: parentPath)
            } else {
                groupSheetReadOnlyField(title: "Parent", value: "Root", secondary: true)
            }

            if let targetPath = mode.targetPath {
                groupSheetReadOnlyField(title: "Path", value: targetPath, monospaced: true, secondary: true)
            }

            TextField("Group title", text: $title)
                .textFieldStyle(.plain)
                .keemacBoxedField()
                .onSubmit {
                    submit()
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    EntryIconView(
                        iconPNGData: nil,
                        iconID: iconID,
                        size: 20,
                        fallbackSystemImage: "folder.fill"
                    )
                    Text(iconID.map { "Icon \($0)" } ?? "Default icon")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Default") {
                        iconID = nil
                    }
                    .disabled(iconID == nil)
                }

                IconPalettePicker(selectedIconID: $iconID)
                    .frame(maxHeight: 120)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
                .keemacSecondaryActionButton()

                Spacer()

                Button(mode.submitTitle) {
                    submit()
                }
                .disabled(isSaving)
                .keemacPrimaryActionButton()
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func groupSheetReadOnlyField(
        title: String,
        value: String,
        monospaced: Bool = false,
        secondary: Bool = false
    ) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.quaternary)
                )
        }
    }

    private func submit() {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            validationMessage = "Group title is required."
            return
        }

        validationMessage = nil
        Task {
            await onSubmit(normalizedTitle, iconID)
        }
    }
}

private struct VaultEntryEditorSheet: View {
    let mode: EntryEditorMode
    let initialForm: VaultEntryForm
    let isSaving: Bool
    let onSubmit: @Sendable (VaultEntryForm) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: VaultEntryForm
    @State private var validationMessage: String?
    @State private var otpEnabled: Bool
    @State private var revealPassword: Bool = false
    @State private var showPasswordGenerator: Bool = false
    @State private var passwordGeneratorOptions = PasswordGenerator.Options()
    @State private var showOTPConfigurationEditor: Bool = false
    @State private var showAdvancedFields: Bool = false
    @State private var attachmentImportError: String?

    init(
        mode: EntryEditorMode,
        initialForm: VaultEntryForm,
        isSaving: Bool,
        onSubmit: @escaping @Sendable (VaultEntryForm) async -> Void
    ) {
        self.mode = mode
        self.initialForm = initialForm
        self.isSaving = isSaving
        self.onSubmit = onSubmit
        _form = State(initialValue: initialForm)
        _otpEnabled = State(initialValue: initialForm.otp != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(mode.title)
                .font(.headline.weight(.semibold))
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        ZStack(alignment: .bottomTrailing) {
                            EntryIconView(
                                iconPNGData: nil,
                                iconID: form.iconID,
                                size: 24,
                                fallbackSystemImage: "key.fill"
                            )
                            .frame(width: 54, height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )

                            Button {
                                showAdvancedFields = true
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: 6)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.helperText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let path = mode.groupPathHint {
                                Text("Group: \(path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    editorFieldRow(title: "Title") {
                        flatInputContainer {
                            TextField("e.g. GitHub", text: $form.title)
                                .textFieldStyle(.plain)
                        }
                    }

                    editorFieldRow(title: "Username") {
                        flatInputContainer {
                            TextField("email@example.com", text: $form.username)
                                .textFieldStyle(.plain)
                        }
                    }

                    editorFieldRow(title: "Password") {
                        VStack(alignment: .leading, spacing: 4) {
                            passwordField
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color.green)
                                        .frame(width: geometry.size.width * passwordStrengthProgress)
                                }
                            }
                            .frame(height: 3)
                        }
                    }

                    editorFieldRow(title: "URL") {
                        flatInputContainer {
                            HStack(spacing: 8) {
                                TextField("https://", text: $form.url)
                                    .textFieldStyle(.plain)
                                if let url = URL(string: form.url), !form.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Link(destination: url) {
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    editorFieldRow(title: "Notes") {
                        flatInputContainer(minHeight: 100) {
                            TextEditor(text: $form.notes)
                                .frame(minHeight: 84, maxHeight: 130)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                        }
                    }

                    otpPanel

                    attachmentsPanel

                    customFieldsPanel

                    if showAdvancedFields {
                        advancedPanel
                    }

                    if let attachmentImportError {
                        Text(attachmentImportError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(minWidth: 94)
                }
                .keemacSecondaryActionButton(minWidth: 94)
                .disabled(isSaving)

                Button {
                    submit()
                } label: {
                    Text(mode.submitTitle == "Save" ? "Save Changes" : mode.submitTitle)
                        .frame(minWidth: 126)
                }
                .keemacPrimaryActionButton(minWidth: 126)
                .disabled(isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 780, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var passwordField: some View {
        HStack(spacing: 8) {
            Group {
                if revealPassword {
                    TextField("Password", text: $form.password)
                        .textFieldStyle(.plain)
                } else {
                    SecureField("Password", text: $form.password)
                        .textFieldStyle(.plain)
                }
            }

            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealPassword ? "Hide password" : "Reveal password")
            .hoverHighlight()

            Button {
                showPasswordGenerator = true
            } label: {
                Image(systemName: "dice")
            }
            .buttonStyle(.borderless)
            .help("Generate password")
            .hoverHighlight()
            .popover(isPresented: $showPasswordGenerator, arrowEdge: .bottom) {
                PasswordGeneratorPopover(
                    options: $passwordGeneratorOptions,
                    onGenerate: {
                        form.password = PasswordGenerator.makePassword(options: passwordGeneratorOptions)
                        revealPassword = false
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private var otpPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ONE-TIME PASSWORD (OTP)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if otpEnabled {
                    Button(showOTPConfigurationEditor ? "Hide" : "Reveal") {
                        showOTPConfigurationEditor.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 8)
                } else {
                    Button("Setup Key") {
                        otpEnabled = true
                        form.otp = form.otp ?? VaultOTPForm(secret: "")
                        showOTPConfigurationEditor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 8)
                }
            }

            if otpEnabled, form.otp != nil {
                HStack(spacing: 8) {
                    Label("Secret Key Configured", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        otpEnabled = false
                        form.otp = nil
                        showOTPConfigurationEditor = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 8, tint: .red)
                    Button("Edit Configuration...") {
                        showOTPConfigurationEditor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverHighlight(cornerRadius: 8)
                }
            } else {
                Text("No OTP configured. Click Setup to add a secret key.")
                    .foregroundStyle(.secondary)
            }

            if showOTPConfigurationEditor {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Secret (Base32/Base64/Hex)", text: Binding(
                        get: { form.otp?.secret ?? "" },
                        set: { form.otp?.secret = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Picker("Algorithm", selection: Binding(
                            get: { form.otp?.algorithm ?? .sha1 },
                            set: { form.otp?.algorithm = $0 }
                        )) {
                            Text("SHA1").tag(VaultOTPAlgorithm.sha1)
                            Text("SHA256").tag(VaultOTPAlgorithm.sha256)
                            Text("SHA512").tag(VaultOTPAlgorithm.sha512)
                        }
                        Picker("Storage", selection: Binding(
                            get: { form.otp?.storageStyle ?? .otpAuth },
                            set: { form.otp?.storageStyle = $0 }
                        )) {
                            Text("otpauth URL").tag(VaultOTPStorageStyle.otpAuth)
                            Text("Native TimeOTP").tag(VaultOTPStorageStyle.native)
                        }
                    }

                    HStack(spacing: 10) {
                        Stepper(
                            "Digits: \(form.otp?.digits ?? 6)",
                            value: Binding(
                                get: { form.otp?.digits ?? 6 },
                                set: { form.otp?.digits = $0 }
                            ),
                            in: 6...9
                        )
                        Stepper(
                            "Period: \(form.otp?.period ?? 30)s",
                            value: Binding(
                                get: { form.otp?.period ?? 30 },
                                set: { form.otp?.period = $0 }
                            ),
                            in: 1...120
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Advanced")
                    .font(.headline)
                Spacer()
                Button("Hide") {
                    showAdvancedFields = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverHighlight(cornerRadius: 8)
            }

            HStack(spacing: 10) {
                EntryIconView(
                    iconPNGData: nil,
                    iconID: form.iconID,
                    size: 20,
                    fallbackSystemImage: "key.fill"
                )
                Text(form.iconID.map { "Icon \($0)" } ?? "Default icon")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Default") {
                    form.iconID = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverHighlight(cornerRadius: 8)
            }

            IconPalettePicker(selectedIconID: $form.iconID)

        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private var attachmentsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Attachment") {
                    importAttachments()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverHighlight(cornerRadius: 8)
            }

            if form.attachments.isEmpty {
                Text("No attachments")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(form.attachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Protected", isOn: attachmentProtectionBinding(for: attachment.id))
                            .toggleStyle(.checkbox)
                        Button(role: .destructive) {
                            form.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(tint: .red)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private var customFieldsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom Fields")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Custom Field") {
                    form.customFields.append(
                        VaultCustomFieldForm(key: "", value: "", isProtected: false)
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverHighlight(cornerRadius: 8)
            }

            if form.customFields.isEmpty {
                Text("No custom fields")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(form.customFields) { field in
                    HStack(spacing: 8) {
                        TextField("Key", text: customFieldKeyBinding(for: field.id))
                            .textFieldStyle(.roundedBorder)
                        TextField("Value", text: customFieldValueBinding(for: field.id))
                            .textFieldStyle(.roundedBorder)
                        Toggle("Protected", isOn: customFieldProtectionBinding(for: field.id))
                            .toggleStyle(.checkbox)
                        Button(role: .destructive) {
                            form.customFields.removeAll(where: { $0.id == field.id })
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(tint: .red)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private func editorFieldRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .frame(width: 82, alignment: .trailing)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func flatInputContainer<Content: View>(minHeight: CGFloat = 38, @ViewBuilder content: () -> Content) -> some View {
        content()
            .keemacBoxedField(minHeight: minHeight, cornerRadius: 7)
    }

    private var passwordStrengthProgress: CGFloat {
        guard !form.password.isEmpty else {
            return 0
        }
        var score: CGFloat = min(CGFloat(form.password.count) / 20.0, 1.0) * 0.45
        if form.password.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 0.15 }
        if form.password.rangeOfCharacter(from: .decimalDigits) != nil { score += 0.15 }
        if form.password.rangeOfCharacter(from: CharacterSet.punctuationCharacters.union(.symbols)) != nil { score += 0.25 }
        return min(score, 1.0)
    }

    private func submit() {
        validationMessage = validate(form: form, otpEnabled: otpEnabled)
        guard validationMessage == nil else {
            return
        }

        if !otpEnabled {
            form.otp = nil
        }

        let formToSubmit = form
        Task {
            await onSubmit(formToSubmit)
        }
    }

    private func validate(form: VaultEntryForm, otpEnabled: Bool) -> String? {
        if form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }

        var keySet = Set<String>()
        for field in form.customFields {
            let trimmedKey = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                return "Custom field key cannot be empty."
            }
            let normalized = trimmedKey.lowercased()
            if keySet.contains(normalized) {
                return "Custom field keys must be unique."
            }
            keySet.insert(normalized)
        }

        if otpEnabled {
            guard let otp = form.otp else {
                return "OTP configuration is incomplete."
            }
            if otp.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OTP secret is required."
            }
            if otp.digits < 6 || otp.digits > 9 {
                return "OTP digits must be between 6 and 9."
            }
            if otp.period < 1 {
                return "OTP period must be positive."
            }
        }

        return nil
    }

    private func attachmentProtectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                form.attachments.first(where: { $0.id == id })?.isProtected ?? false
            },
            set: { isProtected in
                guard let index = form.attachments.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let attachment = form.attachments[index]
                form.attachments[index] = VaultAttachment(
                    name: attachment.name,
                    data: attachment.data,
                    isProtected: isProtected
                )
            }
        )
    }

    private func customFieldKeyBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                form.customFields.first(where: { $0.id == id })?.key ?? ""
            },
            set: { newValue in
                guard let index = form.customFields.firstIndex(where: { $0.id == id }) else {
                    return
                }
                form.customFields[index].key = newValue
            }
        )
    }

    private func customFieldValueBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                form.customFields.first(where: { $0.id == id })?.value ?? ""
            },
            set: { newValue in
                guard let index = form.customFields.firstIndex(where: { $0.id == id }) else {
                    return
                }
                form.customFields[index].value = newValue
            }
        )
    }

    private func customFieldProtectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                form.customFields.first(where: { $0.id == id })?.isProtected ?? false
            },
            set: { isProtected in
                guard let index = form.customFields.firstIndex(where: { $0.id == id }) else {
                    return
                }
                form.customFields[index].isProtected = isProtected
            }
        )
    }

    private func importAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = "Add Attachments"

        guard panel.runModal() == .OK else {
            return
        }

        do {
            let imported = try panel.urls.map { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                return VaultAttachment(name: url.lastPathComponent, data: data)
            }

            for attachment in imported {
                form.attachments.removeAll { $0.name == attachment.name }
                form.attachments.append(attachment)
            }
            form.attachments.sort { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            attachmentImportError = nil
        } catch {
            attachmentImportError = "Failed to import attachment: \(error.localizedDescription)"
        }
    }
}

private struct VaultEntryDetailView: View {
    let entry: VaultEntry
    let onShowHistory: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var revealPassword: Bool = false
    @State private var now: Date = .now
    private let otpTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                EntryIconView(
                    iconPNGData: entry.iconPNGData,
                    iconID: entry.iconID,
                    size: 40,
                    fallbackSystemImage: "key.fill"
                )
                .frame(width: 74, height: 74)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                VStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 44 / 2, weight: .semibold))
                    Text("Modified: \(formattedModifiedDate)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                detailField(title: "Username") {
                    HStack {
                        Text(entry.username ?? "-")
                            .textSelection(.enabled)
                        Spacer()
                        if let username = entry.username, !username.isEmpty {
                            IconActionButton(systemImage: "doc.on.doc", helpText: "Copy username") {
                                copyToClipboard(username)
                            }
                        }
                    }
                }

                detailField(title: "Password") {
                    HStack {
                        if revealPassword {
                            Text(displayPassword)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(displayPassword)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.disabled)
                        }
                        Spacer()

                        if entry.password != nil {
                            IconActionButton(
                                systemImage: revealPassword ? "eye.slash" : "eye",
                                helpText: revealPassword ? "Hide password" : "Reveal password"
                            ) {
                                revealPassword.toggle()
                            }
                            if let password = entry.password, !password.isEmpty {
                                IconActionButton(systemImage: "doc.on.doc", helpText: "Copy password") {
                                    copyToClipboard(password)
                                }
                            }
                        }
                    }
                }

                if let otpState {
                    detailField(title: "TOTP") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(formattedOTPCode(otpState.code))
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                Spacer()
                                HStack(spacing: 8) {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.secondary)
                                    Text("\(otpState.remainingSeconds) s")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout.monospaced())
                            }

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule(style: .continuous)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.45))
                                    Capsule(style: .continuous)
                                        .fill(Color.green)
                                        .frame(width: geometry.size.width * otpProgressFraction(otpState))
                                }
                            }
                            .frame(height: 4)

                            HStack {
                                Spacer()
                                IconActionButton(systemImage: "doc.on.doc", helpText: "Copy OTP code") {
                                    copyToClipboard(otpState.code)
                                }
                            }
                        }
                    }
                }

                detailField(title: "Website") {
                    if let url = entry.url {
                        Link(url.absoluteString, destination: url)
                            .textSelection(.enabled)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }

                if let notes = entry.notes, !notes.isEmpty {
                    detailField(title: "Notes") {
                        Text(notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !entry.customFields.isEmpty {
                    detailField(title: "Custom Fields") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(entry.customFields.enumerated()), id: \.element.id) { _, field in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(field.key)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if field.isProtected {
                                        Text("••••••")
                                            .textSelection(.disabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(field.value)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }

                if !entry.attachments.isEmpty {
                    detailField(title: "Attachments") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entry.attachments) { attachment in
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(attachment.name)
                                            .lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    IconActionButton(systemImage: "square.and.arrow.down", helpText: "Save attachment") {
                                        exportAttachment(attachment)
                                    }
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if let url = entry.url {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Website", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                    .keemacPrimaryActionButton()
                    .disabled(entry.url == nil)

                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("Edit Entry", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .keemacSecondaryActionButton()
                        .disabled(false)
                    }

                    IconActionButton(
                        systemImage: "clock.arrow.circlepath",
                        helpText: "Show history"
                    ) {
                        onShowHistory?()
                    }
                    .disabled(onShowHistory == nil)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .onReceive(otpTimer) { value in
            now = value
        }
    }

    private func detailField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            content()
                .keemacBoxedField(minHeight: KeeMacControlMetrics.tallFieldHeight, cornerRadius: 10)
        }
    }

    private func formattedOTPCode(_ code: String) -> String {
        guard code.count >= 6 else {
            return code
        }
        let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
        return String(code[..<midpoint]) + " " + String(code[midpoint...])
    }

    private func otpProgressFraction(_ state: OTPCodeState) -> CGFloat {
        let elapsed = max(state.period - state.remainingSeconds, 0)
        guard state.period > 0 else {
            return 0
        }
        return min(max(CGFloat(elapsed) / CGFloat(state.period), 0), 1)
    }

    private var displayPassword: String {
        guard let password = entry.password, !password.isEmpty else {
            return "-"
        }
        if revealPassword {
            return password
        }
        return String(repeating: "•", count: max(password.count, 8))
    }

    private var formattedModifiedDate: String {
        guard let modifiedAt = entry.modifiedAt else {
            return "Unknown"
        }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var otpState: OTPCodeState? {
        guard let otp = entry.otp else {
            return nil
        }
        return OTPCodeGenerator.makeCodeState(from: otp, now: now)
    }

    private func copyToClipboard(_ value: String) {
        SensitiveClipboard.shared.copySensitiveText(value)
    }

    private func exportAttachment(_ attachment: VaultAttachment) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = attachment.name
        panel.title = "Save Attachment"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try attachment.data.write(to: destinationURL, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }
}

private struct VaultEntryHistorySheet: View {
    let entry: VaultEntry
    let onRevert: @Sendable (_ historyIndex: Int) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revertingRevisionIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Entry History")
                        .font(.title3.weight(.semibold))
                    Text(entry.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keemacSecondaryActionButton()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if historyChanges.isEmpty {
                        ContentUnavailableView(
                            "No History",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("This entry does not have saved revisions yet.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(historyChanges) { change in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(change.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(change.formattedDate)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if let historyIndex = change.historyIndex {
                                        IconActionButton(
                                            systemImage: "arrow.uturn.backward.circle",
                                            helpText: "Revert to this revision"
                                        ) {
                                            revertingRevisionIndex = historyIndex
                                            Task {
                                                await onRevert(historyIndex)
                                                revertingRevisionIndex = nil
                                            }
                                        }
                                        .disabled(revertingRevisionIndex != nil)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(change.details, id: \.self) { detail in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 6)
                                            Text(detail)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var historyChanges: [HistoryChangeItem] {
        let snapshots = [EntryRevisionSnapshot.current(entry)] + entry.history.enumerated().map(EntryRevisionSnapshot.revision)
        guard !snapshots.isEmpty else {
            return []
        }

        return snapshots.enumerated().map { index, snapshot in
            let olderSnapshot = snapshots.indices.contains(index + 1) ? snapshots[index + 1] : nil
            let details = olderSnapshot.map { snapshot.diffDetails(comparedTo: $0) } ?? ["Initial recorded revision"]
            return HistoryChangeItem(
                id: historyChangeID(for: snapshot, index: index),
                title: historyChangeTitle(for: index),
                formattedDate: Self.dateFormatter.string(from: snapshot.modifiedAt ?? .distantPast),
                details: details,
                historyIndex: snapshot.historyIndex
            )
        }
    }

    private func historyChangeTitle(for index: Int) -> String {
        switch index {
        case 0:
            return "Latest change"
        case 1:
            return "Previous change"
        default:
            return "Earlier change #\(index + 1)"
        }
    }

    private func historyChangeID(for snapshot: EntryRevisionSnapshot, index: Int) -> String {
        let timestamp = snapshot.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(index)-\(snapshot.id.uuidString)-\(timestamp)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct HistoryChangeItem: Identifiable {
    let id: String
    let title: String
    let formattedDate: String
    let details: [String]
    let historyIndex: Int?
}

private struct EntryRevisionSnapshot {
    let id: UUID
    let isCurrent: Bool
    let historyIndex: Int?
    let modifiedAt: Date?
    let groupPath: String
    let title: String
    let username: String?
    let password: String?
    let url: URL?
    let notes: String?
    let customFields: [VaultCustomField]
    let attachments: [VaultAttachment]
    let iconID: Int?
    let otp: VaultOTPConfiguration?
    let otpStorageStyle: VaultOTPStorageStyle?

    static func current(_ entry: VaultEntry) -> EntryRevisionSnapshot {
        EntryRevisionSnapshot(
            id: entry.id,
            isCurrent: true,
            historyIndex: nil,
            modifiedAt: entry.modifiedAt,
            groupPath: entry.groupPath,
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            customFields: entry.customFields,
            attachments: entry.attachments,
            iconID: entry.iconID,
            otp: entry.otp,
            otpStorageStyle: entry.otpStorageStyle
        )
    }

    static func revision(_ item: EnumeratedSequence<[VaultEntryRevision]>.Element) -> EntryRevisionSnapshot {
        let revision = item.element
        return EntryRevisionSnapshot(
            id: revision.id,
            isCurrent: false,
            historyIndex: item.offset,
            modifiedAt: revision.modifiedAt,
            groupPath: revision.groupPath,
            title: revision.title,
            username: revision.username,
            password: revision.password,
            url: revision.url,
            notes: revision.notes,
            customFields: revision.customFields,
            attachments: revision.attachments,
            iconID: revision.iconID,
            otp: revision.otp,
            otpStorageStyle: revision.otpStorageStyle
        )
    }

    func diffDetails(comparedTo older: EntryRevisionSnapshot) -> [String] {
        var details: [String] = []

        if title != older.title {
            details.append("Title: \(quoted(older.title)) -> \(quoted(title))")
        }
        if normalized(username) != normalized(older.username) {
            details.append("Username: \(describe(old: older.username, new: username))")
        }
        if normalized(password) != normalized(older.password) {
            details.append("Password updated")
        }
        if normalizedURL(url) != normalizedURL(older.url) {
            details.append("Website: \(describe(old: older.url?.absoluteString, new: url?.absoluteString))")
        }
        if normalized(groupPath) != normalized(older.groupPath) {
            details.append("Moved: \(describe(old: emptyAsDash(older.groupPath), new: emptyAsDash(groupPath)))")
        }
        if normalized(notes) != normalized(older.notes) {
            details.append("Notes updated")
        }
        if iconID != older.iconID {
            details.append("Icon changed")
        }
        if otpSummary != older.otpSummary {
            details.append("One-time password configuration updated")
        }
        if attachmentSummary != older.attachmentSummary {
            details.append("Attachments updated")
        }

        let customFieldChanges = customFieldDiff(comparedTo: older)
        details.append(contentsOf: customFieldChanges)

        return details
    }

    private var otpSummary: String {
        guard let otp else {
            return "none"
        }
        return "\(otp.algorithm.rawValue)|\(otp.digits)|\(otp.period)|\(otp.timeBase)|\(otpStorageStyle?.rawValue ?? "none")|\(otp.secret.base64EncodedString())"
    }

    private var attachmentSummary: String {
        attachments
            .map { "\($0.name)|\($0.data.base64EncodedString())|\($0.isProtected)" }
            .sorted()
            .joined(separator: "||")
    }

    private func customFieldDiff(comparedTo older: EntryRevisionSnapshot) -> [String] {
        let oldFields = Dictionary(uniqueKeysWithValues: older.customFields.map { ($0.key, $0) })
        let newFields = Dictionary(uniqueKeysWithValues: customFields.map { ($0.key, $0) })
        let keys = Set(oldFields.keys).union(newFields.keys).sorted()
        var details: [String] = []

        for key in keys {
            switch (oldFields[key], newFields[key]) {
            case let (nil, newField?):
                details.append("Custom field added: \(newField.key)")
            case let (oldField?, nil):
                details.append("Custom field removed: \(oldField.key)")
            case let (oldField?, newField?):
                if oldField.value != newField.value || oldField.isProtected != newField.isProtected {
                    details.append("Custom field updated: \(newField.key)")
                }
            case (nil, nil):
                break
            }
        }

        return details
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedURL(_ value: URL?) -> String {
        value?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func emptyAsDash(_ value: String) -> String {
        let normalizedValue = normalized(value)
        return normalizedValue.isEmpty ? "-" : normalizedValue
    }

    private func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    private func describe(old: String?, new: String?) -> String {
        "\(quoted(displayValue(old))) -> \(quoted(displayValue(new)))"
    }

    private func displayValue(_ value: String?) -> String {
        let normalizedValue = normalized(value)
        return normalizedValue.isEmpty ? "-" : normalizedValue
    }
}

private struct IconActionButton: View {
    let systemImage: String
    let helpText: String
    let tint: Color?
    let action: () -> Void

    init(systemImage: String, helpText: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.helpText = helpText
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .hoverHighlight()
    }
}

private struct IconPalettePicker: View {
    @Binding var selectedIconID: Int?

    private let columns = [
        GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(DefaultKeePassIconMapper.availableIconIDs, id: \.self) { iconID in
                    Button {
                        selectedIconID = iconID
                    } label: {
                        Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? "questionmark")
                            .frame(width: 18, height: 18)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedIconID == iconID ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selectedIconID == iconID ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Icon \(iconID)")
                    .hoverHighlight()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 96, maxHeight: 144)
    }
}

private struct PasswordGeneratorPopover: View {
    @Binding var options: PasswordGenerator.Options
    let onGenerate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Generator")
                .font(.headline)

            Stepper("Length: \(options.length)", value: $options.length, in: 8...128)

            Toggle("Lowercase (a-z)", isOn: $options.includeLowercase)
            Toggle("Uppercase (A-Z)", isOn: $options.includeUppercase)
            Toggle("Digits (0-9)", isOn: $options.includeDigits)
            Toggle("Symbols (!@#...)", isOn: $options.includeSymbols)

            if !options.hasAnyCharacterSet {
                Text("Select at least one character set.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }

                Spacer()

                Button("Generate") {
                    onGenerate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!options.hasAnyCharacterSet)
                .hoverHighlight(cornerRadius: 10)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private enum PasswordGenerator {
    struct Options: Equatable {
        var length: Int = 20
        var includeLowercase: Bool = true
        var includeUppercase: Bool = true
        var includeDigits: Bool = true
        var includeSymbols: Bool = true

        var hasAnyCharacterSet: Bool {
            includeLowercase || includeUppercase || includeDigits || includeSymbols
        }
    }

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.?/")

    static func makePassword(options: Options) -> String {
        var activeSets: [[Character]] = []
        if options.includeLowercase {
            activeSets.append(lowercase)
        }
        if options.includeUppercase {
            activeSets.append(uppercase)
        }
        if options.includeDigits {
            activeSets.append(digits)
        }
        if options.includeSymbols {
            activeSets.append(symbols)
        }

        if activeSets.isEmpty {
            activeSets = [lowercase]
        }

        let targetLength = max(options.length, activeSets.count)
        let fullSet = activeSets.flatMap { $0 }
        var rng = SystemRandomNumberGenerator()
        var result: [Character] = activeSets.compactMap { $0.randomElement(using: &rng) }

        while result.count < targetLength {
            if let next = fullSet.randomElement(using: &rng) {
                result.append(next)
            }
        }

        result.shuffle(using: &rng)
        return String(result)
    }
}

private struct EntryIconView: View {
    let iconPNGData: Data?
    let iconID: Int?
    let size: CGFloat
    let fallbackSystemImage: String

    var body: some View {
        Group {
            if let iconPNGData, let image = NSImage(data: iconPNGData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else {
                Image(systemName: DefaultKeePassIconMapper.symbolName(for: iconID) ?? fallbackSystemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }
}

private enum DefaultKeePassIconMapper {
    static let availableIconIDs = Array(0...68)

    static func symbolName(for iconID: Int?) -> String? {
        guard let iconID else {
            return nil
        }

        switch iconID {
        case 0: return "key.fill"
        case 1: return "network"
        case 2: return "exclamationmark.triangle.fill"
        case 3: return "server.rack"
        case 4: return "paperclip"
        case 5: return "globe"
        case 6: return "externaldrive.fill.badge.minus"
        case 7: return "note.text"
        case 8: return "dot.radiowaves.left.and.right"
        case 9: return "person.crop.circle"
        case 10: return "person.2.fill"
        case 11: return "camera.fill"
        case 12: return "desktopcomputer.trianglebadge.exclamationmark"
        case 13: return "key.horizontal.fill"
        case 14: return "battery.100"
        case 15: return "scanner.fill"
        case 16: return "safari.fill"
        case 17: return "opticaldiscdrive.fill"
        case 18: return "display"
        case 19: return "envelope.fill"
        case 20: return "ellipsis.circle.fill"
        case 21: return "calendar"
        case 22: return "textformat.abc"
        case 23: return "square.grid.3x3.fill"
        case 24: return "link"
        case 25: return "tray.fill"
        case 26: return "square.and.arrow.down.fill"
        case 27: return "externaldrive.fill.badge.minus"
        case 28: return "play.rectangle.fill"
        case 29: return "terminal.fill"
        case 30: return "terminal"
        case 31: return "printer.fill"
        case 32: return "externaldrive.connected.to.line.below.fill"
        case 33: return "play.fill"
        case 34: return "gearshape.fill"
        case 35: return "macwindow"
        case 36: return "archivebox.fill"
        case 37: return "percent"
        case 38: return "network.slash"
        case 39: return "clock.arrow.circlepath"
        case 40: return "envelope.badge.magnifyingglass"
        case 41: return "point.topleft.down.curvedto.point.bottomright.up"
        case 42: return "memorychip.fill"
        case 43: return "trash.fill"
        case 44: return "note.text"
        case 45: return "xmark.circle.fill"
        case 46: return "questionmark.circle.fill"
        case 47: return "shippingbox.fill"
        case 48: return "folder.fill"
        case 49: return "folder"
        case 50: return "archivebox.circle.fill"
        case 51: return "lock.open.fill"
        case 52: return "lock.fill"
        case 53: return "checkmark.circle.fill"
        case 54: return "signature"
        case 55: return "photo.fill"
        case 56: return "book.closed.fill"
        case 57: return "doc.text.fill"
        case 58: return "person.badge.shield.checkmark.fill"
        case 59: return "hammer.fill"
        case 60: return "house.fill"
        case 61: return "square.3.layers.3d.down.right.fill"
        case 62: return "lizard.fill"
        case 63: return "feather.fill"
        case 64: return "apple.logo"
        case 65: return "text.book.closed.fill"
        case 66: return "dollarsign.circle.fill"
        case 67: return "checkmark.seal.fill"
        case 68: return "phone.fill"
        default: return nil
        }
    }
}

private struct OTPCodeState {
    let code: String
    let remainingSeconds: Int
    let period: Int
}

private enum OTPCodeGenerator {
    static func makeCodeState(from config: VaultOTPConfiguration, now: Date) -> OTPCodeState? {
        let period = max(config.period, 1)
        let seconds = now.timeIntervalSince1970 - config.timeBase
        guard seconds >= 0 else {
            return nil
        }

        let counter = UInt64(floor(seconds / Double(period)))
        let counterData = counter.bigEndianData
        let hash = hmac(
            secret: config.secret,
            data: counterData,
            algorithm: config.algorithm
        )

        guard hash.count >= 20 else {
            return nil
        }

        let offset = Int(hash[hash.count - 1] & 0x0f)
        guard hash.count > offset + 3 else {
            return nil
        }

        let codeInt =
            (Int(hash[offset] & 0x7f) << 24) |
            (Int(hash[offset + 1]) << 16) |
            (Int(hash[offset + 2]) << 8) |
            Int(hash[offset + 3])
        let modulo = decimalModulo(digits: config.digits)
        guard modulo > 0 else {
            return nil
        }

        let code = String(codeInt % modulo).leftPadded(to: config.digits, with: "0")

        let elapsed = Int(floor(seconds))
        let remainder = elapsed % period
        let remaining = remainder == 0 ? period : (period - remainder)

        return OTPCodeState(code: code, remainingSeconds: remaining, period: period)
    }

    private static func hmac(secret: Data, data: Data, algorithm: VaultOTPAlgorithm) -> Data {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
    }

    private static func decimalModulo(digits: Int) -> Int {
        let clampedDigits = min(max(digits, 1), 9)
        var value = 1
        for _ in 0..<clampedDigits {
            value *= 10
        }
        return value
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else {
            return self
        }
        return String(repeating: String(character), count: length - count) + self
    }
}

private enum OTPSecretFormatter {
    static func encodeBase32(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let index = Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}
