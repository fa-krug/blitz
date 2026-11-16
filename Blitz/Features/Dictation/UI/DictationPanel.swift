import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the recording capsule shows; the capture writes levels, the coordinator the phase.
@MainActor
@Observable
final class DictationDisplayState {
    enum Phase {
        case listening
        case transcribing
    }

    var phase: Phase = .listening
    var levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
}

private struct DictationWaveform: View {
    let levels: [Float]
    let processing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Size.dictationWaveGap) {
            ForEach(levels.indices, id: \.self) { index in
                let emphasis =
                    processing
                    ? Double(levels[index])
                    : min(1, Double(min(index, levels.count - 1 - index)) / 3)
                let reach = processing ? Theme.Size.dictationProcessingHeight : Theme.Size.dictationWaveHeight
                Capsule()
                    .fill(Theme.Colors.textPrimary.opacity(0.4 + 0.6 * emphasis))
                    .frame(
                        width: Theme.Size.dictationWaveBar,
                        height: Theme.Size.dictationWaveBar + reach * CGFloat(levels[index]))
            }
        }
        .animation(.easeOut(duration: 0.06), value: levels)
    }
}

/// A bright band sweeping left to right while the recording is transcribed.
private struct DictationProcessingWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private static let period = 1.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let progress =
                timeline.date.timeIntervalSince(startedAt)
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            let bars = Double(DictationSpectrum.barCount)
            // Starts and ends off the edges, so the band enters and leaves rather than popping.
            let center = (reduceMotion ? 0.5 : progress) * (bars + 7) - 4
            DictationWaveform(
                levels: (0..<DictationSpectrum.barCount).map { index in
                    Float(max(0, 1 - abs(Double(index) - center) / 4))
                }, processing: true)
        }
    }
}

private struct DictationPanelView: View {
    let state: DictationDisplayState

    var body: some View {
        Group {
            switch state.phase {
            case .listening:
                DictationWaveform(levels: tapered(state.levels), processing: false)
                    .accessibilityLabel("Dictation listening")
            case .transcribing:
                DictationProcessingWave()
                    .accessibilityLabel("Transcribing dictation")
            }
        }
        .frame(width: Theme.Size.dictationPanel.width, height: Theme.Size.dictationPanel.height)
        .glassEffect(.regular, in: .capsule)
    }

    /// Fades only toward the ends, so the middle bars carry the voice without a fixed peak.
    private func tapered(_ levels: [Float]) -> [Float] {
        levels.enumerated().map { index, level in
            let edge = min(1, Float(min(index, levels.count - 1 - index)) / 4)
            let taper = edge * edge * (3 - 2 * edge)
            return level * (0.2 + 0.8 * taper)
        }
    }
}

/// Nonactivating, so the app being dictated into stays active; ↵ and ⎋ reach it as key window.
private final class DictationPanel: NSPanel {
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    init(content: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Theme.Size.dictationPanel),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                onAccept?()
                return
            case kVK_Escape:
                onCancel?()
                return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

/// Owns the capsule; built on each show and dropped on close, so nothing animates while hidden.
@MainActor
final class DictationPanelController {
    let state = DictationDisplayState()
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    private var panel: DictationPanel?

    /// A tenth of the way up the screen the pointer is on, clear of the Dock and most text.
    private static let heightFraction: CGFloat = 0.1

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let panel =
            panel ?? DictationPanel(content: NSHostingView(rootView: DictationPanelView(state: state)))
        panel.onAccept = { [weak self] in self?.onAccept?() }
        panel.onCancel = { [weak self] in self?.onCancel?() }
        self.panel = panel
        let size = Theme.Size.dictationPanel
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + frame.height * Self.heightFraction - size.height / 2))
        state.phase = .listening
        state.levels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
