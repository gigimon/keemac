import AppKit
import Data
import Domain
import SwiftUI

public struct VaultBrowserView: View {
    fileprivate struct GroupTreeNode: Identifiable, Hashable {
        let id: String
        let title: String
        let path: String
        let iconPNGData: Data?
        let iconID: Int?
        let children: [GroupTreeNode]?
    }

    fileprivate enum LibrarySelection: Hashable {
        case allItems
        case favorites
        case recentlyViewed
        case recentlyModified
        case trash
        case report
        case changedElsewhere
        case group(String)
        case tag(String)
        /// The trash of an additional database, by its key.
        case databaseTrash(String)

        var id: String {
            switch self {
            case .allItems:
                return "library.all"
            case .favorites:
                return "library.favorites"
            case .recentlyViewed:
                return "library.recent"
            case .recentlyModified:
                return "library.modified"
            case .trash:
                return "library.trash"
            case .report:
                return "library.report"
            case .changedElsewhere:
                return "library.changed"
            case .group(let path):
                return "group.\(path)"
            case .tag(let name):
                return "tag.\(name)"
            case .databaseTrash(let key):
                return "dbtrash.\(key)"
            }
        }

        init?(id: String) {
            switch id {
            case "library.all":
                self = .allItems
            case "library.favorites":
                self = .favorites
            case "library.recent":
                self = .recentlyViewed
            case "library.modified":
                self = .recentlyModified
            case "library.trash":
                self = .trash
            case "library.report":
                self = .report
            case "library.changed":
                self = .changedElsewhere
            default:
                if id.hasPrefix("group.") {
                    self = .group(String(id.dropFirst("group.".count)))
                } else if id.hasPrefix("tag.") {
                    self = .tag(String(id.dropFirst("tag.".count)))
                } else if id.hasPrefix("dbtrash.") {
                    self = .databaseTrash(String(id.dropFirst("dbtrash.".count)))
                } else {
                    return nil
                }
            }
        }
    }

    fileprivate enum SortOrder: String, CaseIterable {
        case title
        case modified

        var label: String {
            switch self {
            case .title:
                return L("Title")
            case .modified:
                return L("Last Modified")
            }
        }
    }

    private struct NewEntryRequest: Identifiable {
        let id = UUID()
        let mode: EntryTypeSheet.Mode

        init(groupPath: String?, type: VaultEntryType = .login, template: EntryTemplate? = nil) {
            mode = .create(groupPath: groupPath, type: type, template: template)
        }

        init(editing entry: VaultEntry) {
            mode = .edit(entry)
        }

        /// The additional database the entry goes to or lives in; nil for the main one.
        var databaseKey: String? {
            switch mode {
            case .create(let groupPath, _, _):
                return DatabaseScope.key(of: groupPath)
            case .edit(let entry):
                return DatabaseScope.key(of: entry.groupPath)
            }
        }
    }

    public let vault: LoadedVault
    public let favoriteEntryIDs: Set<UUID>
    public let recentViewedEntryIDs: [UUID]
    public let includeSubgroupEntries: Bool
    public let syncStatus: AppViewModel.SyncStatus
    public let externalChanges: [UUID: AppViewModel.ExternalChange]
    public let revealRequest: AppViewModel.RevealRequest?
    public let syncFailureMessage: String?
    public let showsDiskChangeBanner: Bool
    public let showsExpiryBanner: Bool
    public let expiryWarnDays: Int
    public let passwordHealthRequest: AppViewModel.PasswordHealthRequest?
    private let onReviewExpiry: () -> Void
    private let onDismissExpiryBanner: () -> Void
    private let onPasswordHealthHandled: () -> Void
    private let onMergeDiskChanges: () -> Void
    private let onShowDiskChanges: () -> Void
    private let onIgnoreDiskChanges: () -> Void
    private let onShowDiskChangeBanner: () -> Void
    private let onMergeDatabase: () -> Void
    private let onRevealHandled: () -> Void
    private let onExternalChangeSeen: (UUID) -> Void
    private let onRetrySync: () -> Void
    private let onDismissSyncFailure: () -> Void
    private let onCreateGroup: @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void
    private let onUpdateGroup: @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void
    private let onDeleteGroup: @Sendable (_ path: String) async throws -> Void
    private let onCreateEntry: @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void
    private let onUpdateEntry: @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void
    private let onDuplicateEntry: @Sendable (_ id: UUID, _ referencingCredentials: Bool) async throws -> UUID
    private let onDeleteEntry: @Sendable (_ id: UUID) async throws -> Void
    private let onEmptyTrash: @Sendable (_ ids: [UUID]) async throws -> Void
    private let onMoveEntry: @Sendable (_ id: UUID, _ groupPath: String?) async throws -> Void
    private let onMoveGroup: @Sendable (_ path: String, _ toParentPath: String?) async throws -> Void
    private let onRestoreEntry: @Sendable (_ id: UUID) async throws -> Void
    private let onAdvanceHOTP: @Sendable (_ id: UUID) async throws -> Void
    private let onRevertEntry: @Sendable (_ id: UUID, _ historyIndex: Int) async throws -> Void
    private let onToggleFavorite: (UUID) -> Void
    private let onEntryViewed: (UUID) -> Void
    private let onEntryUsed: (UUID) -> Void
    private let onLockVault: () -> Void
    private let onSidebarSelectionChanged: (String?) -> Void
    private let onExpandedGroupsChanged: (Set<String>) -> Void
    let additional: AdditionalDatabasesContext
    @Environment(\.openSettings) private var openSettings

    @State private var searchText: String = ""
    @State private var selectedSidebarItemID: String?
    @State private var expandedGroupPaths: Set<String>
    @State private var selectedEntryID: VaultEntry.ID?
    @State private var editingEntryID: VaultEntry.ID?
    @State private var newEntryRequest: NewEntryRequest?
    @State private var groupEditorMode: GroupEditorMode?
    @State private var historyEntry: VaultEntry?
    @State private var confirmRequest: ConfirmRequest?
    @State private var operationErrorMessage: String?
    @State private var isPerformingMutation: Bool = false
    @State private var newEntryBaseline: Set<UUID>?
    /// A duplicated entry to open in its editor once it shows up in `vault`.
    @State private var pendingEditEntryID: UUID?
    @State private var allItemsIsDropTargeted: Bool = false
    @AppStorage("keemac.report.tab") private var reportTab: ReportTab = .summary
    @State private var breachState: BreachCheckState = .idle
    @State private var breachTask: Task<Void, Never>?
    @AppStorage("keemac.report.expiringDays") private var expiringWithinDays: Int = 30
    @AppStorage("keemac.report.oldDays") private var oldAfterDays: Int = 365
    @AppStorage(KMLayout.storageKey) private var layoutRaw: String = KMLayout.tahoe.rawValue
    @AppStorage(KMLayout.showIconsKey) private var showsEntryIcons: Bool = true
    @AppStorage("keemac.browser.sortOrder") private var sortOrderRaw: String = SortOrder.title.rawValue
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    // Additional databases
    @State private var expandedDatabases: Set<String> = []
    @State private var unlockRequest: AdditionalUnlockRequest?
    @State private var transferFlow: TransferFlow?
    @State private var databaseInfoKey: String?

