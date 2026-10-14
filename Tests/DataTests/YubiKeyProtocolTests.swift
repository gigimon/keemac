import CryptoKit
import Domain
import Foundation
@testable import HardwareKey
import XCTest

/// A YubiKey's OTP application as ykpers describes it: frames of ten 7-byte parts acknowledged by
/// clearing the write flag, responses read back in 7-byte parts with the "pending" flag and a sequence number.
private final class SimulatedYubiKey: YubiKeyTransport {
    var serial: UInt32 = 12_345_678
    var secrets: [Int: Data] = [:]
    var touchLevel: UInt16 = 0x02
    /// Status reports with the touch flag before answering; -1 never answers (times out).
    var touchPolls = 0
    var neverAnswersTouch = false

    private(set) var frames: [[UInt8]] = []
    private(set) var dummyWrites = 0
    private var frame = [UInt8](repeating: 0, count: 70)
    private var response: [[UInt8]] = []
    private var pendingTouch = 0
    private var waitingForTouch = false
    private var touchExpired = false

    func readFeatureReport() throws -> [UInt8] {
        if waitingForTouch {
            if neverAnswersTouch {
                pendingTouch -= 1
                if pendingTouch <= 0 {
                    waitingForTouch = false
                    touchExpired = true
                    return status(0)
                }
                return status(YubiKeyFrame.timeoutWaitFlag | 14)
            }
            if pendingTouch > 0 {
                pendingTouch -= 1
                return status(YubiKeyFrame.timeoutWaitFlag | 14)
            }
            waitingForTouch = false
        }
        guard !response.isEmpty else {
            return status(0)
        }
        return response.removeFirst()
    }

    func writeFeatureReport(_ report: [UInt8]) throws {
        XCTAssertEqual(report.count, 8)
        let control = report[7]
        if control == YubiKeyFrame.dummyReportWrite {
            dummyWrites += 1
            response = []
            waitingForTouch = false
            return
        }
        XCTAssertNotEqual(control & YubiKeyFrame.slotWriteFlag, 0, "frame parts carry the write flag")
        let sequence = Int(control & 0x1f)
        frame.replaceSubrange((sequence * 7)..<(sequence * 7 + 7), with: report[0..<7])
        if sequence == 9 {
            process()
            frame = [UInt8](repeating: 0, count: 70)
        }
    }

    private func status(_ byte: UInt8) -> [UInt8] {
        [0, 5, 4, 3, 1, UInt8(touchLevel & 0xff), UInt8(touchLevel >> 8), byte]
    }

    private func process() {
        frames.append(frame)
        let payload = Array(frame[0..<64])
        let crc = UInt16(frame[65]) | UInt16(frame[66]) << 8
        XCTAssertEqual(crc, YubiKeyFrame.crc16(payload), "frame CRC")
        let command = frame[64]
        switch command {
        case YubiKeyCommand.deviceSerial:
            respond(with: [UInt8(serial >> 24), UInt8(serial >> 16 & 0xff), UInt8(serial >> 8 & 0xff), UInt8(serial & 0xff)])
        case YubiKeyCommand.challengeHMAC1, YubiKeyCommand.challengeHMAC2:
            let slot = command == YubiKeyCommand.challengeHMAC1 ? 1 : 2
            guard let secret = secrets[slot] else {
                return
            }
            var message = payload
            let last = message.last
            while message.last == last {
                message.removeLast()
            }
            respond(with: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret))))
            if touchPolls > 0 || neverAnswersTouch {
                waitingForTouch = true
                pendingTouch = neverAnswersTouch ? 5 : touchPolls
            }
        default:
            XCTFail("unexpected command \(command)")
        }
    }

    /// Data plus the complemented CRC, in 7-byte parts; a report with sequence 0 ends it.
    private func respond(with data: [UInt8]) {
        let crc = ~YubiKeyFrame.crc16(data)
        var bytes = data + [UInt8(crc & 0xff), UInt8(crc >> 8)]
        while bytes.count % 7 != 0 {
            bytes.append(0)
        }
        response = stride(from: 0, to: bytes.count, by: 7).enumerated().map { index, offset in
            Array(bytes[offset..<(offset + 7)]) + [YubiKeyFrame.responsePendingFlag | UInt8(index + 1)]
        }
        response.append(status(YubiKeyFrame.responsePendingFlag))
    }
}

final class YubiKeyProtocolTests: XCTestCase {
    private let secret = Data((1...20).map { UInt8($0) })

    private func device(_ simulated: SimulatedYubiKey) -> YubiKeyDevice {
        YubiKeyDevice(transport: simulated, sleep: { _ in })
    }

    func testCRCResidual() {
        let data: [UInt8] = Array("123456789".utf8)
        let crc = ~YubiKeyFrame.crc16(data)
        XCTAssertEqual(YubiKeyFrame.crc16(data + [UInt8(crc & 0xff), UInt8(crc >> 8)]), YubiKeyFrame.crcOKResidual)
        XCTAssertEqual(YubiKeyFrame.crc16(data), 0x6f91, "CRC-16/ISO-HDLC before the final complement")
    }

