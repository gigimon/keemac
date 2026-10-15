import AppKit
import Data
import Domain
import Foundation
import Observation
import SSHAgent

/// A request shown in the panel: who asks, for which server, with which key.
struct SSHAgentPrompt: Identifiable {
    enum Kind {
        /// The key needs confirmation.
        case confirm
        /// The database is locked; unlocking allows the key until lock.
        case unlock
    }

    let id = UUID()
    let kind: Kind
    /// "ssh", "git".
    let processName: String
    /// The app it was started from: "Terminal", "Tower". Nil when not found.
    let appName: String?
    let appIcon: NSImage?
    /// Nil when the server isn't known.
    let host: String?
    /// Nil while locked (the database decides which key).
    let keyTitle: String?
    let keyFingerprint: String?
    let isForwarded: Bool
}

/// Shows a prompt and reports the answer; the floating panel in the app.
@MainActor
protocol SSHAgentPrompting: AnyObject {
    func show(_ prompt: SSHAgentPrompt, viewModel: AppViewModel, onFinish: @escaping (SSHAgentPanelResult) -> Void)
}

extension SSHAgentPanelController: SSHAgentPrompting {}

/// One answered request for Settings → SSH Agent → Recent requests.
public struct SSHAgentRecentRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let date: Date
    public let app: String
    public let host: String?
    public let key: String
    public let isAllowed: Bool
}

/// KeeMac's SSH agent: serves the main database's keys on `~/.keemac/agent.sock`.
@MainActor
@Observable
public final class SSHAgentController {
    public static let shared = UITesting.isActive
        ? SSHAgentController(socketPath: UITesting.sshAgentSocketPath, knownHostsURL: UITesting.knownHostsURL)
        : SSHAgentController(socketPath: AppVariant.sshAgentSocketPath)

    public enum Status: Equatable {
        case off
        case running
        /// Another agent or KeeMac instance already uses the socket.
        case socketInUse
        case failed(String)
    }

    public private(set) var status: Status = .off
    public private(set) var recentRequests: [SSHAgentRecentRequest] = []
    public let socketPath: String

    @ObservationIgnored private weak var viewModel: AppViewModel?
    @ObservationIgnored private var server: SSHAgentServer?
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let knownHostsURL: URL
    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    /// Decrypted keys while the database is open, by entry ID; cleared on lock.
    @ObservationIgnored private var keyCache: [UUID: (data: Data, password: String, key: SSHPrivateKey)] = [:]
    /// Keys allowed until the database locks.
    @ObservationIgnored private var allowedUntilLock: Set<UUID> = []
    /// Prompts wait in line; one panel at a time.
    @ObservationIgnored private var promptQueue: [(SSHAgentPrompt, CheckedContinuation<SSHAgentPanelResult, Never>)] = []
    @ObservationIgnored private var isShowingPrompt = false
    @ObservationIgnored private let panel: SSHAgentPrompting
    private static let lastUseKey = "keemac.sshAgent.lastUse"

    init(
        settings: AppSettingsStore = .shared,
        socketPath: String = SSHAgentServer.defaultSocketPath,
        prompter: SSHAgentPrompting? = nil,
        userDefaults: UserDefaults = .standard,
        knownHostsURL: URL = SSHKnownHosts.defaultURL
    ) {
        self.settings = settings
        self.socketPath = socketPath
        self.panel = prompter ?? SSHAgentPanelController()
        self.userDefaults = userDefaults
        self.knownHostsURL = knownHostsURL
    }

