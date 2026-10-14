import SwiftUI

/// Blitz's own menu-bar item. A waiting agent's dot is the one thing a feature may add to it.
struct MenuBarLabel: View {
    let appName: String

    var body: some View {
        // Read through Observation, so the dot comes and goes as a chat starts and stops waiting.
        if AppCore.shared.aiChats.isAnyWaiting {
            Image(nsImage: MenuBarIcon.waiting)
                .accessibilityLabel("\(appName), the agent is waiting")
        } else {
            Image("MenuBarIcon")
                .accessibilityLabel(appName)
        }
    }
}

/// The bolt with a dot cut into its corner; still a template, so the bar tints both alike.
@MainActor
private enum MenuBarIcon {
    private nonisolated static let dotDiameter: CGFloat = 5
    private nonisolated static let dotGap: CGFloat = 1.5

    static let waiting: NSImage = {
        let size = NSImage(named: "MenuBarIcon")?.size ?? NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSImage(named: "MenuBarIcon")?.draw(in: rect)
            let dot = NSRect(
                x: rect.maxX - dotDiameter, y: rect.maxY - dotDiameter,
                width: dotDiameter, height: dotDiameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -dotGap, dy: -dotGap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarMenu: View {
    let appName: String

    var body: some View {
        Button("Open \(appName)") {
            AppCore.shared.paletteCoordinator.showPalette(mode: .launcher)
        }
        // Read through Observation, so switching the feature off takes the row with it.
        if AppCore.shared.settings.clipboardEnabled {
            Button("Clipboard History") {
                AppCore.shared.paletteCoordinator.showPalette(mode: .clipboard)
            }
        }
        Divider()
        Button("Check for Updates...") { AppCore.shared.updateCoordinator.checkForUpdates() }
        Button("Support \(appName)...") { AppCore.shared.supportCoordinator.showSupport() }
        Button("Settings...") { AppCore.shared.settingsCoordinator.showSettings() }
            .keyboardShortcut(",")
        Divider()
        // No ⌘Q: the app menu binds it to Close Settings, and two contradictory ⌘Qs is a lie.
        Button("Quit \(appName)") { NSApp.terminate(nil) }
    }
}
