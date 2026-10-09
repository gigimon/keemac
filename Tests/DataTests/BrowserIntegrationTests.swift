@testable import BrowserIntegration
import Domain
import Foundation
import XCTest

final class NaClBoxTests: XCTestCase {
    /// Produced by tweetnacl-js 1.0.3, the library KeePassXC-Browser uses:
    /// `nacl.box(msg, nonce, bob.publicKey, alice.secretKey)` with secret keys 1...32 and 100...131.
    func testOpensBoxMadeByTweetNaClJS() throws {
        let alice = try XCTUnwrap(NaClKeyPair(secretKey: Data((1...32).map { UInt8($0) })))
        let bob = try XCTUnwrap(NaClKeyPair(secretKey: Data((100..<132).map { UInt8($0) })))
        XCTAssertEqual(alice.publicKey.base64EncodedString(), "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=")
        XCTAssertEqual(bob.publicKey.base64EncodedString(), "fZwkMWU5glwYluV/KBl3Rnk85gy+461H2p0HuF+lXio=")

        let nonce = try XCTUnwrap(Data(base64Encoded: "AAcOFRwjKjE4P0ZNVFtiaXB3foWMk5qh"))
        let box = try XCTUnwrap(Data(base64Encoded: "Q7MELKH/kYJhseWjmvrIvel9sOUcvsBu2muN+M39LqM1T1MWhgeVGfqX/XqA"))

        let opened = NaClBox.open(box, nonce: nonce, publicKey: alice.publicKey, secretKey: bob.secretKey)
        XCTAssertEqual(opened.map { String(decoding: $0, as: UTF8.self) }, #"{"action":"get-databasehash"}"#)

        let sealed = NaClBox.seal(Data(#"{"action":"get-databasehash"}"#.utf8), nonce: nonce, publicKey: bob.publicKey, secretKey: alice.secretKey)
        XCTAssertEqual(sealed, box)
    }

    func testTamperedBoxIsRejected() throws {
        let alice = NaClKeyPair.generate()
        let bob = NaClKeyPair.generate()
        let nonce = NaClBox.randomBytes(NaClBox.nonceBytes)
        var box = try XCTUnwrap(NaClBox.seal(Data("secret".utf8), nonce: nonce, publicKey: bob.publicKey, secretKey: alice.secretKey))
        box[box.count - 1] ^= 1
        XCTAssertNil(NaClBox.open(box, nonce: nonce, publicKey: alice.publicKey, secretKey: bob.secretKey))
    }

    func testNonceIncrementIsLittleEndianWithCarry() {
        XCTAssertEqual(NaClBox.increment(Data([0, 0, 0])), Data([1, 0, 0]))
        XCTAssertEqual(NaClBox.increment(Data([255, 255, 7])), Data([0, 0, 8]))
        XCTAssertEqual(NaClBox.increment(Data([255, 255])), Data([0, 0]))
    }
}

@MainActor
private final class FakeVault: BrowserVaultProviding {
    var isVaultUnlocked = true
    var associations: [String: String] = [:]
    var connectionName: String? = "chrome-test"
    var logins: [BrowserLogin] = []
    var queries: [BrowserLoginQuery] = []
    var unlockRequests = 0
    var lockRequests = 0
    let hash = String(repeating: "ab", count: 32)

    func browserDatabaseHash() async -> String? { hash }

    func browserAssociationKey(for id: String) async -> String? { associations[id] }

    func associateBrowser(identificationKey: String) async -> String? {
        guard let connectionName else {
            return nil
        }
        associations[connectionName] = identificationKey
        return connectionName
    }

    func browserLogins(for query: BrowserLoginQuery) async -> [BrowserLogin] {
        queries.append(query)
        return logins
    }

    func browserTOTP(forEntry id: UUID) async -> String? { "123456" }

    var saved: [BrowserSaveRequest] = []
    var saveResult = true
    var groupTree = VaultBrowserGroup(id: UUID(), title: "Root", children: [VaultBrowserGroup(id: UUID(), title: "Web")])
    var createdGroupPaths: [String] = []
    var generatedPassword: String? = "Gen3rated!"
    var generatorDelay: Duration = .zero

    func browserGroups() async -> VaultBrowserGroup? { groupTree }

    func createBrowserGroup(path: String) async -> VaultBrowserGroup? {
        createdGroupPaths.append(path)
        return VaultBrowserGroup(id: UUID(), title: String(path.split(separator: "/").last ?? ""))
    }

    func saveBrowserLogin(_ request: BrowserSaveRequest) async -> Bool {
        saved.append(request)
        return saveResult
    }

    func generateBrowserPassword() async -> String? {
        try? await Task.sleep(for: generatorDelay)
        return generatedPassword
    }

    func lockForBrowser() { lockRequests += 1 }

    func showUnlockForBrowser() { unlockRequests += 1 }
}

/// Speaks to the handler the way keepassxc-browser does.
private final class ExtensionClient: @unchecked Sendable {
    let handler: BrowserMessageHandler
    let connection: Int
    let sessionKeys = NaClKeyPair.generate()
    let identificationKey = NaClKeyPair.generate().publicKey.base64EncodedString()
    var serverKey: Data?

    init(handler: BrowserMessageHandler, connection: Int = 1) {
        self.handler = handler
        self.connection = connection
    }

    func changePublicKeys() async throws -> [String: Any] {
        let nonce = NaClBox.randomBytes(NaClBox.nonceBytes)
        let reply = try await send([
            "action": "change-public-keys",
            "publicKey": sessionKeys.publicKey.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "clientID": NaClBox.randomBytes(24).base64EncodedString()
        ])
        XCTAssertEqual(reply["nonce"] as? String, NaClBox.increment(nonce).base64EncodedString())
        serverKey = (reply["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }
        return reply
    }

    /// Sends an encrypted request and returns the decrypted reply, or the plain error reply.
    func call(_ action: String, _ payload: [String: Any] = [:], nonce: Data = NaClBox.randomBytes(NaClBox.nonceBytes), extra: [String: Any] = [:]) async throws -> [String: Any] {
        let serverKey = try XCTUnwrap(serverKey)
        var message = payload
        message["action"] = action
        let plain = try JSONSerialization.data(withJSONObject: message)
        let box = try XCTUnwrap(NaClBox.seal(plain, nonce: nonce, publicKey: serverKey, secretKey: sessionKeys.secretKey))
        var request: [String: Any] = [
            "action": action,
            "message": box.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "clientID": "client"
        ]
        request.merge(extra) { _, new in new }
        let reply = try await send(request)
        guard let encrypted = reply["message"] as? String else {
            return reply
        }
        let replyNonce = try XCTUnwrap((reply["nonce"] as? String).flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(replyNonce, NaClBox.increment(nonce))
        let opened = try XCTUnwrap(NaClBox.open(try XCTUnwrap(Data(base64Encoded: encrypted)), nonce: replyNonce, publicKey: serverKey, secretKey: sessionKeys.secretKey))
        let decrypted = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
        XCTAssertEqual(decrypted["nonce"] as? String, replyNonce.base64EncodedString())
        XCTAssertEqual(decrypted["success"] as? String, "true")
        XCTAssertEqual(decrypted["version"] as? String, BrowserProtocol.compatibleVersion)
        return decrypted
    }

    func send(_ request: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = await handler.handle(data, from: connection)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
}

final class BrowserMessageHandlerTests: XCTestCase {
    @MainActor
    func testAssociateThenGetLogins() async throws {
        let vault = FakeVault()
        let entryID = UUID()
        vault.logins = [BrowserLogin(
            login: "anna", password: "pw", name: "Mail", uuid: entryID, group: "Root",
            totp: nil, isExpired: false, skipAutoSubmit: true, stringFields: [BrowserStringField(key: "KPH: pin", value: "1234")]
        )]
        let handler = BrowserMessageHandler(provider: vault)
        let client = ExtensionClient(handler: handler)

        let keys = try await client.changePublicKeys()
        XCTAssertEqual(keys["success"] as? String, "true")

        let hash = try await client.call("get-databasehash")
        XCTAssertEqual(hash["hash"] as? String, vault.hash)

        let beforeAssociation = try await client.call("get-logins", ["url": "https://mail.example.com"])
        XCTAssertEqual(beforeAssociation["errorCode"] as? String, "8")

        let associate = try await client.call("associate", [
            "key": client.sessionKeys.publicKey.base64EncodedString(),
            "idKey": client.identificationKey
        ])
        XCTAssertEqual(associate["id"] as? String, "chrome-test")
        XCTAssertEqual(vault.associations["chrome-test"], client.identificationKey)

        let logins = try await client.call("get-logins", [
            "url": "https://mail.example.com/login",
            "submitUrl": "https://mail.example.com/session",
            "keys": [["id": "chrome-test", "key": client.identificationKey]]
        ])
        XCTAssertEqual(logins["count"] as? Int, 1)
        let entry = try XCTUnwrap((logins["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["login"] as? String, "anna")
        XCTAssertEqual(entry["uuid"] as? String, entryID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        XCTAssertEqual(entry["skipAutoSubmit"] as? String, "true")
        XCTAssertEqual((entry["stringFields"] as? [[String: String]])?.first?["KPH: pin"], "1234")
        XCTAssertEqual(vault.queries.last, BrowserLoginQuery(siteURL: "https://mail.example.com/login", formURL: "https://mail.example.com/session", httpAuth: false))

        let totp = try await client.call("get-totp", ["uuid": entryID.browserHex])
        XCTAssertEqual(totp["totp"] as? String, "123456")
    }

    @MainActor
    func testTestAssociateOnNewConnection() async throws {
        let vault = FakeVault()
        let identificationKey = NaClKeyPair.generate().publicKey.base64EncodedString()
        vault.associations["laptop"] = identificationKey
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))
        _ = try await client.changePublicKeys()

        let wrong = try await client.call("test-associate", ["id": "laptop", "key": "other"])
        XCTAssertEqual(wrong["errorCode"] as? String, "8")

        let right = try await client.call("test-associate", ["id": "laptop", "key": identificationKey])
        XCTAssertEqual(right["id"] as? String, "laptop")
        XCTAssertEqual(right["hash"] as? String, vault.hash)

        let unknownKeys = try await client.call("get-logins", ["url": "https://example.com", "keys": [["id": "laptop", "key": "stale"]]])
        XCTAssertEqual(unknownKeys["errorCode"] as? String, "15")
    }

    @MainActor
    func testDeclinedAssociation() async throws {
        let vault = FakeVault()
        vault.connectionName = nil
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))
        _ = try await client.changePublicKeys()
        let reply = try await client.call("associate", ["key": client.sessionKeys.publicKey.base64EncodedString(), "idKey": client.identificationKey])
        XCTAssertEqual(reply["errorCode"] as? String, "6")

        let foreignKey = try await client.call("associate", ["key": NaClKeyPair.generate().publicKey.base64EncodedString()])
        XCTAssertEqual(foreignKey["errorCode"] as? String, "8")
    }

    @MainActor
    func testLockedDatabase() async throws {
        let vault = FakeVault()
        vault.isVaultUnlocked = false
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))

        let withoutKeys = try await client.send(["action": "get-databasehash"])
        XCTAssertEqual(withoutKeys["errorCode"] as? String, "3")

        _ = try await client.changePublicKeys()
        let locked = try await client.call("get-databasehash")
        XCTAssertEqual(locked["errorCode"] as? String, "1")
        XCTAssertEqual(vault.unlockRequests, 0)

        _ = try await client.call("get-databasehash", extra: ["triggerUnlock": "true"])
        XCTAssertEqual(vault.unlockRequests, 1)
    }

    @MainActor
    func testReplayedNonceAndGarbageAreRejected() async throws {
        let vault = FakeVault()
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))
        _ = try await client.changePublicKeys()

        let nonce = NaClBox.randomBytes(NaClBox.nonceBytes)
        _ = try await client.call("get-databasehash", nonce: nonce)
        let replay = try await client.call("get-databasehash", nonce: nonce)
        XCTAssertEqual(replay["errorCode"] as? String, "4")

        let garbage = await client.handler.handle(Data("not json".utf8), from: 1)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: garbage) as? [String: Any])
        XCTAssertEqual(reply["errorCode"] as? String, "13")

        let unknown = try await client.call("passkeys-get")
        XCTAssertEqual(unknown["errorCode"] as? String, "12")
    }

    @MainActor
    func testLockDatabase() async throws {
        let vault = FakeVault()
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))
        _ = try await client.changePublicKeys()
        _ = try await client.call("lock-database")
        XCTAssertEqual(vault.lockRequests, 1)
    }

    @MainActor
    private func associatedClient(_ vault: FakeVault) async throws -> ExtensionClient {
        let client = ExtensionClient(handler: BrowserMessageHandler(provider: vault))
        _ = try await client.changePublicKeys()
        _ = try await client.call("associate", ["key": client.sessionKeys.publicKey.base64EncodedString(), "idKey": client.identificationKey])
        return client
    }

    @MainActor
    func testSetLogin() async throws {
        let vault = FakeVault()
        let client = try await associatedClient(vault)
        let entryID = UUID()
        let groupID = UUID()

        let created = try await client.call("set-login", [
            "id": "chrome-test", "url": "https://example.com/login", "submitUrl": "https://example.com/session",
            "login": "anna", "password": "p{a}ss", "group": "Web", "groupUuid": groupID.browserHex
        ])
        XCTAssertEqual(created["error"] as? String, "success")
        XCTAssertTrue(created["entries"] is NSNull)
        XCTAssertEqual(vault.saved.last, BrowserSaveRequest(
            siteURL: "https://example.com/login", formURL: "https://example.com/session",
            login: "anna", password: "p{a}ss", entryID: nil, groupID: groupID
        ))

        _ = try await client.call("set-login", ["url": "https://example.com", "login": "a", "password": "b", "downloadFavicon": "true"])
        XCTAssertEqual(vault.saved.last?.downloadFavicon, true)
        vault.saved.removeLast()

        vault.saveResult = false
        let declined = try await client.call("set-login", ["url": "https://example.com", "login": "anna", "password": "new", "uuid": entryID.browserHex])
        XCTAssertEqual(declined["error"] as? String, "error")
        XCTAssertEqual(vault.saved.last?.entryID, entryID)
        XCTAssertNil(vault.saved.last?.groupID)

        let reference = try await client.call("set-login", ["url": "https://example.com", "login": "{USERNAME}", "password": "x"])
        XCTAssertEqual(reference["errorCode"] as? String, "34")
        let ref = try await client.call("set-login", ["url": "https://example.com", "login": "a", "password": "{REF:P@I:0123}"])
        XCTAssertEqual(ref["errorCode"] as? String, "34")
        let badUUID = try await client.call("set-login", ["url": "https://example.com", "login": "a", "password": "b", "uuid": "nope"])
        XCTAssertEqual(badUUID["errorCode"] as? String, "18")
        let noURL = try await client.call("set-login", ["login": "a", "password": "b"])
        XCTAssertEqual(noURL["errorCode"] as? String, "14")
        XCTAssertEqual(vault.saved.count, 2)
    }

    @MainActor
    func testGroups() async throws {
        let vault = FakeVault()
        let client = try await associatedClient(vault)

        let groups = try await client.call("get-database-groups")
        let wrapper = try XCTUnwrap(groups["groups"] as? [String: Any])
        let root = try XCTUnwrap((wrapper["groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(root["name"] as? String, "Root")
        XCTAssertEqual(root["uuid"] as? String, vault.groupTree.id.browserHex)
        XCTAssertEqual((root["children"] as? [[String: Any]])?.first?["name"] as? String, "Web")

        let created = try await client.call("create-new-group", ["groupName": "Web/Shops"])
        XCTAssertEqual(created["name"] as? String, "Shops")
        XCTAssertEqual(vault.createdGroupPaths, ["Web/Shops"])

        let empty = try await client.call("create-new-group", ["groupName": ""])
        XCTAssertEqual(empty["errorCode"] as? String, "17")
    }

    @MainActor
    func testGeneratePassword() async throws {
        let vault = FakeVault()
        let client = try await associatedClient(vault)

        let generated = try await client.call("generate-password", ["requestID": "abcd1234"], extra: ["requestID": "abcd1234"])
        XCTAssertEqual(generated["password"] as? String, "Gen3rated!")

        vault.generatedPassword = nil
        let cancelled = try await client.call("generate-password", ["requestID": "abcd1234"], extra: ["requestID": "abcd1234"])
        XCTAssertEqual(cancelled["errorCode"] as? String, "6")
        XCTAssertEqual(cancelled["requestID"] as? String, "abcd1234")
    }

    @MainActor
    func testOnlyOneGeneratorAtATime() async throws {
        let vault = FakeVault()
        vault.generatorDelay = .milliseconds(300)
        let client = try await associatedClient(vault)

        async let first = client.call("generate-password")
        try await Task.sleep(for: .milliseconds(50))
        let second = try await client.call("generate-password")
        XCTAssertEqual(second["errorCode"] as? String, "6")
        let firstReply = try await first
        XCTAssertEqual(firstReply["password"] as? String, "Gen3rated!")
    }

    func testSignalIsPlainJSON() throws {
        let data = BrowserMessageHandler.signal(BrowserAction.databaseLocked)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["action": "database-locked"])
    }

    func testSocketServerRelaysFrames() async throws {
        let vault = await FakeVault()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kmb-\(UUID().uuidString.prefix(8))").path
        let server = BrowserSocketServer(handler: BrowserMessageHandler(provider: vault), path: path)
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try BrowserSocketServer(handler: BrowserMessageHandler(provider: vault), path: path).start())

        let descriptor = try XCTUnwrap(Self.connect(to: path))
        defer { close(descriptor) }
        let request = try JSONSerialization.data(withJSONObject: [
            "action": "change-public-keys",
            "publicKey": NaClKeyPair.generate().publicKey.base64EncodedString(),
            "nonce": NaClBox.randomBytes(24).base64EncodedString()
        ])
        var length = UInt32(request.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(request)
        _ = frame.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }

        var header = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(read(descriptor, &header, 4), 4)
        let replyLength = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        var body = [UInt8](repeating: 0, count: replyLength)
        var received = 0
        while received < replyLength {
            let count = body[received...].withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            XCTAssertGreaterThan(count, 0)
            received += count
        }
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        XCTAssertEqual(reply["action"] as? String, "change-public-keys")
        XCTAssertNotNil(reply["publicKey"])
    }

    /// Runs the built `keemac-proxy` the way a browser does: one native messaging frame in, one out.
    func testProxyRelaysToServer() async throws {
        let proxy = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("keemac-proxy")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: proxy.path), "keemac-proxy isn't built")
        let vault = await FakeVault()
        let directory = URL(fileURLWithPath: "/tmp/kmp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("browser.sock").path
        let server = BrowserSocketServer(handler: BrowserMessageHandler(provider: vault), path: socketPath)
        try server.start()
        defer { server.stop() }

        let process = Process()
        process.executableURL = proxy
        process.environment = ["KEEMAC_BROWSER_SOCKET": socketPath]
        process.arguments = ["chrome-extension://oboonakemofpalcgghocfoadofidjkkk/"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }

        let request = try JSONSerialization.data(withJSONObject: [
            "action": "change-public-keys",
            "publicKey": NaClKeyPair.generate().publicKey.base64EncodedString(),
            "nonce": NaClBox.randomBytes(24).base64EncodedString()
        ])
        var length = UInt32(request.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(request)
        try input.fileHandleForWriting.write(contentsOf: frame)

        let header = try XCTUnwrap(try output.fileHandleForReading.read(upToCount: 4))
        let replyLength = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let body = try XCTUnwrap(try output.fileHandleForReading.read(upToCount: replyLength))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(reply["action"] as? String, "change-public-keys")
        XCTAssertEqual(reply["version"] as? String, BrowserProtocol.compatibleVersion)

        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private static func connect(to path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? descriptor : nil
    }
}

final class BrowserURLMatcherTests: XCTestCase {
    private func candidate(
        _ title: String,
        url: String,
        additionalURLs: [String] = [],
        expired: Bool = false,
        onlyHTTPAuth: Bool = false,
        access: BrowserAccessConfig? = nil
    ) -> VaultBrowserCandidate {
        VaultBrowserCandidate(
            id: UUID(), title: title, username: "", password: "", url: url, additionalURLs: additionalURLs,
            groupTitle: "Root", isExpired: expired, onlyHTTPAuth: onlyHTTPAuth, access: access
        )
    }

    func testHostMatching() {
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "https://example.com", siteURL: "https://example.com/login", formURL: ""))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "example.com", siteURL: "https://accounts.example.com/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "example.com", siteURL: "http://example.com/", formURL: ""), "no scheme means https")
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "http://example.com", siteURL: "http://example.com/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "https://example.com", siteURL: "https://badexample.com/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "https://accounts.example.com", siteURL: "https://example.com/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "https://example.com:8443", siteURL: "https://example.com/", formURL: ""))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "https://example.com:8443", siteURL: "https://example.com:8443/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "co.uk", siteURL: "https://shop.co.uk/", formURL: ""))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "shop.co.uk", siteURL: "https://www.shop.co.uk/", formURL: ""))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "", siteURL: "https://example.com/", formURL: ""))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "https://192.168.1.1", siteURL: "https://192.168.1.1/admin", formURL: ""))
    }

    func testAdditionalURLWildcardsAndExactMatch() {
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "https://*.example.org", siteURL: "https://a.b.example.org/x", formURL: "", allowWildcards: true))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "https://*.example.org", siteURL: "https://example.org.evil.com/", formURL: "", allowWildcards: true))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "https://example.org/app/*", siteURL: "https://example.org/app/login", formURL: "", allowWildcards: true))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "https://example.org/app/*", siteURL: "https://example.org/other", formURL: "", allowWildcards: true))
        XCTAssertTrue(BrowserURLMatcher.matches(entryURL: "\"https://example.org/exact\"", siteURL: "https://example.org/exact", formURL: "", allowWildcards: true))
        XCTAssertFalse(BrowserURLMatcher.matches(entryURL: "\"https://example.org/exact\"", siteURL: "https://example.org/exact/more", formURL: "", allowWildcards: true))
    }

    func testSortsBestMatchFirst() {
        let host = candidate("Host", url: "https://example.com")
        let exact = candidate("Exact", url: "https://example.com/login")
        let parent = candidate("Parent domain", url: "example.com")
        let path = candidate("Path", url: "https://accounts.example.com/")
        let sorted = BrowserURLMatcher.sorted([parent, host, path, exact], siteURL: "https://accounts.example.com/login", formURL: "")
        XCTAssertEqual(sorted.map(\.title), ["Path", "Parent domain", "Host", "Exact"], "85 first, then ties of 60 in their original order")
        XCTAssertEqual(BrowserURLMatcher.priority(of: ["https://example.com/login"], siteURL: "https://example.com/login", formURL: ""), 100)
        XCTAssertEqual(BrowserURLMatcher.priority(of: ["https://example.com/login"], siteURL: "https://example.com/login?next=1", formURL: ""), 90)
        XCTAssertEqual(BrowserURLMatcher.priority(of: ["https://example.com/"], siteURL: "https://example.com/login", formURL: ""), 85)
        XCTAssertEqual(BrowserURLMatcher.priority(of: ["https://example.com/other"], siteURL: "https://example.com/login", formURL: ""), 80)
        XCTAssertEqual(BrowserURLMatcher.priority(of: ["example.com"], siteURL: "https://a.example.com/login", formURL: ""), 60)
    }

    func testAccessRules() {
        let allowed = candidate("Allowed", url: "example.com", access: BrowserAccessConfig(allowedHosts: ["example.com"]))
        let denied = candidate("Denied", url: "example.com", access: BrowserAccessConfig(deniedHosts: ["example.com"]))
        let unknown = candidate("Unknown", url: "example.com")
        let expired = candidate("Expired", url: "example.com", expired: true, access: BrowserAccessConfig(allowedHosts: ["example.com"]))
        let httpOnly = candidate("HTTP auth", url: "example.com", onlyHTTPAuth: true)
        let other = candidate("Other", url: "other.com")
        let all = [allowed, denied, unknown, expired, httpOnly, other]

        let match = BrowserURLMatcher.match(all, siteURL: "https://example.com/", formURL: "", httpAuth: false, alwaysAllowAccess: false, allowExpired: false)
        XCTAssertEqual(match.allowed.map(\.title), ["Allowed"])
        XCTAssertEqual(match.needConfirmation.map(\.title), ["Unknown"])

        let permissive = BrowserURLMatcher.match(all, siteURL: "https://example.com/", formURL: "", httpAuth: false, alwaysAllowAccess: true, allowExpired: true)
        XCTAssertEqual(Set(permissive.allowed.map(\.title)), ["Allowed", "Unknown", "Expired"])

        let formElsewhere = BrowserURLMatcher.match([allowed], siteURL: "https://example.com/", formURL: "https://login.other.com/", httpAuth: false, alwaysAllowAccess: false, allowExpired: false)
        XCTAssertEqual(formElsewhere.needConfirmation.map(\.title), ["Allowed"])

        let httpAuth = BrowserURLMatcher.match(all, siteURL: "https://example.com/", formURL: "", httpAuth: true, alwaysAllowAccess: true, allowExpired: false)
        XCTAssertTrue(httpAuth.allowed.isEmpty)
        XCTAssertTrue(httpAuth.needConfirmation.map(\.title).contains("HTTP auth"))
    }

    func testAccessConfigMatchesKeePassXCJSON() throws {
        let stored = #"{"Allow":["example.com"],"Deny":["evil.com"],"Realm":""}"#
        var config = try XCTUnwrap(BrowserAccessConfig(json: stored))
        XCTAssertTrue(config.isAllowed("example.com"))
        XCTAssertTrue(config.isDenied("evil.com"))
        config.deny("example.com")
        XCTAssertFalse(config.isAllowed("example.com"))
        XCTAssertEqual(config.json, #"{"Allow":[],"Deny":["evil.com","example.com"],"Realm":""}"#)
        XCTAssertNil(BrowserAccessConfig(json: "garbage"))
    }
}
