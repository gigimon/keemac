import Foundation
@testable import SSHAgent
import XCTest

/// KeeMac's block in `~/.ssh/config` and key discovery for "Import Keys from ~/.ssh", on a temporary home.
final class SSHConfigSetupTests: XCTestCase {
    private var home: URL!
    private var sshDirectory: URL!
    private var configURL: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("KeeMacSSHConfig-\(UUID().uuidString)")
        sshDirectory = home.appendingPathComponent(".ssh")
        configURL = sshDirectory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func readConfig() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    private func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configURL)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: Text

    func testRoundTripKeepsTheUsersConfigByteForByte() {
        let configs = [
            "",
            "Host prod\n  HostName prod.example.com\n",
            "Host prod\n  HostName prod.example.com",
            "\n\nHost a\n\n\nHost b\n\n",
            "# my comments\nInclude ~/.ssh/config.d/*\n\nHost *\n  ServerAliveInterval 30\n"
        ]
        for original in configs {
            let added = SSHConfigSetup.adding(to: original)
            XCTAssertTrue(added.hasPrefix(SSHConfigSetup.beginMarker + "\n"), "the block goes first: \(original.debugDescription)")
            XCTAssertTrue(added.hasSuffix(original))
            XCTAssertTrue(SSHConfigSetup.isSetUp(added))
            XCTAssertEqual(SSHConfigSetup.adding(to: added), added, "added once")
            XCTAssertEqual(SSHConfigSetup.removing(from: added), original, "removed exactly: \(original.debugDescription)")
            XCTAssertEqual(SSHConfigSetup.removing(from: original), original, "nothing to remove")
        }
        XCTAssertEqual(
            SSHConfigSetup.adding(to: ""),
            "\(SSHConfigSetup.beginMarker)\nHost *\n  IdentityAgent ~/.keemac/agent.sock\n\(SSHConfigSetup.endMarker)\n"
        )
    }

    func testRemovesTheBlockWhereverItIs() {
        let before = "Host a\n  User anna\n\n"
        let after = "Host b\n  User boris\n"
        let block = "\(SSHConfigSetup.beginMarker)\n\(SSHConfigSetup.lines)\n\(SSHConfigSetup.endMarker)\n"
        XCTAssertEqual(SSHConfigSetup.removing(from: before + block + "\n" + after), before + after)
        // At the end of the file the blank line before the block stays, the one after it goes with the block.
        XCTAssertEqual(SSHConfigSetup.removing(from: before + block), "Host a\n  User anna\n")
    }

    func testDetectsAnIdentityAgentSetUpByHand() {
        XCTAssertTrue(SSHConfigSetup.isSetUp("Host *\n  IdentityAgent ~/.keemac/agent.sock\n"))
        XCTAssertTrue(SSHConfigSetup.isSetUp("Host *\n\tidentityagent=\"/Users/anna/.keemac/agent.sock\"\n"))
        XCTAssertFalse(SSHConfigSetup.isSetUp("Host *\n  # IdentityAgent ~/.keemac/agent.sock\n"), "a comment doesn't count")
        XCTAssertFalse(SSHConfigSetup.isSetUp("Host *\n  IdentityAgent ~/Library/Containers/other/agent.sock\n"), "another agent")
        XCTAssertFalse(SSHConfigSetup.isSetUp("Host *\n  IdentityFile ~/.keemac/agent.sock\n"))

        // Set up by hand: adding leaves it alone, removing has no block to take out.
        let manual = "Host *\n  IdentityAgent ~/.keemac/agent.sock\n"
        XCTAssertEqual(SSHConfigSetup.adding(to: manual), manual)
        XCTAssertEqual(SSHConfigSetup.removing(from: manual), manual)
    }

    // MARK: File

    func testSetUpCreatesThePrivateDirectoryAndFile() throws {
        XCTAssertFalse(SSHConfigSetup.isSetUp(at: configURL), "no file yet")
        try SSHConfigSetup.setUp(at: configURL)
        XCTAssertTrue(SSHConfigSetup.isSetUp(at: configURL))
        XCTAssertEqual(try permissions(sshDirectory), 0o700)
        XCTAssertEqual(try permissions(configURL), 0o600)

        try SSHConfigSetup.remove(at: configURL)
        XCTAssertEqual(try readConfig(), "")
        XCTAssertFalse(SSHConfigSetup.isSetUp(at: configURL))
    }

    func testSetUpAndRemoveKeepTheRestOfTheFile() throws {
        for original in ["Host prod\n  HostName prod.example.com\n  IdentityFile ~/.ssh/prod\n", "Host prod\n  User anna"] {
            try writeConfig(original)
            try SSHConfigSetup.setUp(at: configURL)
            let once = try readConfig()
            try SSHConfigSetup.setUp(at: configURL)
            XCTAssertEqual(try readConfig(), once, "set up twice, one block")
            XCTAssertEqual(once.components(separatedBy: SSHConfigSetup.beginMarker).count, 2)
            XCTAssertTrue(once.hasSuffix(original))
            XCTAssertEqual(try permissions(configURL), 0o600)

            try SSHConfigSetup.remove(at: configURL)
            XCTAssertEqual(try readConfig(), original)
            try SSHConfigSetup.remove(at: configURL)
            XCTAssertEqual(try readConfig(), original, "removing again changes nothing")
        }
    }

    func testRemoveWithoutAFileCreatesNothing() throws {
        try SSHConfigSetup.remove(at: configURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshDirectory.path))
    }

    // MARK: Key discovery

    func testIdentityFileHostsInEveryForm() {
        let config = """
        # Work
        Host prod staging !bastion
          HostName prod.example.com
          IdentityFile ~/.ssh/deploy
          IdentityFile ~/.ssh/deploy_old
        Host build
          IdentityFile=~/.ssh/deploy
        Host github.com
          IDENTITYFILE "~/.ssh/my key"
        Host relative
          IdentityFile id_relative
        Host absolute
          IdentityFile /opt/keys/ci
        Host *
          IdentityFile ~/.ssh/everywhere
        Match host gitlab.com
          IdentityFile ~/.ssh/matched
        Host web?
          HostName web.example.com
          IdentityFile ~/.ssh/web
        """
        let hosts = SSHDirectoryScanner.identityHosts(in: config, sshDirectory: sshDirectory)
        let ssh = sshDirectory.path
        XCTAssertEqual(hosts["\(ssh)/deploy"], ["prod", "staging", "prod.example.com", "build"], "merged, negations skipped")
        XCTAssertEqual(hosts["\(ssh)/deploy_old"], ["prod", "staging", "prod.example.com"])
        XCTAssertEqual(hosts["\(ssh)/my key"], ["github.com"], "quoted path with a space")
        XCTAssertEqual(hosts["\(ssh)/id_relative"], ["relative"], "relative to ~/.ssh")
        XCTAssertEqual(hosts["/opt/keys/ci"], ["absolute"])
        XCTAssertNil(hosts["\(ssh)/everywhere"], "Host * names no server")
        XCTAssertNil(hosts["\(ssh)/matched"], "Match blocks name no Host")
        XCTAssertEqual(hosts["\(ssh)/web"], ["web.example.com"], "the HostName of a wildcard block")
    }

    func testScanFindsPrivateKeysAndTheirHosts() throws {
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        func keygen(_ name: String, _ arguments: [String]) throws {
            try SSHKeyTests.run(["ssh-keygen", "-q", "-C", "anna@\(name)", "-f", sshDirectory.appendingPathComponent(name).path] + arguments)
        }
        try keygen("id_ed25519", ["-t", "ed25519", "-N", ""])
        try keygen("deploy", ["-t", "ecdsa", "-N", "secret"])
        try keygen("legacy", ["-t", "rsa", "-b", "2048", "-N", "", "-m", "PEM"])
        try Data("prod.example.com ssh-ed25519 AAAA\n".utf8).write(to: sshDirectory.appendingPathComponent("known_hosts"))
        try Data("ssh-ed25519 AAAA anna\n".utf8).write(to: sshDirectory.appendingPathComponent("authorized_keys"))
        try Data("not a key\n".utf8).write(to: sshDirectory.appendingPathComponent("notes.txt"))
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\ngarbage\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
            .write(to: sshDirectory.appendingPathComponent("broken"))
        try FileManager.default.createDirectory(at: sshDirectory.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        try writeConfig("""
        Host prod
          HostName prod.example.com
          IdentityFile ~/.ssh/deploy
        Host github.com
          IdentityFile id_ed25519
        """)

        let found = SSHDirectoryScanner.scan(directory: sshDirectory)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["deploy", "id_ed25519", "legacy"], "private keys only, sorted")
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })

        let deploy = try XCTUnwrap(byName["deploy"])
        XCTAssertTrue(deploy.info.isEncrypted)
        let deployPublic = try SSHPublicKey(blob: XCTUnwrap(deploy.info.publicKey?.blob), comment: "anna@deploy")
        let deployLine = try String(contentsOf: sshDirectory.appendingPathComponent("deploy.pub"), encoding: .utf8)
        XCTAssertEqual(deployPublic.authorizedKeysLine, deployLine.trimmingCharacters(in: .whitespacesAndNewlines), "OpenSSH keys show their public part while encrypted")
        XCTAssertEqual(deploy.hosts, ["prod", "prod.example.com"])
        XCTAssertEqual(deploy.data, try Data(contentsOf: sshDirectory.appendingPathComponent("deploy")))

        let plain = try XCTUnwrap(byName["id_ed25519"])
        XCTAssertFalse(plain.info.isEncrypted)
        XCTAssertEqual(plain.hosts, ["github.com"])
        let publicLine = try String(contentsOf: sshDirectory.appendingPathComponent("id_ed25519.pub"), encoding: .utf8)
        XCTAssertEqual(plain.info.publicKey.map { $0.authorizedKeysLine + " anna@id_ed25519" }, publicLine.trimmingCharacters(in: .whitespacesAndNewlines))

        XCTAssertEqual(byName["legacy"]?.hosts, [])
        XCTAssertEqual(byName["legacy"]?.info.publicKey?.algorithm.keyType, "ssh-rsa")
    }

    func testScanOfAMissingDirectoryIsEmpty() {
        XCTAssertTrue(SSHDirectoryScanner.scan(directory: sshDirectory).isEmpty)
    }
}
