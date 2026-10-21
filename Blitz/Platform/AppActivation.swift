import AppKit

extension NSApplication {
    /// A bare `activate()` is refused while another app is frontmost, as after a global shortcut.
    func activateOverFrontmost() {
        let current = NSRunningApplication.current
        guard let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != current else {
            activate()
            return
        }
        current.activate(from: frontmost, options: [])
    }
}
