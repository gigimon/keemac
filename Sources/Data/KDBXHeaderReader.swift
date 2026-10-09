import Domain
import Foundation
import KeePassKit

/// Reads the plaintext outer header of a KDBX file (format version, cipher and KDF)
/// without needing the master key.
public enum KDBXHeaderReader {
    private static let signature1: UInt32 = 0x9AA2_D903
    private static let signature2: UInt32 = 0xB54B_FB67
    private static let maximumHeaderBytes = 1_048_576

    private enum Field: UInt8 {
        case end = 0
        case cipherID = 2
        case transformRounds = 6
        case kdfParameters = 11
    }

    public static func read(from url: URL) -> VaultFileInfo? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumHeaderBytes) else {
            return nil
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> VaultFileInfo? {
        var reader = ByteReader(data: data)
        guard reader.readUInt32() == signature1,
              reader.readUInt32() == signature2,
              let minor = reader.readUInt16(),
              let major = reader.readUInt16(),
              major == 3 || major == 4 else {
            return nil
        }

        var cipher: VaultCipher?
        var kdf: VaultKDFAlgorithm?

        while let rawID = reader.readUInt8() {
            let length: Int?
            if major >= 4 {
                length = reader.readUInt32().map(Int.init)
            } else {
                length = reader.readUInt16().map(Int.init)
            }
            guard let length, let value = reader.readBytes(length) else {
                return nil
            }

            switch Field(rawValue: rawID) {
            case .end:
                return VaultFileInfo(majorVersion: Int(major), minorVersion: Int(minor), cipher: cipher, kdf: kdf)
            case .cipherID:
                cipher = uuid(from: value).flatMap(cipherForUUID)
            case .transformRounds:
                kdf = .aes
            case .kdfParameters:
                kdf = kdfUUID(fromVariantDictionary: value).flatMap(kdfForUUID)
            case nil:
                continue
            }
        }
        return nil
    }

    private static func cipherForUUID(_ uuid: UUID) -> VaultCipher? {
        switch uuid {
        case KPKAESCipher.uuid():
            return .aes256
        case KPKChaCha20Cipher.uuid():
            return .chacha20
        case KPKTwofishCipher.uuid():
            return .twofish
        default:
            return nil
        }
    }

    private static func kdfForUUID(_ uuid: UUID) -> VaultKDFAlgorithm? {
        switch uuid {
        case KPKArgon2IDKeyDerivation.uuid():
            return .argon2id
        case KPKArgon2DKeyDerivation.uuid():
            return .argon2d
        case KPKAESKeyDerivation.uuid():
            return .aes
        default:
            // KeePass also writes the KDBX 4 flavour of AES-KDF under its own identifier.
            return uuid.uuidString == "7C02BB82-79A7-4AC0-927D-114A00648238" ? .aes : nil
        }
    }

    private static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else {
            return nil
        }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Extracts the `$UUID` entry from a KeePass VariantDictionary.
    private static func kdfUUID(fromVariantDictionary data: Data) -> UUID? {
        var reader = ByteReader(data: data)
        guard reader.readUInt16() != nil else {
            return nil
        }
        while let type = reader.readUInt8(), type != 0 {
            guard let keyLength = reader.readUInt32(),
                  let key = reader.readBytes(Int(keyLength)),
                  let valueLength = reader.readUInt32(),
                  let value = reader.readBytes(Int(valueLength)) else {
                return nil
            }
            if String(decoding: key, as: UTF8.self) == "$UUID" {
                return uuid(from: value)
            }
        }
        return nil
    }
}

private struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else {
            return nil
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt8() -> UInt8? {
        readBytes(1).map { $0[$0.startIndex] }
    }

    mutating func readUInt16() -> UInt16? {
        readBytes(2).map { UInt16($0[$0.startIndex]) | UInt16($0[$0.startIndex + 1]) << 8 }
    }

    mutating func readUInt32() -> UInt32? {
        readBytes(4).map { bytes in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[bytes.startIndex + $1]) << (8 * UInt32($1)) }
        }
    }
}
