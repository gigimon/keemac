import AppKit
@testable import UI
import XCTest

final class QRCodeViewTests: XCTestCase {
    func testPasswordRoundTripsThroughQRCode() throws {
        let password = "Kx9#mP2$vL7!qR4&wZ — пароль"
        let image = try XCTUnwrap(QRCodeView.image(for: password))
        var rect = NSRect(origin: .zero, size: image.size)
        let small = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))

        // Scale up with a quiet zone, as the view shows it, so the detector can read it.
        let side = small.width * 8 + 64
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(small, in: CGRect(x: 32, y: 32, width: small.width * 8, height: small.height * 8))
        let scaled = try XCTUnwrap(context.makeImage())

        XCTAssertEqual(OTPQRCodeReader.qrPayloads(in: scaled), [password])
    }

    func testWiFiPayloads() {
        XCTAssertEqual(WiFiQRPayload.make(networkName: "Home", security: "WPA3", password: "secret"), "WIFI:T:WPA;S:Home;P:secret;;")
        XCTAssertEqual(WiFiQRPayload.make(networkName: "Home", security: "WPA2", password: "secret"), "WIFI:T:WPA;S:Home;P:secret;;")
        XCTAssertEqual(WiFiQRPayload.make(networkName: "Old", security: "WEP", password: "12345"), "WIFI:T:WEP;S:Old;P:12345;;")
        XCTAssertEqual(WiFiQRPayload.make(networkName: "Cafe", security: "None", password: "ignored"), "WIFI:T:nopass;S:Cafe;;")
        XCTAssertEqual(
            WiFiQRPayload.make(networkName: #"My;Net,"5G":x"#, security: "WPA2", password: #"a\b;c"#),
            #"WIFI:T:WPA;S:My\;Net\,\"5G\"\:x;P:a\\b\;c;;"#
        )
        XCTAssertNil(WiFiQRPayload.make(networkName: "", security: "WPA2", password: "secret"))
        XCTAssertNil(WiFiQRPayload.make(networkName: "Home", security: "WPA2", password: ""))
    }

    func testRussianJoinStringsAreTranslated() throws {
        let bundle = try XCTUnwrap(UIResources.localizationBundle(for: "ru"))
        XCTAssertEqual(bundle.localizedString(forKey: "Show QR Code to Join the Network", value: nil, table: nil), "Показать QR-код для подключения к сети")
    }
}
