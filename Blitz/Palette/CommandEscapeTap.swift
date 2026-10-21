import AppKit
import Carbon.HIToolbox
import Synchronization

/// C entry point: the decision is a key-code compare, so it is made here rather than crossing out.
private func commandEscapeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let session = Unmanaged<CommandEscapeTap.Session>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        session.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
        CommandEscapeTap.isChord(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags),
        session.claimChord()
    else { return Unmanaged.passUnretained(event) }
    return nil
}

/// The window server binds ⌘⎋ upstream of every app, so only a head-inserted HID tap sees it.
@MainActor
final class CommandEscapeTap {
    private let onChord: @MainActor @Sendable () -> Void
    private var session: Session?

    init(onChord: @escaping @MainActor @Sendable () -> Void) {
        self.onChord = onChord
    }

    isolated deinit {
        session?.stop()
    }

    /// True only for a bare ⌘⎋: any further modifier spells somebody else's chord.
    nonisolated static func isChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(kVK_Escape)
            && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                == .maskCommand
    }

    /// Called on every key focus: a tap refused for want of Accessibility is retried the next time.
    func enable() {
        guard session?.isActive != true else { return }
        let session = Session(onChord: onChord)
        self.session = session
        // Its own run loop, so a busy main thread never holds up every keystroke on the system.
        let thread = Thread { session.run() }
        thread.name = "de.fa-krug.blitz.command-escape"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func disable() {
        session?.stop()
        session = nil
    }

    fileprivate final class Session: Sendable {
        // Core Foundation allows cross-thread run-loop control; only the worker uses the port.
        private struct Installation: @unchecked Sendable {
            let port: CFMachPort
            let runLoop: CFRunLoop
        }

        private struct State {
            var isActive = true
            var installation: Installation?
        }

        // Not an actor: the synchronous C tap callback must decide before it returns.
        private let state = Mutex(State())
        private let onChord: @MainActor @Sendable () -> Void

        init(onChord: @escaping @MainActor @Sendable () -> Void) {
            self.onChord = onChord
        }

        var isActive: Bool { state.withLock { $0.isActive } }

        func stop() {
            state.withLock { state in
                state.isActive = false
                guard let runLoop = state.installation?.runLoop else { return }
                // A queued stop also covers closing before the worker enters its run loop.
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
                CFRunLoopWakeUp(runLoop)
            }
        }

        func run() {
            autoreleasepool {
                defer {
                    state.withLock {
                        $0.isActive = false
                        $0.installation = nil
                    }
                }
                // Head of the HID stream: anywhere later and the system hotkey has eaten it.
                guard isActive,
                    let port = CGEvent.tapCreate(
                        tap: .cghidEventTap,
                        place: .headInsertEventTap,
                        options: .defaultTap,
                        eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                        callback: commandEscapeTapCallback,
                        userInfo: Unmanaged.passUnretained(self).toOpaque())
                else { return }
                defer {
                    CGEvent.tapEnable(tap: port, enable: false)
                    CFMachPortInvalidate(port)
                }
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0),
                    let runLoop = CFRunLoopGetCurrent()
                else { return }
                CFRunLoopAddSource(runLoop, source, .defaultMode)
                defer { CFRunLoopRemoveSource(runLoop, source, .defaultMode) }
                let shouldRun = state.withLock { state in
                    guard state.isActive else { return false }
                    state.installation = Installation(port: port, runLoop: runLoop)
                    return true
                }
                guard shouldRun else { return }
                CFRunLoopRun()
            }
        }

        /// The system disables a tap it thinks is too slow; ours only ever compares two integers.
        func reenable() {
            state.withLock { state in
                guard state.isActive, let port = state.installation?.port else { return }
                CGEvent.tapEnable(tap: port, enable: true)
            }
        }

        func claimChord() -> Bool {
            guard isActive else { return false }
            // Re-checked on main: a session closed while this hop was queued must not act.
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                onChord()
            }
            return true
        }
    }
}
