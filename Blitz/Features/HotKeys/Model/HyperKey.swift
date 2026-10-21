import Carbon.HIToolbox
import CoreGraphics

/// The physical key remapped to the Hyper chord. See docs/features/hotkeys.md#the-hyper-key.
enum HyperKeyPhysicalKey: String, CaseIterable, Identifiable, Sendable {
    case none
    case capsLock
    case rightControl, rightShift, rightOption, rightCommand

    var id: String { rawValue }

    /// The single glyph Hyper shortcuts collapse to.
    static let hyperGlyph = "✦"

    var title: String {
        switch self {
        case .none: return "None"
        case .capsLock: return "Caps Lock (⇪)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        }
    }

    /// Virtual key code of the physical key, `nil` only for `.none`.
    var keyCode: Int? {
        switch self {
        case .none: return nil
        case .capsLock: return kVK_CapsLock
        case .rightControl: return kVK_RightControl
        case .rightShift: return kVK_RightShift
        case .rightOption: return kVK_RightOption
        case .rightCommand: return kVK_RightCommand
        }
    }

    /// The keycode the tap watches; Caps Lock is HID-remapped to F18 while it serves as Hyper.
    var tapKeyCode: Int? {
        self == .capsLock ? kVK_F18 : keyCode
    }

    /// Whether presses arrive as keyDown/keyUp (Caps Lock via F18) or as `flagsChanged`.
    var tapUsesKeyEvents: Bool { self == .capsLock }

    /// Keys that do something on their own when not remapped — these get the Quick Press row.
    var hasOriginalFunction: Bool { self == .capsLock }

    /// The key's own device bit: on its `flagsChanged`, set means it went down. Caps Lock has none.
    var deviceFlag: UInt64? {
        switch self {
        case .none, .capsLock: return nil
        case .rightControl: return ModifierDeviceFlag.rightControl
        case .rightShift: return ModifierDeviceFlag.rightShift
        case .rightOption: return ModifierDeviceFlag.rightOption
        case .rightCommand: return ModifierDeviceFlag.rightCommand
        }
    }

    func isHeld(in flagsRaw: UInt64) -> Bool {
        deviceFlag.map { flagsRaw & $0 != 0 } ?? false
    }

    /// The generic flag this key contributes, so the tap can strip it when outside the set.
    var ownFlag: CGEventFlags? {
        switch self {
        case .none: return nil
        case .capsLock: return .maskAlphaShift
        case .rightControl: return .maskControl
        case .rightShift: return .maskShift
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }

    /// Quick Press label for triggering the key's original function.
    var quickPressOriginalTitle: String? {
        self == .capsLock ? "Trigger Caps Lock (⇪)" : nil
    }
}

/// Device-level modifier bits from IOLLEvent.h. See docs/features/hotkeys.md#the-hyper-key.
enum ModifierDeviceFlag {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
}

/// What a quick lone press of the Hyper key does (only offered for keys with an original function).
enum HyperKeyQuickPress: String, CaseIterable, Sendable {
    case none
    case originalKey
    case escape
}
