import AppKit

/// The panel a Settings row picks a command with; hidden folders show: `~/.local/bin` is one.
@MainActor
enum ExecutablePicker {
    static func choose(message: String, startingAt directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = false
        panel.prompt = "Use Command"
        panel.message = message
        panel.directoryURL = directory
        // Blitz is an accessory app, so the panel opens behind the frontmost app without this.
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
