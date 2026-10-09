import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A value as a QR code, black on white so phones read it in dark mode too.
struct QRCodeView: View {
    let value: String
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let image = Self.image(for: value) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Text(L("Too long for a QR code"))
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.6))
                    .frame(width: size, height: size)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
    }

    /// One pixel per module; the view scales it up without smoothing.
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Icon button that shows a secret as a QR code in a popover, for scanning with a phone.
struct QRCodeButton: View {
    let value: String
    /// What the value is, for the caption and VoiceOver ("Password").
    let label: String
    var size: CGFloat = 30
    var iconSize: CGFloat = 13
    /// Replaces "Show <label> as QR Code" when the code is more than the field's value (Wi-Fi join codes).
    var help: String?
    /// Replaces the default line under the code.
    var caption: String?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: iconSize))
        }
        .buttonStyle(KMIconButtonStyle(size: size, cornerRadius: size == 30 ? 8 : 7))
        .iconHelp(help ?? L("Show \(label) as QR Code"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                QRCodeView(value: value)
                    .accessibilityLabel(L("QR code: \(label)"))
                Text(caption ?? L("Scan with your phone’s camera. Anyone who can see the screen can scan it too."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 248)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}

/// The `WIFI:` text phones read to join a network (the format camera apps on iOS and Android understand).
enum WiFiQRPayload {
    /// `security` is the value KeeMac stores: WPA3, WPA2, WEP or None.
    static func make(networkName: String, security: String, password: String) -> String? {
        guard !networkName.isEmpty else {
            return nil
        }
        let type: String
        switch security {
        case "None":
            type = "nopass"
        case "WEP":
            type = "WEP"
        default:
            type = "WPA"
        }
        var payload = "WIFI:T:\(type);S:\(escaped(networkName));"
        if type != "nopass" {
            guard !password.isEmpty else {
                return nil
            }
            payload += "P:\(escaped(password));"
        }
        return payload + ";"
    }

    /// Backslash before the characters the format uses as separators.
    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\;,:\"".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
