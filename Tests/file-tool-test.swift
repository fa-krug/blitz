import Foundation

// Works in a UUID-named temporary folder, standing in for home; the Trash is a folder there too.
@main
struct FileToolTests {
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

        // MARK: Schema

        let names = [
            FileToolCatalog.listName, FileToolCatalog.readName, FileToolCatalog.writeName,
            FileToolCatalog.moveName, FileToolCatalog.trashName
        ]
        check(
            "the five wire names",
            names == ["files_list", "files_read", "files_write", "files_move", "files_trash"])
        check(
            "both rows offer all five, in order",
            FileToolCatalog.tools(read: true, write: true).map(\.name) == names)
        check(
            "the read row offers list and read",
            FileToolCatalog.tools(read: true, write: false).map(\.name)
                == ["files_list", "files_read"])
        check(
            "the write row offers write, move and trash",
            FileToolCatalog.tools(read: false, write: true).map(\.name)
                == ["files_write", "files_move", "files_trash"])
        check("neither row offers nothing", FileToolCatalog.tools(read: false, write: false).isEmpty)
        check("the catalog claims its names", names.allSatisfy(FileToolCatalog.handles))
        check("and no other", !FileToolCatalog.handles("shell_run_command"))
        check("there is no delete tool", !FileToolCatalog.handles("files_delete"))
        let tools = FileToolCatalog.tools(read: true, write: true)
        func schema(_ name: String) -> [String: JSONValue]? {
            tools.first { $0.name == name }?.parameters.objectValue
        }
        func required(_ name: String) -> JSONValue? { schema(name)?["required"] }
        check("list needs nothing", required("files_list") == .array([]))
        check("read needs a path", required("files_read") == .array([.string("path")]))
        check(
            "write needs a path and content",
            required("files_write") == .array([.string("path"), .string("content")]))
        check("move needs from and to", required("files_move") == .array([.string("from"), .string("to")]))
        check("trash needs a path", required("files_trash") == .array([.string("path")]))
        check(
            "write's mode is an enum of the three",
            schema("files_write")?["properties"]?.objectValue?["mode"]?.objectValue?["enum"]
                == .array([.string("create"), .string("overwrite"), .string("append")]))
        check(
            "every description says the user may decline and some folders are refused",
            tools.allSatisfy {
                $0.description.contains("may decline") && $0.description.contains("always refused")
            })
        check("every tool is a Files row", tools.allSatisfy { $0.origin == "Files" })

        // MARK: Reading a call

        let home = "/Users/tester"
        typealias Reading = Result<FileToolCatalog.Request, AIToolArguments.Invalid>
        func read(_ name: String, _ arguments: String) -> Reading {
            Result { () throws(AIToolArguments.Invalid) in
                try FileToolCatalog.request(name: name, arguments: arguments, homeDirectory: home)
            }
        }
        func accepted(_ name: String, _ arguments: String) -> FileToolCatalog.Request? {
            try? read(name, arguments).get()
        }
        func refusal(_ name: String, _ arguments: String) -> String? {
            guard case .failure(let invalid) = read(name, arguments) else { return nil }
            return invalid.message
        }

