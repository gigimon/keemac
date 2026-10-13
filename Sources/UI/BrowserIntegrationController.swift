import AppKit
import BrowserIntegration
import Data
import Domain
import Foundation
import Observation

/// Runs the KeePassXC-Browser server and answers it from the open database.
@MainActor
@Observable
public final class BrowserIntegrationController: BrowserVaultProviding {
    public enum ServerState: Equatable {
        case off
        case running
        case failed(String)
    }

    public static let shared = UITesting.isActive
        ? BrowserIntegrationController(socketPath: UITesting.browserSocketPath, manifestDirectory: UITesting.manifestDirectory)
        : BrowserIntegrationController()

    public private(set) var serverState: ServerState = .off
    /// Browsers connected to the open database.
    public private(set) var associations: [VaultBrowserAssociation] = []
    public private(set) var hostStates: [BrowserKind: NativeMessagingHostState] = [:]
    public private(set) var hostError: String?

    @ObservationIgnored private weak var viewModel: AppViewModel?
    @ObservationIgnored private var server: BrowserSocketServer?
    @ObservationIgnored private var databaseHash: String?
    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let prompts: any BrowserPrompting
    @ObservationIgnored private let socketPath: String
    @ObservationIgnored private let manifestDirectory: URL
    @ObservationIgnored private let proxyURL: URL?
    @ObservationIgnored private var isShowingUnlock = false

    init(
        settings: AppSettingsStore = .shared,
        prompts: any BrowserPrompting = BrowserPromptPresenter(),
        socketPath: String = BrowserProtocol.socketPath,
        manifestDirectory: URL = NativeMessagingHosts.defaultDirectory,
        proxyURL: URL? = NativeMessagingHosts.proxyURL
    ) {
        self.settings = settings
        self.prompts = prompts
        self.socketPath = socketPath
        self.manifestDirectory = manifestDirectory
        self.proxyURL = proxyURL
    }

