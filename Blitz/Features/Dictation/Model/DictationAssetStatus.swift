import Foundation

/// Whether macOS has the on-device speech model for the chosen language, as Settings shows it.
enum DictationAssetStatus: Equatable, Sendable {
    case checking
    /// No transcriber locale matches the choice or any of the system's preferred languages.
    case unsupported
    case notInstalled
    /// `fraction` is nil until the download reports a size.
    case downloading(fraction: Double?)
    case installed

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .unsupported: "Not available on this Mac"
        case .notInstalled: "Not downloaded"
        case .downloading: "Downloading…"
        case .installed: "Ready"
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