    func testFrameReportsSkipEmptyParts() {
        let reports = YubiKeyFrame.reports(command: YubiKeyCommand.deviceSerial, payload: [])
        XCTAssertEqual(reports.map { $0[7] & 0x1f }, [0, 9], "only the first and last parts of an empty payload go out")
        XCTAssertEqual(reports.last?[1], YubiKeyCommand.deviceSerial, "the command is byte 64 of the frame (part 9, byte 1)")

        let full = YubiKeyFrame.reports(command: YubiKeyCommand.challengeHMAC2, payload: [UInt8](repeating: 0xaa, count: 64))
        XCTAssertEqual(full.count, 10)
        XCTAssertTrue(full.allSatisfy { $0[7] & YubiKeyFrame.slotWriteFlag != 0 })
    }

    func testStatusReport() {
        let status = YubiKeyStatus(report: [0, 5, 4, 3, 7, 0x0b, 0x00, 0])
        XCTAssertEqual(status.versionMajor, 5)
        XCTAssertEqual(status.versionMinor, 4)
        XCTAssertTrue(status.isConfigured(slot: 1))
        XCTAssertTrue(status.isConfigured(slot: 2))
        XCTAssertFalse(status.requiresTouch(slot: 1))
        XCTAssertTrue(status.requiresTouch(slot: 2))
    }

    func testSerialNumber() throws {
        let simulated = SimulatedYubiKey()
        XCTAssertEqual(try device(simulated).serial(), 12_345_678)
        XCTAssertEqual(simulated.dummyWrites, 1, "reading ends with a reset of the read mode")
    }

    func testChallengeResponse() throws {
        let simulated = SimulatedYubiKey()
        simulated.secrets[2] = secret
        let challenge = Data((0..<32).map { UInt8($0 * 3) })
        let response = try device(simulated).challengeResponse(
            slot: 2,
            challenge: Array(HardwareKeyChallenge.padded(challenge)),
            isCancelled: { false }
        )
        XCTAssertEqual(Data(response), SoftwareHardwareKey.response(secret: secret, challenge: challenge))
        XCTAssertEqual(simulated.frames.last?[64], YubiKeyCommand.challengeHMAC2)
    }

    func testWaitsForTouch() throws {
        let simulated = SimulatedYubiKey()
        simulated.secrets[1] = secret
        simulated.touchPolls = 6
        let challenge = Data(repeating: 1, count: 32)
        let response = try device(simulated).challengeResponse(slot: 1, challenge: Array(HardwareKeyChallenge.padded(challenge)), isCancelled: { false })
        XCTAssertEqual(Data(response), SoftwareHardwareKey.response(secret: secret, challenge: challenge))
    }

    func testTouchTimeout() {
        let simulated = SimulatedYubiKey()
        simulated.secrets[2] = secret
        simulated.neverAnswersTouch = true
        XCTAssertThrowsError(try device(simulated).challengeResponse(slot: 2, challenge: Array(HardwareKeyChallenge.padded(Data(count: 32))), isCancelled: { false })) {
            XCTAssertEqual($0 as? VaultError, .hardwareKeyTimedOut)
        }
    }

    func testCancelWhileWaitingForTouch() {
        let simulated = SimulatedYubiKey()
        simulated.secrets[2] = secret
        simulated.touchPolls = 1_000
        var polls = 0
        XCTAssertThrowsError(try device(simulated).challengeResponse(slot: 2, challenge: Array(HardwareKeyChallenge.padded(Data(count: 32))), isCancelled: {
            polls += 1
            return polls > 3
        })) {
            XCTAssertEqual($0 as? VaultError, .hardwareKeyCancelled)
        }
        XCTAssertGreaterThan(simulated.dummyWrites, 0, "cancelling aborts the request on the key")
    }

    func testSlotWithoutChallengeResponse() {
        let simulated = SimulatedYubiKey()
        XCTAssertThrowsError(try device(simulated).challengeResponse(slot: 1, challenge: Array(HardwareKeyChallenge.padded(Data(count: 32))), isCancelled: { false })) {
            XCTAssertEqual($0 as? VaultError, .hardwareKeySlotNotConfigured(slot: 1))
        }
    }

    func testModelNames() {
        let five = YubiKeyStatus(report: [0, 5, 4, 3, 1, 3, 0, 0])
        let four = YubiKeyStatus(report: [0, 4, 3, 7, 1, 3, 0, 0])
        XCTAssertEqual(YubiKeyHIDChallenger.modelName(productID: 0x0407, status: five), "YubiKey 5")
        XCTAssertEqual(YubiKeyHIDChallenger.modelName(productID: 0x0407, status: four), "YubiKey 4")
        XCTAssertEqual(YubiKeyHIDChallenger.modelName(productID: 0x0116, status: four), "YubiKey NEO")
    }
}
