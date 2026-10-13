import AppKit
import Data
import Domain
import SwiftUI

/// Quick Access: a small panel under the menu bar icon to find an entry and copy from it
/// without the main window. It never activates KeeMac, so the app you were in keeps focus
/// and you can paste right away.
@MainActor
public final class QuickAccessController: NSObject, NSWindowDelegate {
    public static let shared = QuickAccessController()

    /// Set when the hotkey can't be registered, usually because another app holds it.
    public private(set) var shortcutConflict = false

    private weak var viewModel: AppViewModel?
    private let settings = AppSettingsStore.shared
    private var hotKey: GlobalHotKey?
    private var panel: QuickAccessPanel?
    private var model: QuickAccessModel?
    /// The database was unlocked from the panel, so it locks again by `quickAccessUnlockDuration`.
    private var unlockedHere = false
    private var relockTask: Task<Void, Never>?
    private var lockStateObserver: NSObjectProtocol?

    override private init() {}

    public func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        hotKey = GlobalHotKey { [weak self] in
            self?.toggle()
        }
        updateHotKey()
        lockStateObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.vaultLockStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let unlocked = notification.userInfo?[AppCommand.vaultUnlockedUserInfoKey] as? Bool ?? false
            Task { @MainActor in
                if !unlocked {
                    self?.forgetQuickUnlock()
                }
            }
        }
    }

    /// Registers the shortcut from settings again (after it changed or was turned off).
    public func updateHotKey() {
        // A global shortcut would clash with the user's own KeeMac.
        guard let hotKey, !UITesting.isActive else {
            return
        }
        guard settings.quickAccessEnabled else {
            hotKey.unregister()
            shortcutConflict = false
            return
        }
        shortcutConflict = !hotKey.register(settings.quickAccessShortcut)
    }

    /// Lets the shortcut recorder see the current shortcut instead of opening the panel.
    public func suspendHotKey() {
        hotKey?.unregister()
    }

    /// The main window was opened: the user is working with the database, so don't lock it behind their back.
    public func keepUnlocked() {
        forgetQuickUnlock()
    }

    public func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    public func show() {
        guard let viewModel else {
            return
        }
        relockTask?.cancel()
        relockTask = nil

        let model = QuickAccessModel(
            viewModel: viewModel,
            suggestionAppName: NSWorkspace.shared.frontmostApplication.flatMap { app in
                app.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app.localizedName
            },
            actions: QuickAccessModel.Actions(
                close: { [weak self] in self?.close() },
                didUnlock: { [weak self] in self?.unlockedHere = true },
                refocus: { [weak self] in self?.panel?.makeKey() },
                showInMainWindow: { [weak self] id in self?.showInMainWindow(entryID: id) }
            )
        )
        self.model = model

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.keyHandler = { [weak model] event in
            model?.handleKey(event) ?? false
        }
        let hosting = NSHostingView(rootView: QuickAccessView(model: model))
        hosting.frame = NSRect(origin: .zero, size: QuickAccessView.size)
        panel.contentView = hosting
        panel.setFrame(frame(for: QuickAccessView.size), display: false)
        panel.makeKeyAndOrderFront(nil)
        model.didAppear()
    }

    public func close() {
        guard let panel, panel.isVisible else {
            return
        }
        panel.orderOut(nil)
        panel.contentView = nil
        model = nil
        scheduleRelock()
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Touch ID's system dialog takes key status for a moment; the panel stays open behind it.
        if model?.isAuthenticating == true {
            return
        }
        close()
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: QuickAccessView.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.delegate = self
        panel.setAccessibilityLabel(L("Quick Access"))
        return panel
    }

    /// Under the menu bar icon, or at the top right of the screen with the pointer when the icon can't be found.
    private func frame(for size: CGSize) -> NSRect {
        let statusWindow = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = statusWindow?.screen ?? mouseScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let anchor = statusWindow?.frame {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: visible.maxY - size.height - 6)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 6)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }

    private func showInMainWindow(entryID: UUID) {
        forgetQuickUnlock()
        close()
        NotificationCenter.default.post(name: AppCommand.showMainWindow, object: nil)
        // The browser picks up reveal requests only once it is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.viewModel?.requestReveal([entryID])
        }
    }

    private func scheduleRelock() {
        guard unlockedHere, let viewModel, viewModel.loadState.isUnlocked else {
            unlockedHere = false
            return
        }
        guard let delay = settings.quickAccessUnlockDuration.relockDelay else {
            unlockedHere = false
            return
        }
        relockTask?.cancel()
        relockTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.unlockedHere else {
                return
            }
            self.unlockedHere = false
            self.relockTask = nil
            self.viewModel?.lockVault(reason: .quickAccess)
        }
    }

    private func forgetQuickUnlock() {
        unlockedHere = false
        relockTask?.cancel()
        relockTask = nil
    }
}

