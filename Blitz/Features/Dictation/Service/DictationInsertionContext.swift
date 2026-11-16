import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// The text either side of the caret, from our own editor or over Accessibility.
@MainActor
enum DictationInsertionContext {
    /// Nil when the app does not expose its caret; the formatter then inserts the plain transcript.
    static func read(in target: InjectionTarget?) -> DictationTextFormatter.Context? {
        if let editor = target?.ownEditor {
            return context(editor.string, range: editor.selectedRange())
        }
        guard let app = target?.externalApp,
            let element = AccessibilityText.focusedElement(in: app)
        else { return nil }
        var value: CFTypeRef?
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String,
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
            let selected, CFGetTypeID(selected) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(selected, to: AXValue.self), .cfRange, &range)
        else { return nil }
        return context(text, range: NSRange(location: range.location, length: range.length))
    }

    private static func context(_ text: String, range: NSRange) -> DictationTextFormatter.Context? {
        guard let selected = Range(range, in: text) else { return nil }
        return DictationTextFormatter.Context(
            before: text[..<selected.lowerBound], after: text[selected.upperBound...])
    }
}
