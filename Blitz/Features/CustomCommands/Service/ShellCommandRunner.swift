import Darwin
import Foundation
import Synchronization

/// How a run ended. `launchFailed` means the shell never started, so nothing was captured.
enum ShellCommandTermination: Sendable, Equatable {
    case exited(status: Int32)
    case launchFailed(String)
    /// Apart from the status, which an interrupted command reports as 130.
    case stopped

    /// A signal death reports the signal as its status, so it fails here like any non-zero exit.
    var succeeded: Bool { self == .exited(status: 0) }
}

enum ShellCommandEvent: Sendable {
    case output(String)
    /// One command line has finished; the folder is where the next one starts.
    case finished(ShellCommandResult, directory: String?)
    /// The shell itself has gone, so the session runs nothing more.
    case ended
}

/// A shell kept open between commands, so a `cd`, an export or a prompt's answer carries over.
struct ShellCommandSession: Sendable {
    let events: AsyncStream<ShellCommandEvent>
    /// Starts one command line; the caller waits for its `finished` before sending another.
    let run: @Sendable (String) -> Void
    /// Text for whatever the running command reads from standard input.
    let type: @Sendable (String) -> Void
    /// ⌃C for the running command; one that will not stop takes the session down with it.
    let stop: @Sendable () -> Void
    /// Not the stream's cancellation: the shell leaves once its current command is done.
    let end: @Sendable () -> Void
}

/// Both tails are filled only by the non-streaming path; a streamed run reports events.
struct ShellCommandResult: Sendable, Equatable {
    let termination: ShellCommandTermination
    /// Kept short: all it feeds is the one-line report a finished command shows.
    let standardOutput: String?
    let standardError: String?

    var succeeded: Bool { termination.succeeded }

