import Foundation

// Pure catalogs plus `OpenToolRunner` in a UUID-named scratch home; nothing is opened or run.
@main
struct MacToolTests {
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

        let home = "/Users/tester"

        // MARK: Schemas and wire names

        let open = OpenToolCatalog.tools()
        let shortcuts = ShortcutToolCatalog.tools()
        let actions = SystemActionToolCatalog.tools()
        let layouts = WindowLayoutToolCatalog.tools()
        check("mac_open is one tool", open.map(\.name) == ["mac_open"])
        check("it needs a target", required(open[0].parameters) == ["target"])
        check(
            "the shortcut tools, list first",
            shortcuts.map(\.name) == ["shortcuts_list", "shortcuts_run"])
        check("running a shortcut needs a name", required(shortcuts[1].parameters) == ["name"])
        check(
            "the system action tools, list first",
            actions.map(\.name) == ["system_actions_list", "system_action_run"])
        check("running an action needs an id", required(actions[1].parameters) == ["id"])
        check(
            "the window layout tools, list first",
            layouts.map(\.name) == ["window_layouts_list", "window_layout_apply"])
        check("applying a layout needs a name", required(layouts[1].parameters) == ["name"])
        let rows: [(names: [String], row: AgentTool)] = [
            (open.map(\.name), .openItems), (shortcuts.map(\.name), .shortcuts),
            (actions.map(\.name), .systemActions), (layouts.map(\.name), .windowLayouts)
        ]
        for (names, row) in rows {
            check(
                "\(names.joined(separator: ", ")) map to \(row.title)",
                names.allSatisfy { AgentTool(builtInToolName: $0) == row })
            check("\(row.title) is hosted", row.isHosted)
            check("\(row.title) acts, so it is not read-only", !row.isReadOnly)
            check("\(row.title) is never allowed for the chat", !row.canAllowForSession)
        }
        check(
            "every catalog handles its own names only",
            OpenToolCatalog.handles("mac_open") && !OpenToolCatalog.handles("shortcuts_run")
                && ShortcutToolCatalog.handles("shortcuts_list")
                && SystemActionToolCatalog.handles("system_action_run")
                && WindowLayoutToolCatalog.handles("window_layout_apply")
                && !WindowLayoutToolCatalog.handles("window_move"))

        // MARK: mac_open — reading the target

        func target(_ text: String) -> OpenToolCatalog.Target? {
            let json = AIToolJSON.text(.object(["target": .string(text)]))
            return try? OpenToolCatalog.target(arguments: json, homeDirectory: home)
        }
        func targetRefusal(_ text: String) -> String? {
            let json = AIToolJSON.text(.object(["target": .string(text)]))
            return refusal { _ = try OpenToolCatalog.target(arguments: json, homeDirectory: home) }
        }
        check(
            "no target is refused",
            refusal { _ = try OpenToolCatalog.target(arguments: "{}", homeDirectory: home) }
                == "\u{201C}target\u{201D} is required.")
        check("an absolute path is a path", target("/Applications/Safari.app") == .path("/Applications/Safari.app"))
        check("~ is the home folder", target("~/Documents/a.pdf") == .path(home + "/Documents/a.pdf"))
        check("a path is canonical", target("~/Documents/../x//y.txt") == .path(home + "/x/y.txt"))
        check("a name is an app", target("Safari") == .app("Safari"))
        check("a bundle id is an app", target("com.apple.Safari") == .app("com.apple.Safari"))
        check(
            "an https link is a link",
            target("https://example.com/a?b=1") == .url(URL(string: "https://example.com/a?b=1")!))
        check("a scheme is read in any case", target("HTTP://Example.com") != nil)
        check(
            "a mailto link is a link",
            target("mailto:ada@example.com") == .url(URL(string: "mailto:ada@example.com")!))
        check(
            "a mailto with nobody is refused",
            targetRefusal("mailto:")?.contains("names who the mail is to") == true)
        check(
            "a file link is refused, pointing at paths",
            targetRefusal("file:///etc/hosts")
                == "To open a file, give its path, such as ~/Documents/report.pdf.")
        for link in [
            "shortcuts://run-shortcut?name=x", "x-apple.systempreferences:com.apple.Security",
            "javascript:alert(1)", "ftp://example.com", "tel:123", "vnc://host", "localhost:3000",
            "C:\\Windows"
        ] {
            check(
                "\(link) is refused by its scheme",
                targetRefusal(link)?.hasPrefix("Only http, https and mailto links can be opened")
                    == true)
        }
        check(
            "credentials in a link are refused",
            targetRefusal("https://user:pw@example.com")
                == "A link with a user name or password in it is not opened.")
        check("a link with no host is refused", targetRefusal("https://")?.contains("no host") == true)
        check("the scheme reader", OpenToolCatalog.scheme(of: "Safari") == nil
            && OpenToolCatalog.scheme(of: "HTTPS://x") == "https"
            && OpenToolCatalog.scheme(of: "a b:c") == nil)

