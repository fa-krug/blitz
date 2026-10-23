import Foundation

@MainActor
@Observable
final class SnippetsStore {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var snippets: [StoredSnippet] = []
    private(set) var state: State = .idle
    private(set) var issues: [SnippetRepository.Issue] = []
    private(set) var operationError: String?

    private(set) var snippetsDirectory: URL
    var onSnapshot: ((SnippetRepository.Snapshot) -> Void)?

    private var repository: SnippetRepository
    @ObservationIgnored private var folderMonitor: SnippetFolderMonitor?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var watcherRetryTask: Task<Void, Never>?
    private var generation = 0
    private var isStarted = false

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
    }

    isolated deinit {
        reloadTask?.cancel()
        watcherRetryTask?.cancel()
        folderMonitor?.stop()
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reload(showLoadingState: true)
    }

    func stop() {
        isStarted = false
        generation &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        folderMonitor?.stop()
        folderMonitor = nil
    }

    /// Moves to another folder; a running store stops, swaps, and loads the new one.
    func relocate(to repository: SnippetRepository) async {
        guard repository.snippetsDirectory != snippetsDirectory else { return }
        let wasStarted = isStarted
        stop()
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
        // Emptied first, so a folder that fails to load leaves no old snippet expanding.
        if !snippets.isEmpty || !issues.isEmpty {
            snippets = []
            issues = []
            onSnapshot?(SnippetRepository.Snapshot(records: [], issues: []))
        }
        guard wasStarted else { return }
        await start()
    }

    func retry() {
        guard isStarted else { return }
        scheduleReload(after: .zero, showLoadingState: true)
    }

    @discardableResult
    func create(_ snippet: Snippet) async throws -> StoredSnippet {
        let record = try await performMutation { try $0.create(snippet) }
        guard isStarted else { return record }
        var records = snippets.filter { $0.id != record.id }
        records.append(record)
        publishLocal(records: records)
        scheduleReload(after: .zero)
        return record
    }

    @discardableResult
    func importSnippets(_ imported: [Snippet]) async throws -> [StoredSnippet] {
        guard !imported.isEmpty else { return [] }
        let created = try await performMutation { try $0.create(imported) }
        guard isStarted else { return created }
        let createdIDs = Set(created.map(\.id))
        publishLocal(records: snippets.filter { !createdIDs.contains($0.id) } + created)
        scheduleReload(after: .zero)
        return created
    }

    @discardableResult
    func save(_ record: StoredSnippet) async throws -> StoredSnippet {
        let saved = try await performMutation {
            try $0.save(
                record.snippet,
                fileURL: record.fileURL,
                expectedRevision: record.sourceRevision)
        }
        guard isStarted else { return saved }
        var records = snippets.filter { $0.id != saved.id }
        records.append(saved)
        publishLocal(records: records)
        scheduleReload(after: .zero)
        return saved
    }

    func delete(id: StoredSnippet.ID) async throws {
        guard let record = record(id: id) else {
            throw SnippetRepository.RepositoryError.fileNotFound(URL(fileURLWithPath: id))
        }
        try await performMutation {
            try $0.delete(
                fileURL: record.fileURL,
                expectedRevision: record.sourceRevision)
        }
        guard isStarted else { return }
        publishLocal(records: snippets.filter { $0.id != id })
        scheduleReload(after: .zero)
    }

    /// A new file, so the original keeps its identity and the shortcut keyed to it.
    @discardableResult
    func duplicate(id: StoredSnippet.ID) async throws -> StoredSnippet {
        guard let record = record(id: id) else {
            throw SnippetRepository.RepositoryError.fileNotFound(URL(fileURLWithPath: id))
        }
        return try await create(record.snippet.duplicate(takenNames: snippets.map(\.snippet.name)))
    }

    func record(id: StoredSnippet.ID) -> StoredSnippet? {
        snippets.first(where: { $0.id == id })
    }

    private enum RepositoryResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(SnippetRepository.RepositoryError)
    }

    private func performMutation<Value: Sendable>(
        _ operation: @escaping @Sendable (SnippetRepository) throws -> Value
    ) async throws -> Value {
        reloadTask?.cancel()
        reloadTask = nil
        generation &+= 1
        let repository = repository

        let result = await Task.detached(priority: .utility) {
            do {
                return RepositoryResult.success(try operation(repository))
            } catch let error as SnippetRepository.RepositoryError {
                return RepositoryResult.failure(error)
            } catch {
                return RepositoryResult.failure(
                    .io(
                        fileURL: repository.snippetsDirectory,
                        message: error.localizedDescription))
            }
        }.value

        switch result {
        case .success(let value):
            operationError = nil
            return value
        case .failure(let error):
            operationError = error.localizedDescription
            throw error
        }
    }

    private func reload(showLoadingState: Bool) async {
        guard isStarted else { return }
        generation &+= 1
        let loadGeneration = generation
        if showLoadingState { state = .loading }
        let repository = repository

        let result = await Task.detached(priority: .utility) {
            do {
                return RepositoryResult.success(try repository.load())
            } catch let error as SnippetRepository.RepositoryError {
                return RepositoryResult.failure(error)
            } catch {
                return RepositoryResult.failure(
                    .io(
                        fileURL: repository.snippetsDirectory,
                        message: error.localizedDescription))
            }
        }.value

        guard isStarted, loadGeneration == generation else { return }
        switch result {
        case .success(let snapshot):
            apply(snapshot)
        case .failure(let error):
            state = .failed(error.localizedDescription)
            scheduleWatcherRetry()
        }
    }

    private func publishLocal(records: [StoredSnippet]) {
        apply(
            SnippetRepository.Snapshot(
                records: records.sorted(by: recordOrder),
                issues: issues))
    }

    private func apply(_ snapshot: SnippetRepository.Snapshot) {
        guard isStarted else { return }
        let isUnchanged =
            state == .ready
            && snippets == snapshot.records
            && issues == snapshot.issues
        if !isUnchanged {
            snippets = snapshot.records
            issues = snapshot.issues
            state = .ready
            onSnapshot?(snapshot)
        }
        // Anything written between the load and the arm is caught by one more pass.
        if armMonitor() {
            scheduleReload(after: .milliseconds(150))
        }
    }

    private func scheduleReload(after delay: Duration, showLoadingState: Bool = false) {
        guard isStarted else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, self.isStarted, !Task.isCancelled else { return }
            await self.reload(showLoadingState: showLoadingState)
        }
    }

    private func armMonitor() -> Bool {
        guard isStarted else { return false }
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        guard folderMonitor == nil else { return false }
        folderMonitor = SnippetFolderMonitor(directory: snippetsDirectory) { [weak self] in
            self?.noteFilesystemChange()
        }
        guard folderMonitor != nil else {
            scheduleWatcherRetry()
            return false
        }
        return true
    }

    private func noteFilesystemChange() {
        guard isStarted else { return }
        generation &+= 1
        scheduleReload(after: .milliseconds(150))
    }

    private func scheduleWatcherRetry() {
        guard isStarted, watcherRetryTask == nil else { return }
        watcherRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.isStarted, !Task.isCancelled else { return }
            self.watcherRetryTask = nil
            await self.reload(showLoadingState: false)
        }
    }

    private func recordOrder(_ lhs: StoredSnippet, _ rhs: StoredSnippet) -> Bool {
        let comparison = lhs.snippet.name.localizedCaseInsensitiveCompare(rhs.snippet.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}
