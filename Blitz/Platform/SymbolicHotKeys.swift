import Foundation

/// macOS's own shortcut table, read live; Blitz never writes `com.apple.symbolichotkeys`.
enum SymbolicHotKeys {
    private static let domain = "com.apple.symbolichotkeys"

    /// Nil when macOS has never written the table, which means every shortcut is at its default.
    static func table() -> [String: Any]? {
        UserDefaults(suiteName: domain)?.dictionary(forKey: "AppleSymbolicHotKeys")
    }
}
