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

/// What a terminal run reports; `ended` always comes last, and nothing follows it.
enum TerminalEvent: Sendable {
    /// Raw bytes for the emulator, the status marker already cut out.
    case output([UInt8])
    /// The opening command's outcome; the shell it leaves behind carries on.
    case commandFinished(ShellCommandResult)
    /// The folder of whatever runs in the foreground, reported only when it changes.
    case directoryChanged(String)
    case ended
}

/// A command run under its own terminal, which then stays open as the user's login shell.
struct TerminalSession: Sendable {
    let events: AsyncStream<TerminalEvent>
    /// Keyboard bytes; the terminal turns a ⌃C among them into SIGINT itself.
    let send: @Sendable ([UInt8]) -> Void
    let resize: @Sendable (_ columns: Int, _ rows: Int) -> Void
    /// Does nothing once the opening command has finished: the shell is the user's from then on.
    let stop: @Sendable () -> Void
    /// Closing a terminal tab: everything in it is hung up at once, unread output dropped.
    let hangUp: @Sendable () -> Void
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
    /// Undelivered output a terminal may hold; past it the command blocks, as in any terminal.
    static let pendingOutputLimit = 256 * 1024
    /// How often a terminal's folder is looked up; a `cd` shows its prompt well within it.
    private static let directoryInterval: Duration = .milliseconds(500)
    /// How long a stopped command is given to leave politely before it is killed.
    private static let stopGrace: DispatchTimeInterval = .seconds(2)
    /// The private OSC number the shell marks a finished line with, nonce first.
    private static let markerCode = 6973
    /// The exit wait blocks, so it stays off the cooperative pool; concurrent, not serial.
    private static let queue = DispatchQueue(
        label: "de.fa-krug.blitz.shell-command", qos: .userInitiated, attributes: .concurrent)

    /// Fire-and-forget, keeping only the error tail; shown output goes through `openTerminal`.
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

    // MARK: - Terminals

    /// The command's exit status arrives as a marker in the output; see `terminalScript`.
    nonisolated static func openTerminal(
        command: String, arguments: [String] = [], loadingShellEnvironment: Bool = false,
        workingDirectory: String? = nil, columns: Int = 80, rows: Int = 24
    ) -> TerminalSession {
        let nonce = UUID().uuidString
        let directory = resolvedWorkingDirectory(workingDirectory)
        let terminal = directory.flatMap {
            PseudoTerminal.spawn(
                executable: shell,
                arguments: [
                    "-fc",
                    terminalScript(nonce: nonce, loadingShellEnvironment: loadingShellEnvironment),
                    "blitz", command,
                ] + arguments,
                environment: terminalEnvironment(
                    inheriting: ProcessInfo.processInfo.environment, locale: .current),
                workingDirectory: $0, columns: columns, rows: rows)
        }

        guard let terminal else {
            let reason =
                directory == nil
                ? missingDirectory(workingDirectory) : "The shell could not be started."
            return TerminalSession(
                events: AsyncStream { continuation in
                    continuation.yield(
                        .commandFinished(ShellCommandResult(termination: .launchFailed(reason))))
                    continuation.yield(.ended)
                    continuation.finish()
                },
                send: { _ in }, resize: { _, _ in }, stop: {}, hangUp: {})
        }

        let state = TerminalState()
        let outbox = TerminalOutbox()
        let hangUp: @Sendable () -> Void = {
            outbox.discardOutput()
            terminal.hangUp()
        }
        queue.async {
            drain(terminal, nonce: nonce, directory: directory ?? "", state: state, into: outbox)
        }
        return TerminalSession(
            // A cancelled reader leaves nobody to show the shell, so it goes like a closed tab.
            events: AsyncStream(
                unfolding: { await outbox.next() },
                onCancel: {
                    outbox.abandon()
                    hangUp()
                }),
            send: { terminal.write($0) },
            resize: { terminal.resize(columns: $0, rows: $1) },
            stop: {
                guard state.requestStop() else { return }
                terminal.signalForeground(SIGINT)
                queue.asyncAfter(deadline: .now() + stopGrace) {
                    if state.isCommandRunning { terminal.killAllButLeader() }
                }
            },
            hangUp: hangUp)
    }

    /// `trap :` and not `trap ''`: a handler resets on exec, so ⌃C still reaches the command.
    nonisolated static func terminalScript(nonce: String, loadingShellEnvironment: Bool) -> String {
        // Without `+m` an interactive zsh takes the terminal's foreground and leaves it stopped.
        let flags = loadingShellEnvironment ? "-i +m -lc" : "-lc"
        return """
            __blitz_command=$1; shift
            trap : INT
            BLITZ=1 /bin/zsh \(flags) "$__blitz_command" blitz "$@"
            __blitz_status=$?
            trap - INT
            printf '\\e]\(markerCode);\(nonce);%d\\a' $__blitz_status
            exec "${SHELL:-/bin/zsh}" -l
            """
    }

