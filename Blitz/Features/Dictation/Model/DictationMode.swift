import Foundation

/// What the Dictation shortcut does: a press starts and the next press stops, or it is held.
enum DictationMode: String, CaseIterable, Identifiable, Sendable {
    case toggle
    case hold

    var id: Self { self }

    var title: String {
        switch self {
        case .toggle: "Press to start or stop"
        case .hold: "Hold to talk"
        }
    }
}
