import AppKit
import AVFoundation

/// Owns dictation: the consent gate, one recording at a time, its transcription and its insertion.
@MainActor
@Observable
final class DictationCoordinator {
    private enum Phase {
        case idle, starting, listening, transcribing, stopping
    }

    private let settings: AppSettings
    private let hotKeys: HotKeyManager
    private let injector: TextInjector
    private let settingsCoordinator: SettingsCoordinator
    /// Dialogs and the HUD, so both stay owned by `AppCore`.
    private unowned let core: AppCore
    @ObservationIgnored private let capture = DictationCapture()
    @ObservationIgnored private let audioDucker: DictationAudioDucker
    @ObservationIgnored private let cues = DictationCueRunner()
    @ObservationIgnored private let panel = DictationPanelController()

    /// The field a mic button is dictating into; nil for a shortcut's session.
    private(set) var field: DictationField?
    /// The model for the language Settings shows, refreshed as that language changes.
    private(set) var assetStatus: DictationAssetStatus = .checking
    /// What the language picker offers, sorted by name; empty until first read.
    private(set) var supportedLanguages: [Locale] = []
    /// The locale "System" resolves to, for the picker's label.
    private(set) var resolvedLanguage: Locale?

    @ObservationIgnored private var phase: Phase = .idle
    /// A new value per session, so a cancelled or superseded run can never insert text.
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var target: InjectionTarget?
    @ObservationIgnored private var locale: Locale?
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, any Error>?
    @ObservationIgnored private var installingLocale: Locale?
    @ObservationIgnored private var languageTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Where the next live chunk starts; the final pass transcribes only what follows it.
    @ObservationIgnored private var liveOffset = 0
    @ObservationIgnored private var liveText = ""
    @ObservationIgnored private var liveDeliveryFailed = false
    @ObservationIgnored private var pendingStartCue: UUID?
    @ObservationIgnored private var finishWhenStarted = false

    /// A Bluetooth headset's output resumes up to a quarter second after the first samples.
    private static let bluetoothSettle = Duration.milliseconds(500)
    /// How often live insertion looks for a pause to cut at.
    private static let liveInterval = Duration.seconds(2)

    init(
        settings: AppSettings, hotKeys: HotKeyManager, injector: TextInjector,
        settingsCoordinator: SettingsCoordinator, core: AppCore,
        audioDucker: DictationAudioDucker = DictationAudioDucker()
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.injector = injector
        self.settingsCoordinator = settingsCoordinator
        self.core = core
        self.audioDucker = audioDucker
        panel.onAccept = { [weak self] in self?.accept() }
        panel.onCancel = { [weak self] in self?.cancel() }
        capture.onLevels = { [weak self] levels in
            guard let self else { return }
            panel.state.levels = levels
            if pendingStartCue == token { playStartCue() }
        }
        capture.onLimit = { [weak self] in self?.accept() }
    }

    var isEnabled: Bool { settings.dictationEnabled }

    // MARK: - Feature switch