    /// `BLITZ` is left for the script to set on the command alone, never on the user's shell.
    nonisolated static func terminalEnvironment(
        inheriting inherited: [String: String], locale: Locale
    ) -> [String: String] {
        var environment = inherited
        environment["BLITZ"] = nil
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // launchd gives an app no LANG, and zsh's line editor needs UTF-8 to draw an umlaut.
        if environment["LANG"] == nil { environment["LANG"] = utf8LocaleName(locale) }
        return environment
    }

    nonisolated private static func utf8LocaleName(_ locale: Locale) -> String {
        let fallback = "en_US.UTF-8"
        guard let language = locale.language.languageCode?.identifier,
            let region = locale.region?.identifier
        else { return fallback }
        let name = "\(language)_\(region).UTF-8"
        // English in Germany is a fine preference and no installed locale, which means ASCII.
        return FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") ? name : fallback
    }

    /// The one reader of the terminal, so the scanner needs no lock.
    nonisolated private static func drain(
        _ terminal: PseudoTerminal, nonce: String, directory: String, state: TerminalState,
        into outbox: TerminalOutbox
    ) {
        // The kernel's spelling, or the first lookup reports `/tmp` moving to `/private/tmp`.
        let resolved = realpath(directory, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        }
        state.report(directory: resolved ?? directory, into: outbox)
        // Never looked up at once: until its `chdir` the child still sits in Blitz's own folder.
        let watch = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: directoryInterval)
                if let directory = terminal.foregroundDirectory() {
                    state.report(directory: directory, into: outbox)
                }
            }
        }
        var scanner: ShellMarkerScanner? = ShellMarkerScanner(code: markerCode, nonce: nonce)
        var buffer = [UInt8](repeating: 0, count: readSize)

        func finishCommand(status: Int32) {
            guard let termination = state.finishCommand(status: status) else { return }
            outbox.post(.commandFinished(ShellCommandResult(termination: termination)))
        }

        while true {
            outbox.waitForRoom(readSize)
            let count = read(terminal.parentEnd, &buffer, readSize)
            if count < 0 && errno == EINTR { continue }
            // Zero is EOF; -1 with EIO is what a pty master returns once its child is gone.
            guard count > 0 else { break }
            guard var active = scanner else {
                outbox.post(.output(Array(buffer[0..<count])))
                continue
            }
            var text: [UInt8] = []
            for piece in active.scan(buffer[0..<count]) {
                switch piece {
                case .text(let bytes):
                    text += bytes
                case .marker(let body):
                    if !text.isEmpty { outbox.post(.output(text)) }
                    text = []
                    finishCommand(status: Int32(body) ?? 1)
                    scanner = nil
                }
            }
            // The marker comes once; what follows is the user's shell and passes straight through.
            if scanner == nil {
                text += active.remainder
            } else {
                scanner = active
            }
            if !text.isEmpty { outbox.post(.output(text)) }
        }
        if let remainder = scanner?.remainder, !remainder.isEmpty {
            outbox.post(.output(remainder))
        }

        watch.cancel()
        let status = terminal.wait()
        terminal.close()
        // A script killed before its marker, say by a hang-up, reports its own death instead.
        finishCommand(status: status)
        outbox.post(.ended)
    }

    /// Shared by the drain, the folder watch and the main actor, so it carries its own lock.
    private final class TerminalState: Sendable {
        private struct Phase {
            var isCommandRunning = true
            var isStopping = false
            var directory: String?
        }

        private let phase = Mutex(Phase())

        var isCommandRunning: Bool { phase.withLock { $0.isCommandRunning } }

        /// False once the command has finished, when a signal would reach the user's shell.
        func requestStop() -> Bool {
            phase.withLock { current -> Bool in
                guard current.isCommandRunning else { return false }
                current.isStopping = true
                return true
            }
        }

        /// Nil once the command has been reported, so it is reported exactly once.
        func finishCommand(status: Int32) -> ShellCommandTermination? {
            phase.withLock { current -> ShellCommandTermination? in
                guard current.isCommandRunning else { return nil }
                current.isCommandRunning = false
                return current.isStopping ? .stopped : .exited(status: status)
            }
        }

        func report(directory: String, into outbox: TerminalOutbox) {
            phase.withLock { current in
                guard current.directory != directory else { return }
                current.directory = directory
                outbox.post(.directoryChanged(directory))
            }
        }
    }

    /// Events not yet taken, output merged; the reader stops reading while too much of it waits.
    private final class TerminalOutbox: Sendable {
        private typealias Consumer = CheckedContinuation<TerminalEvent?, Never>

        private struct Mailbox {
            var events: [TerminalEvent] = []
            var pendingBytes = 0
            var isEnded = false
            /// Set by a hang-up: nobody is left to read output, so holding it only costs memory.
            var isDiscardingOutput = false
            var isAbandoned = false
            var isReaderWaiting = false
            var consumer: Consumer?

            /// Output joins output already waiting, so a slow consumer takes it in one piece.
            mutating func append(_ event: TerminalEvent) {
                guard case .output(let more) = event, case .output(var bytes)? = events.last else {
                    events.append(event)
                    return
                }
                events.removeLast()
                bytes += more
                events.append(.output(bytes))
            }

            /// True when the reader was waiting, for the caller to signal once the lock is let go.
            mutating func releaseReader() -> Bool {
                defer { isReaderWaiting = false }
                return isReaderWaiting
            }
        }

        private let mailbox = Mutex(Mailbox())
        /// The reader waits on its own thread, never on the cooperative pool.
        private let room = DispatchSemaphore(value: 0)

        /// Ignored after `ended`, so nothing can follow it.
        func post(_ event: TerminalEvent) {
            let consumer = mailbox.withLock { box -> Consumer? in
                guard !box.isEnded else { return nil }
                if case .ended = event { box.isEnded = true }
                if case .output = event, box.isDiscardingOutput { return nil }
                if let consumer = box.consumer {
                    box.consumer = nil
                    return consumer
                }
                if case .output(let bytes) = event { box.pendingBytes += bytes.count }
                box.append(event)
                return nil
            }
            consumer?.resume(returning: event)
        }

        /// All the output waiting, unless a status sits inside it; then up to the status.
        func next() async -> TerminalEvent? {
            await withCheckedContinuation { (consumer: Consumer) in
                let taken = mailbox.withLock { box -> (event: TerminalEvent?, wakeReader: Bool)? in
                    let isOver = box.isAbandoned || (box.events.isEmpty && box.isEnded)
                    if isOver { return (nil, false) }
                    guard !box.events.isEmpty else {
                        box.consumer = consumer
                        return nil
                    }
                    let event = box.events.removeFirst()
                    if case .output(let bytes) = event { box.pendingBytes -= bytes.count }
                    return (event, box.releaseReader())
                }
                guard let taken else { return }
                if taken.wakeReader { room.signal() }
                consumer.resume(returning: taken.event)
            }
        }

        /// Blocks the reader until `size` more bytes would still fit under the limit.
        func waitForRoom(_ size: Int) {
            while true {
                let isFull = mailbox.withLock { box -> Bool in
                    guard !box.isDiscardingOutput,
                        box.pendingBytes + size > ShellCommandRunner.pendingOutputLimit
                    else { return false }
                    box.isReaderWaiting = true
                    return true
                }
                guard isFull else { return }
                room.wait()
            }
        }

        func discardOutput() {
            let wakeReader = mailbox.withLock { box -> Bool in
                box.isDiscardingOutput = true
                box.events.removeAll { if case .output = $0 { true } else { false } }
                box.pendingBytes = 0
                return box.releaseReader()
            }
            if wakeReader { room.signal() }
        }

        /// The consumer has gone: a `next` still waiting returns nil, as does every later one.
        func abandon() {
            let consumer = mailbox.withLock { box -> Consumer? in
                box.isAbandoned = true
                defer { box.consumer = nil }
                return box.consumer
            }
            consumer?.resume(returning: nil)
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

/// Cuts a nonce-keyed OSC marker out of the output it arrives inside, wherever reads split it.
struct ShellMarkerScanner {
    enum Piece: Equatable {
        case text([UInt8])
        /// Whatever stood between the nonce and the bell.
        case marker(String)
    }

    let marker: [UInt8]
    private var held: [UInt8] = []

    init(code: Int, nonce: String) {
        marker = Array("\u{1B}]\(code);\(nonce);".utf8)
    }

    /// Bytes kept back as a possible marker that never finished.
    var remainder: [UInt8] { held }

    mutating func scan(_ bytes: some Sequence<UInt8>) -> [Piece] {
        held.append(contentsOf: bytes)
        var pieces: [Piece] = []
        while let start = held.firstRange(of: marker)?.lowerBound {
            if start > 0 { pieces.append(.text(Array(held[..<start]))) }
            let bodyStart = start + marker.count
            guard let bell = held[bodyStart...].firstIndex(of: 0x07) else {
                held.removeFirst(start)
                return pieces
            }
            pieces.append(.marker(String(bytes: held[bodyStart..<bell], encoding: .utf8) ?? ""))
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
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
