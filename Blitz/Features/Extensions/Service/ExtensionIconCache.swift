import AppKit
import ImageIO

/// An extension's artwork; docs/features/extensions.md says why it draws smaller.
enum ExtensionIconCache {
    /// Below `IconCache.appIconExtent`; change it only against a rendered strip of icons.
    static let extent: CGFloat = 0.76

    /// `NSCache` is thread-safe but not `Sendable`, so assert the guarantee once here.
    private final class Cache: NSCache<NSString, NSImage>, @unchecked Sendable {}

    /// Fetched row icons, each a fitted ~36 KB bitmap; kept across palette closes like app icons.
    private static let icons: Cache = {
        let cache = Cache()
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    /// Originals, Detail markdown images and store screenshots: far larger, so dropped on close.
    private static let images: Cache = {
        let cache = Cache()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func purgeImages() {
        images.removeAllObjects()
    }

    /// The decoded bitmap's bytes: `size` is in points, which reads a 2× image at a quarter.
    static func decodedCost(of image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh }
        // A vector rep has no pixels of its own; it rasterizes at the 2× it is drawn at.
        guard pixels > 0 else { return Int(image.size.width * image.size.height) * 4 * 4 }
        return pixels * 4
    }

    /// A freshly-decoded, thereafter-immutable `NSImage` is safe to move across the actor boundary.
    private struct Decoded: @unchecked Sendable {
        let image: NSImage?
    }

    // MARK: - Shipped with the extension

    /// Cache-only, so a warm row paints on the same frame.
    static func cached(atPath path: String) -> NSImage? {
        IconCache.cachedArtwork(atPath: path, extent: extent)
    }

    /// Read from the file: `NSWorkspace` would answer a PNG with the generic document icon.
    static func icon(atPath path: String) -> NSImage {
        guard FileManager.default.fileExists(atPath: path) else {
            return IconCache.symbolIcon(named: "puzzlepiece.extension")
        }
        return IconCache.artwork(atPath: path, extent: extent)
    }

    static func loadAsync(atPath path: String) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else {
            return IconCache.symbolIcon(named: "puzzlepiece.extension")
        }
        return await IconCache.loadArtworkAsync(atPath: path, extent: extent)
    }

    /// Never rasterized: fitting flattens a GIF to its first frame.
    static func loadOriginalAsync(atPath path: String) async -> NSImage? {
        let key = originalKey(path)
        if let cached = images.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) {
            Decoded(image: NSImage(contentsOfFile: path))
        }.value
        guard let image = decoded.image else { return nil }
        images.setObject(image, forKey: key, cost: decodedCost(of: image))
        return image
    }

    // MARK: - Carried inline by the extension

    /// Uncached and unfitted: the payload is resident and the extension has sized it.
    static func loadInlineAsync(_ url: URL, palette: [String: String]) async -> NSImage? {
        guard let data = inlineData(url) else { return nil }
        let names = isSVG(url) ? palette : [:]
        return await Task.detached(priority: .userInitiated) {
            Decoded(image: NSImage(data: resolvingPaletteNames(in: data, palette: names)))
        }.value.image
    }

    /// No renderer knows a `raycast-*` colour keyword, so the shape would draw nothing.
    private static func resolvingPaletteNames(in data: Data, palette: [String: String]) -> Data {
        guard let source = String(data: data, encoding: .utf8) else { return data }
        let resolved = rewritingNames(in: source, palette: palette) ?? source
        let rewritten = resolved.replacing(#/(fill|stroke)(\s*=\s*["']|\s*:\s*)transparent\b/#) {
            "\($0.1)\($0.2)none"
        }
        return Data(rewritten.utf8)
    }

    /// Whole names only: `raycast-red` sits inside `raycast-red-invented`.
    private static func rewritingNames(in text: String, palette: [String: String]) -> String? {
        // `.literal`: the default search is Unicode-canonical and costs 3x on a long payload.
        guard text.range(of: paletteNamePrefix, options: .literal) != nil else { return nil }
        var resolved = ""
        var rest = Substring(text)
        while let match = rest.range(of: paletteNamePrefix, options: .literal) {
            let name = rest[match.lowerBound...].prefix { paletteNameCharacters.contains($0) }
            resolved += rest[..<match.lowerBound]
            resolved += palette[String(name)] ?? String(name)
            rest = rest[name.endIndex...]
        }
        return resolved + rest
    }

    private static let paletteNamePrefix = "raycast-"
    private static let paletteNameCharacters = Set("abcdefghijklmnopqrstuvwxyz-")

    /// Case-insensitive, since a media type is: `image/SVG+XML` is a legal spelling.
    private static func isSVG(_ url: URL) -> Bool {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return false }
        return text[..<comma].range(of: "svg", options: .caseInsensitive) != nil
    }

    /// Minus any query: Detail markdown appends Raycast's `?raycast-width=…` hints.
    private static func inlineData(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let payload = String(text[text.index(after: comma)...].prefix { $0 != "?" })
        guard text[..<comma].hasSuffix(";base64") else {
            return payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    // MARK: - Fetched by the extension

    /// A failure caches nothing, so a transient error retries; `asIcon` is off for markdown images.
    static func loadRemoteAsync(_ url: URL, asIcon: Bool = true) async -> NSImage? {
        let key = remoteKey(url, asIcon: asIcon)
        let cache = asIcon ? icons : images
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            Decoded(image: NSImage(data: data))
        }.value
        guard let source = decoded.image else { return nil }
        guard asIcon else {
            cache.setObject(source, forKey: key, cost: decodedCost(of: source))
            return source
        }
        let (icon, cost) = IconCache.fitted(source, to: extent)
        cache.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    /// Downsampled at decode: a store screenshot is ~2000px wide and a strip draws it far smaller.
    static func loadThumbnailAsync(_ url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let key = "thumb:\(Int(maxPixelSize)):\(url.absoluteString)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            Decoded(image: thumbnail(of: data, maxPixelSize: maxPixelSize))
        }.value
        guard let image = decoded.image else { return nil }
        images.setObject(image, forKey: key, cost: decodedCost(of: image))
        return image
    }

    private static func thumbnail(of data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Cacheless, never `URLSession.shared`: an extension names these URLs.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func originalKey(_ path: String) -> NSString { ("raw:" + path) as NSString }
    private static func remoteKey(_ url: URL, asIcon: Bool) -> NSString {
        ((asIcon ? "remote:" : "full:") + url.absoluteString) as NSString
    }
}