/// Borderless panel that takes keyboard input without activating KeeMac.
final class QuickAccessPanel: NSPanel {
    /// Returns true when the key press was handled (arrows, Return, Escape, shortcuts).
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
@Observable
final class QuickAccessModel {
    struct Actions {
        let close: () -> Void
        let didUnlock: () -> Void
        let refocus: () -> Void
        let showInMainWindow: (UUID) -> Void
    }

    let viewModel: AppViewModel
    /// The app that was in front when Quick Access opened; its entries come first.
    let suggestionAppName: String?
    var query = "" {
        didSet {
            selectedIndex = 0
        }
    }
    var selectedIndex = 0
    var masterPassword = ""
    private(set) var isAuthenticating = false
    private(set) var confirmation: String?
    /// Bumped to move focus back into the text field.
    private(set) var focusRequest = 0
    private let actions: Actions

    init(viewModel: AppViewModel, suggestionAppName: String?, actions: Actions) {
        self.viewModel = viewModel
        self.suggestionAppName = suggestionAppName
        self.actions = actions
    }

    var vault: LoadedVault? {
        if case .loaded(let vault) = viewModel.loadState {
            return vault
        }
        return nil
    }

    var canUseTouchID: Bool {
        viewModel.showBiometricUnlockScreen && viewModel.touchIDEnabledForSelectedVault
    }

    var results: [VaultEntry] {
        guard let vault else {
            return []
        }
        let live = vault.entries.filter { !$0.isTrashed }
        let favorites = viewModel.favoriteEntryIDs
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            let search = VaultEntrySearch(trimmed)
            let context = VaultEntrySearch.Context(isFavorite: { favorites.contains($0) })
            return Array(live.filter { search.matches($0, context: context) }.sorted(by: Self.byUsage).prefix(50))
        }

        let suggestions = suggestions(in: live)
        let suggestedIDs = Set(suggestions.map(\.id))
        let rest = live.filter { !suggestedIDs.contains($0.id) }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return suggestions + rest
    }

    /// With an empty query the list starts with this many suggestions, then every other entry by title.
    var suggestionCount: Int {
        guard let vault, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        return suggestions(in: vault.entries.filter { !$0.isTrashed }).count
    }

    /// Entries for the app in front, then recently used, then favorites.
    private func suggestions(in live: [VaultEntry]) -> [VaultEntry] {
        let favorites = viewModel.favoriteEntryIDs
        let suggested = live.filter { Self.entry($0, matchesApp: suggestionAppName) }.sorted(by: Self.byUsage)
        let recent = live.filter { $0.usageCount > 0 }.sorted {
            ($0.accessedAt ?? .distantPast) > ($1.accessedAt ?? .distantPast)
        }
        let favorite = live.filter { favorites.contains($0.id) }.sorted(by: Self.byUsage)
        var seen = Set<UUID>()
        let unique = (suggested + recent + favorite).filter { seen.insert($0.id).inserted }
        return Array(unique.prefix(5))
    }

    /// Some suggestions belong to the app that was in front.
    var hasAppSuggestions: Bool {
        vault?.entries.contains { !$0.isTrashed && Self.entry($0, matchesApp: suggestionAppName) } ?? false
    }

