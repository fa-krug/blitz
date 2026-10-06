import AppKit

/// macOS's own share sheet, the one system popover Blitz shows; see docs/features/file-search.md.
@MainActor
enum SharePicker {
    /// Held here because a picker dies with its last reference, closing the sheet mid-share.
    private static var current: NSSharingServicePicker?

    /// Anchored to `anchor`'s trailing edge, so the row being shared stays visible beside it.
    static func show(_ items: [Any], from anchor: NSView) {
        let picker = NSSharingServicePicker(items: items)
        current = picker
        picker.show(
            relativeTo: CGRect(x: anchor.bounds.maxX, y: anchor.bounds.midY, width: 0, height: 0),
            of: anchor, preferredEdge: .maxX)
    }
}
