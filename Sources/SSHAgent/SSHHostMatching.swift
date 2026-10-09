import CommonCrypto
import CryptoKit
import Foundation
import Security

extension SSHSessionBinding {
    /// The server signed the session identifier with its host key; only then is the binding trusted.
    public var hasValidSignature: Bool {
        SSHSignatureVerifier.verify(signature: signature, of: sessionIdentifier, with: hostKey)
    }
}

enum SSHSignatureVerifier {
    static func verify(signature: Data, of data: Data, with publicKeyBlob: Data) -> Bool {
        do {
            var key = SSHReader(publicKeyBlob)
            let keyType = try key.text()
            var sig = SSHReader(signature)
            let signatureType = try sig.text()
            let signatureBytes = try sig.string()
            switch keyType {
            case "ssh-ed25519":
                guard signatureType == "ssh-ed25519" else { return false }
                return try Curve25519.Signing.PublicKey(rawRepresentation: key.string()).isValidSignature(signatureBytes, for: data)
            case "ssh-rsa":
                let e = try key.mpint()
                let n = try key.mpint()
                let algorithm: SecKeyAlgorithm
                switch signatureType {
                case "rsa-sha2-512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
                case "rsa-sha2-256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
                case "ssh-rsa": algorithm = .rsaSignatureMessagePKCS1v15SHA1
                default: return false
                }
                let der = DER.sequence([DER.integer(n), DER.integer(e)])
                let attributes: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic
                ]
                guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
                return SecKeyVerifySignature(publicKey, algorithm, data as CFData, signatureBytes as CFData, nil)
            default:
                guard let curve = SSHCurve.allCases.first(where: { $0.keyType == keyType }), signatureType == keyType else { return false }
                _ = try key.text()
                let point = try key.string()
                var inner = SSHReader(signatureBytes)
                let raw = padded(try inner.mpint(), to: curve.scalarLength) + padded(try inner.mpint(), to: curve.scalarLength)
                switch curve {
                case .p256:
                    return try P256.Signing.PublicKey(x963Representation: point).isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: data)
                case .p384:
                    return try P384.Signing.PublicKey(x963Representation: point).isValidSignature(P384.Signing.ECDSASignature(rawRepresentation: raw), for: data)
                case .p521:
                    return try P521.Signing.PublicKey(x963Representation: point).isValidSignature(P521.Signing.ECDSASignature(rawRepresentation: raw), for: data)
                }
            }
        } catch {
            return false
        }
    }
}

/// `~/.ssh/known_hosts`: which names a server's host key is known under.
public struct SSHKnownHosts: Sendable {
    struct Line: Sendable {
        /// Plain names and `[host]:port`, lowercased.
        let names: [String]
        /// `|1|salt|hash` entries: HMAC-SHA1 of the name with the salt.
        let hashed: [(salt: Data, hash: Data)]
        let keyBlob: Data
    }

    let lines: [Line]

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    public init(text: String) {
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if fields.first?.hasPrefix("@") == true {
                // @revoked and @cert-authority lines don't name a host key.
                continue
            }
            guard fields.count >= 3, let key = Data(base64Encoded: fields[2]) else { continue }
            let hosts = fields.removeFirst().split(separator: ",").map(String.init)
            var names: [String] = []
            var hashed: [(Data, Data)] = []
            for host in hosts where !host.hasPrefix("!") {
                if host.hasPrefix("|1|") {
                    let parts = host.split(separator: "|").map(String.init)
                    if parts.count == 3, let salt = Data(base64Encoded: parts[1]), let hash = Data(base64Encoded: parts[2]) {
                        hashed.append((salt, hash))
                    }
                } else if !host.contains("*"), !host.contains("?") {
                    names.append(host.lowercased())
                }
            }
            lines.append(Line(names: names, hashed: hashed, keyBlob: key))
        }
        self.lines = lines
    }

    public static func load(from url: URL = defaultURL) -> SSHKnownHosts {
        SSHKnownHosts(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// Names known for this host key: plain names from known_hosts, plus candidates that match hashed lines.
    /// Candidates are the host names KeeMac's keys mention; hashed lines can only be checked against names.
    public func names(for hostKey: Data, candidates: [String]) -> [String] {
        var result: [String] = []
        func add(_ name: String) {
            if !result.contains(name) {
                result.append(name)
            }
        }
        for line in lines where line.keyBlob == hostKey {
            line.names.forEach(add)
            for candidate in candidates.map({ $0.lowercased() }) where line.hashed.contains(where: { Self.hmacSHA1(key: $0.salt, data: Data(candidate.utf8)) == $0.hash }) {
                add(candidate)
            }
        }
        return result
    }

    static func hmacSHA1(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

public enum SSHHostPattern {
    /// `*.example.com` and `prod?` globs, case-insensitive. `[host]:2222` only matches that port's known_hosts name.
    public static func matches(_ pattern: String, name: String) -> Bool {
        let pattern = pattern.lowercased()
        let name = name.lowercased()
        if !pattern.contains("*"), !pattern.contains("?") {
            return pattern == name || (pattern == stripDefaultPort(name))
        }
        return glob(Array(pattern), Array(name))
    }

    /// known_hosts writes non-default ports as `[host]:port`; port 22 stays a plain name.
    private static func stripDefaultPort(_ name: String) -> String {
        if name.hasPrefix("["), name.hasSuffix("]:22") {
            return String(name.dropFirst().dropLast(4))
        }
        return name
    }

    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                mark = t
                p += 1
            } else if star >= 0 {
                p = star + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" {
            p += 1
        }
        return p == pattern.count
    }
}
