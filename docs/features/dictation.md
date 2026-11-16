# Dictation

Dictation is off by default. A global shortcut records from the chosen microphone, transcribes on
this Mac with Apple's `SpeechAnalyzer` and `SpeechTranscriber` (macOS 26's Speech framework), and
sends the text through [`TextInjector`](text-injection.md). The AI Agent window's composer has a mic
of its own that dictates into that field. The design and UX are ported from Tinycast's Dictation;
its transcription pipeline — an embedded helper app, downloaded Core ML models and the IPC to them —
is replaced outright by the system's on-device speech model.

`Features/Dictation/` holds:

| Folder | Holds |
| --- | --- |
| `Model/` | `DictationMode`, `DictationDestination`, `DictationTextFormatter` (spacing and capitalization from the caret), `DictationAudioChunks` (live-insertion cuts), `DictationVolumeSnapshot` (the ducking record), `DictationLanguage` (locale choice), `DictationAssetStatus` |
| `Service/` | `DictationCapture` (the microphone), `DictationTranscriber` (SpeechAnalyzer and its assets), `DictationAudioDucker`, `DictationSpectrum`, `DictationCueRunner`, `DictationInsertionContext` |
| `UI/` | `DictationCoordinator`, `DictationPanel` (the recording capsule and its controller) |
| `Settings/` | `DictationSettingsView` |

## Invariants

- **`AppCore` owns `DictationCoordinator`, and only it.** The microphone session, the panel and the
  injection target belong to the coordinator; launching Blitz or opening Settings records nothing.
  A view reaches it as `core.dictationCoordinator`.
- **The switch is consent.** `dictationEnabled` is written only by
  `DictationCoordinator.setEnabled`, after Blitz's own dialog has explained the microphone and
  Accessibility and macOS has granted the microphone. It is in
  `SettingsBackupCoverage.deliberatelyExcluded` and has no settings.json key, so neither an import
  nor a file can arm a recording shortcut. The chosen microphone stays out of both too, as machine
  state. The other preferences — mode, language, destination, sounds, live insertion, capitalization
  — are ordinary and travel in both.
- **Microphone status is read, never prompted on display.** The Permissions pane and the Dictation
  pane show it; only a user action asks (`Permissions.requestMicrophoneAccess`). Speech recognition
  authorization is not needed: `SpeechTranscriber` runs on device and works with
  `SFSpeechRecognizer.authorizationStatus()` still `.notDetermined`, so Blitz declares only
  `NSMicrophoneUsageDescription` and `com.apple.security.device.audio-input`.
