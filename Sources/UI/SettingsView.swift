import BrowserIntegration
import Domain
import SSHAgent
import SwiftUI

public struct SettingsView: View {
    private enum Tab: Hashable {
        case general
        case security
        case shortcuts
        case browser
        case autoType
        case sshAgent
        case about
    }

    @Bindable private var viewModel: AppViewModel
    @State private var selectedTab: Tab = .general
    @State private var generator = PasswordGeneratorSettings.shared
    @State private var browser = BrowserIntegrationController.shared
    @State private var settings = AppSettingsStore.shared
    @State private var navigation = SettingsNavigation.shared
    @State private var shortcutConflict = QuickAccessController.shared.shortcutConflict
    @State private var autoTypeShortcutConflict = AutoTypeController.shared.shortcutConflict
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var sshAgent = SSHAgentController.shared
    @State private var sshConfigIsSetUp = SSHConfigSetup.isSetUp()
    @State private var showsSSHConfigLines = false
    @State private var showsSSHImport = false
    @State private var sshConfigError: String?
    @AppStorage(KMLayout.storageKey) private var layoutRaw: String = KMLayout.tahoe.rawValue
    @AppStorage(KMLayout.showIconsKey) private var showsEntryIcons: Bool = true

    private let vaultLockTimeoutOptions: [TimeInterval] = [60, 300, 900, 1800, 3600, 0]
    private let clipboardTimeoutOptions: [TimeInterval] = [10, 30, 90, 0]

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            settingsPage {
                generalGroups
            }
            .tabItem {
                Label(L("General"), systemImage: "slider.horizontal.3")
            }
            .tag(Tab.general)

            settingsPage {
                securityGroups
            }
            .tabItem {
                Label(L("Security"), systemImage: "lock")
            }
            .tag(Tab.security)

            settingsPage {
                shortcutGroups
            }
            .tabItem {
                Label(L("Shortcuts"), systemImage: "command")
            }
            .tag(Tab.shortcuts)

            settingsPage {
                browserGroups
            }
            .tabItem {
                Label(L("Browser"), systemImage: "puzzlepiece.extension")
            }
            .tag(Tab.browser)

            settingsPage {
                autoTypeGroups
            }
            .tabItem {
                Label(L("Auto-Type"), systemImage: "keyboard")
            }
            .tag(Tab.autoType)

            settingsPage {
                sshAgentGroups
            }
            .tabItem {
                Label(L("SSH Agent"), systemImage: "terminal")
            }
            .tag(Tab.sshAgent)

