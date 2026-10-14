import Domain
import Foundation

/// 8-byte HID feature reports, the way YubiKey's OTP application talks (ykpers' `ykcore.c`).
public protocol YubiKeyTransport: AnyObject {
    func readFeatureReport() throws -> [UInt8]
    func writeFeatureReport(_ report: [UInt8]) throws
}

public enum YubiKeyCommand {
    public static let deviceSerial: UInt8 = 0x10
    public static let challengeHMAC1: UInt8 = 0x30
    public static let challengeHMAC2: UInt8 = 0x38

    public static func challengeHMAC(slot: Int) -> UInt8 {
        slot == 1 ? challengeHMAC1 : challengeHMAC2
    }
}

/// Frame and report layout of the OTP application.
public enum YubiKeyFrame {
    public static let reportSize = 8
    public static let payloadSize = 64
    /// payload (64) + slot (1) + CRC (2) + filler (3), sent as ten 7-byte parts.
    public static let frameSize = 70

    public static let slotWriteFlag: UInt8 = 0x80
    public static let responsePendingFlag: UInt8 = 0x40
    public static let timeoutWaitFlag: UInt8 = 0x20
    public static let timeoutWaitMask: UInt8 = 0x1f
    public static let sequenceMask: UInt8 = 0x1f
    public static let dummyReportWrite: UInt8 = 0x8f
    /// CRC-16 over data followed by its own (complemented) CRC.
    public static let crcOKResidual: UInt16 = 0xf0b8

    /// ISO 13239 CRC-16 without the final complement (`yubikey_crc16`).
    public static func crc16(_ bytes: some Collection<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                let carry = crc & 1
                crc >>= 1
                if carry != 0 {
                    crc ^= 0x8408
                }
            }
        }
        return crc
    }

    /// The reports that send `payload` to `command`; all-zero parts in the middle are skipped like ykpers does.
    public static func reports(command: UInt8, payload: [UInt8]) -> [[UInt8]] {
        precondition(payload.count <= payloadSize)
        var frame = [UInt8](repeating: 0, count: frameSize)
        frame.replaceSubrange(0..<payload.count, with: payload)
        frame[payloadSize] = command
        let crc = crc16(frame[0..<payloadSize])
        frame[payloadSize + 1] = UInt8(crc & 0xff)
        frame[payloadSize + 2] = UInt8(crc >> 8)

        var reports: [[UInt8]] = []
        let parts = frameSize / (reportSize - 1)
        for sequence in 0..<parts {
            let part = Array(frame[(sequence * 7)..<(sequence * 7 + 7)])
            let isLast = sequence == parts - 1
            if sequence > 0, !isLast, part.allSatisfy({ $0 == 0 }) {
                continue
            }
            reports.append(part + [UInt8(sequence) | slotWriteFlag])
        }
        return reports
    }

    public static var dummyReport: [UInt8] {
        [0, 0, 0, 0, 0, 0, 0, dummyReportWrite]
    }
}

/// Firmware version and slot configuration from the status report.
public struct YubiKeyStatus: Equatable, Sendable {
    public var versionMajor: Int
    public var versionMinor: Int
    public var versionBuild: Int
    public var programmingSequence: Int
    public var touchLevel: UInt16

    public init(report: [UInt8]) {
        versionMajor = Int(report[1])
        versionMinor = Int(report[2])
        versionBuild = Int(report[3])
        programmingSequence = Int(report[4])
        touchLevel = UInt16(report[5]) | UInt16(report[6]) << 8
    }

    public func isConfigured(slot: Int) -> Bool {
        touchLevel & (slot == 1 ? 0x01 : 0x02) != 0
    }

    public func requiresTouch(slot: Int) -> Bool {
        touchLevel & (slot == 1 ? 0x04 : 0x08) != 0
    }
}

/// The OTP application's protocol over a transport: status, serial number, HMAC-SHA1 challenge-response.
public final class YubiKeyDevice {
    private let transport: YubiKeyTransport
    private let sleep: (TimeInterval) -> Void

    public init(transport: YubiKeyTransport, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport
        self.sleep = sleep
    }

    public func status() throws -> YubiKeyStatus {
        YubiKeyStatus(report: try transport.readFeatureReport())
    }

