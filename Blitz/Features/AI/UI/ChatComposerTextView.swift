import AppKit
import SwiftUI

/// The window's composer field: Return sends, ⇧↩ and ⌥↩ break the line, and it grows to a cap.
struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// A new value pulls focus into the field: a switched chat is one you are about to type into.
    let focusKey: UUID
    /// How a control beside the field reaches the text view this makes.
    let handle: ComposerTextViewHandle
    /// The view is about to show another chat or go away: whatever writes into it must stop.
    let onInvalidate: (ComposerTextView) -> Void
    let onSubmit: () -> Void

    private static var font: NSFont { .preferredFont(forTextStyle: .body) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onInvalidate: onInvalidate, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? ComposerTextView else { return scroll }
        handle.textView = textView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Message")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        if context.coordinator.focusedKey != focusKey { onInvalidate(textView) }
        context.coordinator.text = $text
        context.coordinator.onInvalidate = onInvalidate
        context.coordinator.onSubmit = onSubmit
        // Only an outside write lands here; echoing the view's own text back would reset the caret.
        if textView.string != text { textView.string = text }
        guard context.coordinator.focusedKey != focusKey else { return }
        context.coordinator.focusedKey = focusKey
        // Next turn: on first mount the view has no window to become first responder of yet.
        Task { @MainActor [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        coordinator.onInvalidate(textView)
        textView.delegate = nil
    }

    /// Measured from the text rather than the text view, whose width lags the proposal by a pass.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let font = Self.font
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        // A trailing newline starts a line `boundingRect` would not count until it held a glyph.
        let measured = (text.hasSuffix("\n") ? text + " " : text) as NSString
        let height = measured.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height.rounded(.up)
        return CGSize(
            width: width,
            height: min(max(lineHeight, height), Theme.Size.aiChatComposerMaxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onInvalidate: (ComposerTextView) -> Void
        var onSubmit: () -> Void
        var focusedKey: UUID?

        init(
            text: Binding<String>, onInvalidate: @escaping (ComposerTextView) -> Void,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.onInvalidate = onInvalidate
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        /// Never called mid-composition, so Return confirming an input method's text stays its own.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return true
        }
    }
}

/// One of Blitz's own editors, so dictation, snippets and Quick Actions write into it in process.
final class ComposerTextView: NSTextView, InjectableTextView {}

/// Lets the composer's mic reach the text view the representable made.
@MainActor
final class ComposerTextViewHandle {
    weak var textView: ComposerTextView?
}