    public init(
        vault: LoadedVault,
        favoriteEntryIDs: Set<UUID>,
        recentViewedEntryIDs: [UUID],
        includeSubgroupEntries: Bool,
        syncStatus: AppViewModel.SyncStatus = .idle,
        externalChanges: [UUID: AppViewModel.ExternalChange] = [:],
        revealRequest: AppViewModel.RevealRequest? = nil,
        syncFailureMessage: String? = nil,
        showsDiskChangeBanner: Bool = false,
        showsExpiryBanner: Bool = false,
        expiryWarnDays: Int = 7,
        passwordHealthRequest: AppViewModel.PasswordHealthRequest? = nil,
        onReviewExpiry: @escaping () -> Void = {},
        onDismissExpiryBanner: @escaping () -> Void = {},
        onPasswordHealthHandled: @escaping () -> Void = {},
        onMergeDiskChanges: @escaping () -> Void = {},
        onShowDiskChanges: @escaping () -> Void = {},
        onIgnoreDiskChanges: @escaping () -> Void = {},
        onShowDiskChangeBanner: @escaping () -> Void = {},
        onMergeDatabase: @escaping () -> Void = {},
        onRevealHandled: @escaping () -> Void = {},
        onExternalChangeSeen: @escaping (UUID) -> Void = { _ in },
        onRetrySync: @escaping () -> Void = {},
        onDismissSyncFailure: @escaping () -> Void = {},
        initialSidebarSelectionID: String?,
        initialExpandedGroupPaths: Set<String>,
        onCreateGroup: @escaping @Sendable (_ parentPath: String?, _ title: String, _ iconID: Int?) async throws -> Void,
        onUpdateGroup: @escaping @Sendable (_ path: String, _ title: String, _ iconID: Int?) async throws -> Void,
        onDeleteGroup: @escaping @Sendable (_ path: String) async throws -> Void,
        onCreateEntry: @escaping @Sendable (_ groupPath: String?, _ form: VaultEntryForm) async throws -> Void,
        onUpdateEntry: @escaping @Sendable (_ id: UUID, _ form: VaultEntryForm) async throws -> Void,
        onDuplicateEntry: @escaping @Sendable (_ id: UUID, _ referencingCredentials: Bool) async throws -> UUID,
        onDeleteEntry: @escaping @Sendable (_ id: UUID) async throws -> Void,
        onEmptyTrash: @escaping @Sendable (_ ids: [UUID]) async throws -> Void,
        onMoveEntry: @escaping @Sendable (_ id: UUID, _ groupPath: String?) async throws -> Void,
        onMoveGroup: @escaping @Sendable (_ path: String, _ toParentPath: String?) async throws -> Void,
        onRestoreEntry: @escaping @Sendable (_ id: UUID) async throws -> Void,
        onRevertEntry: @escaping @Sendable (_ id: UUID, _ historyIndex: Int) async throws -> Void,
        onAdvanceHOTP: @escaping @Sendable (_ id: UUID) async throws -> Void = { _ in },
        onToggleFavorite: @escaping (UUID) -> Void,
        onEntryViewed: @escaping (UUID) -> Void,
        onEntryUsed: @escaping (UUID) -> Void,
        onLockVault: @escaping () -> Void,
        onSidebarSelectionChanged: @escaping (String?) -> Void,
        onExpandedGroupsChanged: @escaping (Set<String>) -> Void,
        additional: AdditionalDatabasesContext = AdditionalDatabasesContext()
    ) {
        self.additional = additional
        self.vault = vault
        self.favoriteEntryIDs = favoriteEntryIDs
        self.recentViewedEntryIDs = recentViewedEntryIDs
        self.includeSubgroupEntries = includeSubgroupEntries
        self.syncStatus = syncStatus
        self.externalChanges = externalChanges
        self.revealRequest = revealRequest
        self.syncFailureMessage = syncFailureMessage
        self.showsDiskChangeBanner = showsDiskChangeBanner
        self.showsExpiryBanner = showsExpiryBanner
        self.expiryWarnDays = expiryWarnDays
        self.passwordHealthRequest = passwordHealthRequest
        self.onReviewExpiry = onReviewExpiry
        self.onDismissExpiryBanner = onDismissExpiryBanner
        self.onPasswordHealthHandled = onPasswordHealthHandled
        self.onMergeDiskChanges = onMergeDiskChanges
        self.onShowDiskChanges = onShowDiskChanges
        self.onIgnoreDiskChanges = onIgnoreDiskChanges
        self.onShowDiskChangeBanner = onShowDiskChangeBanner
        self.onMergeDatabase = onMergeDatabase
        self.onRevealHandled = onRevealHandled
        self.onExternalChangeSeen = onExternalChangeSeen
        self.onRetrySync = onRetrySync
        self.onDismissSyncFailure = onDismissSyncFailure
        self.onCreateGroup = onCreateGroup
        self.onUpdateGroup = onUpdateGroup
        self.onDeleteGroup = onDeleteGroup
        self.onCreateEntry = onCreateEntry
        self.onUpdateEntry = onUpdateEntry
        self.onDuplicateEntry = onDuplicateEntry
        self.onDeleteEntry = onDeleteEntry
        self.onEmptyTrash = onEmptyTrash
        self.onMoveEntry = onMoveEntry
        self.onMoveGroup = onMoveGroup
        self.onRestoreEntry = onRestoreEntry
        self.onAdvanceHOTP = onAdvanceHOTP
        self.onRevertEntry = onRevertEntry
        self.onToggleFavorite = onToggleFavorite
        self.onEntryViewed = onEntryViewed
        self.onEntryUsed = onEntryUsed
        self.onLockVault = onLockVault
        self.onSidebarSelectionChanged = onSidebarSelectionChanged
        self.onExpandedGroupsChanged = onExpandedGroupsChanged
        _selectedSidebarItemID = State(initialValue: initialSidebarSelectionID ?? LibrarySelection.allItems.id)
        _expandedGroupPaths = State(initialValue: initialExpandedGroupPaths)
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    header
                    if showsDiskChangeBanner {
                        diskChangeBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if showsExpiryBanner, !isShowingReport, !expirySummary.isEmpty {
                        expiryBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if isShowingReport {
                        reportView
                    } else {
                        HStack(spacing: 0) {
                            entriesColumn
                            detailColumn
                        }
                    }
                }
            }
            .background(keyboardShortcuts)

            if let confirmRequest {
                ConfirmDialog(request: confirmRequest) {
                    self.confirmRequest = nil
                }
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirmRequest?.id)
        .environment(\.fieldCompletions, FieldCompletions(entries: vault.entries))
        .animation(.easeOut(duration: 0.2), value: showsDiskChangeBanner)
        .animation(.easeOut(duration: 0.2), value: showsExpiryBanner)
        .background(KM.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .tint(KM.accent)
        .sheet(item: $newEntryRequest) { request in
            let key = request.databaseKey
            EntryTypeSheet(
                mode: request.mode,
                groupOptions: groupOptions(forDatabase: key),
                rootPath: rootPath(ofDatabase: key),
                templates: key == nil ? entryTemplates : [],
                supportsTypes: key.map { additional.supportsEntryTypes[$0] ?? false } ?? supportsEntryTypes,
                databaseName: key.flatMap { additional.database($0)?.fileName } ?? vault.summary.fileName,
                isSaving: isPerformingMutation
            ) { groupPath, form in
                // The sheet returns nil for the root; an additional database's root has a path of its own.
                let groupPath = groupPath ?? key.flatMap { additional.rootPaths[$0] }
                Task {
                    if case .edit(let entry) = request.mode {
                        await performUpdateTypedEntry(entry, groupPath: groupPath, form: form)
                    } else {
                        await performCreateEntry(groupPath: groupPath, form: form)
                    }
                }
            }
            .environment(\.fieldCompletions, FieldCompletions(entries: vault.entries))
        }
        .sheet(item: $groupEditorMode) { mode in
            GroupEditorSheet(mode: mode, rootPath: rootPath(ofDatabase: DatabaseScope.key(of: mode.parentPath)), isSaving: isPerformingMutation) { title, iconID in
                Task {
                    await performGroupEditorAction(mode: mode, title: title, iconID: iconID)
                }
            }
        }
        .sheet(item: $unlockRequest) { request in
            AdditionalUnlockSheet(request: request) { password, keyFileURL in
                try await unlockAdditional(request, password: password, keyFileURL: keyFileURL)
            }
        }
        .sheet(item: $transferFlow) { _ in
            TransferConflictSheet(flow: $transferFlow) { flow in
                commitTransfer(flow.transfer, decisions: flow.decisions)
            }
        }
        .sheet(item: Binding(
            get: { databaseInfoKey.flatMap { additional.database($0) } },
            set: { if $0 == nil { databaseInfoKey = nil } }
        )) { database in
            AdditionalDatabaseInfoSheet(database: database, mainName: databaseName(nil))
        }
        .sheet(item: $historyEntry) { entry in
            VaultEntryHistorySheet(entry: entry) { revisionIndex in
                await performRevert(entryID: entry.id, historyIndex: revisionIndex)
            }
        }
        .alert(L("Save Error"), isPresented: Binding(get: {
            operationErrorMessage != nil
        }, set: { isPresented in
            if !isPresented {
                operationErrorMessage = nil
            }
        })) {
            Button(L("OK"), role: .cancel) {
                operationErrorMessage = nil
            }
        } message: {
            Text(operationErrorMessage ?? L("Unknown error"))
        }
        .onAppear {
            ensureValidSelection()
        }
        .onChange(of: vault.entries.count) { _, _ in
            selectCreatedEntryIfNeeded()
            openPendingEditIfReady()
            ensureValidSelection()
        }
        .onChange(of: vault.summary.groupCount) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: selectedSidebarItemID) { _, newValue in
            editingEntryID = nil
            ensureValidSelection()
            onSidebarSelectionChanged(newValue)
            additional.onActiveDatabaseChanged(activeDatabaseKey)
        }
        .onChange(of: activeDatabaseKey) { _, key in
            additional.onActiveDatabaseChanged(key)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.addAdditionalDatabase)) { _ in
            addAdditionalDatabase()
        }
        .onChange(of: additional.unlockedKeys) { oldKeys, newKeys in
            expandedDatabases.formUnion(newKeys.subtracting(oldKeys))
        }
        .onChange(of: searchText) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: selectedEntryID) { oldValue, newValue in
            if editingEntryID != newValue {
                editingEntryID = nil
            }
            if let oldValue, oldValue != newValue, externalChanges[oldValue] != nil {
                onExternalChangeSeen(oldValue)
            }
            guard let newValue else {
                return
            }
            onEntryViewed(newValue)
        }
        .onChange(of: expandedGroupPaths) { _, newValue in
            onExpandedGroupsChanged(newValue)
        }
        .onDisappear {
            breachTask?.cancel()
        }
        .onChange(of: revealRequest) { _, request in
            guard let request else {
                return
            }
            handleReveal(request)
        }
        .onChange(of: passwordHealthRequest, initial: true) { _, request in
            guard let request else {
                return
            }
            onPasswordHealthHandled()
            searchText = ""
            editingEntryID = nil
            expiringWithinDays = request.warnDays
            reportTab = .health
            selectedSidebarItemID = LibrarySelection.report.id
        }
        .onChange(of: syncFailureMessage) { _, message in
            guard let message else {
                return
            }
            confirmRequest = ConfirmRequest(
                title: L("Couldn’t merge changes from disk"),
                message: L("Your database is still open with your current changes. KeeMac will try again when the file changes.") + "\n\n" + message,
                confirmTitle: L("Retry"),
                cancelTitle: L("Keep Working"),
                isDestructive: false
            ) {
                confirmRequest = nil
                onRetrySync()
            }
        }
        .onChange(of: confirmRequest?.id) { _, newValue in
            if newValue == nil, syncFailureMessage != nil {
                onDismissSyncFailure()
            }
        }
    }

    // MARK: - Report

    private var isShowingReport: Bool {
        currentLibrarySelection == .report && trimmedQuery.isEmpty
    }

    private var report: DatabaseReport {
        DatabaseReport(
            vault: mainVault,
            rootPath: rootPath,
            favoriteEntryIDs: favoriteEntryIDs,
            expiringWithinDays: expiringWithinDays,
            oldAfterDays: oldAfterDays
        )
    }

    private var reportView: some View {
        DatabaseReportView(
            report: report,
            fileName: vault.summary.fileName,
            rootPath: rootPath,
            entriesByID: Dictionary(vault.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            tab: $reportTab,
            expiringWithinDays: $expiringWithinDays,
            oldAfterDays: $oldAfterDays,
            breachState: breachState,
            onOpenEntry: revealEntry,
            onChangeMasterKey: {
                NotificationCenter.default.post(name: AppCommand.openDatabaseSettings, object: nil)
            },
            onRunBreachCheck: runBreachCheck
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KM.windowBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    private func handleReveal(_ request: AppViewModel.RevealRequest) {
        onRevealHandled()
        let entries = request.entryIDs.compactMap { id in vault.entries.first { $0.id == id } }
        if let groupPath = request.groupPath {
            searchText = ""
            editingEntryID = nil
            selectedSidebarItemID = LibrarySelection.group(groupPath).id
            selectedEntryID = entries.first?.id ?? filteredEntries.first?.id
        } else if entries.count == 1, let entry = entries.first {
            revealEntry(entry)
        } else if !entries.isEmpty {
            searchText = ""
            selectedSidebarItemID = LibrarySelection.changedElsewhere.id
            selectedEntryID = filteredEntries.first?.id
        }
    }

    /// "Go to Entry" from a linked field in the editor.
    private func openLinkedEntry(_ id: UUID) {
        editingEntryID = nil
        if let target = vault.entries.first(where: { $0.id == id }) {
            revealEntry(target)
        }
    }

    private func revealEntry(_ entry: VaultEntry) {
        searchText = ""
        let key = DatabaseScope.key(of: entry.groupPath)
        if let key {
            expandedDatabases.insert(key)
        }
        if entry.isTrashed {
            selectedSidebarItemID = key.map { LibrarySelection.databaseTrash($0).id } ?? LibrarySelection.trash.id
        } else if entry.groupPath.isEmpty || entry.groupPath == rootPath {
            selectedSidebarItemID = LibrarySelection.allItems.id
        } else {
            selectedSidebarItemID = LibrarySelection.group(entry.groupPath).id
            var components = entry.groupPath.split(separator: ".").map(String.init)
            while components.count > 1 {
                components.removeLast()
                expandedGroupPaths.insert(components.joined(separator: "."))
            }
        }
        selectedEntryID = entry.id
    }

    private func runBreachCheck() {
        breachTask?.cancel()
        // Passwords that reference another entry are checked through that entry.
        let entries = mainVault.entries.filter { $0.references?.isReference(VaultEntryReferences.password) != true }
        breachState = .running(done: 0, total: 0)
        breachTask = Task {
            do {
                let result = try await BreachChecker.check(entries: entries) { done, total in
                    breachState = .running(done: done, total: total)
                }
                breachState = .finished(result)
            } catch is CancellationError {
                breachState = .idle
            } catch {
                breachState = .failed((error as? URLError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            WindowDragRegion()
                .frame(height: layout.hasFloatingSidebar ? 38 : 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    libraryRows
                        .padding(.top, 4)

                    sidebarSectionHeader(vault.summary.fileName)
                        .contextMenu {
                            Button(L("New Group")) {
                                groupEditorMode = .create(parentPath: nil)
                            }
                        }

                    ForEach(groupTree) { node in
                        GroupTreeRowView(
                            node: node,
                            depth: 0,
                            expandedGroupPaths: $expandedGroupPaths,
                            currentSelection: currentLibrarySelection,
                            counts: groupCounts,
                            onSelect: { selectSidebarItem(.group($0)) },
                            onCreateEntry: { newEntryRequest = NewEntryRequest(groupPath: $0) },
                            onCreateSubgroup: { groupEditorMode = .create(parentPath: $0) },
                            onEditGroup: editGroup,
                            onDeleteGroup: confirmDeleteGroup,
                            onMoveEntry: { id, path in
                                Task {
                                    await performMoveEntry(id: id, toGroupPath: path)
                                }
                            },
                            onMoveGroup: { sourcePath, parentPath in
                                Task {
                                    await performMoveGroup(path: sourcePath, toParentPath: parentPath)
                                }
                            },
                            transferTargets: transferTargets(excluding: nil),
                            onTransferGroup: { path, target, isCopy in
                                startTransfer(entryIDs: [], groupPath: path, to: target, isCopy: isCopy)
                            }
                        )
                    }

                    additionalSections

                    if !availableTags.isEmpty {
                        sidebarSectionHeader(L("Tags"))
                        ForEach(availableTags, id: \.self) { tag in
                            SidebarRow(
                                title: tag,
                                count: tagCount(tag),
                                isSelected: currentLibrarySelection == .tag(tag)
                            ) {
                                Circle()
                                    .fill(KM.tagColor(tag))
                                    .frame(width: 9, height: 9)
                                    .frame(width: 20)
                            }
                            .onTapGesture {
                                selectSidebarItem(.tag(tag))
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(
            RoundedRectangle(cornerRadius: layout.hasFloatingSidebar ? 16 : 0, style: .continuous)
                .fill(KM.sidebarBackground)
        )
        .overlay {
            if layout.hasFloatingSidebar {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(KM.hairline, lineWidth: 0.5)
            }
        }
        .overlay(alignment: .trailing) {
            if !layout.hasFloatingSidebar {
                Rectangle().fill(KM.separator).frame(width: 0.5)
            }
        }
        .shadow(color: .black.opacity(layout.hasFloatingSidebar ? 0.06 : 0), radius: 5, y: 2)
        .padding([.leading, .bottom], layout.hasFloatingSidebar ? 8 : 0)
        .padding(.top, layout.hasFloatingSidebar ? 6 : 0)
        .frame(width: layout.hasFloatingSidebar ? 236 : 244, alignment: .leading)
    }

    private var layout: KMLayout {
        KMLayout(rawValue: layoutRaw) ?? .tahoe
    }

    @ViewBuilder
    private var libraryRows: some View {
        let live = liveEntries
        libraryRow(.allItems, title: L("All Entries"), symbol: "tray.full", count: live.count, isDropTargeted: allItemsIsDropTargeted)
            .contextMenu {
                Button(L("New Entry")) {
                    newEntryRequest = NewEntryRequest(groupPath: nil)
                }
                Button(L("New Group")) {
                    groupEditorMode = .create(parentPath: nil)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                SidebarDragPayload.handleDrop(
                    payloads: payloads,
                    targetGroupPath: nil,
                    onMoveEntry: { id, path in
                        Task {
                            await performMoveEntry(id: id, toGroupPath: path)
                        }
                    },
                    onMoveGroup: { sourcePath, parentPath in
                        Task {
                            await performMoveGroup(path: sourcePath, toParentPath: parentPath)
                        }
                    }
                )
            } isTargeted: { targeted in
                allItemsIsDropTargeted = targeted
            }
        libraryRow(.favorites, title: L("Favorites"), symbol: "star", count: live.filter { favoriteEntryIDs.contains($0.id) }.count)
        libraryRow(.recentlyViewed, title: L("Recently Viewed"), symbol: "eye", count: nil)
        libraryRow(.recentlyModified, title: L("Recently Modified"), symbol: "clock", count: nil)
        libraryRow(.trash, title: L("Trash"), symbol: "trash", count: mainTrashedEntries.count)
        libraryRow(.report, title: L("Database Report"), symbol: "waveform.path.ecg", count: report.issueCount, pills: expiryPills)
    }

    private func libraryRow(
        _ selection: LibrarySelection,
        title: String,
        symbol: String,
        count: Int?,
        isDropTargeted: Bool = false,
        pills: [SidebarPill] = []
    ) -> some View {
        SidebarRow(
            title: title,
            count: count,
            pills: pills,
            isSelected: currentLibrarySelection == selection && trimmedQuery.isEmpty,
            isDropTargeted: isDropTargeted
        ) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(KM.accent)
                .frame(width: 20)
        }
        .accessibilityIdentifier("sidebar.\(selection.id)")
        .onTapGesture {
            selectSidebarItem(selection)
        }
        .accessibilityAction {
            selectSidebarItem(selection)
        }
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(KM.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(listTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                syncStatusLine
            }
            .frame(width: 250, alignment: .leading)

            if supportsEntryTypes {
                newEntrySplitButton
            } else {
                Button {
                    startNewEntry()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                        Text(L("New Entry"))
                    }
                }
                .buttonStyle(KMButtonStyle(kind: .chrome, height: 34, horizontalPadding: 14))
                .help(L("New Entry (⌘N)"))
                .accessibilityIdentifier("toolbar.newEntry")
                .disabled(isPerformingMutation)
            }

            HStack(spacing: 0) {
                Button(action: onLockVault) {
                    Image(systemName: "lock")
                        .font(.system(size: 15))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, width: 38, cornerRadius: 14, tint: KM.textPrimary))
                .iconHelp(L("Lock Database (⌘L)"))
                .accessibilityIdentifier("toolbar.lock")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                }
                .buttonStyle(KMIconButtonStyle(size: 28, width: 38, cornerRadius: 14, tint: KM.textPrimary))
                .iconHelp(L("Settings (⌘,)"))

                Menu {
                    Section(L("Vault")) {
                        Button {
                            onMergeDatabase()
                        } label: {
                            Label(L("Merge Database…"), systemImage: "arrow.triangle.merge")
                        }
                        Button {
                            NotificationCenter.default.post(name: AppCommand.importData, object: nil)
                        } label: {
                            Label(L("Import…"), systemImage: "square.and.arrow.down")
                        }
                        Button {
                            NotificationCenter.default.post(name: AppCommand.exportData, object: nil)
                        } label: {
                            Label(L("Export…"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            addAdditionalDatabase()
                        } label: {
                            Label(L("Add Additional Database…"), systemImage: "cylinder.split.1x2")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15))
                        .foregroundStyle(KM.textPrimary)
                        .frame(width: 38, height: 28)
                        .contentShape(Capsule(style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .iconHelp(L("More"))
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .background(Capsule(style: .continuous).fill(KM.chromeBackground))
            .overlay(Capsule(style: .continuous).strokeBorder(KM.chromeBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

            Spacer(minLength: 0)

            searchField
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 56)
        .background(WindowDragRegion())
    }

    /// "New Entry" creates a login; the arrow offers other types and the database's templates.
    private var newEntrySplitButton: some View {
        HStack(spacing: 0) {
            Button {
                startNewEntry()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                    Text(L("New Entry"))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("New Login (⌘N)"))
            .accessibilityIdentifier("toolbar.newEntry")

            Rectangle()
                .fill(KM.separator)
                .frame(width: 0.5, height: 18)

            Menu {
                ForEach(VaultEntryType.builtIns, id: \.self) { type in
                    Button {
                        startNewEntry(type: type)
                    } label: {
                        Label {
                            Text(type.label)
                        } icon: {
                            Image(nsImage: EntryTypeTile.menuImage(symbol: type.symbol, color: type.tileColor))
                        }
                    }
                }
                let templates = entryTemplates
                if !templates.isEmpty {
                    Section(L("From \(vault.summary.fileName)")) {
                        ForEach(templates) { template in
                            Button {
                                startNewEntry(type: .template, template: template)
                            } label: {
                                Label {
                                    Text(template.title)
                                } icon: {
                                    Image(nsImage: EntryTypeTile.menuImage(symbol: template.symbol, color: VaultEntryType.template.tileColor))
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(templates.isEmpty ? L("Use a Templates Group…") : L("Manage Templates…")) {
                    NotificationCenter.default.post(name: AppCommand.openDatabaseSettings, object: nil)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .iconHelp(L("New Entry of Type"))
        }
        .foregroundStyle(KM.textPrimary)
        .background(Capsule(style: .continuous).fill(KM.chromeBackground))
        .overlay(Capsule(style: .continuous).strokeBorder(KM.chromeBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
        .disabled(isPerformingMutation)
    }

    private var syncStatusLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                switch syncStatus {
                case .merging:
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                case .failed, .changedOnDisk:
                    Circle()
                        .fill(KM.warning)
                        .frame(width: 7, height: 7)
                case .idle, .synced, .notWatching:
                    EmptyView()
                }
                if let key = selectedDatabaseKey, let database = additional.database(key) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 10))
                    Text(L("\(database.fileName) · additional database"))
                        .lineLimit(1)
                } else {
                    Text("\(vault.summary.fileName) · \(syncStatusText(now: context.date))")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .help(syncStatusHelp)
            .contentShape(Rectangle())
            .onTapGesture {
                if syncStatus == .changedOnDisk {
                    onShowDiskChangeBanner()
                }
            }
        }
    }

    private var expirySummary: ExpirySummary {
        ExpirySummary(entries: mainVault.entries, warnDays: expiryWarnDays)
    }

    /// Red and orange counts on "Database Report" for expired and soon-to-expire passwords.
    private var expiryPills: [SidebarPill] {
        let summary = expirySummary
        var pills: [SidebarPill] = []
        if summary.expired > 0 {
            pills.append(SidebarPill(
                count: summary.expired,
                help: L("\(summary.expired) expired"),
                background: Color(lightHex: 0xD70015, darkHex: 0xFF453A),
                foreground: .white
            ))
        }
        if summary.expiringSoon > 0 {
            pills.append(SidebarPill(
                count: summary.expiringSoon,
                help: L("\(summary.expiringSoon) expiring within \(summary.warnDays) days"),
                background: Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A),
                foreground: Color(lightHex: 0xFFFFFF, darkHex: 0x1D1D1F)
            ))
        }
        return pills
    }

    private var expiryBanner: some View {
        let summary = expirySummary
        let tint = summary.expired > 0 ? KM.danger : Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A)
        return HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(tint)
            Text(summary.bannerText)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Review"), action: onReviewExpiry)
                .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 14, fontSize: 12))
            Button(action: onDismissExpiryBanner) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 13))
            .iconHelp(L("Dismiss"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(summary.expired > 0
            ? Color(light: NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 0.07), dark: NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 0.13))
            : Color(light: NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 0.09), dark: NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 0.13)))
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    private var diskChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .font(.system(size: 16))
                .foregroundStyle(KM.accent)
            Text(L("\(vault.summary.fileName) was changed on another device."))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Show Changes"), action: onShowDiskChanges)
                .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 12, fontSize: 12))
            Button(L("Merge"), action: onMergeDiskChanges)
                .buttonStyle(KMButtonStyle(kind: .primary, height: 26, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
            Button(L("Ignore"), action: onIgnoreDiskChanges)
                .buttonStyle(KMButtonStyle(kind: .ghost, height: 26, horizontalPadding: 10, fontWeight: .regular, fontSize: 12))
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Color(light: NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 0.07), dark: NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.14)))
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    private func syncStatusText(now: Date) -> String {
        switch syncStatus {
        case .idle:
            return L("unlocked")
        case .merging:
            return L("merging…")
        case .failed:
            return L("couldn’t merge changes")
        case .changedOnDisk:
            return L("changed on disk")
        case .notWatching:
            return L("not watching")
        case .synced(let date):
            let minutes = Int(now.timeIntervalSince(date) / 60)
            return minutes < 1 ? L("synced just now") : L("synced \(minutes) min ago")
        }
    }

    private var syncStatusHelp: String {
        if case .failed(let message) = syncStatus {
            return message
        }
        switch syncStatus {
        case .changedOnDisk:
            return L("Another device changed this file. Click to review the changes.")
        case .notWatching:
            return L("KeeMac doesn’t watch this file. Changes on disk are still merged before saving.")
        default:
            return L("KeeMac merges changes other devices make to this file.")
        }
    }

    private static let searchHelp = L("""
        Searches titles, usernames, websites, notes, groups, tags and custom fields. All words must match.
        "two words" — exact phrase · -word — exclude
        title: user: url: notes: group: tag: field: — search one field
        is:otp is:expired is:expiring is:weak is:favorite has:attachment — filters
        """)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(KM.textSecondary)
                .accessibilityHidden(true)
            TextField(L("Search"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("toolbar.search")
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .help(Self.searchHelp)
                .onExitCommand {
                    searchText = ""
                    isSearchFocused = false
                }
                .onSubmit {
                    isListFocused = true
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(KM.textTertiary)
                }
                .buttonStyle(.plain)
                .iconHelp(L("Clear search"))
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(width: 250, height: 34)
        .background(Capsule(style: .continuous).fill(KM.chromeBackground))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isSearchFocused ? KM.accent : KM.chromeBorder, lineWidth: isSearchFocused ? 1 : 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }

    private var keyboardShortcuts: some View {
        ZStack {
            Button("") {
                startNewEntry()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("") {
                if let entry = selectedEntry, !entry.isTrashed, editingEntryID == nil {
                    Task {
                        await performDuplicate(entry.id)
                    }
                }
            }
            .keyboardShortcut("d", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Entries list

    private var entriesColumn: some View {
        let entries = filteredEntries
        return VStack(spacing: 0) {
            HStack {
                Text(L("\(entries.count) entries"))
                .accessibilityIdentifier("list.count")
                Spacer()
                if isTrashSelection, trimmedQuery.isEmpty, !entries.isEmpty {
                    Button(L("Empty Trash")) {
                        confirmEmptyTrash(entries)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KM.accent)
                    .disabled(isPerformingMutation)
                } else if isSortable {
                    Menu {
                        Picker(L("Sort By"), selection: $sortOrderRaw) {
                            ForEach(SortOrder.allCases, id: \.rawValue) { order in
                                Text(order.label).tag(order.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 2) {
                            Text(sortOrder.label)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(KM.textSecondary)
                    .fixedSize()
                    .accessibilityLabel(L("Sort by \(sortOrder.label)"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: 32)

            if entries.isEmpty {
                entriesEmptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: layout.usesCompactRows ? 0 : 2) {
                            ForEach(entries) { entry in
                                entryRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .onChange(of: selectedEntryID) { _, newValue in
                        guard let newValue, isListFocused else {
                            return
                        }
                        proxy.scrollTo(newValue)
                    }
                }
            }
            lockedDatabaseNotes
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
    }

    @ViewBuilder
    /// "GitHub, anna, Favorite, Changed on another device".
    private func entryAccessibilityLabel(_ entry: VaultEntry) -> String {
        var parts = [entry.title.isEmpty ? L("Untitled") : entry.title, entrySubtitle(entry)]
        if favoriteEntryIDs.contains(entry.id) {
            parts.append(L("Favorite"))
        }
        if externalChanges[entry.id] != nil {
            parts.append(L("Changed on another device"))
        }
        if let expiresAt = entry.expiresAt, expiresAt < Date() {
            parts.append(L("Expired"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func entryRow(_ entry: VaultEntry) -> some View {
        Group {
            if layout.usesCompactRows {
                compactEntryRow(entry)
            } else {
                richEntryRow(entry)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .onTapGesture {
            selectedEntryID = entry.id
            isListFocused = true
        }
        .contextMenu {
            entryContextMenu(entry)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entryAccessibilityLabel(entry))
        .accessibilityIdentifier("entry.\(entry.title)")
        .accessibilityAddTraits(selectedEntryID == entry.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedEntryID = entry.id
        }
        .draggable(SidebarDragPayload.entryPayload(for: entry.id))
    }

    private func compactEntryRow(_ entry: VaultEntry) -> some View {
        let isSelected = entry.id == selectedEntry?.id

        return HStack(spacing: 8) {
            if showsEntryIcons {
                EntryTile(entry: entry, supportsTypes: supportsEntryTypes, size: 18, cornerRadius: 5, fontSize: 10)
            }
            Text(entry.title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : (EntryColor.color(fromHex: entry.foregroundColorHex) ?? KM.textPrimary))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .layoutPriority(1)
            Text(entrySubtitle(entry))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : KM.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            databaseLabel(for: entry, isSelected: isSelected)
            if externalChanges[entry.id] != nil {
                syncMarker(isSelected: isSelected, size: 11)
            }
            if favoriteEntryIDs.contains(entry.id) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white : KM.warning)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? KM.accent : Color.clear)
        )
    }

    private func richEntryRow(_ entry: VaultEntry) -> some View {
        let isSelected = entry.id == selectedEntry?.id
        let isFavorite = favoriteEntryIDs.contains(entry.id)

        return HStack(spacing: 11) {
            if showsEntryIcons {
                EntryTile(entry: entry, supportsTypes: supportsEntryTypes)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : (EntryColor.color(fromHex: entry.foregroundColorHex) ?? KM.textPrimary))
                    .lineLimit(1)
                Text(entrySubtitle(entry))
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : KM.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            databaseLabel(for: entry, isSelected: isSelected)

            if externalChanges[entry.id] != nil {
                syncMarker(isSelected: isSelected, size: 13)
            }

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : KM.warning)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? KM.accent : Color.clear)
        )
    }

    private func syncMarker(isSelected: Bool, size: CGFloat) -> some View {
        Image(systemName: "arrow.triangle.2.circlepath.icloud")
            .font(.system(size: size))
            .foregroundStyle(isSelected ? Color.white : KM.accent)
            .iconHelp(L("Changed on another device"))
    }

    @ViewBuilder
    private func entryContextMenu(_ entry: VaultEntry) -> some View {
        if let username = entry.username, !username.isEmpty {
            Button(L("Copy Username")) {
                SensitiveClipboard.shared.copySensitiveText(username, label: L("Username"))
                onEntryUsed(entry.id)
            }
        }
        if let password = entry.password, !password.isEmpty {
            Button(L("Copy Password")) {
                SensitiveClipboard.shared.copySensitiveText(password, label: L("Password"))
                onEntryUsed(entry.id)
            }
        }
        if let otp = entry.otp,
           let code = OTPCodeGenerator.makeCodeState(from: otp, now: Date())?.code {
            Button(L("Copy One-Time Code")) {
                SensitiveClipboard.shared.copySensitiveText(code, label: L("One-time code"))
                onEntryUsed(entry.id)
            }
        }

        Divider()

        if entry.isTrashed {
            Button(L("Restore")) {
                Task {
                    await performRestore(entry)
                }
            }
            Button(L("Delete Permanently"), role: .destructive) {
                confirmDeletePermanently(entry)
            }
        } else {
            Button(L("Edit")) {
                selectedEntryID = entry.id
                startEditing(entry)
            }
            Button(L("Duplicate")) {
                Task {
                    await performDuplicate(entry.id)
                }
            }
            Button(L("Duplicate with References")) {
                Task {
                    await performDuplicate(entry.id, referencingCredentials: true)
                }
            }
            let targets = transferTargets(excluding: DatabaseScope.key(of: entry.groupPath))
            if !targets.isEmpty {
                Self.transferMenu(L("Move to"), targets: targets) { startTransfer(entryIDs: [entry.id], groupPath: nil, to: $0, isCopy: false) }
                Self.transferMenu(L("Copy to"), targets: targets) { startTransfer(entryIDs: [entry.id], groupPath: nil, to: $0, isCopy: true) }
            }
            Button(favoriteEntryIDs.contains(entry.id) ? L("Remove from Favorites") : L("Add to Favorites")) {
                onToggleFavorite(entry.id)
            }

            Divider()

            Button(L("Move to Trash"), role: .destructive) {
                confirmMoveToTrash(entry)
            }
        }
    }

    @ViewBuilder
    private var entriesEmptyState: some View {
        let state = emptyState
        VStack(spacing: 6) {
            Image(systemName: state.symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(KM.chevron)
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text(state.message)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .multilineTextAlignment(.center)
            if state.showsAction {
                Button(L("New Entry")) {
                    startNewEntry()
                }
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontWeight: .regular))
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: (symbol: String, title: String, message: String, showsAction: Bool) {
        if !trimmedQuery.isEmpty {
            return ("magnifyingglass", L("No Results for “\(trimmedQuery)”"), L("Check the spelling or try a new search."), false)
        }
        switch currentLibrarySelection {
        case .trash, .databaseTrash:
            return ("trash", L("Trash Is Empty"), L("Deleted entries stay here until you empty the Trash."), false)
        case .favorites:
            return ("star", L("No Favorites"), L("Star an entry to keep it here for quick access."), false)
        case .recentlyViewed:
            return ("eye", L("Nothing Viewed Yet"), L("Entries you open in this session appear here."), false)
        case .recentlyModified:
            return ("clock", L("No Entries"), L("Entries you change will appear here."), false)
        case .tag(let tag):
            return ("tag", L("No Entries"), L("No entries are tagged “\(tag)”."), false)
        case .report:
            return ("waveform.path.ecg", L("Database Report"), L("Clear the search to see the report."), false)
        case .changedElsewhere:
            return ("checkmark.icloud", L("All Caught Up"), L("Entries changed on other devices appear here until you view them."), false)
        case .allItems, .group:
            return ("folder", L("No Entries"), L("This group is empty."), true)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let entry = selectedEntry {
                if editingEntryID == entry.id {
                    EntryEditorPane(
                        entry: entry,
                        isSaving: isPerformingMutation,
                        onCancel: { editingEntryID = nil },
                        onSave: { form in
                            Task {
                                await performUpdateEntry(id: entry.id, form: form)
                            }
                        },
                        referenceTitle: { id in vault.entries.first { $0.id == id }?.title },
                        referenceEntries: vault.entries.filter { DatabaseScope.key(of: $0.groupPath) == DatabaseScope.key(of: entry.groupPath) },
                        onOpenEntry: openLinkedEntry,
                        onConfirm: { title, message, confirmTitle, action in
                            confirmRequest = ConfirmRequest(title: title, message: message, confirmTitle: confirmTitle) {
                                confirmRequest = nil
                                action()
                            }
                        }
                    )
                    .id("edit-\(entry.id.uuidString)")
                } else {
                    EntryDetailPane(
                        entry: entry,
                        style: layout.usesFormDetail ? .form : .grouped,
                        isFavorite: favoriteEntryIDs.contains(entry.id),
                        groupDisplay: GroupPathFormatter.display(entry.groupPath, rootPath: rootPath),
                        externalChange: externalChanges[entry.id],
                        previousGroupDisplay: externalChanges[entry.id]?.previousGroupPath.map { GroupPathFormatter.display($0, rootPath: rootPath) },
                        isBusy: isPerformingMutation,
                        onToggleFavorite: { onToggleFavorite(entry.id) },
                        onMoveToTrash: { confirmMoveToTrash(entry) },
                        onEdit: { startEditing(entry) },
                        onRestore: {
                            Task {
                                await performRestore(entry)
                            }
                        },
                        onDeletePermanently: { confirmDeletePermanently(entry) },
                        onUsed: { onEntryUsed(entry.id) },
                        onShowHistory: entry.history.isEmpty ? nil : { historyEntry = entry },
                        onNextOTP: entry.otp?.kind == .hotp && !entry.isTrashed ? {
                            Task {
                                await runMutation { try await onAdvanceHOTP(entry.id) }
                            }
                        } : nil,
                        supportsTypes: supportsEntryTypes,
                        referenceTitle: { id in vault.entries.first { $0.id == id }?.title },
                        onOpenReference: { id in
                            if let source = vault.entries.first(where: { $0.id == id }) {
                                revealEntry(source)
                            }
                        },
                        sshDefaultConfirmation: AppSettingsStore.shared.sshDefaultConfirmation,
                        sshLastUse: SSHAgentController.shared.lastUse(of: entry.id),
                        // The agent serves the main database's keys only.
                        onUseInSSHAgent: DatabaseScope.key(of: entry.groupPath) == nil ? { attachment in
                            useInSSHAgent(entry, key: attachment)
                        } : nil
                    )
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 34, weight: .light))
                    Text(L("No Entry Selected"))
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(KM.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KM.windowBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(KM.hairline).frame(width: 0.5)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Derived data

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sortOrder: SortOrder {
        SortOrder(rawValue: sortOrderRaw) ?? .title
    }

    private var isSortable: Bool {
        switch currentLibrarySelection {
        case .recentlyViewed, .recentlyModified, .report:
            return !trimmedQuery.isEmpty
        default:
            return true
        }
    }

    /// The main database's root group. Additional databases' paths start with their scope, never with it.
    private var rootPath: String {
        vault.groups.first(where: { !$0.path.contains(".") && DatabaseScope.key(of: $0.path) == nil })?.path ?? ""
    }

    private var browsableGroups: [VaultGroup] {
        vault.groups.filter { !$0.isTrash && !$0.path.isEmpty && $0.path != rootPath && DatabaseScope.key(of: $0.path) == nil }
    }

    /// The main database's live entries: the library (All, Favorites, Recent), tags and the report use only these.
    private var liveEntries: [VaultEntry] {
        vault.entries.filter { !$0.isTrashed && DatabaseScope.key(of: $0.groupPath) == nil }
    }

    /// Live entries of every open database: search and group lists.
    private var allLiveEntries: [VaultEntry] {
        vault.entries.filter { !$0.isTrashed }
    }

    private var mainTrashedEntries: [VaultEntry] {
        vault.entries.filter { $0.isTrashed && DatabaseScope.key(of: $0.groupPath) == nil }
    }

    /// The main database alone, for the report, expiry reminders and the breach check.
    private var mainVault: LoadedVault {
        guard !additional.unlockedKeys.isEmpty else {
            return vault
        }
        return LoadedVault(
            summary: vault.summary,
            groups: vault.groups.filter { DatabaseScope.key(of: $0.path) == nil },
            entries: vault.entries.filter { DatabaseScope.key(of: $0.groupPath) == nil }
        )
    }

    private var listTitle: String {
        if !trimmedQuery.isEmpty {
            return L("Search")
        }
        switch currentLibrarySelection {
        case .allItems:
            return L("All Entries")
        case .favorites:
            return L("Favorites")
        case .recentlyViewed:
            return L("Recently Viewed")
        case .recentlyModified:
            return L("Recently Modified")
        case .trash, .databaseTrash:
            return L("Trash")
        case .report:
            return L("Database Report")
        case .changedElsewhere:
            return L("Changed on Other Device")
        case .group(let path):
            if let key = DatabaseScope.key(of: path), additional.rootPaths[key] == path {
                return databaseName(key)
            }
            return GroupPathFormatter.title(of: path)
        case .tag(let tag):
            return "#\(tag)"
        }
    }

    private func entrySubtitle(_ entry: VaultEntry) -> String {
        if currentLibrarySelection == .recentlyModified, trimmedQuery.isEmpty {
            return L("Modified \(RelativeDateFormatter.modified(entry.modifiedAt))")
        }
        if let typed = entry.typedSubtitle(supportsTypes: supportsEntryTypes) {
            return typed
        }
        if let username = entry.username, !username.isEmpty {
            return username
        }
        if let host = entry.url?.host() {
            return host
        }
        return displayGroupPath(entry.groupPath)
    }

    private var availableTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in liveEntries {
            for tag in entry.tags where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func tagCount(_ tag: String) -> Int {
        let normalized = tag.lowercased()
        return liveEntries.filter { $0.tags.contains { $0.lowercased() == normalized } }.count
    }

    private var groupCounts: [String: Int] {
        var direct: [String: Int] = [:]
        for entry in allLiveEntries {
            direct[entry.groupPath, default: 0] += 1
        }
        guard includeSubgroupEntries else {
            return direct
        }
        var total: [String: Int] = [:]
        for (path, count) in direct where !path.isEmpty {
            var components = path.split(separator: ".").map(String.init)
            while !components.isEmpty {
                total[components.joined(separator: "."), default: 0] += count
                components.removeLast()
            }
        }
        return total
    }

    private var groupOptions: [GroupOption] {
        browsableGroups
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { GroupOption(path: $0.path, title: $0.title, depth: GroupPathFormatter.depth(of: $0.path, rootPath: rootPath)) }
    }

    private var selectedEntry: VaultEntry? {
        guard let selectedEntryID else {
            return filteredEntries.first
        }
        return filteredEntries.first(where: { $0.id == selectedEntryID })
    }

    private var filteredEntries: [VaultEntry] {
        let search = VaultEntrySearch(trimmedQuery)

        if !search.isEmpty {
            let scope: [VaultEntry]
            switch currentLibrarySelection {
            case .trash:
                scope = mainTrashedEntries
            case .databaseTrash(let key):
                scope = trashedEntries(inDatabase: key)
            default:
                scope = allLiveEntries
            }
            let favorites = favoriteEntryIDs
            let context = VaultEntrySearch.Context(
                expiringWithinDays: expiringWithinDays,
                rootPath: rootPath,
                isWeakPassword: { PasswordStrength.evaluate($0)?.level == .weak },
                isFavorite: { favorites.contains($0) }
            )
            return sorted(scope.filter { search.matches($0, context: context) })
        }

        switch currentLibrarySelection {
        case .allItems:
            return sorted(liveEntries)
        case .favorites:
            return sorted(liveEntries.filter { favoriteEntryIDs.contains($0.id) })
        case .recentlyViewed:
            let entriesByID = Dictionary(uniqueKeysWithValues: liveEntries.map { ($0.id, $0) })
            return recentViewedEntryIDs.compactMap { entriesByID[$0] }
        case .recentlyModified:
            return Array(liveEntries.sorted(by: Self.modifiedDescending).prefix(20))
        case .trash:
            return sorted(mainTrashedEntries)
        case .databaseTrash(let key):
            return sorted(trashedEntries(inDatabase: key))
        case .report:
            return []
        case .changedElsewhere:
            return sorted(liveEntries.filter { externalChanges[$0.id] != nil })
        case .group(let path):
            return sorted(allLiveEntries.filter { entry in
                if includeSubgroupEntries {
                    return entry.groupPath == path || entry.groupPath.hasPrefix("\(path).")
                }
                return entry.groupPath == path
            })
        case .tag(let name):
            let normalized = name.lowercased()
            return sorted(liveEntries.filter { $0.tags.contains { $0.lowercased() == normalized } })
        }
    }

    private func sorted(_ entries: [VaultEntry]) -> [VaultEntry] {
        switch sortOrder {
        case .title:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .modified:
            return entries.sorted(by: Self.modifiedDescending)
        }
    }

    private static func modifiedDescending(_ lhs: VaultEntry, _ rhs: VaultEntry) -> Bool {
        (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
    }

    private var groupTree: [GroupTreeNode] {
        let groupIconsByPath = Dictionary(
            browsableGroups.map { ($0.path, ($0.iconPNGData, $0.iconID)) },
            uniquingKeysWith: { first, _ in first }
        )
        let tree = Self.buildGroupTree(from: Array(groupIconsByPath.keys), iconByPath: groupIconsByPath)
        guard !rootPath.isEmpty else {
            return tree
        }
        return tree.first { $0.path == rootPath }?.children ?? []
    }

    private var currentLibrarySelection: LibrarySelection {
        guard let selectedSidebarItemID, let selection = LibrarySelection(id: selectedSidebarItemID) else {
            return .allItems
        }
        return selection
    }

    private var selectedGroupPathForCreation: String? {
        if case .group(let path) = currentLibrarySelection {
            return path
        }
        return nil
    }

    // MARK: - Actions

    private func selectSidebarItem(_ selection: LibrarySelection) {
        searchText = ""
        selectedSidebarItemID = selection.id
    }

    private func startNewEntry() {
        guard !isPerformingMutation else {
            return
        }
        newEntryRequest = NewEntryRequest(groupPath: selectedGroupPathForCreation)
    }

    private func moveSelection(by delta: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else {
            return
        }
        let currentIndex = entries.firstIndex { $0.id == selectedEntry?.id } ?? -1
        let nextIndex = min(max(currentIndex + delta, 0), entries.count - 1)
        selectedEntryID = entries[nextIndex].id
    }

    private func editGroup(_ path: String) {
        guard let group = vault.groups.first(where: { $0.path == path }) else {
            return
        }
        groupEditorMode = .edit(path: group.path, title: group.title, iconID: group.iconID)
    }

    private func ensureValidSelection() {
        if case .group(let path) = currentLibrarySelection,
           !vault.groups.contains(where: { $0.path == path }) {
            selectedSidebarItemID = LibrarySelection.allItems.id
        }

        if case .tag(let name) = currentLibrarySelection,
           !availableTags.contains(where: { $0.lowercased() == name.lowercased() }) {
            selectedSidebarItemID = LibrarySelection.allItems.id
        }

        if case .databaseTrash(let key) = currentLibrarySelection, additional.rootPaths[key] == nil {
            selectedSidebarItemID = LibrarySelection.allItems.id
        }

        if let selectedEntryID, filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = filteredEntries.first?.id
    }

    private func openPendingEditIfReady() {
        guard let pendingEditEntryID, let entry = vault.entries.first(where: { $0.id == pendingEditEntryID }) else {
            return
        }
        self.pendingEditEntryID = nil
        revealEntry(entry)
        startEditing(entry)
    }

    private func selectCreatedEntryIfNeeded() {
        guard let baseline = newEntryBaseline,
              let created = vault.entries.first(where: { !baseline.contains($0.id) && !$0.isTrashed }) else {
            return
        }
        newEntryBaseline = nil
        searchText = ""
        selectedSidebarItemID = created.groupPath.isEmpty || created.groupPath == rootPath
            ? LibrarySelection.allItems.id
            : LibrarySelection.group(created.groupPath).id
        selectedEntryID = created.id
    }

    private func confirmMoveToTrash(_ entry: VaultEntry) {
        confirmRequest = ConfirmRequest(
            title: L("Move “\(entry.title)” to Trash?"),
            message: L("You can restore it from the Trash until the Trash is emptied."),
            confirmTitle: L("Move to Trash")
        ) {
            confirmRequest = nil
            let entries = filteredEntries
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                let next = entries.indices.contains(index + 1) ? entries[index + 1] : (index > 0 ? entries[index - 1] : nil)
                selectedEntryID = next?.id
            }
            Task {
                if await performDelete(entry.id) {
                    showUndoToast(L("Moved to Trash"))
                }
            }
        }
    }

    private func confirmDeletePermanently(_ entry: VaultEntry) {
        confirmRequest = ConfirmRequest(
            title: L("Delete “\(entry.title)” permanently?"),
            message: L("This entry and its attachments will be removed from the database. You can undo this until the database locks."),
            confirmTitle: L("Delete")
        ) {
            confirmRequest = nil
            Task {
                if await performDelete(entry.id) {
                    showUndoToast(L("Entry deleted"))
                }
            }
        }
    }

    private func confirmEmptyTrash(_ entries: [VaultEntry]) {
        let ids = entries.map(\.id)
        confirmRequest = ConfirmRequest(
            title: L("Permanently delete \(ids.count) entries in the Trash?"),
            message: L("You can undo this until the database locks."),
            confirmTitle: L("Empty Trash")
        ) {
            confirmRequest = nil
            Task {
                await performEmptyTrash(ids)
            }
        }
    }

    private func confirmDeleteGroup(_ path: String) {
        confirmRequest = ConfirmRequest(
            title: L("Delete group “\(GroupPathFormatter.title(of: path))”?"),
            message: L("The group with all nested entries and subgroups will be moved to Trash or removed, depending on database settings."),
            confirmTitle: L("Delete Group")
        ) {
            confirmRequest = nil
            Task {
                await performDeleteGroup(path)
            }
        }
    }

    // MARK: - Mutations

    private func runMutation(_ operation: () async throws -> Void) async -> Bool {
        guard !isPerformingMutation else {
            return false
        }
        isPerformingMutation = true
        defer { isPerformingMutation = false }

        do {
            try await operation()
            return true
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func performCreateEntry(groupPath: String?, form: VaultEntryForm) async {
        newEntryBaseline = Set(vault.entries.map(\.id))
        if await runMutation({ try await onCreateEntry(groupPath, form) }) {
            newEntryRequest = nil
            CopyFeedbackCenter.shared.show(L("Entry created"), duration: 2.4)
        } else {
            newEntryBaseline = nil
        }
    }

    private var supportsEntryTypes: Bool {
        vault.summary.supportsEntryTypes
    }

    private var entryTemplates: [EntryTemplate] {
        EntryTemplate.all(in: vault)
    }

    /// Logins are edited inline; other types open the type sheet.
    private func startEditing(_ entry: VaultEntry) {
        selectedEntryID = entry.id
        if entry.effectiveType(supportsTypes: supportsEntryTypes) == .login {
            editingEntryID = entry.id
        } else {
            newEntryRequest = NewEntryRequest(editing: entry)
        }
    }

    private func startNewEntry(type: VaultEntryType, template: EntryTemplate? = nil) {
        guard !isPerformingMutation else {
            return
        }
        newEntryRequest = NewEntryRequest(groupPath: selectedGroupPathForCreation, type: type, template: template)
    }

    private func performUpdateTypedEntry(_ entry: VaultEntry, groupPath: String?, form: VaultEntryForm) async {
        let currentGroup = entry.groupPath == rootPath ? nil : entry.groupPath
        let succeeded = await runMutation {
            try await onUpdateEntry(entry.id, form)
            if groupPath != currentGroup {
                try await onMoveEntry(entry.id, groupPath)
            }
        }
        if succeeded {
            newEntryRequest = nil
            CopyFeedbackCenter.shared.show(L("Changes saved"), duration: 2.4)
        }
    }

    private func performUpdateEntry(id: UUID, form: VaultEntryForm) async {
        if await runMutation({ try await onUpdateEntry(id, form) }) {
            editingEntryID = nil
            CopyFeedbackCenter.shared.show(L("Changes saved"), duration: 2.4)
        }
    }

    /// Duplicates an entry, selects the copy and opens it in the editor so it can be renamed right away.
    private func performDuplicate(_ id: UUID, referencingCredentials: Bool = false) async {
        var copyID: UUID?
        let succeeded = await runMutation {
            copyID = try await onDuplicateEntry(id, referencingCredentials)
        }
        guard succeeded, let copyID else {
            return
        }
        pendingEditEntryID = copyID
        openPendingEditIfReady()
    }

    /// A toast with an Undo button; the button undoes the last change in the database (⌘Z).
    private func showUndoToast(_ message: String) {
        CopyFeedbackCenter.shared.show(message, style: .success, duration: 5, actionTitle: L("Undo")) {
            NotificationCenter.default.post(name: AppCommand.undo, object: nil)
        }
    }

    private func performDelete(_ id: UUID) async -> Bool {
        await runMutation { try await onDeleteEntry(id) }
    }

    private func performEmptyTrash(_ ids: [UUID]) async {
        if await runMutation({ try await onEmptyTrash(ids) }) {
            showUndoToast(L("Trash emptied"))
        }
    }

    private func performMoveEntry(id: UUID, toGroupPath groupPath: String?) async {
        let entryPath = vault.entries.first { $0.id == id }?.groupPath
        if DatabaseScope.key(of: entryPath) != DatabaseScope.key(of: groupPath) {
            startTransfer(entryIDs: [id], groupPath: nil, to: groupPath, isCopy: NSEvent.modifierFlags.contains(.option))
            return
        }
        _ = await runMutation { try await onMoveEntry(id, groupPath) }
    }

    private func performMoveGroup(path: String, toParentPath parentPath: String?) async {
        if DatabaseScope.key(of: path) != DatabaseScope.key(of: parentPath) {
            startTransfer(entryIDs: [], groupPath: path, to: parentPath, isCopy: NSEvent.modifierFlags.contains(.option))
            return
        }
        _ = await runMutation { try await onMoveGroup(path, parentPath) }
    }

    private func performRestore(_ entry: VaultEntry) async {
        if await runMutation({ try await onRestoreEntry(entry.id) }) {
            showUndoToast(L("Restored to \(displayGroupPath(entry.groupPath))"))
        }
    }

    private func performRevert(entryID: UUID, historyIndex: Int) async {
        if await runMutation({ try await onRevertEntry(entryID, historyIndex) }) {
            historyEntry = nil
        }
    }

    private func performGroupEditorAction(mode: GroupEditorMode, title: String, iconID: Int?) async {
        let succeeded = await runMutation {
            switch mode {
            case .create(let parentPath):
                try await onCreateGroup(parentPath, title, iconID)
            case .edit(let path, _, _):
                try await onUpdateGroup(path, title, iconID)
            }
        }
        guard succeeded else {
            return
        }
        if case .edit(let path, _, _) = mode, currentLibrarySelection == .group(path) {
            let parent = mode.parentPath.map { "\($0).\(title)" } ?? title
            selectedSidebarItemID = LibrarySelection.group(parent).id
        }
        groupEditorMode = nil
        let isCreating: Bool
        if case .create = mode {
            isCreating = true
        } else {
            isCreating = false
        }
        CopyFeedbackCenter.shared.show(isCreating ? L("Group created") : L("Group updated"), duration: 2.4)
    }

    private func performDeleteGroup(_ path: String) async {
        if await runMutation({ try await onDeleteGroup(path) }) {
            if currentLibrarySelection == .group(path) {
                selectedSidebarItemID = LibrarySelection.allItems.id
            }
        }
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
            var current = root
            var currentPath = ""

            for part in parts {
                currentPath = currentPath.isEmpty ? part : "\(currentPath).\(part)"
                let icon = iconByPath[currentPath]
                if current.children[part] == nil {
                    current.children[part] = Node(
                        title: part,
                        path: currentPath,
                        iconPNGData: icon?.pngData ?? nil,
                        iconID: icon?.iconID ?? nil
                    )
                }
                if let next = current.children[part] {
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

fileprivate struct SidebarPill: Hashable {
    let count: Int
    let help: String
    let background: Color
    let foreground: Color
}

fileprivate struct SidebarRow<Leading: View>: View {
    let title: String
    let count: Int?
    var pills: [SidebarPill] = []
    let isSelected: Bool
    var isDropTargeted: Bool = false
    var leadingPadding: CGFloat = 10
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(KM.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !pills.isEmpty {
                HStack(spacing: 3) {
                    ForEach(pills, id: \.self) { pill in
                        Text("\(pill.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(pill.foreground)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 16)
                            .background(Capsule(style: .continuous).fill(pill.background))
                            .help(pill.help)
                    }
                }
            } else if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(KM.textSecondary)
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDropTargeted ? KM.accent.opacity(0.2) : (isSelected ? KM.selection : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isDropTargeted ? KM.accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Database Report, 2 expired, 1 expiring within 7 days" or "Work, 12 entries".
    private var accessibilityText: String {
        if !pills.isEmpty {
            return ([title] + pills.map(\.help)).joined(separator: ", ")
        }
        guard let count, count > 0 else {
            return title
        }
        return "\(title), \(count)"
    }
}

fileprivate struct GroupTreeRowView: View {
    let node: VaultBrowserView.GroupTreeNode
    let depth: Int
    @Binding var expandedGroupPaths: Set<String>
    let currentSelection: VaultBrowserView.LibrarySelection
    let counts: [String: Int]
    let onSelect: (String) -> Void
    let onCreateEntry: (String) -> Void
    let onCreateSubgroup: (String) -> Void
    let onEditGroup: (String) -> Void
    let onDeleteGroup: (String) -> Void
    let onMoveEntry: @MainActor (UUID, String?) -> Void
    let onMoveGroup: @MainActor (String, String?) -> Void
    /// Other open databases this group can be moved or copied to.
    var transferTargets: [VaultBrowserView.TransferTarget] = []
    var onTransferGroup: @MainActor (String, String?, Bool) -> Void = { _, _, _ in }

    @State private var isDropTargeted: Bool = false

    private var hasChildren: Bool {
        node.children?.isEmpty == false
    }

    private var isExpanded: Bool {
        expandedGroupPaths.contains(node.path)
    }

    var body: some View {
        Group {
            rowContent
            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    GroupTreeRowView(
                        node: child,
                        depth: depth + 1,
                        expandedGroupPaths: $expandedGroupPaths,
                        currentSelection: currentSelection,
                        counts: counts,
                        onSelect: onSelect,
                        onCreateEntry: onCreateEntry,
                        onCreateSubgroup: onCreateSubgroup,
                        onEditGroup: onEditGroup,
                        onDeleteGroup: onDeleteGroup,
                        onMoveEntry: onMoveEntry,
                        onMoveGroup: onMoveGroup,
                        transferTargets: transferTargets,
                        onTransferGroup: onTransferGroup
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        SidebarRow(
            title: node.title,
            count: counts[node.path],
            isSelected: currentSelection == .group(node.path),
            isDropTargeted: isDropTargeted,
            leadingPadding: 6 + CGFloat(depth) * 16
        ) {
            HStack(spacing: 2) {
                disclosureControl
                groupIcon
                    .frame(width: 22)
            }
        }
        .accessibilityIdentifier("sidebar.group.\(node.path)")
        .onTapGesture {
            onSelect(node.path)
        }
        .accessibilityAction {
            onSelect(node.path)
        }
        .accessibilityActions {
            if node.children?.isEmpty == false {
                Button(isExpanded ? L("Collapse") : L("Expand")) {
                    if isExpanded {
                        expandedGroupPaths.remove(node.path)
                    } else {
                        expandedGroupPaths.insert(node.path)
                    }
                }
            }
            Button(L("Edit Group")) {
                onEditGroup(node.path)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onEditGroup(node.path)
            }
        )
        .help(L("Double-click to edit"))
        .contextMenu {
            Button(L("New Entry")) { onCreateEntry(node.path) }

            Divider()

            Button(L("New Subgroup")) { onCreateSubgroup(node.path) }
            Button(L("Edit Group…")) { onEditGroup(node.path) }

            if !transferTargets.isEmpty {
                Divider()
                VaultBrowserView.transferMenu(L("Move to"), targets: transferTargets) { onTransferGroup(node.path, $0, false) }
                VaultBrowserView.transferMenu(L("Copy to"), targets: transferTargets) { onTransferGroup(node.path, $0, true) }
            }

            Divider()

            Button(L("Delete Group"), role: .destructive) { onDeleteGroup(node.path) }
        }
        .draggable(SidebarDragPayload.groupPayload(for: node.path))
        .dropDestination(for: String.self) { payloads, _ in
            SidebarDragPayload.handleDrop(
                payloads: payloads,
                targetGroupPath: node.path,
                onMoveEntry: onMoveEntry,
                onMoveGroup: onMoveGroup
            )
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private var groupIcon: some View {
        if let data = node.iconPNGData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: DefaultKeePassIconMapper.symbolName(for: node.iconID) ?? "folder")
                .font(.system(size: 14))
                .foregroundStyle(KM.accent)
        }
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if hasChildren {
            Button {
                if isExpanded {
                    expandedGroupPaths.remove(node.path)
                } else {
                    expandedGroupPaths.insert(node.path)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KM.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? L("Collapse \(node.title)") : L("Expand \(node.title)"))
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

fileprivate enum SidebarDragPayload {
    static let entryPrefix = "keemac-entry:"
    static let groupPrefix = "keemac-group:"

    enum Decoded {
        case entry(UUID)
        case group(String)
    }

    static func entryPayload(for entryID: UUID) -> String {
        "\(entryPrefix)\(entryID.uuidString)"
    }

    static func groupPayload(for groupPath: String) -> String {
        "\(groupPrefix)\(groupPath)"
    }

    static func decode(_ value: String) -> Decoded? {
        if value.hasPrefix(entryPrefix) {
            let uuidString = String(value.dropFirst(entryPrefix.count))
            return UUID(uuidString: uuidString).map(Decoded.entry)
        }
        if value.hasPrefix(groupPrefix) {
            let path = String(value.dropFirst(groupPrefix.count))
            guard !path.isEmpty else {
                return nil
            }
            return .group(path)
        }
        return nil
    }

    static func isGroupMoveValid(sourcePath: String, targetParentPath: String?) -> Bool {
        guard let targetParentPath, !targetParentPath.isEmpty else {
            return true
        }
        if sourcePath == targetParentPath {
            return false
        }
        if targetParentPath.hasPrefix(sourcePath + ".") {
            return false
        }
        return true
    }

    @MainActor
    static func handleDrop(
        payloads: [String],
        targetGroupPath: String?,
        onMoveEntry: @escaping @MainActor (UUID, String?) -> Void,
        onMoveGroup: @escaping @MainActor (String, String?) -> Void
    ) -> Bool {
        for payload in payloads {
            switch decode(payload) {
            case .entry(let id):
                onMoveEntry(id, targetGroupPath)
                return true
            case .group(let sourcePath):
                guard isGroupMoveValid(sourcePath: sourcePath, targetParentPath: targetGroupPath) else {
                    return false
                }
                onMoveGroup(sourcePath, targetGroupPath)
                return true
            case nil:
                continue
            }
        }
        return false
    }
}

// MARK: - Additional databases

extension VaultBrowserView {
    /// Another open database as a destination of "Move to" and "Copy to", with its groups.
    struct TransferTarget: Identifiable {
        struct Destination: Identifiable {
            /// Nil is the main database's root.
            let path: String?
            let title: String
            let depth: Int

            var id: String { path ?? "main-root" }
        }

        let key: String?
        let name: String
        let destinations: [Destination]

        var id: String { key ?? "main" }
    }

    @MainActor
    static func transferMenu(_ title: String, targets: [TransferTarget], action: @escaping (String?) -> Void) -> some View {
        Menu(title) {
            ForEach(targets) { target in
                Menu(target.name) {
                    ForEach(target.destinations) { destination in
                        Button(String(repeating: "    ", count: destination.depth) + destination.title) {
                            action(destination.path)
                        }
                    }
                }
            }
        }
    }

    fileprivate var isTrashSelection: Bool {
        switch currentLibrarySelection {
        case .trash, .databaseTrash:
            return true
        default:
            return false
        }
    }

    fileprivate func trashedEntries(inDatabase key: String) -> [VaultEntry] {
        vault.entries.filter { $0.isTrashed && DatabaseScope.key(of: $0.groupPath) == key }
    }

    /// "Work" for an additional database, the main database's name for nil.
    fileprivate func databaseName(_ key: String?) -> String {
        guard let key else {
            return (vault.summary.fileName as NSString).deletingPathExtension
        }
        return additional.database(key)?.name ?? ""
    }

    /// The additional database of the sidebar selection; nil for the main one and the library.
    fileprivate var selectedDatabaseKey: String? {
        switch currentLibrarySelection {
        case .group(let path):
            return DatabaseScope.key(of: path)
        case .databaseTrash(let key):
            return key
        default:
            return nil
        }
    }

    /// The database ⌘Z acts on: the selected entry's while searching, otherwise the sidebar selection's.
    fileprivate var activeDatabaseKey: String? {
        if !trimmedQuery.isEmpty, let entry = selectedEntry {
            return DatabaseScope.key(of: entry.groupPath)
        }
        return selectedDatabaseKey
    }

    fileprivate func rootPath(ofDatabase key: String?) -> String {
        key.flatMap { additional.rootPaths[$0] } ?? rootPath
    }

    /// "Work › Servers" for an additional database's group, the usual path for the main one.
    fileprivate func displayGroupPath(_ path: String) -> String {
        guard let key = DatabaseScope.key(of: path), let root = additional.rootPaths[key] else {
            return GroupPathFormatter.display(path, rootPath: rootPath)
        }
        let name = databaseName(key)
        return path == root ? name : name + " › " + GroupPathFormatter.display(path, rootPath: root)
    }

    fileprivate func groupOptions(forDatabase key: String?) -> [GroupOption] {
        guard let key, let root = additional.rootPaths[key] else {
            return groupOptions
        }
        return vault.groups
            .filter { !$0.isTrash && $0.path != root && DatabaseScope.key(of: $0.path) == key }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { GroupOption(path: $0.path, title: $0.title, depth: GroupPathFormatter.depth(of: $0.path, rootPath: root)) }
    }

    fileprivate func groupTree(forDatabase key: String) -> [GroupTreeNode] {
        guard let root = additional.rootPaths[key] else {
            return []
        }
        let groups = vault.groups.filter { !$0.isTrash && $0.path != root && DatabaseScope.key(of: $0.path) == key }
        let icons = Dictionary(groups.map { ($0.path, ($0.iconPNGData, $0.iconID)) }, uniquingKeysWith: { first, _ in first })
        let tree = Self.buildGroupTree(from: Array(icons.keys), iconByPath: icons)
        return tree.first { $0.path == root }?.children ?? []
    }

    /// Unlocked databases other than `key`, with their groups.
    fileprivate func transferTargets(excluding key: String?) -> [TransferTarget] {
        var targets: [TransferTarget] = []
        if key != nil {
            let name = databaseName(nil)
            targets.append(TransferTarget(
                key: nil,
                name: name,
                destinations: [.init(path: nil, title: name, depth: 0)] + groupOptions.map { .init(path: $0.path, title: $0.title, depth: $0.depth + 1) }
            ))
        }
        for database in additional.databases where database.id != key {
            guard let root = additional.rootPaths[database.id] else {
                continue
            }
            targets.append(TransferTarget(
                key: database.id,
                name: database.name,
                destinations: [.init(path: root, title: database.name, depth: 0)]
                    + groupOptions(forDatabase: database.id).map { .init(path: $0.path, title: $0.title, depth: $0.depth + 1) }
            ))
        }
        return targets
    }

    fileprivate var showsDatabaseLabels: Bool {
        !trimmedQuery.isEmpty && !additional.unlockedKeys.isEmpty
    }

    @ViewBuilder
    fileprivate func databaseLabel(for entry: VaultEntry, isSelected: Bool) -> some View {
        if showsDatabaseLabels {
            Label(databaseName(DatabaseScope.key(of: entry.groupPath)), systemImage: "cylinder.split.1x2")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : KM.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .trailing)
        }
    }

    /// Under search results: additional databases that weren't searched because they are locked.
    @ViewBuilder
    fileprivate var lockedDatabaseNotes: some View {
        if !trimmedQuery.isEmpty {
            ForEach(additional.databases.filter { $0.state == .locked }) { database in
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text(L("\(database.fileName) is locked — not searched"))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L("Unlock")) {
                        requestUnlock(database)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KM.accent)
                }
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
                .padding(.horizontal, 18)
                .frame(height: 28)
                .overlay(alignment: .top) {
                    Rectangle().fill(KM.hairline).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    fileprivate var additionalSections: some View {
        if !additional.databases.isEmpty {
            Color.clear.frame(height: 10)
            ForEach(additional.databases) { database in
                AdditionalDatabaseHeaderRow(
                    database: database,
                    isExpanded: expandedDatabases.contains(database.id),
                    isSelected: additional.rootPaths[database.id].map { currentLibrarySelection == .group($0) } ?? false,
                    onSelect: { selectDatabase(database) },
                    onToggle: { toggleDatabase(database) },
                    onLock: { additional.onLock(database.id) },
                    onUnlock: { requestUnlock(database) },
                    onNewGroup: {
                        if let root = additional.rootPaths[database.id] {
                            groupEditorMode = .create(parentPath: root)
                        }
                    },
                    onShowInFinder: {
                        if let url = database.url {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    },
                    onShowSettings: { databaseInfoKey = database.id },
                    onLocate: { locate(database) },
                    onRemove: { confirmRemove(database) },
                    onDrop: { payloads in
                        guard let root = additional.rootPaths[database.id] else {
                            return false
                        }
                        return SidebarDragPayload.handleDrop(
                            payloads: payloads,
                            targetGroupPath: root,
                            onMoveEntry: { id, path in Task { await performMoveEntry(id: id, toGroupPath: path) } },
                            onMoveGroup: { source, parent in Task { await performMoveGroup(path: source, toParentPath: parent) } }
                        )
                    }
                )
                if database.state == .unlocked, expandedDatabases.contains(database.id) {
                    ForEach(groupTree(forDatabase: database.id)) { node in
                        GroupTreeRowView(
                            node: node,
                            depth: 0,
                            expandedGroupPaths: $expandedGroupPaths,
                            currentSelection: currentLibrarySelection,
                            counts: groupCounts,
                            onSelect: { selectSidebarItem(.group($0)) },
                            onCreateEntry: { newEntryRequest = NewEntryRequest(groupPath: $0) },
                            onCreateSubgroup: { groupEditorMode = .create(parentPath: $0) },
                            onEditGroup: editGroup,
                            onDeleteGroup: confirmDeleteGroup,
                            onMoveEntry: { id, path in Task { await performMoveEntry(id: id, toGroupPath: path) } },
                            onMoveGroup: { source, parent in Task { await performMoveGroup(path: source, toParentPath: parent) } },
                            transferTargets: transferTargets(excluding: database.id),
                            onTransferGroup: { path, target, isCopy in
                                startTransfer(entryIDs: [], groupPath: path, to: target, isCopy: isCopy)
                            }
                        )
                    }
                    SidebarRow(
                        title: L("Trash"),
                        count: trashedEntries(inDatabase: database.id).count,
                        isSelected: currentLibrarySelection == .databaseTrash(database.id),
                        leadingPadding: 22
                    ) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(KM.accent)
                            .frame(width: 22)
                    }
                    .onTapGesture {
                        selectSidebarItem(.databaseTrash(database.id))
                    }
                }
            }
        }
    }

    fileprivate func selectDatabase(_ database: AdditionalDatabase) {
        switch database.state {
        case .locked:
            requestUnlock(database)
        case .missing:
            locate(database)
        case .unlocked:
            expandedDatabases.insert(database.id)
            if let root = additional.rootPaths[database.id] {
                selectSidebarItem(.group(root))
            }
        }
    }

    fileprivate func toggleDatabase(_ database: AdditionalDatabase) {
        guard database.state == .unlocked else {
            selectDatabase(database)
            return
        }
        if expandedDatabases.contains(database.id) {
            expandedDatabases.remove(database.id)
        } else {
            expandedDatabases.insert(database.id)
        }
    }

    // MARK: Opening

    fileprivate func addAdditionalDatabase() {
        guard let url = chooseDatabaseFile(message: L("Choose a database to open alongside \(vault.summary.fileName)")) else {
            return
        }
        unlockRequest = AdditionalUnlockRequest(kind: .new(url), fileName: url.lastPathComponent, path: url.path, keyFileURL: nil)
    }

    fileprivate func requestUnlock(_ database: AdditionalDatabase) {
        unlockRequest = AdditionalUnlockRequest(
            kind: .listed(key: database.id),
            fileName: database.fileName,
            path: database.path,
            keyFileURL: database.keyFileURL
        )
    }

    fileprivate func unlockAdditional(_ request: AdditionalUnlockRequest, password: String, keyFileURL: URL?) async throws {
        switch request.kind {
        case .listed(let key):
            try await additional.onUnlock(key, password, keyFileURL)
            expandedDatabases.insert(key)
        case .new(let url):
            try await additional.onAdd(url, password, keyFileURL)
        }
    }

    fileprivate func locate(_ database: AdditionalDatabase) {
        guard let url = chooseDatabaseFile(message: L("Find \(database.fileName)")) else {
            return
        }
        do {
            try additional.onLocate(database.id, url)
        } catch {
            operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    fileprivate func confirmRemove(_ database: AdditionalDatabase) {
        confirmRequest = ConfirmRequest(
            title: L("Remove “\(database.name)” from the list?"),
            message: L("The file stays where it is. You can add it again later."),
            confirmTitle: L("Remove")
        ) {
            confirmRequest = nil
            if case .databaseTrash(database.id) = currentLibrarySelection {
                selectedSidebarItemID = LibrarySelection.allItems.id
            }
            additional.onRemove(database.id)
        }
    }

    // MARK: Moving between databases

    /// Packs the entries (or group), asks about conflicts and linked fields, then moves or copies them.
    fileprivate func startTransfer(entryIDs: [UUID], groupPath: String?, to target: String?, isCopy: Bool) {
        guard !isPerformingMutation else {
            return
        }
        Task {
            do {
                let transfer = try await additional.onPrepareTransfer(entryIDs, groupPath, target, isCopy)
                let flow = TransferFlow(
                    transfer: transfer,
                    sourceName: databaseName(transfer.sourceKey),
                    targetName: databaseName(transfer.targetKey)
                )
                if !transfer.conflicts.isEmpty {
                    transferFlow = flow
                } else if transfer.linkedFieldCount > 0 {
                    confirmRequest = ConfirmRequest(
                        title: transferQuestion(transfer, targetName: flow.targetName),
                        message: linkedFieldsText(transfer.linkedFieldCount),
                        confirmTitle: isCopy ? L("Copy") : L("Move"),
                        isDestructive: false,
                        badgeSymbol: "link",
                        badgeColor: KM.accent
                    ) {
                        confirmRequest = nil
                        commitTransfer(transfer, decisions: [:])
                    }
                } else {
                    commitTransfer(transfer, decisions: [:])
                }
            } catch {
                operationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The suggestion banner's action: agent settings for an existing key attachment.
    fileprivate func useInSSHAgent(_ entry: VaultEntry, key: VaultAttachment) {
        var form = VaultEntryForm(entry: entry)
        form.sshAgent = VaultSSHAgentSettings(keyAttachmentName: key.name)
        Task {
            if await runMutation({ try await onUpdateEntry(entry.id, form) }) {
                CopyFeedbackCenter.shared.show(L("“\(entry.title)” is now in the SSH agent"), duration: 2.4)
            }
        }
    }

    fileprivate func transferQuestion(_ transfer: PreparedTransfer, targetName: String) -> String {
        let what = transfer.groupTitle.map { "“\($0)”" } ?? L("\(transfer.entryCount) entries")
        return transfer.isCopy ? L("Copy \(what) to \(targetName)?") : L("Move \(what) to \(targetName)?")
    }

    fileprivate func commitTransfer(_ transfer: PreparedTransfer, decisions: [UUID: VaultTransferDecision]) {
        Task {
            var count = 0
            let succeeded = await runMutation {
                count = try await additional.onCommitTransfer(transfer, decisions)
            }
            guard succeeded else {
                return
            }
            let target = databaseName(transfer.targetKey)
            guard count > 0 else {
                CopyFeedbackCenter.shared.show(transfer.isCopy ? L("Nothing was copied") : L("Nothing was moved"), duration: 2.4)
                return
            }
            let message = (transfer.isCopy ? L("Copied to \(target)") : L("Moved to \(target)")) + " · " + L("\(count) entries")
            CopyFeedbackCenter.shared.show(message, style: .success, duration: 5, actionTitle: L("Undo")) {
                Task {
                    await additional.onUndoTransfer()
                }
            }
        }
    }
}

/// An additional database in the sidebar: file name, collapse chevron, lock state, and its menu.
fileprivate struct AdditionalDatabaseHeaderRow: View {
    let database: AdditionalDatabase
    let isExpanded: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onLock: () -> Void
    let onUnlock: () -> Void
    let onNewGroup: () -> Void
    let onShowInFinder: () -> Void
    let onShowSettings: () -> Void
    let onLocate: () -> Void
    let onRemove: () -> Void
    let onDrop: @MainActor ([String]) -> Bool

    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var isUnlocked: Bool { database.state == .unlocked }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: database.state == .missing ? "exclamationmark.triangle.fill" : "cylinder.split.1x2")
                .font(.system(size: 12))
                .foregroundStyle(database.state == .missing ? KM.warning : (isUnlocked ? KM.accent : KM.textTertiary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(database.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : (isUnlocked ? KM.textPrimary : KM.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if database.state != .missing {
                        Button(action: onToggle) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : KM.textTertiary)
                                .rotationEffect(.degrees(isExpanded && isUnlocked ? 90 : 0))
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? L("Collapse \(database.name)") : L("Expand \(database.name)"))
                    }
                }
                if database.state == .missing {
                    Text(L("File not found"))
                        .font(.system(size: 10))
                        .foregroundStyle(KM.warning)
                }
            }
            Spacer(minLength: 4)
            if isUnlocked, isHovered {
                Button(action: onLock) {
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                }
                .buttonStyle(KMIconButtonStyle(size: 20, cornerRadius: 5, tint: isSelected ? .white : KM.textSecondary))
                .iconHelp(L("Lock \(database.name)"))
            } else if database.state == .locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(KM.textTertiary)
                    .help(L("Locked"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? KM.accent : (isDropTargeted ? KM.accent.opacity(0.14) : Color.clear))
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(database.state == .locked ? L("Locked. Click to unlock.") : database.path)
        .contextMenu {
            if database.state == .missing {
                Button(L("Locate…"), action: onLocate)
            } else {
                if isUnlocked {
                    Button(L("Lock"), action: onLock)
                    Button(L("New Group"), action: onNewGroup)
                } else {
                    Button(L("Unlock…"), action: onUnlock)
                }
                Button(L("Show in Finder"), action: onShowInFinder)
                Button(L("Database Settings…"), action: onShowSettings)
            }
            Divider()
            Button(L("Remove from List"), role: .destructive, action: onRemove)
        }
        .dropDestination(for: String.self) { payloads, _ in
            isUnlocked && onDrop(payloads)
        } isTargeted: { targeted in
            isDropTargeted = targeted && isUnlocked
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
