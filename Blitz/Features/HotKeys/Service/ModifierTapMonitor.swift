import AppKit
import Carbon.HIToolbox

/// C entry point: reduce to Sendable scalars, then cross in. Listen-only, so nothing changes.
private func modifierTapEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.tapWasDisabled() }
        return Unmanaged.passUnretained(event)
    }

    // macOS follows a bare Globe release with key-down 179; it is not a separate key press.
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 179 {
        return Unmanaged.passUnretained(event)
    }
    let isFlagsChanged = type == .flagsChanged
    let flagsRaw = event.flags.rawValue
    // A click has no keycode; -1 keeps it from reading as `kVK_ANSI_A`.
    let keyCode =
        isFlagsChanged || type == .keyDown
        ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : -1
    MainActor.assumeIsolated {
        monitor.process(isFlagsChanged: isFlagsChanged, flagsRaw: flagsRaw, keyCode: keyCode)
    }
    return Unmanaged.passUnretained(event)
}

/// The listen-only modifier tap. See docs/features/hotkeys.md#modifier-only-shortcuts.
@MainActor
@Observable
final class ModifierTapMonitor: HealthCheckable {
    /// True while something is bound and the tap can't be created; the recorder surfaces it.
    private(set) var needsAccessibility = false

    /// Fired on the tap's final release, so the key is up by the time the action runs.
    @ObservationIgnored var onTrigger: ((HotKeyBinding) -> Void)?
    /// The hold key has been down alone for `DoubleTapDetector.maxHold`.
    @ObservationIgnored var onHoldPressed: (() -> Void)?
    @ObservationIgnored var onHoldReleased: (() -> Void)?
    /// Another modifier, key or click interrupted the hold.
    @ObservationIgnored var onHoldCancelled: (() -> Void)?

