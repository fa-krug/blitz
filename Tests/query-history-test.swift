import Foundation

/// ↑ in the launcher must only ever walk back through searches the user acted on, newest first.
@main
struct QueryHistoryTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

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

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all query history checks passed")
    }
}
