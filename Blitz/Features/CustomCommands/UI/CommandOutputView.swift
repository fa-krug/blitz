import AppKit
import SwiftUI

/// One flat surface: the log is the page, separated by space and weight, not by rules.
struct CommandOutputView: View {
    let presenter: CommandOutputPresenter
    @State private var draft = ""
    /// Which `history` entry ↑ has reached; nil while a fresh line is being typed.
    @State private var recalled: Int?
    @FocusState private var inputFocused: Bool

    static let initialSize = CGSize(width: 720, height: 460)

    var body: some View {
        Group {
            if let transcript = presenter.transcript {
                VStack(alignment: .leading, spacing: 0) {
                    header(transcript)
                    TerminalLogView(transcript: transcript)
                    inputLine(transcript)
                    footer(transcript)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.terminalSurface)
        .onAppear { inputFocused = true }
    }

    // MARK: - Header

    private func header(_ transcript: CommandTranscript) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            SymbolImage(name: transcript.symbol, size: Self.headerGlyph)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(transcript.name)
                    .font(.headline)
                Text((transcript.directory as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Spacing.md)
            actions(transcript)
        }
        // Less on top: the transparent title bar already contributes its own height above this.
        .padding(.top, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    /// Stop while a line runs, Run Again once the shell has gone; between them the input line.
    private func actions(_ transcript: CommandTranscript) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            CopyLogButton(log: transcript.log)
            iconButton("apple.terminal", help: "Open in Terminal (⌘↵)") { openInTerminal() }
            if transcript.isRunning {
                iconButton("stop.fill", help: "Stop (⌃C)") { presenter.stopRunning() }
            } else if !transcript.isOpen {
                iconButton("arrow.clockwise", help: "Run Again") { presenter.runAgain() }
            }
        }
    }

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        BarButton(chrome: .rounded, action: action) {
            Image(systemName: symbol)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .tooltip(help)
    }

    // MARK: - Input

    private func inputLine(_ transcript: CommandTranscript) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(transcript.isRunning ? "›" : "❯")
                .foregroundStyle(Theme.Colors.textTertiary)
                .accessibilityHidden(true)
            TextField("", text: $draft, prompt: Text(Self.placeholder(transcript)))
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .disabled(!transcript.isOpen)
                .onSubmit(submit)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    openInTerminal()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard presenter.transcript?.isRunning == false else { return .ignored }
                    recall(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .onKeyPress(phases: .down, action: controlKey)
                .accessibilityLabel(Text(Self.placeholder(transcript)))
        }
        .font(Theme.Typography.code)
        .overlay(alignment: .topLeading) { hint(transcript) }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// ⌃C and ⌃D mean what they do in a terminal, but only while a line is running to receive them.
    private func controlKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.control), presenter.transcript?.isRunning == true else {
            return .ignored
        }
        switch press.characters {
        case "c", "\u{3}": presenter.stopRunning()
        case "d", "\u{4}": presenter.sendEndOfInput()
        default: return .ignored
        }
        return .handled
    }

    private static func placeholder(_ transcript: CommandTranscript) -> String {
        if !transcript.isOpen { return "The shell has exited" }
        return transcript.isRunning ? "Input for the running command" : "Run another command"
    }

    private func submit() {
        presenter.submit(draft)
        draft = ""
        recalled = nil
        // Return ends editing on macOS, and the next line is typed straight after this one.
        inputFocused = true
    }

    private func openInTerminal() {
        presenter.openInTerminal(running: draft)
        draft = ""
        recalled = nil
    }

    /// ↑ walks back through what was typed here, ↓ forward again to an empty line.
    private func recall(_ step: Int) {
        let history = presenter.history
        let next = (recalled ?? history.count) + step
        guard next >= 0 else { return }
        guard next < history.count else {
            recalled = nil
            draft = ""
            return
        }
        recalled = next
        draft = history[next]
    }

    // MARK: - Footer

    private func footer(_ transcript: CommandTranscript) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(statusTint(transcript))
                .frame(width: Self.statusDot, height: Self.statusDot)
            if let outcome = transcript.outcome {
                Text(outcome.summary)
                Text("·")
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(CommandDuration.text(from: transcript.startedAt, to: outcome.finishedAt))
            } else {
                Text("Running")
                Text("·")
                    .foregroundStyle(Theme.Colors.textTertiary)
                elapsed(from: transcript.startedAt)
            }
            Spacer(minLength: Theme.Spacing.md)
            if let outcome = transcript.outcome {
                Text(outcome.finishedAt, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    /// Ticks itself rather than being driven by a timer the window would have to own.
    private func elapsed(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(CommandDuration.text(from: start, to: context.date))
                .monospacedDigit()
        }
    }

    /// Sits above the input line rather than in it: the nudge is a sentence, and the bar is a line.
    @ViewBuilder
    private func hint(_ transcript: CommandTranscript) -> some View {
        if let hint = transcript.outcome?.hint {
            HStack(spacing: Theme.Spacing.sm) {
                Text(hint)
                Button("Open Settings") { presenter.showCommandSettings() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize()
            .alignmentGuide(.top) { $0[.bottom] + Theme.Spacing.md }
        }
    }

    private static let statusDot: CGFloat = 7
    private static let headerGlyph: CGFloat = 15

    private func statusTint(_ transcript: CommandTranscript) -> Color {
        guard let outcome = transcript.outcome else { return Theme.Colors.progress }
        return outcome.succeeded ? Theme.Colors.success : Theme.Colors.destructive
    }
}

/// Copies the whole log, then shows a checkmark long enough to be believed.
private struct CopyLogButton: View {
    let log: String
    @State private var copiedAt: Date?

    var body: some View {
        BarButton(chrome: .rounded) {
            Paster.copyPlainText(log)
            copiedAt = Date()
        } label: {
            Image(systemName: copiedAt == nil ? "square.on.square" : "checkmark")
                .font(Theme.Typography.bar)
                .foregroundStyle(copiedAt == nil ? Theme.Colors.textSecondary : Theme.Colors.success)
        }
        .tooltip("Copy Output")
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Theme.Duration.copyFeedback))
            copiedAt = nil
        }
    }
}

/// Elapsed time, in the one place a duration becomes text.
enum CommandDuration {
    static func text(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        let whole = Int(seconds)
        return "\(whole / 60)m \(whole % 60)s"
    }
}
