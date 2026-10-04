import Foundation

/// How far a chat model may reach into one of the Mac's own stores through Blitz's tools.
enum AIDataAccess: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case read = 1
    case readWrite = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .read: "Read Only"
        case .readWrite: "Read & Write"
        }
    }

    var canRead: Bool { self != .off }
    var canWrite: Bool { self == .readWrite }
}
