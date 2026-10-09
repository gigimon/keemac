import AppKit
import Data
import Domain
import SwiftUI

private struct WindowAccessorView: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

public struct RootView: View {
    @Bindable private var viewModel: AppViewModel
    @State private var copyFeedback = CopyFeedbackCenter.shared
    @State private var activityMonitorToken: Any?
    @State private var showDatabaseSettings: Bool = false
    @State private var isCreatingDatabase: Bool = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var additionalContext: AdditionalDatabasesContext {
        var context = AdditionalDatabasesContext()
        context.databases = viewModel.additionalDatabases
        for database in viewModel.additionalDatabases where database.state == .unlocked {
            context.rootPaths[database.id] = viewModel.additionalRootPath(database.id)
            context.supportsEntryTypes[database.id] = viewModel.additionalSupportsEntryTypes(database.id)
        }
        context.onAdd = { url, password, keyFileURL in
            try await viewModel.addAdditionalDatabase(url: url, password: password, keyFileURL: keyFileURL)
        }
        context.onUnlock = { key, password, keyFileURL in
            try await viewModel.unlockAdditionalDatabase(key, password: password, keyFileURL: keyFileURL)
        }
        context.onLock = { viewModel.lockAdditionalDatabase($0) }
        context.onRemove = { viewModel.removeAdditionalDatabase($0) }
        context.onLocate = { key, url in try viewModel.locateAdditionalDatabase(key, at: url) }
        context.onActiveDatabaseChanged = { viewModel.activeDatabaseKey = $0 }
        context.onPrepareTransfer = { ids, groupPath, target, isCopy in
            try await viewModel.prepareTransfer(entryIDs: ids, groupPath: groupPath, toGroupPath: target, isCopy: isCopy)
        }
        context.onCommitTransfer = { transfer, decisions in
            try await viewModel.commitTransfer(transfer, decisions: decisions)
        }
        context.onUndoTransfer = { await viewModel.undoLastTransfer() }
        return context
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loaded(let vault):
                VaultBrowserView(
                    vault: viewModel.browserVault ?? vault,
                    favoriteEntryIDs: viewModel.favoriteEntryIDs,
                    recentViewedEntryIDs: viewModel.recentViewedEntryIDs,
                    includeSubgroupEntries: viewModel.includeSubgroupEntriesInGroupView,
                    syncStatus: viewModel.syncStatus,
                    externalChanges: viewModel.externalChanges,
                    revealRequest: viewModel.revealRequest,
                    syncFailureMessage: viewModel.syncFailureMessage,
                    showsDiskChangeBanner: viewModel.showsDiskChangeBanner,
                    showsExpiryBanner: viewModel.showsExpiryBanner,
                    expiryWarnDays: viewModel.expiryWarnDaysForSelectedVault,
                    passwordHealthRequest: viewModel.passwordHealthRequest,
                    onReviewExpiry: { viewModel.openPasswordHealth() },
                    onDismissExpiryBanner: { viewModel.dismissExpiryBanner() },
                    onPasswordHealthHandled: { viewModel.consumePasswordHealthRequest() },
                    onMergeDiskChanges: { Task { await viewModel.mergeDiskChanges() } },
                    onShowDiskChanges: { viewModel.showDiskChanges() },
                    onIgnoreDiskChanges: { viewModel.ignoreDiskChanges() },
                    onShowDiskChangeBanner: { viewModel.showDiskChangeBanner() },
                    onMergeDatabase: { viewModel.showMergeDatabase() },
                    onRevealHandled: { viewModel.consumeRevealRequest() },
                    onExternalChangeSeen: { viewModel.markExternalChangeSeen($0) },
                    onRetrySync: { viewModel.retrySync() },
                    onDismissSyncFailure: { viewModel.dismissSyncFailure() },
                    initialSidebarSelectionID: viewModel.browserSidebarSelectionID(for: viewModel.selectedVaultURL),
                    initialExpandedGroupPaths: viewModel.browserExpandedGroupPaths(for: viewModel.selectedVaultURL),
                    onCreateGroup: { parentPath, title, iconID in
                        try await viewModel.createGroup(inParentPath: parentPath, title: title, iconID: iconID)
                    },
                    onUpdateGroup: { path, title, iconID in
                        try await viewModel.updateGroup(path: path, title: title, iconID: iconID)
                    },
                    onDeleteGroup: { path in
                        try await viewModel.deleteGroup(path: path)
                    },
                    onCreateEntry: { groupPath, form in
                        try await viewModel.createEntry(inGroupPath: groupPath, form: form)
                    },
                    onUpdateEntry: { id, form in
                        try await viewModel.updateEntry(id: id, form: form)
                    },
                    onDuplicateEntry: { id, referencing in
                        try await viewModel.duplicateEntry(id: id, referencingCredentials: referencing)
                    },
                    onDeleteEntry: { id in
                        try await viewModel.deleteEntry(id: id)
                    },
                    onEmptyTrash: { ids in
                        try await viewModel.emptyTrash(ids: ids)
                    },
                    onMoveEntry: { id, groupPath in
                        try await viewModel.moveEntry(id: id, toGroupPath: groupPath)
                    },
                    onMoveGroup: { path, parentPath in
                        try await viewModel.moveGroup(path: path, toParentPath: parentPath)
                    },
                    onRestoreEntry: { id in
                        try await viewModel.restoreEntry(id: id)
                    },
                    onRevertEntry: { id, index in
                        try await viewModel.revertEntry(id: id, toHistoryRevisionAt: index)
                    },
                    onToggleFavorite: { id in
                        viewModel.toggleFavorite(entryID: id)
                    },
                    onEntryViewed: { id in
                        viewModel.markEntryViewed(id)
                    },
                    onEntryUsed: { id in
                        viewModel.recordEntryUsage(id: id)
                    },
                    onLockVault: {
                        NotificationCenter.default.post(name: AppCommand.lockVault, object: nil)
                    },
                    onSidebarSelectionChanged: { id in
                        // Additional databases are opened for one session; only the main database's selection is remembered.
                        guard let id, !id.contains(DatabaseScope.start), !id.hasPrefix("dbtrash.") else {
                            return
                        }
                        viewModel.setBrowserSidebarSelectionID(id, for: viewModel.selectedVaultURL)
                    },
                    onExpandedGroupsChanged: { paths in
                        viewModel.setBrowserExpandedGroupPaths(paths.filter { DatabaseScope.key(of: $0) == nil }, for: viewModel.selectedVaultURL)
                    },
                    additional: additionalContext
                )
                    .id(viewModel.selectedVaultURL?.standardizedFileURL.path ?? "")
                    .onAppear {
                        startActivityMonitor()
                        viewModel.registerUserActivity()
                    }
                    .onDisappear {
                        stopActivityMonitor()
                    }
                    .sheet(item: Binding(
                        get: { viewModel.mergeSheet },
                        set: { if $0 == nil { viewModel.dismissMergeSheet() } }
                    )) { request in
                        MergeSheet(request: request, vault: vault, databaseURL: viewModel.selectedVaultURL, viewModel: viewModel)
                    }
                    .sheet(isPresented: Binding(
                        get: { viewModel.showsImportSheet },
                        set: { viewModel.showsImportSheet = $0 }
                    )) {
                        ImportSheet(vault: vault, viewModel: viewModel)
                    }
                    .sheet(isPresented: Binding(
                        get: { viewModel.showsExportSheet },
                        set: { viewModel.showsExportSheet = $0 }
                    )) {
                        ExportSheet(vault: vault, viewModel: viewModel, currentGroupPath: viewModel.selectedBrowserGroupPath)
                    }
                    .overlay {
                        if let request = syncAlertRequest {
                            ConfirmDialog(request: request) {
                                viewModel.dismissSyncAlert()
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: viewModel.syncAlert)
            case .idle, .loading, .locked, .failed:
                if isCreatingDatabase {
                    NewDatabaseView(viewModel: viewModel) {
                        isCreatingDatabase = false
                    }
                } else {
                    UnlockView(
                        viewModel: viewModel,
                        statusMessage: lockedStatus.message,
                        isError: lockedStatus.isError,
                        onCreateDatabase: { isCreatingDatabase = true }
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.loadState)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            viewModel.lockVault(reason: .systemSleep)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Self.screenLockedNotification)) { _ in
            if viewModel.lockOnScreenLock {
                viewModel.lockVault(reason: .screenLocked)
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Self.screenSaverStartedNotification)) { _ in
            if viewModel.lockOnScreenLock {
                viewModel.lockVault(reason: .screenLocked)
            }
        }
        // Fast user switching: KeeMac keeps running in the session that moved to the background.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
            if viewModel.lockOnScreenLock {
                viewModel.lockVault(reason: .sessionSwitched)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openVault)) { _ in
            viewModel.disableBiometricUnlockScreen()
            if let url = VaultFilePicker.chooseVault() {
                viewModel.selectVault(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.newVault)) { _ in
            if case .loaded = viewModel.loadState {
                viewModel.lockVault(reason: .userInitiated)
            }
            isCreatingDatabase = true
        }
        .onChange(of: isCreatingDatabase) { _, _ in
            applyWindowLayout(for: viewModel.loadState)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.selectKeyFile)) { _ in
            if let url = VaultFilePicker.chooseKeyFile() {
                viewModel.selectKeyFile(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openPasswordHealth)) { _ in
            viewModel.openPasswordHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.importData)) { _ in
            viewModel.showImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.exportData)) { _ in
            viewModel.showExport()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.undo)) { _ in
            Task { await viewModel.undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.redo)) { _ in
            Task { await viewModel.redo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.mergeDatabase)) { _ in
            viewModel.showMergeDatabase()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openDatabaseSettings)) { _ in
            if case .loaded = viewModel.loadState {
                showDatabaseSettings = true
            }
        }
        .sheet(isPresented: $showDatabaseSettings) {
            DatabaseSettingsView(
                templateGroups: templateGroupOptions,
                onLoad: {
                    try await viewModel.loadDatabaseSettings()
                },
                onSaveSettings: { settings in
                    try await viewModel.updateDatabaseSettings(settings)
                },
                onChangePassword: { newPassword in
                    try await viewModel.changeMasterPassword(newPassword: newPassword)
                },
                additionalDatabases: viewModel.additionalDatabases,
                onRemoveAdditional: { viewModel.removeAdditionalDatabase($0) },
                onLocateAdditional: { key, url in try viewModel.locateAdditionalDatabase(key, at: url) }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.clearKeyFile)) { _ in
            viewModel.selectKeyFile(url: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.lockVault)) { _ in
            viewModel.lockVault(reason: .userInitiated)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow else {
                return
            }
            guard MainWindowStore.shared.isMainWindow(window) else {
                return
            }
            viewModel.lockVault(reason: .userInitiated)
            MainWindowStore.shared.clearIfMainWindow(window)
        }
        .onChange(of: viewModel.loadState) { _, newState in
            if case .loaded = newState {
                isCreatingDatabase = false
            }
            applyWindowLayout(for: newState)
        }
        .background(
            WindowAccessorView { window in
                MainWindowStore.shared.register(window: window)
                applyWindowLayout(for: viewModel.loadState)
            }
        )
        .overlay(alignment: .bottom) {
            CopyFeedbackOverlay(center: copyFeedback)
        }
        .frame(
            minWidth: isLoaded ? 980 : (isCreatingDatabase ? 620 : 440),
            idealWidth: isLoaded ? 1240 : (isCreatingDatabase ? 620 : 440),
            minHeight: isLoaded ? 680 : 540,
            idealHeight: isLoaded ? 780 : 580
        )
    }

    private static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenSaverStartedNotification = Notification.Name("com.apple.screensaver.didstart")

    private var templateGroupOptions: [TemplateGroupOption]? {
        guard case .loaded(let vault) = viewModel.loadState, vault.summary.supportsEntryTypes else {
            return nil
        }
        let rootPath = vault.groups.first(where: { !$0.path.contains(".") })?.path ?? ""
        return vault.groups
            .filter { !$0.isTrash && $0.path != rootPath }
            .map { group in
                TemplateGroupOption(
                    path: group.path,
                    title: group.title,
                    depth: max(group.path.split(separator: ".").count - 2, 0),
                    entryCount: vault.entries.filter { !$0.isTrashed && $0.groupPath == group.path }.count
                )
            }
    }

    private var syncAlertRequest: ConfirmRequest? {
        guard let alert = viewModel.syncAlert else {
            return nil
        }
        let name = viewModel.selectedVaultURL?.lastPathComponent ?? L("this database")
        switch alert {
        case .conflictCopies(let copies):
            let title = copies.count == 1
                ? L("Found a conflicting copy of \(name)")
                : L("Found conflicting copies of \(name)")
            return ConfirmRequest(
                title: title,
                message: L("Other devices saved their own copies instead of updating this file. Review the changes and merge them into \(name)."),
                confirmTitle: L("Review and Merge"),
                cancelTitle: L("Later"),
                isDestructive: false,
                badgeSymbol: "icloud.fill",
                badgeColor: KM.accent,
                files: copies.map(Self.confirmFile)
            ) {
                viewModel.reviewConflictCopies()
            }
        case .trashCopies(let copies):
            return ConfirmRequest(
                title: copies.count == 1 ? L("Move the conflicting copy to Trash?") : L("Move conflicting copies to Trash?"),
                message: copies.count == 1
                    ? L("All its changes are now in \(name). The copy is no longer needed.")
                    : L("All their changes are now in \(name). The copies are no longer needed."),
                confirmTitle: copies.count == 1 ? L("Move Copy to Trash") : L("Move Copies to Trash"),
                cancelTitle: copies.count == 1 ? L("Keep Copy") : L("Keep Copies"),
                isDestructive: false,
                badgeSymbol: "trash.fill",
                badgeColor: KM.textSecondary,
                files: copies.map(Self.confirmFile)
            ) {
                viewModel.trashConflictCopies()
            }
        }
    }

    private static func confirmFile(_ copy: VaultConflictCopy) -> ConfirmFile {
        let date = copy.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? L("unknown date")
        return ConfirmFile(name: copy.fileURL.lastPathComponent, detail: "\(copy.provider.rawValue) · \(date)")
    }

    private var lockedStatus: (message: String?, isError: Bool) {
        switch viewModel.loadState {
        case .locked(let message):
            return (message, false)
        case .failed(let message):
            return (message, true)
        case .idle, .loading, .loaded:
            return (nil, false)
        }
    }

    private var isLoaded: Bool {
        if case .loaded = viewModel.loadState {
            return true
        }
        return false
    }

    private func startActivityMonitor() {
        guard activityMonitorToken == nil else {
            return
        }
        let model = viewModel
        activityMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved, .scrollWheel]
        ) { event in
            model.registerUserActivity()
            return event
        }
    }

    private func stopActivityMonitor() {
        guard let activityMonitorToken else {
            return
        }
        NSEvent.removeMonitor(activityMonitorToken)
        self.activityMonitorToken = nil
    }

    private func applyWindowLayout(for state: AppViewModel.LoadState) {
        guard let window = MainWindowStore.shared.window else {
            return
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        switch state {
        case .loaded(let vault):
            window.title = vault.summary.fileName
            let minSize = NSSize(width: 980, height: 680)
            window.minSize = minSize
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

            let currentSize = window.contentRect(forFrameRect: window.frame).size
            if currentSize.width < minSize.width || currentSize.height < minSize.height {
                window.setContentSize(NSSize(width: max(currentSize.width, 1240), height: max(currentSize.height, 780)))
                keepOnScreen(window)
            }

        case .idle, .loading, .locked, .failed:
            window.title = isCreatingDatabase ? L("New Database") : "KeeMac"
            let width: CGFloat = isCreatingDatabase ? 620 : 440
            let targetSize = NSSize(width: width, height: 580)
            window.minSize = NSSize(width: width, height: 540)
            window.maxSize = NSSize(width: width, height: 760)

            let currentSize = window.contentRect(forFrameRect: window.frame).size
            if abs(currentSize.width - targetSize.width) > 1 || currentSize.height > 760 || currentSize.height < 540 {
                window.setContentSize(targetSize)
                keepOnScreen(window)
            }
        }
    }

    /// Growing keeps the top-left corner, which can push the window past the screen's edge.
    private func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}

