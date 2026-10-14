import Domain
import Foundation
import IOKit.hid

/// A YubiKey interface opened through IOKit. Like ykpers, the FIDO interface is preferred: macOS asks for
/// Input Monitoring before an app may open a keyboard, and the OTP keyboard interface is one.
final class YubiKeyHIDTransport: YubiKeyTransport {
    private let device: IOHIDDevice

    init(device: IOHIDDevice) throws {
        self.device = device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            if result == kIOReturnNotPermitted {
                throw VaultError.hardwareKeyFailed(details: "macOS didn't allow access to the YubiKey (Privacy & Security → Input Monitoring).")
            }
            throw VaultError.hardwareKeyFailed(details: "Could not open the YubiKey (\(String(format: "0x%08x", result))).")
        }
    }

    deinit {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func readFeatureReport() throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: YubiKeyFrame.reportSize)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &report, &length)
        guard result == kIOReturnSuccess, length == report.count else {
            throw VaultError.hardwareKeyFailed(details: "Reading from the YubiKey failed (\(String(format: "0x%08x", result))).")
        }
        return report
    }

    func writeFeatureReport(_ report: [UInt8]) throws {
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else {
            throw VaultError.hardwareKeyFailed(details: "Writing to the YubiKey failed (\(String(format: "0x%08x", result))).")
        }
    }
}

/// Finds connected YubiKeys over USB HID and answers challenges with their HMAC-SHA1 slots.
public final class YubiKeyHIDChallenger: HardwareKeyChallenging, @unchecked Sendable {
    public static let shared = YubiKeyHIDChallenger()

    static let vendorID = 0x1050
    /// Product IDs with the OTP application (YubiKey 1–2, NEO, 4, 5, Plus).
    static let otpProductIDs: Set<Int> = [0x0010, 0x0110, 0x0111, 0x0114, 0x0116, 0x0401, 0x0403, 0x0405, 0x0407, 0x0410]
    private static let fidoUsagePage = 0xf1d0
    private static let fidoUsage = 0x01

    /// One request at a time: the OTP application keeps a single frame in flight.
    private let lock = NSLock()

    public init() {}

    public func connectedKeys() throws -> [VaultHardwareKey] {
        try lock.withLock {
            try devicesBySerial().flatMap { serial, info in
                [1, 2].compactMap { slot -> VaultHardwareKey? in
                    guard info.status.isConfigured(slot: slot) else {
                        return nil
                    }
                    return VaultHardwareKey(
                        serial: serial,
                        slot: slot,
                        model: Self.modelName(productID: info.productID, status: info.status),
                        requiresTouch: info.status.requiresTouch(slot: slot)
                    )
                }
            }
            .sorted { ($0.serial, -$0.slot) < ($1.serial, -$1.slot) }
        }
    }

    public func challengeResponse(_ challenge: Data, key: VaultHardwareKey, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        try lock.withLock {
            guard let info = try devicesBySerial()[key.serial] else {
                throw VaultError.hardwareKeyNotFound(serial: key.serial)
            }
            let transport = try YubiKeyHIDTransport(device: info.device)
            let yubiKey = YubiKeyDevice(transport: transport)
            let padded = HardwareKeyChallenge.padded(challenge)
            return Data(try yubiKey.challengeResponse(slot: key.slot, challenge: Array(padded), isCancelled: isCancelled))
        }
    }

    private struct DeviceInfo {
        let device: IOHIDDevice
        let productID: Int
        let status: YubiKeyStatus
    }

    /// Each key once (it can show up as a FIDO and a keyboard interface), keyed by serial number.
    private func devicesBySerial() throws -> [UInt32: DeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return [:]
        }
        let candidates = set.compactMap { device -> (IOHIDDevice, Int, Int)? in
            let productID = Self.intProperty(device, kIOHIDProductIDKey)
            let usagePage = Self.intProperty(device, kIOHIDPrimaryUsagePageKey)
            let usage = Self.intProperty(device, kIOHIDPrimaryUsageKey)
            guard Self.otpProductIDs.contains(productID) else {
                return nil
            }
            let isFIDO = usagePage == Self.fidoUsagePage && usage == Self.fidoUsage
            let isKeyboard = usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard
            guard isFIDO || isKeyboard else {
                return nil
            }
            return (device, productID, isFIDO ? 0 : 1)
        }
        // FIDO interfaces first; a key whose FIDO interface answers isn't opened again as a keyboard.
        var result: [UInt32: DeviceInfo] = [:]
        var firstError: Error?
        for (device, productID, _) in candidates.sorted(by: { $0.2 < $1.2 }) {
            let location = Self.intProperty(device, kIOHIDLocationIDKey)
            if result.values.contains(where: { Self.intProperty($0.device, kIOHIDLocationIDKey) == location && location != 0 }) {
                continue
            }
            do {
                let transport = try YubiKeyHIDTransport(device: device)
                let yubiKey = YubiKeyDevice(transport: transport)
                let status = try yubiKey.status()
                guard let serial = try yubiKey.serial() else {
                    continue
                }
                if result[serial] == nil {
                    result[serial] = DeviceInfo(device: device, productID: productID, status: status)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if result.isEmpty, let firstError, !candidates.isEmpty {
            throw firstError
        }
        return result
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    static func modelName(productID: Int, status: YubiKeyStatus) -> String {
        switch productID {
        case 0x0010:
            return "YubiKey \(status.versionMajor)"
        case 0x0110, 0x0111, 0x0114, 0x0116:
            return "YubiKey NEO"
        case 0x0410:
            return "YubiKey Plus"
        default:
            return status.versionMajor >= 5 ? "YubiKey 5" : "YubiKey 4"
        }
    }
}
