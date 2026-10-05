import Foundation

/// The palette's Store screen: one search in flight, and what each install it started is doing.
@MainActor
@Observable
final class ExtensionStoreSession {
    enum Status: Equatable {
        case idle
        case searching
        case answered
        case failed(String)
    }

    /// The last answered search; it stays up while the next term resolves, so typing never blanks.
    private(set) var results: [ExtensionListing] = []
    private(set) var status = Status.idle
    private(set) var progress: [ExtensionListing.ID: ExtensionInstaller.Progress] = [:]
    private(set) var failures: [ExtensionListing.ID: String] = [:]
    @ObservationIgnored private var term = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let client: ExtensionStoreClient

    /// Every keystroke would otherwise be a request to someone else's API.
    private static let debounce = Duration.milliseconds(350)

    init(client: ExtensionStoreClient = ExtensionStoreClient()) {
        self.client = client
    }

    func search(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != self.term else { return }
        self.term = term
        task?.cancel()
        guard !term.isEmpty else {
            results = []
            status = .idle
            return
        }
        status = .searching
        task = Task { [weak self, client] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.search(term)
                guard !Task.isCancelled else { return }
                self?.results = found
                self?.status = .answered
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Installs keep running and reporting after the screen closes; only the search is dropped.
    func reset() {
        task?.cancel()
        task = nil
        term = ""
        results = []
        status = .idle
        failures = [:]
    }

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
