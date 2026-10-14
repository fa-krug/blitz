import Foundation

/// What a chat model may run in the user's shell, and how its calls and answers are spelled.
enum ShellToolCatalog {
    static let origin = "Shell"
    static let runCommandName = "shell_run_command"
    /// Per stream: a chatty command must flood neither the model's context nor Blitz's memory.
    static let outputLimit = 16 * 1024
    static let timeout: Duration = .seconds(60)

    private typealias Invalid = AIToolArguments.Invalid

    /// A call, already checked; `directory` is absolute and was a folder when the call was read.
    struct Request: Equatable, Sendable {
        let command: String
        let directory: String
    }

    /// One stream's first `outputLimit` bytes, and how many came after them.
    struct Output: Equatable, Sendable {
        let text: String
        let omittedBytes: Int

        static let empty = Output(text: "", omittedBytes: 0)
    }

    struct Outcome: Equatable, Sendable {
        enum Ending: Equatable, Sendable {
            case exited(Int32)
            case signalled(Int32)
            case timedOut(seconds: Int)
            /// The reply was stopped while the command ran, so it was killed with it.
            case stopped
            case failedToStart(String)
        }

        let ending: Ending
        var standardOutput = Output.empty
        var standardError = Output.empty

        var succeeded: Bool { ending == .exited(0) }
    }

    static func handles(_ name: String) -> Bool {
        name == runCommandName
    }

    static func tools() -> [AITool] {
        let seconds = Int(timeout.components.seconds)
        let run = AITool(
            name: runCommandName,
            description: "Run a command in the user's login shell on their Mac, as the user, and "
                + "read its exit status, output and errors. Blitz supplies this tool with the "
                + "user's permission; the user may be asked to confirm each command and may "
                + "decline. Prefer short, non-interactive commands: stdin is empty, a command "
                + "is stopped after \(seconds) seconds, and each stream is cut after "
                + "\(outputLimit / 1024) KB.",
            parameters: AIToolJSON.object(
                properties: [
                    "command": AIToolJSON.string("The shell command line to run."),
                    "directory": AIToolJSON.string(
                        "Optional folder to run it in, absolute or starting with ~. "
                            + "Default: the user's home folder.")
                ],
                required: ["command"]),
            origin: origin, title: "Run Command")
        return [run]
    }

    static func request(
        arguments: String, homeDirectory: String,
        isDirectory: (String) -> Bool = Self.isExistingDirectory
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        let command = try arguments.requiredString("command")
        guard let named = arguments.string("directory") else {
            return Request(command: command, directory: homeDirectory)
        }
        let directory = resolved(named, homeDirectory: homeDirectory)
        guard isDirectory(directory) else {
            throw Invalid("There is no folder at \u{201C}\(named)\u{201D} on this Mac.")
        }
        return Request(command: command, directory: directory)
    }

    /// A relative path is taken from the home folder, where a command runs when none is named.
    static func resolved(_ path: String, homeDirectory: String) -> String {
        let home = homeDirectory as NSString
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return path }
        return home.appendingPathComponent(path)
    }

    /// What the confirmation shows: the command verbatim, then where it would run.
    static func summary(of request: Request, homeDirectory: String) -> String {
        "\(request.command)\n\nIn \(abbreviated(request.directory, homeDirectory: homeDirectory))"
    }

    static func abbreviated(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory { return "~" }
        let prefix = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    /// `head` is what was kept of `totalBytes`; a scalar the cut split is dropped, not mangled.
    static func output(head: [UInt8], totalBytes: Int) -> Output {
        let kept = totalBytes > head.count ? droppingPartialScalar(head[...]) : head[...]
        var text = String(decoding: kept, as: UTF8.self)
        while text.last?.isNewline == true { text.removeLast() }
        return Output(text: text, omittedBytes: totalBytes - kept.count)
    }

    static func droppingPartialScalar(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let lead = bytes.suffix(4).lastIndex(where: { $0 & 0xC0 != 0x80 }) else {
            return bytes
        }
        let byte = bytes[lead]
        let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
        return bytes.distance(from: lead, to: bytes.endIndex) < length ? bytes[..<lead] : bytes
    }

    static func result(_ outcome: Outcome, callID: String) -> AIToolResult {
        AIToolResult(callID: callID, content: answer(outcome), isError: !outcome.succeeded)
    }

    static func answer(_ outcome: Outcome) -> String {
        let status: String
        switch outcome.ending {
        case .exited(let code): status = "Exit status: \(code)"
        case .signalled(let signal): status = "Ended by signal \(signal)"
        case .timedOut(let seconds): status = "Stopped after \(seconds) seconds without finishing"
        case .stopped: status = "Stopped before it finished"
        case .failedToStart(let reason): return "The command could not be started: \(reason)"
        }
        return [
            status, section("stdout", outcome.standardOutput),
            section("stderr", outcome.standardError)
        ].joined(separator: "\n")
    }

    private static func section(_ name: String, _ output: Output) -> String {
        guard !output.text.isEmpty || output.omittedBytes > 0 else { return "\(name): (empty)" }
        guard output.omittedBytes > 0 else { return "\(name):\n\(output.text)" }
        return "\(name):\n\(output.text)\n[\(output.omittedBytes) more bytes cut]"
    }

    static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
