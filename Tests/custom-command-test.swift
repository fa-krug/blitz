import Foundation

// Spawns real `/bin/zsh`; `ZDOTDIR` is a fixture, so every assertion is relative.
@main
struct CustomCommandTests {
    @MainActor
    static func main() async {
        // The app has no controlling terminal; an inherited one gets `zsh -i` stopped by SIGTTOU.
        setsid()
        let suiteName = "de.fa-krug.blitz.custom-command-tests"
        let defaults = isolatedDefaults(suiteName)

        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // MARK: Store

        let store = CustomCommandStore(defaults: defaults)
        let added = try? store.add(
            CustomCommand(
                name: "  Sleep Displays  ", command: "  /usr/bin/pmset displaysleepnow  ",
                requiresConfirmation: true))
        check("add trims the name", added?.name == "Sleep Displays")
        check("add trims the command", added?.command == "/usr/bin/pmset displaysleepnow")
        check("add keeps the flags", added?.requiresConfirmation == true)
        check(
            "the entry id round-trips to the UUID",
            added.map { CustomCommand.id(fromEntryID: $0.entryID) == $0.id } == true)

        guard let added else {
            print("FAIL  add returned nothing; the remaining cases need it")
            exit(1)
        }

        var duplicateRejected = false
        do {
            _ = try store.add(CustomCommand(name: "sleep displays", command: "/usr/bin/true"))
        } catch CustomCommandValidationError.duplicateName {
            duplicateRejected = true
        } catch {}
        check("a name differing only in case is rejected", duplicateRejected)

        try? store.update(
            CustomCommand(
                id: added.id, name: "Sleep Screens", command: "/usr/bin/true",
                loadsShellEnvironment: true))
        check("update keeps the id", store.command(id: added.id) != nil)
        check("update applies the new name", store.command(id: added.id)?.name == "Sleep Screens")
        check(
            "update applies a flag",
            store.command(id: added.id)?.loadsShellEnvironment == true)
        check(
            "update clears a flag left out of the draft",
            store.command(id: added.id)?.requiresConfirmation == false)

        check("a new command is enabled", store.command(id: added.id)?.isEnabled == true)
        store.setEnabled(false, id: added.id)
        check("disabling is stored", store.command(id: added.id)?.isEnabled == false)
        check(
            "disabling keeps every other field intact",
            store.command(id: added.id)?.command == "/usr/bin/true")
        store.setEnabled(true, id: added.id)

        let expected = store.commands
        check(
            "commands survive a reload with their flags",
            CustomCommandStore(defaults: defaults).commands == expected)

        // `replace` runs the import sanitizer, which must carry every flag through.
        store.replace(with: [
            CustomCommand(
                name: "Imported", command: "/usr/bin/true", loadsShellEnvironment: true,
                requiresConfirmation: true, showsConfirmation: true,
                arguments: [CustomCommandArgument(name: "  Query  ", isOptional: true)],
                opensTerminal: true)
        ])
        check(
            "import preserves every flag",
            store.commands.first?.loadsShellEnvironment == true
                && store.commands.first?.requiresConfirmation == true
                && store.commands.first?.showsConfirmation == true
                && store.commands.first?.opensTerminal == true)
        let storedFlags = Data(
            #"[{"id":"\#(UUID().uuidString)","name":"Old","command":"/usr/bin/true","#
                .appending(#""showsOutput":true,"runsInTerminal":true}]"#).utf8)
        let decoded = try? JSONDecoder().decode([CustomCommand].self, from: storedFlags)
        check(
            "a stored runsInTerminal key is ignored and showsOutput reads as opensTerminal",
            decoded?.first?.opensTerminal == true)
        let encoded = (try? JSONEncoder().encode(decoded ?? []))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        check(
            "opensTerminal is written under the showsOutput key",
            encoded?.first?["showsOutput"] as? Bool == true
                && encoded?.first?["opensTerminal"] == nil
                && encoded?.first?["runsInTerminal"] == nil)
        check(
            "import trims an argument name and keeps its optionality",
            store.commands.first?.arguments == [
                CustomCommandArgument(name: "Query", isOptional: true)
            ])

        store.replace(with: [
            CustomCommand(
                name: "Blanks", command: "/usr/bin/true",
                arguments: [
                    CustomCommandArgument(name: "Kept"), CustomCommandArgument(name: "   ")
                ])
        ])
        check(
            "a blank argument is dropped without losing the command",
            store.commands.first?.arguments == [CustomCommandArgument(name: "Kept")])

        // A command stored before arguments existed must still decode.
        let legacy = Data(
            """
            [{"id":"\(UUID().uuidString)","name":"Legacy","command":"/usr/bin/true"}]
            """.utf8)
        defaults.set(legacy, forKey: "customCommands")
        check(
            "a record written before arguments existed still loads",
            CustomCommandStore(defaults: defaults).commands.first?.name == "Legacy")
        check(
            "a record written before the enabled flag loads as enabled",
            CustomCommandStore(defaults: defaults).commands.first?.isEnabled == true)

        // MARK: Batch add

        var commits = 0
        store.onChange = { _ in commits += 1 }
        let batched = store.add(contentsOf: [
            CustomCommand(name: "One", command: "/usr/bin/true"),
            CustomCommand(name: "blanks", command: "/usr/bin/true"),
            CustomCommand(name: "Two", command: "/usr/bin/true"),
            CustomCommand(name: "one", command: "/usr/bin/false")
        ])
        store.onChange = nil
        check("a batch add counts only the commands it added", batched == 2)
        check("a whole batch is one commit", commits == 1)
        check(
            "a name colliding with the library or with the batch is dropped",
            store.commands.map(\.name) == ["Blanks", "One", "Two"])

        // MARK: Raycast script import

        let shellSource = """
            #!/bin/bash

            # Required parameters:
            # @raycast.schemaVersion 1
            # @raycast.title Chrome CDP
            # @raycast.mode silent

            # Optional parameters:
            # @raycast.icon 📘
            # @raycast.needsConfirmation false

            CDP_PORT=9222
            # @raycast.mode fullOutput
            """
        let shellScript = RaycastScriptImport.command(
            at: URL(fileURLWithPath: "/Users/me/scripts/chrome cdp.sh"), source: shellSource)
        check("the title becomes the command name", shellScript?.name == "Chrome CDP")
        check(
            "the shebang names the interpreter and the path is one quoted word",
            shellScript?.command == #"/bin/bash '/Users/me/scripts/chrome cdp.sh' "$@""#)
        check("silent mode opens no terminal", shellScript?.opensTerminal == false)
        check("needsConfirmation false stays off", shellScript?.requiresConfirmation == false)
        check(
            "a script runs in its own folder",
            shellScript?.workingDirectory == "/Users/me/scripts")

        let appleSource = """
            #!/usr/bin/osascript

            # @raycast.schemaVersion 1
            # @raycast.title Facebook
            # @raycast.mode fullOutput
            # @raycast.needsConfirmation true
            # @raycast.currentDirectoryPath ~/Sites
            # @raycast.argument1 { "type": "text", "placeholder": "Profile" }
            # @raycast.argument2 { "type": "text", "placeholder": "Tab", "optional": true }

            tell application id "com.vivaldi.Vivaldi"
            """
        let appleScript = RaycastScriptImport.command(
            at: URL(fileURLWithPath: "/tmp/facebook.applescript"), source: appleSource)
        check(
            "osascript comes from the shebang",
            appleScript?.command == #"/usr/bin/osascript '/tmp/facebook.applescript' "$@""#)
        check("an output mode opens the terminal", appleScript?.opensTerminal == true)
        check("needsConfirmation true is carried over", appleScript?.requiresConfirmation == true)
        check(
            "a declared directory wins over the script's folder",
            appleScript?.workingDirectory == "~/Sites")
        check(
            "arguments come from their placeholders, in order",
            appleScript?.arguments == [
                CustomCommandArgument(name: "Profile"),
                CustomCommandArgument(name: "Tab", isOptional: true)
            ])

        check(
            "a file naming no interpreter is not a script command",
            RaycastScriptImport.command(
                at: URL(fileURLWithPath: "/tmp/notes.txt"), source: "# @raycast.title Notes\n")
                == nil)
        check(
            "a script declaring no title is not a script command",
            RaycastScriptImport.command(
                at: URL(fileURLWithPath: "/tmp/helper.sh"),
                source: "#!/bin/bash\n# @raycast.schemaVersion 1\necho hi\n") == nil)
        check(
            "the JavaScript template's // directives are read too",
            RaycastScriptImport.command(
                at: URL(fileURLWithPath: "/tmp/x.js"),
                source: "#!/usr/bin/env node\n// @raycast.title Node\n")?.command
                == #"/usr/bin/env node '/tmp/x.js' "$@""#)
        check(
            "a quote in the path cannot break out of the argument",
            RaycastScriptImport.command(
                at: URL(fileURLWithPath: "/tmp/it's here.sh"),
                source: "#!/bin/zsh\n# @raycast.title Quoted\n")?.command
                == #"/bin/zsh '/tmp/it'\''s here.sh' "$@""#)

        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-scripts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: scriptDirectory.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for (name, source) in [
            ("b-second.sh", "#!/bin/bash\n# @raycast.title Second\n"),
            ("a-first.sh", "#!/bin/bash\n# @raycast.title First\n"),
            ("plain.txt", "just notes\n"),
            (".hidden.sh", "#!/bin/bash\n# @raycast.title Hidden\n")
        ] {
            try? Data(source.utf8).write(to: scriptDirectory.appendingPathComponent(name))
        }
        check(
            "a folder yields its script commands in name order and nothing else",
            RaycastScriptImport.scan(directory: scriptDirectory).map(\.name) == ["First", "Second"])

        // The whole run, through `"$@"`: an imported script reads its value as data, never as syntax.
        try? Data("#!/bin/bash\n# @raycast.title Echo\nprintf '%s' \"$1\"\n".utf8).write(
            to: scriptDirectory.appendingPathComponent("echo.sh"))
        let imported = RaycastScriptImport.scan(directory: scriptDirectory).first { $0.name == "Echo" }
        let forwarded = await ShellCommandRunner.run(
            imported?.command ?? "", arguments: ["; touch /tmp/blitz-import-should-not-exist"],
            workingDirectory: imported?.workingDirectory)
        check(
            "an imported script receives its argument as one inert word",
            forwarded.standardOutput == "; touch /tmp/blitz-import-should-not-exist"
                && !FileManager.default.fileExists(atPath: "/tmp/blitz-import-should-not-exist"))
        try? FileManager.default.removeItem(at: scriptDirectory)

        // MARK: Runner

        let succeeded = await ShellCommandRunner.run("/usr/bin/true")
        check("a zero exit reports success", succeeded.succeeded)

        let inHome = await ShellCommandRunner.run("test \"$PWD\" = \"$HOME\"")
        check("commands start in the user's home directory", inHome.succeeded)

        let marker = await ShellCommandRunner.run("test \"$BLITZ\" = 1")
        check("the BLITZ marker is exported so a shell config can detect us", marker.succeeded)

        let failed = await ShellCommandRunner.run("printf 'expected failure' >&2; exit 7")
        check(
            "a non-zero exit reports its status and stderr",
            failed.termination == .exited(status: 7) && failed.standardError == "expected failure")

        // MARK: Working directory

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let atHome = await ShellCommandRunner.run("pwd")
        check(
            "a command with no folder starts at home",
            atHome.lastOutputLine?.hasSuffix(home) == true)

        let elsewhere = await ShellCommandRunner.run("pwd", workingDirectory: "/usr/lib")
        check("a command runs in the folder it names", elsewhere.lastOutputLine == "/usr/lib")

        let tilde = await ShellCommandRunner.run("pwd", workingDirectory: "~/")
        check("a tilde path is expanded", tilde.lastOutputLine?.hasSuffix(home) == true)

        // Silently running somewhere else would be worse than not running at all.
        let gone = await ShellCommandRunner.run("pwd", workingDirectory: "/nope/does/not/exist")
        var reportedMissing = false
        if case .launchFailed(let reason) = gone.termination {
            reportedMissing = reason.contains("no longer exists")
        }
        check("a folder that has gone is reported, not ignored", reportedMissing)

        let notADirectory = await ShellCommandRunner.run("pwd", workingDirectory: "/etc/hosts")
        var rejectedFile = false
        if case .launchFailed = notADirectory.termination { rejectedFile = true }
        check("a file is not accepted as a working folder", rejectedFile)

        // MARK: One-line report

        let spoke = await ShellCommandRunner.run("echo first; echo 'all done'")
        check("the report shows the command's last line", spoke.lastOutputLine == "all done")

        let trailing = await ShellCommandRunner.run("printf 'only line\\n\\n\\n'")
        check("trailing blank lines are skipped", trailing.lastOutputLine == "only line")

        let mute = await ShellCommandRunner.run("true")
        check("a silent command offers no line to report", mute.lastOutputLine == nil)

        // MARK: Icon and folder round-trip

        store.replace(with: [
            CustomCommand(
                name: "Iconned", command: "/usr/bin/true",
                workingDirectory: "  ~/Developer  ", iconSymbol: "  hammer  ")
        ])
        check(
            "an icon and a folder are trimmed and kept",
            store.commands.first?.iconSymbol == "hammer"
                && store.commands.first?.workingDirectory == "~/Developer")

        store.replace(with: [
            CustomCommand(name: "Bare", command: "/usr/bin/true", workingDirectory: "   ")
        ])
        check(
            "a blank folder means home rather than an empty path",
            store.commands.first?.workingDirectory == nil)
        check(
            "a command with no icon falls back to the shared glyph",
            store.commands.first?.symbol == CustomCommand.sfSymbol)

        // MARK: Arguments

        let positional = await ShellCommandRunner.run(
            "test \"$1\" = alpha && test \"$2\" = beta", arguments: ["alpha", "beta"])
        check("values arrive as positional parameters", positional.succeeded)

        // The whole reason values are passed positionally: shell syntax in one is inert.
        let injected = await ShellCommandRunner.run(
            "printf '%s\\n' \"$1\"", arguments: ["; touch /tmp/blitz-should-not-exist"])
        check(
            "a value carrying shell syntax is data, not code",
            injected.lastOutputLine == "; touch /tmp/blitz-should-not-exist"
                && !FileManager.default.fileExists(atPath: "/tmp/blitz-should-not-exist"))

        // MARK: Inline argument values

        let search = CustomCommand(
            name: "Search", command: "open \"$1$2\"",
            arguments: [
                CustomCommandArgument(name: "Query"),
                CustomCommandArgument(name: "Query", isOptional: true)
            ])
        check(
            "fields are keyed by position, so a shared name cannot collide",
            (0..<2).map(CustomCommandArgument.fieldID) == ["$1", "$2"])
        check(
            "a required value still empty holds the run",
            search.positionalValues(from: ["$2": "swift"]) == nil)
        check(
            "an optional value left empty still occupies its slot",
            search.positionalValues(from: ["$1": "google"]) == ["google", ""])
        check(
            "values arrive in $n order",
            search.positionalValues(from: ["$2": "swift", "$1": "google"]) == ["google", "swift"])
        check(
            "a command without arguments is always complete",
            CustomCommand(name: "Plain", command: "true").positionalValues(from: [:]) == [])

        let capped = CustomCommandArgument.sanitized(
            ["a", " ", "b", "c", "d"].map { CustomCommandArgument(name: $0) })
        check(
            "arguments are capped at three, counted after blanks drop",
            capped.map(\.name) == ["a", "b", "c"])

        // MARK: Shell environment

        // A throwaway ZDOTDIR proves interactive mode sources an rc file.
        let zdotdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-zdotdir-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try? Data("alias blitz_probe=true\n".utf8).write(
            to: zdotdir.appendingPathComponent(".zshrc"))
        setenv("ZDOTDIR", zdotdir.path, 1)
        // `/etc/zshrc` sources `zshrc_$TERM_PROGRAM`, which writes to the real home.
        unsetenv("TERM_PROGRAM")

        let withEnvironment = await ShellCommandRunner.run(
            "blitz_probe", loadingShellEnvironment: true)
        check(
            "loading the shell environment resolves an rc-file alias",
            withEnvironment.succeeded)

        // The reported symptom: an alias only in `.zshrc` is command-not-found.
        let withoutEnvironment = await ShellCommandRunner.run("blitz_probe")
        check(
            "the default shell exits 127 on an rc-file alias",
            withoutEnvironment.termination == .exited(status: 127))

        // The interactive-shell argument rests on this: a prompt reads EOF.
        let prompted = await ShellCommandRunner.run(
            "read -r answer", loadingShellEnvironment: true)
        check("a command reading stdin fails instead of hanging", !prompted.succeeded)

        // MARK: Terminals

        // Stands in for the user's shell, so a run ends once it shows the shell opened.
        let fakeShell = zdotdir.appendingPathComponent("fake-shell")
        FileManager.default.createFile(
            atPath: fakeShell.path,
            contents: Data(
                "#!/bin/sh\nprintf 'shell-opened:%s:%s\\n' \"${BLITZ-unset}\" \"$1\"\n".utf8),
            attributes: [.posixPermissions: 0o755])
        setenv("SHELL", fakeShell.path, 1)

        let liveTerminal = await record(
            ShellCommandRunner.openTerminal(command: "echo first; sleep 1; echo second"))
        check(
            "terminal output arrives while the command is still running",
            (liveTerminal.firstOutputAt ?? .seconds(9)) < .milliseconds(500)
                && liveTerminal.output.contains("first\nsecond"))
        check(
            "the user's shell opens as a login shell once the command is done",
            liveTerminal.outputAfterCommand.contains("shell-opened:unset:-l") && liveTerminal.ended)

        let exitedTerminal = await record(ShellCommandRunner.openTerminal(command: "exit 7"))
        check(
            "the command's status arrives through the marker, which never reaches the view",
            exitedTerminal.result == .exited(status: 7) && !exitedTerminal.output.contains("6973"))

        var markerScanner = ShellMarkerScanner(code: 6973, nonce: "N")
        let markedBytes = Array("before\u{1B}]6973;N;7\u{07}after".utf8)
        let splitPieces = markedBytes.flatMap { markerScanner.scan([$0]) }
        let splitText = splitPieces.flatMap { piece -> [UInt8] in
            if case .text(let bytes) = piece { return bytes }
            return []
        }
        check(
            "a marker split across reads is still found and cut out",
            String(decoding: splitText, as: UTF8.self) == "beforeafter"
                && splitPieces.filter { $0 == .marker("7") }.count == 1
                && markerScanner.remainder.isEmpty)
        var lookalike = ShellMarkerScanner(code: 6973, nonce: "N")
        let heldBack = lookalike.scan(Array("x\u{1B}]69".utf8))
        let released = lookalike.scan(Array("q".utf8))
        check(
            "bytes held back as a possible marker are released once they are not one",
            heldBack == [.text(Array("x".utf8))] && released == [.text(Array("\u{1B}]69q".utf8))])

        let spoofed = await record(
            ShellCommandRunner.openTerminal(
                command: "printf '\\e]6973;not-the-nonce;0\\a'; printf 'after\\n'; exit 5"))
        check(
            "a marker without the nonce is ignored and passed through to the view",
            spoofed.result == .exited(status: 5)
                && spoofed.output.contains("\u{1B}]6973;not-the-nonce;0\u{07}after"))

        for loadsEnvironment in [false, true] {
            let mode = loadsEnvironment ? " (loading the environment)" : ""
            var interrupted = false
            // Interactive zsh shrugs off a ⌃C between commands, so `ready` comes from the child.
            let typedInterrupt = await record(
                ShellCommandRunner.openTerminal(
                    command: "/bin/sh -c 'echo ready; exec sleep 30'; echo nope",
                    loadingShellEnvironment: loadsEnvironment)
            ) { session, run in
                if !interrupted, run.output.contains("ready") {
                    interrupted = true
                    session.send([0x03])
                }
            }
            check(
                "a typed ⌃C interrupts the command with 130 and abandons its line\(mode)",
                typedInterrupt.result == .exited(status: 130)
                    && !typedInterrupt.output.contains("nope")
                    && (typedInterrupt.finishedAt ?? .seconds(9)) < .seconds(2))
            check(
                "the shell still opens after a typed ⌃C\(mode)",
                typedInterrupt.outputAfterCommand.contains("shell-opened"))
        }

        var stopSent = false
        let stoppedTerminal = await record(
            ShellCommandRunner.openTerminal(command: "echo ready; sleep 30; echo nope")
        ) { session, run in
            if !stopSent, run.output.contains("ready") {
                stopSent = true
                session.stop()
            }
        }
        check(
            "Stop reports a stopped command, without waiting for the kill",
            stoppedTerminal.result == .stopped && !stoppedTerminal.output.contains("nope")
                && (stoppedTerminal.finishedAt ?? .seconds(9)) < .milliseconds(1500))
        check(
            "the shell still opens after Stop",
            stoppedTerminal.outputAfterCommand.contains("shell-opened"))

        var stubbornStopSent = false
        let stubbornTerminal = await record(
            ShellCommandRunner.openTerminal(command: "trap '' INT; echo ready; sleep 45")
        ) { session, run in
            if !stubbornStopSent, run.output.contains("ready") {
                stubbornStopSent = true
                session.stop()
            }
        }
        let stubbornSurvivors = await ShellCommandRunner.run("pgrep -f 'sleep 4[5]' | wc -l")
        check(
            "a command ignoring ⌃C is killed after the grace, with no survivor",
            stubbornTerminal.result == .stopped && stubbornSurvivors.lastOutputLine == "0")
        check(
            "the shell still opens after the backstop kill",
            stubbornTerminal.outputAfterCommand.contains("shell-opened"))

        // A slow rc file is where a Stop lands between commands, which interactive zsh shrugs off.
        var startupStopSent = false
        let startupStopped = await record(
            ShellCommandRunner.openTerminal(
                command: "echo ready; sleep 46", loadingShellEnvironment: true)
        ) { session, run in
            if !startupStopSent, run.output.contains("ready") {
                startupStopSent = true
                session.stop()
            }
        }
        check(
            "Stop still ends an interactive command that shrugged off its ⌃C",
            startupStopped.result == .stopped
                && startupStopped.outputAfterCommand.contains("shell-opened"))

        let abandoned = ShellCommandRunner.openTerminal(command: "sleep 47")
        let abandonedReader = Task { for await _ in abandoned.events {} }
        try? await Task.sleep(for: .milliseconds(300))
        abandonedReader.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        let abandonedSurvivors = await ShellCommandRunner.run("pgrep -f 'sleep 4[7]' | wc -l")
        check(
            "a terminal whose events are dropped is hung up",
            abandonedSurvivors.lastOutputLine == "0")

        let controlling = await record(
            ShellCommandRunner.openTerminal(
                command: ": </dev/tty && echo tty-ok; [[ -t 0 ]] && echo stdin-is-tty; stty -a"))
        check(
            "the command has a controlling terminal",
            controlling.output.contains("tty-ok") && controlling.output.contains("stdin-is-tty"))
        check(
            "the terminal keeps the kernel's ⌃D and ⌃C and adds UTF-8 erasing",
            controlling.output.contains(" iutf8") && controlling.output.contains("eof = ^D")
                && controlling.output.contains("intr = ^C"))

        let injection = "/tmp/blitz-terminal-should-not-exist"
        let terminalValues = ["it's", "a; touch \(injection)", "$(touch \(injection))"]
        let positionalTerminal = await record(
            ShellCommandRunner.openTerminal(
                command: "printf '[%s]\\n' \"$@\"", arguments: terminalValues))
        check(
            "terminal values arrive positionally, shell syntax in them inert",
            terminalValues.allSatisfy { positionalTerminal.output.contains("[\($0)]") }
                && !FileManager.default.fileExists(atPath: injection))

        var resized = false
        let sizedTerminal = await record(
            ShellCommandRunner.openTerminal(
                command: "stty size; read -r _; stty size", columns: 100, rows: 30)
        ) { session, run in
            if !resized, run.output.contains("30 100") {
                resized = true
                session.resize(120, 40)
                session.send(Array("\n".utf8))
            }
        }
        check(
            "the terminal starts at the size asked for and follows a resize",
            sizedTerminal.output.contains("30 100") && sizedTerminal.output.contains("40 120"))

        var hungUp = false
        let hangUpTerminal = await record(
            ShellCommandRunner.openTerminal(command: "echo ready; sleep 44")
        ) { session, run in
            if !hungUp, run.output.contains("ready") {
                hungUp = true
                session.hangUp()
            }
        }
        let hangUpSurvivors = await ShellCommandRunner.run("pgrep -f 'sleep 4[4]' | wc -l")
        check(
            "hanging up ends the session at once and kills the running command",
            hangUpTerminal.ended && (hangUpTerminal.endedAt ?? .seconds(9)) < .seconds(2)
                && hangUpSurvivors.lastOutputLine == "0")

        let limit = ShellCommandRunner.pendingOutputLimit
        let flood = await record(
            ShellCommandRunner.openTerminal(
                command: "yes blitz-flood | head -n 100000; echo done-marker"),
            pausingOnFirstOutput: .milliseconds(500))
        check(
            "a flood the consumer is too slow for backs up only to the limit, then arrives whole",
            flood.largestOutput <= limit && flood.largestOutput > limit / 2
                && flood.output.hasPrefix(
                    String(repeating: "blitz-flood\n", count: 100_000) + "done-marker\n")
                && flood.result == .exited(status: 0) && flood.ended)

        let pausedHangUp = ShellCommandRunner.openTerminal(command: "yes blitz-hang-up")
        let hangUpDuringPause = Task {
            try? await Task.sleep(for: .milliseconds(250))
            pausedHangUp.hangUp()
        }
        let hungUpFlood = await record(pausedHangUp, pausingOnFirstOutput: .milliseconds(500))
        hangUpDuringPause.cancel()
        let pausedSurvivors = await ShellCommandRunner.run("pgrep -f 'yes blitz-hang-u[p]' | wc -l")
        check(
            "hanging up a flood nobody is reading drops its output and ends it at once",
            hungUpFlood.ended && (hungUpFlood.endedAt ?? .seconds(9)) < .milliseconds(1200)
                && hungUpFlood.output.utf8.count <= limit
                && pausedSurvivors.lastOutputLine == "0")

        let missingTerminal = await record(
            ShellCommandRunner.openTerminal(
                command: "pwd", workingDirectory: "/nope/does/not/exist"))
        var terminalMissingReported = false
        if case .launchFailed(let reason) = missingTerminal.result {
            terminalMissingReported = reason.contains("no longer exists")
        }
        check(
            "a terminal in a folder that has gone reports a launch failure",
            terminalMissingReported && missingTerminal.ended)

        // Not close-on-exec, the way a library might leave them; the child must still not see them.
        let strayDescriptor = open("/dev/null", O_RDONLY)
        let highStrayDescriptor = fcntl(strayDescriptor, F_DUPFD, 60)
        let descriptorTerminal = await record(
            ShellCommandRunner.openTerminal(command: "/bin/ls /dev/fd | /usr/bin/paste -sd , -"))
        Darwin.close(strayDescriptor)
        Darwin.close(highStrayDescriptor)
        // `ls` holds 3 and 4 itself while it lists the folder.
        check(
            "the command inherits only the terminal's three descriptors",
            descriptorTerminal.output.hasPrefix("0,1,2,3,4\n"))

        let blitzMarked = await record(
            ShellCommandRunner.openTerminal(command: "echo \"command:${BLITZ-unset}\""))
        check(
            "BLITZ is set for the command and not for the user's shell",
            blitzMarked.output.contains("command:1")
                && blitzMarked.outputAfterCommand.contains("shell-opened:unset"))

        let folderTerminal = await record(
            ShellCommandRunner.openTerminal(command: "sleep 0.6", workingDirectory: "/usr/lib"))
        check(
            "the terminal reports the folder it starts in",
            folderTerminal.directories.first == "/usr/lib")

        let blankEnvironment = ShellCommandRunner.terminalEnvironment(
            inheriting: ["BLITZ": "1", "TERM": "dumb"], locale: Locale(identifier: "de_DE"))
        check(
            "a terminal asks for colour, drops an inherited BLITZ and fills a missing LANG",
            blankEnvironment["TERM"] == "xterm-256color"
                && blankEnvironment["COLORTERM"] == "truecolor"
                && blankEnvironment["BLITZ"] == nil && blankEnvironment["LANG"] == "de_DE.UTF-8")
        check(
            "an uninstalled language and region falls back to a UTF-8 locale that exists",
            ShellCommandRunner.terminalEnvironment(
                inheriting: [:], locale: Locale(identifier: "en_DE"))["LANG"] == "en_US.UTF-8")
        check(
            "a LANG the user already has is kept",
            ShellCommandRunner.terminalEnvironment(
                inheriting: ["LANG": "C"], locale: Locale(identifier: "de_DE"))["LANG"] == "C")

        // The "suspended (tty output)" regression: the shell after an interactive command must run.
        try? Data("alias blitz_probe=true\nPS1='blitz-prompt> '\n".utf8).write(
            to: zdotdir.appendingPathComponent(".zshrc"))
        setenv("SHELL", "/bin/zsh", 1)
        var shellStep = 0
        let interactiveTerminal = await record(
            ShellCommandRunner.openTerminal(
                command: "blitz_probe && echo alias-ok", loadingShellEnvironment: true)
        ) { session, run in
            switch shellStep {
            case 0 where run.outputAfterCommand.contains("blitz-prompt> "):
                shellStep = 1
                session.send(Array("cd /usr/lib\n".utf8))
            case 1 where run.directories.last == "/usr/lib":
                shellStep = 2
                session.send(Array("echo typed-$((6*7)); exit\n".utf8))
            default:
                break
            }
        }
        check(
            "loading the environment resolves an rc-file alias in a terminal",
            interactiveTerminal.result == .exited(status: 0)
                && interactiveTerminal.output.contains("alias-ok"))
        check(
            "a cd in the user's shell is reported as the terminal's folder",
            shellStep == 2)
        check(
            "the user's shell runs a typed line after an interactive command, then exits",
            interactiveTerminal.outputAfterCommand.contains("typed-42")
                && interactiveTerminal.ended
                && (interactiveTerminal.endedAt ?? .seconds(9)) < .seconds(8))
        unsetenv("SHELL")

        unsetenv("ZDOTDIR")

        try? FileManager.default.removeItem(at: zdotdir)
        discardSuite(suiteName, defaults)
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `removePersistentDomain` only empties the domain; cfprefsd still leaves the plist on disk.
private func discardSuite(_ name: String, _ defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(name).plist"))
}

/// A fixed suite name stops cfprefsd accumulating a plist per run.
private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// What a terminal reported, with times measured from when recording began.
private struct TerminalRecord {
    var output = ""
    var outputAfterCommand = ""
    var result: ShellCommandTermination?
    var directories: [String] = []
    var ended = false
    /// The most output any one event carried.
    var largestOutput = 0
    var firstOutputAt: Duration?
    var finishedAt: Duration?
    var endedAt: Duration?
}

/// Records until the session ends; one still open at `limit` is hung up, which fails its checks.
@MainActor
private func record(
    _ session: TerminalSession, limit: Duration = .seconds(8),
    pausingOnFirstOutput pause: Duration? = nil,
    react: (TerminalSession, TerminalRecord) -> Void = { _, _ in }
) async -> TerminalRecord {
    let watchdog = Task {
        try? await Task.sleep(for: limit)
        if !Task.isCancelled { session.hangUp() }
    }
    defer { watchdog.cancel() }
    let clock = ContinuousClock()
    let began = clock.now
    var run = TerminalRecord()
    for await event in session.events {
        switch event {
        case .output(let bytes):
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            let isFirstOutput = run.firstOutputAt == nil
            run.firstOutputAt = run.firstOutputAt ?? clock.now - began
            run.output += text
            run.largestOutput = max(run.largestOutput, bytes.count)
            if run.result != nil { run.outputAfterCommand += text }
            if isFirstOutput, let pause { try? await Task.sleep(for: pause) }
        case .commandFinished(let result):
            run.result = result.termination
            run.finishedAt = clock.now - began
        case .directoryChanged(let directory):
            run.directories.append(directory)
        case .ended:
            run.ended = true
            run.endedAt = clock.now - began
        }
        react(session, run)
    }
    return run
}
