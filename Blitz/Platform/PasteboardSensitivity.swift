import Foundation

/// The markers that say a copy must never be kept or read back; history and the agent share them.
enum PasteboardSensitivity {
    /// Put on secret copies by password managers, browsers and the OS.
    static let markerTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.apple.is-sensitive"
    ]

    static func isSensitive(_ types: [String]) -> Bool {
        types.contains(where: markerTypes.contains)
    }
}