    public func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        lockObserver = NotificationCenter.default.addObserver(forName: AppCommand.vaultLockStateChanged, object: nil, queue: .main) { [weak self] notification in
            let unlocked = notification.userInfo?[AppCommand.vaultUnlockedUserInfoKey] as? Bool ?? false
            Task { @MainActor in
                if !unlocked {
                    self?.forgetKeys()
                }
            }
        }
        applySettings()
    }

    /// Starts or stops the socket after "Use KeeMac as SSH agent" changed.
    public func applySettings() {
        if settings.sshAgentEnabled {
            start()
        } else {
            stop()
        }
    }

    public func shutdown() {
        stop()
    }

    private func start() {
        guard server == nil else { return }
        let server = SSHAgentServer(backend: Backend(controller: self), path: socketPath)
        do {
            try server.start()
            self.server = server
            status = .running
        } catch SSHAgentServer.StartError.alreadyInUse {
            status = .socketInUse
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        status = .off
    }

    private func forgetKeys() {
        keyCache = [:]
        allowedUntilLock = []
    }

    // MARK: Keys

    /// Entries of the main database whose key the agent offers.
    var agentEntries: [VaultEntry] {
        guard case .loaded(let vault) = viewModel?.loadState else { return [] }
        return vault.entries.filter { !$0.isTrashed && $0.sshAgent?.isEnabled == true }
    }

    public var keyCount: Int {
        agentEntries.count
    }

    public var isDatabaseUnlocked: Bool {
        viewModel?.loadState.isUnlocked ?? false
    }

    public var databaseName: String {
        viewModel?.selectedVaultURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    private func privateKey(for entry: VaultEntry) -> SSHPrivateKey? {
        let data: Data?
        if let attachment = entry.sshKeyAttachment {
            data = attachment.data
        } else if let path = entry.sshAgent?.keyFilePath {
            data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            data = nil
        }
        guard let data else { return nil }
        let password = entry.password ?? ""
        if let cached = keyCache[entry.id], cached.data == data, cached.password == password {
            return cached.key
        }
        guard let key = try? SSHKeyReader.read(data, passphrase: password.isEmpty ? nil : password) else { return nil }
        let named = key.publicKey.comment.isEmpty ? key.withComment(entry.title) : key
        keyCache[entry.id] = (data, password, named)
        return named
    }

    private func loadedKeys() -> [(entry: VaultEntry, key: SSHPrivateKey)] {
        agentEntries.compactMap { entry in privateKey(for: entry).map { (entry, $0) } }
    }

    // MARK: Requests

    fileprivate func identities(for request: SSHAgentRequest) async -> [SSHAgentIdentity] {
        guard settings.sshAgentEnabled else { return [] }
        if viewModel?.loadState.isUnlocked != true {
            guard await askToUnlock(request) else { return [] }
        }
        var keys = loadedKeys()
        let names = destinationNames(request)
        if settings.sshPickKeysByHost, !names.isEmpty {
            // Only the keys for this server; all of them when none is set up for it.
            let matching = keys.filter { matches($0.entry, names: names) }
            if !matching.isEmpty {
                keys = matching
            }
        }
        return keys.map { SSHAgentIdentity(publicKeyBlob: $0.key.publicKey.blob, comment: $0.key.publicKey.comment) }
    }

    /// Host patterns of a key: its own list (with learned hosts) and an `ssh://host:port` URL.
    private func hostPatterns(of entry: VaultEntry) -> [String] {
        var patterns = entry.sshAgent?.hosts.map(\.pattern) ?? []
        if let url = entry.url, url.scheme?.lowercased() == "ssh", let host = url.host() {
            patterns.append(url.port.map { $0 == 22 ? host : "[\(host)]:\($0)" } ?? host)
        }
        return patterns
    }

    private func matches(_ entry: VaultEntry, names: [String]) -> Bool {
        hostPatterns(of: entry).contains { pattern in names.contains { SSHHostPattern.matches(pattern, name: $0) } }
    }

    /// The server ssh is logged in to, by the names its host key has in known_hosts. Empty when unknown or unverified.
    private func destinationNames(_ request: SSHAgentRequest) -> [String] {
        guard let binding = request.destination, binding.hasValidSignature else { return [] }
        let candidates = agentEntries.flatMap(hostPatterns).filter { !$0.contains("*") && !$0.contains("?") }
        return SSHKnownHosts.load(from: knownHostsURL).names(for: binding.hostKey, candidates: candidates)
    }

    /// A readable name for the panel: a host name rather than an address.
    private func displayName(_ names: [String]) -> String? {
        names.first { $0.contains(where: \.isLetter) } ?? names.first
    }

    fileprivate func sign(publicKeyBlob: Data, data: Data, flags: UInt32, for request: SSHAgentRequest) async -> Data? {
        if viewModel?.loadState.isUnlocked != true {
            guard await askToUnlock(request) else { return nil }
        }
        guard let (entry, key) = loadedKeys().first(where: { $0.key.publicKey.blob == publicKeyBlob }) else { return nil }
        let names = destinationNames(request)
        let host = displayName(names)
        let confirmation = entry.sshAgent?.confirmation ?? settings.sshDefaultConfirmation
        let mustAsk = (request.isForwarded && settings.sshAskForwarded)
            || confirmation == .everyTime
            || (confirmation == .oncePerUnlock && !allowedUntilLock.contains(entry.id))
        var allowed = true
        if mustAsk {
            switch await ask(prompt(for: request, kind: .confirm, entry: entry, key: key, host: host)) {
            case .allowOnce:
                allowed = true
            case .allowUntilLock:
                allowedUntilLock.insert(entry.id)
                allowed = true
            case .deny:
                allowed = false
            }
        }
        record(request, keyTitle: entry.title, host: host, allowed: allowed)
        guard allowed, let signature = try? key.sign(data, flags: flags) else { return nil }
        rememberUse(of: entry, host: host)
        // ssh asks to sign only after the server accepted the key, so the server goes on the key's list.
        if settings.sshLearnHosts, !request.isForwarded, let host, !matches(entry, names: names) {
            learn(host, for: entry)
        }
        return signature
    }

    private func learn(_ host: String, for entry: VaultEntry) {
        guard let viewModel, var settings = entry.sshAgent else { return }
        settings.hosts.append(VaultSSHHost(pattern: host, learnedAt: Date()))
        var form = VaultEntryForm(entry: entry)
        form.sshAgent = settings
        Task {
            guard (try? await viewModel.updateEntry(id: entry.id, form: form)) != nil else { return }
            CopyFeedbackCenter.shared.show(L("\(host) remembered for \(entry.title)"), style: .success, duration: 5, actionTitle: L("Undo")) { [weak self] in
                self?.forget(host, forEntryID: entry.id)
            }
        }
    }

    private func forget(_ host: String, forEntryID id: UUID) {
        guard let viewModel, case .loaded(let vault) = viewModel.loadState,
              let entry = vault.entries.first(where: { $0.id == id }), var settings = entry.sshAgent else { return }
        settings.hosts.removeAll { $0.pattern == host && $0.isLearned }
        var form = VaultEntryForm(entry: entry)
        form.sshAgent = settings
        Task {
            try? await viewModel.updateEntry(id: id, form: form)
        }
    }

    private func askToUnlock(_ request: SSHAgentRequest) async -> Bool {
        guard viewModel?.selectedVaultURL != nil else { return false }
        // While locked only plain known_hosts names are readable, hashed ones need the keys' hosts.
        let result = await ask(prompt(for: request, kind: .unlock, entry: nil, key: nil, host: displayName(destinationNames(request))))
        guard result != .deny, viewModel?.loadState.isUnlocked == true else {
            record(request, keyTitle: "—", host: nil, allowed: false)
            return false
        }
        // Unlocking from a request allows its keys until lock.
        for entry in agentEntries {
            allowedUntilLock.insert(entry.id)
        }
        return true
    }

    private func ask(_ prompt: SSHAgentPrompt) async -> SSHAgentPanelResult {
        await withCheckedContinuation { continuation in
            promptQueue.append((prompt, continuation))
            showNextPrompt()
        }
    }

    private func showNextPrompt() {
        guard !isShowingPrompt, !promptQueue.isEmpty, let viewModel else { return }
        let (prompt, continuation) = promptQueue.removeFirst()
        // A request queued behind an unlock doesn't need its own unlock any more.
        if prompt.kind == .unlock, viewModel.loadState.isUnlocked {
            continuation.resume(returning: .allowUntilLock)
            showNextPrompt()
            return
        }
        isShowingPrompt = true
        panel.show(prompt, viewModel: viewModel) { [weak self] result in
            continuation.resume(returning: result)
            self?.isShowingPrompt = false
            self?.showNextPrompt()
        }
    }

    private func prompt(for request: SSHAgentRequest, kind: SSHAgentPrompt.Kind, entry: VaultEntry?, key: SSHPrivateKey?, host: String?) -> SSHAgentPrompt {
        let app = request.client.processes.dropFirst().lazy
            .compactMap { NSRunningApplication(processIdentifier: $0.pid) }
            .first { $0.bundleIdentifier != nil && $0.activationPolicy != .prohibited }
        return SSHAgentPrompt(
            kind: kind,
            processName: request.client.name,
            appName: app?.localizedName,
            appIcon: app?.icon,
            host: host,
            keyTitle: entry?.title,
            keyFingerprint: key.map { String($0.publicKey.fingerprint.prefix(20)) + "…" },
            isForwarded: request.isForwarded
        )
    }

    private func record(_ request: SSHAgentRequest, keyTitle: String, host: String?, allowed: Bool) {
        let entry = SSHAgentRecentRequest(date: Date(), app: request.client.name, host: host, key: keyTitle, isAllowed: allowed)
        recentRequests = Array(([entry] + recentRequests).prefix(5))
    }

    // MARK: Last use

    private func rememberUse(of entry: VaultEntry, host: String?) {
        var all = userDefaults.dictionary(forKey: Self.lastUseKey) as? [String: [String: Any]] ?? [:]
        all[entry.id.uuidString] = ["date": Date().timeIntervalSince1970, "host": host ?? ""]
        userDefaults.set(all, forKey: Self.lastUseKey)
    }

    /// "Used by ssh for prod.example.com · 5 min ago".
    public func lastUse(of entryID: UUID) -> String? {
        guard let all = userDefaults.dictionary(forKey: Self.lastUseKey) as? [String: [String: Any]],
              let item = all[entryID.uuidString], let time = item["date"] as? TimeInterval else {
            return nil
        }
        let ago = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: time), relativeTo: Date())
        let host = (item["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return host.map { L("Used by ssh for \($0) · \(ago)") } ?? L("Used by ssh · \(ago)")
    }
}

/// Bridges the socket server (any thread) to the controller (main actor).
private struct Backend: SSHAgentBackend {
    let controller: SSHAgentController

    func identities(for request: SSHAgentRequest) async -> [SSHAgentIdentity] {
        await controller.identities(for: request)
    }

    func sign(publicKeyBlob: Data, data: Data, flags: UInt32, for request: SSHAgentRequest) async -> Data? {
        await controller.sign(publicKeyBlob: publicKeyBlob, data: data, flags: flags, for: request)
    }
}
