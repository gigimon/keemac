import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum SSHCurve: String, Sendable, CaseIterable {
    case p256 = "nistp256"
    case p384 = "nistp384"
    case p521 = "nistp521"

    var keyType: String { "ecdsa-sha2-\(rawValue)" }

    var displayName: String {
        switch self {
        case .p256: return "ECDSA P-256"
        case .p384: return "ECDSA P-384"
        case .p521: return "ECDSA P-521"
        }
    }

    var scalarLength: Int {
        switch self {
        case .p256: return 32
        case .p384: return 48
        case .p521: return 66
        }
    }

    /// DER content of the curve's OID.
    var oid: Data {
        switch self {
        case .p256: return Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        case .p384: return Data([0x2B, 0x81, 0x04, 0x00, 0x22])
        case .p521: return Data([0x2B, 0x81, 0x04, 0x00, 0x23])
        }
    }
}

public enum SSHKeyAlgorithm: Sendable, Equatable, Hashable {
    case ed25519
    case rsa(bits: Int)
    case ecdsa(SSHCurve)

    /// "Ed25519", "RSA 4096", "ECDSA P-256".
    public var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .rsa(let bits): return "RSA \(bits)"
        case .ecdsa(let curve): return curve.displayName
        }
    }

    /// The key type in the wire format and in authorized_keys.
    public var keyType: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .rsa: return "ssh-rsa"
        case .ecdsa(let curve): return curve.keyType
        }
    }
}

/// What can be generated in KeeMac.
public enum SSHKeyKind: String, Sendable, CaseIterable {
    case ed25519
    case rsa4096
    case ecdsaP256
}

public enum SSHKeyError: Error, Equatable, Sendable {
    /// Not a private SSH key (or damaged).
    case notAKey
    /// A key type, cipher or format KeeMac doesn't handle.
    case unsupported(String)
    /// The key is encrypted and no passphrase was given.
    case passphraseRequired
    case wrongPassphrase
    case signingFailed
}

public struct SSHPublicKey: Sendable, Equatable, Hashable {
    /// The key in the wire format (what the agent lists and authorized_keys holds, base64).
    public let blob: Data
    public let algorithm: SSHKeyAlgorithm
    public let comment: String

    /// `SHA256:…` like `ssh-keygen -l`.
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// One line for authorized_keys or a `.pub` file.
    public var authorizedKeysLine: String {
        let base = "\(algorithm.keyType) \(blob.base64EncodedString())"
        return comment.isEmpty ? base : "\(base) \(comment)"
    }

    public init(blob: Data, comment: String) throws {
        var reader = SSHReader(blob)
        let type = try reader.text()
        switch type {
        case "ssh-ed25519":
            algorithm = .ed25519
        case "ssh-rsa":
            _ = try reader.mpint()
            let modulus = try reader.mpint()
            algorithm = .rsa(bits: Self.bitLength(of: modulus))
        default:
            guard let curve = SSHCurve.allCases.first(where: { $0.keyType == type }) else {
                throw SSHKeyError.unsupported(type)
            }
            algorithm = .ecdsa(curve)
        }
        self.blob = blob
        self.comment = comment
    }

    static func bitLength(of magnitude: Data) -> Int {
        let bytes = magnitude.drop { $0 == 0 }
        guard let first = bytes.first else { return 0 }
        return (bytes.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }
}

/// What a key file says before its passphrase is known.
public struct SSHKeyInfo: Sendable, Equatable {
    /// Nil for an encrypted PEM key, whose public part is encrypted too.
    public let publicKey: SSHPublicKey?
    public let isEncrypted: Bool
}

/// A decrypted private key: lists itself and signs for the agent.
public struct SSHPrivateKey: Sendable {
    enum Material: Sendable {
        case ed25519(seed: Data, publicKey: Data)
        case rsa(n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data)
        case ecdsa(curve: SSHCurve, d: Data, q: Data)
    }

    public let publicKey: SSHPublicKey
    let material: Material

