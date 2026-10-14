@testable import Data
import Darwin
import Domain
import Foundation
@testable import SSHAgent
@testable import UI
import XCTest

/// The agent answered from a real open database, through a temporary socket, with the real `ssh-add` / `ssh-keygen`
/// and a small agent client for what they can't send (`session-bind`, forwarding).
@MainActor
final class SSHAgentControllerTests: XCTestCase {
    /// Answers prompts instead of the floating panel.
    private final class Prompter: SSHAgentPrompting {
        private(set) var prompts: [SSHAgentPrompt] = []
        var answer: @MainActor (SSHAgentPrompt, AppViewModel) async -> SSHAgentPanelResult = { _, _ in .deny }
        private var pending: [(SSHAgentPrompt, AppViewModel, (SSHAgentPanelResult) -> Void)] = []

        func show(_ prompt: SSHAgentPrompt, viewModel: AppViewModel, onFinish: @escaping (SSHAgentPanelResult) -> Void) {
            prompts.append(prompt)
            pending.append((prompt, viewModel, onFinish))
            Task { @MainActor in
                await self.answerNext()
            }
        }

        private func answerNext() async {
            guard !pending.isEmpty else { return }
            let (prompt, viewModel, finish) = pending.removeFirst()
            finish(await answer(prompt, viewModel))
        }

        func reset() {
            prompts = []
        }
    }

    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettingsStore!
    private var vaultURL: URL!
    private var knownHostsURL: URL!
    private var socketPath: String!
    private var model: AppViewModel!
    private var prompter: Prompter!
    private var controller: SSHAgentController!

