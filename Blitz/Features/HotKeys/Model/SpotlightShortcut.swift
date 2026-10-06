import Carbon.HIToolbox
import Foundation

/// A system search shortcut as `AppleSymbolicHotKeys` records it. See docs/features/hotkeys.md.
struct SpotlightShortcut: Equatable, Sendable {
    enum Owner: String, CaseIterable, Sendable {
        case spotlight
        case finderSearch

        /// The key macOS files this shortcut under in `AppleSymbolicHotKeys`.
        var symbolicHotKeyID: String {
            switch self {
            case .spotlight: "64"
            case .finderSearch: "65"
            }
        }

        /// The checkbox's label in Keyboard Shortcuts › Spotlight.
        var settingTitle: String {
            switch self {
            case .spotlight: "Show Spotlight search"
            case .finderSearch: "Show Finder search window"
            }
        }

        /// What macOS uses until the user touches the shortcut, when the table holds no entry.
        var defaultChord: KeyShortcut {
            switch self {
            case .spotlight: SpotlightShortcut.commandSpace
            case .finderSearch:
                KeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: cmdKey | optionKey)
            }
        }
    }

    static let commandSpace = KeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: cmdKey)

    let owner: Owner
    let isEnabled: Bool
    /// Nil when the user cleared the shortcut, which leaves it bound to nothing.
    let chord: KeyShortcut?

    /// True when macOS takes `shortcut` for this one before any app hotkey can see it.
    func claims(_ shortcut: KeyShortcut) -> Bool {
        isEnabled && chord == shortcut
    }

    /// Every system search shortcut that takes `shortcut`, in `Owner` order.
    static func holders(of shortcut: KeyShortcut, in table: [String: Any]?) -> [Owner] {
        Owner.allCases.filter { read($0, from: table).claims(shortcut) }
    }

    /// A missing table or entry is the macOS default, which is enabled.
    static func read(_ owner: Owner, from table: [String: Any]?) -> SpotlightShortcut {
        guard let entry = table?[owner.symbolicHotKeyID] as? [String: Any] else {
            return SpotlightShortcut(owner: owner, isEnabled: true, chord: owner.defaultChord)
        }
        let isEnabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
        guard let value = entry["value"] as? [String: Any] else {
            return SpotlightShortcut(owner: owner, isEnabled: isEnabled, chord: owner.defaultChord)
        }
        return SpotlightShortcut(owner: owner, isEnabled: isEnabled, chord: chord(from: value))
    }

    /// `parameters` is (character, virtual key code, device-independent `NSEvent` flags).
    private static func chord(from value: [String: Any]) -> KeyShortcut? {
        guard let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else {
            return nil
        }
        let keyCode = parameters[1].intValue
        guard keyCode != unassignedKeyCode else { return nil }
        return KeyShortcut(
            carbonKeyCode: keyCode, carbonModifiers: carbonModifiers(from: parameters[2].intValue))
    }

    private static let unassignedKeyCode = 65535

    private static let eventFlagToCarbon: [(flag: Int, carbon: Int)] = [
        (0x20000, shiftKey), (0x40000, controlKey), (0x80000, optionKey), (0x100000, cmdKey),
        (0x800000, kEventKeyModifierFnMask)
    ]

    private static func carbonModifiers(from eventFlags: Int) -> Int {
        eventFlagToCarbon.reduce(0) { carbon, pair in
            eventFlags & pair.flag != 0 ? carbon | pair.carbon : carbon
        }
    }
}