    init(material: Material, comment: String) throws {
        self.material = material
        var writer = SSHWriter()
        switch material {
        case .ed25519(_, let publicKey):
            writer.string("ssh-ed25519")
            writer.string(publicKey)
        case .rsa(let n, let e, _, _, _, _):
            writer.string("ssh-rsa")
            writer.mpint(e)
            writer.mpint(n)
        case .ecdsa(let curve, _, let q):
            writer.string(curve.keyType)
            writer.string(curve.rawValue)
            writer.string(q)
        }
        publicKey = try SSHPublicKey(blob: writer.data, comment: comment)
    }

    public func withComment(_ comment: String) -> SSHPrivateKey {
        (try? SSHPrivateKey(material: material, comment: comment)) ?? self
    }
}

// MARK: - Reading

public enum SSHKeyReader {
    /// True for text that looks like a private SSH key, for suggesting "Use in SSH agent" on attachments.
    public static func looksLikePrivateKey(_ data: Data) -> Bool {
        guard data.count < 64 * 1024, let text = String(data: data.prefix(200), encoding: .utf8) else {
            return false
        }
        return text.contains("-----BEGIN OPENSSH PRIVATE KEY-----")
            || text.contains("-----BEGIN RSA PRIVATE KEY-----")
            || text.contains("-----BEGIN EC PRIVATE KEY-----")
            || text.contains("-----BEGIN PRIVATE KEY-----")
    }

    /// The public key and whether a passphrase is needed, without decrypting anything.
    public static func inspect(_ data: Data) throws -> SSHKeyInfo {
        let armor = try Armor(data)
        switch armor.label {
        case "OPENSSH PRIVATE KEY":
            let container = try OpenSSHContainer(armor.body)
            return SSHKeyInfo(publicKey: try SSHPublicKey(blob: container.publicBlob, comment: ""), isEncrypted: container.cipher != "none")
        default:
            if armor.isEncrypted {
                return SSHKeyInfo(publicKey: nil, isEncrypted: true)
            }
            return SSHKeyInfo(publicKey: try read(data, passphrase: nil).publicKey, isEncrypted: false)
        }
    }

    public static func read(_ data: Data, passphrase: String?) throws -> SSHPrivateKey {
        let armor = try Armor(data)
        switch armor.label {
        case "OPENSSH PRIVATE KEY":
            return try OpenSSHContainer(armor.body).decrypt(passphrase: passphrase)
        case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY":
            var der = armor.body
            if armor.isEncrypted {
                der = try armor.decryptLegacyPEM(passphrase: passphrase)
            }
            do {
                return try readDER(der, label: armor.label)
            } catch {
                // A wrong passphrase on a legacy PEM key shows up as garbage DER.
                throw armor.isEncrypted ? SSHKeyError.wrongPassphrase : error
            }
        case "ENCRYPTED PRIVATE KEY":
            throw SSHKeyError.unsupported("PKCS#8 encrypted key")
        default:
            throw SSHKeyError.notAKey
        }
    }

