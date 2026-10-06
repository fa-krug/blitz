import Foundation

/// Someone else's endpoint, so every field an install doesn't need is optional.
enum ExtensionStoreResponse {
    /// The endpoint the store's own site searches with; unofficial, so it can change unannounced.
    static func searchURL(query: String, page: Int) -> URL? {
        var components = URLComponents(string: "https://www.raycast.com/frontend_api/extensions/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            // Case-sensitive: any other spelling returns only extensions listing no platforms.
            URLQueryItem(name: "platform", value: "macOS")
        ]
        return components?.url
    }

    /// The store's own front page, already ordered by popularity; a search ignores every sort.
    static func popularURL(page: Int) -> URL? {
        var components = URLComponents(string: "https://www.raycast.com/frontend_api/extensions")
        components?.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "platform", value: "macOS")
        ]
        return components?.url
    }

    /// One extension by the handle and name its manifest carries.
    static func lookupURL(handle: String, name: String) -> URL? {
        guard !handle.isEmpty, !name.isEmpty else { return nil }
        return URL(string: "https://www.raycast.com/api/v1/extensions")?
            .appending(path: handle)
            .appending(path: name)
    }

    /// One page of a listing, and enough to tell whether the store holds more past it.
    struct Page: Sendable {
        let listings: [ExtensionListing]
        /// Entries the page carried, installable or not, which is what `total` counts.
        let entryCount: Int
        let total: Int?

        /// `seen` counts every entry of every page so far, this one included.
        func hasMore(afterSeeing seen: Int) -> Bool {
            guard entryCount > 0 else { return false }
            return total.map { seen < $0 } ?? true
        }
    }

    private struct StorePayload: Decodable {
        let data: [StoreEntry]
        let total: Int?

        enum CodingKeys: String, CodingKey {
            case data
            case total = "total_results"
        }
    }

    private struct StoreEntry: Decodable {
        let id: String
        let name: String
        let title: String?
        let description: String?
        let author: Person?
        let owner: Person?
        let icons: Icons?
        let commands: [Command]?
        let downloadCount: Int?
        let downloadURL: String?
        let commitSHA: String?
        let status: String?
        let categories: [String]?
        let updatedAt: Double?
        let readmeURL: String?
        let readmeAssetsPath: String?
        let metadata: [String]?
        let changelog: Changelog?

        struct Person: Decodable {
            let name: String?
            let handle: String?
        }
        struct Icons: Decodable {
            let light: String?
            let dark: String?
        }
        struct Command: Decodable {
            let name: String?
        }
        struct Changelog: Decodable {
            let versions: [Version]?

            struct Version: Decodable {
                let title: String?
                let date: String?
                let markdown: String?
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, title, description, author, owner, icons, commands, status
            case categories, metadata, changelog
            case downloadCount = "download_count"
            case downloadURL = "download_url"
            case commitSHA = "commit_sha"
            case updatedAt = "updated_at"
            case readmeURL = "readme_url"
            case readmeAssetsPath = "readme_assets_path"
        }

        /// Only what an install needs may fail the entry; a reshaped extra reads as absent.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
            commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            author = try? container.decodeIfPresent(Person.self, forKey: .author)
            owner = try? container.decodeIfPresent(Person.self, forKey: .owner)
            icons = try? container.decodeIfPresent(Icons.self, forKey: .icons)
            commands = try? container.decodeIfPresent([Command].self, forKey: .commands)
            downloadCount = try? container.decodeIfPresent(Int.self, forKey: .downloadCount)
            categories = try? container.decodeIfPresent([String].self, forKey: .categories)
            updatedAt = try? container.decodeIfPresent(Double.self, forKey: .updatedAt)
            readmeURL = try? container.decodeIfPresent(String.self, forKey: .readmeURL)
            readmeAssetsPath = try? container.decodeIfPresent(String.self, forKey: .readmeAssetsPath)
            metadata = try? container.decodeIfPresent([String].self, forKey: .metadata)
            changelog = try? container.decodeIfPresent(Changelog.self, forKey: .changelog)
        }
    }

    static func parseStore(_ data: Data) throws -> [ExtensionListing] {
        try parsePage(data).listings
    }

    static func parsePage(_ data: Data) throws -> Page {
        let payload = try JSONDecoder().decode(StorePayload.self, from: data)
        return Page(
            listings: payload.data.compactMap(listing(from:)), entryCount: payload.data.count,
            total: payload.total)
    }

    /// A lookup answers with the entry itself, not a page of them.
    static func parseEntry(_ data: Data) throws -> ExtensionListing? {
        listing(from: try JSONDecoder().decode(StoreEntry.self, from: data))
    }

    /// An entry without a usable download is dropped, not listed as uninstallable.
    private static func listing(from entry: StoreEntry) -> ExtensionListing? {
        // A de-listed extension is still returned by search; it can't be downloaded any more.
        guard entry.status == nil || entry.status == "active" else { return nil }
        guard let raw = entry.downloadURL, let url = URL(string: raw) else { return nil }
        return ExtensionListing(
            id: entry.id,
            name: entry.name,
            title: entry.title ?? entry.name,
            summary: entry.description ?? "",
            author: entry.author?.name ?? entry.author?.handle ?? "",
            handle: entry.owner?.handle ?? entry.author?.handle,
            lightIconURL: entry.icons?.light.flatMap(URL.init(string:)),
            darkIconURL: entry.icons?.dark.flatMap(URL.init(string:)),
            commandCount: entry.commands?.count ?? 0,
            downloadCount: entry.downloadCount,
            downloadURL: url,
            commitSHA: entry.commitSHA,
            categories: entry.categories ?? [],
            updatedAt: entry.updatedAt.map(Date.init(timeIntervalSince1970:)),
            readmeURL: entry.readmeURL.flatMap(URL.init(string:)).flatMap(ExtensionStoreReadme.rawURL),
            readmeAssetsURL: entry.readmeAssetsPath.flatMap(ExtensionStoreReadme.assetsBase),
            screenshotURLs: (entry.metadata ?? []).compactMap(URL.init(string:)),
            latestChange: latestChange(entry.changelog))
    }

    /// Newest first, as the store writes it; a version with no notes says nothing worth showing.
    private static func latestChange(_ changelog: StoreEntry.Changelog?) -> ExtensionListing.Change? {
        guard let version = changelog?.versions?.first,
            let markdown = version.markdown?.trimmingCharacters(in: .whitespacesAndNewlines),
            !markdown.isEmpty
        else { return nil }
        return ExtensionListing.Change(title: version.title ?? "", date: version.date, markdown: markdown)
    }
}

enum ExtensionStoreError: LocalizedError {
    case malformedResponse
    case rejected(String)
    case downloadFailed(String)
    case noPackageManager
    case noNode
    case buildFailed(String)
    case notAnExtension

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "The server answered with something this version doesn't understand."
        case .rejected(let message):
            return message
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .noPackageManager:
            return
                "No package manager was found. Install pnpm, npm, Yarn or Bun, or add the folder "
                + "it lives in to Custom search paths."
        case .noNode:
            return
                "Node wasn't found. Install Node.js, add the folder it lives in to Custom search "
                + "paths, or install this extension from the Raycast Store instead."
        case .buildFailed(let output):
            return "The extension didn't build: \(output)"
        case .notAnExtension:
            return "That download didn't contain a Raycast extension."
        }
    }
}
