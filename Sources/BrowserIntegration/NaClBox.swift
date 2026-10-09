import CTweetNaCl
import Foundation

/// A Curve25519 key pair for NaCl `crypto_box`.
public struct NaClKeyPair: Sendable {
    public let publicKey: Data
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    /// Derives the public key for a known secret key.
    public init?(secretKey: Data) {
        guard secretKey.count == NaClBox.keyBytes else {
            return nil
        }
        var publicKey = [UInt8](repeating: 0, count: NaClBox.keyBytes)
        _ = crypto_scalarmult_curve25519_tweet_base(&publicKey, [UInt8](secretKey))
        self.init(publicKey: Data(publicKey), secretKey: secretKey)
    }

    public static func generate() -> NaClKeyPair {
        var publicKey = [UInt8](repeating: 0, count: NaClBox.keyBytes)
        var secretKey = [UInt8](repeating: 0, count: NaClBox.keyBytes)
        _ = crypto_box_curve25519xsalsa20poly1305_tweet_keypair(&publicKey, &secretKey)
        return NaClKeyPair(publicKey: Data(publicKey), secretKey: Data(secretKey))
    }
}

/// NaCl `crypto_box` (X25519 + XSalsa20-Poly1305) as used by KeePassXC-Browser (TweetNaCl.js `nacl.box`).
public enum NaClBox {
    public static let keyBytes = 32
    public static let nonceBytes = 24
    public static let macBytes = 16
    private static let zeroBytes = 32
    private static let boxZeroBytes = 16

    /// Encrypts and authenticates `message`; the result is the MAC followed by the ciphertext.
    public static func seal(_ message: Data, nonce: Data, publicKey: Data, secretKey: Data) -> Data? {
        guard nonce.count == nonceBytes, publicKey.count == keyBytes, secretKey.count == keyBytes else {
            return nil
        }
        let padded = [UInt8](repeating: 0, count: zeroBytes) + [UInt8](message)
        var output = [UInt8](repeating: 0, count: padded.count)
        let result = crypto_box_curve25519xsalsa20poly1305_tweet(
            &output, padded, UInt64(padded.count), [UInt8](nonce), [UInt8](publicKey), [UInt8](secretKey)
        )
        guard result == 0 else {
            return nil
        }
        return Data(output[boxZeroBytes...])
    }

    /// Verifies and decrypts a box made by `seal` or `nacl.box`. Returns nil when it was tampered with.
    public static func open(_ box: Data, nonce: Data, publicKey: Data, secretKey: Data) -> Data? {
        guard box.count >= macBytes, nonce.count == nonceBytes, publicKey.count == keyBytes, secretKey.count == keyBytes else {
            return nil
        }
        let padded = [UInt8](repeating: 0, count: boxZeroBytes) + [UInt8](box)
        var output = [UInt8](repeating: 0, count: padded.count)
        let result = crypto_box_curve25519xsalsa20poly1305_tweet_open(
            &output, padded, UInt64(padded.count), [UInt8](nonce), [UInt8](publicKey), [UInt8](secretKey)
        )
        guard result == 0 else {
            return nil
        }
        return Data(output[zeroBytes...])
    }

    /// Adds one to the nonce as a little-endian number, like libsodium's `sodium_increment`.
    public static func increment(_ nonce: Data) -> Data {
        var bytes = [UInt8](nonce)
        for index in bytes.indices {
            bytes[index] &+= 1
            if bytes[index] != 0 {
                break
            }
        }
        return Data(bytes)
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return Data(bytes)
    }
}