    var selectedEntry: VaultEntry? {
        let results = results
        return results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func didAppear() {
        focusRequest += 1
        if vault == nil, canUseTouchID, viewModel.loadState != .loading {
            unlockWithTouchID()
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch Int(event.keyCode) {
        case 53: // Escape
            actions.close()
            return true
        case 125: // Down
            guard vault != nil else { return false }
            moveSelection(by: 1)
            return true
        case 126: // Up
            guard vault != nil else { return false }
            moveSelection(by: -1)
            return true
        case 36, 76: // Return, Enter
            if vault == nil {
                unlockWithPassword()
            } else if flags.contains(.command) {
                selectedEntry.map { actions.showInMainWindow($0.id) }
            } else {
                copy(.password)
            }
            return true
        default:
            break
        }

        guard flags == .command else {
            return false
        }
        switch key {
        case "u" where vault != nil:
            copy(.username)
            return true
        case "t" where vault != nil:
            copy(.oneTimeCode)
            return true
        // KeeMac isn't the active app, so the Edit menu can't route these to the text field.
        case "v":
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "c":
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "a":
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        default:
            return false
        }
    }

    enum Field {
        case password
        case username
        case oneTimeCode

        var label: String {
            switch self {
            case .password:
                return L("Password")
            case .username:
                return L("Username")
            case .oneTimeCode:
                return L("One-time code")
            }
        }
    }

    func value(of field: Field, in entry: VaultEntry) -> String? {
        let value: String?
        switch field {
        case .password:
            value = entry.password
        case .username:
            value = entry.username
        case .oneTimeCode:
            value = entry.otp.flatMap { OTPCodeGenerator.makeCodeState(from: $0, now: Date())?.code }
        }
        return value?.isEmpty == false ? value : nil
    }

    func copy(_ field: Field, from entry: VaultEntry? = nil) {
        guard let entry = entry ?? selectedEntry, let value = value(of: field, in: entry) else {
            NSSound.beep()
            return
        }
        if field == .oneTimeCode, let otp = entry.otp, otp.kind == .hotp {
            copyHOTPCode(otp, of: entry)
            return
        }
        confirmation = SensitiveClipboard.shared.copySensitiveText(value, label: field.label, showsToast: false)
        viewModel.recordEntryUsage(id: entry.id)
        viewModel.registerUserActivity()
        closeAfterConfirmation()
    }

    /// A copied HOTP code is used up: the counter moves on and is saved before the panel closes (and may lock).
    private func copyHOTPCode(_ otp: VaultOTPConfiguration, of entry: VaultEntry) {
        Task {
            do {
                guard let used = try await viewModel.advanceHOTPCounter(entryID: entry.id),
                      let code = OTPCodeGenerator.code(secret: otp.secret, counter: used, digits: otp.digits, algorithm: otp.algorithm) else {
                    NSSound.beep()
                    return
                }
                confirmation = SensitiveClipboard.shared.copySensitiveText(code, label: Field.oneTimeCode.label, showsToast: false)
                viewModel.recordEntryUsage(id: entry.id)
                viewModel.registerUserActivity()
                closeAfterConfirmation()
            } catch {
                SecureLogger.logUnlockFailure(error)
                NSSound.beep()
            }
        }
    }

    func showInMainWindow(_ entry: VaultEntry) {
        actions.showInMainWindow(entry.id)
    }

    func unlockWithTouchID() {
        guard !isAuthenticating else {
            return
        }
        isAuthenticating = true
        Task {
            await viewModel.unlockWithBiometrics()
            finishUnlock()
        }
    }

    func unlockWithPassword() {
        guard !masterPassword.isEmpty, !isAuthenticating else {
            return
        }
        let password = masterPassword
        masterPassword = ""
        isAuthenticating = true
        Task {
            await viewModel.unlock(masterPassword: password)
            finishUnlock()
        }
    }

    func openMainWindow() {
        actions.close()
        NotificationCenter.default.post(name: AppCommand.showMainWindow, object: nil)
    }

    private func finishUnlock() {
        isAuthenticating = false
        if viewModel.loadState.isUnlocked {
            actions.didUnlock()
            query = ""
        }
        actions.refocus()
        focusRequest += 1
    }

    private func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else {
            return
        }
        selectedIndex = min(max(selectedIndex + offset, 0), count - 1)
    }

    private func closeAfterConfirmation() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            actions.close()
        }
    }

    private static func byUsage(_ lhs: VaultEntry, _ rhs: VaultEntry) -> Bool {
        if lhs.usageCount != rhs.usageCount {
            return lhs.usageCount > rhs.usageCount
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// "Slack" matches entries titled "Slack Work" or for slack.com.
    private static func entry(_ entry: VaultEntry, matchesApp appName: String?) -> Bool {
        guard let appName else {
            return false
        }
        let name = appName.lowercased().filter { !$0.isWhitespace }
        guard name.count >= 3 else {
            return false
        }
        if entry.title.lowercased().filter({ !$0.isWhitespace }).contains(name) {
            return true
        }
        return entry.url?.host()?.lowercased().contains(name) ?? false
    }
}

struct QuickAccessView: View {
    static let visibleRows = 7
    static let rowHeight: CGFloat = 44
    static let size = CGSize(width: 440, height: 56 + CGFloat(visibleRows) * rowHeight + 12 + 34)

    @Bindable var model: QuickAccessModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.vault != nil {
                searchContent
            } else {
                lockedContent
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KM.menuBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KM.chromeBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .tint(KM.accent)
        .onChange(of: model.focusRequest, initial: true) {
            isFieldFocused = true
        }
    }

    // MARK: Unlocked

    private var searchContent: some View {
        let results = model.results
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(KM.textSecondary)
                TextField(L("Search entries"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($isFieldFocused)
                    .accessibilityLabel(L("Search entries"))
                if let name = model.viewModel.selectedVaultURL?.deletingPathExtension().lastPathComponent {
                    // The open database, not a filter: no chip, so it doesn't read as a removable tag.
                    Label(name, systemImage: "cylinder.split.1x2")
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(L("Database"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            Rectangle()
                .fill(KM.hairline)
                .frame(height: 0.5)

            if results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let suggestionCount = model.suggestionCount
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                if suggestionCount > 0 && index == 0 {
                                    sectionLabel(suggestionTitle)
                                } else if suggestionCount > 0 && index == suggestionCount {
                                    sectionLabel(L("All entries"))
                                        .padding(.top, 6)
                                }
                                row(entry, isSelected: index == model.selectedIndex)
                                    .id(entry.id)
                                    .onTapGesture {
                                        model.selectedIndex = index
                                        model.copy(.password, from: entry)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedIndex) { _, index in
                        if results.indices.contains(index) {
                            proxy.scrollTo(results[index].id)
                        }
                    }
                }
            }

            footer
        }
    }

    private var suggestionTitle: String {
        if let app = model.suggestionAppName, model.hasAppSuggestions {
            return L("Suggested in \(app)")
        }
        return L("Suggested")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(KM.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private func row(_ entry: VaultEntry, isSelected: Bool) -> some View {
        let supportsTypes = model.vault?.summary.supportsEntryTypes ?? false
        return HStack(spacing: 10) {
            EntryTile(entry: entry, supportsTypes: supportsTypes, size: 28, cornerRadius: 7, fontSize: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? L("Untitled") : entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : KM.textPrimary)
                    .lineLimit(1)
                Text(subtitle(entry, supportsTypes: supportsTypes))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : KM.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                HStack(spacing: 4) {
                    rowAction("person", help: L("Copy Username (⌘U)"), enabled: model.value(of: .username, in: entry) != nil) {
                        model.copy(.username, from: entry)
                    }
                    rowAction("key", help: L("Copy Password (↩)"), enabled: model.value(of: .password, in: entry) != nil) {
                        model.copy(.password, from: entry)
                    }
                    if entry.otp != nil {
                        rowAction("clock", help: L("Copy One-Time Code (⌘T)"), enabled: true) {
                            model.copy(.oneTimeCode, from: entry)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? KM.accent : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowAction(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .iconHelp(help)
    }

    private func subtitle(_ entry: VaultEntry, supportsTypes: Bool) -> String {
        if let typed = entry.typedSubtitle(supportsTypes: supportsTypes) {
            return typed
        }
        let rootPath = model.vault?.groups.first(where: { !$0.path.contains(".") })?.path ?? ""
        let group = entry.groupPath == rootPath ? "" : GroupPathFormatter.display(entry.groupPath, rootPath: rootPath)
        let detail = entry.username.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url?.host() ?? ""
        return [detail, group].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.query.isEmpty ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(KM.textTertiary)
            Text(model.query.isEmpty ? L("No Entries") : L("No entries match “\(model.query)”"))
                .font(.system(size: 13))
                .foregroundStyle(KM.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let confirmation = model.confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(KM.success)
                    .lineLimit(1)
            } else {
                hint("↩", L("Password"))
                hint("⌘U", L("Username"))
                hint("⌘T", L("quickAccess.hint.code", default: "Code"))
                Spacer(minLength: 0)
                hint("⌘↩", L("Show in KeeMac"))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(KM.insetFill)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(KM.hairline)
                .frame(height: 0.5)
        }
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KM.textSecondary)
            Text(title)
                .foregroundStyle(KM.textTertiary)
        }
        .lineLimit(1)
    }

    // MARK: Locked

    @ViewBuilder
    private var lockedContent: some View {
        if let vaultURL = model.viewModel.selectedVaultURL {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AppIconImage(size: 52)
                Text(L("Unlock \(vaultURL.deletingPathExtension().lastPathComponent)"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(L("Quick Access needs the database unlocked"))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    SecureField(L("Master password"), text: $model.masterPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isFieldFocused)
                        .kmField(height: 32)
                        .disabled(model.isAuthenticating)
                    if model.canUseTouchID {
                        Button(action: model.unlockWithTouchID) {
                            Image(systemName: "touchid")
                                .font(.system(size: 18))
                                .foregroundStyle(KM.touchID)
                        }
                        .buttonStyle(KMIconButtonStyle(size: 32, cornerRadius: 8, filled: true))
                        .iconHelp(L("Unlock with Touch ID"))
                        .disabled(model.isAuthenticating)
                    }
                }
                .frame(width: 300)
                .padding(.top, 18)

                Group {
                    if model.isAuthenticating || model.viewModel.loadState == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else if case .failed(let message) = model.viewModel.loadState {
                        Text(message)
                            .foregroundStyle(KM.danger)
                    } else {
                        Text(L("Press ↩ to unlock"))
                            .foregroundStyle(KM.textTertiary)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 300, height: 30)
                .padding(.top, 6)

                Spacer(minLength: 0)
                Button(L("Open KeeMac"), action: model.openMainWindow)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(KM.accent)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                AppIconImage(size: 52)
                Text(L("No database selected"))
                    .font(.system(size: 15, weight: .semibold))
                Button(L("Open KeeMac"), action: model.openMainWindow)
                    .buttonStyle(KMButtonStyle(kind: .primary, height: 28, horizontalPadding: 14, fontWeight: .semibold, fontSize: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