- **`HotKeyAction.dictation` uses the shared recorder and conflict rules.** Toggle mode accepts any
  binding; hold to talk accepts a Carbon chord or one physical modifier, Globe included (see
  [hotkeys.md](hotkeys.md#hold-to-talk)). Carbon's key-up or the modifier tap's release ends a held
  recording; another key, modifier or click cancels it and inserts nothing. A double tap needs toggle
  mode, and Settings says why a recorded binding cannot hold.
- **A session token guards every insertion.** Each session gets a fresh `UUID`; cancelling or
  superseding one replaces it, and every queued delivery checks it again through `TextInjector`'s
  `isValid` when its turn comes, so a cancelled run can never type text later.
- **Return finishes, Escape cancels.** The capsule is a nonactivating panel that becomes key, so
  the app being dictated into stays active and the two keys reach Blitz. The modifier tap ignores
  both during an active hold.
- **Insertion is `TextInjector`'s, whole.** The target is resolved at the press
  (`InjectionTarget.current()`), and delivery reuses the injector's temporary pasteboard loan, focus,
  Secure Input and own-bundle checks. Copy-only writes the plain transcript without reading the
  caret; paste-and-copy writes the persistent copy after delivery, or after a failed one.
- **Spacing and capitalization follow the caret, and never guess.** `DictationInsertionContext`
  reads the text either side of the caret from our own editor or over Accessibility;
  `DictationTextFormatter` decides from it. An app that exposes no caret gets the plain transcript.
  Capitalization can be switched off without losing the spacing.
- **Audio never leaves memory.** Mono 16 kHz Float32, capped at five minutes (the limit finishes the
  recording); nothing is written to disk or sent anywhere, and the speech model runs on device.
- **The language model is fetched on demand.** `DictationTranscriber` reserves the chosen locale
  with `AssetInventory` and runs its installation request; Settings shows the state and a Download
  button with progress, and a session that starts without the model starts the download at once and
  waits for it before transcribing. Reserved locales are capped by macOS, so switching language
  releases the oldest reservation first.
- **Live insertion is off by default.** While on, every two seconds the coordinator looks for a
  pause, or eight seconds of unbroken speech, cuts near the quietest moment, re-transcribes a
  two-second overlap anchored on a quiet spot and drops the repeated words
  (`DictationTextFormatter.stripEcho`). Chunks paste in order; finishing waits for them
  (`TextInjector.drain()`) and then transcribes only the remainder. Pasted text is never revised. A
  chunk that fails to paste is reported once at the end. A copy-only session never runs the loop.
- **The composer's mic always toggles into its own field.** `toggle(into:)` targets the composer's
  `ComposerTextView` in process whatever has focus; its transcript is inserted whatever the
  destination says, never copied. A chat switch or a closed composer cancels only the session
  writing into that editor (`cancel(in:)`), and a hold cancellation never ends a mic session.
- **Ducking is crash-safe.** The default output fades to a tenth from the press (or from the start
  cue when sounds are on) and back at the end, on cancel and on quit. Before each fade step a
  bundle-ID Application Support file records the device, the original volume and the values Blitz set;
  at launch `recoverVolume()` puts a matching device back, whether or not Dictation is on. A volume
  the user moved meanwhile is never overwritten; an unplugged device keeps its record and blocks new
  ducking until it is back.
- **Sounds are macOS's own.** With Play sounds on, `dt-begin.caf` plays on the microphone's first
  samples (half a second later for a Bluetooth headset, which drops output while it switches) and
  `dt-confirm.caf` when the recording stops; cancelling is silent. They are undocumented resources of
  `AssistantServices.framework`, and a missing one is skipped.
- **The capsule is Liquid Glass, and stops when hidden.** 21 logarithmic bands, 32–5000 Hz, at most
  twenty updates a second from a reused 512-point Accelerate transform on the capture queue;
  transcribing swaps them for a sweeping wave that Reduce Motion pauses. Closing drops the hosting
  view.
- **`Model/` imports Foundation only**, and `dictation-test` compiles it with the ducker.

## Deviations from Tinycast

- **No helper process, models or downloader.** `SpeechTranscriber` replaces Parakeet and Qwen, so the
  Engine and Model pickers, idle release, the helper's pipes and the model store are gone. The
  language picker lists `SpeechTranscriber.supportedLocales`; *System* resolves to the first
  preferred language the transcriber covers.
- **No long-recording split.** `SpeechAnalyzer` takes a five-minute buffer in one pass.
- **No launcher command.** Tinycast has none either; `blitz://run/dictation` presses the shortcut.
- **No 🎤-key remap.** Tinycast's dictation key (F20) is out of scope.

## Testing

`dictation-test` covers the formatter, echo stripping, chunk cuts and pause detection on synthetic
audio, the options' persisted spellings, locale resolution, the volume record, and the ducker's
fade, crash recovery, user override and unplugged device against injected outputs and a private
file — it never touches the real volume or the microphone. `settings-backup-test` and
`settings-file-test` pin the consent flag out of both. The hold bindings are `hotkey-test`'s.

Manual, since nothing here can speak into a microphone: enabling (dialog, microphone grant and
denial), toggle and hold (chord, Right Option, Globe), Return and Escape, each destination, live
insertion on and off, spacing and capitalization against text around the caret in a native field,
Chromium and our own editors, a language whose model is not yet downloaded (Settings progress, and a
first dictation that waits for it), sounds with speakers and a Bluetooth headset, ducking and its
recovery after a forced quit mid-recording, and the composer mic (switching chats mid-session).
