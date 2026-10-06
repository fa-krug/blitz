// Standalone test for emoji search, compiling the real index and frequency store.
import Foundation

@main
@MainActor
struct EmojiSearchTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if !condition {
            print("FAIL: \(label)")
            failures += 1
        }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emoji-search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let frequent = FrequentEmojiStore(fileURL: directory.appendingPathComponent("frequency.json"))
        let index = EmojiIndex()
        await index.load()

        // Pins are authored order, not usage order: reloads retain it and imports sanitize it.
        let pinnedURL = directory.appendingPathComponent("pinned.json")
        try JSONEncoder().encode(["A", "", "A", "B"]).write(to: pinnedURL)
        let pinned = PinnedEmojiStore(fileURL: pinnedURL)
        expect(pinned.glyphs == ["A", "B"], "pin load drops blanks and duplicates")
        pinned.toggle("C")
        expect(pinned.glyphs == ["A", "B", "C"], "a new pin is appended")
        pinned.swap("C", with: "B")
        expect(pinned.glyphs == ["A", "C", "B"], "a swap exchanges exactly the two named pins")
        pinned.swap("A", with: "missing")
        expect(pinned.glyphs == ["A", "C", "B"], "a swap with an unpinned glyph changes nothing")
        pinned.toggle("C")
        expect(pinned.glyphs == ["A", "B"], "toggling an existing pin removes it")
        pinned.replace(["B", "B", "D", ""])
        expect(pinned.glyphs == ["B", "D"], "backup replacement preserves sanitized order")
        expect(
            PinnedEmojiStore(fileURL: pinnedURL).glyphs == ["B", "D"],
            "pin order survives a store reload")
        var reportedPersistenceFailure = false
        let unwritable = PinnedEmojiStore(fileURL: directory)
        unwritable.onPersistenceFailure = { reportedPersistenceFailure = true }
        unwritable.toggle("A")
        expect(reportedPersistenceFailure, "pin persistence failures are reported")

        for (query, glyph, maxRank) in [
            ("pray", "🙏", 5),
            (":+1:", "👍", 1),
            (":-1:", "👎", 1),
            (":rocket:", "🚀", 1),
            ("hand waving", "👋", 1),
            ("face joy", "😂", 1),
            ("tears joy", "😂", 1),
            ("birthday", "🎂", 1),
            ("party", "🎉", 1),
            ("states united", "🇺🇸", 1)
        ] {
            let results = index.search(query, frequent: frequent)
            expect(
                results.prefix(maxRank).contains { $0.glyph == glyph },
                "\(query) finds \(glyph) in the first \(maxRank) results")
        }

        // Packs for the Mac's languages join English, which keeps its ranking for every user.
        let resources = Bundle(path: "Blitz/Resources")!
        let multilingual = EmojiIndex()
        await multilingual.load(languages: ["fr-FR", "ja-JP", "en-US"], bundle: resources)
        for (query, glyph) in [
            ("poulet", "🐔"), ("gateau", "🎂"), ("gâteau d'anniversaire", "🎂"),
            ("allemagne", "🇩🇪"), ("ねこ", "🐱"), ("ネコ", "🐱"), ("寿司", "🍣")
        ] {
            expect(
                multilingual.search(query, frequent: frequent).prefix(3).contains { $0.glyph == glyph },
                "\(query) finds \(glyph) in the first 3 results")
        }
        expect(
            multilingual.search("poulet", frequent: frequent).contains { $0.glyph == "🍗" },
            "a localized keyword reaches every glyph CLDR files it under")
        for query in ["chicken", "birthday", "party", "pray", "red heart", "hand waving", "cat"] {
            expect(
                multilingual.search(query, frequent: frequent).prefix(5).map(\.glyph)
                    == index.search(query, frequent: frequent).prefix(5).map(\.glyph),
                "\(query) ranks as it does in English alone")
        }
        let english = EmojiIndex()
        await english.load(languages: ["en-US"], bundle: resources)
        expect(english.entries.map(\.keywords) == index.entries.map(\.keywords), "English reads no pack")

        let waving = index.search("hand waving", frequent: frequent)
        expect(waving.contains { $0.glyph == "👋" }, "multiword terms can match in either order")
        expect(
            !index.search("and waving", frequent: frequent).contains { $0.glyph == "👋" },
            "multiword terms must begin a word")
        expect(
            !index.search("hello missing", frequent: frequent).contains { $0.glyph == "👋" },
            "every multiword term must match")
        expect(index.search("quuxxyz", frequent: frequent).isEmpty, "unmatched query")
        expect(
            index.search("  RED\t HEART\n", frequent: frequent)
                == index.search("red heart", frequent: frequent),
            "case and whitespace do not change ranking")
        expect(
            index.search("piñata", frequent: frequent)
                == index.search("ＰＩＮＡＴＡ", frequent: frequent),
            "accent and width folding are preserved")

        let boundaries = EmojiIndex()
        await boundaries.load("A|zebra|ob|0|red,blue\nB|ladybug bug|ob|0|red")
        expect(
            !boundaries.search("db", frequent: frequent).contains { $0.glyph == "A" },
            "a fuzzy match cannot cross keyword boundaries")
        expect(
            boundaries.search("red blue", frequent: frequent).first?.glyph == "A",
            "separate query words may match separate keywords")
        expect(
            !boundaries.search("red,blue zebra", frequent: frequent).contains { $0.glyph == "A" },
            "one term cannot cross the serialized keyword separator")
        expect(
            boundaries.search("bug red", frequent: frequent).first?.glyph == "B",
            "a later word-start hit survives an earlier mid-word hit")
        for (query, glyph) in [
            ("face screaming in fear", "😱"), ("leaf fluttering in wind", "🍃"),
            ("family: man boy", "👨‍👦"), ("family: man  girl", "👨‍👧"),
            ("couple with heart: woman man", "👩‍❤️‍👨")
        ] {
            expect(
                index.search(query, frequent: frequent).first?.glyph == glyph,
                "full name still ranks first: \(query)")
        }

        await boundaries.load("A|zebra|ob|0|red blue\nB|blue red|ob|0|\nC|zebra|ob|0|red,blue")
        expect(
            boundaries.search("red blue", frequent: frequent).map(\.glyph) == ["A", "B", "C"],
            "a literal phrase outranks reordered name words, then separate keywords")
        expect(
            boundaries.search("blue red", frequent: frequent).first?.glyph == "B",
            "a literal full name outranks metadata matches")

        await boundaries.load(
            "A|red balloon|ob|0|\nB|zebra|ob|0|red\nC|redwood|ob|0|\nD|red|ob|0|")
        expect(
            boundaries.search("red", frequent: frequent).map(\.glyph) == ["D", "A", "B", "C"],
            "full name, complete leading word, exact keyword, then partial leading word")

        // Custom keywords: a store round trip, then the index ranks them above CLDR's.
        let keywordsURL = directory.appendingPathComponent("keywords.json")
        let keywordStore = EmojiKeywordStore(fileURL: keywordsURL)
        var pushed: [String: [String]]?
        keywordStore.onChange = { pushed = $0 }
        keywordStore.setTerms(["lgtm", " LGTM ", "ship it"], for: "👍")
        expect(keywordStore.terms(for: "👍") == ["lgtm", "ship it"], "stored terms are normalized")
        expect(pushed == ["👍": ["lgtm", "ship it"]], "a change is pushed to the index's owner")
        let revisionBeforeNoop = keywordStore.revision
        keywordStore.setTerms(["lgtm", "ship it"], for: "👍")
        expect(keywordStore.revision == revisionBeforeNoop, "an unedited save changes nothing")
        expect(
            EmojiKeywordStore(fileURL: keywordsURL).keywords == ["👍": ["lgtm", "ship it"]],
            "keywords survive a store reload")
        keywordStore.setTerms([], for: "👍")
        expect(keywordStore.keywords.isEmpty, "emptying the field clears the glyph's terms")
        keywordStore.replace(["👍": ["yes", "yes"], "": ["x"]])
        expect(keywordStore.keywords == ["👍": ["yes"]], "a backup replacement is normalized")
        keywordStore.removeAll()
        expect(
            EmojiKeywordStore(fileURL: keywordsURL).keywords.isEmpty,
            "a reset survives a store reload")
        var keywordFailure = false
        let unwritableKeywords = EmojiKeywordStore(fileURL: directory)
        unwritableKeywords.onPersistenceFailure = { keywordFailure = true }
        unwritableKeywords.setTerms(["x"], for: "A")
        expect(keywordFailure, "keyword persistence failures are reported")

        let custom = EmojiIndex()
        await custom.load("A|zebra|ob|0|red\nB|red balloon|ob|0|\nC|apple|ob|0|\nD|redwood|ob|0|")
        expect(
            custom.search("crimson", frequent: frequent).isEmpty,
            "an unknown word finds nothing before it is added")
        custom.setCustomKeywords(["C": ["crimson", "red"]])
        expect(
            custom.search("crimson", frequent: frequent).map(\.glyph) == ["C"],
            "an edit reaches search without a reload")
        expect(
            custom.search("red", frequent: frequent).map(\.glyph) == ["C", "B", "A", "D"],
            "an exact custom keyword outranks a leading name word and a catalog keyword")
        custom.setCustomKeywords(["C": ["crimson tide"]])
        expect(
            custom.search("tide crimson", frequent: frequent).first?.glyph == "C",
            "multiword terms may match inside a custom keyword")
        custom.setCustomKeywords([:])
        expect(
            custom.search("crimson", frequent: frequent).isEmpty,
            "clearing keywords invalidates the memo")
        await custom.load("A|zebra|ob|0|red")
        custom.setCustomKeywords(["A": ["blue"]])
        await custom.load("A|zebra|ob|0|red")
        expect(
            custom.search("blue", frequent: frequent).first?.glyph == "A",
            "custom keywords outlive a catalog reload")

        frequent.record("🙏")
        expect(index.search("pray", frequent: frequent).first?.glyph == "🙏", "usage reranks a tie")

        let ranking = EmojiIndex()
        await ranking.load("A|alpha|ob|0|\nB|beta|ob|0|alpha")
        let rankingFrequency = FrequentEmojiStore(
            fileURL: directory.appendingPathComponent("ranking-frequency.json"))
        rankingFrequency.record("B")
        expect(
            ranking.search("alpha", frequent: rankingFrequency).first?.glyph == "A",
            "usage cannot overtake a stronger text match")

        await ranking.load("A|alpha|ob|0|red\nB|beta|ob|0|red")
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        rankingFrequency.replace([
            FrequentEmoji(glyph: "A", count: 2, lastUsed: first),
            FrequentEmoji(glyph: "B", count: 1, lastUsed: second)
        ])
        expect(rankingFrequency.records.map(\.glyph) == ["B", "A"], "history uses recency, not counts")
        expect(
            ranking.search("red", frequent: rankingFrequency).first?.glyph == "A",
            "count breaks text ties before recency")
        rankingFrequency.record("A")
        expect(rankingFrequency.records.map(\.glyph) == ["A", "B"], "reusing an emoji moves it to the front")
        expect(
            FrequentEmojiStore(fileURL: directory.appendingPathComponent("ranking-frequency.json"))
                .records.map(\.glyph) == ["A", "B"],
            "history order survives a reload")
        rankingFrequency.replace([
            FrequentEmoji(glyph: "A", count: 2, lastUsed: first),
            FrequentEmoji(glyph: "B", count: 2, lastUsed: second)
        ])
        expect(
            ranking.search("red", frequent: rankingFrequency).first?.glyph == "B",
            "recency breaks equal-count ties and replacement invalidates the memo")
        rankingFrequency.replace([])
        expect(
            ranking.search("red", frequent: rankingFrequency).first?.glyph == "A",
            "clearing usage restores catalog order")

        let otherFrequency = FrequentEmojiStore(
            fileURL: directory.appendingPathComponent("other-frequency.json"))
        otherFrequency.record("B")
        expect(
            ranking.search("red", frequent: otherFrequency).first?.glyph == "B",
            "another frequency store is scored independently")
        expect(
            ranking.search("red", frequent: frequent).first?.glyph == "A",
            "stores with equal revisions cannot share a cached ranking")

        otherFrequency.replace([
            FrequentEmoji(glyph: "B", count: 2, lastUsed: second),
            FrequentEmoji(glyph: "B", count: 1, lastUsed: first)
        ])
        expect(
            ranking.search("red", frequent: otherFrequency).first?.glyph == "B",
            "duplicate imported glyphs do not crash search")
        expect(
            otherFrequency.records.map(\.glyph) == ["B"] && otherFrequency.records.first?.count == 2,
            "an import keeps only the newest tally of a repeated glyph")

        let history = FrequentEmojiStore(fileURL: directory.appendingPathComponent("history.json"))
        history.replace(
            (0..<300).map {
                FrequentEmoji(
                    glyph: String($0), count: 100, lastUsed: Date(timeIntervalSince1970: Double($0)))
            })
        history.record("new")
        expect(history.records.first?.glyph == "new", "new usage leads a full history")
        expect(
            history.records.count == 300 && !history.records.contains(where: { $0.glyph == "0" }),
            "a full history evicts the oldest emoji")

        expect(index.search("face", frequent: frequent, limit: 1).count == 1, "one-result limit")
        expect(index.search("face", frequent: frequent, limit: 12).count == 12, "limit is memoized")
        expect(index.search(" ", frequent: frequent).isEmpty, "empty query")
        expect(index.search("face", frequent: frequent, limit: 0).isEmpty, "zero limit")

        if failures == 0 {
            print("emoji-search-test: all checks passed")
        } else {
            print("emoji-search-test: \(failures) failure(s)")
            exit(1)
        }
    }
}