    private static func readDER(_ der: Data, label: String) throws -> SSHPrivateKey {
        let root = try DER.parse(der)
        switch label {
        case "RSA PRIVATE KEY":
            return try rsa(fromPKCS1: root)
        case "EC PRIVATE KEY":
            return try ecdsa(fromSEC1: root, curve: nil)
        default:
            // PKCS#8: version, AlgorithmIdentifier, OCTET STRING with the inner key.
            let items = try root.children()
            guard items.count >= 3, items[1].tag == 0x30, items[2].tag == 0x04 else { throw SSHKeyError.notAKey }
            let algorithm = try items[1].children()
            guard let oid = algorithm.first?.content else { throw SSHKeyError.notAKey }
            switch oid {
            case Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]):
                return try rsa(fromPKCS1: try DER.parse(items[2].content))
            case Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]):
                let curveOID = algorithm.count > 1 ? algorithm[1].content : Data()
                return try ecdsa(fromSEC1: try DER.parse(items[2].content), curve: SSHCurve.allCases.first { $0.oid == curveOID })
            case Data([0x2B, 0x65, 0x70]):
                let seed = try DER.parse(items[2].content).content
                guard seed.count == 32 else { throw SSHKeyError.notAKey }
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                return try SSHPrivateKey(material: .ed25519(seed: seed, publicKey: key.publicKey.rawRepresentation), comment: "")
            default:
                throw SSHKeyError.unsupported("PKCS#8 key")
            }
        }
    }

    private static func rsa(fromPKCS1 node: DER.Node) throws -> SSHPrivateKey {
        let items = try node.children()
        guard items.count >= 9 else { throw SSHKeyError.notAKey }
        return try SSHPrivateKey(material: .rsa(
            n: items[1].unsignedInteger,
            e: items[2].unsignedInteger,
            d: items[3].unsignedInteger,
            p: items[4].unsignedInteger,
            q: items[5].unsignedInteger,
            iqmp: items[8].unsignedInteger
        ), comment: "")
    }

    private static func ecdsa(fromSEC1 node: DER.Node, curve known: SSHCurve?) throws -> SSHPrivateKey {
        let items = try node.children()
        guard items.count >= 2, items[1].tag == 0x04 else { throw SSHKeyError.notAKey }
        var curve = known
        for item in items.dropFirst(2) where item.tag == 0xA0 {
            let parameters = try DER.parse(item.content)
            if parameters.tag == 0x06 {
                curve = SSHCurve.allCases.first { $0.oid == parameters.content } ?? curve
            } else if parameters.tag == 0x30 {
                // Explicit parameters (OpenSSL writes them for `ssh-keygen -m PEM`): the field prime's size tells the NIST curve.
                let fieldID = try parameters.children().dropFirst().first?.children()
                let primeLength = fieldID?.dropFirst().first?.unsignedInteger.count
                curve = SSHCurve.allCases.first { $0.scalarLength == primeLength } ?? curve
            }
        }
        guard let curve else { throw SSHKeyError.unsupported("EC curve") }
        let d = items[1].content
        return try SSHPrivateKey(material: .ecdsa(curve: curve, d: d, q: try publicPoint(curve: curve, d: d)), comment: "")
    }

    static func publicPoint(curve: SSHCurve, d: Data) throws -> Data {
        let scalar = padded(d, to: curve.scalarLength)
        switch curve {
        case .p256: return try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p384: return try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .p521: return try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        }
    }
}

func padded(_ value: Data, to length: Int) -> Data {
    let trimmed = Data(value.drop { $0 == 0 })
    guard trimmed.count < length else { return trimmed }
    return Data(repeating: 0, count: length - trimmed.count) + trimmed
}

/// `-----BEGIN …-----` text with optional legacy PEM headers.
private struct Armor {
    let label: String
    let body: Data
    let headers: [String: String]

    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw SSHKeyError.notAKey
        }
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else {
            throw SSHKeyError.notAKey
        }
        let label = String(lines[start].dropFirst("-----BEGIN ".count).dropLast(5))
        guard let end = lines[start...].firstIndex(of: "-----END \(label)-----") else {
            throw SSHKeyError.notAKey
        }
        var headers: [String: String] = [:]
        var base64 = ""
        for line in lines[(start + 1)..<end] where !line.isEmpty {
            if let colon = line.firstIndex(of: ":"), base64.isEmpty {
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                base64 += line
            }
        }
        guard let body = Data(base64Encoded: base64) else {
            throw SSHKeyError.notAKey
        }
        self.label = label
        self.body = body
        self.headers = headers
    }

    var isEncrypted: Bool {
        headers["Proc-Type"]?.contains("ENCRYPTED") == true
    }

    /// OpenSSL's legacy PEM encryption: AES-CBC with a key from EVP_BytesToKey (MD5, salt = first 8 bytes of the IV).
    func decryptLegacyPEM(passphrase: String?) throws -> Data {
        guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }
        guard let info = headers["DEK-Info"], let comma = info.firstIndex(of: ",") else { throw SSHKeyError.notAKey }
        let cipher = String(info[..<comma]).uppercased()
        let ivHex = String(info[info.index(after: comma)...])
        let keyLength: Int
        switch cipher {
        case "AES-128-CBC": keyLength = 16
        case "AES-192-CBC": keyLength = 24
        case "AES-256-CBC": keyLength = 32
        default: throw SSHKeyError.unsupported(cipher)
        }
        guard let iv = Data(hex: ivHex), iv.count == 16 else { throw SSHKeyError.notAKey }
        var key = Data()
        var previous = Data()
        let password = Data(passphrase.utf8)
        while key.count < keyLength {
            previous = Data(Insecure.MD5.hash(data: previous + password + iv.prefix(8)))
            key.append(previous)
        }
        guard let plain = AES.cbc(.decrypt, key: key.prefix(keyLength), iv: iv, data: body, padding: true) else {
            throw SSHKeyError.wrongPassphrase
        }
        return plain
    }
}

