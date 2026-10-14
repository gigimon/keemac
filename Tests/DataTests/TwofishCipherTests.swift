import Foundation
import KeePassKit
import XCTest

/// KeePassKit's Twofish (patched in `scripts/patches/keepasskit-twofish-buffers.patch`).
final class TwofishCipherTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })
    private let iv = Data((0..<16).map { UInt8(0xf0 - $0) })

    private func roundTrip(_ plain: Data) throws -> (encrypted: Data, decrypted: Data) {
        let encrypted = try KPKTwofishCipher().encryptData(plain, withKey: key, initializationVector: iv)
        let decrypted = try KPKTwofishCipher().decryptData(encrypted, withKey: key, initializationVector: iv)
        return (encrypted, decrypted)
    }

    func testRoundTripPadsToWholeBlocks() throws {
        for length in [0, 1, 15, 16, 17, 31, 32, 1_000] {
            let plain = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let (encrypted, decrypted) = try roundTrip(plain)
            XCTAssertEqual(encrypted.count, (length / 16 + 1) * 16, "PKCS#7 always adds padding (length \(length))")
            XCTAssertEqual(decrypted, plain, "length \(length)")
        }
    }

    /// Databases used to be encrypted into a stack buffer: too large for a background thread.
    func testLargeDataOnABackgroundThread() throws {
        let plain = Data((0..<3_000_001).map { UInt8(truncatingIfNeeded: $0) })
        let done = expectation(description: "round trip")
        let thread = Thread { [key, iv] in
            let encrypted = try? KPKTwofishCipher().encryptData(plain, withKey: key, initializationVector: iv)
            let decrypted = encrypted.flatMap { try? KPKTwofishCipher().decryptData($0, withKey: key, initializationVector: iv) }
            XCTAssertEqual(decrypted, plain)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 30)
    }

    func testWrongKeyDoesNotProduceAHugeLength() throws {
        let encrypted = try KPKTwofishCipher().encryptData(Data(repeating: 1, count: 64), withKey: key, initializationVector: iv)
        let wrongKey = Data(repeating: 0x55, count: 32)
        for _ in 0..<20 {
            let decrypted = try? KPKTwofishCipher().decryptData(encrypted, withKey: wrongKey, initializationVector: iv)
            XCTAssertLessThanOrEqual(decrypted?.count ?? 0, encrypted.count)
        }
    }
}
