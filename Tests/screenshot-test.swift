import Foundation

@main
struct ScreenshotTests {
    nonisolated(unsafe) static var failures = 0
    static let home = URL(fileURLWithPath: "/Users/test")

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        datePrefix()
        expression()
        eligibility()
        scopes()
        selection()
        pendingWork()
        store()

        print(failures == 0 ? "Screenshot tests passed" : "\(failures) screenshot tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func datePrefix() {
        let today = ScreenshotQuery(parsing: "date:today invoice")
        expect(today.date == .today, "date:today is a range")
        expect(today.terms == ["invoice"], "the prefix leaves the rest as terms")
        expect(ScreenshotQuery(parsing: "DATE:Yesterday").date == .yesterday, "the prefix ignores case")
        expect(ScreenshotQuery(parsing: "date:week").terms.isEmpty, "a lone prefix has no terms")
        let unknown = ScreenshotQuery(parsing: "date:monday chart")
        expect(unknown.date == nil, "an unknown range is not a filter")
        expect(unknown.terms == ["date:monday", "chart"], "an unknown range stays a literal term")
        let late = ScreenshotQuery(parsing: "chart date:today")
        expect(late.date == nil, "only a leading token is a prefix")
        expect(late.terms == ["chart", "date:today"], "a later date: token is a term")
        expect(ScreenshotQuery(parsing: "  ").terms.isEmpty, "blank input has no terms")
    }

    static func expression() {
        expect(
            ScreenshotQuery(parsing: "anything").expression == "kMDItemIsScreenCapture == 1",
            "terms never reach Spotlight; it is asked only for captures")
        expect(
            ScreenshotQuery(parsing: "date:today").expression
                == "kMDItemIsScreenCapture == 1 && kMDItemContentCreationDate >= $time.today",
            "today starts at midnight")
        expect(
            ScreenshotQuery(parsing: "date:yesterday").expression
                == "kMDItemIsScreenCapture == 1 && kMDItemContentCreationDate >= $time.yesterday"
                + " && kMDItemContentCreationDate < $time.today",
            "yesterday is bounded on both sides")
        expect(
            ScreenshotQuery(parsing: "date:week").expression
                == "kMDItemIsScreenCapture == 1 && kMDItemContentCreationDate >= $time.today(-6)",
            "a week is today and the six days before")
    }

    static func eligibility() {
        expect(
            ScreenshotQuery.isEligible("/Users/test/Desktop/Screenshot.png", homeDirectory: home),
            "a desktop capture is listed")
        expect(
            !ScreenshotQuery.isEligible(
                "/Users/test/Library/Containers/x/Screenshot.png", homeDirectory: home),
            "Library is never listed")
        expect(
            !ScreenshotQuery.isEligible("/Users/test/.cache/Screenshot.png", homeDirectory: home),
            "a hidden folder is never listed")
        expect(
            ScreenshotQuery.isEligible("/Volumes/Shots/Screenshot.png", homeDirectory: home),
            "a capture outside home is listed")
    }

    static func scopes() {
        expect(
            ScreenshotQuery.scopes(homeDirectory: home, captureLocation: nil) == [home],
            "no location default searches home")
        expect(
            ScreenshotQuery.scopes(homeDirectory: home, captureLocation: "~/Pictures/Shots")
                == [home],
            "a location under home adds nothing")
        expect(
            ScreenshotQuery.scopes(homeDirectory: home, captureLocation: "/Volumes/Shots")
                == [home, URL(fileURLWithPath: "/Volumes/Shots", isDirectory: true)],
            "a location outside home is searched too")
    }