/// The `openssh-key-v1` container.
private struct OpenSSHContainer {
    static let magic = Data("openssh-key-v1\0".utf8)

    let cipher: String
    let kdf: String
    let kdfOptions: Data
    let publicBlob: Data
    let encrypted: Data

    init(_ body: Data) throws {
        guard body.starts(with: Self.magic) else { throw SSHKeyError.notAKey }
        do {
            var reader = SSHReader(body.dropFirst(Self.magic.count))
            cipher = try reader.text()
            kdf = try reader.text()
            kdfOptions = try reader.string()
            guard try reader.uint32() == 1 else { throw SSHKeyError.unsupported("several keys in one file") }
            publicBlob = try reader.string()
            encrypted = try reader.string()
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw SSHKeyError.notAKey
        }
    }

    func decrypt(passphrase: String?) throws -> SSHPrivateKey {
        var plain = encrypted
        if cipher != "none" {
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }
            guard kdf == "bcrypt" else { throw SSHKeyError.unsupported(kdf) }
            guard let spec = OpenSSHCipher(name: cipher) else { throw SSHKeyError.unsupported(cipher) }
            var options = SSHReader(kdfOptions)
            let salt = try options.string()
            let rounds = try options.uint32()
            let material = try bcryptPBKDF(passphrase, salt: salt, rounds: rounds, length: spec.keyLength + spec.ivLength)
            guard let decrypted = spec.crypt(.decrypt, key: material.prefix(spec.keyLength), iv: material.suffix(spec.ivLength), data: encrypted) else {
                throw SSHKeyError.wrongPassphrase
            }
            plain = decrypted
        }
        do {
            var reader = SSHReader(plain)
            guard try reader.uint32() == reader.uint32() else {
                throw cipher == "none" ? SSHKeyError.notAKey : SSHKeyError.wrongPassphrase
            }
            let type = try reader.text()
            let material: SSHPrivateKey.Material
            switch type {
            case "ssh-ed25519":
                let publicKey = try reader.string()
                let secret = try reader.string()
                guard publicKey.count == 32, secret.count == 64 else { throw SSHKeyError.notAKey }
                material = .ed25519(seed: secret.prefix(32), publicKey: publicKey)
            case "ssh-rsa":
                let n = try reader.mpint(), e = try reader.mpint(), d = try reader.mpint()
                let iqmp = try reader.mpint(), p = try reader.mpint(), q = try reader.mpint()
                material = .rsa(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp)
            default:
                guard let curve = SSHCurve.allCases.first(where: { $0.keyType == type }) else {
                    throw SSHKeyError.unsupported(type)
                }
                _ = try reader.text()
                let q = try reader.string()
                let d = try reader.mpint()
                material = .ecdsa(curve: curve, d: d, q: q)
            }
            let comment = try reader.text()
            return try SSHPrivateKey(material: material, comment: comment)
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw cipher == "none" ? SSHKeyError.notAKey : SSHKeyError.wrongPassphrase
        }
    }
}

