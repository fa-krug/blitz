import Foundation

@main
struct AgentPolicyTests {
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

        func segments(_ command: String) -> [String]? {
            ShellCommandSegments.segments(of: command)
        }

        // MARK: Splitter — operators

        check("a plain command is one segment", segments("ls -la") == ["ls -la"])
        check("; splits", segments("ls; pwd") == ["ls", "pwd"])
        check("&& splits", segments("cd x && ls") == ["cd x", "ls"])
        check("|| splits", segments("test -f x || touch x") == ["test -f x", "touch x"])
        check("| splits", segments("ls | wc -l") == ["ls", "wc -l"])
        check("a background & splits", segments("sleep 1 & ls") == ["sleep 1", "ls"])
        check("a trailing & leaves the job", segments("sleep 1 &") == ["sleep 1"])
        check("a newline splits", segments("ls\npwd") == ["ls", "pwd"])
        check(
            "every operator in one line",
            segments("a; b && c || d | e & f\ng") == ["a", "b", "c", "d", "e", "f", "g"])
        check("operators without spaces split", segments("a;b&&c||d|e") == ["a", "b", "c", "d", "e"])
        check("|& reads as a pipe", segments("make |& tee log") == ["make", "tee log"])
        check("segments are trimmed", segments("  ls   ;\t pwd  ") == ["ls", "pwd"])
        check("empty segments are dropped", segments("ls;;  ; pwd") == ["ls", "pwd"])
        check("a dangling && leaves the command", segments("ls &&") == ["ls"])

        // MARK: Splitter — quotes and escapes

