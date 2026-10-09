import Foundation

/// Why a command stopped, as its failure screen, its HUD and Copy Error all read it.
struct ExtensionFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case error
        /// Fixed in the extension's Settings page rather than by running it again.
        case missingPreferences
    }

    let message: String
    var reason: Reason = .error

    static func unsupportedRoot(_ type: String) -> ExtensionFailure {
        ExtensionFailure(message: "This command renders \(type), which Blitz can't display yet.")
    }

    /// The first line; a JavaScriptCore stack follows it with frames only.
    var headline: String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    }

    var detail: String? {
        let lines = message.split(separator: "\n").dropFirst()
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// What Copy Error puts on the clipboard: the message, then what the command logged before it.
    func report(console: [String]) -> String {
        guard !console.isEmpty else { return message }
        return message + "\n\nConsole:\n" + console.joined(separator: "\n")
    }
}
