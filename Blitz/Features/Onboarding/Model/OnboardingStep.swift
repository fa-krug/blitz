import Foundation

/// The welcome tour's pages, in the order they are shown.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case shortcut
    case accessibility
    case raycastImport
    case tips
    case done

    static let first = Self.shortcut
    static let last = Self.done

    var title: String {
        switch self {
        case .shortcut: "Welcome to Blitz"
        case .accessibility: "Enable Pasting"
        case .raycastImport: "Import from Raycast"
        case .tips: "Three Things to Try"
        case .done: "You're all set"
        }
    }

    /// Nil on the last page, whose line names the launcher shortcut just chosen.
    var subtitle: String? {
        switch self {
        case .shortcut: "Set a shortcut to summon the launcher from anywhere."
        case .accessibility: "Let Blitz paste items back into the app you were using."
        case .raycastImport: "Bring your shortcuts, favorites, and clipboard history along."
        case .tips: "Each one works from the launcher's search field."
        case .done: nil
        }
    }

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }
}