private struct CopyFeedbackOverlay: View {
    let center: CopyFeedbackCenter

    var body: some View {
        ZStack {
            if let toast = center.current {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: toast.style))
                        .font(.system(size: 15))
                        .foregroundStyle(color(for: toast.style))
                    Text(toast.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KM.toastText)
                        .lineLimit(1)
                    if let actionTitle = toast.actionTitle {
                        Rectangle()
                            .fill(KM.toastText.opacity(0.25))
                            .frame(width: 1, height: 16)
                        Button(actionTitle) {
                            center.runAction()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(lightHex: 0x4DA3FF, darkHex: 0x007AFF))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .frame(height: 36)
                .background(
                    Capsule(style: .continuous)
                        .fill(KM.toastBackground)
                )
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(toast.actionTitle != nil)
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
    }

    private func symbol(for style: CopyFeedbackCenter.Toast.Style) -> String {
        switch style {
        case .success:
            return "checkmark.circle.fill"
        case .synced:
            return "checkmark.icloud.fill"
        case .restored:
            return "clock.arrow.circlepath"
        }
    }

    private func color(for style: CopyFeedbackCenter.Toast.Style) -> Color {
        switch style {
        case .success, .synced:
            return KM.success
        case .restored:
            return KM.accent
        }
    }
}