        // MARK: mac_open — apps

        let apps = [
            OpenToolCatalog.App(
                name: "Calculator", alternateNames: ["Rechner"], bundleID: "com.apple.calculator",
                path: "/System/Applications/Calculator.app"),
            OpenToolCatalog.App(
                name: "Café", alternateNames: [], bundleID: "com.example.cafe",
                path: "/Applications/Café.app"),
            OpenToolCatalog.App(
                name: "Foo", alternateNames: [], bundleID: "com.one.foo", path: "/Applications/Foo.app"),
            OpenToolCatalog.App(
                name: "Foo", alternateNames: [], bundleID: "com.two.foo",
                path: "/Users/tester/Applications/Foo.app"),
            OpenToolCatalog.App(
                name: "Safari", alternateNames: [], bundleID: "com.apple.Safari",
                path: "/Applications/Safari.app"),
            OpenToolCatalog.App(
                name: "Visual Studio Code", alternateNames: [], bundleID: "com.microsoft.VSCode",
                path: "/Applications/Visual Studio Code.app")
        ]
        func app(_ name: String) -> String? {
            (try? OpenToolCatalog.app(named: name, in: apps))?.bundleID
        }
        func appRefusal(_ name: String) -> String? {
            refusal { _ = try OpenToolCatalog.app(named: name, in: apps) }
        }
        check("a name in any case", app("safari") == "com.apple.Safari")
        check("a bundle id in any case", app("COM.APPLE.SAFARI") == "com.apple.Safari")
        check("a trailing .app is dropped", app("Safari.app") == "com.apple.Safari")
        check("a localised name", app("rechner") == "com.apple.calculator")
        check("accents are folded", app("cafe") == "com.example.cafe")
        check("a bundle id settles two apps of one name", app("com.two.foo") == "com.two.foo")
        check(
            "two apps of one name are refused, naming both",
            appRefusal("Foo")
                == "More than one app is called \u{201C}Foo\u{201D}: Foo (com.one.foo); Foo "
                + "(com.two.foo). Name the one to open by its bundle id.")
        check(
            "a missing app names near ones",
            appRefusal("Code")?.contains(
                "Installed apps with a similar name: Visual Studio Code (com.microsoft.VSCode).")
                == true)
        check(
            "and says what else mac_open takes",
            appRefusal("Zed")?.hasSuffix(
                "mac_open also takes a path starting with / or ~, or a link starting with "
                    + "https://, http:// or mailto:.") == true
                && appRefusal("Zed")?.contains("similar") == false)

        // MARK: Near names

        let words = ["Alpha", "Beta Alpha", "alphabet", "Gamma", "Al", "Alp1", "Alp2", "Alp3", "Alp4"]
        if case .missing(let near) = AgentNameMatch.match("alp", among: words, names: { [$0] }) {
            check(
                "near names: starts first, then holds, at most five",
                near == ["Alpha", "alphabet", "Alp1", "Alp2", "Alp3"])
        } else {
            check("near names: starts first, then holds, at most five", false)
        }
        if case .missing(let near) = AgentNameMatch.match("Big Gamma Ray", among: words, names: { [$0] }) {
            check("a longer query finds a name it holds", near == ["Gamma"])
        } else {
            check("a longer query finds a name it holds", false)
        }
        check(
            "a blank query finds nothing near",
            AgentNameMatch.match(" ", among: words, names: { [$0] }) == .missing(near: []))