    /// The factory serial number (big endian, unlike everything else); nil when reading it is disabled.
    public func serial() throws -> UInt32? {
        try write(command: YubiKeyCommand.deviceSerial, payload: [])
        guard let bytes = try? readResponse(length: 4, mayBlock: false, isCancelled: { false }) else {
            return nil
        }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Sends a challenge (already padded to 64 bytes) and waits for the 20-byte HMAC-SHA1 response,
    /// up to the slot's own touch timeout (~15 s).
    public func challengeResponse(slot: Int, challenge: [UInt8], isCancelled: @escaping () -> Bool) throws -> [UInt8] {
        try write(command: YubiKeyCommand.challengeHMAC(slot: slot), payload: challenge)
        return try readResponse(length: 20, mayBlock: true, isCancelled: isCancelled, slot: slot)
    }

    private func write(command: UInt8, payload: [UInt8]) throws {
        for report in YubiKeyFrame.reports(command: command, payload: payload) {
            try waitUntilWriteFlagCleared()
            try transport.writeFeatureReport(report)
        }
    }

    private func waitUntilWriteFlagCleared() throws {
        var waited: TimeInterval = 0
        var interval: TimeInterval = 0.001
        while waited < 1.15 {
            sleep(interval)
            waited += interval
            interval = min(interval * 2, 0.5)
            let report = try transport.readFeatureReport()
            if report[7] & YubiKeyFrame.slotWriteFlag == 0 {
                return
            }
        }
        throw VaultError.hardwareKeyFailed(details: "The YubiKey didn't accept the request.")
    }

    private func readResponse(length: Int, mayBlock: Bool, isCancelled: () -> Bool, slot: Int = 0) throws -> [UInt8] {
        let first = try waitForPendingResponse(mayBlock: mayBlock, isCancelled: isCancelled, slot: slot)
        var data = Array(first[0..<7])
        let limit = ((length + 2 + 6) / 7) * 7
        while true {
            let report = try transport.readFeatureReport()
            let status = report[7]
            guard status & YubiKeyFrame.responsePendingFlag != 0 else {
                try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
                throw VaultError.hardwareKeyFailed(details: "The response was cut short.")
            }
            if status & YubiKeyFrame.sequenceMask == 0 {
                break
            }
            data += report[0..<7]
            guard data.count <= limit else {
                try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
                throw VaultError.hardwareKeyFailed(details: "The response is too long.")
            }
        }
        try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
        guard data.count == limit, YubiKeyFrame.crc16(data[0..<(length + 2)]) == YubiKeyFrame.crcOKResidual else {
            throw VaultError.hardwareKeyFailed(details: "The response checksum is wrong.")
        }
        return Array(data[0..<length])
    }

    /// Polls until the key sets the "response pending" flag. A slot that waits for a touch says so
    /// with the timeout flag; a slot that isn't set up for challenge-response never answers.
    private func waitForPendingResponse(mayBlock: Bool, isCancelled: () -> Bool, slot: Int) throws -> [UInt8] {
        var waited: TimeInterval = 0
        var interval: TimeInterval = 0.001
        var limit: TimeInterval = 1
        var waitingForTouch = false
        while waited < limit {
            if isCancelled() {
                try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
                throw VaultError.hardwareKeyCancelled
            }
            sleep(interval)
            waited += interval
            interval = min(interval * 2, waitingForTouch ? 0.1 : 0.5)
            let report = try transport.readFeatureReport()
            let status = report[7]
            if status & YubiKeyFrame.responsePendingFlag != 0 {
                return report
            }
            if status & YubiKeyFrame.timeoutWaitFlag != 0 {
                guard mayBlock else {
                    try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
                    throw VaultError.hardwareKeyTimedOut
                }
                if !waitingForTouch {
                    waitingForTouch = true
                    limit += 256
                }
            } else if waitingForTouch {
                // The key stopped waiting: its own touch timeout ran out.
                throw VaultError.hardwareKeyTimedOut
            }
        }
        try? transport.writeFeatureReport(YubiKeyFrame.dummyReport)
        if waitingForTouch {
            throw VaultError.hardwareKeyTimedOut
        }
        throw slot == 0 ? VaultError.hardwareKeyFailed(details: "No response.") : VaultError.hardwareKeySlotNotConfigured(slot: slot)
    }
}
