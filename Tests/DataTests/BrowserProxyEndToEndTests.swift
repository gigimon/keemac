import BrowserIntegration
@testable import Data
import Darwin
import Domain
import Foundation
@testable import UI
import XCTest

@MainActor
private final class AnsweringPrompts: BrowserPrompting {
    var connectionName: String? = "chrome-e2e"
    private(set) var accessRequests = 0
    private(set) var updateRequests = 0
    private(set) var groupRequests = 0
    private(set) var unlockRequests = 0

    func askConnectionName(databaseName: String, existingNames: Set<String>) async -> String? { connectionName }

    func askAccess(site: String, entries: [VaultBrowserCandidate]) async -> BrowserAccessAnswer? {
        accessRequests += 1
        return BrowserAccessAnswer(allowed: Set(entries.map(\.id)), remember: true)
    }

    func confirmUpdate(site: String, target: VaultBrowserLoginTarget, newUsername: String?, changesPassword: Bool) async -> Bool {
        updateRequests += 1
        return true
    }

    func confirmNewGroup(path: String) async -> Bool {
        groupRequests += 1
        return true
    }

    func askUnlock(viewModel: AppViewModel) async -> Bool {
        unlockRequests += 1
        return false
    }

    func generatePassword() async -> String? { nil }

    func cancelAll() {}
}

/// Collects `length + JSON` frames read from a descriptor on its own thread.
private final class FrameReader: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var isClosed = false
    private var waiter: (token: Int, continuation: CheckedContinuation<Data?, Never>)?
    private var nextToken = 0

    init(descriptor: Int32) {
        Thread { [self] in readLoop(descriptor) }.start()
    }

    /// The next frame as JSON, nil on timeout or end of stream.
    func next(timeout: Duration = .seconds(10)) async -> [String: Any]? {
        let data: Data? = await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if !frames.isEmpty {
                continuation.resume(returning: frames.removeFirst())
                return
            }
            if isClosed {
                continuation.resume(returning: nil)
                return
            }
            nextToken += 1
            let token = nextToken
            waiter = (token, continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if let waiter, waiter.token == token {
                    self.waiter = nil
                    waiter.continuation.resume(returning: nil)
                }
            }
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func readLoop(_ descriptor: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            while buffer.count >= 4 {
                let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard buffer.count >= 4 + length else {
                    break
                }
                deliver(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
        }
        lock.lock()
        isClosed = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }

    private func deliver(_ frame: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: frame)
        } else {
            frames.append(frame)
            lock.unlock()
        }
    }
}

/// Runs the built `keemac-proxy` and talks to it like KeePassXC-Browser: native messaging frames, NaCl boxes.
@MainActor
private final class ProxyBrowser {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let reader: FrameReader
    let sessionKeys = NaClKeyPair.generate()
    let identificationKey: String
    let clientID = NaClBox.randomBytes(24).base64EncodedString()
    private(set) var serverKey: Data?

