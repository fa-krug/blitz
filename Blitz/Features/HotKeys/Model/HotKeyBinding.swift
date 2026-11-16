import Foundation

/// What an action is bound to. See docs/features/hotkeys.md.
enum HotKeyBinding: Hashable, Sendable, Codable {
    case combo(KeyShortcut)
    case doubleTap(DoubleTapModifier)
    /// One sided physical modifier; only Dictation records it. Globe alone stays `.globe`.
    case modifier(ModifierKey)
    case globe
    case doubleGlobe

    /// One string per keycap, so every display site renders all bindings through one path.
    @MainActor var keycaps: [String] {
        switch self {
        case .combo(let shortcut): shortcut.keycaps
        case .doubleTap(let modifier): modifier.keycaps
        case .modifier(let key): [key.glyph]
        case .globe: [ModifierKey.globeGlyph]
        case .doubleGlobe: [ModifierKey.globeGlyph, ModifierKey.globeGlyph]
        }
    }

    /// The small L or R a sided modifier's keycap carries before its glyph.
    var recorderPrefix: String? {
        guard case .modifier(let key) = self else { return nil }
        return key.side.map { String($0.prefix(1)) }
    }

    /// Spoken in full, since "⌥" with a stray "R" reads as nothing to VoiceOver.
    @MainActor var accessibilityLabel: String {
        guard case .modifier(let key) = self else { return keycaps.joined(separator: " ") }
        return key.spokenName
    }

    var shortcut: KeyShortcut? {
        if case .combo(let shortcut) = self { return shortcut }
        return nil
    }

    /// Hold-to-talk needs a release to watch for: a Carbon chord's key-up, or a modifier coming up.
    var supportsHold: Bool {
        switch self {
        case .combo, .modifier, .globe: true
        case .doubleTap, .doubleGlobe: false
        }
    }

    /// The physical key a hold watches; a combo's hold is Carbon's, not the tap's.
    var holdKey: ModifierKey? {
        switch self {
        case .modifier(let key): key
        case .globe: .globe
        case .combo, .doubleTap, .doubleGlobe: nil
        }
    }

    var usesModifierTapMonitor: Bool {
        switch self {
        case .combo: false
        case .doubleTap, .modifier, .globe, .doubleGlobe: true
        }
    }

    /// Every physical key a gesture of this binding starts with.
    private var modifierKeys: Set<ModifierKey> {
        switch self {
        case .modifier(let key): [key]
        case .globe, .doubleGlobe: [.globe]
        case .doubleTap(let modifier): Set(ModifierKey.allCases.filter { $0.modifier == modifier })
        case .combo: []
        }
    }

    /// `holdsModifier`: one side is a hold, which reserves its key from every tap gesture.
    func conflicts(with other: Self, holdsModifier: Bool = false) -> Bool {
        if self == other { return true }
        guard holdsModifier else { return false }
        return !modifierKeys.isDisjoint(with: other.modifierKeys)
    }
}
