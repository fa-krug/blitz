import Darwin
import Foundation
import Synchronization

/// Runs one command a chat model asked for in the login shell, bounded in time and in output.
enum ShellToolRunner {
    /// How long a terminated command is given to leave before its whole group is killed.
    private static let terminationGrace: Duration = .seconds(2)
    /// A background job can keep the pipes open after the shell exits; it is not waited for.
    private static let drainGrace: Duration = .milliseconds(500)
    private static let pollInterval: Duration = .milliseconds(20)
    private static let fallbackShell = "/bin/zsh"

    /// Never throws: whatever happened, the model reads it as the call's answer.
    nonisolated static func run(
        _ request: ShellToolCatalog.Request, timeout: Duration = ShellToolCatalog.timeout,
        outputLimit: Int = ShellToolCatalog.outputLimit, shell: String = loginShell()
    ) async -> ShellToolCatalog.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", request.command]
        process.currentDirectoryURL = URL(fileURLWithPath: request.directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        // Lets a shell config skip slow sections when Blitz is the caller.
        environment["BLITZ"] = "1"
        process.environment = environment
        // Load-bearing: a command or config that prompts reads EOF and moves on, never hanging.
        process.standardInput = FileHandle.nullDevice
        let output = StreamCapture(limit: outputLimit)
        let errors = StreamCapture(limit: outputLimit)
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        do {
            try process.run()
        } catch {
            _ = output.finish()
            _ = errors.finish()
            return ShellToolCatalog.Outcome(ending: .failedToStart(error.localizedDescription))
        }

        let exited = await wait(upTo: timeout) { !process.isRunning }
        if !exited { await stop(process) }
        _ = await wait(upTo: drainGrace) { output.isFinished && errors.isFinished }
        let ending: ShellToolCatalog.Outcome.Ending
        if !exited {
            ending =
                Task.isCancelled ? .stopped : .timedOut(seconds: Int(timeout.components.seconds))
        } else if process.terminationReason == .uncaughtSignal {
            ending = .signalled(process.terminationStatus)
        } else {
            ending = .exited(process.terminationStatus)
        }
        return ShellToolCatalog.Outcome(
            ending: ending, standardOutput: output.finish(), standardError: errors.finish())
    }

    /// `$SHELL` where it names a program, else the account's shell, else zsh.
    nonisolated static func loginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let candidates = [environment["SHELL"], accountShell()].compactMap { $0 }
        return candidates.first {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        } ?? fallbackShell
    }

    nonisolated private static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    /// The child leads its own process group, so a signal to the group reaches its jobs too.
    nonisolated private static func stop(_ process: Process) async {
        let group = -process.processIdentifier
        kill(group, SIGTERM)
        guard await !wait(upTo: terminationGrace, until: { !process.isRunning }) else { return }
        kill(group, SIGKILL)
        _ = await wait(upTo: terminationGrace) { !process.isRunning }
    }

    /// False once `limit` passes, or at once in a cancelled task, which a stopped reply is.
    nonisolated private static func wait(
        upTo limit: Duration, until isDone: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !isDone() {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    /// Drained as it fills, so a chatty command never blocks; bytes past the limit are counted.
    private final class StreamCapture: Sendable {
        private struct Captured {
            var head: [UInt8] = []
            var totalBytes = 0
            var isFinished = false
        }

        let pipe = Pipe()
        private let limit: Int
        private let captured = Mutex(Captured())

        init(limit: Int) {
            self.limit = limit
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                captured.withLock { stream in
                    guard !data.isEmpty else {
                        stream.isFinished = true
                        return
                    }
                    let room = max(limit - stream.head.count, 0)
                    stream.head += data.prefix(room)
                    stream.totalBytes += data.count
                }
            }
        }

        var isFinished: Bool { captured.withLock(\.isFinished) }

        /// Stops reading, which also breaks the handler's hold on this capture.
        func finish() -> ShellToolCatalog.Output {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            return captured.withLock { stream in
                ShellToolCatalog.output(head: stream.head, totalBytes: stream.totalBytes)
            }
        }
    }
}