        // MARK: mac_open — what a path may be

        func pathRefusal(_ path: String, program: Bool = false) -> String? {
            OpenToolCatalog.refusal(forPath: path, isProgram: program, homeDirectory: home)
        }
        check(
            "a script would run",
            pathRefusal(home + "/x.command")
                == "Opening \u{201C}~/x.command\u{201D} would run it, so mac_open never opens a "
                + ".command file.")
        check("an extension in any case", pathRefusal(home + "/Setup.PKG")?.contains("install") == true)
        check(
            "a link file is refused",
            pathRefusal(home + "/x.webloc")?.contains("link file that can point anywhere") == true)
        for ext in ["sh", "py", "jar", "workflow", "terminal", "mobileconfig", "prefpane", "shortcut"] {
            check(".\(ext) is refused", pathRefusal("/tmp/a.\(ext)") != nil)
        }
        for ext in ["pdf", "txt", "app", "png", "md", "dmg", "zip"] {
            check(".\(ext) may be opened", pathRefusal("/tmp/a.\(ext)") == nil)
        }
        check(
            "a program with no extension is refused",
            pathRefusal(home + "/bin/tool", program: true)
                == "\u{201C}~/bin/tool\u{201D} is a program: opening it would run it in Terminal, "
                + "so mac_open does not open it.")
        check("a plain file with no extension may be opened", pathRefusal(home + "/README") == nil)
        func kind(_ path: String, folder: Bool, file: Bool) -> OpenToolCatalog.ItemKind? {
            try? OpenToolCatalog.kind(of: path, isFolder: folder, isFile: file, homeDirectory: home)
                .get()
        }
        check("a folder named .app is an app", kind("/Applications/X.app", folder: true, file: false) == .app)
        check("a folder is a folder", kind("/tmp/X", folder: true, file: false) == .folder)
        check("a file is a file", kind("/tmp/x.pdf", folder: false, file: true) == .file)
        check("a pipe or a device is neither", kind("/dev/null", folder: false, file: false) == nil)

        // MARK: mac_open — dialogs and answers

        let appPrompt = OpenToolCatalog.prompt(forApp: apps[4])
        check(
            "the app dialog names the app",
            appPrompt.title == "Let the agent open Safari?"
                && appPrompt.message == "It launches Safari, or brings it forward if it is running.")
        check(
            "acting dialogs offer Allow and Don't Allow only",
            appPrompt.choices == [.allowOnce("Allow"), .refuse("Don't Allow")]
                && appPrompt.defaultIndex == 0 && appPrompt.symbol == AgentTool.openItems.symbolName)
        let filePrompt = OpenToolCatalog.prompt(
            forPath: home + "/Documents/a.pdf", kind: .file, homeDirectory: home)
        check(
            "the file dialog names the path",
            filePrompt.title == "Let the agent open \u{201C}~/Documents/a.pdf\u{201D}?"
                && filePrompt.message == "It opens in its default app."
                && filePrompt.choices.count == 2)
        check(
            "a folder opens in Finder",
            OpenToolCatalog.prompt(forPath: home, kind: .folder, homeDirectory: home).message
                == "It opens in Finder.")
        let linkPrompt = OpenToolCatalog.prompt(forURL: URL(string: "https://example.com/a")!)
        check(
            "the link dialog names the host and the browser",
            linkPrompt.title == "Let the agent open example.com in your browser?"
                && linkPrompt.message == "https://example.com/a\n\nIt opens in your default browser.")
        let mailPrompt = OpenToolCatalog.prompt(
            forURL: URL(string: "mailto:ada%40example.com?subject=Hi")!)
        check(
            "the mail dialog names who it is to and that nothing is sent",
            mailPrompt.title == "Let the agent open a new mail to ada@example.com?"
                && mailPrompt.message?.hasSuffix("Nothing is sent until you send it.") == true)
        check("the answers", OpenToolCatalog.opened(app: "Safari") == "Opened Safari."
            && OpenToolCatalog.opened(path: home + "/a.pdf", homeDirectory: home)
                == "Opened \u{201C}~/a.pdf\u{201D}."
            && OpenToolCatalog.opened(url: URL(string: "mailto:a@b.c")!)
                == "Opened a new mail in the mail app; it is not sent.")

