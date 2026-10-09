import SwiftUI

/// An action's own shortcut, matched before the palette's bindings see it.
struct ExtensionShortcutKeys: ViewModifier {
    /// Resolved per press, so the palette never re-renders its handlers to track the selection.
    let target: () -> (screen: ExtensionCommandScreen, selection: Int)?

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard !press.modifiers.isEmpty, let target = target() else { return .ignored }
            return target.screen.dispatchShortcut(
                key: ASCIIKeyboardLayout.keyEquivalent(fallingBackTo: press.key),
                modifiers: press.modifiers,
                at: target.selection) ? .handled : .ignored
        }
    }
}

struct ExtensionToastSlot: ViewModifier {
    let extensions: ExtensionManager
    let showing: Bool

    func body(content: Content) -> some View {
        let toast = showing ? extensions.toasts.last : nil
        ZStack(alignment: .leading) {
            content
                .opacity(toast == nil ? 1 : 0)
                .allowsHitTesting(toast == nil)
            if let toast {
                ExtensionToastPill(
                    toast: toast, onAction: { extensions.runToastAction(token: $0) },
                    onDismiss: { extensions.hide(toast: toast.id) }
                )
                .id(toast.id)
                .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: toast?.id)
    }
}

struct ExtensionFormKeys: ViewModifier {
    let field: ExtensionFormField
    let onActivate: () -> Void
    let onSubmit: () -> Void
    @Environment(PaletteState.self) private var palette

    func body(content: Content) -> some View {
        content.onKeyPress(keys: ExtensionFormKey.enterKeys.union([.space]), phases: [.down, .repeat]) {
            press in
            switch ExtensionFormKey.resolve(
                field: field, key: press.key, modifiers: press.modifiers,
                repeating: press.phase == .repeat, menuOpen: palette.menuOpen,
                composing: palette.isComposing)
            {
            case .activate: onActivate()
            case .submit: onSubmit()
            case .consume: break
            case .ignored: return .ignored
            }
            return .handled
        }
    }
}