    public func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        lockObserver = NotificationCenter.default.addObserver(
            forName: AppCommand.vaultLockStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let unlocked = notification.userInfo?[AppCommand.vaultUnlockedUserInfoKey] as? Bool ?? false
            MainActor.assumeIsolated {
                self?.vaultLockStateChanged(unlocked: unlocked)
            }
        }
        refreshHostStates()
        if settings.browserIntegrationEnabled {
            start()
            repairMovedManifests()
        }
    }

    // MARK: - Settings

    public var isEnabled: Bool {
        settings.browserIntegrationEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        settings.browserIntegrationEnabled = enabled
        if enabled {
            start()
            repairMovedManifests()
        } else {
            stop()
        }
    }

    public var alwaysAllowAccess: Bool {
        get { settings.browserAlwaysAllowAccess }
        set { settings.browserAlwaysAllowAccess = newValue }
    }

    public var allowExpired: Bool {
        get { settings.browserAllowExpired }
        set { settings.browserAllowExpired = newValue }
    }

    public var alwaysAllowUpdate: Bool {
        get { settings.browserAlwaysAllowUpdate }
        set { settings.browserAlwaysAllowUpdate = newValue }
    }

    public var isProxyAvailable: Bool {
        guard let url = proxyURL else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func refreshHostStates() {
        var states: [BrowserKind: NativeMessagingHostState] = [:]
        for browser in BrowserKind.allCases {
            states[browser] = NativeMessagingHosts.state(for: browser, proxyURL: proxyURL, in: manifestDirectory)
        }
        hostStates = states
    }

    public func setHost(_ browser: BrowserKind, installed: Bool) {
        hostError = nil
        do {
            if installed {
                guard let proxyURL, isProxyAvailable else {
                    hostError = L("keemac-proxy is missing next to the KeeMac executable.")
                    return
                }
                try NativeMessagingHosts.install(for: browser, proxyURL: proxyURL, in: manifestDirectory)
            } else {
                try NativeMessagingHosts.uninstall(for: browser, in: manifestDirectory)
            }
        } catch {
            hostError = L("Couldn’t update \(browser.title): \(error.localizedDescription)")
        }
        refreshHostStates()
    }

    public func removeAssociation(_ association: VaultBrowserAssociation) async {
        guard let access = viewModel?.browserAccess, isVaultUnlocked else {
            return
        }
        do {
            let vault = try await access.removeBrowserAssociation(id: association.id)
            await viewModel?.applyBrowserSave(vault)
        } catch {
            SecureLogger.logUnlockFailure(error)
        }
        associations = await access.browserAssociations()
    }

    /// Closes the socket when KeeMac quits, keeping the setting.
    public func shutdown() {
        stop()
    }

    private func start() {
        guard server == nil else {
            return
        }
        let server = BrowserSocketServer(handler: BrowserMessageHandler(provider: self), path: socketPath)
        do {
            try server.start()
            self.server = server
            serverState = .running
        } catch BrowserSocketServer.StartError.alreadyInUse {
            serverState = .failed(L("Another KeeMac is already serving the browser extension."))
        } catch {
            serverState = .failed(L("Couldn’t open the browser connection socket."))
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        serverState = .off
        prompts.cancelAll()
    }

    /// Points KeeMac's manifests at the current proxy after the app was moved.
    private func repairMovedManifests() {
        guard let proxyURL, isProxyAvailable else {
            return
        }
        for browser in BrowserKind.allCases
        where NativeMessagingHosts.state(for: browser, proxyURL: proxyURL, in: manifestDirectory) == .outdated {
            try? NativeMessagingHosts.install(for: browser, proxyURL: proxyURL, in: manifestDirectory)
        }
        refreshHostStates()
    }

    private func vaultLockStateChanged(unlocked: Bool) {
        databaseHash = nil
        associations = []
        if unlocked {
            Task {
                await loadVaultData()
                server?.broadcast(BrowserMessageHandler.signal(BrowserAction.databaseUnlocked))
            }
        } else {
            prompts.cancelAll()
            server?.broadcast(BrowserMessageHandler.signal(BrowserAction.databaseLocked))
        }
    }

    private func loadVaultData() async {
        guard let access = viewModel?.browserAccess, isVaultUnlocked else {
            return
        }
        let hash = await access.browserDatabaseHash()
        let associations = await access.browserAssociations()
        guard isVaultUnlocked else {
            return
        }
        databaseHash = hash
        self.associations = associations
    }

    // MARK: - BrowserVaultProviding

    public var isVaultUnlocked: Bool {
        viewModel?.loadState.isUnlocked ?? false
    }

    public func browserDatabaseHash() async -> String? {
        if databaseHash == nil {
            await loadVaultData()
        }
        return databaseHash
    }

    public func browserAssociationKey(for id: String) async -> String? {
        if databaseHash == nil {
            await loadVaultData()
        }
        return associations.first { $0.id == id }?.key
    }

    public func associateBrowser(identificationKey: String) async -> String? {
        guard let viewModel, let access = viewModel.browserAccess, isVaultUnlocked else {
            return nil
        }
        let databaseName = viewModel.selectedVaultURL?.lastPathComponent ?? L("this database")
        let existing = Set(associations.map(\.id))
        guard let name = await prompts.askConnectionName(databaseName: databaseName, existingNames: existing),
              isVaultUnlocked else {
            return nil
        }
        let created = Date().formatted(date: .numeric, time: .shortened)
        do {
            let vault = try await access.storeBrowserAssociation(id: name, key: identificationKey, created: created)
            await viewModel.applyBrowserSave(vault)
        } catch {
            SecureLogger.logUnlockFailure(error)
            return nil
        }
        associations = await access.browserAssociations()
        return name
    }

    public func browserLogins(for query: BrowserLoginQuery) async -> [BrowserLogin] {
        guard let viewModel, let access = viewModel.browserAccess, isVaultUnlocked else {
            return []
        }
        let candidates = await access.browserCandidates()
        var match = BrowserURLMatcher.match(
            candidates,
            siteURL: query.siteURL,
            formURL: query.formURL,
            httpAuth: query.httpAuth,
            alwaysAllowAccess: settings.browserAlwaysAllowAccess,
            allowExpired: settings.browserAllowExpired
        )

        if !match.needConfirmation.isEmpty {
            let siteHost = BrowserURLMatcher.host(of: query.siteURL)
            let formHost = BrowserURLMatcher.host(of: query.formURL)
            if let answer = await prompts.askAccess(site: siteHost ?? query.siteURL, entries: match.needConfirmation),
               isVaultUnlocked {
                let selected = match.needConfirmation.filter { answer.allowed.contains($0.id) }
                if answer.remember {
                    let hosts = [siteHost, formHost == siteHost ? nil : formHost].compactMap { $0 }
                    let denied = match.needConfirmation.map(\.id).filter { !answer.allowed.contains($0) }
                    do {
                        if let vault = try await access.rememberBrowserAccess(allowed: selected.map(\.id), denied: denied, hosts: hosts) {
                            await viewModel.applyBrowserSave(vault)
                        }
                    } catch {
                        SecureLogger.logUnlockFailure(error)
                    }
                }
                match.allowed = BrowserURLMatcher.sorted(match.allowed + selected, siteURL: query.siteURL, formURL: query.formURL)
            }
        }

        guard isVaultUnlocked else {
            return []
        }
        let now = Date()
        return match.allowed.map { candidate in
            BrowserLogin(
                login: candidate.username,
                password: candidate.password,
                name: candidate.title,
                uuid: candidate.id,
                group: candidate.groupTitle,
                // Every listed login would use up an HOTP code; the extension asks with get-totp when it fills one.
                totp: candidate.otp.flatMap { $0.kind == .hotp ? nil : OTPCodeGenerator.makeCodeState(from: $0, now: now)?.code },
                isExpired: candidate.isExpired,
                skipAutoSubmit: candidate.skipAutoSubmit,
                stringFields: candidate.kphFields.map { BrowserStringField(key: $0.key, value: $0.value) }
            )
        }
    }

    /// Handing out an HOTP code to the browser uses it: the counter moves on and is saved.
    public func browserTOTP(forEntry id: UUID) async -> String? {
        guard let viewModel, case .loaded(let vault) = viewModel.loadState,
              let otp = vault.entries.first(where: { $0.id == id && !$0.isTrashed })?.otp else {
            return nil
        }
        guard otp.kind == .hotp else {
            return OTPCodeGenerator.makeCodeState(from: otp, now: Date())?.code
        }
        do {
            // The code of the counter this request used up; another request gets the next one.
            guard let used = try await viewModel.advanceHOTPCounter(entryID: id) else {
                return nil
            }
            return OTPCodeGenerator.code(secret: otp.secret, counter: used, digits: otp.digits, algorithm: otp.algorithm)
        } catch {
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    public func browserGroups() async -> VaultBrowserGroup? {
        guard let access = viewModel?.browserAccess, isVaultUnlocked else {
            return nil
        }
        return await access.browserGroupTree()
    }

    public func createBrowserGroup(path: String) async -> VaultBrowserGroup? {
        guard let viewModel, let access = viewModel.browserAccess, isVaultUnlocked else {
            return nil
        }
        let titles = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty else {
            return nil
        }
        if let existing = await access.browserGroup(atPath: titles) {
            return existing
        }
        guard await prompts.confirmNewGroup(path: titles.joined(separator: " / ")), isVaultUnlocked else {
            return nil
        }
        do {
            let result = try await access.createBrowserGroup(atPath: titles)
            await viewModel.applyBrowserSave(result.vault)
            return result.group
        } catch {
            SecureLogger.logUnlockFailure(error)
            return nil
        }
    }

    public func saveBrowserLogin(_ request: BrowserSaveRequest) async -> Bool {
        guard let viewModel, let access = viewModel.browserAccess, isVaultUnlocked else {
            return false
        }
        let siteHost = BrowserURLMatcher.host(of: request.siteURL)
        let formHost = BrowserURLMatcher.host(of: request.formURL)
        do {
            let vault: LoadedVault
            if let entryID = request.entryID, let target = await access.browserLoginTarget(for: entryID) {
                let changesUsername = !target.usernameIsReference && target.username != request.login
                let changesPassword = target.password != request.password
                guard changesUsername || changesPassword else {
                    return true
                }
                if !settings.browserAlwaysAllowUpdate {
                    guard await prompts.confirmUpdate(
                        site: siteHost ?? request.siteURL,
                        target: target,
                        newUsername: changesUsername ? request.login : nil,
                        changesPassword: changesPassword
                    ), isVaultUnlocked else {
                        return false
                    }
                }
                vault = try await access.updateBrowserLogin(id: target.id, username: request.login, password: request.password)
            } else {
                // Like KeePassXC, an update for an entry that no longer exists saves a new one.
                let added = try await access.addBrowserLogin(VaultBrowserNewLogin(
                    title: siteHost ?? request.siteURL,
                    url: request.siteURL,
                    username: request.login,
                    password: request.password,
                    groupID: request.groupID,
                    allowedHosts: [siteHost, formHost].compactMap { $0 }
                ))
                vault = added.vault
                if request.downloadFavicon {
                    downloadIcon(for: added.entryID, siteURL: request.siteURL)
                }
            }
            await viewModel.applyBrowserSave(vault)
            return true
        } catch {
            SecureLogger.logUnlockFailure(error)
            return false
        }
    }

    /// Fetches the site's icon after the reply went out; the entry keeps the default icon if anything fails.
    private func downloadIcon(for entryID: UUID, siteURL: String) {
        Task {
            guard let png = await FaviconFetcher.fetchPNG(forSiteURL: siteURL),
                  let viewModel, let access = viewModel.browserAccess, isVaultUnlocked else {
                return
            }
            do {
                if let vault = try await access.setBrowserEntryIcon(id: entryID, imageData: png) {
                    await viewModel.applyBrowserSave(vault)
                }
            } catch {
                SecureLogger.logUnlockFailure(error)
            }
        }
    }

    public func generateBrowserPassword() async -> String? {
        await prompts.generatePassword()
    }

    public func lockForBrowser() {
        viewModel?.lockVault(reason: .userInitiated)
    }

    /// A small floating unlock window (Touch ID or password); the extension retries on `database-unlocked`.
    public func showUnlockForBrowser() {
        guard let viewModel, viewModel.selectedVaultURL != nil, !isVaultUnlocked else {
            NotificationCenter.default.post(name: AppCommand.showMainWindow, object: nil)
            return
        }
        guard !isShowingUnlock else {
            return
        }
        isShowingUnlock = true
        Task {
            _ = await prompts.askUnlock(viewModel: viewModel)
            isShowingUnlock = false
        }
    }
}