        // MARK: mac_open — the policy

        let seeds = PathRule.seeds(bundleID: "de.fa-krug.blitz")
        func openDecision(
            _ row: AgentDecision, _ path: String, rules extra: [PathRule] = [],
            mode: AgentMode = .manual, tool: AgentTool = .openItems
        ) -> AgentDecision {
            var scope = AgentSessionScope()
            scope.mode = mode
            return AgentPolicy.decision(
                for: .files(tool, paths: [path], homeDirectory: home),
                rules: AgentRules([tool: row], pathRules: extra + seeds), mcpTrust: { _ in .deny },
                scope: scope)
        }
        check("the ssh seed denies opening a key", openDecision(.allow, home + "/.ssh/id_rsa") == .deny)
        check(
            "Blitz's own folder too",
            openDecision(.ask, home + "/Library/Application Support/de.fa-krug.blitz/chats") == .deny)
        check("an ordinary file takes the row", openDecision(.allow, home + "/a.pdf") == .allow)
        let projects = PathRule(pattern: "~/Projects/**", access: .read, decision: .allow)
        check(
            "an Allow read rule never lifts an open",
            openDecision(.ask, home + "/Projects/a.pdf", rules: [projects]) == .ask)
        check(
            "while it lifts a read",
            openDecision(.ask, home + "/Projects/a.pdf", rules: [projects], tool: .filesRead) == .allow)
        let asked = PathRule(pattern: "~/Private/**", access: .read, decision: .ask)
        check(
            "an Ask read rule holds an open there",
            openDecision(.allow, home + "/Private/a.pdf", rules: [asked]) == .ask)
        let writeOnly = PathRule(pattern: "~/Locked/**", access: .write, decision: .deny)
        check(
            "a write rule does not weigh an open",
            openDecision(.allow, home + "/Locked/a.pdf", rules: [writeOnly]) == .allow)
        check("Auto answers an Ask", openDecision(.ask, home + "/a.pdf", mode: .auto) == .allow)
        check("Plan refuses an open", openDecision(.allow, home + "/a.pdf", mode: .plan) == .deny)
        var rules = AgentRules.defaults
        rules.allowPath("~/Projects/**", for: .files(.openItems, paths: [home + "/Projects/a"], homeDirectory: home))
        check("Always Allow never comes from an open", rules.pathRules == AgentRules.defaults.pathRules)

        var plan = AgentSessionScope()
        plan.mode = .plan
        let allowAll = AgentRules([
            .openItems: .allow, .shortcuts: .allow, .systemActions: .allow, .windowLayouts: .allow
        ])
        for row in [AgentTool.openItems, .shortcuts, .systemActions, .windowLayouts] {
            check(
                "\(row.title) is Deny by default, so not offered",
                AgentRules.defaults.decision(for: row) == .deny
                    && !AgentPolicy.isOffered(
                        row, rules: .defaults, mcpTrust: { _ in .deny }, scope: AgentSessionScope()))
            check(
                "\(row.title) is not offered in Plan even on Allow",
                !AgentPolicy.isOffered(row, rules: allowAll, mcpTrust: { _ in .deny }, scope: plan))
            check(
                "\(row.title) is offered on Allow outside Plan",
                AgentPolicy.isOffered(
                    row, rules: allowAll, mcpTrust: { _ in .deny }, scope: AgentSessionScope()))
        }
        check(
            "the refusals name each action",
            AgentRefusal.denied.message(for: .openItems)
                == "Blitz's agent rules do not let the model open this."
                && AgentRefusal.declined.message(for: .shortcuts)
                    == "The user declined to let the model run this shortcut."
                && AgentRefusal.denied.message(for: .systemActions)
                    == "Blitz's agent rules do not let the model run this system action."
                && AgentRefusal.declined.message(for: .windowLayouts)
                    == "The user declined to let the model apply this window layout.")

