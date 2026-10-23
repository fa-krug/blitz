import Foundation
import Synchronization

/// One JSON file per extension, read whole on first use; writes are debounced and land off-main.
@MainActor
final class ExtensionStorage {
    private struct Store: Codable, Sendable {
        var localStorage: [String: StoredValue] = [:]
        var caches: [String: [String: String]] = [:]
        var preferences: [String: StoredValue] = [:]
        /// A search-bar dropdown's `storeValue` pick — host UI state, so not `LocalStorage`.
        var accessoryValues: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case localStorage, caches, preferences, accessoryValues
        }

        init() {}

        /// Per section: an absent key must not fail a decode, which resets the file and API keys.
        init(from decoder: Decoder) throws {
            let store = try decoder.container(keyedBy: CodingKeys.self)
            localStorage =
                try store.decodeIfPresent([String: StoredValue].self, forKey: .localStorage) ?? [:]
            caches =
                try store.decodeIfPresent([String: [String: String]].self, forKey: .caches) ?? [:]
            preferences =
                try store.decodeIfPresent([String: StoredValue].self, forKey: .preferences) ?? [:]
            accessoryValues =
                try store.decodeIfPresent([String: String].self, forKey: .accessoryValues) ?? [:]
        }
    }

    /// `LocalStorage` accepts strings, numbers and booleans and must return them with their type.
    enum StoredValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var jsonValue: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .bool(let value): return value
            }
        }

        init?(renderValue: RenderValue) {
            switch renderValue {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            default: return nil
            }
        }

        init(preference: ExtensionPreferenceValue) {
            switch preference {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            case .application(let path): self = .string(path)
            }
        }

        var preferenceValue: ExtensionPreferenceValue {
            switch self {
            case .string(let value): return .string(value)
            case .number(let value): return .number(value)
            case .bool(let value): return .bool(value)
            }
        }
    }

    private let directory: URL
    private var stores: [String: Store] = [:]
    /// Writes are coalesced, so a busy `Cache` doesn't hit the disk per key.
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private let disk = ExtensionStorageDisk()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - LocalStorage

    func localStorageValue(extension name: String, key: String) -> StoredValue? {
        store(for: name).localStorage[key]
    }

    func allLocalStorage(extension name: String) -> [String: StoredValue] {
        store(for: name).localStorage
    }

    func setLocalStorage(extension name: String, key: String, value: StoredValue) {
        mutate(name) { $0.localStorage[key] = value }
    }

    func removeLocalStorage(extension name: String, key: String) {
        mutate(name) { $0.localStorage.removeValue(forKey: key) }
    }

    func clearLocalStorage(extension name: String) {
        mutate(name) { $0.localStorage.removeAll() }
    }

    // MARK: - Search-bar dropdowns

    func accessoryValue(extension name: String, key: String) -> String? {
        store(for: name).accessoryValues[key]
    }

    func setAccessoryValue(extension name: String, key: String, value: String) {
        mutate(name) { $0.accessoryValues[key] = value }
    }

    // MARK: - Cache

    func caches(extension name: String) -> [String: [String: String]] {
        store(for: name).caches
    }

    /// `nil` removes the key; a `nil` key clears the namespace.
    func setCache(extension name: String, namespace: String, key: String?, value: String?) {
        mutate(name) { store in
            guard let key else {
                store.caches[namespace] = [:]
                return
            }
            var bucket = store.caches[namespace] ?? [:]
            if let value { bucket[key] = value } else { bucket.removeValue(forKey: key) }
            store.caches[namespace] = bucket
        }
    }

    func clearCache(extension name: String, namespace: String) {
        mutate(name) { $0.caches[namespace] = [:] }
    }

    // MARK: - Preferences

    func preference(extension name: String, key: String) -> ExtensionPreferenceValue? {
        store(for: name).preferences[key]?.preferenceValue
    }

    func setPreference(extension name: String, key: String, value: ExtensionPreferenceValue?) {
        mutate(name) { store in
            if let value {
                store.preferences[key] = StoredValue(preference: value)
            } else {
                store.preferences.removeValue(forKey: key)
            }
        }
    }

    /// Manifest defaults overlaid with the user's — what `getPreferenceValues()` sees.
    func resolvedPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [String: ExtensionPreferenceValue] {
        var resolved: [String: ExtensionPreferenceValue] = [:]
        for schema in schemas {
            resolved[schema.name] = schema.runtimeValue(preference(extension: name, key: schema.name))
        }
        return resolved
    }

    /// A command with an unset required preference must not run.
    func missingRequiredPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [ExtensionPreferenceSchema] {
        schemas.filter { schema in
            guard schema.required else { return false }
            let value = preference(extension: name, key: schema.name) ?? schema.effectiveDefault
            if case .string(let text) = value { return text.isEmpty }
            return false
        }
    }

    /// Synchronous, so a reinstall's first read cannot find the file a queued write would leave.
    func removeAll(extension name: String) {
        stores.removeValue(forKey: name)
        dirty.remove(name)
        disk.enqueue([fileURL(for: name): .remove])
        disk.drain()
    }

    // MARK: - Persistence

    private func store(for name: String) -> Store {
        if let existing = stores[name] { return existing }
        let loaded =
            (try? Data(contentsOf: fileURL(for: name)))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        stores[name] = loaded
        return loaded
    }

    private func mutate(_ name: String, _ body: (inout Store) -> Void) {
        var current = store(for: name)
        body(&current)
        stores[name] = current
        dirty.insert(name)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }

    /// Encodes and writes off-main: a `Cache` holding fetched results runs to megabytes.
    func flush() {
        guard queueDirtyStores() else { return }
        let disk = self.disk
        Task.detached(priority: .utility) { disk.drain() }
    }

    /// Termination cannot await a detached write, so whatever is still queued lands here.
    func flushSynchronously() {
        queueDirtyStores()
        disk.drain()
    }

    @discardableResult
    private func queueDirtyStores() -> Bool {
        flushTask?.cancel()
        flushTask = nil
        var operations: [URL: ExtensionStorageDisk.Operation] = [:]
        for name in dirty {
            guard let store = stores[name] else { continue }
            operations[fileURL(for: name)] = .write { try JSONEncoder().encode(store) }
        }
        dirty.removeAll()
        disk.enqueue(operations)
        return !operations.isEmpty
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(ExtensionCatalog.safeName(name)).json")
    }
}

/// Only the newest operation per file is queued, and one drain runs at a time, so none reorder.
private final class ExtensionStorageDisk: Sendable {
    enum Operation: Sendable {
        case write(@Sendable () throws -> Data)
        case remove
    }

    private let queued = Mutex<[URL: Operation]>([:])
    private let io = Mutex(())

    func enqueue(_ operations: [URL: Operation]) {
        queued.withLock { $0.merge(operations) { _, newer in newer } }
    }

    func drain() {
        io.withLock { _ in
            let operations = queued.withLock { queued in
                defer { queued.removeAll() }
                return queued
            }
            for (url, operation) in operations {
                switch operation {
                case .write(let encode):
                    guard let data = try? encode() else { continue }
                    try? data.write(to: url, options: .atomic)
                case .remove:
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