    /// Set while a recorder captures, so editing a binding can't trigger it.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            resetDetectors()
        }
    }

    private var bound: Set<HotKeyBinding> = []
    /// Advanced by the tap callback on every modifier transition; released by teardown.
    @ObservationIgnored private var doubleTapDetector = DoubleTapDetector()
    @ObservationIgnored private var globeDetector = GlobeTapDetector()
    @ObservationIgnored private var pendingSingleGlobe: Task<Void, Never>?
    @ObservationIgnored private var modifierDetector = ModifierKeyDetector()
    /// A `.modifier` tap waiting out the double-tap window of the same modifier.
    @ObservationIgnored private var pendingSingleModifier: Task<Void, Never>?
    @ObservationIgnored private var pendingSingleModifierKey: ModifierKey?
    @ObservationIgnored private var pendingHold: Task<Void, Never>?
    @ObservationIgnored private var globeDown = false
    @ObservationIgnored private var isHolding = false
    /// The physical key hold-to-talk is armed on; nil while nothing holds.
    private var holdKey: ModifierKey?
    @ObservationIgnored private var tapPort: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var sessionTokens: [NotificationToken] = []
    private var sessionActive = true
    private var loggedTapFailure = false

    @ObservationIgnored weak var healthTicker: HealthTicker?

    // The tap holds an unretained `self`, so it must not outlive it.
    isolated deinit {
        tearDownTap()
    }

    func start() {
        installObserversIfNeeded()
        syncTapPresence()
    }

    /// Modifier-only bindings and the armed hold key; with neither the tap is torn down entirely.
    func update(bound: Set<HotKeyBinding>, holdKey: ModifierKey? = nil) {
        guard bound != self.bound || holdKey != self.holdKey else { return }
        self.bound = bound
        self.holdKey = holdKey
        resetDetectors()
        syncTapPresence()
    }

    private var isNeeded: Bool { !bound.isEmpty || holdKey != nil }

    // MARK: - Detection

    fileprivate func process(isFlagsChanged: Bool, flagsRaw: UInt64, keyCode: Int) {
        guard !isPaused else { return }
        // `systemUptime` is monotonic, so a wall-clock adjustment can't turn a tap into a hold.
        let now = ProcessInfo.processInfo.systemUptime
        let input: DoubleTapDetector.Input
        if isFlagsChanged {
            let flags = CGEventFlags(rawValue: flagsRaw)
            let modifiers = Self.modifiers(in: flags)
            let isGlobeKey = keyCode == kVK_Function
            if isGlobeKey { globeDown = flags.contains(.maskSecondaryFn) }
            if let event = modifierDetector.handle(
                ModifierKey.held(in: flagsRaw, globeDown: globeDown), at: now)
            {
                handleModifierKey(event)
            }
            if !isGlobeKey || !modifiers.isEmpty { cancelPendingSingleGlobe() }
            if let gesture = globeDetector.handle(
                isGlobeKey: isGlobeKey, functionDown: flags.contains(.maskSecondaryFn),
                hasOtherModifiers: !modifiers.isEmpty, at: now)
            {
                handleGlobe(gesture)
            }
            input = .modifiers(modifiers, hasOtherModifiers: Self.hasOtherModifiers(in: flags))
        } else {
            // The dictation panel owns these while the key is held, so they finish, not cancel.
            if isHolding, Self.panelKeyCodes.contains(keyCode) { return }
            globeDetector.cancel()
            cancelPendingSingleGlobe()
            modifierDetector.cancel()
            cancelPendingSingleModifier()
            cancelHold()
            input = .otherInput
        }
        guard let modifier = doubleTapDetector.handle(input, at: now),
            bound.contains(.doubleTap(modifier))
        else { return }
        cancelPendingSingleModifier()
        onTrigger?(.doubleTap(modifier))
    }

    private static let panelKeyCodes: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape]

    private func handleModifierKey(_ event: ModifierKeyDetector.Event) {
        switch event {
        case .pressed(let key):
            if key != pendingSingleModifierKey { cancelPendingSingleModifier() }
            guard key == holdKey else { return }
            pendingHold = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DoubleTapDetector.maxHold))
                guard !Task.isCancelled, let self else { return }
                pendingHold = nil
                isHolding = true
                onHoldPressed?()
            }
        case .released(let key, let doubleTap, let held):
            if key == holdKey {
                pendingHold?.cancel()
                pendingHold = nil
                guard isHolding else { return }
                isHolding = false
                onHoldReleased?()
                return
            }
            if doubleTap, let modifier = key.modifier, bound.contains(.doubleTap(modifier)) {
                // `doubleTapDetector` fires the double itself, later in this same event.
                cancelPendingSingleModifier()
                return
            }
            guard !held, case .modifier = key.binding, bound.contains(key.binding) else { return }
            triggerSingleModifier(key)
        case .cancelled:
            cancelPendingSingleModifier()
            cancelHold()
        }
    }

    /// A lone tap fires at once, unless a double tap of the same modifier could still follow.
    private func triggerSingleModifier(_ key: ModifierKey) {
        let binding = key.binding
        if pendingSingleModifierKey == key {
            cancelPendingSingleModifier()
            onTrigger?(binding)
        }
        guard let modifier = key.modifier, bound.contains(.doubleTap(modifier)) else {
            onTrigger?(binding)
            return
        }
        pendingSingleModifierKey = key
        // Every pause, unbind or interruption cancels this, so waking needs no re-check.
        pendingSingleModifier = Task { [weak self] in
            try? await Task.sleep(for: ModifierKeyDetector.resolutionWindow)
            guard !Task.isCancelled, let self else { return }
            pendingSingleModifier = nil
            pendingSingleModifierKey = nil
            onTrigger?(binding)
        }
    }

    private func cancelPendingSingleModifier() {
        pendingSingleModifier?.cancel()
        pendingSingleModifier = nil
        pendingSingleModifierKey = nil
    }

    private func cancelHold() {
        pendingHold?.cancel()
        pendingHold = nil
        guard isHolding else { return }
        isHolding = false
        onHoldCancelled?()
    }

    private func handleGlobe(_ gesture: GlobeTapDetector.Gesture) {
        switch gesture {
        case .single:
            guard bound.contains(.globe) else { return }
            guard bound.contains(.doubleGlobe) else {
                globeDetector.cancel()
                onTrigger?(.globe)
                return
            }
            if pendingSingleGlobe != nil {
                cancelPendingSingleGlobe()
                onTrigger?(.globe)
            }
            // Every pause, unbind or session change cancels this, so waking needs no re-check.
            pendingSingleGlobe = Task { [weak self] in
                try? await Task.sleep(for: GlobeTapDetector.resolutionWindow)
                guard !Task.isCancelled, let self else { return }
                pendingSingleGlobe = nil
                onTrigger?(.globe)
            }
        case .double:
            cancelPendingSingleGlobe()
            if bound.contains(.doubleGlobe) { onTrigger?(.doubleGlobe) }
        }
    }

    private func cancelPendingSingleGlobe() {
        pendingSingleGlobe?.cancel()
        pendingSingleGlobe = nil
    }

    private func resetDetectors() {
        doubleTapDetector.reset()
        globeDetector.cancel()
        cancelPendingSingleGlobe()
        modifierDetector.reset()
        globeDown = false
        cancelPendingSingleModifier()
        cancelHold()
    }

    private static func modifiers(in flags: CGEventFlags) -> Set<DoubleTapModifier> {
        var held: Set<DoubleTapModifier> = []
        if flags.contains(.maskControl) { held.insert(.control) }
        if flags.contains(.maskAlternate) { held.insert(.option) }
        if flags.contains(.maskShift) { held.insert(.shift) }
        if flags.contains(.maskCommand) { held.insert(.command) }
        return held
    }

    // Never `maskAlphaShift`: it tracks the latch, killing every tap while Caps Lock is on.
    private static func hasOtherModifiers(in flags: CGEventFlags) -> Bool {
        flags.contains(.maskSecondaryFn)
    }

    // MARK: - Tap lifecycle

    private func installObserversIfNeeded() {
        guard sessionTokens.isEmpty else { return }
        // Fast user switching: another session owns the keyboard, so stop watching.
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sessionDidChange(active: false) }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sessionDidChange(active: true) }
                }, center: center)
        ]
    }

    private func sessionDidChange(active: Bool) {
        sessionActive = active
        resetDetectors()
        syncTapPresence()
    }

    private func syncTapPresence() {
        guard isNeeded, sessionActive else {
            tearDownTap()
            healthTicker?.unsubscribe(self)
            needsAccessibility = false
            return
        }
        healthTicker?.subscribe(self)
        installTapIfNeeded()
    }

    private func installTapIfNeeded() {
        guard tapPort == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                // Appended, so `HyperKeyTap`'s rewrite lands first. See docs/features/hotkeys.md.
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: modifierTapEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Even a listen-only tap needs Accessibility; the health timer retries until granted.
            if !loggedTapFailure {
                NSLog("Blitz: Failed to create modifier event tap")
                loggedTapFailure = true
            }
            needsAccessibility = true
            return
        }
        loggedTapFailure = false
        tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        needsAccessibility = false
    }

    private func tearDownTap() {
        resetDetectors()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
    }

    /// Called when the system disables the tap; any half-tracked press is stale by then.
    fileprivate func tapWasDisabled() {
        resetDetectors()
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    }

    /// One-second watchdog while something is bound. See docs/features/hotkeys.md#lifecycle.
    func healthCheck() {
        guard isNeeded, sessionActive else { return }
        if tapPort == nil {
            installTapIfNeeded()
        } else if !Permissions.isAccessibilityTrusted() {
            tearDownTap()
            needsAccessibility = true
        } else if let tapPort, !CGEvent.tapIsEnabled(tap: tapPort) {
            resetDetectors()
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }
}