    static var proxyURL: URL {
        Bundle(for: BrowserProxyEndToEndTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("keemac-proxy")
    }

    init(socketPath: String, identificationKey: String = NaClKeyPair.generate().publicKey.base64EncodedString()) throws {
        self.identificationKey = identificationKey
        process.executableURL = Self.proxyURL
        process.arguments = ["chrome-extension://oboonakemofpalcgghocfoadofidjkkk/"]
        var environment = ProcessInfo.processInfo.environment
        environment["KEEMAC_BROWSER_SOCKET"] = socketPath
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        reader = FrameReader(descriptor: output.fileHandleForReading.fileDescriptor)
        try process.run()
    }

    func closeInput() throws {
        try input.fileHandleForWriting.close()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    var errorOutput: String {
        String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func nextFrame() async -> [String: Any]? {
        await reader.next()
    }

    func send(_ request: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: request)
        var length = UInt32(body.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try input.fileHandleForWriting.write(contentsOf: frame)
        let reply = await reader.next()
        return try XCTUnwrap(reply, "no reply to \(request["action"] ?? "")")
    }

    func changePublicKeys() async throws -> [String: Any] {
        let nonce = NaClBox.randomBytes(NaClBox.nonceBytes)
        let reply = try await send([
            "action": "change-public-keys",
            "publicKey": sessionKeys.publicKey.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "clientID": clientID
        ])
        XCTAssertEqual(reply["nonce"] as? String, NaClBox.increment(nonce).base64EncodedString())
        serverKey = (reply["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }
        return reply
    }

    /// Sends an encrypted request; returns the decrypted reply or the plain error reply.
    func call(_ action: String, _ payload: [String: Any] = [:], extra: [String: Any] = [:]) async throws -> [String: Any] {
        let serverKey = try XCTUnwrap(serverKey)
        let nonce = NaClBox.randomBytes(NaClBox.nonceBytes)
        var message = payload
        message["action"] = action
        let box = try XCTUnwrap(NaClBox.seal(try JSONSerialization.data(withJSONObject: message), nonce: nonce, publicKey: serverKey, secretKey: sessionKeys.secretKey))
        var request: [String: Any] = [
            "action": action,
            "message": box.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "clientID": clientID
        ]
        request.merge(extra) { _, new in new }
        let reply = try await send(request)
        return try decrypt(reply, requestNonce: nonce)
    }

    func decrypt(_ reply: [String: Any], requestNonce: Data? = nil) throws -> [String: Any] {
        guard let encrypted = reply["message"] as? String else {
            return reply
        }
        let serverKey = try XCTUnwrap(serverKey)
        let replyNonce = try XCTUnwrap((reply["nonce"] as? String).flatMap { Data(base64Encoded: $0) })
        if let requestNonce {
            XCTAssertEqual(replyNonce, NaClBox.increment(requestNonce))
        }
        let box = try XCTUnwrap(Data(base64Encoded: encrypted))
        let plain = try XCTUnwrap(NaClBox.open(box, nonce: replyNonce, publicKey: serverKey, secretKey: sessionKeys.secretKey))
        var decrypted = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(decrypted["success"] as? String, "true")
        XCTAssertEqual(decrypted["version"] as? String, BrowserProtocol.compatibleVersion)
        XCTAssertEqual(decrypted["nonce"] as? String, replyNonce.base64EncodedString())
        decrypted["action"] = reply["action"]
        return decrypted
    }

    var keys: [[String: String]] {
        [["id": "chrome-e2e", "key": identificationKey]]
    }

    func associate() async throws -> [String: Any] {
        try await call("associate", ["key": sessionKeys.publicKey.base64EncodedString(), "idKey": identificationKey])
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
final class BrowserProxyEndToEndTests: XCTestCase {
    private let password = "pw"
    private var directory: URL!
    private var url: URL!
    private var socketPath: String!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var model: AppViewModel!
    private var loader: KeePassKitVaultLoader!
    private var prompts: AnsweringPrompts!
    private var controller: BrowserIntegrationController!
    private var proxies: [ProxyBrowser] = []
    private var mailID: UUID!

    override func setUp() async throws {
        guard FileManager.default.isExecutableFile(atPath: ProxyBrowser.proxyURL.path) else {
            XCTFail("keemac-proxy isn't built next to the tests; DataTests depends on the Proxy target")
            throw CocoaError(.fileNoSuchFile)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Proxy.kdbx")
        socketPath = FileManager.default.temporaryDirectory.appendingPathComponent("kme-\(UUID().uuidString.prefix(8)).sock").path
        XCTAssertNotEqual(socketPath, BrowserProtocol.socketPath)

        let kdf = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let creator = KeePassKitVaultLoader()
        _ = try await creator.createVault(options: VaultCreationOptions(fileURL: url, name: "Proxy", masterPassword: password, keyDerivation: kdf))
        let vault = try await creator.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Mail", username: "anna", password: "secret", url: "https://mail.example.com"))
        mailID = try XCTUnwrap(vault.entries.first { $0.title == "Mail" }?.id)

        suiteName = "KeeMacBrowserProxyTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        settings.setExpiryNotificationsEnabled(false, for: url)
        loader = KeePassKitVaultLoader()
        model = AppViewModel(vaultLoader: loader, settingsStore: settings, userDefaults: defaults)
        prompts = AnsweringPrompts()
        controller = BrowserIntegrationController(
            settings: settings,
            prompts: prompts,
            socketPath: socketPath,
            manifestDirectory: directory.appendingPathComponent("Application Support"),
            proxyURL: nil
        )
        controller.configure(viewModel: model)
        model.selectVault(url: url)
        await model.unlock(masterPassword: password)
        XCTAssertTrue(model.loadState.isUnlocked)
        controller.setEnabled(true)
        XCTAssertEqual(controller.serverState, .running)
    }

    override func tearDown() async throws {
        proxies.forEach { $0.stop() }
        proxies = []
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
        if let socketPath {
            unlink(socketPath)
        }
    }

    private func startProxy(identificationKey: String? = nil) throws -> ProxyBrowser {
        let proxy = if let identificationKey {
            try ProxyBrowser(socketPath: socketPath, identificationKey: identificationKey)
        } else {
            try ProxyBrowser(socketPath: socketPath)
        }
        proxies.append(proxy)
        return proxy
    }

    private func reopen() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: url, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    func testBrowserSessionThroughProxy() async throws {
        let browser = try startProxy()

        let keys = try await browser.changePublicKeys()
        XCTAssertEqual(keys["action"] as? String, "change-public-keys")
        XCTAssertEqual(keys["success"] as? String, "true")
        XCTAssertEqual(keys["version"] as? String, BrowserProtocol.compatibleVersion)
        XCTAssertNotNil(browser.serverKey)

        let expectedHash = await loader.browserDatabaseHash()
        let hash = try await browser.call("get-databasehash")
        XCTAssertEqual(hash["hash"] as? String, expectedHash)

        let early = try await browser.call("get-logins", ["url": "https://mail.example.com/login", "keys": browser.keys])
        XCTAssertEqual(early["errorCode"] as? String, "8", "logins need an association first")

        let associated = try await browser.associate()
        XCTAssertEqual(associated["id"] as? String, "chrome-e2e")
        XCTAssertEqual(associated["hash"] as? String, expectedHash)
        let stored = try await reopen().0.browserAssociations()
        XCTAssertEqual(stored.map(\.id), ["chrome-e2e"])
        XCTAssertEqual(stored.first?.key, browser.identificationKey)

        let tested = try await browser.call("test-associate", ["id": "chrome-e2e", "key": browser.identificationKey])
        XCTAssertEqual(tested["id"] as? String, "chrome-e2e")
        let wrongKey = try await browser.call("test-associate", ["id": "chrome-e2e", "key": "nope"])
        XCTAssertEqual(wrongKey["errorCode"] as? String, "8")

        let logins = try await browser.call("get-logins", [
            "url": "https://mail.example.com/login",
            "submitUrl": "https://mail.example.com/session",
            "keys": browser.keys
        ])
        XCTAssertEqual(logins["count"] as? Int, 1)
        let entry = try XCTUnwrap((logins["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["login"] as? String, "anna")
        XCTAssertEqual(entry["password"] as? String, "secret")
        XCTAssertEqual(entry["name"] as? String, "Mail")
        XCTAssertEqual(entry["uuid"] as? String, mailID.browserHex)
        XCTAssertEqual(prompts.accessRequests, 1)

        let noMatch = try await browser.call("get-logins", ["url": "https://nothing.test/", "keys": browser.keys])
        XCTAssertEqual(noMatch["errorCode"] as? String, "15")

        let created = try await browser.call("set-login", [
            "url": "https://new.example.com/login", "submitUrl": "https://new.example.com/post",
            "login": "neo", "password": "red-pill", "id": "chrome-e2e"
        ])
        XCTAssertEqual(created["error"] as? String, "success")
        XCTAssertEqual(created["hash"] as? String, expectedHash)
        let updated = try await browser.call("set-login", [
            "url": "https://mail.example.com/login", "login": "anna", "password": "changed", "uuid": mailID.browserHex
        ])
        XCTAssertEqual(updated["error"] as? String, "success")
        XCTAssertEqual(prompts.updateRequests, 1)

        let (_, vault) = try await reopen()
        let newEntry = try XCTUnwrap(vault.entries.first { $0.title == "new.example.com" })
        XCTAssertEqual(newEntry.username, "neo")
        XCTAssertTrue(newEntry.groupPath.hasSuffix("KeePassXC-Browser Passwords"))
        let mail = try XCTUnwrap(vault.entries.first { $0.id == mailID })
        XCTAssertEqual(mail.password, "changed")
        XCTAssertEqual(mail.history.count, 1)

        let newGroup = try await browser.call("create-new-group", ["groupName": "Web/Shops"])
        XCTAssertEqual(newGroup["name"] as? String, "Shops")
        let groups = try await browser.call("get-database-groups")
        let root = try XCTUnwrap(((groups["groups"] as? [String: Any])?["groups"] as? [[String: Any]])?.first)
        let childNames = (root["children"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(Set(childNames).isSuperset(of: ["KeePassXC-Browser Passwords", "Web"]), "\(childNames)")

        let totp = try await browser.call("get-totp", ["uuid": mailID.browserHex])
        XCTAssertEqual(totp["totp"] as? String, "", "no OTP on this entry")

        try browser.closeInput()
        await waitUntil("the proxy exits when the browser closes stdin") { !browser.process.isRunning }
        XCTAssertEqual(browser.process.terminationStatus, 0)
    }

    func testSecondBrowserReconnectsWithStoredAssociation() async throws {
        let first = try startProxy()
        _ = try await first.changePublicKeys()
        _ = try await first.associate()
        _ = try await first.call("get-logins", ["url": "https://mail.example.com/", "keys": first.keys])
        XCTAssertEqual(prompts.accessRequests, 1)

        let second = try startProxy(identificationKey: first.identificationKey)
        _ = try await second.changePublicKeys()
        let tested = try await second.call("test-associate", ["id": "chrome-e2e", "key": second.identificationKey])
        XCTAssertEqual(tested["id"] as? String, "chrome-e2e")
        let logins = try await second.call("get-logins", ["url": "https://mail.example.com/", "keys": second.keys])
        XCTAssertEqual((logins["entries"] as? [[String: Any]])?.first?["login"] as? String, "anna")
        XCTAssertEqual(prompts.accessRequests, 1, "the remembered answer covers the second browser")

        let stale = try await first.call("get-databasehash")
        XCTAssertNotNil(stale["hash"], "the first connection keeps its own session")
    }

    func testLockAndUnlockReachBrowsersThroughProxy() async throws {
        let browser = try startProxy()
        _ = try await browser.changePublicKeys()
        _ = try await browser.associate()
        let listener = try startProxy()
        _ = try await listener.changePublicKeys()

        // The requesting browser gets its reply and the broadcast in either order.
        let first = try await browser.call("lock-database")
        let second = await browser.nextFrame()
        XCTAssertEqual(Set([first["action"], second?["action"]].compactMap { $0 as? String }), ["lock-database", "database-locked"])
        XCTAssertNil(first["errorCode"])
        XCTAssertFalse(model.loadState.isUnlocked)
        let signal = await listener.nextFrame()
        XCTAssertEqual(signal?["action"] as? String, "database-locked", "every connected browser hears about the lock")

        let locked = try await browser.call("get-databasehash")
        XCTAssertEqual(locked["errorCode"] as? String, "1")
        XCTAssertEqual(prompts.unlockRequests, 0)
        let triggered = try await browser.call("get-logins", ["url": "https://mail.example.com/"], extra: ["triggerUnlock": "true"])
        XCTAssertEqual(triggered["errorCode"] as? String, "1")
        await waitUntil("the unlock window is requested") { self.prompts.unlockRequests == 1 }

        await model.finishPendingLock()
        await model.unlock(masterPassword: password)
        let unlocked = await listener.nextFrame()
        XCTAssertEqual(unlocked?["action"] as? String, "database-unlocked")
        let ownSignal = await browser.nextFrame()
        XCTAssertEqual(ownSignal?["action"] as? String, "database-unlocked")
        let hash = try await browser.call("get-databasehash")
        XCTAssertNotNil(hash["hash"])
    }

    func testProxyExitsWhenKeeMacStopsServing() async throws {
        let browser = try startProxy()
        _ = try await browser.changePublicKeys()

        controller.setEnabled(false)
        let end = await browser.nextFrame()
        XCTAssertNil(end, "stdout closes")
        await waitUntil("the proxy exits after the socket closed") { !browser.process.isRunning }
        XCTAssertEqual(browser.process.terminationStatus, 0)
    }

    func testProxyWithoutServerFailsFast() async throws {
        controller.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        let browser = try startProxy()
        await waitUntil("the proxy gives up without a server") { !browser.process.isRunning }
        XCTAssertEqual(browser.process.terminationStatus, 1)
        XCTAssertEqual(browser.errorOutput, "KeeMac is not running or browser integration is off.\n")
        let reply = await browser.nextFrame()
        XCTAssertNil(reply)
    }
}
