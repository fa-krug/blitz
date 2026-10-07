import AppKit
import SwiftUI

/// One flat surface: the terminal is the page, between its command's header and its status.
struct CommandTerminalView: View {
    let presenter: CommandTerminalPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TerminalHost(view: presenter.terminalView)
                .padding(.horizontal, Theme.Spacing.xxl)
            hint
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.terminalSurface)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            SymbolImage(name: presenter.symbol, size: Self.headerGlyph)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(presenter.name)
                    .font(.headline)
                Text((presenter.directory as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Spacing.md)
            if presenter.isRunning {
                iconButton("stop.fill", help: "Stop") { presenter.stop() }
            } else {
                iconButton("arrow.clockwise", help: "Run Again") { presenter.runAgain() }
            }
        }
        // Less on top: the transparent title bar already contributes its own height above this.
        .padding(.top, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        BarButton(chrome: .rounded, action: action) {
            Image(systemName: symbol)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .accessibilityLabel(help)
        .tooltip(help, alignment: .trailing, edge: .bottom)
    }

    // MARK: - Hint

    @ViewBuilder
    private var hint: some View {
        if let hint = presenter.outcome?.hint {
            HStack(spacing: Theme.Spacing.sm) {
                Text(hint)
                Button("Open Settings") { presenter.showCommandSettings() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.lg)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(statusTint)
                .frame(width: Self.statusDot, height: Self.statusDot)
                .accessibilityHidden(true)
            if let outcome = presenter.outcome {
                Text(outcome.summary)
                Text("·")
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(CommandDuration.text(from: presenter.startedAt, to: outcome.finishedAt))
                    .monospacedDigit()
            } else {
                Text("Running")
                Text("·")
                    .foregroundStyle(Theme.Colors.textTertiary)
                elapsed(from: presenter.startedAt)
            }
            Spacer(minLength: Theme.Spacing.md)
            if !presenter.isShellOpen {
                Text("Shell exited")
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    /// Ticks itself rather than being driven by a timer the presenter would have to own.
    private func elapsed(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(CommandDuration.text(from: start, to: context.date))
                .monospacedDigit()
        }
    }

    private static let statusDot: CGFloat = 7
    private static let headerGlyph: CGFloat = 15

    private var statusTint: Color {
        guard let outcome = presenter.outcome else { return Theme.Colors.progress }
        return outcome.succeeded ? Theme.Colors.success : Theme.Colors.destructive
    }
}

/// Hands SwiftUI the presenter's one emulator, so a re-render never builds a fresh terminal.
private struct TerminalHost: NSViewRepresentable {
    let view: CommandTerminalEmulatorView

    func makeNSView(context: Context) -> TerminalKeyView { TerminalKeyView(terminal: view) }

    func updateNSView(_ nsView: TerminalKeyView, context: Context) {}
}

/// SwiftTerm closes `performKeyEquivalent` to overrides, so a key it must not see is caught here.
private final class TerminalKeyView: NSView {
    init(terminal: NSView) {
        super.init(frame: terminal.frame)
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// No Blitz menu owns ⌘W, and Escape belongs to the terminal (vim), so ⌘W closes it here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, event.charactersIgnoringModifiers == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        window?.performClose(nil)
        return true
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
