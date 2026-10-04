import Foundation

/// How one command line ended, once it has.
struct CommandOutcome: Sendable {
    let summary: String
    /// The nudge for a failure the reader can fix, when the exit status names one.
    let hint: String?
    let succeeded: Bool
    let finishedAt: Date
}

/// One window's shell: the command it opened with and every line typed into it after.
struct CommandTranscript: Identifiable, Sendable {
    let id = UUID()
    /// Which custom command opened the window, so Run Again can open it afresh.
    let commandID: UUID
    let name: String
    let symbol: String
    /// Where the next line starts, following every `cd`.
    var directory: String
    var startedAt: Date
    /// Everything printed so far, for copying and for a redraw from scratch.
    var log = ""
    /// One step on means the view appends this rather than walking the whole log.
    var delta = ""
    var revision = 0
    /// Bumped when the head of `log` is dropped, which is the text view's cue to redraw whole.
    var generation = 0
    /// Bumped per line started, so a reader scrolled up is brought back to see it run.
    var lineCount = 0
    /// Nil while the current line is still running.
    var outcome: CommandOutcome?
    /// False once the shell has exited; only Run Again starts another.
    var isOpen = true

    var isRunning: Bool { isOpen && outcome == nil }

    mutating func record(_ text: String, keeping limit: Int) {
        log += text
        delta = text
        revision += 1
        if log.utf8.count > limit {
            log = String(log.suffix(limit / 2))
            // The delta no longer describes the change, so the view is told to redraw instead.
            generation += 1
        }
    }
}

/// One window, reused: a second run replaces what it shows and never cancels the first.
@MainActor
@Observable
final class CommandOutputPresenter {
    /// Past this the head is dropped: the tail is where a command says how it went.
    private static let logLimit = 256 * 1024

    private(set) var transcript: CommandTranscript?
    /// Lines typed into the window, oldest first, for ↑ to walk back through.
    private(set) var history: [String] = []

    @ObservationIgnored private var session: ShellCommandSession?
    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private let rerun: (UUID) -> Void
    @ObservationIgnored private let handOff: (_ directory: String, _ command: String?) -> Void
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private lazy var window = AppWindowController(
        title: "Command Output", contentSize: CommandOutputView.initialSize, resizable: true,
        autosaveName: "CommandOutputWindow", activation: activation, closesOnEscape: true,
        onClose: { [weak self] in self?.endSession() })

    init(
        activation: ActivationPolicy, rerun: @escaping (UUID) -> Void,
        handOff: @escaping (_ directory: String, _ command: String?) -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.activation = activation
        self.rerun = rerun
        self.handOff = handOff
        self.openSettings = openSettings
    }

    /// Opens the window on `session` running `commandText`; returns the id events report against.
    @discardableResult
    func begin(
        commandID: UUID, name: String, commandText: String, symbol: String, directory: String,
        session: ShellCommandSession
    ) -> UUID {
        // Superseded, not stopped: the old shell leaves once its own command is done.
        self.session?.end()
        self.session = session
        let transcript = CommandTranscript(
            commandID: commandID, name: name, symbol: symbol, directory: directory,
            startedAt: Date())
        self.transcript = transcript
        startLine(commandText)
        window.show { CommandOutputView(presenter: self) }
        return transcript.id
    }

    func append(_ text: String, to id: UUID) {
        guard var transcript, transcript.id == id else { return }
        transcript.record(text, keeping: Self.logLimit)
        self.transcript = transcript
    }

    func finish(_ outcome: CommandOutcome, directory: String?, for id: UUID) {
        guard var transcript, transcript.id == id else { return }
        transcript.outcome = outcome
        if let directory { transcript.directory = directory }
        self.transcript = transcript
    }

    /// The shell has exited, so the window keeps its log but takes no further line.
    func end(for id: UUID) {
        guard var transcript, transcript.id == id else { return }
        transcript.isOpen = false
        self.transcript = transcript
        session = nil
    }

    // MARK: - Actions the window offers

    /// What was typed: input while a line runs, the next line to run once it has finished.
    func submit(_ text: String) {
        guard let transcript, transcript.isOpen else { return }
        if transcript.isRunning {
            session?.type(text + "\n")
            return
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if history.last != line { history.append(line) }
        startLine(line)
    }

    /// ⌃D: a command reading its input is told there is no more.
    func sendEndOfInput() {
        guard transcript?.isRunning == true else { return }
        session?.type("\u{4}")
    }

    func stopRunning() {
        guard transcript?.isRunning == true else { return }
        session?.stop()
    }

    func runAgain() {
        guard let transcript, !transcript.isRunning else { return }
        rerun(transcript.commandID)
    }

    /// The folder, and `command` when one is typed, handed to the user's own terminal.
    func openInTerminal(running command: String) {
        guard let transcript else { return }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        handOff(transcript.directory, command.isEmpty ? nil : command)
    }

    func showCommandSettings() {
        openSettings()
    }

    /// Re-raise an open output window; false when none is up, so a reopen falls through.
    func focusExisting() -> Bool {
        window.focus()
    }

    // MARK: - Private

    private func startLine(_ line: String) {
        guard var transcript else { return }
        transcript.outcome = nil
        transcript.startedAt = Date()
        transcript.lineCount += 1
        transcript.record(Self.prompt(for: line, after: transcript.log), keeping: Self.logLimit)
        self.transcript = transcript
        session?.run(line)
    }

    /// Closing the window lets the shell go once its current line is done, never cutting it short.
    private func endSession() {
        session?.end()
        session = nil
    }

    /// Drawn through the log's own SGR handling, set off from the output above by a blank line.
    private static func prompt(for line: String, after log: String) -> String {
        let separator = log.isEmpty ? "" : log.unicodeScalars.last == "\n" ? "\n" : "\n\n"
        return separator + "\u{1B}[0;2m❯ \u{1B}[0;1m\(line)\u{1B}[0m\n"
    }
}
