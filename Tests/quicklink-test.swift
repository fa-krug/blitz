// Standalone test for the quicklink model, destination detection, store and archive.
import Foundation

@main
@MainActor
struct QuicklinkTests {
    static var failures = 0
    static var passes = 0

    /// Injected everywhere a path is resolved, so no assertion depends on the machine.
    static let home = "/Users/blitz-harness"

    static func main() {
        destinationDetection()
        pathDetection()
        encodingChoice()
        placeholderDetection()
        displayOrder()
        storeCRUD()
        storeValidation()
        pinning()
        persistence()
        readsADatabaseWrittenElsewhere()
        corruptDatabaseIsPreserved()
        batchAppend()
        replaceNotifiesTwice()
        batchAppendAtScale()
        faviconStorage()
        faviconPathsSurviveOtherEdits()
        faviconDiscovery()
        archiveRoundTrip()
        archiveMerge()
        archiveAcceptsAHandWrittenFile()
        raycastImport()
        tagNormalization()
        tagSearch()
        tagsPersist()
        tagsTravelInArchives()
        tabURLMatching()
        handlerProbe()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Destination detection

    static func destinationDetection() {
        expect(detect("https://example.com") == .web(url("https://example.com")), "https is a website")
        expect(detect("http://example.com/a") == .web(url("http://example.com/a")), "http is a website")
        expect(
            detect("example.com/search?q=1") == .web(url("https://example.com/search?q=1")),
            "a bare host gains https, keeping its path and query")
        expect(
            detect("sub.example.co.uk") == .web(url("https://sub.example.co.uk")),
            "a multi-label host is still a website")
        expect(
            detect("example.com:8080/x") == .web(url("https://example.com:8080/x")),
            "a port does not stop a bare host being a website")
        expect(
            detect("spotify://track/1") == .deeplink(url("spotify://track/1")),
            "an unknown scheme is a deeplink")
        expect(
            detect("shortcuts://run-shortcut?name=Focus")
                == .deeplink(url("shortcuts://run-shortcut?name=Focus")),
            "a deeplink keeps its query")
        expect(
            detect("mailto:someone@example.com") == .deeplink(url("mailto:someone@example.com")),
            "a schemeless-authority scheme is still a deeplink")
        expect(
            detect("smb://server/share") == .network(url("smb://server/share")),
            "smb is a network path")
        expect(
            detect("afp://server/share") == .network(url("afp://server/share")),
            "afp is a network path")
        expect(
            detect("http://example.com/a b") == .web(url("http://example.com/a%20b")),
            "a literal space is rescued rather than rejected")
        expect(
            detect("https://example.com/a%20b") == .web(url("https://example.com/a%20b")),
            "an already-encoded value is not encoded twice")

        expect(detect("") == nil, "an empty link resolves to nothing")
        expect(detect("   ") == nil, "a whitespace-only link resolves to nothing")
        expect(detect("not a url") == nil, "prose is not a destination")
        expect(detect("{argument}") == nil, "a bare leftover placeholder is not a destination")
        expect(detect("1.5") == nil, "a decimal is not a host")
        expect(detect("C:/Users/x") == nil, "a drive letter is not a scheme")
    }

    static func pathDetection() {
        expect(detect("/tmp") == .path("/tmp"), "an absolute path is a path")
        expect(
            detect("~/Downloads") == .path("\(home)/Downloads"),
            "a tilde expands against the injected home")
        expect(detect("~") == .path(home), "a bare tilde is the home directory")
        expect(
            detect("  ~/Projects/Blitz  ") == .path("\(home)/Projects/Blitz"),
            "surrounding whitespace is trimmed before detection")
        expect(
            detect("file:///Users/x/notes.md") == .path("/Users/x/notes.md"),
            "a file URL resolves to the path it names, not to a deeplink")
        expect(
            QuicklinkDestination.detect("~/Downloads", homeDirectory: "/Users/other/")
                == .path("/Users/other/Downloads"),
            "a trailing slash on the home directory does not double up")
    }

    static func encodingChoice() {
        expect(
            QuicklinkDestination.usesURLEncoding("https://x.com/?q={argument}", homeDirectory: home),
            "values going into a URL are encoded")
        expect(
            QuicklinkDestination.usesURLEncoding("spotify://search/{argument}", homeDirectory: home),
            "values going into a deeplink are encoded")
        expect(
            !QuicklinkDestination.usesURLEncoding("~/Notes/{date}.md", homeDirectory: home),
            "values going into a path are not encoded")
        expect(
            !QuicklinkDestination.usesURLEncoding("/tmp/{argument}", homeDirectory: home),
            "an absolute path is not encoded either")
    }

    static func placeholderDetection() {
        expect(
            QuicklinkDestination.containsPlaceholder("https://x.com/?q={argument}"),
            "a token is a placeholder")
        expect(
            !QuicklinkDestination.containsPlaceholder("https://x.com/?q=1"),
            "a plain link has no placeholder")
        expect(
            !QuicklinkDestination.containsPlaceholder("https://x.com/{unterminated"),
            "an unclosed brace is not a placeholder")
    }

    // MARK: - Model

    static func displayOrder() {
        let base = Date(timeIntervalSince1970: 1_000)
        let zulu = link("Zulu")
        let alpha = link("alpha")
        var pinnedLate = link("Late Pin")
        pinnedLate.pinnedAt = base.addingTimeInterval(60)
        var pinnedEarly = link("Early Pin")
        pinnedEarly.pinnedAt = base

        let sorted = [zulu, alpha, pinnedLate, pinnedEarly].sorted(by: Quicklink.precedes)
        expect(
            sorted.map(\.name) == ["Early Pin", "Late Pin", "alpha", "Zulu"],
            "pins lead in pin order, then the rest sort case-insensitively by name")
    }

    // MARK: - Store

    static func storeCRUD() {
        withStore { store in
            guard let github = try? store.add(link("GitHub", "https://github.com")) else {
                return fail("adding a quicklink succeeds")
            }
            expect(store.quicklinks.map(\.name) == ["GitHub"], "an added quicklink is listed")
            expect(store.quicklink(entryID: github.entryID)?.id == github.id, "entry id round-trips")

            var edited = github
            edited.name = "GitHub Issues"
            edited.link = "https://github.com/issues"
            try? store.update(edited)
            expect(
                store.quicklink(id: github.id)?.name == "GitHub Issues",
                "an edit is stored under the same identity")
            expect(
                store.quicklink(id: github.id)?.link == "https://github.com/issues",
                "the edited link is stored")

            try? store.setShowsInRootSearch(false, id: github.id)
            expect(
                store.quicklink(id: github.id)?.showsInRootSearch == false,
                "hiding from root search is stored")

            expect(github.isEnabled, "a new quicklink is enabled")
            try? store.setEnabled(false, id: github.id)
            expect(store.quicklink(id: github.id)?.isEnabled == false, "disabling is stored")
            expect(
                store.quicklink(id: github.id)?.link == "https://github.com/issues",
                "disabling keeps every other field intact")

            guard let copy = try? store.duplicate(id: github.id) else {
                return fail("duplicating a quicklink succeeds")
            }
            expect(copy.id != github.id, "a duplicate is a new identity")
            expect(copy.name == "GitHub Issues Copy", "a duplicate gets a distinct name")
            expect(copy.link == "https://github.com/issues", "a duplicate keeps the destination")
            expect(!copy.isEnabled, "a duplicate inherits the enabled flag")

            try? store.remove(id: copy.id)
            expect(store.quicklinks.map(\.id) == [github.id], "removing drops only that row")
        }
    }

    static func storeValidation() {
        withStore { store in
            expect(throwsError(store, link("", "https://x.com")) == .emptyName, "a name is required")
            expect(throwsError(store, link("Name", "")) == .emptyLink, "a link is required")
            expect(
                throwsError(store, link("Name", "not a url")) == .unresolvableLink,
                "a link that resolves to nothing is rejected")
            expect(
                throwsError(store, link("Na\0me", "https://x.com")) == .invalidCharacter,
                "a null character is rejected")

            _ = try? store.add(link("Search", "https://x.com/?q={argument}"))
            expect(
                store.quicklinks.count == 1,
                "a templated link is accepted, since its destination is only knowable once expanded")
            expect(
                throwsError(store, link("search", "https://other.com")) == .duplicateName,
                "a duplicate name is rejected case-insensitively")

            var renamed = store.quicklinks[0]
            renamed.name = "  Search  "
            expect(
                (try? store.update(renamed)) != nil,
                "a quicklink does not collide with its own name when edited")
            expect(store.quicklinks[0].name == "Search", "names are trimmed on save")
        }
    }

    static func pinning() {
        withStore { store in
            _ = try? store.add(link("Alpha"))
            _ = try? store.add(link("Bravo"))
            _ = try? store.add(link("Charlie"))
            expect(names(store) == ["Alpha", "Bravo", "Charlie"], "unpinned rows sort by name")

            let charlie = store.quicklinks[2].id
            let alpha = store.quicklinks[0].id
            try? store.togglePinned(id: charlie)
            expect(names(store) == ["Charlie", "Alpha", "Bravo"], "a pin lifts the row to the top")

            try? store.togglePinned(id: alpha)
            expect(
                names(store) == ["Charlie", "Alpha", "Bravo"],
                "a second pin joins below the first rather than displacing it")

            var pinned = store.quicklink(id: charlie)!
            pinned.name = "Charlie Renamed"
            try? store.update(pinned)
            expect(
                names(store) == ["Charlie Renamed", "Alpha", "Bravo"],
                "editing a pinned row keeps its pin stamp and its place")

            try? store.togglePinned(id: charlie)
            expect(
                names(store) == ["Alpha", "Bravo", "Charlie Renamed"],
                "unpinning drops the row back into the alphabetical block")
        }
    }

    static func persistence() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var stored: UUID?
        do {
            let store = QuicklinkStore(directory: dir)
            var draft = link("Downloads", "~/Downloads")
            draft.iconSymbol = "folder"
            draft.openWithBundleID = "com.apple.finder"
            stored = try? store.add(draft).id
            try? store.togglePinned(id: stored!)
            try? store.setEnabled(false, id: stored!)
        }

        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        expect(reopened.isAvailable, "a reopened database is available")
        guard let restored = reopened.quicklinks.first, reopened.quicklinks.count == 1 else {
            return fail("the quicklink survives a close and reopen")
        }
        expect(restored.id == stored, "identity survives")
        expect(restored.name == "Downloads" && restored.link == "~/Downloads", "fields survive")
        expect(restored.iconSymbol == "folder", "the icon survives")
        expect(restored.openWithBundleID == "com.apple.finder", "the open-with app survives")
        expect(restored.isPinned, "the pin stamp survives")
        expect(!restored.isEnabled, "the enabled flag survives")
    }

