# Architecture

How Blitz is wired together. Per-feature internals live in [features/](README.md#features);
conventions for writing new code live in [standards.md](standards.md).

## The layering

Independently of the folder tree, every mature subsystem follows the same four layers, and the
`Tests/` harnesses are what hold them apart.

```
┌─ PURE ─────────────────────────────────────────────────────────────────────┐
│ No AppKit, SwiftUI or Cocoa: the layer that decides, never presents.       │
│ ⇒ Compiled verbatim by a harness, so it cannot drift.                      │
│                                                                            │
│ SearchRelevance · LauncherMatch · EntryNaming · ScriptRomanization ·       │
│ LauncherOrder · LauncherSuggestions · LauncherRankingStore ·               │
│ SearchScopes · LauncherQueryHistory{,Store} ·                              │
│ FileSearch{Query,Result,Scope} · Screenshot{Query,File,TextStore} ·        │
│ Calculator/* · EmojiCatalog · EmojiGridGeometry · SystemAction ·           │
│ VolumeLevel ·                                                              │
│ WindowCommand · WindowPlacementEngine · WindowActionMemory ·               │
│ WindowLayout/* · CustomWindowSize{,Store} · Room/* ·                       │
│ PaletteRowIndex ·                                                          │
│ Uninstall{Target,SearchRoot,Rules,Protection,Plan} ·                       │
│ Quicklink{,Destination,Favicon,Store,Archive} · AppleShortcut ·            │
│ Notes/Model/* · Snippets/Model/* ·                                         │
│ ShellCommandRunner · DoubleTap{Modifier,Detector} · ClipboardStore ·       │
│ RaycastDecoder · Scrypt · AppSettingsKey · SettingsBackupCoverage          │
│ SettingsFile{JSON,Key,Value,Format,Binding,Issue,Identity} ·               │
│ HotKeySpelling · WindowManagementFileFormat ·                              │
│ MeetingLink · MeetingEvent · UpcomingWindow · MeetingDay · MenuBarSummary  │
│ AutoJoinPolicy · EventDraft · SupportReminderSchedule ·                    │
│ Reminders/Model/* · Contacts/Model/* ·                                     │
│ MenuSearch{Item,Shortcut,Query,Target} · MenuTreeNode ·                    │
│ MenuSnapshotPolicy ·                                                       │
│ WindowSwitch{Entry,Order,Query}                                            │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │ consumed by
┌─ EFFECT ─────────────────────────▼─────────────────────────────────────────┐
│ All platform I/O, one folder per feature.                                  │
│ AppIndex · FileSearchService · ScreenshotService · ScreenshotIndexer ·     │
│ SettingsPaneScanner ·                                                      │
│ AXWindowAccess · AXScreens · WindowInventory · WindowLayoutRunner ·        │
│ RoomWindowSweep · RoomRunner ·                                             │
│ IconCache · WindowMover · UninstallScanner · UninstallRunner ·             │
│ SystemActionRunner · QuicklinkLauncher · TextInjector ·                    │
│ SnippetKeywordListener · NotesRepository · CurrencyRateStore · Paster ·    │
│ HotKeyCenter · HyperKeyTap · ModifierTapMonitor · RunningAppsMonitor ·     │
│ CalendarStore · MeetingLauncher · MeetingClock · CameraSession ·           │
│ RemindersStore · ReminderLauncher · SmartReminderRunner ·                  │
│ ContactsStore · ContactLauncher ·                                          │
│ SupportReminderStore · AXMenuAccess · WindowZOrder · WindowSwitchSweep ·   │
│ AppleShortcutRunner · SettingsFileRepository · SettingsFileMonitor ·       │
│ WindowManagementSettingsFile                                               │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │ published through
┌─ OBSERVABLE STATE ───────────────▼─────────────────────────────────────────┐
│ @MainActor @Observable stores, sessions, indices and State types           │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │ rendered by
┌─ VIEW ───────────────────────────▼─────────────────────────────────────────┐
│ SwiftUI screens, views and each feature's coordinator — declarative, thin  │
└────────────────────────────────────────────────────────────────────────────┘
```

In the folder tree those become `Model/`, `Service/`, and `UI/` plus `Settings/` — observable state lives
in whichever of the two owns it.

- **`Model/` — pure.** No AppKit, SwiftUI or Cocoa; Foundation and whatever lower framework the data
  needs (SQLite3, CoreGraphics, Carbon's key codes, CryptoKit). Where a harness has to control an
  environment fact, it is **injected**: `CalcEngine` takes `now` / `calendar` / `rates`,
  `LauncherRankingStore` takes `now` and its file URL, `WindowActionMemory` takes `now` as a parameter,
  `UninstallRules` is handed directory *names* rather than URLs, and `QuicklinkStore` is handed the home
  directory. This is the layer that **decides** things.
- **`Service/` — effects.** Stores, monitors, runners, scanners and AppKit glue. Every `AXUIElement`
  call, `CGEventTap`, `NSWorkspace.open`, `URLSession` request, `FileManager` walk and CoreAudio read
  lives here. This is the layer that **does** things.
- **`UI/` and `Settings/` — views**, plus the feature's coordinator. Declarative, thin, holding no policy.

The rule is checkable, which is the point: **a file under `Model/` may not import AppKit, SwiftUI or
Cocoa**,
because the harnesses compile the shipped sources rather than a copy. A harness that stops compiling is
the signal that a decision leaked into the effect layer, or an effect into the decision layer.

The boundary keeps effects out of decisions: `CalcEngine.evaluate` is handed a finished
`CurrencyRates?` rather than reaching for one, which is what keeps it pure and testable.
Confirmation gates live in the coordinator, never in the runner — which is why `ShellCommandRunner`
and `SystemActionRunner` stay harness-compilable while the "are you sure?" step still cannot be bypassed.

Two things sit deliberately outside a feature folder: `Features/PaletteRowIndex.swift`, because the
palette rather than any one feature owns the flat selection index, and `DesignSystem/` + `Platform/`,
the shared primitives and system shims every feature draws on. Neither may depend on a feature.

## Single-owner core

`AppCore.shared` (`App/AppCore.swift`) is a `@MainActor` singleton owning every long-lived thing in the
app: the stores (`AppIndex`, `ClipboardStore`, `SnippetsStore`, `QuicklinkStore`, `CustomCommandStore`,
`FavoritesStore`, `VisibilityStore`, `AliasStore`, `LauncherRankingStore`, `LauncherQueryHistoryStore`,
`CalculatorHistoryStore`,
`CurrencyRateStore`, `FrequentEmojiStore`, `CalendarStore`, `RemindersStore`, `ContactsStore`), the
managers, monitors and clocks (`ClipboardManager`, the opt-in `ClipboardTextIndexer` and
`ScreenshotIndexer`, the opt-in `SettingsFileRepository`,
`HotKeyManager`, `HyperKeyTap`, `RunningAppsMonitor`, `SnippetKeywordListener`), the shared state
(`AppSettings`, `PaletteState`, `FileSearchSession`, `MenuSearchSession`, `UninstallSession`,
`MeetingClock`), `NotesStore`, every feature's coordinator, and the window controllers.

`AppDelegate.applicationDidFinishLaunching` calls `AppCore.shared.start()` and nothing else. That is the
one wiring point, and `start()` reads as the app's whole boot sequence in one screen.

**Feature actions live on that feature's coordinator, and a view must never reach past a coordinator
into a store to mutate it.** That is the rule; `AppCore` holds only the closure wiring that connects a
hotkey to a coordinator. Views inject `AppCore` through `@Environment` and use it as the *locator* for
those coordinators — `core.quicklinkCoordinator.deleteQuicklink(…)` is the shape, and the alternative
is injecting every coordinator separately for no gain. Reading a store off `AppCore` to render it is
fine too; deciding something with one is what the rule forbids. `showNotice`, `confirm`,
`reportFailure`, `showMessage` and `pickVolume` are forwarders on `AppCore` itself, so
`DialogController` and `MessageHUDController` stay single-owned.

New long-lived state belongs on `AppCore`, wired in `start()`. Do not create a competing singleton: this is a singleton, not a container.

Text recognition — the clipboard's and Search Screenshots' — is the one thing that leaves the
process. `AppCore` owns both indexers;
the stateless `ClipboardTextWorker` runs one bundled `ClipboardTextHelper` per item, from
`Contents/Helpers`, and reaps it before returning. Vision's and PDFKit's allocations therefore belong
to a process that exits, and the helper — which has no database, clipboard or settings access — is
handed an input path and answers with bounded text down a pipe.

## Entry points and windows

`BlitzApp` (`@main`) declares only two `MenuBarExtra` scenes — Blitz's own item and the
calendar's, each inserted by one preference and independent of the other; everything else visible is
driven imperatively from AppKit. Extension menu extras are dynamic `NSStatusItem`s owned entirely by
`Features/Extensions/`, through `ExtensionManager`, with no scene or lifecycle wiring in the core.

- **Command palette** — a borderless floating `NSPanel` (`Palette/PalettePanel.swift`) hosting SwiftUI
  via `NSHostingView`, managed by `PaletteWindowController`. It toggles between a compact bar and the
  full launcher by resizing the window. The controller **solely** owns the frame, resolved once per show
  to a top-left anchor so it grows downward, and the hosting view sets `sizingOptions = []` so SwiftUI
  never drives the window size — without that the hosting view resizes the panel to fit content and the
  top edge drifts on the compact↔expanded swap. The panel auto-dismisses on `windowDidResignKey`,
  unless a modal panel holds key.
  See [features/palette.md](features/palette.md).
- **Settings and Onboarding** — titled `NSWindow`s, one `Windows/AppWindowController.swift` each, owned
  by `SettingsCoordinator` and `OnboardingCoordinator`. SwiftUI `Settings` and `Window` scenes are
  unreliable for accessory apps, so this is deliberate. Their lifecycles are independent of the
  palette's in both directions. Onboarding opens by itself once, on first launch; the Show Welcome
  Tour command and Settings ▸ General ▸ Welcome Tour reopen it through `showOnboarding()`.
  Settings is the one window **hidden rather than torn down on close** (`keepsContentWhenClosed`):
  rebuilding its split, sidebar and toolbar costs ~200 ms per open, so a reopen keeps them and only
  restarts the session. `SettingsCoordinator.showSettings` calls
  `SettingsNavigationState.restart(on:page:revealing:)` with the pane the caller asked for, or the
  one the window was closed on when it names none; that starts a fresh history on that pane and bumps
  `session`, which clears the sidebar's search and remounts the pane so its appear-time refreshes
  still run. Editor panels are dismissed on close, and Quit from the Dock still closes it outright.
- **Notes** — a persistent, titled, non-activating `NotesPanel` managed by `NotesWindowController`.
  The user owns its size and AppKit autosaves the frame; its TextKit 2 editor renders Markdown over the
  literal source, switches among local Markdown files and stays visible on focus loss. The displayed
  string is the canonical file source; there is no source/display mapping.
  See [features/notes.md](features/notes.md).
- **AI Chat** — a titled `AppWindowController` window owned by `AIChatCoordinator`: an
  `NSSplitViewController` with a collapsible sidebar of saved chats beside the open conversation, as
  Settings is built. The conversation lives on `AppCore.aiChats`, not the window, so closing it cancels
  nothing. Quick AI is the same feature's palette screen. See [features/ai.md](features/ai.md).
- **The main menu** — shaped by `BlitzApp`'s `.commands`, which rebinds ⌘Q to Close Window: the AI
  Chat window when it is key, otherwise Settings. It is only ever on screen while a titled window is
  open, so it is those windows' menu bar. It must stay declarative.
- **Dialogs** — borderless `DialogPanel`s driven by `DialogController`, the app's only presenter for
  confirmations, failure reports and value prompts. Presentation is `async`, so nothing blocks the main
  actor, and the presenter refuses a second dialog while one is up — that, not a flag, is what stops a
  held hotkey stacking dialogs. Click-away dismisses; the draft forms' kept edits live on
  `DialogController` too, in one `FormDraftMemory` per form. See [ui.md](ui.md#dialogs--hud).
- **Support** — a titled `AppWindowController` window owned by `SupportCoordinator`, sized to the
  height its content measured. Every route into it — the palette's menu circle, Settings → About, the
  menu bar, the launcher, and the 30-day reminder — lands on `showSupport()`, which is what moves the
  reminder's anchor. See [features/support.md](features/support.md).
- **Terminal windows** — one titled `AppWindowController` window per custom-command terminal run,
  each owned by its own `CommandTerminalPresenter` together with the SwiftTerm view and the pty
  session behind it. `CustomCommandCoordinator` keeps the open presenters as a list, oldest first;
  a new window cascades off the newest, a Dock click raises it, and closing one hangs up its shell
  and drops it from the list. See
  [features/custom-commands.md](features/custom-commands.md#open-in-terminal).
- **The camera surfaces** — a borderless, non-activating `CameraPanel` at `.floating`, in two
  shapes over one `CameraSession`: `CameraPreviewController`, owned by `CalendarCoordinator`, gates a
  join and doubles as auto join's confirmation; `CameraCoordinator`, owned by `AppCore`, is the
  standalone `Open Camera` command. See [features/camera.md](features/camera.md) and
  [features/calendar.md](features/calendar.md).
- **HUDs** are separate, because a dialog asks and a HUD reports: `MessageHUDController` (the pill) and
  `VolumeHUDController` (the level box), both over a shared `HUDPresenter` that owns the
  one-at-a-time, auto-dismiss and fade policy. See [ui.md](ui.md#dialogs--hud).

`NSAlert` is never used, and that is load-bearing. Appearance is a setting: `AppCore.applyAppearance()`
assigns `NSApp.appearance` from `AppSettings.appearance`, and `.system` assigns `nil` so AppKit follows
macOS by itself. Nothing else in the app sets an appearance.

## Observation and concurrency

State lives in `@MainActor @Observable` types — the stores, sessions, indices and `State` types
`AppCore` owns — and views read it through `@Environment`. Each hosting view is handed `AppCore` and
the shared state it reads by one environment modifier per surface (`paletteEnvironment`,
`settingsEnvironment`), and `AppCore` reacts to a settings change outside a view through
`AppCore.track`. Off-main work leaves through `nonisolated` functions driven by `Task.detached` and
comes back as `Sendable` values. The rules for both — the Observation gotchas, when an `actor` is
allowed, the main-thread idioms — live in
[standards.md](standards.md#concurrency-and-lifetime).

## The tree

The folder layout is the layering above, made navigable — one folder per feature, each holding
everything that feature owns.

```
Blitz/
  App/              @main, AppDelegate, AppCore — the composition root
  DesignSystem/     Theme (the token source), InterfaceMetrics, KeyCapChip, BarButton, Tooltip,
                    SymbolImage, GlassEffectView, PopoverMenu, SettingsComponents, Scrolling/,
                    Interaction/
  Platform/         system shims: Permissions, LaunchAtLogin, InputSourceSwitcher, ScreenTarget,
                    AppDisplayName, SymbolicHotKeys, NotificationToken, AppPaths, Signposts,
                    HealthTicker, Memo, ActivationPolicy, ProcessExit, Images/, Compression/
  Resources/        RaycastRuntime.generated.js (the embedded extension runtime), EmojiKeywords/
  Palette/          the palette shell: PalettePanel, PaletteWindowController, RootPaletteView,
                    the PaletteScreen protocol, PaletteCoordinator, PaletteState, PaletteMode,
                    MenuPanel, EmptyResults, armedHover
  Windows/          the non-palette AppKit surfaces: AppWindowController, Dialog/, HUD/, About/
  Assets.xcassets/  the app icon and the bundled image sets some catalog symbols resolve to
  Features/
    PaletteRowIndex.swift   the flat selection index and its section/page maths — palette-owned
    Launcher/ Clipboard/ Calculator/ Calendar/ Reminders/ Contacts/ Camera/ Emoji/ Dictionary/
    FileSearch/ Screenshots/ MenuSearch/ WindowSwitcher/ Notes/ Quicklinks/ Snippets/
    AppleShortcuts/ Uninstall/ SystemActions/ CustomCommands/ HotKeys/ TextInjection/
    WindowManagement/ AI/ QuickActions/ MCP/ Backup/ Onboarding/ Updates/ Support/ Settings/
    Extensions/
        Model/      pure — the harness inputs
        Service/    effects — stores, monitors, runners, AppKit glue
        UI/         screens, views, and the feature's coordinator
        Settings/   the feature's own panes
    Settings/       the Settings shell only: SettingsCoordinator, the root/sidebar/detail views, the chrome,
                    navigation types, SettingsTab, AppSettings, AppSettingsKey, the settings file
                    (Model/, Service/, SettingsFileSchema), and Panes/ for the panes no feature
                    owns
Tests/              the standalone harnesses, one Swift file each
Scripts/            run-tests.sh, lint.sh, format.sh, the three gen-*.js data generators,
                    raycast-runtime/ (the extension runtime build), release signing checks,
                    sync-lsp.sh
```

A feature splits into the sub-folders it has something for; a small one may stay flat until the flat
folder stops being scannable. `Onboarding/` has no `Settings/` because its tour is its own window.

Every `SettingsTab` maps to one `…SettingsView`, and each is a stock `Form` with
`.formStyle(.grouped)` — see [ui.md](ui.md#settings). A pane lives with its feature; only a pane no
feature owns (General, Appearance, Navigation, Permissions) lives in `Settings/Panes/`. The four
launcher-category panes — Applications, System Settings, System Actions, Commands — are thin wrappers
over the shared `LauncherItemsSection`; Apple Shortcuts pairs its feature switch with the same
`LauncherItemsList`.

`SettingsTab` and `SettingsSection` both identify by the case itself, never by an index. A selectable
`List` flattens section and row IDs into one namespace, so overlapping `Int` IDs make SwiftUI drop
whole sidebar groups; `Tests/settings-history-test.swift` pins the two namespaces apart.
