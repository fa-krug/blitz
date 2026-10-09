import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm's emulator dressed for a Blitz window; held by its owner so SwiftUI never rebuilds it.
final class CommandTerminalEmulatorView: TerminalView, TerminalViewDelegate {
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
    private var hasTakenFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        terminalDelegate = self
        // German layouts type @ | { } [ ] with Option, so it has to reach the keyboard layout.
        optionAsMetaKey = false
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The window moves by its background, which would otherwise swallow a selection drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasTakenFocus else { return }
        hasTakenFocus = true
        window.makeFirstResponder(self)
    }

    /// SwiftTerm keeps resolved colours, so a dynamic one would stay in the old appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Colours

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.isDark
            let surface = Self.resolved(NSColor(Theme.Colors.terminalSurface))
            nativeForegroundColor = Self.resolved(.textColor)
            // Clear so the window's surface shows through; reverse video swaps to it, opaque.
            nativeBackgroundColor = surface.withAlphaComponent(0)
            caretTextColor = surface
            selectedTextBackgroundColor = Self.resolved(.selectedTextBackgroundColor)
            selectedTextForegroundColor = Self.resolved(.selectedTextColor)
            let palette = Self.palette(isDark: isDark).map { Self.resolved($0) }
            installColors(palette.map { SwiftTerm.Color(nsColor: $0) })
        }
    }

    private static func resolved(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    /// The 16 ANSI slots from the system's own hues; black and white are read against the surface.
    private static func palette(isDark: Bool) -> [NSColor] {
        let hues: [NSColor] = [
            .systemRed, .systemGreen, isDark ? .systemYellow : .systemOrange, .systemBlue,
            .systemPurple, .systemCyan,
        ]
        let black = NSColor(white: isDark ? 0.35 : 0, alpha: 1)
        let white = NSColor(white: isDark ? 0.85 : 0.45, alpha: 1)
        let brightBlack = NSColor(white: isDark ? 0.55 : 0.6, alpha: 1)
        let brightWhite = NSColor(white: isDark ? 1 : 0.3, alpha: 1)
        let toward: NSColor = isDark ? .white : .black
        let brightHues = hues.map { $0.blended(withFraction: 0.25, of: toward) ?? $0 }
        return [black] + hues + [white, brightBlack] + brightHues + [brightWhite]
    }
}