    /// The bound column order must match the read order, and an older table must gain new columns.
    static func readsADatabaseWrittenElsewhere() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        sqlite(
            dir.appendingPathComponent("quicklinks.sqlite3"),
            """
            CREATE TABLE quicklinks(
              id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, link TEXT NOT NULL,
              open_with TEXT, icon TEXT, in_root_search INTEGER NOT NULL DEFAULT 1,
              pinned_at REAL, created_at REAL NOT NULL
            );
            INSERT INTO quicklinks(id, name, link, open_with, icon, in_root_search, created_at)
              VALUES('\(id.uuidString)', 'Jira', 'https://jira.example.com', NULL, 'ticket', 0, 1000);
            """)

        let store = QuicklinkStore(directory: dir)
        store.load()
        guard let row = store.quicklinks.first else {
            return fail("an externally written row loads")
        }
        expect(row.id == id, "the external id is read")
        expect(row.name == "Jira" && row.link == "https://jira.example.com", "the text columns line up")
        expect(row.iconSymbol == "ticket", "the icon column lines up")
        expect(row.openWithBundleID == nil, "a null open-with reads as none")
        expect(!row.showsInRootSearch, "the root-search flag lines up")
        expect(!row.isPinned, "a null pin stamp reads as unpinned")
        expect(row.isEnabled, "a table written before is_enabled loads its rows as enabled")
        expect(row.favicon == nil, "a table written before favicon loads its rows without one")
        expect(row.tags.isEmpty, "a table written before tags loads its rows untagged")