    /// What a command said about itself, for a report with room for one line.
    var lastOutputLine: String? {
        standardOutput?
            .split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    init(
        termination: ShellCommandTermination, standardOutput: String? = nil,
        standardError: String? = nil
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

enum ShellCommandRunner {
    /// Only ever surfaces on failure, where the last few lines are the whole story.
    private static let standardErrorLimit = 8 * 1024
    /// Only the last line is ever shown, so this is a generous bound on one of them.
    private static let standardOutputLimit = 4 * 1024
    private static let shell = "/bin/zsh"
    /// Big enough that a chatty command needs few reads, small enough to stay live.
    private static let readSize = 16 * 1024
    /// Coalesces bursts so a flood cannot drive a redraw per line.
    private static let flushInterval: Duration = .milliseconds(40)
    /// A prompt or a progress bar never ends a line; past this it is shown anyway.
    private static let unlinedLimit = 4 * 1024
    /// How long a stopped command is given to leave politely before it is killed.
    private static let stopGrace: DispatchTimeInterval = .seconds(2)
    /// The private OSC number the shell marks a finished line with, nonce first.
    private static let markerCode = 6973
    /// The exit wait blocks, so it stays off the cooperative pool; concurrent, not serial.
    private static let queue = DispatchQueue(
        label: "de.fa-krug.blitz.shell-command", qos: .userInitiated, attributes: .concurrent)

    /// Fire-and-forget, keeping only the error tail; shown output goes through `stream`.
    nonisolated static func run(
        _ command: String, arguments: [String] = [], loadingShellEnvironment: Bool = false,
        workingDirectory: String? = nil
    ) async -> ShellCommandResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: execute(
                        command, arguments: arguments,
                        loadingShellEnvironment: loadingShellEnvironment,
                        workingDirectory: workingDirectory))
            }
        }
    }

    nonisolated private static func execute(
        _ command: String, arguments: [String], loadingShellEnvironment: Bool,
        workingDirectory: String?
    ) -> ShellCommandResult {
        guard let directory = resolvedWorkingDirectory(workingDirectory) else {
            return ShellCommandResult(termination: .launchFailed(missingDirectory(workingDirectory)))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellArguments(
            command: command, arguments: arguments,
            loadingShellEnvironment: loadingShellEnvironment)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // Lets a shell config skip slow sections when Blitz is the caller.
        process.environment = ProcessInfo.processInfo.environment.merging(["BLITZ": "1"]) { _, new in
            new
        }
        // Load-bearing: a config that prompts reads EOF and moves on, never hanging.
        process.standardInput = FileHandle.nullDevice

        let output = StreamCapture.make()
        let errors = StreamCapture.make()
        process.standardOutput = output?.handle ?? FileHandle.nullDevice
        process.standardError = errors?.handle ?? FileHandle.nullDevice
        defer {
            output?.remove()
            errors?.remove()
        }

        do {
            try process.runObservingExit().wait()
        } catch {
            return ShellCommandResult(termination: .launchFailed(error.localizedDescription))
        }

        return ShellCommandResult(
            termination: .exited(status: process.terminationStatus),
            standardOutput: output?.readSuffix(limit: standardOutputLimit),
            standardError: errors?.readSuffix(limit: standardErrorLimit))
    }

    // MARK: - Sessions

    /// Runs under a pseudo-terminal; see `PseudoTerminal` for why a pipe cannot do this.
    nonisolated static func openSession(
        arguments: [String] = [], loadingShellEnvironment: Bool = false,
        workingDirectory: String? = nil
    ) -> ShellCommandSession {
        var environment = ProcessInfo.processInfo.environment
        environment["BLITZ"] = "1"
        // A terminal makes tools colour output, so ask for colour the window can draw.
        environment["TERM"] = "xterm-256color"

        let nonce = UUID().uuidString
        let directory = resolvedWorkingDirectory(workingDirectory)
        let terminal = directory.flatMap {
            PseudoTerminal.spawn(
                executable: shell,
                arguments: shellArguments(
                    command: sessionScript(nonce: nonce), arguments: arguments,
                    loadingShellEnvironment: loadingShellEnvironment),
                environment: environment, workingDirectory: $0)
        }

        guard let terminal else {
            let reason =
                directory == nil
                ? missingDirectory(workingDirectory) : "The shell could not be started."
            return ShellCommandSession(
                events: AsyncStream { continuation in
                    continuation.yield(
                        .finished(
                            ShellCommandResult(termination: .launchFailed(reason)), directory: nil))
                    continuation.yield(.ended)
                    continuation.finish()
                },
                run: { _ in }, type: { _ in }, stop: {}, end: {})
        }

        let state = SessionState()
        let marker = Array("\u{1B}]\(markerCode);\(nonce);".utf8)
        let events = AsyncStream<ShellCommandEvent> { continuation in
            queue.async {
                drain(terminal, marker: marker, state: state, into: continuation)
            }
        }
        return ShellCommandSession(
            events: events,
            run: { line in
                state.begin()
                // The shell reads up to a NUL, so one inside the line would split it in two.
                terminal.sendControl(Array(line.utf8).filter { $0 != 0 } + [0])
            },
            type: { terminal.type(Array($0.utf8)) },
            stop: {
                guard let generation = state.requestStop() else { return }
                terminal.signalSession(SIGINT)
                // The backstop, for a command that ignores a polite ask.
                queue.asyncAfter(deadline: .now() + stopGrace) {
                    if state.isRunning(generation) { terminal.signalSession(SIGKILL) }
                }
            },
            end: { terminal.closeControl() })
    }

    /// Reads NUL-ended lines from the control descriptor; ⌃C ends a line but never the loop.
    nonisolated private static func sessionScript(nonce: String) -> String {
        let control = PseudoTerminal.controlDescriptor
        // Job control gives each command its own group, out of reach of the session's signal.
        return """
            builtin unsetopt monitor
            TRAPINT() { __blitz_interrupted=1; return $(( 128 + $1 )) }
            __blitz_next() {
              { IFS= builtin read -r -d '' -u \(control) __blitz_line } \\
                always { TRY_BLOCK_INTERRUPT=0 }
            }
            __blitz_run() {
              { builtin eval "$__blitz_line" \(control)<&- } always { TRY_BLOCK_INTERRUPT=0 }
            }
            while :; do
              __blitz_interrupted= __blitz_line=
              __blitz_next
              __blitz_read=$?
              [[ -n $__blitz_interrupted ]] && continue
              (( __blitz_read == 0 )) || break
              __blitz_run "$@"
              builtin printf '\\e]\(markerCode);\(nonce);%d;%s\\a' $? "$PWD"
            done
            """
    }

    /// One queue, one reader: the decode buffer is touched from here alone, so it needs no lock.
    nonisolated private static func drain(
        _ terminal: PseudoTerminal, marker: [UInt8], state: SessionState,
        into continuation: AsyncStream<ShellCommandEvent>.Continuation
    ) {
        var scanner = LineEndScanner(marker: marker)
        var decoder = TerminalTextDecoder()
        var buffer = [UInt8](repeating: 0, count: readSize)
        var lastYield = ContinuousClock().now

        func flush(force: Bool) {
            guard let text = decoder.take(force: force) else { return }
            continuation.yield(.output(text))
            lastYield = ContinuousClock().now
        }

        while true {
            // A prompt never ends its line, so a pause in the output is what shows it.
            if decoder.isHolding, !terminal.awaitOutput(timeout: flushInterval) {
                flush(force: true)
                continue
            }
            // Zero is EOF; -1 with EIO is what a pty master returns once its child is gone.
            let count = read(terminal.parentEnd, &buffer, readSize)
            guard count > 0 else { break }
            for piece in scanner.scan(buffer[0..<count]) {
                switch piece {
                case .text(let bytes):
                    decoder.append(bytes)
                case .lineEnd(let status, let directory):
                    flush(force: true)
                    let termination: ShellCommandTermination =
                        state.finish() ? .stopped : .exited(status: status)
                    continuation.yield(
                        .finished(
                            ShellCommandResult(termination: termination), directory: directory))
                }
            }
            flush(force: ContinuousClock().now - lastYield >= flushInterval)
        }
        decoder.append(scanner.remainder)
        flush(force: true)

        let status = terminal.wait()
        terminal.close()
        // A shell that dies mid-line never marks its end, so the line is reported here instead.
        if state.isRunning {
            let termination: ShellCommandTermination =
                state.finish() ? .stopped : .exited(status: status)
            continuation.yield(
                .finished(ShellCommandResult(termination: termination), directory: nil))
        }
        continuation.yield(.ended)
        continuation.finish()
    }

    /// Written from the main actor and read on the drain queue, so it carries its own lock.
    private final class SessionState: Sendable {
        private struct Phase {
            /// Which line a delayed kill was meant for, so it can never land on the next one.
            var generation = 0
            var isRunning = false
            var isStopping = false
        }

        private let phase = Mutex(Phase())

        var isRunning: Bool { phase.withLock { $0.isRunning } }

        func begin() {
            phase.withLock {
                $0.generation += 1
                $0.isRunning = true
                $0.isStopping = false
            }
        }

        /// The line to stop, or nil when none is running and a signal would reach the shell.
        func requestStop() -> Int? {
            phase.withLock { current -> Int? in
                guard current.isRunning else { return nil }
                current.isStopping = true
                return current.generation
            }
        }

        func isRunning(_ generation: Int) -> Bool {
            phase.withLock { $0.isRunning && $0.generation == generation }
        }

        /// Whether the line that just ended was stopped.
        func finish() -> Bool {
            phase.withLock { current -> Bool in
                current.isRunning = false
                return current.isStopping
            }
        }
    }

    /// Splits the shell's end-of-line markers out of the output they arrive inside.
    private struct LineEndScanner {
        enum Piece {
            case text([UInt8])
            case lineEnd(status: Int32, directory: String)
        }

        let marker: [UInt8]
        private var held: [UInt8] = []

        init(marker: [UInt8]) {
            self.marker = marker
        }

        /// Bytes kept back as a possible marker that never finished.
        var remainder: [UInt8] { held }

        mutating func scan(_ bytes: ArraySlice<UInt8>) -> [Piece] {
            held.append(contentsOf: bytes)
            var pieces: [Piece] = []
            while let start = held.firstRange(of: marker)?.lowerBound {
                if start > 0 { pieces.append(.text(Array(held[..<start]))) }
                let bodyStart = start + marker.count
                guard let bell = held[bodyStart...].firstIndex(of: 0x07) else {
                    held.removeFirst(start)
                    return pieces
                }
                pieces.append(Self.lineEnd(held[bodyStart..<bell]))
                held.removeFirst(bell + 1)
            }
            // A marker split across reads keeps its opening bytes back until the rest arrives.
            let kept = partialMarkerLength()
            if held.count > kept { pieces.append(.text(Array(held.dropLast(kept)))) }
            held = Array(held.suffix(kept))
            return pieces
        }

        private func partialMarkerLength() -> Int {
            var length = min(held.count, marker.count - 1)
            while length > 0, !held.suffix(length).elementsEqual(marker.prefix(length)) {
                length -= 1
            }
            return length
        }

        /// The body is `status;folder`, and only the status can never hold a semicolon.
        private static func lineEnd(_ body: ArraySlice<UInt8>) -> Piece {
            let separator = body.firstIndex(of: UInt8(ascii: ";")) ?? body.endIndex
            let status = Int32(String(decoding: body[..<separator], as: UTF8.self)) ?? 1
            let directory = String(decoding: body[separator...].dropFirst(), as: UTF8.self)
            return .lineEnd(status: status, directory: directory)
        }
    }

    /// Whole lines only: a newline is a scalar boundary, so no read decodes mid-character.
    private struct TerminalTextDecoder {
        private var pending: [UInt8] = []

        var isHolding: Bool { !pending.isEmpty }

        mutating func append(_ bytes: [UInt8]) {
            pending.append(contentsOf: bytes)
        }

        /// `force` flushes at exit and for a prompt that never ends a line, still on a boundary.
        mutating func take(force: Bool) -> String? {
            guard !pending.isEmpty else { return nil }
            var end = pending.lastIndex(of: 0x0A).map { $0 + 1 }
            if end == nil {
                guard force || pending.count >= unlinedLimit else { return nil }
                end = scalarBoundary(before: pending.count)
            }
            guard let end, end > 0 else { return nil }
            // Latin-1 cannot fail, so other encodings still reach the reader.
            let bytes = Array(pending[0..<end])
            pending.removeFirst(end)
            return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        }

        /// Walks back over at most three continuation bytes to the start of a whole character.
        private func scalarBoundary(before index: Int) -> Int {
            var boundary = index
            var stepped = 0
            while boundary > 0, stepped < 4, pending[boundary - 1] & 0xC0 == 0x80 {
                boundary -= 1
                stepped += 1
            }
            // A lead byte only holds back when its own sequence is still incomplete.
            guard boundary > 0 else { return index }
            let lead = pending[boundary - 1]
            let width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            return index - boundary + 1 >= width ? index : boundary - 1
        }
    }

    /// Nil when the named directory is gone: running somewhere unexpected is worse than not.
    nonisolated private static func resolvedWorkingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return expanded
    }

    nonisolated private static func missingDirectory(_ path: String?) -> String {
        "The folder “\(path ?? "")” no longer exists."
    }

    /// Values follow as `$1`, `$2`, never spliced where zsh would re-parse them as syntax.
    nonisolated private static func shellArguments(
        command: String, arguments: [String], loadingShellEnvironment: Bool
    ) -> [String] {
        // zsh reads `.zshrc` only for interactive shells, so `-l` alone sees no aliases.
        [loadingShellEnvironment ? "-ilc" : "-lc", command, "blitz"] + arguments
    }

    /// A temp file, not a `Pipe`: nothing drains a pipe until the command exits.
    private final class StreamCapture: @unchecked Sendable {
        let url: URL
        let handle: FileHandle

        init(url: URL, handle: FileHandle) {
            self.url = url
            self.handle = handle
        }

        func readSuffix(limit: Int) -> String? {
            try? handle.synchronize()
            guard let end = try? handle.seekToEnd() else { return nil }
            let start = end > UInt64(limit) ? end - UInt64(limit) : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
            // A byte-offset tail can open mid-scalar; dropping the orphans avoids a leading U+FFFD.
            let body = start > 0 ? data.drop { $0 & 0xC0 == 0x80 } : data[...]
            return String(decoding: body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        func remove() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        static func make() -> StreamCapture? {
            let template = FileManager.default.temporaryDirectory
                .appendingPathComponent("blitz-command-stream.XXXXXX").path
            var bytes = Array(template.utf8CString)
            let descriptor = bytes.withUnsafeMutableBufferPointer { buffer in
                mkstemp(buffer.baseAddress!)
            }
            guard descriptor >= 0 else { return nil }
            let path = String(
                decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return StreamCapture(
                url: URL(fileURLWithPath: path),
                handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A shell in the user's own terminal, for what a log cannot draw: `vim`, `htop`, `ssh`.
enum TerminalHandoff {
    /// Removes itself first, then leaves a login shell open in the folder once the command is done.
    static func script(
        directory: String, command: String?, arguments: [String], loadingShellEnvironment: Bool
    ) -> String {
        var lines = ["#!/bin/zsh", "rm -f -- \"$0\"", "cd -- \(quoted(directory)) || exit"]
        if let command, !command.isEmpty {
            // The run contract, word for word: values stay positional, quoted, never spliced in.
            let flags = loadingShellEnvironment ? "-ilc" : "-lc"
            let words = [quoted(command), "blitz"] + arguments.map(quoted)
            lines.append("BLITZ=1 /bin/zsh \(flags) " + words.joined(separator: " "))
        }
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A `.command` file, which opens in Terminal unless the user picked another app for it.
    static func writeScript(
        directory: String, command: String?, arguments: [String], loadingShellEnvironment: Bool
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Blitz-\(UUID().uuidString).command")
        let contents = script(
            directory: directory, command: command, arguments: arguments,
            loadingShellEnvironment: loadingShellEnvironment)
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: Data(contents.utf8),
                attributes: [.posixPermissions: 0o700])
        else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Single quotes make every other character literal, so only a single quote needs escaping.
    static func quoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
