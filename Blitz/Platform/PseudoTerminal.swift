import Darwin
import Foundation
import Synchronization

/// libc block-buffers a pipe, so a pty is what makes output live and correctly ordered.
final class PseudoTerminal: Sendable {
    /// Everything the command writes to any of its three descriptors arrives here.
    let parentEnd: Int32
    /// Leads the child's session and its first process group, so `-processID` names both.
    let processID: pid_t
    /// A write blocks while nothing reads, so it never waits on the caller's thread.
    private let typingQueue = DispatchQueue(label: "de.fa-krug.blitz.pty.typing")
    private let lifecycle: Mutex<Lifecycle>

    private struct Lifecycle {
        var isTerminalOpen = true
        /// Set once the child is reaped, after which its pid may name a stranger.
        var exitStatus: Int32?
    }

    private init(parentEnd: Int32, processID: pid_t) {
        self.parentEnd = parentEnd
        self.processID = processID
        lifecycle = Mutex(Lifecycle())
    }

    /// The child gets the terminal as its controlling one, which `posix_spawn` cannot give it.
    static func spawn(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String, columns: Int, rows: Int
    ) -> PseudoTerminal? {
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let paths = CStringArray([executable, workingDirectory])

        // A worker thread blocks or ignores signals, and both would survive the exec.
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        let descriptorLimit = getdtablesize()
        guard var settings = terminalDefaults() else { return nil }
        var size = windowSize(columns: columns, rows: rows)

        var parentEnd: Int32 = -1
        // The child must never run a deinit, which would call `free` after a threaded fork.
        let processID = withExtendedLifetime((argv, envp, paths)) { () -> pid_t in
            let (arguments, variables) = (argv.pointers, envp.pointers)
            let (path, directory) = (paths.pointers[0], paths.pointers[1])
            let processID = forkpty(&parentEnd, nil, &settings, &size)
            guard processID == 0 else { return processID }
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL && number != SIGSTOP { sigaction(number, &defaultAction, nil) }
                number += 1
            }
            sigprocmask(SIG_SETMASK, &noSignals, nil)
            var descriptor: Int32 = 3
            while descriptor < descriptorLimit {
                Darwin.close(descriptor)
                descriptor += 1
            }
            if chdir(directory) == 0 { execve(path, arguments, variables) }
            _exit(127)
        }
        guard processID > 0 else { return nil }
        // Blitz spawns other children, and one holding the master would keep the pty from closing.
        _ = fcntl(parentEnd, F_SETFD, FD_CLOEXEC)
        return PseudoTerminal(parentEnd: parentEnd, processID: processID)
    }

    /// What a keyboard would deliver to whatever is reading the terminal.
    func write(_ bytes: [UInt8]) {
        typingQueue.async { [self] in
            guard lifecycle.withLock({ $0.isTerminalOpen }) else { return }
            Self.writeAll(bytes, to: parentEnd)
        }
    }

    /// The kernel follows with SIGWINCH to the foreground group, which is what redraws a screen.
    func resize(columns: Int, rows: Int) {
        lifecycle.withLock { state in
            guard state.isTerminalOpen else { return }
            var size = Self.windowSize(columns: columns, rows: rows)
            _ = ioctl(parentEnd, TIOCSWINSZ, &size)
        }
    }

    /// The group the terminal's ⌃C would reach: the running job, or the shell when it is idle.
    var foregroundProcessGroup: pid_t? {
        lifecycle.withLock { foregroundGroup($0) }
    }

    /// What the terminal's own ⌃C does, sent without one having to be typed.
    func signalForeground(_ signal: Int32) {
        lifecycle.withLock { state in
            guard let group = foregroundGroup(state) else { return }
            kill(-group, signal)
        }
    }

    /// Like closing a terminal tab: the shell's group and the running job both get SIGHUP.
    func hangUp() {
        lifecycle.withLock { state in
            if state.exitStatus == nil { kill(-processID, SIGHUP) }
            if let group = foregroundGroup(state), group != processID { kill(-group, SIGHUP) }
        }
    }

    /// The backstop for a command that ignores ⌃C; the session leader lives on to report it.
    func killAllButLeader() {
        lifecycle.withLock { state in
            guard state.exitStatus == nil else { return }
            let groups = Set([processID, foregroundGroup(state)].compactMap(\.self))
            // A process forked between the listing and the kill only shows up on a later pass.
            for _ in 0..<3 {
                let victims = groups.flatMap(Self.members(of:)).filter { $0 != processID }
                guard !victims.isEmpty else { return }
                for victim in victims { kill(victim, SIGKILL) }
            }
        }
    }

    /// The working folder of the foreground group's leader, which is the shell while it is idle.
    func foregroundDirectory() -> String? {
        guard let group = foregroundProcessGroup else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(group, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        return path?.isEmpty == false ? path : nil
    }

    /// Blocks until the command exits. A signalled death reports the signal, the way a shell does.
    func wait() -> Int32 {
        if let status = lifecycle.withLock({ $0.exitStatus }) { return status }
        // Waiting without reaping keeps the pid ours, so no signal sent meanwhile hits a stranger.
        var info = siginfo_t()
        while waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
        return lifecycle.withLock { state in
            if let status = state.exitStatus { return status }
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
            let reported = status & 0x7F != 0 ? 128 + (status & 0x7F) : (status >> 8) & 0xFF
            state.exitStatus = reported
            return reported
        }
    }

    /// Queued behind any pending typing, so no write can land on a descriptor number reused since.
    func close() {
        typingQueue.async { [self] in
            lifecycle.withLock { state in
                guard state.isTerminalOpen else { return }
                state.isTerminalOpen = false
                Darwin.close(parentEnd)
            }
        }
    }

    private func foregroundGroup(_ state: Lifecycle) -> pid_t? {
        guard state.isTerminalOpen else { return nil }
        let group = tcgetpgrp(parentEnd)
        return group > 1 && group != getpgrp() ? group : nil
    }

    private static func members(of group: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listpgrppids(
            group, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return Array(buffer.prefix(Int(max(count, 0))))
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    private static func windowSize(columns: Int, rows: Int) -> winsize {
        winsize(
            ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(columns, 1)),
            ws_xpixel: 0, ws_ypixel: 0)
    }

    /// The kernel's own defaults, plus UTF-8 so a canonical backspace erases a whole character.
    private static func terminalDefaults() -> termios? {
        var parentEnd: Int32 = -1
        var childEnd: Int32 = -1
        guard openpty(&parentEnd, &childEnd, nil, nil, nil) == 0 else { return nil }
        defer {
            Darwin.close(parentEnd)
            Darwin.close(childEnd)
        }
        var settings = termios()
        guard tcgetattr(childEnd, &settings) == 0 else { return nil }
        settings.c_iflag |= tcflag_t(IUTF8)
        return settings
    }
}

/// The argv/envp arrays must outlive the spawn, so this is a real allocation.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointers = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() { pointers[index] = strdup(value) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