    static func selection() {
        let paths = (0..<40).map { "/Users/test/Desktop/Screenshot \($0).png" }
        expect(
            ScreenshotQuery(parsing: "").select(from: paths, textMatches: [])
                == Array(paths.prefix(ScreenshotQuery.recentLimit)),
            "a blank query keeps the newest captures, in order")
        let named = [
            "/Users/test/Desktop/Invoice chart.png", "/Users/test/Desktop/Screenshot 1.png",
            "/Users/test/Desktop/chart.png"
        ]
        expect(
            ScreenshotQuery(parsing: "chart").select(from: named, textMatches: [])
                == [named[0], named[2]],
            "a filename match keeps recency order")
        expect(
            ScreenshotQuery(parsing: "budget").select(from: named, textMatches: [named[1]])
                == [named[1]],
            "a text match is enough on its own")
        expect(
            ScreenshotQuery(parsing: "chart invoice").select(from: named, textMatches: [])
                == [named[0]],
            "every term has to match the filename")
        expect(
            ScreenshotQuery(parsing: "zzz").select(
                from: named, textMatches: ["/Users/test/Elsewhere.png"]
            ).isEmpty,
            "a text match outside the listed captures is not shown")
    }

    static func pendingWork() {
        let files = [
            ScreenshotFile(path: "/a.png", modified: 1), ScreenshotFile(path: "/b.png", modified: 2),
            ScreenshotFile(path: "/c.png", modified: 3), ScreenshotFile(path: "/d.png", modified: 4)
        ]
        let pending = ScreenshotFile.needingText(
            files, indexed: ["/a.png": 1, "/b.png": 1], skipping: ["/d.png"])
        expect(pending == [files[1], files[2]], "unchanged and failed files are skipped, order kept")
    }

    static func store() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "screenshot-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "screenshots.sqlite3")
        let store = ScreenshotTextStore(url: url)

        expect(store.stamps().isEmpty, "a missing database reads as empty")
        expect(store.paths(matching: ["chart"]).isEmpty, "a missing database matches nothing")
        expect(!FileManager.default.fileExists(atPath: url.path), "reading never creates the file")

        let invoice = ScreenshotFile(path: "/shots/invoice.png", modified: 10)
        let empty = ScreenshotFile(path: "/shots/blank.png", modified: 11)
        let chart = ScreenshotFile(path: "/shots/chart.png", modified: 12)
        expect(store.record(invoice, text: "Invoice total 42 EUR\nDue Friday"), "a row records")
        expect(store.record(empty, text: ""), "an empty read records")
        expect(store.record(chart, text: "Quarterly revenue chart"), "a second row records")
        expect(
            store.stamps() == [invoice.path: 10, empty.path: 11, chart.path: 12],
            "stamps read back what was recorded")

        expect(store.paths(matching: ["invoice"]) == [invoice.path], "trigram search finds a word")
        expect(store.paths(matching: ["INVOICE"]) == [invoice.path], "search ignores case")
        expect(
            store.paths(matching: ["friday", "total"]) == [invoice.path],
            "every term has to occur, in any order")
        expect(store.paths(matching: ["invoice", "revenue"]).isEmpty, "terms never span two rows")
        expect(store.paths(matching: ["42"]) == [invoice.path], "a short term falls back to a scan")
        expect(store.paths(matching: ["%"]).isEmpty, "a LIKE wildcard is literal")
        expect(store.paths(matching: ["\"quarterly"]).isEmpty, "a quote cannot break the match")
        expect(
            store.text(at: chart.path, modified: 12) == "Quarterly revenue chart", "text reads back")
        expect(store.text(at: chart.path, modified: 13) == nil, "an edited file's text is stale")
        expect(store.text(at: "/shots/none.png", modified: 1) == nil, "an unknown path has no text")

        let edited = ScreenshotFile(path: chart.path, modified: 20)
        expect(store.record(edited, text: "Annual forecast"), "a changed file records again")
        expect(store.stamps()[chart.path] == 20, "the new stamp replaces the old")
        expect(store.paths(matching: ["revenue"]).isEmpty, "the old text leaves the index")
        expect(store.paths(matching: ["forecast"]) == [chart.path], "the new text joins it")

        let removed = store.prune { $0 == invoice.path }
        expect(removed == 1, "prune reports what it removed")
        expect(store.stamps()[invoice.path] == nil, "a vanished file's row is gone")
        expect(store.paths(matching: ["invoice"]).isEmpty, "and so is its text")
        expect(store.prune { _ in false } == 0, "nothing vanished, nothing removed")
    }
}