private struct OpenSSHCipher {
    enum Mode {
        case ctr
        case cbc
    }

    let keyLength: Int
    let ivLength = 16
    let mode: Mode

    init?(name: String) {
        switch name {
        case "aes256-ctr": keyLength = 32; mode = .ctr
        case "aes192-ctr": keyLength = 24; mode = .ctr
        case "aes128-ctr": keyLength = 16; mode = .ctr
        case "aes256-cbc": keyLength = 32; mode = .cbc
        case "aes192-cbc": keyLength = 24; mode = .cbc
        case "aes128-cbc": keyLength = 16; mode = .cbc
        default: return nil
        }
    }

    func crypt(_ operation: AES.Operation, key: Data, iv: Data, data: Data) -> Data? {
        switch mode {
        case .ctr: return AES.ctr(key: key, iv: iv, data: data)
        case .cbc: return AES.cbc(operation, key: key, iv: iv, data: data, padding: false)
        }
    }
}

func bcryptPBKDF(_ passphrase: String, salt: Data, rounds: UInt32, length: Int) throws -> Data {
    let password = Array(passphrase.utf8)
    var output = [UInt8](repeating: 0, count: length)
    let result = password.withUnsafeBufferPointer { pass in
        salt.withUnsafeBytes { saltBytes in
            pass.withMemoryRebound(to: CChar.self) { passChars in
                bcrypt_pbkdf(passChars.baseAddress, pass.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, &output, length, rounds)
            }
        }
    }
    guard result == 0 else { throw SSHKeyError.wrongPassphrase }
    return Data(output)
}

/// AES through CommonCrypto (CryptoKit has no CTR or CBC).
enum AES {
    enum Operation {
        case encrypt
        case decrypt
    }

    static func ctr(key: Data, iv: Data, data: Data) -> Data? {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, &output, output.count, &moved)
        }
        return status == kCCSuccess ? Data(output.prefix(moved)) : nil
    }

    static func cbc(_ operation: Operation, key: Data, iv: Data, data: Data, padding: Bool) -> Data? {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { input in
                    CCCrypt(
                        CCOperation(operation == .encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        input.baseAddress, data.count, &output, output.count, &moved
                    )
                }
            }
        }
        return status == kCCSuccess ? Data(output.prefix(moved)) : nil
    }
}

extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

// MARK: - Signing

extension SSHPrivateKey {
    /// Agent sign-request flags.
    public static let rsaSHA256: UInt32 = 2
    public static let rsaSHA512: UInt32 = 4

    /// The signature blob for SSH2_AGENT_SIGN_RESPONSE.
    public func sign(_ data: Data, flags: UInt32 = 0) throws -> Data {
        var writer = SSHWriter()
        switch material {
        case .ed25519(let seed, _):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            writer.string("ssh-ed25519")
            writer.string(try key.signature(for: data))
        case .ecdsa(let curve, let d, _):
            let scalar = padded(d, to: curve.scalarLength)
            let raw: Data
            switch curve {
            case .p256: raw = try P256.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
            case .p384: raw = try P384.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
            case .p521: raw = try P521.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
            }
            var inner = SSHWriter()
            inner.mpint(raw.prefix(raw.count / 2))
            inner.mpint(raw.suffix(raw.count / 2))
            writer.string(curve.keyType)
            writer.string(inner.data)
        case .rsa:
            let (name, algorithm): (String, SecKeyAlgorithm)
            if flags & Self.rsaSHA512 != 0 {
                (name, algorithm) = ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
            } else if flags & Self.rsaSHA256 != 0 {
                (name, algorithm) = ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256)
            } else {
                (name, algorithm) = ("ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1)
            }
            var error: Unmanaged<CFError>?
            guard let key = try rsaSecKey(),
                  let signature = SecKeyCreateSignature(key, algorithm, data as CFData, &error) as Data? else {
                throw SSHKeyError.signingFailed
            }
            writer.string(name)
            writer.string(signature)
        }
        return writer.data
    }

