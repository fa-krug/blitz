import Foundation

/// The last lines a command logged, kept in release builds too so Copy Error can carry them.
struct ExtensionConsoleLog: Equatable, Sendable {
    static let defaultCapacity = 50
    /// One runaway `console.log(hugeObject)` must not hold megabytes until the next launch.
    static let lineLimit = 2_000

    let capacity: Int
    private(set) var lines: [String] = []

    init(capacity: Int = ExtensionConsoleLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(level: String, message: String) {
        let text =
            message.count > Self.lineLimit ? String(message.prefix(Self.lineLimit)) + "…" : message
        lines.append("[\(level)] \(text)")
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    mutating func clear() {
        lines.removeAll()
    }
}
