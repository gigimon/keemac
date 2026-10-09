import AppKit
import Foundation

/// Downloads a site's icon for entries saved from the browser. Talks only to the site itself
/// (no third-party icon services), without cookies, and returns a 64×64 PNG.
enum FaviconFetcher {
    static let iconSize: CGFloat = 64
    private static let maximumPageBytes = 512 * 1024
    private static let maximumIconBytes = 1024 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func fetchPNG(forSiteURL siteURL: String) async -> Data? {
        guard let site = URL(string: siteURL), let scheme = site.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = site.host, !host.isEmpty else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = site.port
        origin.path = "/"
        guard let originURL = origin.url else {
            return nil
        }

        var candidates: [URL] = []
        if let page = await download(originURL, limit: maximumPageBytes) {
            let base = page.response.url ?? originURL
            candidates += iconLinks(in: String(decoding: page.data, as: UTF8.self), base: base)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: originURL)?.absoluteURL {
            candidates.append(fallback)
        }

        var seen = Set<URL>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard let icon = await download(candidate, limit: maximumIconBytes),
                  let png = normalizedPNG(from: icon.data) else {
                continue
            }
            return png
        }
        return nil
    }

    /// `<link rel="…icon…" href="…">` in the page, biggest declared size first, Apple touch icons before plain ones.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var found: [(url: URL, score: Int)] = []
        for match in tagPattern.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else {
                continue
            }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains(where: { $0 == "icon" || $0 == "apple-touch-icon" || $0 == "apple-touch-icon-precomposed" }),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            let declaredSize = attribute("sizes", in: tag)
                .flatMap { $0.lowercased().split(separator: "x").first.flatMap { Int($0) } } ?? 0
            let touchBonus = rel.contains("apple-touch-icon") ? 1000 : 0
            found.append((url, touchBonus + declaredSize))
        }
        return found.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.url)
    }

    /// Any decodable image (ICO, PNG, SVG…) drawn into a square PNG.
    static func normalizedPNG(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(iconSize),
                pixelsHigh: Int(iconSize),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current?.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func download(_ url: URL, limit: Int) async -> (data: Data, response: URLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("image/*,text/html;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(limit) else {
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : (data, response)
    }
}
