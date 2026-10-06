import Foundation

/// ↑ in the launcher must only ever walk back through searches the user acted on, newest first.
@main
@MainActor
struct QueryHistoryTest {
    static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static func main() async {
        walk()
        forward()
        skipRule()
        await store()

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all query history checks passed")
    }

    static func walk() {
        var history = LauncherQueryHistory()
        check("an empty history recalls nothing", history.older(than: "", recalled: nil) == nil)

        history.record("   ")
        check("a blank search is not recorded", history.queries.isEmpty)
        history.record(String(repeating: "x", count: LauncherQueryHistory.queryLimit + 1))
        check("an oversized paste is not recorded", history.queries.isEmpty)

        history.record("safari")
        history.record(" notes ")
        history.record("2+2")
        check("newest first, trimmed", history.queries == ["2+2", "notes", "safari"])

        history.record("safari")
        check("a repeat moves to the front", history.queries == ["safari", "2+2", "notes"])

        check("an empty field recalls the newest", history.older(than: "", recalled: nil) == 0)
        check("a blank field counts as empty", history.older(than: "  ", recalled: 2) == 0)
        check("an unedited recall steps older", history.older(than: "safari", recalled: 0) == 1)
        check("and older again", history.older(than: "2+2", recalled: 1) == 2)
        check("the oldest leaves ↑ to the list", history.older(than: "notes", recalled: 2) == nil)
        check("an edited recall is never stepped", history.older(than: "safar", recalled: 0) == nil)
        check("a typed query is not a recall", history.older(than: "safari", recalled: nil) == nil)
        check("a stale index is ignored", history.older(than: "safari", recalled: 9) == nil)
        check("subscript reads the recalled entry", history[1] == "2+2")

        for index in 0..<(LauncherQueryHistory.limit + 5) { history.record("q\(index)") }
        check("bounded at the limit", history.queries.count == LauncherQueryHistory.limit)
        check("the oldest fall off", history.queries.last == "q5")
        let newest = "q\(LauncherQueryHistory.limit + 4)"
        check("the newest stays first", history.queries.first == newest)
    }

    /// ↓ only ever retraces a walk ↑ started, ending on the empty field it began from.
    static func forward() {
        let history = LauncherQueryHistory(queries: ["2+2", "notes", "safari"])
        check("an empty field is no walk", history.newer(than: "", recalled: nil) == nil)
        check("a typed query is no walk", history.newer(than: "notes", recalled: nil) == nil)
        check("a recall steps newer", history.newer(than: "safari", recalled: 2) == .recall(1))
        check("and newer again", history.newer(than: "notes", recalled: 1) == .recall(0))
        check("the newest clears the field", history.newer(than: "2+2", recalled: 0) == .clear)
        check("an edited recall is never stepped", history.newer(than: "note", recalled: 1) == nil)
        check("a stale index is ignored", history.newer(than: "notes", recalled: 7) == nil)
        var index = history.older(than: "", recalled: nil)
        var walked: [String] = []
        while let step = index {
            walked.append(history[step])
            index = history.older(than: history[step], recalled: step)
        }
        check("↑ walks every entry oldest-ward", walked == ["2+2", "notes", "safari"])
        var back: [String] = []
        var position = 2
        while case .recall(let step) = history.newer(than: history[position], recalled: position) {
            back.append(history[step])
            position = step
        }
        check("↓ retraces the walk", back == ["notes", "2+2"])

        let restored = LauncherQueryHistory(queries: ["a", " b ", "a", "", "c"])
        check("a stored list is cleaned like fresh searches", restored.queries == ["a", "b", "c"])
        let overfull = LauncherQueryHistory(queries: (0..<30).map { "q\($0)" })
        check("a stored list is capped", overfull.queries.count == LauncherQueryHistory.limit)
        check("keeping the newest end", overfull.queries.first == "q0")
    }

    /// A line run through the shell fallback can carry a secret, so it is never kept at all.
    static func skipRule() {
        var history = LauncherQueryHistory()
        history.record("export TOKEN=abc", from: .shellCommand)
        check("a shell command is not recorded", history.queries.isEmpty)
        history.record("safari", from: .result)
        history.record("safari", from: .shellCommand)
        check("nor does it move an earlier search", history.queries == ["safari"])
    }

    /// The store reads back what it wrote, and forgets the file once persistence is off.
    static func store() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-history-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("launcher-history.json")
        let exists = { FileManager.default.fileExists(atPath: file.path) }

        let first = LauncherQueryHistoryStore(fileURL: file, persists: true)
        check("a missing file starts empty", first.isEmpty)
        first.record("safari", from: .result)
        first.record("ls ~/secret", from: .shellCommand)
        first.record("notes", from: .result)
        await first.flush()
        let reopened = LauncherQueryHistoryStore(fileURL: file, persists: true)
        check("history survives a restart", reopened.history.queries == ["notes", "safari"])

        reopened.persists = false
        await reopened.flush()
        check("turning it off deletes the file", !exists())
        check("but keeps the session's searches", reopened.history.queries == ["notes", "safari"])
        reopened.record("calendar", from: .result)
        await reopened.flush()
        check("searches stay in memory while off", !exists())
        reopened.persists = true
        await reopened.flush()
        let resumed = LauncherQueryHistoryStore(fileURL: file, persists: true)
        check("turning it on writes the session", resumed.history.queries.first == "calendar")

        let off = LauncherQueryHistoryStore(fileURL: file, persists: false)
        check("an off store reads nothing", off.isEmpty)
        check("and removes a file left behind", !exists())

        let cleared = LauncherQueryHistoryStore(fileURL: file, persists: true)
        cleared.replace(["one", "two"])
        await cleared.flush()
        check("a backup's list is written", exists())
        cleared.clear()
        await cleared.flush()
        check("clearing empties the history", cleared.isEmpty)
        check("and removes the file", !exists())

        try? Data("not json".utf8).write(to: file)
        let corrupt = LauncherQueryHistoryStore(fileURL: file, persists: true)
        check("a corrupt file reads as empty", corrupt.isEmpty)
    }
}