        // MARK: mac_open — resolving on disk

        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appending(path: "blitz-mac-tool-test-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let fakeHome = scratch.resolvingSymlinksInPath().path + "/home"
        func make(_ relative: String) {
            try? fileManager.createDirectory(
                atPath: fakeHome + "/" + relative, withIntermediateDirectories: true)
        }
        func put(_ relative: String, executable: Bool = false) {
            fileManager.createFile(
                atPath: fakeHome + "/" + relative, contents: Data("x".utf8),
                attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }
        func link(_ relative: String, to destination: String) {
            try? fileManager.createSymbolicLink(
                atPath: fakeHome + "/" + relative, withDestinationPath: destination)
        }
        make(".ssh")
        make("Documents/Thing.app/Contents")
        make("Documents/Flow.workflow")
        put(".ssh/id_rsa")
        put("Documents/report.txt")
        put("Documents/run.command")
        put("Documents/tool", executable: true)
        put("Documents/notes.txt", executable: true)
        link("Documents/key", to: fakeHome + "/.ssh/id_rsa")
        link("Documents/gone", to: fakeHome + "/missing")

        func resolve(_ path: String) -> String? {
            try? OpenToolRunner.resolved(
                FileToolCatalog.absolute(path, homeDirectory: fakeHome), homeDirectory: fakeHome
            ).get()
        }
        func inspect(_ path: String) -> Result<OpenToolCatalog.ItemKind, FileToolCatalog.Failure> {
            OpenToolRunner.inspect(fakeHome + "/" + path, homeDirectory: fakeHome)
        }
        check("a text file opens", (try? inspect("Documents/report.txt").get()) == .file)
        check("a folder opens", (try? inspect("Documents").get()) == .folder)
        check("an app bundle opens as an app", (try? inspect("Documents/Thing.app").get()) == .app)
        check("a script is refused", (try? inspect("Documents/run.command").get()) == nil)
        check("a workflow bundle is refused", (try? inspect("Documents/Flow.workflow").get()) == nil)
        check(
            "a program with no extension is refused",
            inspect("Documents/tool").failure?.message.contains("is a program") == true)
        check(
            "an executable bit alone does not refuse a document",
            (try? inspect("Documents/notes.txt").get()) == .file)
        check(
            "nothing there is refused",
            inspect("Documents/none.pdf").failure?.message
                == "There is nothing at \u{201C}~/Documents/none.pdf\u{201D}.")
        check(
            "a link to a key resolves to the key",
            resolve("~/Documents/key") == fakeHome + "/.ssh/id_rsa")
        check("a link to nothing is refused", resolve("~/Documents/gone") == nil)
        let openRow = AgentRules([.openItems: .allow], pathRules: PathRule.seeds(bundleID: "x"))
        func decision(_ path: String) -> AgentDecision {
            AgentPolicy.decision(
                for: .files(.openItems, paths: [path], homeDirectory: fakeHome), rules: openRow,
                mcpTrust: { _ in .deny }, scope: AgentSessionScope())
        }
        check(
            "the link's own spelling would slip past the seed",
            decision(fakeHome + "/Documents/key") == .allow)
        check("its resolved path is denied", decision(resolve("~/Documents/key") ?? "") == .deny)
        let report = fakeHome + "/Documents/report.txt"
        check(
            "an unchanged path passes the second look",
            OpenToolRunner.recheck(report, as: report, kind: .file, homeDirectory: fakeHome) == nil)
        try? fileManager.removeItem(atPath: report)
        link("Documents/report.txt", to: fakeHome + "/.ssh/id_rsa")
        check(
            "a path swapped for a link while asking is refused",
            OpenToolRunner.recheck(report, as: report, kind: .file, homeDirectory: fakeHome)?.message
                == "\u{201C}~/Documents/report.txt\u{201D} changed while the user was asked, so "
                + "nothing was opened.")

        // MARK: Shortcuts

        func shortcutRequest(_ name: String, _ arguments: String) -> ShortcutToolCatalog.Request? {
            try? ShortcutToolCatalog.request(name: name, arguments: arguments)
        }
        check(
            "a listing with a query",
            shortcutRequest("shortcuts_list", #"{"query":" Mail "}"#) == .list(query: "Mail"))
        check("a listing with nothing", shortcutRequest("shortcuts_list", "") == .list(query: nil))
        check(
            "a run with input",
            shortcutRequest("shortcuts_run", #"{"name":"Translate","input":" hola "}"#)
                == .run(name: "Translate", input: " hola "))
        check(
            "empty input is none",
            shortcutRequest("shortcuts_run", #"{"name":"Translate","input":""}"#)
                == .run(name: "Translate", input: nil))
        check(
            "a run needs a name",
            refusal { _ = try ShortcutToolCatalog.request(name: "shortcuts_run", arguments: "{}") }
                == "\u{201C}name\u{201D} is required.")
        let long = String(repeating: "a", count: ShortcutToolCatalog.inputLimit + 1)
        check(
            "input past the cap is refused",
            refusal {
                _ = try ShortcutToolCatalog.request(
                    name: "shortcuts_run",
                    arguments: AIToolJSON.text(.object(["name": .string("x"), "input": .string(long)])))
            } == "\u{201C}input\u{201D} holds at most 20000 characters.")
        let library = [
            AppleShortcut(id: UUID(), name: "Make GIF"),
            AppleShortcut(id: UUID(), name: "Mail Summary"),
            AppleShortcut(id: UUID(), name: "Translate")
        ]
        func shortcut(_ name: String) -> String? {
            (try? ShortcutToolCatalog.shortcut(named: name, in: library))?.name
        }
        check("a shortcut by name in any case", shortcut("translate") == "Translate")
        check("a shortcut by identifier", shortcut(library[1].id.uuidString) == "Mail Summary")
        check(
            "a missing shortcut names near ones",
            refusal { _ = try ShortcutToolCatalog.shortcut(named: "Mail", in: library) }
                == "There is no shortcut called \u{201C}Mail\u{201D}. Shortcuts with a similar "
                + "name: \u{201C}Mail Summary\u{201D}. shortcuts_list lists them all.")
        check(
            "the listing names each",
            ShortcutToolCatalog.listing(library, query: nil)
                == "3 shortcuts:\nMake GIF\nMail Summary\nTranslate")
        check(
            "a query narrows it",
            ShortcutToolCatalog.listing(library, query: "mail") == "1 shortcut:\nMail Summary")
        check(
            "a query that matches nothing says so",
            ShortcutToolCatalog.listing(library, query: "zz")
                == "No shortcut\u{2019}s name contains \u{201C}zz\u{201D}.")
        check(
            "an empty library says so",
            ShortcutToolCatalog.listing([], query: nil) == "The Shortcuts app holds no shortcuts.")
        let translate = library[2]
        check(
            "nothing returned",
            ShortcutToolCatalog.result(of: translate, output: nil)
                == "Ran \u{201C}Translate\u{201D}. It returned nothing.")
        check(
            "text returned",
            ShortcutToolCatalog.result(of: translate, output: Data("hello\n".utf8))
                == "Ran \u{201C}Translate\u{201D}. It returned:\n\nhello")
        check(
            "bytes are never shown",
            ShortcutToolCatalog.result(of: translate, output: Data([0x89, 0x50, 0x00, 0x47]))
                == "Ran \u{201C}Translate\u{201D}. What it returned is not text, so it is not shown.")
        let flood = String(repeating: "b", count: ShortcutToolCatalog.outputLimit + 5)
        let clipped = ShortcutToolCatalog.result(of: translate, output: Data(flood.utf8))
        check(
            "long output is cut and says so",
            clipped.contains("cut to its first 20000 of 20005 characters")
                && clipped.hasSuffix(String(repeating: "b", count: ShortcutToolCatalog.outputLimit)))
        let shortcutPrompt = ShortcutToolCatalog.prompt(
            for: translate, input: String(repeating: "c", count: 400))
        check(
            "the shortcut dialog names it and shows the input, clipped",
            shortcutPrompt.title == "Let the agent run the shortcut \u{201C}Translate\u{201D}?"
                && shortcutPrompt.message?.hasPrefix(
                    "With this input:\n" + String(repeating: "c", count: 300) + "\u{2026}\n\n") == true
                && shortcutPrompt.choices == [.allowOnce("Allow"), .refuse("Don't Allow")])
        check(
            "with no input it says what a shortcut can do",
            ShortcutToolCatalog.prompt(for: translate, input: nil).message
                == "It can do anything its actions do, and what it returns is sent to the model"
                + "\u{2019}s provider.")

        // MARK: System actions

        let excluded: Set<SystemAction.ID> = [
            .restart, .shutDown, .logOut, .emptyTrash, .quitAllApps, .ejectAllDisks,
            .toggleBluetooth, .dismissNotifications, .setVolume
        ]
        check("exactly these are excluded", Set(SystemActionToolCatalog.excluded.keys) == excluded)
        check(
            "every action that confirms first is among them",
            SystemActionCatalog.all.filter { $0.confirmation != .none }
                .allSatisfy { excluded.contains($0.id) })
        check(
            "the rest are offered, in catalog order",
            SystemActionToolCatalog.offered.map(\.id)
                == SystemAction.ID.allCases.filter { !excluded.contains($0) })
        let enumIDs =
            actions[1].parameters.objectValue?["properties"]?.objectValue?["id"]?.objectValue?["enum"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        check(
            "the schema lists only offered ids",
            enumIDs == SystemActionToolCatalog.offered.map(\.id.rawValue)
                && enumIDs.contains("lock-screen") && !enumIDs.contains("empty-trash"))
        func action(_ id: String) -> SystemAction.ID? {
            guard case .run(let action) = try? SystemActionToolCatalog.request(
                name: "system_action_run", arguments: #"{"id":"\#(id)"}"#)
            else { return nil }
            return action.id
        }
        func actionRefusal(_ id: String) -> String? {
            refusal {
                _ = try SystemActionToolCatalog.request(
                    name: "system_action_run", arguments: #"{"id":"\#(id)"}"#)
            }
        }
        check("an action by id", action("lock-screen") == .lockScreen)
        check("an action by its name", action("Lock Screen") == .lockScreen)
        check("and in any case", action("TOGGLE-MUTE") == .toggleMute)
        for id in excluded {
            let name = SystemActionCatalog.action(id: id).name
            check(
                "\(id.rawValue) is refused by id",
                actionRefusal(id.rawValue)?.hasPrefix(
                    "\u{201C}\(name)\u{201D} is not available to the agent: ") == true)
            check("\(id.rawValue) is refused by name", action(name) == nil)
        }
        check(
            "an emptied Trash is refused with its reason",
            actionRefusal("empty-trash")
                == "\u{201C}Empty Trash\u{201D} is not available to the agent: it deletes what is "
                + "in the Trash for good.")
        check(
            "an unknown action is refused",
            actionRefusal("self-destruct")
                == "There is no system action \u{201C}self-destruct\u{201D}; system_actions_list "
                + "lists their ids.")
        check(
            "listing is a request of its own",
            (try? SystemActionToolCatalog.request(name: "system_actions_list", arguments: "")) == .list)
        let actionLines = SystemActionToolCatalog.listing().split(separator: "\n")
        check(
            "the listing gives id and name per action",
            actionLines.count == SystemActionToolCatalog.offered.count + 1
                && actionLines.contains("lock-screen\tLock Screen")
                && !actionLines.contains { $0.hasPrefix("empty-trash") })
        let lock = SystemActionCatalog.action(id: .lockScreen)
        check(
            "the action dialog names it",
            SystemActionToolCatalog.prompt(for: lock).title
                == "Let the agent run \u{201C}Lock Screen\u{201D}?"
                && SystemActionToolCatalog.prompt(for: lock).choices.count == 2)
        check(
            "the answer carries the feedback",
            SystemActionToolCatalog.result(
                of: SystemActionCatalog.action(id: .toggleAppearance), feedback: "Dark Appearance")
                == "Ran \u{201C}Toggle System Appearance\u{201D}. Dark Appearance."
                && SystemActionToolCatalog.result(of: lock, feedback: nil)
                    == "Ran \u{201C}Lock Screen\u{201D}.")

        // MARK: Window layouts

        let coding = WindowLayoutToolCatalog.Layout(id: UUID(), name: "Coding", summary: "3 windows")
        let writing = WindowLayoutToolCatalog.Layout(
            id: UUID(), name: "Writing", summary: "2 windows · 2 displays")
        let saved = [coding, writing]
        check(
            "apply needs a name",
            refusal {
                _ = try WindowLayoutToolCatalog.request(name: "window_layout_apply", arguments: "{}")
            } == "\u{201C}name\u{201D} is required.")
        check(
            "apply reads the name",
            (try? WindowLayoutToolCatalog.request(
                name: "window_layout_apply", arguments: #"{"name":"coding"}"#))
                == .apply(name: "coding"))
        check(
            "a layout by name in any case",
            (try? WindowLayoutToolCatalog.layout(named: "coding", in: saved)) == coding)
        check(
            "a layout by id",
            (try? WindowLayoutToolCatalog.layout(named: writing.id.uuidString, in: saved)) == writing)
        check(
            "a missing layout names near ones",
            refusal { _ = try WindowLayoutToolCatalog.layout(named: "cod", in: saved) }
                == "There is no window layout called \u{201C}cod\u{201D}. Layouts with a similar "
                + "name: \u{201C}Coding\u{201D}. window_layouts_list lists them all.")
        check(
            "the listing gives name and what it arranges",
            WindowLayoutToolCatalog.listing(saved)
                == "2 window layouts, as name and what it arranges:\nCoding\t3 windows\n"
                + "Writing\t2 windows · 2 displays")
        check(
            "no layouts says so",
            WindowLayoutToolCatalog.listing([]) == "The user has saved no window layouts.")
        let layoutPrompt = WindowLayoutToolCatalog.prompt(for: writing)
        check(
            "the layout dialog names it and what it does",
            layoutPrompt.title == "Let the agent apply the window layout \u{201C}Writing\u{201D}?"
                && layoutPrompt.message
                    == "2 windows · 2 displays. It opens the apps it names that are not running, "
                    + "then moves and resizes their windows."
                && layoutPrompt.choices.count == 2)
        let clean = WindowLayoutToolCatalog.result(
            of: coding, outcome: .init(placed: 3, opened: 1, problems: nil))
        check(
            "a clean run",
            clean.text == "Applied \u{201C}Coding\u{201D}: placed 3 windows, opening 1 app."
                && !clean.isError)
        let partial = WindowLayoutToolCatalog.result(
            of: coding, outcome: .init(placed: 1, opened: 0, problems: "1 display not connected"))
        check(
            "a partial run says what did not happen",
            partial.text
                == "Applied \u{201C}Coding\u{201D}: placed 1 window. Not everything happened: 1 "
                + "display not connected." && !partial.isError)
        let none = WindowLayoutToolCatalog.result(
            of: coding, outcome: .init(placed: 0, opened: 0, problems: nil))
        check(
            "a run that placed nothing is an error",
            none.text == "Could not apply \u{201C}Coding\u{201D}: no window could be placed."
                && none.isError)
        check(
            "missing Accessibility is a sentence, never a prompt",
            WindowLayoutToolCatalog.needsAccessibility.hasPrefix(
                "Blitz does not have Accessibility access"))

        print(failures == 0 ? "\nAll Mac tool tests passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
