import AppKit

/// Downloads a website quicklink's icon as a square PNG. docs/features/quicklinks.md#favicons
enum QuicklinkFaviconFetcher {
    /// Private and cacheless, so the PNG in the quicklinks database stays the only copy on disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    /// Nil when the link isn't a website or nothing the site offers decodes as an image.
    static func fetch(for link: String) async -> Data? {
        guard let site = QuicklinkFavicon.siteURL(for: link) else { return nil }
        var candidates: [URL] = []
        if let page = await download(site, limit: nil) {
            candidates = await Task.detached(priority: .userInitiated) {
                let head = page.data.prefix(QuicklinkFavicon.maxPageBytes)
                // The cut can split a character, which a strict UTF-8 read would reject outright.
                let html =
                    String(bytes: head, encoding: .utf8)
                    ?? String(bytes: head, encoding: .isoLatin1) ?? ""
                return QuicklinkFavicon.candidates(inHTML: html, baseURL: page.url)
            }.value
        }
        candidates.append(QuicklinkFavicon.conventionalURL(for: site))
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            guard let image = await download(candidate, limit: QuicklinkFavicon.maxImageBytes)
            else { continue }
            let png = await Task.detached(priority: .userInitiated) {
                Self.rasterized(image.data)
            }.value
            if let png { return png }
        }
        return nil
    }

    /// The URL is where redirects ended, which is what a page's relative `href`s resolve against.
    private static func download(_ url: URL, limit: Int?) async -> (data: Data, url: URL)? {
        guard let (data, response) = try? await session.data(from: url),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            !data.isEmpty, data.count <= limit ?? .max
        else { return nil }
        return (data, http.url ?? url)
    }

    /// One fixed square, so an `.ico` holding many sizes or a vector stores one known bitmap.
    private static func rasterized(_ data: Data) -> Data? {
        let side = QuicklinkFavicon.pixelSide
        var proposed = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = NSImage(data: data),
            let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
            source.width > 0, source.height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(side) / CGFloat(max(source.width, source.height))
        let width = CGFloat(source.width) * scale
        let height = CGFloat(source.height) * scale
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(
                x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                width: width, height: height))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }
}
