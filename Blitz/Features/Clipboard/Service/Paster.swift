import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Stamped on Blitz's own synthetic keystrokes so the snippet keyword tap can skip them.
    static let blitzEventTag: Int64 = 0x54494E59

    /// Covers the gap between `activate()` returning and the target app accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    /// Write the item and paste it into `previousApp`, activating it so ⌘V lands there.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?,
        formats: Set<ClipboardRichFormat>? = nil
    ) -> Bool {
        guard write(item, store: store, formats: formats) else { return false }
        store.promote(item)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
        return true
    }

    /// Paste only the item's text, so a file arrives as its path and the receiver's style applies.
    @MainActor @discardableResult
    static func pastePlainText(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard let text = item.plainText else { return false }
        pasteString(text, previousApp: previousApp)
        store.promote(item)
        return true
    }

    /// Put the item on the pasteboard without pasting; the marker stops re-capture.
    @MainActor @discardableResult
    static func copy(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        guard write(item, store: store) else { return false }
        store.promote(item)
        return true
    }

    /// Put a string on the pasteboard unmarked, so it enters history like any other copy.
    @MainActor
    static func copyPlainText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    /// String counterpart of `paste`, marker-stamped so the text doesn't re-enter history.
    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        writeString(text)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    /// A file, pasted into `previousApp`; the receiver takes the file or its path, as it reads.
    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        PasteboardFiles.write(url, to: .general)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    /// String counterpart of `copy(_:store:)`.
    @MainActor
    static func copyString(_ text: String) {
        writeString(text)
    }

    /// String counterpart of `pasteInPlace`; the palette stays frontmost.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        writeString(text)
        guard let pid = app?.processIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
            postCommandV(toPid: pid)
        }
    }

    @MainActor
    private static func writeString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.internalType)
    }

    /// Paste into `app` without activating or promoting, so the palette and its rows hold still.
    @MainActor @discardableResult
    static func pasteInPlace(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        if let pid = app?.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
                postCommandV(toPid: pid)
            }
        }
        return true
    }

    /// False for a vanished item, which leaves the pasteboard alone; nil `formats` writes them all.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, formats: Set<ClipboardRichFormat>? = nil,
        to pb: NSPasteboard = .general
    ) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            let styled = richData(of: item, limitedTo: formats)
            pb.clearContents()
            pb.declareTypes(
                styled.map(\.type) + [.string, ClipboardManager.internalType], owner: nil)
            for (type, data) in styled { pb.setData(data, forType: type) }
            pb.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item),
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                return false
            }
            pb.clearContents()
            pb.declareTypes([.png, ClipboardManager.internalType], owner: nil)
            pb.setData(data, forType: .png)
        case .file:
            guard let url = store.fileURL(for: item),
                FileManager.default.fileExists(atPath: url.path)
            else { return false }
            pb.clearContents()
            pb.declareTypes([.fileURL, .string, ClipboardManager.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            // Both types: a file-taking app receives the file, a text field receives the path.
            pb.setString(url.path, forType: .string)
        }
        pb.setData(Data(), forType: ClipboardManager.internalType)
        return true
    }

    /// A flavour whose file has gone is skipped, so the plain text still pastes.
    private static func richData(
        of item: ClipboardItem, limitedTo formats: Set<ClipboardRichFormat>?
    ) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        ClipboardRichFormat.allCases.compactMap { format in
            guard formats?.contains(format) ?? true, let path = item.formats[format],
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return nil }
            return (NSPasteboard.PasteboardType(format.rawValue), data)
        }
    }

    /// Synthesize ⌘V, to `pid` alone when given, else through the system tap.
    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @MainActor
    static func postCommandC(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    @MainActor
    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) {
        guard Permissions.ensureAccessibility() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: blitzEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: blitzEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
