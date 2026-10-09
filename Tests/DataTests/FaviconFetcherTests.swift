import AppKit
@testable import UI
import XCTest

final class FaviconFetcherTests: XCTestCase {
    func testFindsIconLinksBestFirst() throws {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/site.css">
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <link href='https://cdn.example.com/icon-32.png' rel='icon' sizes='32x32'>
        <link rel="apple-touch-icon" href="touch.png">
        <LINK REL="shortcut icon" HREF="/legacy.ico">
        </head></html>
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/account/"))
        let links = FaviconFetcher.iconLinks(in: html, base: base).map(\.absoluteString)
        XCTAssertEqual(links, [
            "https://example.com/account/touch.png",
            "https://cdn.example.com/icon-32.png",
            "https://example.com/favicon-16.png",
            "https://example.com/legacy.ico"
        ])
    }

    func testIgnoresNonHTTPIcons() throws {
        let html = #"<link rel="icon" href="data:image/png;base64,AAAA"><link rel="icon" href="javascript:alert(1)">"#
        let links = FaviconFetcher.iconLinks(in: html, base: try XCTUnwrap(URL(string: "https://example.com/")))
        XCTAssertTrue(links.isEmpty)
    }

    func testNormalizesToSquarePNG() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let png = try XCTUnwrap(FaviconFetcher.normalizedPNG(from: source))
        let result = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(result.pixelsWide, 64)
        XCTAssertEqual(result.pixelsHigh, 64)
        XCTAssertNil(FaviconFetcher.normalizedPNG(from: Data("<html>not an image</html>".utf8)))
    }
}
