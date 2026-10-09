import Foundation
@testable import SSHAgent
import XCTest

/// Keys made by the real `ssh-keygen`, read by KeeMac, and the other way round.
final class SSHKeyTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func run(_ arguments: [String], input: String? = nil, environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        }
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ssh-keygen", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    private func keygen(_ name: String, type: String, bits: Int? = nil, passphrase: String = "", pem: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var arguments = ["ssh-keygen", "-q", "-t", type, "-N", passphrase, "-C", "anna@\(name)", "-f", url.path]
        if let bits {
            arguments += ["-b", String(bits)]
        }
        if pem {
            arguments += ["-m", "PEM"]
        }
        try Self.run(arguments)
        return url
    }

    /// `ssh-keygen -l` fingerprint and `ssh-keygen -y` public key must match what KeeMac reads.
    private func assertMatchesKeygen(_ url: URL, passphrase: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        let key = try SSHKeyReader.read(try Data(contentsOf: url), passphrase: passphrase)
        let fingerprint = try Self.run(["ssh-keygen", "-l", "-f", url.path + ".pub"]).split(separator: " ")[1]
        XCTAssertEqual(key.publicKey.fingerprint, String(fingerprint), file: file, line: line)
        let publicLine = try String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8)
        XCTAssertEqual(publicLine.split(separator: " ")[1], key.publicKey.authorizedKeysLine.split(separator: " ")[1], file: file, line: line)
    }

    func testReadsOpenSSHKeysOfEveryType() throws {
        try assertMatchesKeygen(try keygen("ed", type: "ed25519"), passphrase: nil)
        try assertMatchesKeygen(try keygen("rsa", type: "rsa", bits: 2048), passphrase: nil)
        try assertMatchesKeygen(try keygen("p256", type: "ecdsa", bits: 256), passphrase: nil)
        try assertMatchesKeygen(try keygen("p384", type: "ecdsa", bits: 384), passphrase: nil)
        try assertMatchesKeygen(try keygen("p521", type: "ecdsa", bits: 521), passphrase: nil)

        let key = try SSHKeyReader.read(try Data(contentsOf: directory.appendingPathComponent("ed")), passphrase: nil)
        XCTAssertEqual(key.publicKey.comment, "anna@ed")
        XCTAssertEqual(key.publicKey.algorithm, .ed25519)
        let rsa = try SSHKeyReader.read(try Data(contentsOf: directory.appendingPathComponent("rsa")), passphrase: nil)
        XCTAssertEqual(rsa.publicKey.algorithm.displayName, "RSA 2048")
    }

    func testEncryptedOpenSSHKey() throws {
        let url = try keygen("enc", type: "ed25519", passphrase: "secret phrase")
        let data = try Data(contentsOf: url)
        let info = try SSHKeyReader.inspect(data)
        XCTAssertTrue(info.isEncrypted)
        XCTAssertNotNil(info.publicKey, "the public part is readable without the passphrase")
        XCTAssertThrowsError(try SSHKeyReader.read(data, passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyError, .passphraseRequired) }
        XCTAssertThrowsError(try SSHKeyReader.read(data, passphrase: "wrong")) { XCTAssertEqual($0 as? SSHKeyError, .wrongPassphrase) }
        try assertMatchesKeygen(url, passphrase: "secret phrase")
        XCTAssertEqual(try SSHKeyReader.read(data, passphrase: "secret phrase").publicKey, info.publicKey.map { try! SSHPublicKey(blob: $0.blob, comment: "anna@enc") })
    }

    func testReadsLegacyPEMKeys() throws {
        try assertMatchesKeygen(try keygen("rsa-pem", type: "rsa", bits: 2048, pem: true), passphrase: nil)
        try assertMatchesKeygen(try keygen("ec-pem", type: "ecdsa", bits: 256, pem: true), passphrase: nil)
        let encrypted = try keygen("rsa-pem-enc", type: "rsa", bits: 2048, passphrase: "pem pass", pem: true)
        XCTAssertTrue(try SSHKeyReader.inspect(try Data(contentsOf: encrypted)).isEncrypted)
        XCTAssertThrowsError(try SSHKeyReader.read(try Data(contentsOf: encrypted), passphrase: "nope")) {
            XCTAssertEqual($0 as? SSHKeyError, .wrongPassphrase)
        }
        try assertMatchesKeygen(encrypted, passphrase: "pem pass")
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try SSHKeyReader.read(Data("hello".utf8), passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyError, .notAKey) }
        XCTAssertFalse(SSHKeyReader.looksLikePrivateKey(Data("ssh-ed25519 AAAA… anna@mac".utf8)))
    }

    /// Keys generated and written by KeeMac open in `ssh-keygen`, encrypted or not.
    func testGeneratedKeysOpenInSSHKeygen() throws {
        for kind in SSHKeyKind.allCases {
            let key = try SSHPrivateKey.generate(kind, comment: "anna@keemac")
            for passphrase in [nil, "gen pass"] {
                let url = directory.appendingPathComponent("\(kind.rawValue)-\(passphrase == nil ? "plain" : "enc")")
                try key.openSSHText(passphrase: passphrase).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let derived = try Self.run(["ssh-keygen", "-y", "-P", passphrase ?? "", "-f", url.path])
                XCTAssertEqual(derived.split(separator: " ")[1], key.publicKey.authorizedKeysLine.split(separator: " ")[1], "\(kind)")
                let reread = try SSHKeyReader.read(try Data(contentsOf: url), passphrase: passphrase)
                XCTAssertEqual(reread.publicKey, key.publicKey)
            }
        }
    }

    func testBigUnsignedModulo() {
        XCTAssertEqual(BigUnsigned.modulo(Data([0x01, 0x00]), Data([0x07])), Data([0x04]), "256 mod 7")
        XCTAssertEqual(BigUnsigned.subtractOne(Data([0x01, 0x00])), Data([0x00, 0xFF]))
    }
}
