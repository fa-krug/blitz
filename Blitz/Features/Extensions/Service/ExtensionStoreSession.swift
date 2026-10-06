import Foundation

/// The palette's Store screen: one listing in flight, its detail page, and the installs it began.
@MainActor
@Observable
final class ExtensionStoreSession {
    enum Status: Equatable {
        case idle
        case searching
        case answered
        case failed(String)
    }

    /// One extension's store page, filled in as its lookup and README land.
    struct Detail: Equatable {
        let listing: ExtensionListing
        /// The row the list lands back on when the page closes.
        let returnSelection: Int
        /// The lookup's copy, the only one that carries screenshots and a changelog.
        var full: ExtensionListing?
        var readme: String?
        var isLoading = true

        var shown: ExtensionListing { full ?? listing }
    }

    /// Both endpoints serve ten a page, whatever `per_page` asks for.
    static let pageSize = 10

    /// The last answered pages; they stay up while the next term resolves, so typing never blanks.
    private(set) var results: [ExtensionListing] = []
    private(set) var status = Status.idle
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var detail: Detail?
    private(set) var progress: [ExtensionListing.ID: ExtensionInstaller.Progress] = [:]
    private(set) var failures: [ExtensionListing.ID: String] = [:]
    /// Nil until something is asked for; empty is the popular listing.
    @ObservationIgnored private var term: String?
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var seen = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private let client: ExtensionStoreClient

    /// Every keystroke would otherwise be a request to someone else's API.
    private static let debounce = Duration.milliseconds(350)

    init(client: ExtensionStoreClient = ExtensionStoreClient()) {
        self.client = client
    }

    /// An empty query browses what is popular; a new term also closes any open detail page.
    func search(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != self.term else { return }
        self.term = term
        task?.cancel()
        closeDetailPage()
        page = 0
        seen = 0
        hasMore = false
        isLoadingMore = false
        status = .searching
        task = Task { [weak self, client] in
            if !term.isEmpty { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            do {
                let first = try await client.listings(matching: term, page: 1)
                guard !Task.isCancelled else { return }
                self?.accept(first, page: 1)
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// `index` is a row just reached, by scrolling or by the keyboard.
    func loadMore(reaching index: Int) {
        let pagination = ExtensionPagination(hasMore: hasMore, pageSize: Self.pageSize, handler: nil)
        guard hasMore, !isLoadingMore, status == .answered, let term,
            index >= pagination.triggerIndex(itemCount: results.count)
        else { return }
        isLoadingMore = true
        let next = page + 1
        task = Task { [weak self, client] in
            let found = try? await client.listings(matching: term, page: next)
            guard !Task.isCancelled, let self else { return }
            isLoadingMore = false
            // A failed page keeps `hasMore`, so reaching the end again retries it.
            guard let found else { return }
            accept(found, page: next)
        }
    }

    private func accept(_ found: ExtensionStoreResponse.Page, page: Int) {
        let isFirst = page == 1
        self.page = page
        seen = (isFirst ? 0 : seen) + found.entryCount
        hasMore = found.hasMore(afterSeeing: seen)
        // The order is live, so a later page can repeat an entry an earlier one already showed.
        let known = isFirst ? [] : Set(results.map(\.id))
        let fresh = found.listings.filter { !known.contains($0.id) }
        results = isFirst ? fresh : results + fresh
        status = .answered
    }

    /// Installs keep running and reporting after the screen closes; only the listing is dropped.
    func reset() {
        task?.cancel()
        task = nil
        closeDetailPage()
        term = nil
        page = 0
        seen = 0
        results = []
        hasMore = false
        isLoadingMore = false
        status = .idle
        failures = [:]
    }

    // MARK: - Detail

    func showDetail(_ listing: ExtensionListing, returning selection: Int) {
        detailTask?.cancel()
        detail = Detail(listing: listing, returnSelection: selection)
        detailTask = Task { [weak self, client] in
            async let lookup = Self.lookup(listing, client: client)
            async let readme = Self.readme(listing, client: client)
            let (full, text) = await (lookup, readme)
            guard !Task.isCancelled, self?.detail?.listing.id == listing.id else { return }
            self?.detail?.full = full
            self?.detail?.readme = text
            self?.detail?.isLoading = false
        }
    }

    /// The row the list should land back on, or nil when no page was open.
    func closeDetail() -> Int? {
        guard let selection = detail?.returnSelection else { return nil }
        closeDetailPage()
        return selection
    }

    private func closeDetailPage() {
        detailTask?.cancel()
        detailTask = nil
        detail = nil
    }

    private nonisolated static func lookup(
        _ listing: ExtensionListing, client: ExtensionStoreClient
    ) async -> ExtensionListing? {
        guard let handle = listing.handle else { return nil }
        return try? await client.lookup(handle: handle, name: listing.name)
    }

    private nonisolated static func readme(
        _ listing: ExtensionListing, client: ExtensionStoreClient
    ) async -> String? {
        guard let url = listing.readmeURL, let text = try? await client.readme(url) else {
            return nil
        }
        let base = listing.readmeAssetsURL ?? url.deletingLastPathComponent()
        return ExtensionStoreReadme.resolvingRelativeImages(in: text, base: base)
    }

    // MARK: - Installs

    func isInstalling(_ listing: ExtensionListing) -> Bool { progress[listing.id] != nil }

    /// False when it failed, or was already underway; the row then says which.
    func install(_ listing: ExtensionListing, using manager: ExtensionManager) async -> Bool {
        guard !isInstalling(listing) else { return false }
        failures[listing.id] = nil
        progress[listing.id] = .downloading
        defer { progress[listing.id] = nil }
        do {
            try await manager.install(listing) { [weak self] step in
                Task { @MainActor in
                    // A step can land after the install ended; it must not bring the spinner back.
                    guard self?.progress[listing.id] != nil else { return }
                    self?.progress[listing.id] = step
                }
            }
            return true
        } catch {
            failures[listing.id] = error.localizedDescription
            return false
        }
    }
}
