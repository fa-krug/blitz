import AppKit

/// How the opening command ended, once it has.
struct CommandOutcome: Sendable {
    let summary: String
    /// The nudge for a failure the reader can fix, when the exit status names one.
    let hint: String?
    let succeeded: Bool
    let finishedAt: Date
}

/// One terminal window: the command it opened with, the shell left behind, and how the run went.
@MainActor
@Observable
final class CommandTerminalPresenter {
    static let initialSize = CGSize(width: 720, height: 460)
    /// Small enough to tuck beside an editor; the header and footer still fit.
    private static let minimumSize = CGSize(width: 440, height: 260)
    /// Held by one open window at a time, so simultaneous windows never fight over a frame.
    private static let autosaveName = "CommandTerminalWindow"
    /// A guess at the header and footer; the first layout resizes the terminal to the truth.
    private static let chromeHeight: CGFloat = 110

    let name: String
    let symbol: String
    let startedAt = Date()
    /// Where the foreground process sits, following every `cd`.
    private(set) var directory: String
    /// Nil while the opening command runs; the shell after it is the user's.
    private(set) var outcome: CommandOutcome?
    private(set) var isShellOpen = true

    @ObservationIgnored let terminalView: CommandTerminalEmulatorView
    @ObservationIgnored private let session: TerminalSession
    @ObservationIgnored private let describe: (ShellCommandResult) -> CommandOutcome
    @ObservationIgnored private let rerun: () -> Void
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private let onClose: (CommandTerminalPresenter) -> Void
    @ObservationIgnored private let cascadeAnchor: NSRect?
    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private lazy var window = AppWindowController(
        title: name, contentSize: Self.initialSize, minimumSize: Self.minimumSize, resizable: true,
        autosaveName: Self.autosaveName, cascadingFrom: cascadeAnchor, activation: activation,
        onClose: { [weak self] in self?.windowDidClose() })

    var isRunning: Bool { outcome == nil }

    init(
        command: CustomCommand, arguments: [String], cascadingFrom cascadeAnchor: NSRect?,
        activation: ActivationPolicy, describe: @escaping (ShellCommandResult) -> CommandOutcome,
        rerun: @escaping () -> Void, openSettings: @escaping () -> Void,
        onClose: @escaping (CommandTerminalPresenter) -> Void
    ) {
        name = command.name
        symbol = command.symbol
        directory = Self.startingDirectory(of: command)
        self.cascadeAnchor = cascadeAnchor
        self.activation = activation
        self.describe = describe
        self.rerun = rerun
        self.openSettings = openSettings
        self.onClose = onClose

        let size = Self.initialSize
        let view = CommandTerminalEmulatorView(
            frame: CGRect(
                x: 0, y: 0, width: size.width - 2 * Theme.Spacing.xxl,
                height: size.height - Self.chromeHeight))
        let grid = view.terminalDimensions
        let session = ShellCommandRunner.openTerminal(
            command: command.command, arguments: arguments,
            loadingShellEnvironment: command.loadsShellEnvironment,
            workingDirectory: command.workingDirectory, columns: grid.cols, rows: grid.rows)
        view.onInput = session.send
        view.onResize = session.resize
        terminalView = view
        self.session = session
    }

    /// Opens the window and starts drawing what the terminal prints.
    func show() {
        window.show { CommandTerminalView(presenter: self) }
        let events = session.events
        reader = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    /// Nil once closed; the next window cascades from it.
    var frame: NSRect? { window.frame }

    // MARK: - Actions the window offers

    func stop() {
        guard isRunning else { return }
        session.stop()
    }

    func runAgain() {
        guard !isRunning else { return }
        rerun()
    }

    func showCommandSettings() {
        openSettings()
    }

    /// Re-raise the window; false once it has closed.
    func focus() -> Bool {
        window.focus()
    }

    // MARK: - Private

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .output(let bytes):
            terminalView.feed(byteArray: bytes[...])
        case .commandFinished(let result):
            outcome = describe(result)
            // Nothing ran to say why, so the terminal says it the way a shell would.
            if case .launchFailed(let detail) = result.termination {
                terminalView.feed(text: detail + "\r\n")
            }
        case .directoryChanged(let path):
            directory = path
        case .ended:
            isShellOpen = false
        }
    }

    /// Like closing a terminal tab: everything in it is hung up at once.
    private func windowDidClose() {
        session.hangUp()
        reader?.cancel()
        onClose(self)
    }

    private static func startingDirectory(of command: CustomCommand) -> String {
        guard let folder = command.workingDirectory else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return (folder as NSString).expandingTildeInPath
    }
}
