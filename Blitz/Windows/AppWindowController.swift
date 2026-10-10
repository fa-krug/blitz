import AppKit
import SwiftUI

private final class AppWindow: NSWindow {
    var closesOnEscape = false

    override func cancelOperation(_ sender: Any?) {
        if closesOnEscape { close() } else { super.cancelOperation(sender) }
    }
}

/// Built on first show and torn down on close, unless kept hidden. Never quits the app.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    private let title: String
    private let contentSize: CGSize
    private let minimumSize: CGSize
    private let isResizable: Bool
    private let autosaveName: String?
    /// A sibling's frame to open cascaded from, keeping its size, instead of centred or restored.
    private let cascadeAnchor: NSRect?
    private let activation: ActivationPolicy
    private let closesOnEscape: Bool
    /// Closing hides the window instead, so reopening skips rebuilding what it holds.
    private let keepsContentWhenClosed: Bool
    /// For an owner holding something that should end with the window, not just hide behind it.
    private let onClose: (() -> Void)?
    private var window: NSWindow?
    /// False while a kept window waits hidden; a torn-down one has no window at all.
    private var isShown = false
    /// Rebuilt with the window, so a chrome's state never outlives the window it decorated.
    private var chrome: WindowChrome?

    /// The opening size is also the resize floor unless a smaller `minimumSize` is named.
    init(
        title: String, contentSize: CGSize, minimumSize: CGSize? = nil, resizable: Bool = false,
        autosaveName: String? = nil, cascadingFrom cascadeAnchor: NSRect? = nil,
        activation: ActivationPolicy, closesOnEscape: Bool = false,
        keepsContentWhenClosed: Bool = false, onClose: (() -> Void)? = nil
    ) {
        self.title = title
        self.contentSize = contentSize
        self.minimumSize = minimumSize ?? contentSize
        self.isResizable = resizable
        self.autosaveName = autosaveName
        self.cascadeAnchor = cascadeAnchor
        self.activation = activation
        self.closesOnEscape = closesOnEscape
        self.keepsContentWhenClosed = keepsContentWhenClosed
        self.onClose = onClose
    }

    /// Returns `true` when a window was built, `false` when an already-open one was re-raised.
    @discardableResult
    func show<Content: View>(
        chrome: WindowChrome? = nil, @ViewBuilder content: () -> Content
    ) -> Bool {
        let root = content()
        return show(chrome: chrome) {
            let hosting = NSHostingController(rootView: root)
            // Keep the window's size authoritative: an unconstrained fill would drive the frame.
            hosting.sizingOptions = []
            return hosting
        }
    }

    /// A prebuilt controller; Settings needs one to bridge its SwiftUI toolbar into the window.
    @discardableResult
    func show(chrome: WindowChrome? = nil, contentViewController: () -> NSViewController) -> Bool {
        if let window {
            reveal(window)
            return false
        }
        let window = makeWindow(content: contentViewController(), chrome: chrome)
        self.chrome = chrome
        self.window = window
        reveal(window)
        return true
    }

    /// Re-raise an open window without rebuilding it; `false` when none is open.
    @discardableResult
    func focus() -> Bool {
        guard let window, isShown else { return false }
        raise(window)
        return true
    }

    /// Shows a kept window again with the tree it closed on; `false` when there is none.
    @discardableResult
    func reopen() -> Bool {
        guard let window, !isShown else { return false }
        reveal(window)
        return true
    }

    func close() {
        if keepsContentWhenClosed { hide() } else { window?.close() }
    }

    /// Nil while closed, kept or not; what a sibling window cascades from.
    var frame: NSRect? { isShown ? window?.frame : nil }

    /// The title bar sits inside the frame but outside the layout area, so it is added back.
    func fitContent(width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let size = CGSize(width: width, height: height + titlebar)
        guard window.contentMinSize != size else { return }
        let top = window.frame.maxY
        window.contentMinSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard keepsContentWhenClosed else { return true }
        hide()
        return false
    }

    /// Reached by a kept window too when something closes it outright, such as Quit from the Dock.
    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        let wasShown = isShown
        self.window = nil
        self.chrome = nil
        isShown = false
        guard wasShown else { return }
        activation.windowDidClose(window)
        onClose?()
    }

    // MARK: - Private

    private func makeWindow(content: NSViewController, chrome: WindowChrome?) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if isResizable { style.insert(.resizable) }
        let window = AppWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.closesOnEscape = closesOnEscape
        // Edge-to-edge under a transparent titlebar, so it reads as one surface.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // AppKit would otherwise resurrect the window at launch, before anything is wired up.
        window.isRestorable = false
        window.contentMinSize = minimumSize
        window.delegate = self
        // Before the content: a bridged SwiftUI toolbar restores the title flags it mounted over.
        chrome?.install(in: window)

        window.contentViewController = content
        // `contentViewController` resets the frame to the controller's fitting size.
        window.setContentSize(contentSize)

        if let cascadeAnchor {
            window.setFrame(cascadeAnchor, display: false)
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: .zero))
            // Claims the name only once no sibling holds it, so two windows never share one frame.
            if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        } else if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(autosaveName) { window.center() }
        } else {
            window.center()
        }
        return window
    }

    private func reveal(_ window: NSWindow) {
        if !isShown {
            isShown = true
            activation.windowDidOpen(window)
        }
        raise(window)
    }

    private func hide() {
        guard let window, isShown else { return }
        isShown = false
        window.orderOut(nil)
        activation.windowDidClose(window)
        onClose?()
    }

    private func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // `NSApp.activate` is async, so re-assert next turn — never onto a window closed since.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window, let self, self.window === window, self.isShown else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
