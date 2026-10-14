import Foundation

// The personal and context catalogs, pure; no contact, note, clipboard or app is touched.
@main
struct PersonalToolTests {
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

        func refusal(_ body: () throws -> Void) -> String? {
            do {
                try body()
                return nil
            } catch {
                return (error as? AIToolArguments.Invalid)?.message ?? "\(error)"
            }
        }

        func required(_ schema: JSONValue) -> [String] {
            schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        func properties(_ schema: JSONValue) -> Set<String> {
            Set(schema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!

        // MARK: Schemas, wire names and rows

        let contacts = ContactToolCatalog.tools()
        let notes = NoteToolCatalog.tools(read: true, append: true)
        let clipboard = ClipboardToolCatalog.tools()
        let snippets = SnippetToolCatalog.tools()
        let quicklinks = QuicklinkToolCatalog.tools()
        let context = ContextToolCatalog.tools(frontmostApp: true, selectedText: true, clipboard: true)
        check("contacts_search is one tool", contacts.map(\.name) == ["contacts_search"])
        check("a search needs a query", required(contacts[0].parameters) == ["query"])
        check(
            "a search takes a query and a limit",
            properties(contacts[0].parameters) == ["query", "limit"])
        check("the note tools, read first", notes.map(\.name) == ["note_read", "note_append"])
        check("reading the note takes nothing", properties(notes[0].parameters).isEmpty)
        check("adding needs text", required(notes[1].parameters) == ["text"])
        check(
            "each note half is offered on its own",
            NoteToolCatalog.tools(read: true, append: false).map(\.name) == ["note_read"]
                && NoteToolCatalog.tools(read: false, append: true).map(\.name) == ["note_append"]
                && NoteToolCatalog.tools(read: false, append: false).isEmpty)
        check("clipboard_history is one tool", clipboard.map(\.name) == ["clipboard_history"])
        check("history needs nothing", required(clipboard[0].parameters).isEmpty)
        check(
            "the snippet tools, list first",
            snippets.map(\.name) == ["snippets_list", "snippets_read"])
        check("reading a snippet needs a name", required(snippets[1].parameters) == ["name"])
        check("quicklinks_list is one tool", quicklinks.map(\.name) == ["quicklinks_list"])
        check(
            "the context tools, app first",
            context.map(\.name)
                == ["context_frontmost_app", "context_selected_text", "context_clipboard"])
        check(
            "each context tool is offered on its own",
            ContextToolCatalog.tools(frontmostApp: false, selectedText: true, clipboard: false)
                .map(\.name) == ["context_selected_text"])
        check("context tools take nothing", context.allSatisfy { properties($0.parameters).isEmpty })
        let rows: [(names: [String], row: AgentTool)] = [
            (contacts.map(\.name), .contactsRead), ([NoteToolCatalog.readName], .noteRead),
            ([NoteToolCatalog.appendName], .noteWrite), (clipboard.map(\.name), .clipboardRead),
            (snippets.map(\.name) + quicklinks.map(\.name), .snippetsRead),
            ([ContextToolCatalog.frontmostAppName], .frontmostApp),
            ([ContextToolCatalog.selectedTextName], .selectedText),
            ([ContextToolCatalog.clipboardName], .currentClipboard)
        ]
        for (names, row) in rows {
            check(
                "\(names.joined(separator: ", ")) map to \(row.title)",
                names.allSatisfy { AgentTool(builtInToolName: $0) == row })
            check("\(row.title) is hosted", row.isHosted)
        }
        for name in context.map(\.name) {
            check(
                "the catalog names \(name)'s row as AgentTool does",
                ContextToolCatalog.row(for: name) == AgentTool(builtInToolName: name)
                    && ContextToolCatalog.handles(name))
        }
        check("an unknown context name has no row", ContextToolCatalog.row(for: "context_x") == nil)
        check(
            "every read row may be allowed for the chat, the note's addition never",
            [AgentTool.contactsRead, .noteRead, .clipboardRead, .snippetsRead, .frontmostApp,
                .selectedText, .currentClipboard].allSatisfy { $0.isReadOnly && $0.canAllowForSession }
                && !AgentTool.noteWrite.isReadOnly && !AgentTool.noteWrite.canAllowForSession)
        check(
            "reads ask and the addition is denied by default",
            AgentRules.defaultDecision(for: .contactsRead) == .ask
                && AgentRules.defaultDecision(for: .currentClipboard) == .ask
                && AgentRules.defaultDecision(for: .noteWrite) == .deny)

        // MARK: Contacts

        check(
            "a search reads the query, ten by default",
            (try? ContactToolCatalog.request(arguments: #"{"query":"  Greg "}"#))
                == ContactToolCatalog.Request(query: "Greg", limit: 10))
        check(
            "a limit is capped at 25",
            (try? ContactToolCatalog.request(arguments: #"{"query":"a","limit":400}"#))?.limit
                == 25)
        check(
            "a limit sent as text is read",
            (try? ContactToolCatalog.request(arguments: #"{"query":"a","limit":"3"}"#))?.limit == 3)
        check(
            "no query is refused",
            refusal { _ = try ContactToolCatalog.request(arguments: "{}") }
                == "\u{201C}query\u{201D} is required.")
        check(
            "a zero limit is refused",
            refusal { _ = try ContactToolCatalog.request(arguments: #"{"query":"a","limit":0}"#) }
                == "\u{201C}limit\u{201D} must be a whole number from 1.")
        check(
            "arguments that are not an object are refused",
            refusal { _ = try ContactToolCatalog.request(arguments: "[1]") }
                == "The arguments must be one JSON object.")
        let forbidden: Set = ["note", "imageData", "thumbnailImageData", "imageDataAvailable"]
        check(
            "a search never fetches the note or an image",
            forbidden.isDisjoint(with: ContactToolCatalog.fetchedKeys))
        check(
            "it fetches company, numbers, addresses and birthday",
            Set(ContactToolCatalog.fetchedKeys) == [
                "organizationName", "phoneNumbers", "emailAddresses", "postalAddresses", "birthday"
            ])
        typealias Field = ContactToolCatalog.Card.Field
        let card = ContactToolCatalog.Card(
            name: "Greg Smith", organization: "Acme",
            emails: [Field(label: "work", value: "greg@acme.test")],
            phones: [Field(label: nil, value: "+49 151 234")],
            addresses: [Field(label: "home", value: "1 Main St, Springfield")],
            birthday: .init(year: nil, month: 4, day: 2))
        let bare = ContactToolCatalog.Card(
            name: "Acme", organization: "", emails: [], phones: [], addresses: [],
            birthday: .init(year: 1980, month: 12, day: 24))
        let found = ContactToolCatalog.answer([card, bare], query: "Greg", matches: 7)
        check(
            "an answer is sorted-key JSON with the count of all matches",
            found == #"{"contacts":[{"addresses":[{"label":"home","value":"1 Main St, Springfield"}],"#
                + #""birthday":"--04-02","emails":[{"label":"work","value":"greg@acme.test"}],"#
                + #""name":"Greg Smith","organization":"Acme","phones":[{"value":"+49 151 234"}]},"#
                + #"{"birthday":"1980-12-24","name":"Acme"}],"matches":7,"query":"Greg","shown":2}"#)
        check(
            "a card's JSON carries no note or image field",
            !found.contains("\"note") && !found.contains("image"))
        check(
            "no match is a sentence",
            ContactToolCatalog.answer([], query: "Zed", matches: 0)
                == "No contact matches \u{201C}Zed\u{201D}.")
        check(
            "a birthday with its year is a whole date",
            ContactToolCatalog.text(of: .init(year: 1990, month: 1, day: 5)) == "1990-01-05")
        check(
            "the search dialog names the query and what is seen",
            AgentPrompt.searchContacts("Greg").title
                == "Let the agent search your contacts for \u{201C}Greg\u{201D}?"
                && AgentPrompt.searchContacts("Greg").message?.contains("never its notes or photo")
                    == true)

        // MARK: The note

        check(
            "note_read takes nothing",
            (try? NoteToolCatalog.request(name: NoteToolCatalog.readName, arguments: "")) == .read)
        check(
            "an addition keeps its text as sent",
            (try? NoteToolCatalog.request(
                name: NoteToolCatalog.appendName, arguments: #"{"text":"  - [ ] milk\n"}"#))
                == .append("  - [ ] milk\n"))
        check(
            "a blank addition is refused",
            refusal {
                _ = try NoteToolCatalog.request(
                    name: NoteToolCatalog.appendName, arguments: #"{"text":" \n "}"#)
            } == "\u{201C}text\u{201D} is required.")
        let long = String(repeating: "a", count: NoteToolCatalog.appendLimit + 1)
        check(
            "an addition over 20 000 characters is refused",
            refusal {
                _ = try NoteToolCatalog.request(
                    name: NoteToolCatalog.appendName, arguments: #"{"text":"\#(long)"}"#)
            } == "\u{201C}text\u{201D} holds at most 20000 characters.")
        check(
            "an addition starts its own line",
            NoteToolCatalog.addition("b", to: "a") == "\nb"
                && NoteToolCatalog.addition("b", to: "a\n") == "b"
                && NoteToolCatalog.addition("b", to: "") == "b")
        check(
            "a read names the note",
            NoteToolCatalog.answer(title: "Plan", source: "# Plan\n")
                == "The note \u{201C}Plan\u{201D}:\n\n# Plan\n")
        check(
            "an empty note says so",
            NoteToolCatalog.answer(title: "Plan", source: "")
                == "The note \u{201C}Plan\u{201D} is empty.")
        let big = String(repeating: "é", count: NoteToolCatalog.readLimit)
        let clippedNote = NoteToolCatalog.answer(title: "Big", source: big)
        let noteBody = clippedNote.components(separatedBy: "\n\n").last ?? ""
        check(
            "a long note is cut at 64 KB on a character",
            noteBody.utf8.count == NoteToolCatalog.readLimit && noteBody.allSatisfy { $0 == "é" }
                && clippedNote.hasPrefix(
                    "The note \u{201C}Big\u{201D}, cut to its first 65536 of 131072 bytes"))
        check(
            "the answer counts what was added",
            NoteToolCatalog.appended("hi", title: "Plan")
                == "Added 2 characters to the end of \u{201C}Plan\u{201D}.")
        let readNote = AgentPrompt.readNote("Plan")
        check(
            "reading the note asks with Allow This Chat",
            readNote.title == "Let the agent read your note?"
                && readNote.choices == [.allowOnce("Allow"), .allowThisChat, .refuse("Don't Allow")])
        let append = AgentPrompt.appendToNote("Plan", text: String(repeating: "x", count: 400))
        check(
            "adding asks each time and shows the text, clipped",
            append.title == "Let the agent add to your note?"
                && append.choices == [.allowOnce("Allow"), .refuse("Don't Allow")]
                && append.message?.hasSuffix(String(repeating: "x", count: 300) + "\u{2026}") == true
                && append.message?.contains("\u{201C}Plan\u{201D}") == true)

        // MARK: Clipboard history

        check(
            "history defaults to ten, no query",
            (try? ClipboardToolCatalog.request(arguments: "{}"))
                == ClipboardToolCatalog.Request(query: nil, limit: 10))
        check(
            "its limit is capped at 50",
            (try? ClipboardToolCatalog.request(arguments: #"{"limit":99}"#))?.limit == 50)
        check(
            "a negative limit is refused",
            refusal { _ = try ClipboardToolCatalog.request(arguments: #"{"limit":-1}"#) }
                == "\u{201C}limit\u{201D} must be a whole number from 1.")
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        func clip(
            _ text: String?, _ minutes: Int, kind: ClipboardItem.Kind = .text,
            from source: String? = "com.apple.Safari", pinned: Bool = false, title: String? = nil
        ) -> ClipboardItem {
            ClipboardItem(
                id: UUID(), kind: kind, text: text,
                imagePath: kind == .image ? "/tmp/blitz-test.png" : nil,
                createdAt: start.addingTimeInterval(Double(minutes) * 60), sourceBundleID: source,
                pinnedAt: pinned ? start : nil, title: title)
        }
        let old = clip("old note", 0, pinned: true, title: "Keep")
        let image = clip(nil, 5, kind: .image, from: nil)
        let file = clip("/Users/tester/report.pdf", 6, kind: .file, from: "com.apple.finder")
        let ignored = clip("from the password app", 7, from: "com.agilebits.onepassword7")
        let fresh = clip("fresh text", 8)
        let history = [old, image, file, ignored, fresh]
        let ignoredApps: Set = ["com.agilebits.onepassword7"]
        check(
            "entries are newest first, without an ignored app's copies",
            ClipboardToolCatalog.entries(history, query: nil, ignoredApps: ignoredApps).map(\.id)
                == [fresh.id, file.id, image.id, old.id])
        check(
            "a query matches text or title",
            ClipboardToolCatalog.entries(history, query: "keep", ignoredApps: []).map(\.id)
                == [old.id]
                && ClipboardToolCatalog.entries(history, query: "FRESH", ignoredApps: [])
                    .map(\.id) == [fresh.id])
        check(
            "an ignored app's copy is never found by a query",
            ClipboardToolCatalog.entries(history, query: "password", ignoredApps: ignoredApps)
                .isEmpty)
        let listing = ClipboardToolCatalog.listing(
            [fresh, file, image, old], request: .init(query: nil, limit: 4), total: 4,
            imageSizes: [image.id: .init(width: 640, height: 480)],
            appNames: ["com.apple.Safari": "Safari"], calendar: calendar)
        check(
            "a listing numbers each entry with when, where, pin and title",
            listing == "4 of 4 clipboard entries, newest first:\n\n"
                + "1. 2026-10-14T09:08 \u{00B7} from Safari\nfresh text\n\n"
                + "2. 2026-10-14T09:06 \u{00B7} from com.apple.finder\n"
                + "[file] /Users/tester/report.pdf\n\n"
                + "3. 2026-10-14T09:05\n[image] 640 \u{00D7} 480 pixels\n\n"
                + "4. 2026-10-14T09:00 \u{00B7} from Safari \u{00B7} pinned \u{00B7} titled "
                + "\u{201C}Keep\u{201D}\nold note")
        let unsized = ClipboardToolCatalog.listing(
            [image], request: .init(query: "x", limit: 1), total: 1, imageSizes: [:],
            appNames: [:], calendar: calendar)
        check(
            "an image without a readable size is still named",
            unsized == "1 of 1 clipboard entry containing \u{201C}x\u{201D}, newest first:\n\n"
                + "1. 2026-10-14T09:05\n[image]")
        let huge = clip(String(repeating: "z", count: ClipboardToolCatalog.entryLimit + 5), 9)
        check(
            "a long entry is cut and says how much is left",
            ClipboardToolCatalog.listing(
                [huge], request: .init(query: nil, limit: 1), total: 1, imageSizes: [:],
                appNames: [:], calendar: calendar
            ).hasSuffix(
                String(repeating: "z", count: ClipboardToolCatalog.entryLimit)
                    + "\u{2026} [5 more characters]"))
        check(
            "nothing found is a sentence",
            ClipboardToolCatalog.listing(
                [], request: .init(query: "q", limit: 3), total: 0, imageSizes: [:],
                appNames: [:], calendar: calendar) == "No clipboard entry contains \u{201C}q\u{201D}."
                && ClipboardToolCatalog.listing(
                    [], request: .init(query: nil, limit: 3), total: 0, imageSizes: [:],
                    appNames: [:], calendar: calendar) == "The clipboard history is empty.")
        let historyPrompt = AgentPrompt.readClipboardHistory(query: "foo", limit: 5)
        check(
            "the history dialog names the reach and the query",
            historyPrompt.title == "Let the agent read your clipboard history?"
                && historyPrompt.message?.hasPrefix(
                    "It sees up to 5 of your latest copies that contain \u{201C}foo\u{201D}")
                    == true
                && historyPrompt.message?.hasSuffix(
                    "What it reads is sent to the model\u{2019}s provider.") == true)

        // MARK: Snippets and quicklinks

        let library = [
            Snippet(name: "Signature", text: "Best regards,\n\tSascha", keyword: ";sig"),
            Snippet(name: "Address", text: "1 Main St"),
            Snippet(name: "Old", text: "gone", isEnabled: false),
            Snippet(name: "Twin", text: "one", keyword: ";t1"),
            Snippet(name: "Twin", text: "two", keyword: ";t2")
        ]
        check(
            "snippets_list takes an optional query",
            (try? SnippetToolCatalog.request(name: SnippetToolCatalog.listName, arguments: "{}"))
                == .list(query: nil))
        check(
            "snippets_read needs a name",
            refusal {
                _ = try SnippetToolCatalog.request(name: SnippetToolCatalog.readName, arguments: "{}")
            } == "\u{201C}name\u{201D} is required.")
        check(
            "a listing leaves a disabled snippet out and previews one line",
            SnippetToolCatalog.listing(library, query: nil)
                == "4 snippets, tab-separated: name, keyword, start of text:\n"
                + "Signature\tkeyword ;sig\tBest regards, Sascha\n"
                + "Address\tno keyword\t1 Main St\nTwin\tkeyword ;t1\tone\nTwin\tkeyword ;t2\ttwo")
        check(
            "a query matches name, keyword or text",
            SnippetToolCatalog.listed(library, query: "MAIN").map(\.name) == ["Address"]
                && SnippetToolCatalog.listed(library, query: ";sig").map(\.name) == ["Signature"]
                && SnippetToolCatalog.listing(library, query: "gone")
                    == "No snippet contains \u{201C}gone\u{201D}.")
        check(
            "a preview is clipped",
            SnippetToolCatalog.preview(of: String(repeating: "w", count: 100))
                == String(repeating: "w", count: 80) + "\u{2026}")
        check(
            "a snippet is found by name or keyword, case aside",
            (try? SnippetToolCatalog.snippet(named: "signature", in: library))?.name == "Signature"
                && (try? SnippetToolCatalog.snippet(named: ";t2", in: library))?.text == "two")
        check(
            "two of one name are told apart by keyword",
            refusal { _ = try SnippetToolCatalog.snippet(named: "Twin", in: library) }
                == "More than one snippet is called \u{201C}Twin\u{201D}. Name one by its "
                + "keyword: \u{201C};t1\u{201D}, \u{201C};t2\u{201D}.")
        check(
            "a disabled snippet is never found",
            refusal { _ = try SnippetToolCatalog.snippet(named: "Old", in: library) }?
                .hasPrefix("There is no snippet called \u{201C}Old\u{201D}.") == true)
        check(
            "a miss names near snippets",
            refusal { _ = try SnippetToolCatalog.snippet(named: "Sig", in: library) }
                == "There is no snippet called \u{201C}Sig\u{201D}. Snippets with a similar name: "
                + "\u{201C}Signature\u{201D}. snippets_list lists them all.")
        check(
            "a read is the template as written",
            SnippetToolCatalog.answer(library[0])
                == "The snippet \u{201C}Signature\u{201D}, keyword ;sig:\n\nBest regards,\n\tSascha")
        let bigSnippet = Snippet(
            name: "Big", text: String(repeating: "ü", count: SnippetToolCatalog.readLimit))
        check(
            "a long snippet is cut at 64 KB",
            SnippetToolCatalog.answer(bigSnippet).hasPrefix(
                "The snippet \u{201C}Big\u{201D}, cut to its first 65536 of 131072 bytes"))
        let links = [
            Quicklink(name: "Search Docs", link: "https://docs.test/?q={query}", tags: ["work"]),
            Quicklink(name: "Hidden", link: "https://x.test", isEnabled: false),
            Quicklink(name: "Home", link: "~/")
        ]
        check(
            "quicklinks_list takes an optional query",
            (try? QuicklinkToolCatalog.query(arguments: #"{"query":" work "}"#)) == "work")
        check(
            "a quicklink listing shows enabled ones, their template and tags",
            QuicklinkToolCatalog.listing(links, query: nil)
                == "2 quicklinks, tab-separated: name, link, tags:\n"
                + "Search Docs\thttps://docs.test/?q={query}\twork\nHome\t~/")
        check(
            "a quicklink query matches a tag",
            QuicklinkToolCatalog.listing(links, query: "WORK").hasPrefix("1 quicklink,")
                && QuicklinkToolCatalog.listing(links, query: "hidden")
                    == "No quicklink\u{2019}s name or tag contains \u{201C}hidden\u{201D}.")
        check(
            "the snippet and quicklink dialogs",
            AgentPrompt.readSnippets(nil).title == "Let the agent list your snippets?"
                && AgentPrompt.readSnippets("Signature").title
                    == "Let the agent read the snippet \u{201C}Signature\u{201D}?"
                && AgentPrompt.readQuicklinks().title == "Let the agent list your quicklinks?"
                && AgentPrompt.readQuicklinks().choices.contains(.allowThisChat))

        // MARK: Context

        check("no arguments is fine", refusal { try ContextToolCatalog.checkArguments("") } == nil)
        check(
            "arguments must still be an object",
            refusal { try ContextToolCatalog.checkArguments("nope") }
                == "The arguments must be one JSON object.")
        let safari = ContextToolCatalog.App(name: "Safari", bundleID: "com.apple.Safari")
        check(
            "the frontmost answer names the app, its bundle and its window",
            ContextToolCatalog.frontmostAnswer(safari, window: .title("Start"))
                == "The user is working in Safari (com.apple.Safari). Its front window is titled "
                + "\u{201C}Start\u{201D}.")
        check(
            "without Accessibility the title is said to be unknown",
            ContextToolCatalog.frontmostAnswer(safari, window: .needsAccessibility)
                .hasSuffix("Blitz does not have Accessibility access."))
        check(
            "a window without a title says so",
            ContextToolCatalog.frontmostAnswer(
                .init(name: "Tool", bundleID: nil), window: .none)
                == "The user is working in Tool. It shows no window with a title.")
        check(
            "a selection names its app",
            ContextToolCatalog.selectionAnswer("hello", in: safari) == "Selected in Safari:\n\nhello")
        let bigSelection = ContextToolCatalog.selectionAnswer(
            String(repeating: "\u{1F600}", count: 20_000), in: safari)
        let selectionBody = bigSelection.components(separatedBy: "\n\n").last ?? ""
        check(
            "a long selection is cut at 64 KB between characters",
            selectionBody.utf8.count == ContextToolCatalog.readLimit
                && selectionBody.unicodeScalars.allSatisfy { $0 == "\u{1F600}" })
        func pasteboard(
            _ types: [String], text: String? = nil, files: [String] = []
        ) -> ContextToolCatalog.Clipboard {
            ContextToolCatalog.clipboard(
                .init(types: types, text: text, filePaths: files),
                secretTypes: PasteboardSensitivity.markerTypes)
        }
        for marker in [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            "com.apple.is-sensitive"
        ] {
            check(
                "\(marker) is never read, text and all",
                pasteboard(["public.utf8-plain-text", marker], text: "hunter2") == .sensitive)
        }
        check(
            "the markers are the clipboard history's own",
            PasteboardSensitivity.markerTypes == [
                "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                "com.apple.is-sensitive"
            ])
        check(
            "a marker-free copy is read",
            pasteboard(["public.utf8-plain-text"], text: "hi") == .text("hi"))
        check(
            "files win over the names Finder adds as text",
            pasteboard(["public.file-url", "public.utf8-plain-text"], text: "a.pdf", files: ["/a.pdf"])
                == .files(["/a.pdf"]))
        check("nothing at all is empty", pasteboard([]) == .empty)
        check(
            "empty text with other types is described",
            pasteboard(["public.png"], text: "") == .other(["public.png"]))
        check(
            "the dialog names the kind and size, never the content",
            ContextToolCatalog.summary(of: .text("secret words")) == "text, 12 characters"
                && ContextToolCatalog.summary(of: .files(["/a", "/b"])) == "2 files\u{2019} paths"
                && ContextToolCatalog.summary(of: .other(["public.tiff"])) == "an image"
                && ContextToolCatalog.summary(of: .other(["com.adobe.pdf"])) == "a PDF"
                && ContextToolCatalog.summary(of: .other(["x.y"])) == "content that is not text")
        check(
            "text comes back whole",
            ContextToolCatalog.clipboardAnswer(.text("hi")) == "The clipboard holds this text:\n\nhi")
        check(
            "files come back as paths",
            ContextToolCatalog.clipboardAnswer(.files(["/a", "/b"]))
                == "The clipboard holds 2 copied files:\n/a\n/b")
        let types = (1...7).map { "type.\($0)" }
        check(
            "anything else is named by its first types",
            ContextToolCatalog.clipboardAnswer(.other(types))
                == "The clipboard holds no text, only content that is not text (type.1, type.2, "
                + "type.3, type.4, type.5 and 2 more).")
        check(
            "long clipboard text is cut at 64 KB",
            ContextToolCatalog.clipboardAnswer(
                .text(String(repeating: "a", count: ContextToolCatalog.readLimit + 10))
            ).hasPrefix("The clipboard holds text, cut here to its first 65536 of 65546 bytes"))
        check(
            "a secret answers with its refusal",
            ContextToolCatalog.clipboardAnswer(.sensitive) == ContextToolCatalog.sensitive)
        check(
            "the context dialogs name what is read and the provider",
            AgentPrompt.seeFrontmostApp("Safari").title
                == "Let the agent see that you are using Safari?"
                && AgentPrompt.readSelectedText(in: "Safari").title
                    == "Let the agent read the text selected in Safari?"
                && AgentPrompt.readSelectedText(in: "Safari").message
                    == "What it reads is sent to the model\u{2019}s provider."
                && AgentPrompt.readClipboard("text, 3 characters").message
                    == "It reads what you copied last: text, 3 characters. What it reads is sent "
                    + "to the model\u{2019}s provider.")
        check(
            "the refusals are sentences",
            ContextToolCatalog.noSelection(safari) == "Nothing is selected in Safari."
                && ContextToolCatalog.needsAccessibility.hasPrefix(
                    "Blitz does not have Accessibility access")
                && ContextToolCatalog.clipboardChanged.hasSuffix("so nothing was read."))
        check(
            "a denied row's sentence names what was refused",
            AgentRefusal.denied.message(for: .noteWrite)
                == "Blitz's agent rules do not let the model add to the note."
                && AgentRefusal.declined.message(for: .currentClipboard)
                    == "The user declined to let the model read the clipboard.")

        print(failures == 0 ? "\nAll personal tool tests passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
