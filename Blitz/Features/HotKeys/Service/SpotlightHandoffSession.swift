import Foundation

/// Taking ⌘Space from Spotlight: the user frees it in System Settings; Blitz binds it on return.
@MainActor
@Observable
final class SpotlightHandoffSession {
    /// The system search shortcuts that take ⌘Space before any app hotkey sees it.
    private(set) var holders: [SpotlightShortcut.Owner] = []
    /// Set once ⌘Space was asked for while taken; freeing it then binds it with no recording.
    private(set) var isWaiting = false
    /// The Blitz action already holding ⌘Space, which keeps the launcher from taking it.
    private(set) var conflictOwner: String?
    @ObservationIgnored private let hotKeys: HotKeyManager

    init(hotKeys: HotKeyManager) {
        self.hotKeys = hotKeys
    }

    var launcherUsesCommandSpace: Bool {
        hotKeys.binding(for: .togglePalette) == .combo(SpotlightShortcut.commandSpace)
    }

    /// ⌘Space is the launcher's, but macOS still opens a search with it.
    var isLauncherBlocked: Bool { launcherUsesCommandSpace && !holders.isEmpty }

    var showsGuide: Bool { isWaiting || isLauncherBlocked }

    /// Cheap enough to run whenever Blitz becomes active, which is how the user returns.
    func refresh() {
        holders = Self.currentHolders()
        if isWaiting, holders.isEmpty { bind() }
    }

    /// Binds ⌘Space at once when it is free, else waits for the user to free it.
    func useCommandSpace() {
        holders = Self.currentHolders()
        if holders.isEmpty {
            bind()
        } else {
            isWaiting = true
        }
    }

    func showGuide() {
        isWaiting = true
    }

    static func currentHolders() -> [SpotlightShortcut.Owner] {
        SpotlightShortcut.holders(of: SpotlightShortcut.commandSpace, in: SymbolicHotKeys.table())
    }

    private func bind() {
        isWaiting = false
        let binding = HotKeyBinding.combo(SpotlightShortcut.commandSpace)
        conflictOwner = hotKeys.conflictOwner(of: binding, excluding: .togglePalette)
        guard conflictOwner == nil else { return }
        hotKeys.setBinding(binding, for: .togglePalette)
    }
}
