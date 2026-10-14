import Foundation

/// The context reads: the app the user is in, the text selected there, and the clipboard now.
enum ContextToolCatalog {
    static let origin = "Context"
    static let frontmostAppName = "context_frontmost_app"
    static let selectedTextName = "context_selected_text"
    static let clipboardName = "context_clipboard"
    /// Bytes of UTF-8 a selection or the clipboard's text hands back.
    static let readLimit = 64 * 1024
    /// Type names a description of what is not text lists at most.
    static let typeLimit = 5

    private typealias Invalid = AIToolArguments.Invalid

    /// The app as the tools name it.
    struct App: Equatable, Sendable {
        let name: String
        let bundleID: String?
    }

    enum WindowTitle: Equatable, Sendable {
        case title(String)
        case none
        case needsAccessibility
    }

    /// What the pasteboard holds, read as plain values.
    struct Pasteboard: Equatable, Sendable {
        let types: [String]
        let text: String?
        let filePaths: [String]
    }

    enum Clipboard: Equatable, Sendable {
        /// Marked secret or transient by whoever copied it, so never read back.
        case sensitive
        case empty
        case text(String)
        case files([String])
        /// Neither text nor files: the types it does hold.
        case other([String])
    }

    static func handles(_ name: String) -> Bool { row(for: name) != nil }

    static func row(for name: String) -> AgentTool? {
        switch name {
        case frontmostAppName: .frontmostApp
        case selectedTextName: .selectedText
        case clipboardName: .currentClipboard
        default: nil
        }
    }

    static func tools(frontmostApp: Bool, selectedText: Bool, clipboard: Bool) -> [AITool] {
        let confirm = " The user may be asked to confirm, and may decline."
        let none = AIToolJSON.object(properties: [:])
        let app = AITool(
            name: frontmostAppName,
            description: "Find out which app the user is working in: the frontmost app other "
                + "than Blitz, or the one they were in before switching to Blitz, with its "
                + "bundle identifier and the title of its front window." + confirm,
            parameters: none, origin: origin, title: "See the Frontmost App")
        let selection = AITool(
            name: selectedTextName,
            description: "Read the text the user has selected in the app they are working in, "
                + "the same app \(frontmostAppName) names." + confirm,
            parameters: none, origin: origin, title: "Read Selected Text")
        let pasteboard = AITool(
            name: clipboardName,
            description: "Read what the user copied last: its text, the paths of copied files, "
                + "or what kind of content it is. A copy marked secret, as password managers "
                + "mark theirs, is never read." + confirm,
            parameters: none, origin: origin, title: "Read the Clipboard")
        return (frontmostApp ? [app] : []) + (selectedText ? [selection] : [])
            + (clipboard ? [pasteboard] : [])
    }

    /// None of the three takes arguments, but a call must still be one JSON object.
    static func checkArguments(_ arguments: String) throws(AIToolArguments.Invalid) {
        _ = try AIToolArguments(arguments)
    }

    // MARK: - The frontmost app

    static func frontmostAnswer(_ app: App, window: WindowTitle) -> String {
        let bundle = app.bundleID.map { " (\($0))" } ?? ""
        let title =
            switch window {
            case .title(let title): "Its front window is titled \u{201C}\(title)\u{201D}."
            case .none: "It shows no window with a title."
            case .needsAccessibility:
                "Its window\u{2019}s title is unknown: Blitz does not have Accessibility access."
            }
        return "The user is working in \(app.name)\(bundle). " + title
    }

    // MARK: - The selection

    static func selectionAnswer(_ text: String, in app: App) -> String {
        let header = "Selected in \(app.name)"
        let size = text.utf8.count
        guard size > readLimit else { return header + ":\n\n" + text }
        let shown = AIToolJSON.prefix(text, utf8Bytes: readLimit)
        return header + ", cut to its first \(shown.utf8.count) of \(size) bytes:\n\n" + shown
    }

    // MARK: - The clipboard

    /// A secret marker wins over everything; files before text, since Finder adds their names.
    static func clipboard(_ pasteboard: Pasteboard, secretTypes: Set<String>) -> Clipboard {
        if pasteboard.types.contains(where: secretTypes.contains) { return .sensitive }
        if !pasteboard.filePaths.isEmpty { return .files(pasteboard.filePaths) }
        if let text = pasteboard.text, !text.isEmpty { return .text(text) }
        return pasteboard.types.isEmpty ? .empty : .other(pasteboard.types)
    }

    /// What the dialog names: the kind and size of the content, never the content.
    static func summary(of clipboard: Clipboard) -> String {
        switch clipboard {
        case .text(let text):
            text.count == 1 ? "text, 1 character" : "text, \(text.count) characters"
        case .files(let paths):
            paths.count == 1 ? "1 file\u{2019}s path" : "\(paths.count) files\u{2019} paths"
        case .other(let types): kind(of: types)
        case .sensitive, .empty: "nothing"
        }
    }

    static func clipboardAnswer(_ clipboard: Clipboard) -> String {
        switch clipboard {
        case .text(let text):
            let size = text.utf8.count
            guard size > readLimit else { return "The clipboard holds this text:\n\n" + text }
            let shown = AIToolJSON.prefix(text, utf8Bytes: readLimit)
            return "The clipboard holds text, cut here to its first \(shown.utf8.count) of "
                + "\(size) bytes:\n\n" + shown
        case .files(let paths):
            let count = paths.count == 1 ? "1 copied file" : "\(paths.count) copied files"
            return "The clipboard holds \(count):\n" + paths.joined(separator: "\n")
        case .other(let types):
            let listed = types.prefix(typeLimit).joined(separator: ", ")
            let more = types.count > typeLimit ? " and \(types.count - typeLimit) more" : ""
            return "The clipboard holds no text, only \(kind(of: types)) (\(listed)\(more))."
        case .sensitive: return sensitive
        case .empty: return empty
        }
    }

    private static let imageTypes: Set = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"
    ]

    private static func kind(of types: [String]) -> String {
        if types.contains(where: imageTypes.contains) { return "an image" }
        if types.contains("com.adobe.pdf") { return "a PDF" }
        return "content that is not text"
    }

    // MARK: - Refusals

    static let noApp = "No app other than Blitz has been in front since Blitz started."
    static let needsAccessibility =
        "Blitz does not have Accessibility access, so it cannot read the selected text. The user "
        + "can allow it in System Settings \u{203A} Privacy & Security \u{203A} Accessibility."
    static let sensitive =
        "What was copied last is marked as a secret, as password managers mark theirs, so Blitz "
        + "does not read it."
    static let empty = "The clipboard is empty."
    static let clipboardChanged =
        "The clipboard changed while the user was asked, so nothing was read."

    static func noFocusedElement(_ app: App) -> String {
        "\(app.name) does not tell Blitz which of its text is focused, so the selection cannot be "
            + "read there."
    }

    static func noSelection(_ app: App) -> String {
        "Nothing is selected in \(app.name)."
    }

    static func quit(_ app: App) -> String {
        "\(app.name) quit while the user was asked."
    }
}
