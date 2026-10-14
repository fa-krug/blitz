import AppKit

/// Reads the context rows' facts off the Mac and asks before any of it goes back to the model.
@MainActor
enum ContextToolRunner {
    /// `app` is the user's app, never Blitz: `ExternalAppMonitor` says which.
    static func run(
        _ call: AIToolCall, app: NSRunningApplication?, authorize: AgentAuthorization
    ) async -> AIToolResult {
        do throws(AIToolArguments.Invalid) {
            try ContextToolCatalog.checkArguments(call.arguments)
        } catch {
            return .failure(call.id, error.message)
        }
        switch call.name {
        case ContextToolCatalog.frontmostAppName:
            return await frontmostApp(app, callID: call.id, authorize: authorize)
        case ContextToolCatalog.selectedTextName:
            return await selectedText(in: app, callID: call.id, authorize: authorize)
        default:
            return await clipboard(callID: call.id, authorize: authorize)
        }
    }

    private static func frontmostApp(
        _ running: NSRunningApplication?, callID: String, authorize: AgentAuthorization
    ) async -> AIToolResult {
        guard let running else { return .failure(callID, ContextToolCatalog.noApp) }
        let app = described(running)
        if let refusal = await authorize(AgentPrompt.seeFrontmostApp(app.name)) {
            return .failure(callID, refusal)
        }
        guard !running.isTerminated else { return .failure(callID, ContextToolCatalog.quit(app)) }
        let window: ContextToolCatalog.WindowTitle
        if Permissions.isAccessibilityTrusted() {
            let title = await Task.detached { AccessibilityText.windowTitle(in: running) }.value
            window = title.flatMap { $0.isEmpty ? nil : .title($0) } ?? .none
        } else {
            window = .needsAccessibility
        }
        let answer = ContextToolCatalog.frontmostAnswer(app, window: window)
        return AIToolResult(callID: callID, content: answer, isError: false)
    }

    /// Read before asking, so a dialog never offers what is not there; never a borrowed ⌘C.
    private static func selectedText(
        in running: NSRunningApplication?, callID: String, authorize: AgentAuthorization
    ) async -> AIToolResult {
        // Checked, never prompted for: macOS's own request belongs to a gesture of the user's.
        guard Permissions.isAccessibilityTrusted() else {
            return .failure(callID, ContextToolCatalog.needsAccessibility)
        }
        guard let running else { return .failure(callID, ContextToolCatalog.noApp) }
        let app = described(running)
        let text: String
        switch await Task.detached(operation: { AccessibilityText.read(in: running) }).value {
        case .noFocusedElement: return .failure(callID, ContextToolCatalog.noFocusedElement(app))
        case .empty: return .failure(callID, ContextToolCatalog.noSelection(app))
        case .text(let selected):
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(callID, ContextToolCatalog.noSelection(app))
            }
            text = selected
        }
        if let refusal = await authorize(AgentPrompt.readSelectedText(in: app.name)) {
            return .failure(callID, refusal)
        }
        guard Permissions.isAccessibilityTrusted() else {
            return .failure(callID, ContextToolCatalog.needsAccessibility)
        }
        let answer = ContextToolCatalog.selectionAnswer(text, in: app)
        return AIToolResult(callID: callID, content: answer, isError: false)
    }

    /// A secret copy is refused unasked, and a copy made while the dialog was up is never read.
    private static func clipboard(
        callID: String, authorize: AgentAuthorization
    ) async -> AIToolResult {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let content = ContextToolCatalog.clipboard(
            read(pasteboard), secretTypes: PasteboardSensitivity.markerTypes)
        switch content {
        case .sensitive: return .failure(callID, ContextToolCatalog.sensitive)
        case .empty: return .failure(callID, ContextToolCatalog.empty)
        case .text, .files, .other: break
        }
        let summary = ContextToolCatalog.summary(of: content)
        if let refusal = await authorize(AgentPrompt.readClipboard(summary)) {
            return .failure(callID, refusal)
        }
        guard pasteboard.changeCount == changeCount else {
            return .failure(callID, ContextToolCatalog.clipboardChanged)
        }
        let answer = ContextToolCatalog.clipboardAnswer(content)
        return AIToolResult(callID: callID, content: answer, isError: false)
    }

    private static func read(_ pasteboard: NSPasteboard) -> ContextToolCatalog.Pasteboard {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        // The markers are checked before anything else is read off a secret copy.
        guard !PasteboardSensitivity.isSensitive(types) else {
            return ContextToolCatalog.Pasteboard(types: types, text: nil, filePaths: [])
        }
        return ContextToolCatalog.Pasteboard(
            types: types, text: pasteboard.string(forType: .string),
            filePaths: PasteboardFiles.urls(on: pasteboard).map(\.path))
    }

    private static func described(_ app: NSRunningApplication) -> ContextToolCatalog.App {
        ContextToolCatalog.App(
            name: app.localizedName ?? app.bundleIdentifier ?? "The app",
            bundleID: app.bundleIdentifier)
    }
}