        // A second open must find the column already there rather than adding it twice.
        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        expect(reopened.quicklinks.count == 1, "the migrated table reopens cleanly")
    }

    /// Quicklinks are authored data, so an unreadable database is reported, never recreated.
    static func corruptDatabaseIsPreserved() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("quicklinks.sqlite3")
        let garbage = Data("this is definitely not a database".utf8)
        try? garbage.write(to: dbURL)

        let store = QuicklinkStore(directory: dir)
        expect(!store.isAvailable, "an unreadable database reports itself unavailable")
        expect(store.quicklinks.isEmpty, "no rows are invented")
        expect(
            (try? Data(contentsOf: dbURL)) == garbage,
            "the unreadable file is left exactly as it was — never deleted or overwritten")
        expect(
            throwsError(store, link("Anything")) == .storageUnavailable,
            "a mutation refuses rather than pretending to save")
    }

    // MARK: - Batches

    /// An import is one transaction and one `onChange`, held to the rules a single add follows.
    static func batchAppend() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = QuicklinkStore(directory: dir)
            _ = try? store.add(link("GitHub", "https://github.com"))
            var changes = 0
            store.onChange = { _ in changes += 1 }
            let added = store.append([
                link("Jira", "https://jira.example.com"),
                link("JIRA", "https://other.example.com"),
                link("github", "https://elsewhere.com"),
                link("", "https://empty.example.com"),
                link("Broken", "not a url"),
                link("  Docs  ", "https://docs.example.com")
            ])
            expect(
                added.map(\.name) == ["Jira", "Docs"],
                "a batch skips in-batch and library duplicates and invalid entries, keeping order")
            expect(changes == 1, "a batch notifies once, however many rows it adds")
            expect(names(store) == ["Docs", "GitHub", "Jira"], "a batch lands sorted")
            expect(
                throwsError(store, link("jira", "https://x.com")) == .duplicateName,
                "a single add rejects a name a batch stored, in the same case-insensitive sense")
            expect(
                store.append([link("docs", "https://x.com")]).isEmpty, "a repeat batch adds nothing")
            expect(changes == 1, "a batch that adds nothing does not notify")
        }

        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        expect(names(reopened) == ["Docs", "GitHub", "Jira"], "a batch survives a reopen")
    }

    static func replaceNotifiesTwice() {
        withStore { store in
            _ = store.append([link("Alpha"), link("Bravo")])
            var changes = 0
            store.onChange = { _ in changes += 1 }
            let count = store.replace(with: [link("Charlie"), link("Delta"), link("Echo")])
            expect(count == 3, "a replace reports what it stored")
            expect(names(store) == ["Charlie", "Delta", "Echo"], "a replace swaps the whole set")
            expect(changes == 2, "a replace notifies for the clear and once for the batch")
        }
    }

    /// No wall-clock bound: a regression to per-row commits shows up as thousands of notifications.
    static func batchAppendAtScale() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = 2_000

        do {
            let store = QuicklinkStore(directory: dir)
            var changes = 0
            store.onChange = { _ in changes += 1 }
            let incoming = (0..<count).map { index in
                var draft = link("Link \(index)", "https://example.com/\(index)")
                if index.isMultiple(of: 10) { draft.favicon = Data("icon \(index)".utf8) }
                return draft
            }
            expect(store.append(incoming).count == count, "a large batch stores every row")
            expect(changes == 1, "a large batch notifies once")
            expect(store.faviconPaths.count == count / 10, "a large batch writes every favicon")

            let before = store.faviconPaths
            if let first = store.quicklinks.first { try? store.togglePinned(id: first.id) }
            expect(store.faviconPaths == before, "pinning one row leaves every favicon path alone")
        }

        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        expect(reopened.quicklinks.count == count, "a large batch survives a reopen")
        expect(reopened.faviconPaths.count == count / 10, "its favicons are written again on load")
    }

    // MARK: - Favicons

    /// The blob is the source; the file is derived from it, so it may be pruned but never stale.
    static func faviconStorage() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data("not really a png".utf8)

        var stored: Quicklink?
        do {
            let store = QuicklinkStore(directory: dir)
            var draft = link("GitHub", "https://github.com")
            draft.favicon = png
            stored = try? store.add(draft)
            guard let stored, let path = store.faviconPaths[stored.id] else {
                return fail("a stored favicon is written out as a file")
            }
            expect(
                FileManager.default.contents(atPath: path) == png, "the file holds the favicon bytes")
            guard let copy = try? store.duplicate(id: stored.id) else {
                return fail("duplicating a quicklink with a favicon succeeds")
            }
            expect(copy.favicon == png, "a duplicate keeps the favicon")
            expect(store.faviconPaths[copy.id] == path, "identical favicons share one file")

            var empty = link("Empty", "https://example.com")
            empty.favicon = Data()
            let added = try? store.add(empty)
            expect(added != nil && added?.favicon == nil, "an empty favicon is stored as none")
        }

        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        guard let id = stored?.id, let restored = reopened.quicklink(id: id) else {
            return fail("a quicklink with a favicon survives a reopen")
        }
        expect(restored.favicon == png, "the favicon survives a close and reopen")
        let oldPath = reopened.faviconPaths[id]
        expect(oldPath != nil, "a reopened store writes its favicon paths again")

        var refetched = restored
        refetched.favicon = Data("a newer icon".utf8)
        try? reopened.update(refetched)
        expect(
            reopened.faviconPaths[id] != oldPath,
            "a refetched favicon moves to a new path, so no icon cache serves the old one")

        let folder = dir.appendingPathComponent("QuicklinkFavicons")
        let copyPath = reopened.quicklinks.first { $0.name == "GitHub Copy" }
            .flatMap { reopened.faviconPaths[$0.id] }
        expect(copyPath == oldPath, "the copy still draws the original favicon")
        if let copy = reopened.quicklinks.first(where: { $0.name == "GitHub Copy" }) {
            try? reopened.remove(id: copy.id)
        }
        let pruned = QuicklinkStore(directory: dir)
        pruned.load()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        expect(files.count == 1, "a reload prunes the files no quicklink references any more")
    }

    /// Paths are reused across edits rather than rehashed, so they must never drift from the bytes.
    static func faviconPathsSurviveOtherEdits() {
        withStore { store in
            var github = link("GitHub", "https://github.com")
            github.favicon = Data("github icon".utf8)
            var jira = link("Jira", "https://jira.example.com")
            jira.favicon = Data("jira icon".utf8)
            _ = store.append([github, jira, link("Plain")])
            guard let githubPath = store.faviconPaths[github.id],
                let jiraPath = store.faviconPaths[jira.id]
            else { return fail("a batch writes each favicon out") }

            if let plain = store.quicklinks.first(where: { $0.name == "Plain" }) {
                try? store.togglePinned(id: plain.id)
            }
            try? store.setEnabled(false, id: jira.id)
            try? store.setShowsInRootSearch(false, id: github.id)
            expect(
                store.faviconPaths == [github.id: githubPath, jira.id: jiraPath],
                "pinning, disabling and hiding leave favicon paths where they were")

            var refetched = store.quicklink(id: github.id)!
            refetched.favicon = Data("github icon, redrawn".utf8)
            try? store.update(refetched)
            let newPath = store.faviconPaths[github.id]
            expect(newPath != nil && newPath != githubPath, "a changed favicon moves its path")
            expect(
                newPath.flatMap { FileManager.default.contents(atPath: $0) } == refetched.favicon,
                "the moved path holds the new bytes")
            expect(store.faviconPaths[jira.id] == jiraPath, "the other favicon keeps its path")

            refetched.favicon = Data("github icon".utf8)
            try? store.update(refetched)
            expect(
                store.faviconPaths[github.id] == githubPath,
                "restoring the old favicon returns to the old file")

            refetched.favicon = nil
            try? store.update(refetched)
            expect(store.faviconPaths[github.id] == nil, "dropping a favicon drops its path")
            expect(
                FileManager.default.contents(atPath: jiraPath) == jira.favicon,
                "a file still referenced is untouched")
        }
    }

    static func faviconDiscovery() {
        expect(
            QuicklinkFavicon.siteURL(for: "https://github.com/search?q={argument}")
                == url("https://github.com/"),
            "a templated link resolves to its site's root")
        expect(
            QuicklinkFavicon.siteURL(for: "github.com/fa-krug") == url("https://github.com/"),
            "a bare host reads as https")
        expect(
            QuicklinkFavicon.siteURL(for: "http://localhost:8080/x") == url("http://localhost:8080/"),
            "the scheme and port are kept")
        expect(QuicklinkFavicon.siteURL(for: "~/Downloads") == nil, "a path has no favicon")
        expect(QuicklinkFavicon.siteURL(for: "spotify://track/1") == nil, "a deeplink has none")
        expect(
            QuicklinkFavicon.siteURL(for: "https://{argument}.atlassian.net") == nil,
            "a templated host has no site to ask")
        expect(
            QuicklinkFavicon.conventionalURL(for: url("https://example.com/"))
                == url("https://example.com/favicon.ico"),
            "the conventional location sits at the root")

        let html = """
            <head>
            <link rel="stylesheet" href="/s.css">
            <link rel="icon" href="/favicon-16.png" sizes="16x16">
            <LINK REL="Shortcut Icon" HREF='/legacy.ico'>
            <link rel="apple-touch-icon" href="/touch.png">
            <link rel="icon" type="image/png" sizes="192x192" href="https://cdn.example.com/i.png?v=1&amp;x=2">
            <link rel="mask-icon" href="/mask.svg">
            <link rel="icon" href="/favicon.svg" type="image/svg+xml">
            <link rel="icon" href="/favicon-16.png">
            </head>
            """
        let found = QuicklinkFavicon.candidates(
            inHTML: html, baseURL: url("https://example.com/home/"))
        expect(
            found == [
                url("https://example.com/favicon.svg"),
                url("https://cdn.example.com/i.png?v=1&x=2"),
                url("https://example.com/touch.png"),
                url("https://example.com/legacy.ico"),
                url("https://example.com/favicon-16.png")
            ],
            "declared icons are ranked vector, then size, deduplicated, and resolved")

        let first = QuicklinkFavicon.fileName(for: Data("one".utf8))
        expect(first == QuicklinkFavicon.fileName(for: Data("one".utf8)), "a file name is stable")
        expect(
            first != QuicklinkFavicon.fileName(for: Data("two".utf8)),
            "different favicons get different files")
    }

    // MARK: - Archive

    static func archiveRoundTrip() {
        // Whole seconds: the archive is ISO 8601 so a reader can hand-edit it.
        let stamp = Date(timeIntervalSince1970: 500)
        let pinned = Quicklink(
            name: "Pinned", link: "~/Downloads", openWithBundleID: "com.apple.finder",
            iconSymbol: "folder", favicon: Data([0x89, 0x50, 0x4e, 0x47]), isEnabled: false,
            showsInRootSearch: false, pinnedAt: stamp, createdAt: stamp)
        let plain = Quicklink(name: "GitHub", link: "https://github.com", createdAt: stamp)
        let source = [plain, pinned]

        guard let data = try? QuicklinkArchive.encode(source),
            let decoded = try? QuicklinkArchive.decode(data)
        else { return fail("an exported archive decodes again") }
        expect(decoded == source, "every field survives an export and import round trip")
    }

    static func archiveMerge() {
        let existing = [link("GitHub", "https://github.com"), link("Downloads", "~/Downloads")]
        let incoming = [
            link("github", "https://elsewhere.com"),  // same name
            link("Repos", "https://github.com"),  // same destination
            link("Jira", "https://jira.example.com"),  // new
            link("Jira Two", "https://jira.example.com")  // duplicate of the one above, in-batch
        ]

        let result = QuicklinkArchive.merge(incoming, into: existing)
        expect(result.imported == 1, "only the genuinely new quicklink is imported")
        expect(result.skipped == 3, "the duplicates are counted rather than silently dropped")
        expect(result.additions.first?.name == "Jira", "the imported quicklink is the new one")
        expect(
            result.additions.first?.id != incoming[2].id,
            "an import takes a fresh identity so it cannot inherit another item's hotkey")

        let reimported = QuicklinkArchive.merge(existing, into: existing)
        expect(
            reimported.imported == 0 && reimported.skipped == 2,
            "importing the same file twice adds nothing")
    }

    static func archiveAcceptsAHandWrittenFile() {
        let handWritten = Data(
            """
            { "version": 1, "quicklinks": [ { "name": "Staging", "link": "https://staging.example.com" } ] }
            """.utf8)
        guard let decoded = try? QuicklinkArchive.decode(handWritten), let first = decoded.first
        else { return fail("a hand-written archive decodes") }
        expect(first.name == "Staging", "the name is read")
        expect(first.isEnabled, "an omitted enabled flag defaults to on")
        expect(first.showsInRootSearch, "an omitted root-search flag defaults to shown")
        expect(first.pinnedAt == nil, "an omitted pin stamp reads as unpinned")

        let bareArray = Data(#"[{ "name": "A", "link": "https://a.example.com" }]"#.utf8)
        expect((try? QuicklinkArchive.decode(bareArray))?.count == 1, "a bare array also decodes")
        expect(
            throwsArchiveError(Data("{}".utf8)) == .unreadable, "an unrelated JSON file is rejected")
        expect(
            throwsArchiveError(Data(#"{"version":1,"quicklinks":[]}"#.utf8)) == .empty,
            "an archive with no quicklinks is reported as empty rather than imported")
    }

    static func raycastImport() {
        let bundleIDs = ["/Applications/Chrome.app": "com.google.Chrome"]
        let stamped = Date(timeIntervalSince1970: 1_780_497_120)
        let imported = RaycastQuicklinkImport.parse(
            [
                "schemaVersion": 1,
                "openWithPlatforms": [
                    ["id": "plat-1", "macos": "/Applications/Chrome.app"]
                ],
                "quicklinks": [
                    [
                        "name": " Search ",
                        "link": " https://google.com/search?q={Query} ",
                        "createdAt": "2026-06-03T14:32:00Z"
                    ],
                    [
                        "name": "Dash",
                        "link": "https://kapeli.com",
                        "openWith": "/Applications/Chrome.app"
                    ],
                    [
                        "name": "Via platform",
                        "link": "https://via.example",
                        "openWith": "plat-1"
                    ],
                    ["name": "Anna", "link": "https://annas-archive.org/search?q={query}"],
                    [
                        "name": "Named",
                        "link": #"https://x.com?q={argument name="Keyword"}"#
                    ],
                    ["name": "  ", "link": "https://skip.example"],
                    ["name": "No link"],
                    ["name": "Missing Text"]
                ]
            ],
            bundleIDForAppPath: { bundleIDs[$0] })

        expect(
            RaycastQuicklinkImport.parse(["quicklinks": []]).isEmpty,
            "Raycast import ignores an empty container")
        expect(
            RaycastQuicklinkImport.parse(["foo": 1]).isEmpty,
            "Raycast import ignores an unrecognized container")
        expect(
            imported.map(\.name) == ["Search", "Dash", "Via platform", "Anna", "Named"],
            "Raycast import keeps valid entries and source order")
        guard imported.count == 5 else { return }
        expect(
            imported[0].link == "https://google.com/search?q={argument}",
            "Raycast import rewrites {Query} to {argument}")
        expect(
            imported[3].link == "https://annas-archive.org/search?q={argument}",
            "Raycast import rewrites {query} the same way")
        expect(
            imported[4].link == #"https://x.com?q={argument name="Keyword"}"#,
            "Raycast import leaves a real {argument} token alone")
        expect(
            imported[1].openWithBundleID == "com.google.Chrome"
                && imported[2].openWithBundleID == "com.google.Chrome",
            "Raycast import resolves an app path and a platform id through the same lookup")
        expect(
            imported[0].createdAt == stamped,
            "Raycast import keeps the export's createdAt")

        let bare = RaycastQuicklinkImport.parse([
            ["name": "Bare", "link": "https://bare.example"]
        ])
        expect(bare.map(\.name) == ["Bare"], "a bare array still parses, matching snippets")
        expect(
            RaycastQuicklinkImport.rewrittenLink(
                #"https://x.com?q={argument name="query"}"#)
                == #"https://x.com?q={argument name="query"}"#,
            "a parameter named query is not rewritten as the token")
    }

    // MARK: - Helpers

    // MARK: - Tags

    static func tagNormalization() {
        expect(
            Quicklink.normalizedTags(["  Work ", "", "work", "Docs", "a\nb", "   "])
                == ["Work", "Docs", "a b"],
            "tags trim, drop blanks, fold duplicates by case and keep no line break")
        expect(
            Quicklink.tags(fromList: "work, docs,,  Work ,dev") == ["work", "docs", "dev"],
            "the editor's comma list reads as tags, first spelling winning")
        expect(Quicklink.tags(fromList: " , ").isEmpty, "a list of nothing is no tags")
        let library = [
            Quicklink(name: "A", link: "https://a.test", tags: ["zeta", "Alpha"]),
            Quicklink(name: "B", link: "https://b.test", tags: ["alpha", "beta"])
        ]
        expect(
            Quicklink.allTags(in: library) == ["Alpha", "beta", "zeta"],
            "the filter lists each tag once, alphabetically and ignoring case")
    }

    static func tagSearch() {
        let tagged = Quicklink(name: "Jira", link: "https://jira.test", tags: ["Work", "tickets"])
        expect(tagged.matches("jir"), "the name still matches")
        expect(tagged.matches("TICK"), "a tag matches, ignoring case")
        expect(!tagged.matches("jira.test"), "the link stays unsearchable")
        expect(tagged.hasTag("work") && !tagged.hasTag("wor"), "the tag filter is a whole tag")
    }

    static func tagsPersist() {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var stored: UUID?
        do {
            let store = QuicklinkStore(directory: dir)
            var draft = link("Tagged")
            draft.tags = [" work ", "Work", "docs"]
            stored = try? store.add(draft).id
            expect(
                store.quicklinks.first?.tags == ["work", "docs"],
                "the store keeps tags normalized")
            let copy = try? store.duplicate(id: stored!)
            expect(copy?.tags == ["work", "docs"], "a duplicate keeps the tags")
        }
        let reopened = QuicklinkStore(directory: dir)
        reopened.load()
        expect(
            reopened.quicklink(id: stored!)?.tags == ["work", "docs"],
            "tags survive a close and reopen, in order")
        guard var untagged = reopened.quicklink(id: stored!) else { return fail("tagged row") }
        untagged.tags = []
        try? reopened.update(untagged)
        let again = QuicklinkStore(directory: dir)
        again.load()
        expect(again.quicklink(id: stored!)?.tags == [], "clearing every tag persists")
    }

    static func tagsTravelInArchives() {
        let stamp = Date(timeIntervalSince1970: 500)
        let tagged = Quicklink(
            name: "Tagged", link: "https://a.test", createdAt: stamp, tags: ["work", "docs"])
        guard let data = try? QuicklinkArchive.encode([tagged]),
            let decoded = try? QuicklinkArchive.decode(data)
        else { return fail("a tagged archive decodes") }
        expect(decoded.first?.tags == ["work", "docs"], "tags survive an export and import")
        expect(
            QuicklinkArchive.merge(decoded, into: []).additions.first?.tags == ["work", "docs"],
            "an import keeps the tags of what it adds")
        let legacy = Data(#"[{"name":"Old","link":"https://old.test"}]"#.utf8)
        expect(
            (try? QuicklinkArchive.decode(legacy))?.first?.tags == [],
            "a file written before tags imports untagged")
    }

    static func tabURLMatching() {
        let cases: [(String, String, Bool, String)] = [
            ("https://GitHub.com/a", "https://github.com/a", true, "the host folds case"),
            ("HTTPS://github.com/a", "https://github.com/a", true, "the scheme folds case"),
            ("https://github.com/a/", "https://github.com/a", true, "a trailing slash is ignored"),
            ("https://github.com/", "https://github.com", true, "a bare host matches its root"),
            ("https://github.com/a#top", "https://github.com/a", true, "the fragment is ignored"),
            ("https://github.com/A", "https://github.com/a", false, "the path keeps its case"),
            ("https://github.com/a?q=1", "https://github.com/a?q=1", true, "an equal query matches"),
            ("https://github.com/a?q=1", "https://github.com/a?q=2", false, "a query must match"),
            ("https://github.com/a?q=1", "https://github.com/a", false, "a missing query differs"),
            ("https://github.com/a?b=1&a=2", "https://github.com/a?a=2&b=1", false,
                "query order is part of the query"),
            ("http://github.com/a", "https://github.com/a", false, "the scheme still counts"),
            ("https://github.com:8443/a", "https://github.com/a", false, "the port still counts")
        ]
        for (lhs, rhs, matches, label) in cases {
            expect(BrowserTab.matches(lhs, rhs) == matches, label)
        }
    }

    static func handlerProbe() {
        expect(
            QuicklinkDestination.handlerProbe("https://github.com/search?q={argument}")?.scheme
                == "https",
            "a templated web link still names a web handler")
        expect(
            QuicklinkDestination.handlerProbe("spotify:search:{argument}")?.scheme == "spotify",
            "a deeplink names its scheme's handler")
        expect(
            QuicklinkDestination.handlerProbe("~/Notes", homeDirectory: "/Users/me")?.path
                == "/Users/me/Notes",
            "a plain path names its own file")
        expect(
            QuicklinkDestination.handlerProbe("~/Notes/{date}.md", homeDirectory: "/Users/me")
                == nil,
            "a templated path has no file to ask about yet")
        expect(QuicklinkDestination.handlerProbe("{clipboard | raw}") == nil, "a bare token has none")
    }

    static func detect(_ value: String) -> QuicklinkDestination? {
        QuicklinkDestination.detect(value, homeDirectory: home)
    }

    static func url(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            fail("harness could not build \(value)")
            exit(1)
        }
        return url
    }

    static func link(_ name: String, _ target: String = "https://example.com") -> Quicklink {
        Quicklink(name: name, link: target)
    }

    static func names(_ store: QuicklinkStore) -> [String] {
        store.quicklinks.map(\.name)
    }

    static func throwsError(_ store: QuicklinkStore, _ draft: Quicklink) -> QuicklinkError? {
        do {
            _ = try store.add(draft)
            return nil
        } catch {
            return error
        }
    }

    static func throwsArchiveError(_ data: Data) -> QuicklinkArchive.ArchiveError? {
        do {
            _ = try QuicklinkArchive.decode(data)
            return nil
        } catch {
            return error
        }
    }

    static func withStore(_ body: (QuicklinkStore) -> Void) {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        body(QuicklinkStore(directory: dir))
    }

    static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-quicklink-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a database the store didn't create, which is the only way to prove it reads one.
    @discardableResult
    static func sqlite(_ database: URL, _ sql: String) -> Set<String> {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [database.path, sql]
        task.standardOutput = pipe
        guard (try? task.run()) != nil else {
            fail("could not run sqlite3")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 { fail("sqlite3 failed: \(sql.prefix(60))") }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}
