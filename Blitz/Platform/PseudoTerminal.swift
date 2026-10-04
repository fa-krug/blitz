import Darwin
import Foundation

/// libc block-buffers a pipe, so a pty is what makes output live and correctly ordered.
final class PseudoTerminal: @unchecked Sendable {
    /// Where the child finds `controlEnd`'s pipe: beside the terminal, never its standard input.
    static let controlDescriptor: Int32 = 3

    /// Everything the command writes to any of its three descriptors arrives here.
    let parentEnd: Int32
    let processID: pid_t
    private let controlEnd: Int32
    /// A write blocks while nothing reads, so neither end may wait behind the other.
    private let typingQueue = DispatchQueue(label: "de.fa-krug.blitz.pty.typing")
    private let controlQueue = DispatchQueue(label: "de.fa-krug.blitz.pty.control")
    /// Each flag is touched only on its own end's queue, which is what makes this class Sendable.
    private var isTerminalOpen = true
    private var isControlOpen = true

    private init(parentEnd: Int32, controlEnd: Int32, processID: pid_t) {
        self.parentEnd = parentEnd
        self.controlEnd = controlEnd
        self.processID = processID
    }

    static func spawn(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String
    ) -> PseudoTerminal? {
        // POSIX names these the master and slave ends; these are the same two descriptors.
        var parentEnd: Int32 = 0
        var childEnd: Int32 = 0
        var settings = terminalSettings()
        guard openpty(&parentEnd, &childEnd, nil, &settings, nil) == 0 else { return nil }
        var control: [Int32] = [0, 0]
        guard pipe(&control) == 0 else {
            Darwin.close(parentEnd)
            Darwin.close(childEnd)
            return nil
        }
        // Blitz spawns other children, and one holding the pipe would keep the shell from its EOF.
        for descriptor in [parentEnd, control[1]] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        // A shell that has exited must fail the write, not raise SIGPIPE and take Blitz with it.
        _ = fcntl(control[1], F_SETNOSIGPIPE, 1)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // A worker thread blocks SIGINT, and zsh hands the mask it inherits to every command.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var catchableSignals = sigset_t()
        sigfillset(&catchableSignals)
        sigdelset(&catchableSignals, SIGKILL)
        sigdelset(&catchableSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &catchableSignals)
        // The child leads its session, so `kill(-pid)` reaches it all; only dup2 targets survive.
        let flags =
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        for descriptor in Int32(0)...Int32(2) {
            posix_spawn_file_actions_adddup2(&actions, childEnd, descriptor)
        }
        posix_spawn_file_actions_adddup2(&actions, control[0], controlDescriptor)

        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }

        var processID: pid_t = 0
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let status = posix_spawn(
            &processID, executable, &actions, &attributes, argv.pointers, envp.pointers)
        Darwin.close(childEnd)
        Darwin.close(control[0])
        guard status == 0, processID > 0 else {
            Darwin.close(parentEnd)
            Darwin.close(control[1])
            return nil
        }
        return PseudoTerminal(parentEnd: parentEnd, controlEnd: control[1], processID: processID)
    }

    /// What a keyboard would deliver to whatever is reading the terminal.
    func type(_ bytes: [UInt8]) {
        typingQueue.async { [self] in
            guard isTerminalOpen else { return }
            Self.writeAll(bytes, to: parentEnd)
        }
    }

    func sendControl(_ bytes: [UInt8]) {
        controlQueue.async { [self] in
            guard isControlOpen else { return }
            Self.writeAll(bytes, to: controlEnd)
        }
    }

    /// The child reads EOF on `controlDescriptor` once anything already sent has been read.
    func closeControl() {
        controlQueue.async { [self] in
            guard isControlOpen else { return }
            isControlOpen = false
            Darwin.close(controlEnd)
        }
    }

    /// Whether output is waiting within `timeout`; an error counts, so the read can report it.
    func awaitOutput(timeout: Duration) -> Bool {
        // `select` because `poll` has long refused character devices on macOS.
        guard parentEnd < FD_SETSIZE else { return true }
        var descriptors = fd_set()
        withUnsafeMutableBytes(of: &descriptors.fds_bits) { bits in
            let words = bits.bindMemory(to: Int32.self)
            words[Int(parentEnd) / 32] |= Int32(bitPattern: 1 << UInt32(parentEnd % 32))
        }
        let microseconds = timeout.components.attoseconds / 1_000_000_000_000
        var limit = timeval(
            tv_sec: Int(timeout.components.seconds), tv_usec: Int32(microseconds))
        return select(parentEnd + 1, &descriptors, nil, nil, &limit) != 0
    }

    /// Signals the session rather than the process — the negative pid is what reaches the children.
    func signalSession(_ signal: Int32) {
        guard processID > 0 else { return }
        kill(-processID, signal)
    }

    /// Blocks until the command exits. A signalled death reports the signal, the way a shell does.
    func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
        if status & 0x7F != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    /// Queued behind any pending typing, so no write can land on a descriptor number reused since.
    func close() {
        closeControl()
        typingQueue.async { [self] in
            isTerminalOpen = false
            Darwin.close(parentEnd)
        }
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Canonical for whole lines; echo on, so what is typed shows up unless a prompt hides it.
    private static func terminalSettings() -> termios {
        var settings = termios()
        cfmakeraw(&settings)
        settings.c_lflag = tcflag_t(ICANON | ISIG | ECHO)
        settings.c_oflag = tcflag_t(OPOST | ONLCR)
        // A zeroed `termios` makes NUL the end-of-file character, so ⌃D would arrive as text.
        withUnsafeMutableBytes(of: &settings.c_cc) { $0[Int(VEOF)] = 0x04 }
        return settings
    }
}

/// The argv/envp arrays must outlive `posix_spawn`, so this is a real allocation.
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