        check(
            "; inside single quotes stays",
            segments("echo 'a; b' ; ls") == ["echo 'a; b'", "ls"])
        check(
            "| inside double quotes stays",
            segments(#"grep "a|b" file | wc"#) == [#"grep "a|b" file"#, "wc"])
        check(
            "&& inside double quotes stays",
            segments(#"echo "x && y""#) == [#"echo "x && y""#])
        check(
            "a newline inside quotes stays",
            segments("git commit -m 'one\ntwo'") == ["git commit -m 'one\ntwo'"])
        check(
            "an escaped ; is literal",
            segments(#"find . -name x -exec ls {} \;"#) == [#"find . -name x -exec ls {} \;"#])
        check("an escaped | is literal", segments(#"echo a\|b"#) == [#"echo a\|b"#])
        check(
            "an escaped quote inside double quotes",
            segments(#"echo "say \"hi\"; ok""#) == [#"echo "say \"hi\"; ok""#])
        check(
            "a backslash in single quotes is literal",
            segments(#"echo 'a\' ; ls"#) == [#"echo 'a\'"#, "ls"])
        check("a line continuation joins", segments("ls \\\n-la") == ["ls -la"])
        check("a ' inside double quotes", segments(#"echo "it's""#) == [#"echo "it's""#])

        // MARK: Splitter — redirections stay in their segment

        check("> stays", segments("ls > out.txt") == ["ls > out.txt"])
        check(">> stays", segments("ls >> out.txt; pwd") == ["ls >> out.txt", "pwd"])
        check("2>&1 stays", segments("make 2>&1 | tail") == ["make 2>&1", "tail"])
        check("&> stays", segments("ls &> log") == ["ls &> log"])
        check("&>> stays", segments("ls &>> log") == ["ls &>> log"])
        check(">| stays", segments("ls >| log") == ["ls >| log"])
        check("< stays", segments("wc -l < file") == ["wc -l < file"])
        check("<&- stays", segments("cat <&-") == ["cat <&-"])

        // MARK: Splitter — what it refuses to read

        check("empty input", segments("") == nil)
        check("whitespace input", segments("  \t ") == nil)
        check("only separators", segments(" ; && | ") == nil)
        check("$( substitution", segments("echo $(whoami)") == nil)
        check("$( inside double quotes", segments(#"echo "$(whoami)""#) == nil)
        check("$( inside single quotes", segments("echo '$(whoami)'") == nil)
        check("$(( arithmetic", segments("echo $((1 + 2))") == nil)
        check("backticks", segments("echo `whoami`") == nil)
        check("backticks in double quotes", segments(#"echo "`whoami`""#) == nil)
        check("<( process substitution", segments("diff <(ls a) <(ls b)") == nil)
        check(">( process substitution", segments("ls > >(cat)") == nil)
        check("a heredoc", segments("cat <<EOF\nhi\nEOF") == nil)
        check("a here-string", segments("cat <<< hi") == nil)
        check("an unbalanced single quote", segments("echo 'oops") == nil)
        check("an unbalanced double quote", segments(#"echo "oops"#) == nil)
        check("a trailing backslash", segments("ls \\") == nil)
        check("a trailing backslash in double quotes", segments(#"echo "a\"#) == nil)
        check("a subshell", segments("(cd x; rm y)") == nil)
        check("a closing paren alone", segments("ls )") == nil)
        check("a brace group", segments("{ ls; pwd; }") == nil)
        check("a function definition", segments("f() { rm x; }; f") == nil)
        check("a zsh parameter flag", segments(#"echo "${(e)x}""#) == nil)
        check("ANSI-C quoting", segments("echo $'a\\'b'") == nil)
        check("a comment", segments("ls # ; rm -rf ~") == nil)
        check("a comment hiding a quote", segments("ls #'\nrm -rf ~\n'") == nil)
        check("a control character", segments("ls\u{07}") == nil)
        check("a carriage return", segments("ls\r\nrm x") == nil)
        check("a quote fused with a combining mark", segments("echo '\u{301}; rm x'") != nil)
        check(
            "and its pieces still split as the shell sees them",
            segments("echo '\u{301}; rm x'") == ["echo '\u{301}; rm x'"])
        check("$( fused with a combining mark", segments("echo $(\u{301}whoami)") == nil)
        for word in ["eval", "exec", "source", ".", "command", "builtin", "trap", "alias", "export"] {
            check("\(word) at a segment's start", segments("\(word) ls") == nil)
        }
        check("eval after an operator", segments("ls && eval x") == nil)
        check("eval as an argument is fine", segments("echo eval") == ["echo eval"])
        for keyword in ["if", "for", "while", "do", "done", "case", "!", "then", "time"] {
            check("the keyword \(keyword)", segments("\(keyword) x") == nil)
        }
        check("a loop", segments("for f in a b; do rm $f; done") == nil)
        check("a leading assignment", segments("FOO=1 ls") == nil)
        check("a variable as the command", segments("$EDITOR file") == nil)
        check("a quoted command word", segments("'rm' -rf x") == nil)
        check("an escaped command word", segments(#"\rm -rf x"#) == nil)
        check("a globbed command word", segments("/bin/r? x") == nil)
        check("a brace-expanded command word", segments("{rm,-rf,x}") == nil)
        check("a leading redirection", segments(">out ls") == nil)
        check("[ as the command is fine", segments("[ -f x ] && cat x") == ["[ -f x ]", "cat x"])
        check("$VAR as an argument is fine", segments("echo $HOME") == ["echo $HOME"])
        check("${VAR} as an argument is fine", segments("echo ${HOME}") == ["echo ${HOME}"])
        check("a path command is fine", segments("/usr/bin/true") == ["/usr/bin/true"])

        // MARK: Glob matching

        func matches(_ pattern: String, _ segment: String) -> Bool {
            ShellRule(pattern: pattern, decision: .allow).matches(segment)
        }

        check("ls matches ls", matches("ls", "ls"))
        check("ls does not match ls -la", !matches("ls", "ls -la"))
        check("ls * matches ls -la", matches("ls *", "ls -la"))
        check("ls * also matches a bare ls", matches("ls *", "ls"))
        check("ls* matches a bare ls", matches("ls*", "ls"))
        check("ls* matches ls -la", matches("ls*", "ls -la"))
        check("ls* also matches lsof", matches("ls*", "lsof"))
        check("ls * does not match lsof", !matches("ls *", "lsof"))
        check("* spans spaces", matches("git *", "git log --oneline -n 5"))
        check("* in the middle", matches("git * --dry-run", "git push origin --dry-run"))
        check("* matches nothing", matches("brew list*", "brew list"))
        check("? is one character", matches("l?", "ls") && !matches("l?", "l"))
        check("? is not two", !matches("l?", "lsx"))
        check("a lone * matches anything", matches("*", "rm -rf ~"))
        check("the match is whole, not a prefix", !matches("git", "git status"))
        check("the match is whole, not a suffix", !matches("status", "git status"))
        check("matching is case-sensitive", !matches("LS", "ls"))
        check("whitespace in the segment collapses", matches("git status", "git   status"))
        check("tabs collapse", matches("git status", "git\tstatus"))
        check("whitespace in the pattern collapses", matches("git    *", "git status"))
        check("pattern edges are trimmed", matches("  ls  ", "ls"))
        check("other characters are literal", matches("echo [a].txt", "echo [a].txt"))
        check("[ is not a class", !matches("echo [ab]", "echo a"))
        check("an empty pattern matches nothing real", !matches("", "ls"))
        check(
            "a non-breaking space is not a separator",
            !matches("ls *", "ls\u{A0}-la") && !matches("ls -la", "ls\u{A0}-la"))
        check("unicode is literal", matches("echo é*", "echo étoile"))

        // MARK: Decisions and tools

        check("deny < ask < allow", AgentDecision.deny < .ask && AgentDecision.ask < .allow)
        check("min narrows", min(AgentDecision.allow, .ask) == .ask)
        check(
            "decision titles",
            AgentDecision.allCases.map(\.title) == ["Deny", "Ask", "Allow"])
        check(
            "built-in rows, in Settings order",
            AgentTool.builtIn == [
                .shell, .calendarRead, .calendarWrite, .remindersRead, .remindersWrite, .webSearch
            ])
        check("only web search has no ask", AgentTool.builtIn.filter { !$0.canAsk } == [.webSearch])
        check("an MCP server can ask", AgentTool.mcp("github").canAsk)
        check("an MCP row is titled by its slug", AgentTool.mcp("github").title == "github")
        check(
            "every built-in tool has a title and a symbol",
            AgentTool.builtIn.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
        check(
            "titles are distinct",
            Set(AgentTool.builtIn.map(\.title)).count == AgentTool.builtIn.count)

        // MARK: Wire names

        check("the shell's name", AgentTool(wireName: ShellToolCatalog.runCommandName) == .shell)
        check(
            "calendar listing reads",
            AgentTool(wireName: CalendarToolCatalog.listEventsName) == .calendarRead)
        check(
            "calendar creating writes",
            AgentTool(wireName: CalendarToolCatalog.createEventName) == .calendarWrite)
        check(
            "reminder listing reads",
            AgentTool(wireName: ReminderToolCatalog.listName) == .remindersRead)
        for name in [
            ReminderToolCatalog.createName, ReminderToolCatalog.updateName,
            ReminderToolCatalog.completeName
        ] {
            check("\(name) writes", AgentTool(wireName: name) == .remindersWrite)
        }
        func catalogs(read: Bool, write: Bool) -> [String] {
            let now = Date()
            return (CalendarToolCatalog.tools(
                canRead: read, canWrite: write, now: now, calendar: .current)
                + ReminderToolCatalog.tools(
                    canRead: read, canWrite: write, now: now, calendar: .current)).map(\.name)
        }
        let catalogNames = ShellToolCatalog.tools().map(\.name) + catalogs(read: true, write: true)
        check(
            "every catalog tool maps to a built-in row",
            catalogNames.allSatisfy { AgentTool(builtInToolName: $0) != nil })
        let readOnlyNames = catalogs(read: true, write: false)
        check(
            "what a read-only catalog offers maps to a read row",
            readOnlyNames.allSatisfy { name in
                let tool = AgentTool(builtInToolName: name)
                return tool == .calendarRead || tool == .remindersRead
            })
        check(
            "an MCP wire name maps to its server",
            AgentTool(wireName: MCPToolName.compose(slug: "github", tool: "list_issues"))
                == .mcp("github"))
        check("an unknown name maps to nothing", AgentTool(wireName: "launch_rockets") == nil)
        check(
            "a built-in name is never read as MCP",
            AgentTool(builtInToolName: "github__list") == nil)

        // MARK: MCP trust

        check("always ↔ allow", MCPTrust.always.decision == .allow && MCPTrust(.allow) == .always)
        check("ask ↔ ask", MCPTrust.ask.decision == .ask && MCPTrust(.ask) == .ask)
        check("never ↔ deny", MCPTrust.never.decision == .deny && MCPTrust(.deny) == .never)
        check(
            "the mapping round-trips",
            MCPTrust.allCases.allSatisfy { MCPTrust($0.decision) == $0 })

        // MARK: Rules — defaults and web search

        let defaults = AgentRules.defaults
        check("the shell defaults to deny", defaults.shell == .deny)
        check("calendar read defaults to ask", defaults.calendarRead == .ask)
        check("calendar write defaults to deny", defaults.calendarWrite == .deny)
        check("reminders read defaults to ask", defaults.remindersRead == .ask)
        check("reminders write defaults to deny", defaults.remindersWrite == .deny)
        check("web search defaults to allow: the composer toggle is the opt-in", defaults.webSearch == .allow)
        check("no shell rules by default", defaults.shellRules.isEmpty)

        var rules = AgentRules.defaults
        rules.webSearch = .ask
        check("web search set to ask reads as deny", rules.webSearch == .deny)
        rules.webSearch = .allow
        rules.set(.ask, for: .webSearch)
        check("and through set(_:for:) too", rules.webSearch == .deny)
        let built = AgentRules(
            shell: .ask, calendarRead: .ask, calendarWrite: .ask, remindersRead: .ask,
            remindersWrite: .ask, webSearch: .ask)
        check("and through the initialiser", built.webSearch == .deny)
        rules.set(.allow, for: .webSearch)
        check("allow is kept", rules.webSearch == .allow)

        for tool in AgentTool.builtIn {
            var table = AgentRules.defaults
            table.set(.allow, for: tool)
            check("\(tool.title) is set and read back", table.decision(for: tool) == .allow)
        }
        var mcpTable = AgentRules.defaults
        mcpTable.set(.allow, for: .mcp("github"))
        check("an MCP row is not the table's", mcpTable == .defaults)
        check("and reads as nil", mcpTable.decision(for: .mcp("github")) == nil)

        let calendarOff = AgentRules.migrated(
            calendarAccess: .readWrite, remindersAccess: .readWrite, shellCommandsEnabled: true
        ).restricted(to: { $0 != .calendarRead && $0 != .calendarWrite })
        check(
            "a feature that is off denies its rows",
            calendarOff.calendarRead == .deny && calendarOff.calendarWrite == .deny)
        check(
            "and leaves the rest",
            calendarOff.remindersRead == .allow && calendarOff.shell == .ask)

        // MARK: Rules — migration

        typealias Row = (read: AgentDecision, write: AgentDecision)
        let calendarRows: [AIDataAccess: Row] = [
            .off: (.deny, .deny), .read: (.allow, .deny), .readWrite: (.allow, .ask)
        ]
        let reminderRows: [AIDataAccess: Row] = [
            .off: (.deny, .deny), .read: (.allow, .deny), .readWrite: (.allow, .allow)
        ]
        for calendar in AIDataAccess.allCases {
            for reminders in AIDataAccess.allCases {
                for shell in [false, true] {
                    let migrated = AgentRules.migrated(
                        calendarAccess: calendar, remindersAccess: reminders,
                        shellCommandsEnabled: shell)
                    let label = "\(calendar.title)/\(reminders.title)/shell \(shell)"
                    check(
                        "\(label): calendar rows",
                        migrated.calendarRead == calendarRows[calendar]?.read
                            && migrated.calendarWrite == calendarRows[calendar]?.write)
                    check(
                        "\(label): reminder rows",
                        migrated.remindersRead == reminderRows[reminders]?.read
                            && migrated.remindersWrite == reminderRows[reminders]?.write)
                    check("\(label): shell", migrated.shell == (shell ? .ask : .deny))
                    check("\(label): web search is offered", migrated.webSearch == .allow)
                    check("\(label): no shell rules", migrated.shellRules.isEmpty)
                }
            }
        }

        // MARK: Rules — Codable

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var stored = AgentRules.migrated(
            calendarAccess: .read, remindersAccess: .readWrite, shellCommandsEnabled: true)
        stored.shellRules = [
            ShellRule(pattern: "git push*", decision: .ask),
            ShellRule(pattern: "git *", decision: .allow),
            ShellRule(pattern: "rm *", decision: .deny)
        ]
        let roundTripped = (try? encoder.encode(stored)).flatMap {
            try? decoder.decode(AgentRules.self, from: $0)
        }
        check("the table round-trips", roundTripped == stored)
        check(
            "shell rules keep their order and ids",
            roundTripped?.shellRules.map(\.id) == stored.shellRules.map(\.id))
        let storedRows: [String: Any] = [
            "shell": "ask", "calendarRead": "allow", "calendarWrite": "deny",
            "remindersRead": "ask", "remindersWrite": "deny", "webSearch": "ask", "shellRules": []
        ]
        let storedAsk = (try? JSONSerialization.data(withJSONObject: storedRows)) ?? Data()
        check(
            "a stored web search ask decodes as deny",
            (try? decoder.decode(AgentRules.self, from: storedAsk))?.webSearch == .deny)
        let decodedShell = (try? decoder.decode(AgentRules.self, from: storedAsk))?.shell
        check("the other rows decode as stored", decodedShell == .ask)
        check(
            "decisions encode by name",
            (try? encoder.encode([AgentDecision.allow, .ask, .deny]))
                == Data(#"["allow","ask","deny"]"#.utf8))

        let tools: [AgentTool] = AgentTool.builtIn + [.mcp("github"), .mcp("a:b")]
        let toolsRoundTripped = (try? encoder.encode(tools)).flatMap {
            try? decoder.decode([AgentTool].self, from: $0)
        }
        check("every tool round-trips, MCP slugs included", toolsRoundTripped == tools)
        check(
            "tools encode as stable strings",
            (try? encoder.encode([AgentTool.calendarWrite, .mcp("github")]))
                == Data(#"["calendarWrite","mcp:github"]"#.utf8))
        check(
            "an unknown tool fails to decode",
            (try? decoder.decode([AgentTool].self, from: Data(#"["files"]"#.utf8))) == nil)

        // MARK: Session scope

        var scope = AgentSessionScope()
        check("a fresh scope allows everything", tools.allSatisfy(scope.allows))
        scope.toggle(.shell)
        check("toggling excludes", !scope.allows(.shell) && scope.allows(.calendarRead))
        scope.toggle(.shell)
        check("toggling again restores", scope.allows(.shell))
        scope.toggle(.mcp("github"))
        check("an MCP server toggles by slug", !scope.allows(.mcp("github")))
        check("another server is untouched", scope.allows(.mcp("linear")))
        scope.isEnabled = false
        check("a disabled scope allows nothing", !tools.contains(where: scope.allows))

        // MARK: Policy

        let everythingAsks = AgentRules(
            shell: .ask, calendarRead: .ask, calendarWrite: .ask, remindersRead: .ask,
            remindersWrite: .ask, webSearch: .allow)
        let open = AgentSessionScope()
        let trust: [String: AgentDecision] = ["always": .allow, "ask": .ask, "never": .deny]
        let mcpTrust: (String) -> AgentDecision = { trust[$0] ?? .deny }

        func decide(
            _ call: AgentCall, _ rules: AgentRules = everythingAsks,
            scope: AgentSessionScope = open
        ) -> AgentDecision {
            AgentPolicy.decision(for: call, rules: rules, mcpTrust: mcpTrust, scope: scope)
        }
        func offered(
            _ tool: AgentTool, _ rules: AgentRules = everythingAsks,
            scope: AgentSessionScope = open
        ) -> Bool {
            AgentPolicy.isOffered(tool, rules: rules, mcpTrust: mcpTrust, scope: scope)
        }
        func withShell(_ base: AgentDecision, _ patterns: [(String, AgentDecision)]) -> AgentRules {
            var table = everythingAsks
            table.shell = base
            table.shellRules = patterns.map { ShellRule(pattern: $0.0, decision: $0.1) }
            return table
        }

        check("a built-in tool takes its row", decide(AgentCall(tool: .calendarRead)) == .ask)
        var calendarAllowed = everythingAsks
        calendarAllowed.calendarRead = .allow
        check("allow is allow", decide(AgentCall(tool: .calendarRead), calendarAllowed) == .allow)
        check(
            "deny is deny",
            decide(AgentCall(tool: .calendarWrite), .defaults) == .deny)
        check("a shell call without a command takes the row", decide(AgentCall(tool: .shell)) == .ask)

        let gitRules = withShell(.ask, [("git *", .allow), ("rm *", .deny)])
        check("base ask + allow pattern → allow", decide(.shell("git status"), gitRules) == .allow)
        check("an unmatched command asks", decide(.shell("ls"), gitRules) == .ask)
        check("a deny pattern denies", decide(.shell("rm -rf x"), gitRules) == .deny)
        check(
            "deny beats allow across segments",
            decide(.shell("git status && rm -rf x"), gitRules) == .deny)
        check(
            "deny wins wherever it sits",
            decide(.shell("rm x; git status"), gitRules) == .deny)
        check(
            "allow + unmatched → ask",
            decide(.shell("git status; ls"), gitRules) == .ask)
        check(
            "every segment allowed → allow",
            decide(.shell("git status | git log"), gitRules) == .allow)
        check(
            "an unreadable command asks even when it would match",
            decide(.shell("git log $(whoami)"), gitRules) == .ask)
        check(
            "an unreadable command asks even under a deny pattern",
            decide(.shell("rm $(whoami)"), gitRules) == .ask)

        let ordered = withShell(.ask, [("git push*", .ask), ("git *", .allow)])
        check("the first matching rule decides", decide(.shell("git push origin"), ordered) == .ask)
        check("a later rule still matches the rest", decide(.shell("git fetch"), ordered) == .allow)
        let reversed = withShell(.ask, [("git *", .allow), ("git push*", .deny)])
        check(
            "a later deny beats an earlier allow in the same segment",
            decide(.shell("git push"), reversed) == .deny)
        check("and leaves the rest to the allow", decide(.shell("git fetch"), reversed) == .allow)
        let laterAsk = withShell(.ask, [("git *", .allow), ("git push*", .ask)])
        check(
            "a later ask does not beat an earlier allow: only deny skips the order",
            decide(.shell("git push"), laterAsk) == .allow)
        check(
            "a deny under an allow row wins over an allow pattern above it",
            decide(.shell("rm x"), withShell(.allow, [("*", .allow), ("rm *", .deny)])) == .deny)
        let askPattern = withShell(.allow, [("brew *", .ask)])
        check("an ask pattern narrows an allow row", decide(.shell("brew upgrade"), askPattern) == .ask)
        check("an unmatched segment takes an allow row", decide(.shell("ls; pwd"), askPattern) == .allow)
        check("an allow row still asks for the unreadable", decide(.shell("ls `pwd`"), askPattern) == .ask)
        check(
            "an allow row with a deny pattern still denies",
            decide(.shell("ls; rm x"), withShell(.allow, [("rm *", .deny)])) == .deny)

        let shellOff = withShell(.deny, [("git *", .allow), ("*", .allow)])
        check("base deny → deny even under allow patterns", decide(.shell("git status"), shellOff) == .deny)
        check("base deny → not offered, patterns or not", !offered(.shell, shellOff))
        check("base deny → unreadable is deny too", decide(.shell("ls $(pwd)"), shellOff) == .deny)
        check("a shell row that asks is offered", offered(.shell, gitRules))
        check("a shell row that allows is offered", offered(.shell, withShell(.allow, [])))

        var askEverything = AgentSessionScope()
        askEverything.asksForEverything = true
        check(
            "ask for everything caps an allow pattern",
            decide(.shell("git status"), gitRules, scope: askEverything) == .ask)
        check(
            "and an allow row",
            decide(AgentCall(tool: .calendarRead), calendarAllowed, scope: askEverything) == .ask)
        check(
            "and an MCP server that is always trusted",
            decide(AgentCall(tool: .mcp("always")), scope: askEverything) == .ask)
        check(
            "but never lifts a deny",
            decide(.shell("rm x"), gitRules, scope: askEverything) == .deny)
        check(
            "web search has no ask, so it stays allowed",
            decide(AgentCall(tool: .webSearch), scope: askEverything) == .allow)
        check("and stays offered", offered(.webSearch, scope: askEverything))

        var withoutShell = AgentSessionScope()
        withoutShell.toggle(.shell)
        check(
            "a tool switched off for the session is denied",
            decide(.shell("git status"), gitRules, scope: withoutShell) == .deny)
        check("and not offered", !offered(.shell, gitRules, scope: withoutShell))
        check("others stay", decide(AgentCall(tool: .calendarRead), scope: withoutShell) == .ask)
        var disabled = AgentSessionScope()
        disabled.isEnabled = false
        check(
            "a session with tools off denies everything",
            tools.allSatisfy { decide(AgentCall(tool: $0), calendarAllowed, scope: disabled) == .deny })

        check("MCP always → allow", decide(AgentCall(tool: .mcp("always"))) == .allow)
        check("MCP ask → ask", decide(AgentCall(tool: .mcp("ask"))) == .ask)
        check("MCP never → deny", decide(AgentCall(tool: .mcp("never"))) == .deny)
        check("an unknown server → deny", decide(AgentCall(tool: .mcp("gone"))) == .deny)
        check("a never-trusted server is not offered", !offered(.mcp("never")))
        check("an asking server is offered", offered(.mcp("ask")))
        var withoutServer = AgentSessionScope()
        withoutServer.toggle(.mcp("always"))
        check(
            "a server switched off for the session is denied",
            decide(AgentCall(tool: .mcp("always")), scope: withoutServer) == .deny)
        check(
            "a server's slug is never read as a command",
            decide(AgentCall(tool: .mcp("always"), command: "rm x"), gitRules) == .allow)

        check("web search allowed → allow", decide(AgentCall(tool: .webSearch)) == .allow)
        var noSearch = AgentRules.defaults
        noSearch.set(.deny, for: .webSearch)
        check("web search denied → deny", decide(AgentCall(tool: .webSearch), noSearch) == .deny)
        check(
            "web search is never ask, whatever the scope",
            [open, askEverything].allSatisfy { scope in
                [everythingAsks, .defaults].allSatisfy {
                    decide(AgentCall(tool: .webSearch), $0, scope: scope) != .ask
                }
            })

        check(
            "the defaults offer only the read rows and web search",
            Set(AgentPolicy.offered(tools, rules: .defaults, mcpTrust: mcpTrust, scope: open))
                == [.calendarRead, .remindersRead, .webSearch])
        check(
            "offered keeps the given order",
            AgentPolicy.offered(
                [.mcp("ask"), .shell, .mcp("never"), .mcp("always")], rules: gitRules,
                mcpTrust: mcpTrust, scope: open) == [.mcp("ask"), .shell, .mcp("always")])

        // MARK: Suggested pattern

        check("git status → git *", AgentPolicy.suggestedPattern(for: "git status") == "git *")
        check("a bare command → word *", AgentPolicy.suggestedPattern(for: "ls") == "ls *")
        check(
            "surrounding whitespace is ignored",
            AgentPolicy.suggestedPattern(for: "  brew list  ") == "brew *")
        check(
            "redirections do not change the word",
            AgentPolicy.suggestedPattern(for: "ls -la > out") == "ls *")
        check("more than one segment → none", AgentPolicy.suggestedPattern(for: "ls; pwd") == nil)
        check("a pipe → none", AgentPolicy.suggestedPattern(for: "ls | wc") == nil)
        check("unreadable → none", AgentPolicy.suggestedPattern(for: "ls $(pwd)") == nil)
        check("empty → none", AgentPolicy.suggestedPattern(for: "  ") == nil)
        check("a path → none", AgentPolicy.suggestedPattern(for: "/bin/ls -la") == nil)
        check("a relative path → none", AgentPolicy.suggestedPattern(for: "./build.sh") == nil)
        check("a home path → none", AgentPolicy.suggestedPattern(for: "~/bin/tool") == nil)
        for word in [
            "rm", "rmdir", "sudo", "su", "doas", "curl", "wget", "ssh", "scp", "sftp", "rsync", "dd",
            "mkfs", "diskutil", "chmod", "chown", "kill", "killall", "pkill", "launchctl",
            "defaults", "osascript", "sh", "bash", "zsh", "python", "python3", "node", "ruby",
            "perl", "env", "xargs", "find", "mv", "cp"
        ] {
            check("\(word) is never suggested", AgentPolicy.suggestedPattern(for: "\(word) x") == nil)
        }
        check(
            "a suggestion matches the command it came from",
            ShellRule(pattern: AgentPolicy.suggestedPattern(for: "git status") ?? "", decision: .allow)
                .matches("git status"))

        // MARK: Calls from the wire

        func call(_ name: String, _ arguments: String = "{}") -> AgentCall? {
            AgentCall(toolCall: AIToolCall(id: "1", name: name, arguments: arguments))
        }
        check(
            "a shell call carries its command, trimmed as the runner reads it",
            call(ShellToolCatalog.runCommandName, #"{"command":"  ls -la "}"#) == .shell("ls -la"))
        check(
            "a shell call with no command still names the shell",
            call(ShellToolCatalog.runCommandName, "not json") == AgentCall(tool: .shell))
        check(
            "a calendar write carries no command",
            call(CalendarToolCatalog.createEventName, #"{"command":"ls"}"#)
                == AgentCall(tool: .calendarWrite))
        check(
            "a reminder completion is a write",
            call(ReminderToolCatalog.completeName) == AgentCall(tool: .remindersWrite))
        check(
            "an MCP call is its server's row",
            call(MCPToolName.compose(slug: "github", tool: "list"))
                == AgentCall(tool: .mcp("github")))
        check("an unknown call maps to nothing", call("launch_rockets") == nil)

        // MARK: Ask dialogs

        func titles(_ prompt: AgentPrompt) -> [String] { prompt.choices.map(\.title) }
        let ls = AgentPrompt.shell(command: "ls -la", summary: "ls -la\n\nIn ~")
        check(
            "a plain command offers Run, Always Allow its pattern, Don't Run",
            titles(ls) == ["Run", "Always Allow \u{201C}ls *\u{201D}", "Don't Run"])
        check(
            "Always Allow carries the suggested pattern",
            ls.choices[1] == .alwaysAllowCommands(pattern: "ls *"))
        check("↵ runs the command once", ls.defaultIndex == 0 && ls.choices[0].allows)
        check("Escape, the last choice, refuses", ls.choices.last?.allows == false)
        check(
            "the shell dialog shows the summary verbatim",
            ls.title == "Run this command?" && ls.message == "ls -la\n\nIn ~")
        for command in ["rm -rf build", "sudo ls", "ls && pwd", "ls | wc -l", "ls $(pwd)", "./x"] {
            check(
                "\(command) offers no Always Allow",
                titles(AgentPrompt.shell(command: command, summary: command))
                    == ["Run", "Don't Run"])
        }
        let write = AgentPrompt.write(title: "Add “Lunch”?", message: "Sat", symbol: "calendar")
        check(
            "a write is Allow or Don't Allow, with its summary",
            titles(write) == ["Allow", "Don't Allow"] && write.message == "Sat")
        let read = AgentPrompt.read(.calendarRead)
        check(
            "a read may be allowed for the chat",
            titles(read) == ["Allow", "Allow This Chat", "Don't Allow"]
                && read.title == "Let the agent read your calendar?")
        check(
            "reminders read as reminders",
            AgentPrompt.read(.remindersRead).title == "Let the agent read your reminders?")
        let server = AgentPrompt.mcp(serverTitle: "GitHub", tool: "list_issues")
        check(
            "an MCP server keeps its three-way dialog, This Chat by default",
            titles(server) == ["Always Allow", "Allow This Chat", "Don't Allow"]
                && server.defaultIndex == 1 && server.title == "Let GitHub run its tools?")
        check(
            "every dialog ends on its refusal",
            [ls, write, read, server].allSatisfy { prompt in
                prompt.choices.last?.allows == false
                    && prompt.choices.dropLast().allSatisfy(\.allows)
                    && prompt.choices.indices.contains(prompt.defaultIndex)
            })

        // MARK: Refusals

        check(
            "a denied command says the rules stopped it",
            AgentRefusal.denied.message(for: .shell)
                == "Blitz's agent rules do not let the model run this command.")
        check(
            "a declined event says the user did",
            AgentRefusal.declined.message(for: .calendarWrite)
                == "The user declined to let the model add this event.")
        check(
            "every row has both sentences, and they differ",
            (AgentTool.builtIn + [.mcp("x")]).allSatisfy {
                AgentRefusal.denied.message(for: $0) != AgentRefusal.declined.message(for: $0)
            })

        // MARK: This chat's grants

        let asking = AgentRules(
            shell: .ask, calendarRead: .ask, calendarWrite: .ask, remindersRead: .deny,
            remindersWrite: .ask, webSearch: .allow)
        var grantedScope = AgentSessionScope()
        for tool: AgentTool in [
            .calendarRead, .remindersRead, .shell, .calendarWrite, .mcp("ask"), .mcp("never")
        ] {
            grantedScope.grant(tool)
        }
        func granted(_ tool: AgentTool, scope: AgentSessionScope = grantedScope) -> AgentDecision {
            decide(AgentCall(tool: tool), asking, scope: scope)
        }
        check("a granted read is allowed", granted(.calendarRead) == .allow)
        check("a grant never lifts a Deny", granted(.remindersRead) == .deny)
        check(
            "the shell and writes take no grant",
            granted(.shell) == .ask && granted(.calendarWrite) == .ask
                && grantedScope.granted == [.calendarRead, .remindersRead, .mcp("ask"), .mcp("never")])
        check("a granted server is allowed", granted(.mcp("ask")) == .allow)
        check("a grant never lifts a withheld server", granted(.mcp("never")) == .deny)
        check(
            "without the grant, the read and the server still ask",
            granted(.calendarRead, scope: open) == .ask && granted(.mcp("ask"), scope: open) == .ask)
        var grantedAsking = grantedScope
        grantedAsking.asksForEverything = true
        check(
            "ask for everything caps a grant back to ask",
            granted(.calendarRead, scope: grantedAsking) == .ask
                && granted(.mcp("ask"), scope: grantedAsking) == .ask)
        check(
            "a fresh scope carries no grant",
            AgentSessionScope().granted.isEmpty && grantedScope != AgentSessionScope())
        check(
            "only reads and servers can be allowed for a chat",
            AgentTool.builtIn.filter(\.canAllowForSession) == [.calendarRead, .remindersRead]
                && AgentTool.mcp("x").canAllowForSession)

        // MARK: No chat grant under Ask for Everything

        check("an open scope offers grants", open.offersGrants && !askEverything.offersGrants)
        check("an open scope leaves a read's dialog alone", read.scoped(to: open) == read)
        check("and a server's", server.scoped(to: open) == server)
        let scopedRead = read.scoped(to: askEverything)
        check(
            "a read under ask for everything drops Allow This Chat",
            titles(scopedRead) == ["Allow", "Don't Allow"] && scopedRead.defaultIndex == 0
                && scopedRead.choices[0] == .allowOnce("Allow"))
        let scopedServer = server.scoped(to: askEverything)
        check(
            "a server under ask for everything allows once instead, still by default",
            titles(scopedServer) == ["Always Allow", "Allow", "Don't Allow"]
                && scopedServer.defaultIndex == 1 && scopedServer.choices[1] == .allowOnce("Allow"))
        check(
            "and keeps Always Allow, which writes the table rather than the chat",
            scopedServer.choices.first == .alwaysAllowServer)
        check(
            "a dialog with no chat grant is untouched",
            [ls, write].allSatisfy { $0.scoped(to: askEverything) == $0 })
        check(
            "no scoped dialog offers Allow This Chat",
            [ls, write, read, server].allSatisfy { prompt in
                let scoped = prompt.scoped(to: askEverything)
                return !scoped.choices.contains(.allowThisChat)
                    && scoped.choices.last?.allows == false
                    && scoped.choices.indices.contains(scoped.defaultIndex)
            })

        // MARK: Always Allow a pattern

        func patterns(_ rules: AgentRules) -> [String] {
            rules.shellRules.map { "\($0.pattern) → \($0.decision.rawValue)" }
        }
        var pushAsks = withShell(.ask, [("git push *", .ask)])
        check("before: git push asks", decide(.shell("git push origin"), pushAsks) == .ask)
        pushAsks.allow("git *", for: "git push origin")
        check(
            "a new allow lands before the first non-deny rule the command matches",
            patterns(pushAsks) == ["git * → allow", "git push * → ask"])
        check("so it decides that command", decide(.shell("git push origin"), pushAsks) == .allow)
        pushAsks.allow("git *", for: "git push origin")
        check("allowing again adds no duplicate", patterns(pushAsks) == ["git * → allow", "git push * → ask"])

        var unrelated = withShell(.ask, [("ls *", .ask)])
        unrelated.allow("git *", for: "git status")
        check(
            "with nothing matching, the allow is appended",
            patterns(unrelated) == ["ls * → ask", "git * → allow"])

        var pushDenied = withShell(.ask, [("git push *", .deny), ("brew *", .ask)])
        pushDenied.allow("git *", for: "git status")
        check(
            "a deny is never a place to insert before",
            patterns(pushDenied) == ["git push * → deny", "brew * → ask", "git * → allow"])
        var denyFirst = withShell(.ask, [("git status *", .ask), ("git push *", .deny)])
        denyFirst.allow("git *", for: "git status")
        check(
            "an allow placed above a deny",
            patterns(denyFirst) == ["git * → allow", "git status * → ask", "git push * → deny"])
        check("never shadows it", decide(.shell("git push origin"), denyFirst) == .deny)
        check("and decides its own command", decide(.shell("git status"), denyFirst) == .allow)

        let samePatternID = UUID()
        var samePattern = everythingAsks
        samePattern.shellRules = [
            ShellRule(pattern: "brew *", decision: .ask),
            ShellRule(pattern: "git  status *", decision: .ask),
            ShellRule(id: samePatternID, pattern: "git *", decision: .ask)
        ]
        samePattern.allow("git *", for: "git status -s")
        check(
            "an existing rule with the same pattern turns allow and moves ahead of the decider",
            patterns(samePattern) == ["brew * → ask", "git * → allow", "git  status * → ask"]
                && samePattern.shellRules[1].id == samePatternID)
        check("and decides the command", decide(.shell("git status -s"), samePattern) == .allow)
        var spaced = samePattern
        spaced.allow("git   *", for: "git status")
        check("patterns compare collapsed, so no duplicate appears", spaced == samePattern)
        var earlyRule = withShell(.ask, [("git *", .ask), ("ls *", .ask)])
        earlyRule.allow("git *", for: "git status")
        check(
            "an existing rule already ahead stays where it is",
            patterns(earlyRule) == ["git * → allow", "ls * → ask"])
        var multi = withShell(.ask, [("ls *", .ask), ("git log *", .ask)])
        multi.allow("git *", for: "ls && git log")
        check(
            "any segment of the command places the allow",
            patterns(multi) == ["git * → allow", "ls * → ask", "git log * → ask"])
        var blank = withShell(.ask, [])
        blank.allow("  ", for: "ls")
        check("an empty pattern is never added", blank.shellRules.isEmpty)

        // MARK: Context card rows

        let rows = AgentPolicy.decisions(
            for: [.shell, .calendarRead, .remindersRead, .mcp("github"), .mcp("files")],
            rules: asking, mcpTrust: { $0 == "github" ? .allow : .deny },
            scope: AgentSessionScope())
        check(
            "rows list the offered tools in order, with their bare decision",
            rows == [
                .init(tool: .shell, decision: .ask), .init(tool: .calendarRead, decision: .ask),
                .init(tool: .mcp("github"), decision: .allow)
            ])
        var narrowed = AgentSessionScope()
        narrowed.excluded = [.shell]
        narrowed.asksForEverything = true
        check(
            "the chat's scope removes and narrows rows",
            AgentPolicy.decisions(
                for: [.shell, .mcp("github")], rules: asking,
                mcpTrust: { _ in .allow }, scope: narrowed)
                == [.init(tool: .mcp("github"), decision: .ask)])
        narrowed.isEnabled = false
        check(
            "tools off leaves no rows",
            AgentPolicy.decisions(
                for: AgentTool.builtIn, rules: asking, mcpTrust: { _ in .allow }, scope: narrowed)
                .isEmpty)

        exit(failures == 0 ? 0 : 1)
    }
}
