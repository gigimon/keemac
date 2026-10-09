import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
@testable import UI
import XCTest

final class OTPQRCodeTests: XCTestCase {
    private func qrImage(_ texts: [String]) throws -> CGImage {
        let context = CIContext()
        var images: [CIImage] = []
        for text in texts {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            images.append(output)
        }
        // Side by side on a white background with a margin, like a screenshot.
        var canvas = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 420 * images.count + 40, height: 460))
        for (index, image) in images.enumerated() {
            canvas = image.transformed(by: CGAffineTransform(translationX: CGFloat(40 + index * 420), y: 40)).composited(over: canvas)
        }
        return try XCTUnwrap(context.createCGImage(canvas, from: canvas.extent))
    }

    func testParsesIssuerAndAccount() throws {
        let code = try XCTUnwrap(OTPQRCode(uri: "otpauth://totp/GitHub:anna%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"))
        XCTAssertEqual(code.issuer, "GitHub")
        XCTAssertEqual(code.account, "anna@example.com")
        XCTAssertEqual(code.label, "GitHub · anna@example.com")
        XCTAssertNil(OTPQRCode(uri: "otpauth://hotp/Bank?secret=JBSWY3DPEHPK3PXP&counter=1"))
        XCTAssertNil(OTPQRCode(uri: "otpauth://totp/NoSecret"))
        XCTAssertNil(OTPQRCode(uri: "https://example.com"))
    }

    func testReadsOneCodeFromImage() throws {
        let uri = "otpauth://totp/GitHub:anna@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        guard case .found(let codes) = OTPQRCodeReader.read(try qrImage([uri])) else {
            return XCTFail("QR code not found")
        }
        XCTAssertEqual(codes.map(\.uri), [uri])
    }

    func testReadsSeveralCodesAndRejectsOthers() throws {
        let first = "otpauth://totp/A:one?secret=JBSWY3DPEHPK3PXP"
        let second = "otpauth://totp/B:two?secret=KRSXG5DSNFXGOIDB"
        guard case .found(let codes) = OTPQRCodeReader.read(try qrImage([first, second])) else {
            return XCTFail("QR codes not found")
        }
        XCTAssertEqual(Set(codes.map(\.uri)), [first, second])

        guard case .unsupportedHOTP = OTPQRCodeReader.read(try qrImage(["otpauth://hotp/Bank?secret=JBSWY3DPEHPK3PXP&counter=1"])) else {
            return XCTFail("HOTP should be reported")
        }
        guard case .authenticatorExport = OTPQRCodeReader.read(try qrImage(["otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8"])) else {
            return XCTFail("Authenticator export should be reported")
        }
        guard case .nothingFound = OTPQRCodeReader.read(try qrImage(["https://example.com"])) else {
            return XCTFail("Plain URL is not a one-time password")
        }
    }
}
