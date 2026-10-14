import CryptoKit
import Foundation

/// A YubiKey slot programmed for HMAC-SHA1 challenge-response, used as part of the master key
/// (KeePassXC's scheme). The database file doesn't record it; KeeMac remembers it per database.
public struct VaultHardwareKey: Codable, Hashable, Sendable, Identifiable {
    public var serial: UInt32
    public var slot: Int
    public var model: String
    /// The slot waits for a touch before answering.
    public var requiresTouch: Bool

    public init(serial: UInt32, slot: Int, model: String = "YubiKey", requiresTouch: Bool = false) {
        self.serial = serial
        self.slot = slot
        self.model = model
        self.requiresTouch = requiresTouch
    }

    public var id: String { "\(serial):\(slot)" }

    /// "YubiKey 5 NFC (12345678) · Slot 2"
    public var label: String {
        L("\(model) (\(String(serial))) · Slot \(slot)")
    }

    /// "YubiKey 12345678 · Slot 2"
    public var shortLabel: String {
        L("YubiKey \(String(serial)) · Slot \(slot)")
    }

    /// Same device and slot; the model name and touch flag are only descriptive.
    public func isSameSlot(as other: VaultHardwareKey) -> Bool {
        serial == other.serial && slot == other.slot
    }
}

/// A hardware key's answer to one challenge (the KDF seed), kept for Touch ID unlock without the key.
public struct VaultHardwareKeyResponse: Codable, Equatable, Sendable {
    public var challenge: Data
    public var response: Data
    /// The slot that answered; a response only stands in for that slot.
    public var key: VaultHardwareKey?

    public init(challenge: Data, response: Data, key: VaultHardwareKey? = nil) {
        self.challenge = challenge
        self.response = response
        self.key = key
    }

    public func belongs(to other: VaultHardwareKey) -> Bool {
        key.map { $0.isSameSlot(as: other) } ?? false
    }
}

/// What Change Master Key does with the hardware key part.
public enum VaultHardwareKeyChange: Equatable, Sendable {
    case keep
    case use(VaultHardwareKey)
    case remove
}

/// Talks to hardware keys. Calls block (a slot may wait up to ~15 s for a touch) and run off the main thread.
public protocol HardwareKeyChallenging: Sendable {
    /// Connected keys, one item per slot that is configured.
    func connectedKeys() throws -> [VaultHardwareKey]
    /// HMAC-SHA1 response (20 bytes) of the slot to `challenge`. `isCancelled` is polled while waiting for a touch.
    func challengeResponse(_ challenge: Data, key: VaultHardwareKey, isCancelled: @escaping @Sendable () -> Bool) throws -> Data
}

public enum HardwareKeyChallenge {
    /// KeePassXC pads the challenge to 64 bytes (PKCS#7), which works for slots in fixed and variable length mode.
    public static func padded(_ challenge: Data) -> Data {
        let padLength = 64 - challenge.count
        guard padLength > 0 else {
            return challenge
        }
        return challenge + Data(repeating: UInt8(padLength), count: padLength)
    }

    /// What a slot in variable length mode (`HMAC_LT64`, YubiKey Manager's default) actually signs:
    /// trailing bytes equal to the last byte are dropped.
    public static func variableLengthMessage(_ padded: Data) -> Data {
        guard padded.count == 64, let last = padded.last else {
            return padded
        }
        var end = padded.count
        while end > 0, padded[padded.startIndex + end - 1] == last {
            end -= 1
        }
        return padded.prefix(end)
    }
}

/// A software stand-in for a YubiKey slot (tests and UI testing): HMAC-SHA1 with a known secret.
public final class SoftwareHardwareKey: HardwareKeyChallenging, @unchecked Sendable {
    public let key: VaultHardwareKey
    private let secret: Data
    private let variableLength: Bool
    private let lock = NSLock()
    private var connected = true
    private var challengeCount = 0
    /// Called before answering a touch-required slot; returns false when the touch never comes (timeout).
    private let waitForTouch: (@Sendable (_ isCancelled: @Sendable () -> Bool) -> Bool)?

    public init(
        secret: Data,
        key: VaultHardwareKey = VaultHardwareKey(serial: 12_345_678, slot: 2, model: "YubiKey 5 NFC"),
        variableLength: Bool = true,
        waitForTouch: (@Sendable (_ isCancelled: @Sendable () -> Bool) -> Bool)? = nil
    ) {
        self.secret = secret
        self.key = key
        self.variableLength = variableLength
        self.waitForTouch = waitForTouch
    }

    public var isConnected: Bool {
        get { lock.withLock { connected } }
        set { lock.withLock { connected = newValue } }
    }

    /// How many challenges reached the "device" (each would be a touch on a real key).
    public var challenges: Int {
        lock.withLock { challengeCount }
    }

    public func connectedKeys() throws -> [VaultHardwareKey] {
        isConnected ? [key] : []
    }

    public func challengeResponse(_ challenge: Data, key requested: VaultHardwareKey, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        guard isConnected, requested.serial == key.serial else {
            throw VaultError.hardwareKeyNotFound(serial: requested.serial)
        }
        guard requested.slot == key.slot else {
            throw VaultError.hardwareKeySlotNotConfigured(slot: requested.slot)
        }
        if let waitForTouch {
            guard waitForTouch(isCancelled) else {
                throw isCancelled() ? VaultError.hardwareKeyCancelled : VaultError.hardwareKeyTimedOut
            }
        }
        lock.withLock { challengeCount += 1 }
        return Self.response(secret: secret, challenge: challenge, variableLength: variableLength)
    }

    public static func response(secret: Data, challenge: Data, variableLength: Bool = true) -> Data {
        let padded = HardwareKeyChallenge.padded(challenge)
        let message = variableLength ? HardwareKeyChallenge.variableLengthMessage(padded) : padded
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(code)
    }
}
