import Foundation
@testable import SSHAgent
import XCTest

/// The agent checked with the real OpenSSH tools on a temporary socket.
final class SSHAgentServerTests: XCTestCase {
    private final class Backend: SSHAgentBackend, @unchecked Sendable {
        let keys: [SSHPrivateKey]
        private let lock = NSLock()
        private(set) var signedBy: [String] = []

        init(keys: [SSHPrivateKey]) {
            self.keys = keys
        }

        func identities(for request: SSHAgentRequest) async -> [SSHAgentIdentity] {
            keys.map { SSHAgentIdentity(publicKeyBlob: $0.publicKey.blob, comment: $0.publicKey.comment) }
        }

        func sign(publicKeyBlob: Data, data: Data, flags: UInt32, for request: SSHAgentRequest) async -> Data? {
            guard let key = keys.first(where: { $0.publicKey.blob == publicKeyBlob }) else { return nil }
            lock.withLock { signedBy.append(request.client.name) }
            return try? key.sign(data, flags: flags)
        }
    }

    private var directory: URL!

    override func setUp() async throws {
        // sockaddr_un paths are short: keep the socket in /tmp.
        directory = URL(fileURLWithPath: "/tmp/km-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSSHAddListsAndSSHKeygenSignsThroughTheAgent() throws {
        let keys = try SSHKeyKind.allCases.map { try SSHPrivateKey.generate($0, comment: "anna@\($0.rawValue)") }
        let backend = Backend(keys: keys)
        let socket = directory.appendingPathComponent("agent.sock").path
        let server = SSHAgentServer(backend: backend, path: socket)
        try server.start()
        defer { server.stop() }
        let environment = ["SSH_AUTH_SOCK": socket]

        let listed = try SSHKeyTests.run(["ssh-add", "-L"], environment: environment)
        for key in keys {
            XCTAssertTrue(listed.contains(key.publicKey.authorizedKeysLine), "ssh-add lists \(key.publicKey.algorithm.displayName)")
        }

        let message = directory.appendingPathComponent("message.txt")
        try Data("signed through KeeMac".utf8).write(to: message)
        for (index, key) in keys.enumerated() {
            let publicFile = directory.appendingPathComponent("key\(index).pub")
            try Data((key.publicKey.authorizedKeysLine + "\n").utf8).write(to: publicFile)
            try? FileManager.default.removeItem(at: message.appendingPathExtension("sig"))
            try SSHKeyTests.run(["ssh-keygen", "-Y", "sign", "-n", "file", "-f", publicFile.path, message.path], environment: environment)

            let allowed = directory.appendingPathComponent("allowed\(index)")
            try Data("anna \(key.publicKey.authorizedKeysLine)\n".utf8).write(to: allowed)
            let verified = try SSHKeyTests.run(
                ["ssh-keygen", "-Y", "verify", "-f", allowed.path, "-I", "anna", "-n", "file", "-s", message.path + ".sig"],
                input: "signed through KeeMac"
            )
            XCTAssertTrue(verified.contains("Good"), "\(key.publicKey.algorithm.displayName): \(verified)")
        }
        XCTAssertEqual(backend.signedBy.count, keys.count)
        XCTAssertTrue(backend.signedBy.allSatisfy { $0 == "ssh-keygen" }, "the client is the process on the socket")
    }

    func testOutsideChangesAreRefused() throws {
        let backend = Backend(keys: [])
        let socket = directory.appendingPathComponent("agent.sock").path
        let server = SSHAgentServer(backend: backend, path: socket)
        try server.start()
        defer { server.stop() }
        let keyFile = directory.appendingPathComponent("outside")
        try SSHKeyTests.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyFile.path])
        XCTAssertThrowsError(try SSHKeyTests.run(["ssh-add", keyFile.path], environment: ["SSH_AUTH_SOCK": socket]))
        XCTAssertThrowsError(try SSHAgentServer(backend: backend, path: socket).start()) {
            XCTAssertEqual($0 as? SSHAgentServer.StartError, .alreadyInUse)
        }
    }
}

final class SSHConfigTests: XCTestCase {
    func testAddsAndRemovesOnlyKeeMacsBlock() {
        let original = "Host prod\n  HostName prod.example.com\n  IdentityFile ~/.ssh/prod\n"
        let added = SSHConfigSetup.adding(to: original)
        XCTAssertTrue(added.hasPrefix("# >>> KeeMac SSH agent"))
        XCTAssertTrue(added.contains("IdentityAgent ~/.keemac/agent.sock"))
        XCTAssertTrue(SSHConfigSetup.isSetUp(added))
        XCTAssertEqual(SSHConfigSetup.adding(to: added), added, "added once")
        XCTAssertEqual(SSHConfigSetup.removing(from: added), original)
        XCTAssertFalse(SSHConfigSetup.isSetUp(original))
    }

    func testFindsHostsOfKeyFiles() {
        let ssh = URL(fileURLWithPath: "/Users/anna/.ssh")
        let config = """
        Host prod staging
          HostName prod.example.com
          IdentityFile ~/.ssh/deploy
        Host *.internal
          IdentityFile ~/.ssh/internal
        Host github.com
          IdentityFile id_ed25519
        """
        let hosts = SSHDirectoryScanner.identityHosts(in: config, sshDirectory: ssh)
        XCTAssertEqual(hosts["/Users/anna/.ssh/deploy"], ["prod", "staging", "prod.example.com"])
        XCTAssertNil(hosts["/Users/anna/.ssh/internal"], "wildcard-only hosts aren't names")
        XCTAssertEqual(hosts["/Users/anna/.ssh/id_ed25519"], ["github.com"])
    }
}