        check(
            "a bare list is the home folder, flat, without hidden items",
            accepted("files_list", "") == .list(path: home, recursive: false, includeHidden: false))
        check(
            "list flags are read, a string true too",
            accepted("files_list", #"{"path":"~/Projects","recursive":true,"includeHidden":"true"}"#)
                == .list(path: "/Users/tester/Projects", recursive: true, includeHidden: true))
        check(
            "a flag that is not a boolean is refused, naming it",
            refusal("files_list", #"{"recursive":"maybe"}"#)?.contains("recursive") == true)
        check(
            "a relative path is taken from home",
            accepted("files_read", #"{"path":"notes/todo.md"}"#)
                == .read(path: "/Users/tester/notes/todo.md", offset: 1, limit: nil))
        check(
            "dots are resolved",
            accepted("files_read", #"{"path":"~/a/../b/./c.txt"}"#)?.paths == ["/Users/tester/b/c.txt"])
        check(
            "an absolute path is kept",
            accepted("files_read", #"{"path":"/etc/hosts"}"#)?.paths == ["/etc/hosts"])
        check(
            "offset and limit are read, as text too",
            accepted("files_read", #"{"path":"a","offset":5,"limit":"10"}"#)
                == .read(path: "/Users/tester/a", offset: 5, limit: 10))
        check(
            "an offset of 0 is refused",
            refusal("files_read", #"{"path":"a","offset":0}"#)?.contains("offset") == true)
        check(
            "a limit that is not a number is refused",
            refusal("files_read", #"{"path":"a","limit":"lots"}"#)?.contains("limit") == true)
        check(
            "a null limit reads as none",
            accepted("files_read", #"{"path":"a","limit":null}"#)
                == .read(path: "/Users/tester/a", offset: 1, limit: nil))
        check("read needs its path", refusal("files_read", "{}")?.contains("path") == true)
        check(
            "content keeps its whitespace, and create is the default",
            accepted("files_write", #"{"path":"a.txt","content":"  hi\n"}"#)
                == .write(
                    path: "/Users/tester/a.txt", content: "  hi\n", mode: .create,
                    createFolders: false))
        check(
            "empty content is a file with nothing in it",
            accepted("files_write", #"{"path":"a.txt","content":""}"#) != nil)
        check(
            "missing content is refused",
            refusal("files_write", #"{"path":"a.txt"}"#)?.contains("content") == true)
        check(
            "a mode is read ignoring case",
            accepted("files_write", #"{"path":"a","content":"x","mode":"Append","createFolders":true}"#)
                == .write(path: "/Users/tester/a", content: "x", mode: .append, createFolders: true))
        check(
            "an unknown mode is refused, naming the three",
            refusal("files_write", #"{"path":"a","content":"x","mode":"replace"}"#)
                == "\u{201C}mode\u{201D} must be create, overwrite or append.")
        let huge = String(repeating: "x", count: FileToolCatalog.writeLimit + 1)
        check(
            "content over 1 MB is refused, pointing at append",
            refusal("files_write", #"{"path":"a","content":"\#(huge)"}"#)?.contains("append") == true)
        check(
            "exactly 1 MB is fine",
            accepted(
                "files_write",
                #"{"path":"a","content":"\#(String(repeating: "x", count: FileToolCatalog.writeLimit))"}"#)
                != nil)
        check(
            "a move reads both paths",
            accepted("files_move", #"{"from":"a.txt","to":"~/b/a.txt"}"#)
                == .move(from: "/Users/tester/a.txt", to: "/Users/tester/b/a.txt"))
        check("a move needs its destination", refusal("files_move", #"{"from":"a"}"#) != nil)
        check(
            "trash reads its path",
            accepted("files_trash", #"{"path":"old.txt"}"#) == .trash(path: "/Users/tester/old.txt"))
        check("arguments that are not JSON are refused", refusal("files_read", "a.txt") != nil)
        check("an unknown file tool is refused", refusal("files_delete", #"{"path":"a"}"#) != nil)

        let move = FileToolCatalog.Request.move(from: "/a", to: "/b")
        check("reads are the read row", accepted("files_list", "")?.tool == .filesRead)
        check("a move is the write row, both paths weighed", move.tool == .filesWrite && move.paths == ["/a", "/b"])
        check(
            "only a move and the Trash keep a final link",
            move.keepsFinalLink && FileToolCatalog.Request.trash(path: "/a").keepsFinalLink
                && !(accepted("files_read", #"{"path":"a"}"#)?.keepsFinalLink ?? true))
        check(
            "paths are replaced in order",
            move.replacingPaths(["/c", "/d"]) == .move(from: "/c", to: "/d")
                && move.replacingPaths(["/c"]) == move)

        // MARK: Dialogs

        let seeds = PathRule.seeds(bundleID: "de.fa-krug.blitz")
        func prompt(_ request: FileToolCatalog.Request) -> AgentPrompt {
            FileToolCatalog.prompt(for: request, homeDirectory: home, seeds: seeds)
        }
        func titles(_ prompt: AgentPrompt) -> [String] { prompt.choices.map(\.title) }
        let readPrompt = prompt(.read(path: "/Users/tester/Projects/app/main.swift", offset: 1, limit: nil))
        check(
            "a read names the file",
            readPrompt.title == "Let the agent read \u{201C}~/Projects/app/main.swift\u{201D}?")
        check(
            "a read offers Allow, This Chat, Always Allow its folder, Don't Allow",
            titles(readPrompt) == [
                "Allow", "Allow This Chat", "Always Allow \u{201C}~/Projects/app/**\u{201D}",
                "Don't Allow"
            ])
        check(
            "Always Allow carries the pattern",
            readPrompt.choices[2] == .alwaysAllowPaths(pattern: "~/Projects/app/**"))
        check("↵ allows once", readPrompt.defaultIndex == 0 && readPrompt.choices[0].allows)
        check("a read says where it goes", readPrompt.message?.contains("provider") == true)
        let listPrompt = prompt(.list(path: "/Users/tester/Projects", recursive: true, includeHidden: false))
        check(
            "a list allows the folder itself",
            listPrompt.title == "Let the agent list \u{201C}~/Projects\u{201D}?"
                && listPrompt.choices.contains(.alwaysAllowPaths(pattern: "~/Projects/**"))
                && listPrompt.message?.contains("3 levels deep") == true)
        check(
            "listing home offers no Always Allow",
            titles(prompt(.list(path: home, recursive: false, includeHidden: false)))
                == ["Allow", "Allow This Chat", "Don't Allow"])
        check(
            "nor does a file in home, at the root or under a seed",
            [
                "/Users/tester/notes.txt", "/hosts", "/Users/tester/.ssh/config",
                "/Users/tester/Library/Application Support/de.fa-krug.blitz/chats.json"
            ].allSatisfy {
                titles(prompt(.read(path: $0, offset: 1, limit: nil)))
                    == ["Allow", "Allow This Chat", "Don't Allow"]
            })
        let writePrompt = prompt(
            .write(path: "/Users/tester/Projects/app/a.txt", content: "hello", mode: .create, createFolders: true))
        check(
            "a write is Allow, Always Allow, Don't Allow, never This Chat",
            titles(writePrompt) == [
                "Allow", "Always Allow \u{201C}~/Projects/app/**\u{201D}", "Don't Allow"
            ])
        check(
            "a write names the file and what it would do",
            writePrompt.title == "Let the agent write to \u{201C}~/Projects/app/a.txt\u{201D}?"
                && writePrompt.message
                    == "It would create this file with 5 bytes of text, making any folders it needs.")
        check(
            "an append says so",
            prompt(.write(path: "/Users/tester/Projects/a", content: "x", mode: .append, createFolders: false))
                .message == "It would add 1 byte of text to the end of the file.")
        check(
            "a write under /System offers no Always Allow",
            titles(prompt(.write(path: "/System/x/y", content: "", mode: .overwrite, createFolders: false)))
                == ["Allow", "Don't Allow"])
        let movePrompt = prompt(
            .move(from: "/Users/tester/Projects/app/a.txt", to: "/Users/tester/Projects/app/b.txt"))
        check(
            "a rename in one folder offers that folder",
            movePrompt.title == "Let the agent move \u{201C}~/Projects/app/a.txt\u{201D}?"
                && movePrompt.message == "To \u{201C}~/Projects/app/b.txt\u{201D}"
                && movePrompt.choices.contains(.alwaysAllowPaths(pattern: "~/Projects/app/**")))
        check(
            "a move between folders offers no Always Allow",
            titles(prompt(.move(from: "/Users/tester/Projects/a/x", to: "/Users/tester/Projects/b/x")))
                == ["Allow", "Don't Allow"])
        let trashPrompt = prompt(.trash(path: "/Users/tester/Projects/app/old.txt"))
        check(
            "the Trash says it can be put back",
            trashPrompt.title == "Let the agent move \u{201C}~/Projects/app/old.txt\u{201D} to the Trash?"
                && trashPrompt.message == "It can be put back from the Trash.")
        check(
            "every dialog ends on its refusal",
            [readPrompt, listPrompt, writePrompt, movePrompt, trashPrompt].allSatisfy { prompt in
                prompt.choices.last?.allows == false
                    && prompt.choices.dropLast().allSatisfy(\.allows)
            })

        check("the root is protected", FileToolCatalog.isProtected("/", homeDirectory: home))
        check("so is home", FileToolCatalog.isProtected("/users/TESTER", homeDirectory: home))
        check("and a folder holding it", FileToolCatalog.isProtected("/Users", homeDirectory: home))
        check("but not a sibling", !FileToolCatalog.isProtected("/Users/test", homeDirectory: home))
        check("nor what is inside home", !FileToolCatalog.isProtected("/Users/tester/a", homeDirectory: home))

        // MARK: Answers

        check(
            "sizes are spelled the same everywhere",
            [0, 1, 1023, 1024, 1536, 1024 * 1024, 5 * 1024 * 1024 / 2].map(FileToolCatalog.byteCount)
                == ["0 bytes", "1 byte", "1023 bytes", "1 KB", "1.5 KB", "1 MB", "2.5 MB"])

        let utc = TimeZone(identifier: "UTC") ?? .current
        let epoch = Date(timeIntervalSince1970: 0)
        let listing = FileToolCatalog.Listing(
            folder: "\u{201C}~/P\u{201D}", recursive: false,
            entries: [
                .init(path: "app", kind: .folder, size: nil, modified: epoch),
                .init(path: "a.txt", kind: .file, size: 2048, modified: epoch)
            ])
        check(
            "a listing is a header, then a tab-separated row per item",
            FileToolCatalog.listing(listing, timeZone: utc) == """
                \u{201C}~/P\u{201D}, 2 items:
                name\ttype\tsize\tmodified
                app\tfolder\t-\t1970-01-01 00:00:00
                a.txt\tfile\t2 KB\t1970-01-01 00:00:00
                """)
        var cut = listing
        cut.omitted = 3
        check(
            "a flat listing counts what it left out",
            FileToolCatalog.listing(cut, timeZone: utc).contains("5 items:")
                && FileToolCatalog.listing(cut, timeZone: utc)
                    .hasSuffix("[3 more not listed: at most 500 items come back.]"))
        var deep = FileToolCatalog.Listing(
            folder: "\u{201C}~\u{201D}", recursive: true, entries: listing.entries)
        deep.stoppedAtLimit = true
        deep.tooDeep = 2
        deep.denied = [".ssh"]
        let deepText = FileToolCatalog.listing(deep, timeZone: utc)
        check(
            "a recursive listing says how deep, where it stopped, and what it would not enter",
            deepText.hasPrefix("\u{201C}~\u{201D}, 3 levels deep, the first 2 items:")
                && deepText.contains("[Stopped at 500 items")
                && deepText.contains("[2 folders 3 levels down are listed, not entered.]")
                && deepText.contains("as the agent rules deny it: .ssh"))
        check(
            "an empty folder says so",
            FileToolCatalog.listing(.init(folder: "\u{201C}~/E\u{201D}", recursive: false, entries: []))
                == "\u{201C}~/E\u{201D} is empty.")

        typealias Excerpt = Result<String, FileToolCatalog.Failure>
        func excerpt(
            _ text: String, offset: Int = 1, limit: Int? = nil, isWhole: Bool = true, cap: Int = 1000
        ) -> Excerpt {
            Result { () throws(FileToolCatalog.Failure) in
                try FileToolCatalog.excerpt(
                    of: text, path: "f", offset: offset, limit: limit, isWhole: isWhole, cap: cap)
            }
        }
        let numbered = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        check(
            "a whole file says its lines",
            (try? excerpt(numbered).get()) == "f, lines 1\u{2013}10 of 10:\n"
                + (1...10).map { "line \($0)" }.joined(separator: "\n"))
        check(
            "offset and limit pick lines",
            (try? excerpt(numbered, offset: 3, limit: 2).get()) == "f, lines 3\u{2013}4 of 10:\nline 3\nline 4")
        check(
            "a limit past the end stops at the end",
            (try? excerpt(numbered, offset: 9, limit: 50).get())?.hasPrefix("f, lines 9\u{2013}10 of 10:") == true)
        check(
            "an offset past the end is refused",
            excerpt(numbered, offset: 11).failure?.message == "f has 10 lines, so offset 11 is past its end.")
        let clipped = (try? excerpt(numbered, cap: 20).get()) ?? ""
        check(
            "the cap cuts at a line and says where to go on",
            clipped == "f, lines 1\u{2013}2 of 10:\nline 1\nline 2\n"
                + "[Cut at 20 bytes after line 2. Read on with offset 3.]")
        let long = (try? excerpt(String(repeating: "é", count: 30) + "\nnext", cap: 9).get()) ?? ""
        check(
            "a line longer than the cap shows its start, whole characters only",
            long.contains("\néééé\n[Line 1 is longer than 9 bytes; only its start is shown.]")
                && long.hasSuffix("Read on with offset 2.]"))
        check(
            "a cut file never counts its last, maybe partial, line",
            (try? excerpt("a\nb\nc", isWhole: false).get())
                == "f, lines 1\u{2013}2 of at least 2 (only its first 8 MB can be read):\na\nb")
        check("an empty file says so", (try? excerpt("").get()) == "f is empty.")
        check(
            "CRLF lines are lines",
            (try? excerpt("a\r\nb\r\n", offset: 2).get()) == "f, lines 2\u{2013}2 of 2:\nb")

        func decoded(_ bytes: [UInt8], isWhole: Bool = true) -> String? {
            FileToolCatalog.decodedText(Data(bytes), isWhole: isWhole)
        }
        check("UTF-8 is read", decoded(Array("grüß\n".utf8)) == "grüß\n")
        check("a UTF-8 mark is dropped", decoded([0xEF, 0xBB, 0xBF] + Array("hi".utf8)) == "hi")
        check("marked UTF-16LE is read", decoded([0xFF, 0xFE, 0x68, 0, 0x69, 0]) == "hi")
        check("marked UTF-16BE is read", decoded([0xFE, 0xFF, 0, 0x68, 0, 0x69]) == "hi")
        let unmarked = Array("hello world\n".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        check("unmarked UTF-16LE is told by its zeros", decoded(unmarked) == "hello world\n")
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48]
        check("a PNG is not text", decoded(png) == nil)
        check("invalid UTF-8 is not text", decoded([0x68, 0xC3, 0x28]) == nil)
        check("a NUL past the sample still makes it binary", decoded([0xEF, 0xBB, 0xBF, 0x61, 0, 0x62]) == nil)
        check(
            "a scalar cut by the scan limit is dropped, not refused",
            decoded(Array("aä".utf8).dropLast(), isWhole: false) == "a")
        check(
            "the binary refusal names the type",
            FileToolCatalog.notText(path: "\u{201C}~/a.png\u{201D}", kind: "PNG image")
                == "\u{201C}~/a.png\u{201D} cannot be read as text (PNG image): files_read reads "
                + "UTF-8 and UTF-16 text only.")

        // MARK: Canonical paths

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "blitz-file-tool-test-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        // The spelling the runner produces: `resolvingSymlinksInPath` drops `/private`.
        let root = scratch.resolvingSymlinksInPath().path
        let fakeHome = root + "/home"
        func make(_ relative: String) {
            try? fileManager.createDirectory(
                atPath: fakeHome + "/" + relative, withIntermediateDirectories: true)
        }
        func put(_ relative: String, _ text: String) {
            fileManager.createFile(atPath: fakeHome + "/" + relative, contents: Data(text.utf8))
        }
        func link(_ relative: String, to destination: String) {
            try? fileManager.createSymbolicLink(
                atPath: fakeHome + "/" + relative, withDestinationPath: destination)
        }
        make(".ssh")
        make("Documents")
        put(".ssh/id_ed25519", "secret")
        link("Documents/keys", to: "../.ssh")
        link("Documents/key", to: fakeHome + "/.ssh/id_ed25519")
        link("Documents/nowhere", to: fakeHome + "/missing/file")

        func resolve(_ path: String, keepsFinalLink: Bool = false) -> String? {
            try? FileToolRunner.resolved(path, keepsFinalLink: keepsFinalLink, homeDirectory: fakeHome)
        }
        check("a plain path stays", resolve("~/Documents") == fakeHome + "/Documents")
        check(
            "a link to a key resolves to the key",
            resolve("~/Documents/key") == fakeHome + "/.ssh/id_ed25519")
        check(
            "a path through a linked folder resolves through it",
            resolve("~/Documents/keys/id_ed25519") == fakeHome + "/.ssh/id_ed25519")
        check(
            "a new file in a linked folder lands in the real one",
            resolve("~/Documents/keys/new") == fakeHome + "/.ssh/new")
        check(
            "missing folders keep their names under the real parent",
            resolve("~/Documents/keys/a/b/c.txt") == fakeHome + "/.ssh/a/b/c.txt")
        check(
            "a move or the Trash keeps the link itself",
            resolve("~/Documents/key", keepsFinalLink: true) == fakeHome + "/Documents/key")
        check(
            "but resolves the folders above it",
            resolve("~/Documents/keys/id_ed25519", keepsFinalLink: true)
                == fakeHome + "/.ssh/id_ed25519")
        check("a link to nothing is refused", resolve("~/Documents/nowhere") == nil)
        check(
            "unless the link itself is what moves",
            resolve("~/Documents/nowhere", keepsFinalLink: true) == fakeHome + "/Documents/nowhere")
        check("the root never moves", resolve("/", keepsFinalLink: true) == nil)

        let fakeSeeds = PathRule.seeds(bundleID: "de.fa-krug.blitz")
        var openRules = AgentRules([.filesRead: .allow, .filesWrite: .allow], pathRules: fakeSeeds)
        func decision(_ tool: AgentTool, _ paths: [String]) -> AgentDecision {
            AgentPolicy.decision(
                for: .files(tool, paths: paths, homeDirectory: fakeHome), rules: openRules,
                mcpTrust: { _ in .deny }, scope: AgentSessionScope())
        }
        check(
            "the link's own spelling would slip past the seed",
            decision(.filesRead, [fakeHome + "/Documents/key"]) == .allow)
        check(
            "its resolved path is caught by it",
            decision(.filesRead, [resolve("~/Documents/key") ?? ""]) == .deny)
        check(
            "and so is a write through a linked folder",
            decision(.filesWrite, [resolve("~/Documents/keys/authorized_keys") ?? ""]) == .deny)
        openRules.pathRules = []
        check(
            "without the seed it is allowed again",
            decision(.filesRead, [resolve("~/Documents/key") ?? ""]) == .allow)

        // MARK: Runner

        func prepared(_ name: String, _ arguments: String) -> FileToolRunner.Prepared? {
            try? FileToolRunner.prepare(name: name, arguments: arguments, homeDirectory: fakeHome).get()
        }
        let trash = root + "/Trash"
        try? fileManager.createDirectory(atPath: trash, withIntermediateDirectories: true)
        func toTrash(_ url: URL) throws {
            try fileManager.moveItem(atPath: url.path, toPath: trash + "/" + url.lastPathComponent)
        }
        func run(_ name: String, _ arguments: String, denied: [PathRule] = []) -> Excerpt {
            guard let prepared = prepared(name, arguments) else {
                return .failure(.init("could not prepare"))
            }
            return FileToolRunner.run(prepared, deniedRules: denied, trash: toTrash)
        }
        func preflight(_ name: String, _ arguments: String) -> String? {
            prepared(name, arguments).flatMap(FileToolRunner.preflight)?.message
        }
        func contents(_ relative: String) -> String? {
            fileManager.contents(atPath: fakeHome + "/" + relative).flatMap {
                String(bytes: $0, encoding: .utf8)
            }
        }

        let created = run("files_write", #"{"path":"~/Work/a.txt","content":"one\n"}"#)
        check(
            "a write into a missing folder is refused without createFolders",
            created.failure?.message.contains("createFolders") == true)
        check(
            "and the preflight says so before anyone is asked",
            preflight("files_write", #"{"path":"~/Work/a.txt","content":"one\n"}"#)?
                .contains("createFolders") == true)
        let made = run(
            "files_write", #"{"path":"~/Work/a.txt","content":"one\n","createFolders":true}"#)
        check(
            "createFolders makes the folder and the file",
            (try? made.get()) == "Created \u{201C}~/Work/a.txt\u{201D} with 4 bytes of text."
                && contents("Work/a.txt") == "one\n")
        check(
            "create never replaces",
            run("files_write", #"{"path":"~/Work/a.txt","content":"two"}"#).failure?.message
                .contains("already exists") == true && contents("Work/a.txt") == "one\n")
        _ = run("files_write", #"{"path":"~/Work/a.txt","content":"two\n","mode":"append"}"#)
        check("append adds to the end", contents("Work/a.txt") == "one\ntwo\n")
        _ = run("files_write", #"{"path":"~/Work/b.txt","content":"new","mode":"append"}"#)
        check("append makes a missing file", contents("Work/b.txt") == "new")
        _ = run("files_write", #"{"path":"~/Work/b.txt","content":"over","mode":"overwrite"}"#)
        check("overwrite replaces", contents("Work/b.txt") == "over")
        check(
            "a folder is never written",
            run("files_write", #"{"path":"~/Work","content":"x","mode":"overwrite"}"#).failure?
                .message == "\u{201C}~/Work\u{201D} is a folder.")

        put("Work/long.txt", (1...100).map { "row \($0)" }.joined(separator: "\n"))
        check(
            "a read takes lines from offset, up to limit",
            (try? run("files_read", #"{"path":"~/Work/long.txt","offset":10,"limit":2}"#).get())
                == "\u{201C}~/Work/long.txt\u{201D}, lines 10\u{2013}11 of 100:\nrow 10\nrow 11")
        fileManager.createFile(atPath: fakeHome + "/Work/pic.png", contents: Data(png))
        check(
            "a binary is refused naming its type",
            run("files_read", #"{"path":"~/Work/pic.png"}"#).failure?.message.contains("(PNG image)")
                == true)
        check(
            "a folder is listed, not read",
            preflight("files_read", #"{"path":"~/Work"}"#)?.contains("files_list") == true)
        check(
            "a missing file is named",
            preflight("files_read", #"{"path":"~/Work/none.txt"}"#)
                == "There is no file at \u{201C}~/Work/none.txt\u{201D}.")
        check(
            "a pipe is never read, so a read can never hang",
            mkfifo(fakeHome + "/Work/pipe", 0o600) == 0
                && preflight("files_read", #"{"path":"~/Work/pipe"}"#)?.contains("not a regular file")
                    == true)
        try? fileManager.removeItem(atPath: fakeHome + "/Work/pipe")
        check(
            "a read through a link reads the target",
            (try? run("files_read", #"{"path":"~/Documents/key"}"#).get())?.hasSuffix("secret") == true)

        put("Work/.hidden", "h")
        let flat = (try? run("files_list", #"{"path":"~/Work"}"#).get()) ?? ""
        check(
            "a flat list shows each item with its type and size",
            flat.hasPrefix("\u{201C}~/Work\u{201D}, 4 items:\nname\ttype\tsize\tmodified\n")
                && flat.contains("\na.txt\tfile\t8 bytes\t") && flat.contains("\nlong.txt\tfile\t")
                && !flat.contains(".hidden"))
        check(
            "hidden items only when asked",
            (try? run("files_list", #"{"path":"~/Work","includeHidden":true}"#).get())?
                .contains("\n.hidden\tfile\t1 byte\t") == true)
        check(
            "a link is listed as one",
            (try? run("files_list", #"{"path":"~/Documents"}"#).get())?.contains("\nkey\tlink\t-\t")
                == true)
        check(
            "a file is read, not listed",
            preflight("files_list", #"{"path":"~/Work/a.txt"}"#)?.contains("files_read") == true)

        make("Tree/a/b/c/d")
        put("Tree/a/b/c/d/deep.txt", "x")
        make("Tree/secret/inner")
        let tree = (try? run(
            "files_list", #"{"path":"~/Tree","recursive":true}"#,
            denied: [PathRule(pattern: "~/Tree/secret/**", decision: .deny)]).get()) ?? ""
        check(
            "a recursive list goes three levels deep",
            tree.contains("\na/b/c\tfolder\t") && !tree.contains("a/b/c/d")
                && tree.contains("[1 folders 3 levels down are listed, not entered.]"))
        check(
            "and never enters a folder a Deny rule covers",
            tree.contains("\nsecret\tfolder\t") && !tree.contains("secret/inner")
                && tree.contains("as the agent rules deny it: secret"))
        check(
            "nor follows a link into another folder",
            !((try? run("files_list", #"{"path":"~/Documents","recursive":true}"#).get()) ?? "")
                .contains("id_ed25519"))

        make("Many")
        for index in 0..<(FileToolCatalog.listLimit + 10) {
            put("Many/f\(index)", "")
        }
        let many = (try? run("files_list", #"{"path":"~/Many"}"#).get()) ?? ""
        check(
            "a flat list stops at 500 and counts the rest",
            many.contains("510 items:") && many.hasSuffix("[10 more not listed: at most 500 items come back.]")
                && many.split(separator: "\n").count == 2 + 500 + 1)
        let manyDeep = (try? run("files_list", #"{"path":"~","recursive":true}"#).get()) ?? ""
        check(
            "a recursive list stops at 500 and says so",
            manyDeep.contains("[Stopped at 500 items"))

        check(
            "a move never replaces",
            run("files_move", #"{"from":"~/Work/a.txt","to":"~/Work/b.txt"}"#).failure?.message
                .contains("never replaces") == true && contents("Work/b.txt") == "over")
        check(
            "a move renames",
            (try? run("files_move", #"{"from":"~/Work/a.txt","to":"~/Work/c.txt"}"#).get())
                == "Moved \u{201C}~/Work/a.txt\u{201D} to \u{201C}~/Work/c.txt\u{201D}."
                && contents("Work/c.txt") == "one\ntwo\n" && contents("Work/a.txt") == nil)
        check(
            "a move needs its folder",
            preflight("files_move", #"{"from":"~/Work/c.txt","to":"~/Nope/c.txt"}"#)
                == "There is no folder at \u{201C}~/Nope\u{201D}.")
        _ = run("files_move", #"{"from":"~/Documents/key","to":"~/Work/key"}"#)
        check(
            "a move takes the link, not what it points to",
            FileToolRunner.itemExists(fakeHome + "/Work/key")
                && contents(".ssh/id_ed25519") == "secret")
        check(
            "home itself is never moved",
            run("files_move", #"{"from":"~","to":"~/Work/home"}"#).failure?.message
                .contains("never moved") == true)

        check(
            "the Trash takes the item",
            (try? run("files_trash", #"{"path":"~/Work/c.txt"}"#).get())
                == "Moved \u{201C}~/Work/c.txt\u{201D} to the Trash, where the user can put it back."
                && contents("Work/c.txt") == nil
                && fileManager.fileExists(atPath: trash + "/c.txt"))
        check(
            "home is never moved to the Trash",
            preflight("files_trash", #"{"path":"~"}"#)?.contains("never moved") == true)
        check(
            "nothing there is said so",
            preflight("files_trash", #"{"path":"~/Work/c.txt"}"#)
                == "There is nothing at \u{201C}~/Work/c.txt\u{201D}.")

        // MARK: A path that changes while the user is asked

        make("Swap/real")
        make("Swap/elsewhere")
        put("Swap/real/a.txt", "real")
        put("Swap/elsewhere/a.txt", "elsewhere")
        if let asked = prepared("files_write", #"{"path":"~/Swap/real/a.txt","content":"x","mode":"overwrite"}"#) {
            try? fileManager.removeItem(atPath: fakeHome + "/Swap/real")
            link("Swap/real", to: fakeHome + "/Swap/elsewhere")
            let swapped = FileToolRunner.run(asked, trash: toTrash)
            check(
                "a folder swapped for a link after asking is refused",
                swapped.failure?.message
                    == "\u{201C}~/Swap/real/a.txt\u{201D} changed while the user was asked, so nothing was done."
                    && contents("Swap/elsewhere/a.txt") == "elsewhere")
        } else {
            check("a folder swapped for a link after asking is refused", false)
        }

        print(failures == 0 ? "\nAll file tool tests passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