            ScrollView {
                settingsPage {
                    AboutView()
                }
            }
            .frame(height: 520)
            .background(KM.unlockBackground)
            .tabItem {
                Label(L("About"), systemImage: "info.circle")
            }
            .tag(Tab.about)
        }
        .frame(width: 640)
        .tint(KM.accent)
        .onAppear {
            viewModel.refreshLaunchAtLoginState()
            browser.refreshHostStates()
            sshConfigIsSetUp = SSHConfigSetup.isSetUp()
            accessibilityGranted = AccessibilityPermission.isGranted
        }
        .onChange(of: navigation.showsAbout, initial: true) {
            if navigation.showsAbout {
                selectedTab = .about
                navigation.showsAbout = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings › Accessibility.
            accessibilityGranted = AccessibilityPermission.isGranted
        }
        .task(id: selectedTab) {
            // KeeMac may not become active again after the switch is turned on in System Settings.
            while selectedTab == .autoType, !Task.isCancelled {
                accessibilityGranted = AccessibilityPermission.isGranted
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $showsSSHImport) {
            SSHImportSheet(viewModel: viewModel)
        }
    }

    // MARK: Auto-Type

    @ViewBuilder
    private var autoTypeGroups: some View {
        settingsGroup(L("Permission")) {
            settingRow(L("Accessibility access"), subtitle: L("Read the window title and type into other apps"), isFirst: true) {
                HStack(spacing: 10) {
                    Text(accessibilityGranted ? L("Granted") : L("Not granted"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accessibilityGranted ? KM.success : KM.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(
                            Capsule().fill((accessibilityGranted ? KM.success : KM.warning).opacity(0.16))
                        )
                        .accessibilityIdentifier("settings.autoType.permission")
                    Button(L("Open System Settings…")) {
                        AccessibilityPermission.request()
                        AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                    .accessibilityIdentifier("settings.autoType.openSystemSettings")
                }
            }
        }
        Text(L("KeeMac needs Accessibility to read the window title and type into other apps."))
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, -10)

        settingsGroup(L("Typing")) {
            settingRow(L("Delay between keystrokes"), subtitle: L("Raise it when an app drops characters"), isFirst: true) {
                HStack(spacing: 6) {
                    TextField("", value: Binding(
                        get: { settings.autoTypeKeyDelay },
                        set: { settings.autoTypeKeyDelay = min(max($0, 0), 1000) }
                    ), format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 44)
                    .kmField(height: 24)
                    .accessibilityIdentifier("settings.autoType.delay")
                    Text(L("ms"))
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    Stepper("", value: Binding(
                        get: { settings.autoTypeKeyDelay },
                        set: { settings.autoTypeKeyDelay = min(max($0, 0), 1000) }
                    ), in: 0...1000, step: 5)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.autoType.delayStepper")
                }
            }
        }
        (Text(L("Default sequence: ")) + Text(defaultAutoTypeSequence).font(.system(size: 11, design: .monospaced)))
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, -10)
    }

    // MARK: Shortcuts

    @ViewBuilder
    private var shortcutGroups: some View {
        settingsGroup(L("Global shortcuts")) {
            settingRow(L("Open Quick Access"), subtitle: quickAccessSubtitle, isFirst: true) {
                HStack(spacing: 10) {
                    ShortcutRecorder(shortcut: Binding(
                        get: { settings.quickAccessShortcut },
                        set: { shortcut in
                            settings.quickAccessShortcut = shortcut
                            updateHotKeys()
                        }
                    ), onFinish: updateHotKeys)
                    .disabled(!settings.quickAccessEnabled)
                    .accessibilityIdentifier("settings.quickAccess.shortcut")
                    settingsToggle(Binding(
                        get: { settings.quickAccessEnabled },
                        set: { isOn in
                            settings.quickAccessEnabled = isOn
                            updateHotKeys()
                        }
                    ))
                    .accessibilityIdentifier("settings.quickAccess.enabled")
                }
            }
            settingRow(L("Auto-Type"), subtitle: autoTypeSubtitle) {
                HStack(spacing: 10) {
                    ShortcutRecorder(shortcut: Binding(
                        get: { settings.autoTypeShortcut },
                        set: { shortcut in
                            settings.autoTypeShortcut = shortcut
                            updateHotKeys()
                        }
                    ), label: L("Auto-Type shortcut"), onFinish: updateHotKeys)
                    .disabled(!settings.autoTypeEnabled)
                    .accessibilityIdentifier("settings.autoType.shortcut")
                    settingsToggle(Binding(
                        get: { settings.autoTypeEnabled },
                        set: { isOn in
                            settings.autoTypeEnabled = isOn
                            updateHotKeys()
                        }
                    ))
                    .accessibilityIdentifier("settings.autoType.enabled")
                }
            }
        }
        Text(L("They work in any app, also while KeeMac is in the background. Click a shortcut and press a new one."))
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, -10)
    }

    /// Both shortcuts are on and the same, so only the one registered first works.
    private var shortcutsClash: Bool {
        settings.quickAccessEnabled && settings.autoTypeEnabled
            && settings.quickAccessShortcut.keyCode == settings.autoTypeShortcut.keyCode
            && settings.quickAccessShortcut.modifierFlags == settings.autoTypeShortcut.modifierFlags
    }

    private var autoTypeSubtitle: String {
        if shortcutsClash {
            return L("Same as the Quick Access shortcut. Choose a different one")
        }
        if settings.autoTypeEnabled && autoTypeShortcutConflict {
            return L("This shortcut is used by another app. Choose a different one")
        }
        return L("Types the matching entry into the frontmost window.")
    }

    private func updateHotKeys() {
        updateQuickAccessHotKey()
        updateAutoTypeHotKey()
    }

    private func updateAutoTypeHotKey() {
        AutoTypeController.shared.updateHotKey()
        autoTypeShortcutConflict = AutoTypeController.shared.shortcutConflict
    }

    // MARK: SSH agent

    @ViewBuilder
    private var sshAgentGroups: some View {
        settingsGroup(L("SSH agent")) {
            settingRow(L("Use KeeMac as SSH agent"), subtitle: sshAgentStatus, isFirst: true) {
                settingsToggle(Binding(
                    get: { settings.sshAgentEnabled },
                    set: { isOn in
                        settings.sshAgentEnabled = isOn
                        sshAgent.applySettings()
                    }
                ))
            }
        }
        Text(L("Keys come from \(sshAgent.databaseName.isEmpty ? L("the open database") : sshAgent.databaseName) only: entries with an attached private key and “Use in SSH agent” turned on."))
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .padding(.horizontal, 4)
            .padding(.top, -10)

        settingsGroup("~/.ssh/config") {
            settingRow(
                L("Tell ssh to use KeeMac"),
                subtitle: AppVariant.isDevelopment
                    ? L("KeeMac Dev doesn't change this file. Use SSH_AUTH_SOCK=\(AppVariant.sshAgentSocketPath)")
                    : (sshConfigIsSetUp ? L("Set up") : L("Not set up")),
                isFirst: true
            ) {
                if AppVariant.isDevelopment {
                    EmptyView()
                } else if sshConfigIsSetUp {
                    Button(L("Remove")) {
                        runConfigChange { try SSHConfigSetup.remove() }
                    }
                } else {
                    Button(L("Set Up…")) {
                        runConfigChange { try SSHConfigSetup.setUp() }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showsSSHConfigLines.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showsSSHConfigLines ? 90 : 0))
                        Text(L("Lines added to the file"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(KM.textSecondary)
                }
                .buttonStyle(.plain)
                if showsSSHConfigLines {
                    HStack(alignment: .top) {
                        Text(SSHConfigSetup.lines)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(L("Copy")) {
                            SensitiveClipboard.shared.copyPlainText(SSHConfigSetup.lines, label: L("Lines"))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KM.fieldBackground))
                }
                Text(sshConfigError ?? (sshConfigIsSetUp
                    ? L("ssh asks KeeMac for keys first. Key files in ~/.ssh keep working.")
                    : L("ssh doesn’t use KeeMac yet. Set Up adds these two lines to the top of the file, or add them yourself.")))
                    .font(.system(size: 11))
                    .foregroundStyle(sshConfigError == nil ? KM.textSecondary : KM.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.horizontal, 14)
            }
        }

        settingsGroup(L("Choosing keys")) {
            settingRow(L("Pick keys by host"), subtitle: L("Offer only the keys that match the server; others when nothing matches"), isFirst: true) {
                settingsToggle(Binding(get: { settings.sshPickKeysByHost }, set: { settings.sshPickKeysByHost = $0 }))
            }
            settingRow(L("Learn hosts automatically"), subtitle: L("Remember a server the first time it accepts a key")) {
                settingsToggle(Binding(get: { settings.sshLearnHosts }, set: { settings.sshLearnHosts = $0 }))
            }
            settingRow(L("Default confirmation for new keys"), subtitle: L("Keys can override it in their entry")) {
                Menu {
                    ForEach(VaultSSHConfirmation.allCases, id: \.self) { mode in
                        Button(mode.title) { settings.sshDefaultConfirmation = mode }
                    }
                } label: {
                    menuLabel(settings.sshDefaultConfirmation.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            settingRow(L("Forwarded requests"), subtitle: L("Always ask, even for keys that don’t need confirmation")) {
                settingsToggle(Binding(get: { settings.sshAskForwarded }, set: { settings.sshAskForwarded = $0 }))
            }
        }

        settingsGroup(L("Existing keys")) {
            settingRow(L("Keys in ~/.ssh"), subtitle: L("Copies them into \(sshAgent.databaseName.isEmpty ? L("the open database") : sshAgent.databaseName) as SSH Key entries"), isFirst: true) {
                Button(L("Import Keys from ~/.ssh…")) {
                    showsSSHImport = true
                }
                .disabled(!sshAgent.isDatabaseUnlocked)
            }
        }

        if !sshAgent.recentRequests.isEmpty {
            settingsGroup(L("Recent requests")) {
                ForEach(Array(sshAgent.recentRequests.enumerated()), id: \.element.id) { index, request in
                    HStack(spacing: 10) {
                        Image(systemName: request.isAllowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(request.isAllowed ? KM.success : KM.danger)
                        Text(request.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(KM.textSecondary)
                        Text(request.app).font(.system(size: 12, design: .monospaced))
                        Text(request.host ?? L("Unknown host"))
                            .font(.system(size: 12))
                            .foregroundStyle(request.host == nil ? KM.textSecondary : KM.textPrimary)
                        Spacer()
                        Text(request.key).font(.system(size: 12))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(KM.hairline).frame(height: 0.5).padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
    }

    private var sshAgentStatus: String {
        switch sshAgent.status {
        case .off:
            return L("Off")
        case .socketInUse:
            return L("Another SSH agent already uses \(AppVariant.sshAgentSocketPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        case .failed(let message):
            return message
        case .running:
            guard sshAgent.isDatabaseUnlocked else {
                return L("Database locked — keys appear after unlocking")
            }
            return L("Running · \(sshAgent.keyCount) keys from \(sshAgent.databaseName)")
        }
    }

    private func runConfigChange(_ change: () throws -> Void) {
        do {
            try change()
            sshConfigError = nil
        } catch {
            sshConfigError = error.localizedDescription
        }
        sshConfigIsSetUp = SSHConfigSetup.isSetUp()
    }

    @ViewBuilder
    private var generalGroups: some View {
        settingsGroup(L("Startup")) {
            settingRow(L("Launch at login"), subtitle: launchAtLoginSubtitle, isFirst: true) {
                if viewModel.launchAtLoginRequiresApproval {
                    Button(L("Open Login Items")) {
                        viewModel.openLoginItemsSystemSettings()
                    }
                    .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                } else {
                    settingsToggle(Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    ))
                }
            }
            settingRow(L("Start minimized"), subtitle: L("Open without showing the main window")) {
                settingsToggle($viewModel.startMinimized)
            }
            settingRow(L("Show in Dock"), subtitle: L("When off, KeeMac stays in the menu bar only")) {
                settingsToggle(Binding(
                    get: { viewModel.showDockIcon },
                    set: { viewModel.setShowDockIcon($0) }
                ))
            }
        }

        settingsGroup(L("Entries")) {
            settingRow(L("Show entries from subgroups"), subtitle: L("Selecting a group also lists entries of its nested groups"), isFirst: true) {
                settingsToggle($viewModel.includeSubgroupEntriesInGroupView)
            }
        }

        settingsGroup(L("Password generator")) {
            settingRow(
                L("Remember last-used options"),
                subtitle: generator.rememberOptions
                    ? L("The generator opens with the options you used last")
                    : L("The generator opens with these defaults every time"),
                isFirst: true
            ) {
                settingsToggle($generator.rememberOptions)
            }
            if !generator.rememberOptions {
                settingRow(L("Default mode"), subtitle: L("Used when KeeMac starts")) {
                    KMSegmentedControl(
                        options: PasswordGeneratorOptions.Mode.allCases.map { ($0, $0.title) },
                        selection: $generator.defaultMode,
                        fontSize: 12,
                        horizontalPadding: 12
                    )
                }
                settingRow(L("Default length"), subtitle: L("Characters in a password")) {
                    Menu {
                        ForEach(PasswordGeneratorSettings.lengthChoices, id: \.self) { length in
                            Button(L("\(length) characters")) { generator.defaultLength = length }
                        }
                    } label: {
                        menuLabel(L("\(generator.defaultLength) characters"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                settingRow(L("Default number of words"), subtitle: L("Words in a passphrase")) {
                    Menu {
                        ForEach(PasswordGeneratorSettings.wordChoices, id: \.self) { words in
                            Button(L("\(words) words")) { generator.defaultWords = words }
                        }
                    } label: {
                        menuLabel(L("\(generator.defaultWords) words"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }

        settingsGroup(L("Sync")) {
            settingRow(L("When the database changes on disk"), subtitle: appliesToSubtitle, isFirst: true) {
                Menu {
                    ForEach(VaultSyncMode.allCases, id: \.self) { mode in
                        Button(mode.title) {
                            viewModel.setSyncModeForSelectedVault(mode)
                        }
                    }
                } label: {
                    menuLabel(viewModel.syncModeForSelectedVault.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(viewModel.selectedVaultURL == nil)
            }
            settingRow(L("Look for conflicting copies when unlocking"), subtitle: L("Finds copies left by Dropbox, iCloud and Syncthing")) {
                settingsToggle($viewModel.lookForConflictCopies)
            }
        }

        settingsGroup(L("Notifications")) {
            settingRow(L("Notify about expiring passwords"), subtitle: L("One notification after unlocking. It shows counts only, never entry names."), isFirst: true) {
                settingsToggle(Binding(
                    get: { viewModel.expiryNotificationsForSelectedVault },
                    set: { viewModel.expiryNotificationsForSelectedVault = $0 }
                ))
                .disabled(viewModel.selectedVaultURL == nil)
            }
            if viewModel.expiryNotificationsForSelectedVault {
                settingRow(L("Warn before"), subtitle: appliesToSubtitle) {
                    KMSegmentedControl(
                        options: AppSettingsStore.expiryWarnDayOptions.map { ($0, L("\($0) days")) },
                        selection: Binding(
                            get: { viewModel.expiryWarnDaysForSelectedVault },
                            set: { viewModel.expiryWarnDaysForSelectedVault = $0 }
                        ),
                        fontSize: 12,
                        horizontalPadding: 12
                    )
                    .disabled(viewModel.selectedVaultURL == nil)
                }
            }
            settingRow(L("Show a reminder in the window"), subtitle: L("A one-line banner above the list after unlocking")) {
                settingsToggle(Binding(
                    get: { viewModel.expiryBannerForSelectedVault },
                    set: { viewModel.expiryBannerForSelectedVault = $0 }
                ))
                .disabled(viewModel.selectedVaultURL == nil)
            }
        }

        settingsGroup(L("Appearance")) {
            settingRow(L("Layout"), subtitle: layoutSubtitle, isFirst: true) {
                KMSegmentedControl(
                    options: KMLayout.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { KMLayout(rawValue: layoutRaw) ?? .tahoe },
                        set: { layoutRaw = $0.rawValue }
                    ),
                    fontSize: 12,
                    horizontalPadding: 12,
                    identifierPrefix: "settings.layout"
                )
            }
            settingRow(L("Show entry icons"), subtitle: L("Letter tiles and custom icons in the entry list")) {
                settingsToggle($showsEntryIcons)
            }
        }
    }

    @ViewBuilder
    private var securityGroups: some View {
        settingsGroup(L("Unlock")) {
            settingRow(L("Use Touch ID to unlock"), subtitle: vaultScopedSubtitle(L("Unlock with your fingerprint after the first password unlock")), isFirst: true) {
                settingsToggle(Binding(
                    get: { viewModel.touchIDEnabledForSelectedVault },
                    set: { viewModel.setTouchIDEnabledForSelectedVault($0) }
                ))
                .disabled(viewModel.selectedVaultURL == nil)
                .accessibilityIdentifier("settings.touchID")
            }
        }

        settingsGroup(L("Automatic protection")) {
            settingRow(L("Lock database after inactivity"), subtitle: vaultScopedSubtitle(nil), isFirst: true) {
                settingsMenu(
                    title: timeoutTitle(viewModel.idleLockTimeoutForSelectedVault),
                    options: vaultLockTimeoutOptions,
                    select: viewModel.setIdleLockTimeoutForSelectedVault
                )
                .disabled(viewModel.selectedVaultURL == nil)
            }
            settingRow(L("Lock when the screen locks"), subtitle: L("Also when the screen saver starts or you switch users")) {
                settingsToggle($viewModel.lockOnScreenLock)
            }
            settingRow(L("Clear clipboard after copying"), subtitle: L("Applies to passwords, usernames and one-time codes. Also cleared when the database locks")) {
                settingsMenu(
                    title: timeoutTitle(viewModel.clipboardAutoClearTimeoutSeconds),
                    options: clipboardTimeoutOptions,
                    select: { viewModel.clipboardAutoClearTimeoutSeconds = $0 }
                )
            }
        }

        settingsGroup(L("Quick Access")) {
            settingRow(L("Keep unlocked after Quick Access"), subtitle: L("When Quick Access unlocked the database. Inactivity still locks it earlier"), isFirst: true) {
                Menu {
                    ForEach(QuickAccessUnlockDuration.allCases, id: \.self) { duration in
                        Button(duration.title) {
                            settings.quickAccessUnlockDuration = duration
                        }
                    }
                } label: {
                    menuLabel(settings.quickAccessUnlockDuration.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var quickAccessSubtitle: String {
        if settings.quickAccessEnabled && shortcutConflict {
            return L("This shortcut is used by another app. Choose a different one")
        }
        return L("Find an entry and copy from it in any app. Also in the menu bar")
    }

    private func updateQuickAccessHotKey() {
        QuickAccessController.shared.updateHotKey()
        shortcutConflict = QuickAccessController.shared.shortcutConflict
    }

    @ViewBuilder
    private var browserGroups: some View {
        settingsGroup(L("KeePassXC-Browser")) {
            settingRow(L("Fill logins in the browser"), subtitle: browserServerSubtitle, isFirst: true) {
                settingsToggle(Binding(
                    get: { browser.isEnabled },
                    set: { browser.setEnabled($0) }
                ))
            }
        }

        settingsGroup(L("Browsers")) {
            let browsers = BrowserKind.allCases.filter { browser.hostStates[$0] != .browserNotFound }
            if browsers.isEmpty {
                settingRow(L("No supported browser found"), subtitle: L("Chrome, Chromium, Brave, Edge, Vivaldi and Firefox are supported"), isFirst: true) {
                    EmptyView()
                }
            }
            ForEach(Array(browsers.enumerated()), id: \.element) { index, kind in
                settingRow(kind.title, subtitle: hostSubtitle(browser.hostStates[kind]), isFirst: index == 0) {
                    settingsToggle(Binding(
                        get: { isInstalled(browser.hostStates[kind]) },
                        set: { browser.setHost(kind, installed: $0) }
                    ))
                    .disabled(!browser.isEnabled || !browser.isProxyAvailable)
                }
            }
        }
        if let hostError = browser.hostError {
            Text(hostError)
                .font(.system(size: 11))
                .foregroundStyle(KM.danger)
                .padding(.leading, 4)
        }

        settingsGroup(L("Access")) {
            settingRow(L("Always allow access"), subtitle: L("Send matching logins without asking the first time a site requests them"), isFirst: true) {
                settingsToggle($browser.alwaysAllowAccess)
            }
            settingRow(L("Fill expired logins"), subtitle: L("Expired entries are hidden from the browser when this is off")) {
                settingsToggle($browser.allowExpired)
            }
            settingRow(L("Always allow updating logins"), subtitle: L("Save changed passwords from the browser without asking. The old password still goes to history")) {
                settingsToggle($browser.alwaysAllowUpdate)
            }
        }

        settingsGroup(L("Connected browsers")) {
            if !viewModel.loadState.isUnlocked {
                settingRow(L("Database is locked"), subtitle: L("Unlock a database to see the browsers connected to it"), isFirst: true) {
                    EmptyView()
                }
            } else if browser.associations.isEmpty {
                settingRow(L("No browsers connected"), subtitle: L("Click Connect in the KeePassXC-Browser extension"), isFirst: true) {
                    EmptyView()
                }
            } else {
                ForEach(Array(browser.associations.enumerated()), id: \.element.id) { index, association in
                    settingRow(association.id, subtitle: association.created.map { L("Connected \($0)") } ?? L("Connected"), isFirst: index == 0) {
                        Button(L("Remove")) {
                            Task { await browser.removeAssociation(association) }
                        }
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                    }
                }
            }
        }
    }

    private var browserServerSubtitle: String {
        switch browser.serverState {
        case .off:
            return L("Uses the KeePassXC-Browser extension. Turn off browser integration in KeePassXC first")
        case .running:
            return browser.isProxyAvailable ? L("Waiting for the extension") : L("keemac-proxy is missing from this build")
        case .failed(let message):
            return message
        }
    }

    private func hostSubtitle(_ state: NativeMessagingHostState?) -> String {
        switch state {
        case .installed:
            return L("Set up for KeeMac")
        case .outdated:
            return L("Set up for an older copy of KeeMac")
        case .otherProgram(let path):
            let program = path.localizedCaseInsensitiveContains("keepassxc") ? "KeePassXC" : L("another app")
            return L("Used by \(program). Turning on switches it to KeeMac")
        case .notInstalled, .browserNotFound, nil:
            return L("Not set up")
        }
    }

    private func isInstalled(_ state: NativeMessagingHostState?) -> Bool {
        state == .installed || state == .outdated
    }

    private var layoutSubtitle: String {
        switch KMLayout(rawValue: layoutRaw) ?? .tahoe {
        case .tahoe:
            return L("Floating sidebar and grouped entry cards")
        case .classic:
            return L("Flush sidebar and a form-style entry view")
        case .compact:
            return L("Dense single-line entry list")
        }
    }

    private var appliesToSubtitle: String {
        guard let url = viewModel.selectedVaultURL else {
            return L("Open a database to change this setting")
        }
        return L("Applies to \(url.lastPathComponent)")
    }

    private var launchAtLoginSubtitle: String {
        viewModel.launchAtLoginRequiresApproval
            ? L("Disabled in System Settings — allow KeeMac in Login Items")
            : L("Open KeeMac when you log in to your Mac")
    }

    private func vaultScopedSubtitle(_ base: String?) -> String {
        guard let url = viewModel.selectedVaultURL else {
            return L("Open a database to change this setting")
        }
        let scope = L("For \(url.lastPathComponent)")
        guard let base else {
            return scope
        }
        return "\(base). \(scope)"
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            content()
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(KM.unlockBackground)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                rows()
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(KM.insetFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(light: .black(0.06), dark: .white(0.06)), lineWidth: 0.5)
            )
        }
    }

    private func settingRow<Trailing: View>(
        _ title: String,
        subtitle: String,
        isFirst: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(KM.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)
            }
        }
    }

    private func settingsToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(KM.success)
    }

    private func settingsMenu(title: String, options: [TimeInterval], select: @escaping (TimeInterval) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(timeoutTitle(option)) {
                    select(option)
                }
            }
        } label: {
            menuLabel(title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(KM.textSecondary)
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(KM.raisedButtonBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(KM.softBorder, lineWidth: 0.5)
        )
    }

    private func timeoutTitle(_ timeout: TimeInterval) -> String {
        if timeout == 0 {
            return L("Never")
        }
        if timeout < 60 {
            return L("\(Int(timeout)) seconds")
        }
        if timeout < 3600 {
            let minutes = Int(timeout / 60)
            return L("\(minutes) minutes")
        }
        let hours = Int(timeout / 3600)
        return L("\(hours) hours")
    }
}

/// Click, then press the new shortcut; Escape cancels.
private struct ShortcutRecorder: View {
    @Binding var shortcut: QuickAccessShortcut
    var label: String = L("Quick Access shortcut")
    let onFinish: () -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(isRecording ? L("Type shortcut…") : shortcut.displayString)
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(isRecording ? KM.textSecondary : KM.textPrimary)
                .frame(minWidth: 84)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(KM.raisedButtonBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? KM.accent : KM.softBorder, lineWidth: isRecording ? 1 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(L("Click and press a new shortcut"))
        .accessibilityLabel(label)
        .accessibilityValue(shortcut.displayString)
        .onDisappear {
            if isRecording {
                stopRecording()
                onFinish()
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            onFinish()
            return
        }
        isRecording = true
        // While recording the current shortcuts would open Quick Access or type instead of reaching this view.
        QuickAccessController.shared.suspendHotKey()
        AutoTypeController.shared.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                onFinish()
                return nil
            }
            guard let recorded = QuickAccessShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            shortcut = recorded
            stopRecording()
            onFinish()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        QuickAccessController.shared.updateHotKey()
        AutoTypeController.shared.updateHotKey()
    }
}
