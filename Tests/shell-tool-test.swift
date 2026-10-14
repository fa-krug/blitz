import Foundation

// Spawns real `/bin/zsh`; `ZDOTDIR` points at an empty folder so no personal config runs.
@main
struct ShellToolTests {
    static func main() async {
        let zdotdir = FileManager.default.temporaryDirectory
            .appending(path: "blitz-shell-tool-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        setenv("ZDOTDIR", zdotdir.path, 1)
        defer { try? FileManager.default.removeItem(at: zdotdir) }

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

        let tools = ShellToolCatalog.tools()
        check("one tool is offered", tools.map(\.name) == ["shell_run_command"])
        check("the catalog claims its own name", ShellToolCatalog.handles("shell_run_command"))
        check("and no other", !ShellToolCatalog.handles("calendar_list_events"))
        let parameters = tools.first?.parameters.objectValue
        check(
            "command is the one required field",
            parameters?["required"] == .array([.string("command")]))
        check(
            "directory is offered as an optional string",
            parameters?["properties"]?.objectValue?["directory"]?.objectValue?["type"]
                == .string("string"))
        check(
            "the row reads as the shell's Run Command",
            tools.first?.origin == "Shell" && tools.first?.title == "Run Command")
        check(
            "the description warns the user may decline",
            tools.first?.description.contains("may decline") == true)

        // MARK: Reading a call

        let home = "/Users/tester"
        let folders: Set<String> = [home, "/Users/tester/Projects", "/tmp"]
        typealias Reading = Result<ShellToolCatalog.Request, AIToolArguments.Invalid>
        func read(_ arguments: String) -> Reading {
            Result { () throws(AIToolArguments.Invalid) in
                try ShellToolCatalog.request(
                    arguments: arguments, homeDirectory: home, isDirectory: folders.contains)
            }
        }
        func accepted(_ arguments: String) -> ShellToolCatalog.Request? {
            try? read(arguments).get()
        }

        check(
            "a bare command runs in the home folder",
            accepted(#"{"command":"ls -la"}"#)
                == ShellToolCatalog.Request(command: "ls -la", directory: home))
        check(
            "~ expands to the home folder",
            accepted(#"{"command":"ls","directory":"~"}"#)?.directory == home)
        check(
            "~/ expands inside the home folder",
            accepted(#"{"command":"ls","directory":"~/Projects"}"#)?.directory
                == "/Users/tester/Projects")
        check(
            "a relative folder is taken from home",
            accepted(#"{"command":"ls","directory":"Projects"}"#)?.directory
                == "/Users/tester/Projects")
        check(
            "an absolute folder is kept",
            accepted(#"{"command":"ls","directory":"/tmp"}"#)?.directory == "/tmp")
        check(
            "a blank directory reads as none",
            accepted(#"{"command":"ls","directory":"  "}"#)?.directory == home)
        check(
            "a missing command is refused with a sentence",
            read(#"{"directory":"/tmp"}"#).failure?.message.contains("command") == true)
        check(
            "a blank command is refused",
            read(#"{"command":"   "}"#).failure != nil)
        check(
            "a folder that is not there is refused, naming it",
            read(#"{"command":"ls","directory":"~/Nowhere"}"#).failure?.message
                .contains("~/Nowhere") == true)
        check("arguments that are not JSON are refused", read("ls").failure != nil)

        // MARK: Confirmation text

        let summary = ShellToolCatalog.summary(
            of: .init(command: "rm -rf build", directory: "/Users/tester/Projects"),
            homeDirectory: home)
        check(
            "the confirmation shows the command verbatim, then where",
            summary == "rm -rf build\n\nIn ~/Projects")
        check(
            "a folder outside home is shown whole",
            ShellToolCatalog.abbreviated("/tmp", homeDirectory: home) == "/tmp")
        check(
            "a sibling of home is not abbreviated",
            ShellToolCatalog.abbreviated("/Users/testerX", homeDirectory: home) == "/Users/testerX")

        // MARK: Answers

        let ok = ShellToolCatalog.Outcome(
            ending: .exited(0), standardOutput: .init(text: "hi", omittedBytes: 0))
        check(
            "an answer gives status, output and errors",
            ShellToolCatalog.answer(ok) == "Exit status: 0\nstdout:\nhi\nstderr: (empty)")
        check("exit 0 is not an error", !ShellToolCatalog.result(ok, callID: "a").isError)
        let failed = ShellToolCatalog.Outcome(
            ending: .exited(3), standardError: .init(text: "nope", omittedBytes: 0))
        check(
            "a non-zero exit is reported with its errors",
            ShellToolCatalog.answer(failed) == "Exit status: 3\nstdout: (empty)\nstderr:\nnope")
        check("and marked as an error", ShellToolCatalog.result(failed, callID: "a").isError)
        let clipped = ShellToolCatalog.Outcome(
            ending: .exited(0), standardOutput: .init(text: "abc", omittedBytes: 42))
        check(
            "a clipped stream says how much was cut",
            ShellToolCatalog.answer(clipped).contains("abc\n[42 more bytes cut]"))
        check(
            "a timeout says so",
            ShellToolCatalog.answer(.init(ending: .timedOut(seconds: 60)))
                .hasPrefix("Stopped after 60 seconds without finishing"))
        check(
            "a launch failure is one sentence",
            ShellToolCatalog.answer(.init(ending: .failedToStart("no shell")))
                == "The command could not be started: no shell")

        let umlaut = Array("aä".utf8)
        let cut = ShellToolCatalog.output(head: Array(umlaut.prefix(2)), totalBytes: umlaut.count)
        check(
            "a scalar split by the cut is dropped and counted",
            cut == ShellToolCatalog.Output(text: "a", omittedBytes: 2))
        check(
            "trailing newlines are dropped",
            ShellToolCatalog.output(head: Array("hi\n\n".utf8), totalBytes: 4).text == "hi")

        // MARK: Runner

        // The kernel's spelling: `resolvingSymlinksInPath` drops `/private`, which `pwd -P` keeps.
        let tmp = realpath(zdotdir.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        } ?? zdotdir.path
        func run(
            _ command: String, in directory: String = tmp, timeout: Duration = .seconds(10),
            limit: Int = ShellToolCatalog.outputLimit
        ) async -> ShellToolCatalog.Outcome {
            await ShellToolRunner.run(
                .init(command: command, directory: directory), timeout: timeout,
                outputLimit: limit, shell: "/bin/zsh")
        }

        let echo = await run("echo hi")
        check("echo exits 0", echo.ending == .exited(0))
        check("and its output is captured", echo.standardOutput.text == "hi")
        check("with nothing on stderr", echo.standardError == .empty)

        let failing = await run("echo oops >&2; exit 7")
        check("a non-zero exit is kept", failing.ending == .exited(7))
        check("stderr is captured apart", failing.standardError.text == "oops")

        let here = await run("pwd -P")
        check("the command runs in the folder asked for", here.standardOutput.text == tmp)

        let input = await run("cat; echo done")
        check("stdin is empty, so a read never hangs", input.standardOutput.text == "done")

        let started = ContinuousClock.now
        let slow = await run("sleep 30", timeout: .seconds(1))
        check("a command past its time is stopped", slow.ending == .timedOut(seconds: 1))
        check("promptly", ContinuousClock.now - started < .seconds(5))

        let flooding = await run("yes | head -c 100000", limit: 1000)
        check(
            "a large output keeps only the limit", flooding.standardOutput.text.utf8.count <= 1000)
        check(
            "and counts what it cut",
            flooding.standardOutput.omittedBytes == 100000 - 1000)

        let backgrounded = ContinuousClock.now
        let detached = await run("sleep 20 & echo started")
        check("a background job does not hold the answer", detached.ending == .exited(0))
        check("and the shell's own output arrives", detached.standardOutput.text == "started")
        check("without waiting on the job", ContinuousClock.now - backgrounded < .seconds(5))

        let missing = await ShellToolRunner.run(
            .init(command: "true", directory: tmp), shell: "/nonexistent/shell")
        if case .failedToStart = missing.ending {
            check("a shell that cannot start is reported", true)
        } else {
            check("a shell that cannot start is reported", false)
        }

        check(
            "the login shell is $SHELL when it names a program",
            ShellToolRunner.loginShell(environment: ["SHELL": "/bin/sh"]) == "/bin/sh")
        check(
            "and something runnable otherwise",
            FileManager.default.isExecutableFile(
                atPath: ShellToolRunner.loginShell(environment: ["SHELL": "/no/such/shell"])))

        exit(failures == 0 ? 0 : 1)
    }
}

extension Result {
    fileprivate var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