    override func setUp() async throws {
        // sockaddr_un paths are short: keep everything in /tmp, never ~/.keemac.
        directory = URL(fileURLWithPath: "/tmp/kmc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("agent.sock").path
        knownHostsURL = directory.appendingPathComponent("known_hosts")
        vaultURL = directory.appendingPathComponent("Keys.kdbx")
        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(fileURL: vaultURL, name: "Keys", masterPassword: "pw", keyDerivation: kdf))

        suiteName = "KeeMacSSHAgentControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: vaultURL)
        model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: vaultURL)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)

        prompter = Prompter()
        controller = SSHAgentController(settings: settings, socketPath: socketPath, prompter: prompter, userDefaults: defaults, knownHostsURL: knownHostsURL)
        controller.configure(viewModel: model)
        XCTAssertEqual(controller.status, .running)
    }

    override func tearDown() async throws {
        controller?.shutdown()
        if model?.loadState.isUnlocked == true {
            model.lockVault(reason: .quickAccess)
        }
        await model?.finishPendingLock()
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Helpers

    private var entries: [VaultEntry] {
        guard case .loaded(let vault) = model.loadState else { return [] }
        return vault.entries
    }

    @discardableResult
    private func addKey(
        _ title: String,
        kind: SSHKeyKind = .ed25519,
        comment: String? = nil,
        passphrase: String? = nil,
        password: String? = nil,
        url: String = "",
        configure: (inout VaultSSHAgentSettings) -> Void = { $0.confirmation = .never }
    ) async throws -> (entry: VaultEntry, key: SSHPrivateKey) {
        let key = try SSHPrivateKey.generate(kind, comment: comment ?? "anna@\(title)")
        var agent = VaultSSHAgentSettings(keyAttachmentName: "id_\(title)")
        configure(&agent)
        try await model.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: title,
            password: password ?? passphrase ?? "",
            url: url,
            attachments: [VaultAttachment(name: "id_\(title)", data: key.openSSHText(passphrase: passphrase))],
            entryType: .sshKey,
            sshAgent: agent
        ))
        return (try XCTUnwrap(entries.first { $0.title == title }), key)
    }

    private func entry(_ id: UUID) -> VaultEntry? {
        entries.first { $0.id == id }
    }

    /// Runs blocking work (processes, socket calls) off the main actor, which answers the agent, on a GCD
    /// thread: blocking the cooperative pool starves the agent on machines with few cores (CI runners).
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func sshAdd(_ arguments: [String] = ["-L"]) async throws -> (status: Int32, output: String) {
        let socket = socketPath!
        return try await offMain { try Self.run(["ssh-add"] + arguments, environment: ["SSH_AUTH_SOCK": socket]) }
    }

    private func listedLines() async throws -> [String] {
        let result = try await sshAdd()
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    private func connect() async throws -> AgentClient {
        let path = socketPath!
        return try await offMain { try AgentClient(path: path) }
    }

    private func identities(_ client: AgentClient) async throws -> [Data] {
        try await offMain { try client.identities() }
    }

    private func sign(_ client: AgentClient, with key: SSHPrivateKey, flags: UInt32 = 0) async throws -> Data? {
        let blob = key.publicKey.blob
        let data = Data("session \(UUID().uuidString)".utf8)
        let signature = try await offMain { try client.sign(blob, data: data, flags: flags) }
        if let signature {
            XCTAssertTrue(SSHSignatureVerifier.verify(signature: signature, of: data, with: blob), "a valid signature by \(key.publicKey.comment)")
        }
        return signature
    }

    private func bind(_ client: AgentClient, to hostKey: SSHPrivateKey, forwarding: Bool = false, forged: Bool = false) async throws {
        let ok = try await offMain { try client.bind(to: hostKey, forwarding: forwarding, forged: forged) }
        XCTAssertTrue(ok, "session-bind accepted")
    }

    private func writeKnownHosts(_ lines: [(String, SSHPrivateKey)]) throws {
        let text = lines.map { "\($0.0) \($0.1.publicKey.authorizedKeysLine)" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: knownHostsURL)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func lockAndWait() async {
        model.lockVault(reason: .userInitiated)
        await model.finishPendingLock()
        XCTAssertFalse(model.loadState.isUnlocked)
    }

    nonisolated private static func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Listing

    func testSSHAddListsEnabledKeysOfTheOpenDatabase() async throws {
        let plain = try await addKey("plain")
        let encrypted = try await addKey("encrypted", kind: .ecdsaP256, passphrase: "key secret")
        let untitled = try await addKey("No comment key", comment: "")
        try await addKey("disabled") { $0.isEnabled = false }
        try await addKey("wrong passphrase", passphrase: "right", password: "wrong")
        let trashed = try await addKey("trashed")
        try await model.deleteEntry(id: trashed.entry.id)
        XCTAssertEqual(entry(trashed.entry.id)?.isTrashed, true)
        // An ordinary login doesn't count.
        try await model.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", password: "x"))

        let listed = try await listedLines()
        XCTAssertEqual(Set(listed), [
            plain.key.publicKey.authorizedKeysLine,
            encrypted.key.publicKey.authorizedKeysLine,
            "\(untitled.key.publicKey.authorizedKeysLine) No comment key"
        ], "enabled, untrashed keys that open; a key without a comment is named after its entry")
        XCTAssertEqual(controller.keyCount, 4, "a key that doesn't open still counts as one of the database")
        XCTAssertTrue(prompter.prompts.isEmpty, "listing never asks while unlocked")
        XCTAssertEqual(controller.databaseName, "Keys")
        XCTAssertTrue(controller.isDatabaseUnlocked)
    }

    func testKeyFileOnDiskInsteadOfAnAttachment() async throws {
        let key = try SSHPrivateKey.generate(.ecdsaP256, comment: "anna@file")
        let file = directory.appendingPathComponent("id_file")
        try key.openSSHText(passphrase: "file secret").write(to: file)
        try await model.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "File key",
            password: "file secret",
            entryType: .sshKey,
            sshAgent: VaultSSHAgentSettings(keyFilePath: file.path, confirmation: .never)
        ))
        let listed = try await listedLines()
        XCTAssertEqual(listed, [key.publicKey.authorizedKeysLine])
        let client = try await connect()
        let signed = try await sign(client, with: key)
        XCTAssertNotNil(signed)

        try FileManager.default.removeItem(at: file)
        let gone = try await listedLines()
        XCTAssertEqual(gone, [], "a missing file offers nothing")
    }

    func testOutsideChangesAreRefused() async throws {
        let keyFile = directory.appendingPathComponent("outside")
        _ = try await offMain { try Self.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyFile.path]) }
        let added = try await sshAdd([keyFile.path])
        XCTAssertNotEqual(added.status, 0, added.output)
        let removedAll = try await sshAdd(["-D"])
        XCTAssertNotEqual(removedAll.status, 0, removedAll.output)
    }

    // MARK: Signing and confirmation

    func testSSHKeygenSignsThroughTheAgentAndOnceUntilLockAsksOnce() async throws {
        settings.sshDefaultConfirmation = .oncePerUnlock
        let deploy = try await addKey("deploy", passphrase: "secret") { $0.confirmation = nil }
        prompter.answer = { _, _ in .allowUntilLock }

        let publicFile = directory.appendingPathComponent("deploy.pub")
        try Data((deploy.key.publicKey.authorizedKeysLine + "\n").utf8).write(to: publicFile)
        let message = directory.appendingPathComponent("message.txt")
        try Data("signed through KeeMac".utf8).write(to: message)
        let socket = socketPath!
        for _ in 0..<2 {
            try? FileManager.default.removeItem(at: message.appendingPathExtension("sig"))
            let signed = try await offMain {
                try Self.run(["ssh-keygen", "-Y", "sign", "-n", "file", "-f", publicFile.path, message.path], environment: ["SSH_AUTH_SOCK": socket])
            }
            XCTAssertEqual(signed.status, 0, signed.output)
        }
        let allowed = directory.appendingPathComponent("allowed")
        try Data("anna \(deploy.key.publicKey.authorizedKeysLine)\n".utf8).write(to: allowed)
        let verified = try await offMain {
            try Self.run(["sh", "-c", "ssh-keygen -Y verify -f '\(allowed.path)' -I anna -n file -s '\(message.path).sig' < '\(message.path)'"])
        }
        XCTAssertTrue(verified.output.contains("Good"), verified.output)

        XCTAssertEqual(prompter.prompts.count, 1, "once per unlock: asked the first time only")
        let prompt = try XCTUnwrap(prompter.prompts.first)
        XCTAssertEqual(prompt.kind, .confirm)
        XCTAssertEqual(prompt.keyTitle, "deploy")
        XCTAssertEqual(prompt.processName, "ssh-keygen")
        XCTAssertNil(prompt.host)
        XCTAssertFalse(prompt.isForwarded)
        XCTAssertTrue(deploy.key.publicKey.fingerprint.hasPrefix(String(try XCTUnwrap(prompt.keyFingerprint).dropLast())))

        XCTAssertEqual(controller.recentRequests.count, 2)
        XCTAssertTrue(controller.recentRequests.allSatisfy { $0.isAllowed && $0.key == "deploy" && $0.app == "ssh-keygen" })

        // Last use goes to the injected defaults, not the app's.
        XCTAssertNotNil(controller.lastUse(of: deploy.entry.id))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "keemac.sshAgent.lastUse")?[deploy.entry.id.uuidString])
        XCTAssertNil(controller.lastUse(of: UUID()))
    }

    func testEveryTimeConfirmationAllowsOnceOrDenies() async throws {
        let key = try await addKey("prod") { $0.confirmation = .everyTime }
        let client = try await connect()

        prompter.answer = { _, _ in .deny }
        let denied = try await sign(client, with: key.key)
        XCTAssertNil(denied, "denied")
        XCTAssertNil(controller.lastUse(of: key.entry.id), "a denied request isn't a use")

        prompter.answer = { _, _ in .allowOnce }
        let first = try await sign(client, with: key.key)
        XCTAssertNotNil(first)
        prompter.answer = { _, _ in .allowUntilLock }
        let second = try await sign(client, with: key.key)
        XCTAssertNotNil(second)
        prompter.answer = { _, _ in .deny }
        let third = try await sign(client, with: key.key)
        XCTAssertNil(third, "every time means every time, even after Allow Until Lock")

        XCTAssertEqual(prompter.prompts.count, 4)
        XCTAssertEqual(controller.recentRequests.map(\.isAllowed), [false, true, true, false], "newest first")
        XCTAssertNotNil(controller.lastUse(of: key.entry.id))
    }

    func testNeverConfirmationSignsEveryKeyTypeWithoutAsking() async throws {
        let client = try await connect()
        for kind in SSHKeyKind.allCases {
            let key = try await addKey("key-\(kind.rawValue)", kind: kind)
            let flags: [UInt32] = kind == .rsa4096 ? [0, SSHPrivateKey.rsaSHA256, SSHPrivateKey.rsaSHA512] : [0]
            for flag in flags {
                let signature = try await sign(client, with: key.key, flags: flag)
                XCTAssertNotNil(signature, "\(kind) flags \(flag)")
            }
        }
        XCTAssertTrue(prompter.prompts.isEmpty)

        let unknown = try SSHPrivateKey.generate(.ed25519, comment: "not in the database")
        let refused = try await sign(client, with: unknown)
        XCTAssertNil(refused, "a key the database doesn't have")
    }

    func testDisabledAndTrashedKeysDontSign() async throws {
        let client = try await connect()
        let disabled = try await addKey("disabled") { $0.isEnabled = false }
        let trashed = try await addKey("trashed")
        try await model.deleteEntry(id: trashed.entry.id)
        let signedDisabled = try await sign(client, with: disabled.key)
        let signedTrashed = try await sign(client, with: trashed.key)
        XCTAssertNil(signedDisabled)
        XCTAssertNil(signedTrashed)
    }

    // MARK: Locked database

    func testLockedDatabaseAsksToUnlockAndCancelAnswersNothing() async throws {
        try await addKey("deploy")
        await lockAndWait()

        prompter.answer = { _, _ in .deny }
        let denied = try await sshAdd()
        XCTAssertNotEqual(denied.status, 0, "no identities: \(denied.output)")
        XCTAssertEqual(prompter.prompts.map(\.kind), [.unlock])
        XCTAssertNil(prompter.prompts.first?.keyTitle, "while locked the key isn't known")
        XCTAssertEqual(controller.recentRequests.first?.isAllowed, false)
        XCTAssertFalse(model.loadState.isUnlocked)

        // "Unlock" without the database opening (wrong password, closed panel) still answers nothing.
        prompter.reset()
        prompter.answer = { _, _ in .allowUntilLock }
        let notOpened = try await sshAdd()
        XCTAssertNotEqual(notOpened.status, 0)
        XCTAssertEqual(prompter.prompts.count, 1)

        XCTAssertEqual(controller.keyCount, 0)
        XCTAssertFalse(controller.isDatabaseUnlocked)
    }

    func testUnlockFromARequestAllowsItsKeysUntilLock() async throws {
        settings.sshDefaultConfirmation = .oncePerUnlock
        let deploy = try await addKey("deploy", passphrase: "secret") { $0.confirmation = nil }
        let every = try await addKey("every") { $0.confirmation = .everyTime }
        await lockAndWait()

        prompter.answer = { prompt, viewModel in
            if prompt.kind == .unlock {
                await viewModel.unlock(masterPassword: "pw")
            }
            return .allowUntilLock
        }
        let listed = try await listedLines()
        XCTAssertEqual(Set(listed), [deploy.key.publicKey.authorizedKeysLine, every.key.publicKey.authorizedKeysLine])
        XCTAssertTrue(model.loadState.isUnlocked)
        XCTAssertEqual(prompter.prompts.map(\.kind), [.unlock])

        let client = try await connect()
        let signed = try await sign(client, with: deploy.key)
        XCTAssertNotNil(signed)
        XCTAssertEqual(prompter.prompts.map(\.kind), [.unlock], "once per unlock: unlocking from the request was the confirmation")
        let signedEvery = try await sign(client, with: every.key)
        XCTAssertNotNil(signedEvery)
        XCTAssertEqual(prompter.prompts.map(\.kind), [.unlock, .confirm], "every time still asks")
    }

    func testSigningWhileLockedUnlocksFirst() async throws {
        let deploy = try await addKey("deploy")
        let client = try await connect()
        await lockAndWait()

        prompter.answer = { _, _ in .deny }
        let refused = try await sign(client, with: deploy.key)
        XCTAssertNil(refused)

        prompter.answer = { prompt, viewModel in
            await viewModel.unlock(masterPassword: "pw")
            return .allowUntilLock
        }
        let signed = try await sign(client, with: deploy.key)
        XCTAssertNotNil(signed)
        XCTAssertEqual(prompter.prompts.map(\.kind), [.unlock, .unlock])
    }

    func testRequestsWaitingBehindAnUnlockDontAskAgain() async throws {
        let deploy = try await addKey("deploy")
        await lockAndWait()
        prompter.answer = { prompt, viewModel in
            // Long enough for the other requests to queue up behind this panel.
            try? await Task.sleep(for: .milliseconds(300))
            await viewModel.unlock(masterPassword: "pw")
            return .allowUntilLock
        }
        let socket = socketPath!
        let requests = (0..<3).map { _ in
            Task { try await offMain { try Self.run(["ssh-add", "-L"], environment: ["SSH_AUTH_SOCK": socket]) } }
        }
        var results: [String] = []
        for request in requests {
            results.append(try await request.value.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(results, Array(repeating: deploy.key.publicKey.authorizedKeysLine, count: 3))
        XCTAssertEqual(prompter.prompts.count, 1, "one unlock panel for all of them")
    }

    func testLockForgetsAllowedKeys() async throws {
        settings.sshDefaultConfirmation = .oncePerUnlock
        let deploy = try await addKey("deploy") { $0.confirmation = nil }
        prompter.answer = { _, _ in .allowUntilLock }
        var client = try await connect()
        let first = try await sign(client, with: deploy.key)
        let second = try await sign(client, with: deploy.key)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(prompter.prompts.count, 1)

        await lockAndWait()
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)
        client = try await connect()
        prompter.answer = { _, _ in .deny }
        let afterLock = try await sign(client, with: deploy.key)
        XCTAssertNil(afterLock, "asked again after lock, and denied")
        XCTAssertEqual(prompter.prompts.count, 2)
    }

    // MARK: Forwarding

    func testForwardedRequestsAsk() async throws {
        let deploy = try await addKey("deploy")
        let jump = try SSHPrivateKey.generate(.ed25519, comment: "")
        try writeKnownHosts([("jump.example.com", jump)])
        let client = try await connect()
        try await bind(client, to: jump, forwarding: true)

        prompter.answer = { _, _ in .deny }
        let denied = try await sign(client, with: deploy.key)
        XCTAssertNil(denied, "forwarded requests ask even when the key never does")
        let prompt = try XCTUnwrap(prompter.prompts.first)
        XCTAssertTrue(prompt.isForwarded)
        XCTAssertEqual(prompt.kind, .confirm)
        XCTAssertEqual(prompt.host, "jump.example.com")

        prompter.answer = { _, _ in .allowOnce }
        let allowed = try await sign(client, with: deploy.key)
        XCTAssertNotNil(allowed)
        XCTAssertEqual(entry(deploy.entry.id)?.sshAgent?.hosts, [], "forwarded requests don't teach hosts")

        settings.sshAskForwarded = false
        prompter.reset()
        let unasked = try await sign(client, with: deploy.key)
        XCTAssertNotNil(unasked)
        XCTAssertTrue(prompter.prompts.isEmpty, "the setting turns it off")
    }

    // MARK: Picking by host

    func testPicksKeysByTheServersHostKey() async throws {
        let prodHost = try SSHPrivateKey.generate(.ed25519, comment: "")
        let gitHost = try SSHPrivateKey.generate(.ecdsaP256, comment: "")
        let otherHost = try SSHPrivateKey.generate(.ed25519, comment: "")
        try writeKnownHosts([("prod.example.com,10.0.0.5", prodHost), ("[git.example.com]:2222", gitHost), ("other.example.com", otherHost)])
        let prod = try await addKey("prod") { $0.confirmation = .never; $0.hosts = [VaultSSHHost(pattern: "*.example.com")] }
        let prod2 = try await addKey("prod second account") { $0.confirmation = .never; $0.hosts = [VaultSSHHost(pattern: "prod.example.com")] }
        let git = try await addKey("git", url: "ssh://git.example.com:2222")
        let plain = try await addKey("plain")
        let all = Set([prod, prod2, git, plain].map(\.key.publicKey.blob))

        var client = try await connect()
        let unbound = try await identities(client)
        XCTAssertEqual(Set(unbound), all, "no session-bind: every key")

        try await bind(client, to: prodHost)
        let forProd = try await identities(client)
        XCTAssertEqual(Set(forProd), [prod.key.publicKey.blob, prod2.key.publicKey.blob], "both accounts of prod, by name and glob")

        client = try await connect()
        try await bind(client, to: gitHost)
        let forGit = try await identities(client)
        XCTAssertEqual(forGit, [git.key.publicKey.blob], "ssh:// URL with a port")

        client = try await connect()
        try await bind(client, to: try SSHPrivateKey.generate(.ed25519, comment: ""))
        let unknown = try await identities(client)
        XCTAssertEqual(Set(unknown), all, "a server not in known_hosts: every key")

        client = try await connect()
        try await bind(client, to: prodHost, forged: true)
        let forged = try await identities(client)
        XCTAssertEqual(Set(forged), all, "a binding without a valid host signature isn't trusted")

        // Hashed known_hosts: names come from the keys' own hosts.
        let knownHosts = knownHostsURL!
        _ = try await offMain { try Self.run(["ssh-keygen", "-H", "-f", knownHosts.path]) }
        XCTAssertFalse(try String(contentsOf: knownHostsURL, encoding: .utf8).contains("prod.example.com"))
        client = try await connect()
        try await bind(client, to: prodHost)
        let hashedProd = try await identities(client)
        XCTAssertEqual(Set(hashedProd), [prod.key.publicKey.blob, prod2.key.publicKey.blob], "hashed lines checked against prod.example.com")
        client = try await connect()
        try await bind(client, to: gitHost)
        let hashedGit = try await identities(client)
        XCTAssertEqual(hashedGit, [git.key.publicKey.blob])

        settings.sshPickKeysByHost = false
        client = try await connect()
        try await bind(client, to: prodHost)
        let unpicked = try await identities(client)
        XCTAssertEqual(Set(unpicked), all, "picking turned off")
    }

    func testLearnsTheHostOfAnAcceptedKeyAndUndoForgetsIt() async throws {
        let newHost = try SSHPrivateKey.generate(.ed25519, comment: "")
        try writeKnownHosts([("10.0.0.7,new.example.com", newHost)])
        let deploy = try await addKey("deploy")
        let other = try await addKey("other")

        var client = try await connect()
        try await bind(client, to: newHost)
        let offered = try await identities(client)
        XCTAssertEqual(Set(offered), [deploy.key.publicKey.blob, other.key.publicKey.blob], "nothing set up for it yet")
        let signed = try await sign(client, with: deploy.key)
        XCTAssertNotNil(signed)

        try await waitUntil("the host is learned") { entry(deploy.entry.id)?.sshAgent?.hosts.isEmpty == false }
        let learned = try XCTUnwrap(entry(deploy.entry.id)?.sshAgent?.hosts.first)
        XCTAssertEqual(learned.pattern, "new.example.com", "the readable name, not the address")
        XCTAssertTrue(learned.isLearned)
        XCTAssertEqual(entry(other.entry.id)?.sshAgent?.hosts, [])
        XCTAssertEqual(controller.recentRequests.first?.host, "new.example.com")
        XCTAssertTrue(try XCTUnwrap(controller.lastUse(of: deploy.entry.id)).contains("new.example.com"))

        let reopened = try await KeePassKitVaultLoader().loadVault(from: vaultURL, masterPassword: "pw", keyFileURL: nil)
        XCTAssertEqual(reopened.entries.first { $0.id == deploy.entry.id }?.sshAgent?.hosts.map(\.pattern), ["new.example.com"], "saved in the file")

        // Next time only that key is offered, and signing again learns nothing new.
        client = try await connect()
        try await bind(client, to: newHost)
        let picked = try await identities(client)
        XCTAssertEqual(picked, [deploy.key.publicKey.blob])
        let again = try await sign(client, with: deploy.key)
        XCTAssertNotNil(again)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(entry(deploy.entry.id)?.sshAgent?.hosts.count, 1)

        // The toast's Undo takes it back.
        try await waitUntil("the toast") { CopyFeedbackCenter.shared.current?.actionTitle != nil }
        XCTAssertTrue(try XCTUnwrap(CopyFeedbackCenter.shared.currentMessage).contains("new.example.com"))
        CopyFeedbackCenter.shared.runAction()
        try await waitUntil("the host is forgotten") { entry(deploy.entry.id)?.sshAgent?.hosts.isEmpty == true }
    }

    func testLearningCanBeTurnedOff() async throws {
        settings.sshLearnHosts = false
        let newHost = try SSHPrivateKey.generate(.ed25519, comment: "")
        try writeKnownHosts([("new.example.com", newHost)])
        let deploy = try await addKey("deploy")
        let client = try await connect()
        try await bind(client, to: newHost)
        let signed = try await sign(client, with: deploy.key)
        XCTAssertNotNil(signed)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(entry(deploy.entry.id)?.sshAgent?.hosts, [])
    }

    // MARK: Settings

    func testApplySettingsStartsAndStopsTheSocket() async throws {
        let deploy = try await addKey("deploy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        settings.sshAgentEnabled = false
        controller.applySettings()
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "the socket is removed")
        let off = try await sshAdd()
        XCTAssertNotEqual(off.status, 0, off.output)

        settings.sshAgentEnabled = true
        controller.applySettings()
        controller.applySettings()
        XCTAssertEqual(controller.status, .running)
        let listed = try await listedLines()
        XCTAssertEqual(listed, [deploy.key.publicKey.authorizedKeysLine])

        // Another agent on the same socket.
        let second = SSHAgentController(settings: settings, socketPath: socketPath, prompter: Prompter(), userDefaults: defaults, knownHostsURL: knownHostsURL)
        second.applySettings()
        XCTAssertEqual(second.status, .socketInUse)
        second.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the one that couldn't start leaves the socket alone")

        controller.shutdown()
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testTooLongSocketPathFails() {
        let long = "/tmp/" + String(repeating: "k", count: 120) + "/agent.sock"
        let agent = SSHAgentController(settings: settings, socketPath: long, prompter: Prompter(), userDefaults: defaults, knownHostsURL: knownHostsURL)
        agent.applySettings()
        if case .failed = agent.status {} else {
            XCTFail("expected a failure, got \(agent.status)")
        }
        agent.shutdown()
        try? FileManager.default.removeItem(atPath: (long as NSString).deletingLastPathComponent)
    }
}

/// A minimal agent client: one connection, so `session-bind` applies to the requests after it.
private final class AgentClient: @unchecked Sendable {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = SSHAgentServer.address(for: path) else {
            throw POSIXError(.EINVAL)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Never hang a test on a reply that doesn't come.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close(descriptor)
    }

    func call(_ message: Data) throws -> Data {
        var frame = SSHWriter()
        frame.string(message)
        try frame.data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw POSIXError(.EPIPE) }
                offset += written
            }
        }
        let header = try read(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        return try read(length)
    }

    private func read(_ count: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while result.count < count {
            let got = Darwin.read(descriptor, &buffer, count - result.count)
            guard got > 0 else { throw POSIXError(.ETIMEDOUT) }
            result.append(contentsOf: buffer[0..<got])
        }
        return result
    }

    func identities() throws -> [Data] {
        var reader = SSHReader(try call(Data([SSHAgentProtocol.requestIdentities])))
        guard try reader.byte() == SSHAgentProtocol.identitiesAnswer else { throw POSIXError(.EBADMSG) }
        return try (0..<reader.uint32()).map { _ in
            let blob = try reader.string()
            _ = try reader.string()
            return blob
        }
    }

    func sign(_ blob: Data, data: Data, flags: UInt32) throws -> Data? {
        var writer = SSHWriter()
        writer.byte(SSHAgentProtocol.signRequest)
        writer.string(blob)
        writer.string(data)
        writer.uint32(flags)
        var reader = SSHReader(try call(writer.data))
        guard try reader.byte() == SSHAgentProtocol.signResponse else { return nil }
        return try reader.string()
    }

    /// `session-bind@openssh.com` as ssh sends it after key exchange; `forged` signs with another key.
    func bind(to hostKey: SSHPrivateKey, forwarding: Bool, forged: Bool) throws -> Bool {
        let sessionID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let signer = forged ? try SSHPrivateKey.generate(.ed25519, comment: "") : hostKey
        var writer = SSHWriter()
        writer.byte(SSHAgentProtocol.extensionRequest)
        writer.string("session-bind@openssh.com")
        writer.string(hostKey.publicKey.blob)
        writer.string(sessionID)
        writer.string(try signer.sign(sessionID))
        writer.byte(forwarding ? 1 : 0)
        return try call(writer.data) == Data([SSHAgentProtocol.success])
    }
}
