import Foundation
@testable import SSHAgent
import XCTest

final class SSHHostMatchingTests: XCTestCase {
    func testHostKeySignatureIsChecked() throws {
        let sessionID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        for kind in SSHKeyKind.allCases {
            let hostKey = try SSHPrivateKey.generate(kind, comment: "")
            for flags: UInt32 in [0, SSHPrivateKey.rsaSHA256, SSHPrivateKey.rsaSHA512] {
                let signature = try hostKey.sign(sessionID, flags: flags)
                let binding = SSHSessionBinding(hostKey: hostKey.publicKey.blob, sessionIdentifier: sessionID, signature: signature, isForwarding: false)
                XCTAssertTrue(binding.hasValidSignature, "\(kind) flags \(flags)")
            }
            let other = try SSHPrivateKey.generate(kind, comment: "")
            let forged = SSHSessionBinding(hostKey: hostKey.publicKey.blob, sessionIdentifier: sessionID, signature: try other.sign(sessionID), isForwarding: false)
            XCTAssertFalse(forged.hasValidSignature, "\(kind): someone else's signature")
        }
    }

    func testKnownHostsPlainAndHashed() throws {
        let prod = try SSHPrivateKey.generate(.ed25519, comment: "")
        let git = try SSHPrivateKey.generate(.ecdsaP256, comment: "")
        let text = """
        prod.example.com,10.0.0.5 \(prod.publicKey.authorizedKeysLine)
        [nas.local]:2222 \(git.publicKey.authorizedKeysLine)
        @revoked * \(git.publicKey.authorizedKeysLine)
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("known_hosts")
        try Data((text + "\n").utf8).write(to: file)

        let plain = SSHKnownHosts.load(from: file)
        XCTAssertEqual(plain.names(for: prod.publicKey.blob, candidates: []), ["prod.example.com", "10.0.0.5"])
        XCTAssertEqual(plain.names(for: git.publicKey.blob, candidates: []), ["[nas.local]:2222"])

        // The real ssh-keygen hashes every name; candidates still find them.
        try SSHKeyTests.run(["ssh-keygen", "-H", "-f", file.path])
        let hashed = SSHKnownHosts.load(from: file)
        XCTAssertEqual(hashed.names(for: prod.publicKey.blob, candidates: []), [])
        XCTAssertEqual(hashed.names(for: prod.publicKey.blob, candidates: ["prod.example.com", "github.com"]), ["prod.example.com"])
        XCTAssertEqual(hashed.names(for: git.publicKey.blob, candidates: ["[nas.local]:2222"]), ["[nas.local]:2222"])
    }

    func testHostPatterns() {
        XCTAssertTrue(SSHHostPattern.matches("prod.example.com", name: "PROD.example.com"))
        XCTAssertTrue(SSHHostPattern.matches("*.example.com", name: "db.prod.example.com"))
        XCTAssertFalse(SSHHostPattern.matches("*.example.com", name: "example.org"))
        XCTAssertTrue(SSHHostPattern.matches("web?", name: "web1"))
        XCTAssertTrue(SSHHostPattern.matches("[nas.local]:2222", name: "[nas.local]:2222"))
        XCTAssertFalse(SSHHostPattern.matches("nas.local", name: "[nas.local]:2222"), "another port is another server")
        XCTAssertTrue(SSHHostPattern.matches("nas.local", name: "[nas.local]:22"))
    }
}