    /// PKCS#1 RSAPrivateKey for Security.framework; OpenSSH keeps no CRT exponents, so they are computed here.
    private func rsaSecKey() throws -> SecKey? {
        guard case .rsa(let n, let e, let d, let p, let q, let iqmp) = material else { return nil }
        let dp = BigUnsigned.modulo(d, BigUnsigned.subtractOne(p))
        let dq = BigUnsigned.modulo(d, BigUnsigned.subtractOne(q))
        let der = DER.sequence([
            DER.integer(Data()), DER.integer(n), DER.integer(e), DER.integer(d),
            DER.integer(p), DER.integer(q), DER.integer(dp), DER.integer(dq), DER.integer(iqmp)
        ])
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

// MARK: - Generating and writing

extension SSHPrivateKey {
    public static func generate(_ kind: SSHKeyKind, comment: String) throws -> SSHPrivateKey {
        switch kind {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return try SSHPrivateKey(material: .ed25519(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation), comment: comment)
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return try SSHPrivateKey(material: .ecdsa(curve: .p256, d: key.rawRepresentation, q: key.publicKey.x963Representation), comment: comment)
        case .rsa4096:
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 4096
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                  let der = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
                throw SSHKeyError.signingFailed
            }
            let items = try DER.parse(der).children()
            guard items.count >= 9 else { throw SSHKeyError.signingFailed }
            return try SSHPrivateKey(material: .rsa(
                n: items[1].unsignedInteger, e: items[2].unsignedInteger, d: items[3].unsignedInteger,
                p: items[4].unsignedInteger, q: items[5].unsignedInteger, iqmp: items[8].unsignedInteger
            ), comment: comment)
        }
    }

    /// The key as an OpenSSH private key file, encrypted with aes256-ctr / bcrypt like `ssh-keygen` when a passphrase is given.
    public func openSSHText(passphrase: String?) throws -> Data {
        let isEncrypted = !(passphrase ?? "").isEmpty
        let blockSize = isEncrypted ? 16 : 8
        let check = UInt32.random(in: .min ... .max)
        var plain = SSHWriter()
        plain.uint32(check)
        plain.uint32(check)
        switch material {
        case .ed25519(let seed, let publicKey):
            plain.string("ssh-ed25519")
            plain.string(publicKey)
            plain.string(seed + publicKey)
        case .rsa(let n, let e, let d, let p, let q, let iqmp):
            plain.string("ssh-rsa")
            for value in [n, e, d, iqmp, p, q] {
                plain.mpint(value)
            }
        case .ecdsa(let curve, let d, let q):
            plain.string(curve.keyType)
            plain.string(curve.rawValue)
            plain.string(q)
            plain.mpint(d)
        }
        plain.string(publicKey.comment)
        var padding: UInt8 = 1
        while plain.data.count % blockSize != 0 {
            plain.byte(padding)
            padding += 1
        }

        var container = SSHWriter()
        container.raw(OpenSSHContainer.magic)
        if let passphrase, isEncrypted {
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let rounds: UInt32 = 16
            let material = try bcryptPBKDF(passphrase, salt: salt, rounds: rounds, length: 48)
            guard let encrypted = AES.ctr(key: material.prefix(32), iv: material.suffix(16), data: plain.data) else {
                throw SSHKeyError.signingFailed
            }
            var options = SSHWriter()
            options.string(salt)
            options.uint32(rounds)
            container.string("aes256-ctr")
            container.string("bcrypt")
            container.string(options.data)
            container.uint32(1)
            container.string(publicKey.blob)
            container.string(encrypted)
        } else {
            container.string("none")
            container.string("none")
            container.string(Data())
            container.uint32(1)
            container.string(publicKey.blob)
            container.string(plain.data)
        }
        let base64 = container.data.base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next]))
            index = next
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