    /// The switch funnels here, because turning it on is consent to the microphone.
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            enableTask?.cancel()
            enableTask = nil
            guard settings.dictationEnabled else { return }
            settings.dictationEnabled = false
            return
        }
        guard !settings.dictationEnabled, enableTask == nil else { return }
        NSApp.activateOverFrontmost()
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { enableTask = nil }
            guard
                await core.confirm(
                    title: "Enable Dictation?",
                    message:
                        "Blitz records from your microphone only while you dictate, and transcribes "
                        + "on this Mac with Apple’s speech model. Audio stays in memory and is never "
                        + "saved or sent anywhere. Typing the text into other apps uses Accessibility.",
                    symbol: "mic", confirmTitle: "Continue", tone: .neutral, confirmRole: .standard),
                !Task.isCancelled
            else { return }
            guard await Permissions.requestMicrophoneAccess(), !Task.isCancelled else {
                core.showMessage("Allow Blitz to use the microphone in System Settings", tone: .danger)
                return
            }
            // The flag is consent, so it is written only once macOS has actually granted access.
            settings.dictationEnabled = true
            if settings.dictationDestination.pastes { Permissions.ensureAccessibility() }
        }
    }

    /// Run from `AppCore`'s settings sink, so settings.json and Settings take the same path.
    func applyEnabled() {
        hotKeys.dictationEnabled = settings.dictationEnabled
        applyMode()
        if settings.dictationEnabled {
            refreshLanguage()
        } else {
            cancel()
        }
    }

    func applyMode() {
        hotKeys.dictationHoldsToTalk = settings.dictationEnabled && settings.dictationMode == .hold
    }

    /// Why hold to talk would not fire with the binding recorded, or nil when it would.
    var holdShortcutIssue: String? {
        guard let binding = hotKeys.binding(for: .dictation) else { return nil }
        guard binding.supportsHold else {
            return "Hold to talk needs a key combination or a single modifier. Record another shortcut."
        }
        if let owner = hotKeys.conflictOwner(of: binding, excluding: .dictation) {
            return "\(owner) also starts with this key. Record another shortcut."
        }
        return nil
    }

    func showSettings() {
        settingsCoordinator.showSettings(tab: .dictation)
    }

    // MARK: - Language model

    /// Re-reads the transcriber's languages and the chosen one's model, for Settings.
    func refreshLanguage() {
        languageTask?.cancel()
        let choice = settings.dictationLanguage
        languageTask = Task { [weak self] in
            let supported = await DictationTranscriber.supportedLocales()
            let resolved = DictationLanguage.resolve(
                choice: choice, preferred: Locale.preferredLanguages, supported: supported)
            var status = DictationAssetStatus.unsupported
            if let resolved { status = await DictationTranscriber.status(of: resolved) }
            guard let self, !Task.isCancelled else { return }
            supportedLanguages = DictationLanguage.sorted(supported, in: .current)
            resolvedLanguage = resolved
            if !assetStatus.isDownloading || installingLocale != resolved { assetStatus = status }
        }
    }

    /// Settings' Download button; a session runs the same install on demand.
    func downloadLanguage() {
        guard let resolvedLanguage else { return }
        let install = install(resolvedLanguage)
        Task { [weak self] in
            do { try await install.value } catch is CancellationError {
            } catch {
                self?.core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    /// One download per locale at a time; Settings and a session waiting on it share it.
    private func install(_ locale: Locale) -> Task<Void, any Error> {
        if let installTask, installingLocale == locale { return installTask }
        installTask?.cancel()
        installingLocale = locale
        let task = Task { [weak self] in
            defer {
                if let self, installingLocale == locale {
                    installTask = nil
                    installingLocale = nil
                    refreshLanguage()
                }
            }
            guard let request = try await DictationTranscriber.installation(for: locale) else { return }
            let progress = request.progress
            let reporter = Task { [weak self] in
                while !Task.isCancelled {
                    let total = progress.totalUnitCount
                    self?.assetStatus = .downloading(
                        fraction: total > 0 ? progress.fractionCompleted : nil)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }
        installTask = task
        return task
    }

    // MARK: - Sessions

    /// The shortcut's press: starts a session, or in toggle mode finishes the running one.
    func pressed() {
        guard settings.dictationEnabled, phase != .stopping else { return }
        if settings.dictationMode == .hold, hotKeys.binding(for: .dictation)?.supportsHold == false {
            core.showMessage("Hold to talk needs a key combination or a single modifier", tone: .danger)
            return
        }
        guard phase == .idle else {
            if settings.dictationMode == .toggle { finish() }
            return
        }
        begin(target: InjectionTarget.current())
    }

    /// The shortcut coming up, which ends a held session and is ignored in toggle mode.
    func released() {
        guard settings.dictationMode == .hold, field == nil else { return }
        finish()
    }

    /// A hold interrupted by another key or click; a mic button's session is not the shortcut's.
    func holdCancelled() {
        guard field == nil else { return }
        cancel()
    }

    /// A field's own mic: click to start, click to finish, whatever the shortcut's mode or focus.
    func toggle(into editor: any InjectableTextView) {
        guard settings.dictationEnabled, phase != .stopping else { return }
        guard phase == .idle else {
            if field?.editor == ObjectIdentifier(editor) { finish() }
            return
        }
        field = DictationField(editor: ObjectIdentifier(editor))
        begin(target: .ownEditor(editor))
    }

    /// A chat switch or a closed composer ends only the session writing into that editor.
    func cancel(in editor: any InjectableTextView) {
        guard let target = target?.ownEditor, target === editor else { return }
        cancel()
    }

    private func finish() {
        if phase == .starting {
            finishWhenStarted = true
        } else {
            accept()
        }
    }

    private func begin(target: InjectionTarget?) {
        token = UUID()
        let current = token
        phase = .starting
        finishWhenStarted = false
        liveOffset = 0
        liveText = ""
        liveDeliveryFailed = false
        self.target = target
        pendingStartCue = settings.dictationPlaysSounds ? current : nil
        if pendingStartCue == nil { audioDucker.begin() }
        let choice = settings.dictationLanguage
        let microphone = settings.dictationMicrophone
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let locale = await DictationTranscriber.locale(choice: choice) else {
                    throw DictationTranscriber.Failure.unsupportedLanguage
                }
                guard token == current else { return }
                self.locale = locale
                // Downloads while the user speaks, so the model is usually in place by the end.
                if await DictationTranscriber.status(of: locale) != .installed {
                    _ = install(locale)
                }
                try await capture.start(microphoneID: microphone)
                guard token == current, settings.dictationEnabled else {
                    _ = await capture.stop()
                    return
                }
                phase = .listening
                panel.show()
                startLiveInsertion(token: current)
                if finishWhenStarted { accept() }
            } catch {
                guard token == current else { return }
                reset()
                core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    private func playStartCue() {
        pendingStartCue = nil
        let current = token
        cueTask = Task { [weak self] in
            guard let self else { return }
            if capture.isBluetooth { try? await Task.sleep(for: Self.bluetoothSettle) }
            guard token == current, phase == .starting || phase == .listening else { return }
            cues.play(.start)
            audioDucker.begin()
        }
    }

    /// Return, the toggle's second press, a hold's release or the five-minute limit.
    func accept() {
        guard phase == .listening else { return }
        phase = .transcribing
        panel.state.phase = .transcribing
        field?.isTranscribing = true
        if settings.dictationPlaysSounds {
            audioDucker.restoreImmediately()
            cues.play(.stop)
        } else {
            audioDucker.end()
        }
        // A cancelled chunk keeps its audio: the final pass starts at liveOffset, losing nothing.
        let pendingLive = liveTask
        liveTask = nil
        pendingLive?.cancel()
        let current = token
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await pendingLive?.value
            let samples = await capture.stop()
            // Queued chunks land first: a reset would drop them, and the rest spaces after them.
            if !liveText.isEmpty { await injector.drain() }
            guard token == current, let locale else { return }
            let destination = field == nil ? settings.dictationDestination : .paste
            let tail = liveOffset < samples.count ? Array(samples[liveOffset...]) : []
            guard tail.count >= DictationAudioChunks.minimumSpeechSamples else {
                finishWithoutRemainder(destination)
                return
            }
            do {
                // Polled, not awaited: a download outlives a cancel, which must not wait for it.
                while installTask != nil { try await Task.sleep(for: .milliseconds(100)) }
                let transcript = try await DictationTranscriber.transcribe(tail, locale: locale)
                guard token == current else { return }
                deliver(transcript, to: destination, token: current)
            } catch {
                guard token == current else { return }
                reset(cancelTranscription: false)
                if !(error is CancellationError) {
                    core.showMessage(error.localizedDescription, tone: .danger)
                }
            }
        }
    }

    private func deliver(_ transcript: String, to destination: DictationDestination, token current: UUID) {
        let context = destination.pastes ? insertionContext() : nil
        let text = DictationTextFormatter.format(
            transcript, context: context, adaptCapitalization: settings.dictationAdaptsCapitalization)
        guard !text.isEmpty else {
            finishWithoutRemainder(destination)
            return
        }
        let assembled = liveText + text
        panel.close()
        guard destination.pastes else {
            Paster.copyPlainText(text)
            reset(cancelTranscription: false)
            return
        }
        injector.deliver(
            InjectedText(text), target: target, expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil,
            isValid: { [weak self] in self?.token == current },
            onDelivered: { [weak self] in
                guard let self, token == current else { return }
                let lost = liveDeliveryFailed
                if destination.copies { Paster.copyPlainText(assembled) }
                reset(cancelTranscription: false)
                if lost { core.showMessage("Couldn’t paste some dictation into this app", tone: .danger) }
            },
            onFailed: { [weak self] in
                guard let self, token == current else { return }
                reset(cancelTranscription: false)
                if destination.copies { Paster.copyPlainText(assembled) }
                core.showMessage("Couldn’t paste dictation into this app", tone: .danger)
            })
    }

    private func finishWithoutRemainder(_ destination: DictationDestination) {
        let text = liveText
        let lost = liveDeliveryFailed
        reset(cancelTranscription: false)
        guard !text.isEmpty else {
            core.showMessage("No speech was recorded", tone: .danger)
            return
        }
        if destination.copies { Paster.copyPlainText(text) }
        if lost, destination.pastes {
            core.showMessage("Couldn’t paste some dictation into this app", tone: .danger)
        }
    }

    /// Spacing from the caret, else from the text already pasted, so chunks never glue together.
    private func insertionContext() -> DictationTextFormatter.Context? {
        if let context = DictationInsertionContext.read(in: target) { return context }
        guard !liveText.isEmpty else { return nil }
        return DictationTextFormatter.Context(before: liveText.suffix(512), after: Substring())
    }

    // MARK: - Live insertion

    private func startLiveInsertion(token current: UUID) {
        let pastes = field == nil ? settings.dictationDestination.pastes : true
        guard pastes, settings.dictationLiveInsertion else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveInterval)
                guard let self, !Task.isCancelled, token == current, phase == .listening,
                    settings.dictationLiveInsertion
                else { return }
                await flushLiveChunk(token: current)
            }
        }
    }

    private func flushLiveChunk(token current: UUID) async {
        let snapshot = capture.snapshot()
        guard let locale, token == current else { return }
        let fresh = snapshot.count - liveOffset
        guard fresh >= DictationAudioChunks.minimumLiveSamples,
            fresh >= DictationAudioChunks.maximumLiveSamples
                || DictationAudioChunks.endsInPause(in: snapshot, from: liveOffset, to: snapshot.count)
        else { return }
        let end = DictationAudioChunks.liveCut(in: snapshot, from: liveOffset, to: snapshot.count)
        guard end > liveOffset else { return }
        let overlap = DictationAudioChunks.liveOverlapStart(in: snapshot, before: liveOffset)
        let segment = Array(snapshot[overlap..<end])
        // A failed or cancelled chunk leaves liveOffset alone, so the final pass covers its audio.
        guard installTask == nil,
            let transcript = try? await DictationTranscriber.transcribe(segment, locale: locale),
            token == current
        else { return }
        liveOffset = end
        let text = DictationTextFormatter.format(
            transcript, context: insertionContext(),
            adaptCapitalization: settings.dictationAdaptsCapitalization)
        let stripped = DictationTextFormatter.stripEcho(text, after: liveText)
        guard !stripped.isEmpty else { return }
        liveText += stripped
        injector.deliver(
            InjectedText(stripped), target: target, expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil,
            isValid: { [weak self] in self?.token == current },
            onFailed: { [weak self] in
                guard let self, token == current else { return }
                liveDeliveryFailed = true
            })
    }

    // MARK: - Teardown

    /// Escape, a hold interrupted, the feature switched off: nothing recorded is inserted.
    func cancel() {
        guard phase != .stopping, phase != .idle else { return }
        let pendingStart = startTask
        let pendingTranscription = transcriptionTask
        let pendingLive = liveTask
        reset()
        phase = .stopping
        let current = token
        stopTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            _ = await capture.stop()
            await pendingTranscription?.value
            await pendingLive?.value
            if token == current {
                phase = .idle
                stopTask = nil
            }
        }
    }

    /// A ducked volume must not outlive the app.
    func prepareForTermination() {
        enableTask?.cancel()
        installTask?.cancel()
        languageTask?.cancel()
        cancel()
        cueTask?.cancel()
        audioDucker.restoreImmediately()
    }

    /// Puts back a volume a crash left ducked; runs at launch whether or not Dictation is on.
    func recoverVolume() {
        audioDucker.recover()
    }

    private func reset(cancelTranscription: Bool = true) {
        token = UUID()
        if cancelTranscription { transcriptionTask?.cancel() }
        liveTask?.cancel()
        liveTask = nil
        liveOffset = 0
        liveText = ""
        liveDeliveryFailed = false
        startTask = nil
        transcriptionTask = nil
        pendingStartCue = nil
        phase = .idle
        target = nil
        locale = nil
        field = nil
        panel.close()
        audioDucker.end()
    }
}

/// Which editor a mic session belongs to, so only that field's button shows it running.
struct DictationField: Equatable {
    let editor: ObjectIdentifier
    var isTranscribing = false
}
