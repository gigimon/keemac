import AppKit
import UniformTypeIdentifiers
import Vision

/// A one-time password found in a QR code.
struct OTPQRCode: Identifiable, Equatable {
    let uri: String
    let issuer: String?
    let account: String?

    var id: String { uri }

    /// "GitHub · anna@example.com"
    var label: String {
        [issuer, account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Parses `otpauth://totp|hotp|steam/Issuer:account?secret=…&issuer=…`; nil for anything else.
    init?(uri: String) {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              ["totp", "hotp", "steam"].contains(components.host?.lowercased() ?? ""),
              components.queryItems?.contains(where: { $0.name.lowercased() == "secret" && !($0.value ?? "").isEmpty }) == true else {
            return nil
        }
        self.uri = uri
        let label = String(components.path.drop(while: { $0 == "/" }))
        let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let queryIssuer = components.queryItems?.first { $0.name.lowercased() == "issuer" }?.value
        issuer = queryIssuer ?? (parts.count == 2 ? parts[0] : nil)
        account = parts.last.flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum OTPQRCodeReader {
    enum Outcome {
        case found([OTPQRCode])
        /// `otpauth-migration://` export with several accounts.
        case authenticatorExport
        case nothingFound
    }

    static func read(_ image: CGImage) -> Outcome {
        let payloads = qrPayloads(in: image)
        let codes = payloads.compactMap(OTPQRCode.init(uri:))
        if !codes.isEmpty {
            return .found(codes)
        }
        if payloads.contains(where: { $0.lowercased().hasPrefix("otpauth-migration://") }) {
            return .authenticatorExport
        }
        return .nothingFound
    }

    /// Decoded text of every QR code in the image; runs on-device.
    static func qrPayloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }

    static func image(from data: Data) -> CGImage? {
        NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func imageFromPasteboard() -> CGImage? {
        guard let image = NSImage(pasteboard: .general) else {
            return nil
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static var pasteboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    @MainActor
    static func chooseImage() -> CGImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.title = L("Choose QR Code Image")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else {
            return nil
        }
        return image(from: data)
    }
}

/// Lets the user select the QR code on screen with the system screenshot tool (`screencapture -i`).
/// macOS attributes the capture to KeeMac, so it needs the Screen Recording permission.
@MainActor
enum ScreenQRCodeScanner {
    enum Outcome {
        case image(CGImage)
        case cancelled
        /// Permission was requested; macOS applies it only after KeeMac is reopened.
        case needsPermission
    }

    static func scan(completion: @escaping @MainActor (Outcome) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            completion(.needsPermission)
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("qr.png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            completion(.cancelled)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Interactive selection (Space switches to window mode), no sound, PNG.
        process.arguments = ["-i", "-x", "-t", "png", fileURL.path]
        process.terminationHandler = { _ in
            // The image holds the TOTP secret: read it and delete it right away.
            let data = try? Data(contentsOf: fileURL)
            try? FileManager.default.removeItem(at: directory)
            Task { @MainActor in
                if let image = data.flatMap(OTPQRCodeReader.image(from:)) {
                    completion(.image(image))
                } else {
                    completion(.cancelled)
                }
            }
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(.cancelled)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
