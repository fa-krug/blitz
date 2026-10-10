# Settings

The Settings window's shell: its panes and sidebar, the history behind Back and Forward, search
across every pane and row, the editor panels and the questions a pane asks. What each pane *sets*
belongs to its feature's own doc; the opt-in `settings.json` mirror is
[settings-file.md](settings-file.md), and how a pane looks is [ui.md](../ui.md#settings).

## Invariants

- **`SettingsTab` is the list of panes, and `SettingsSection.tabs` is their order.** The sidebar,
  the detail switch, the search catalog and `settings-history-test`'s coverage check all read it,
  so a pane added to the enum and missed anywhere else fails to compile or fails the harness.
- **`SettingsTab.ownedCommands` is the only place that says which pane lists a command.**
  `CommandID.owner` inverts it once and `CommandCatalog.makeEntry` stamps it onto
  `AppEntry.settingsOwner`; a command no pane names belongs to Settings › Commands. See
  [launcher.md](launcher.md#pane-owned-commands).
- **History belongs to one window session, never to `AppCore`.** `SettingsNavigationState` is
  created with the window and restarted on every reopen, so Back never reaches a pane from a
  previous session. A reopen with no tab asked for restarts on the pane the window was closed on.
- **Every search result has somewhere to land.** A `Form` cannot be asked what rows it holds, so
  `SettingsSearchCatalog` is hand-written against `SettingsAnchor`s, and
  `Scripts/check-settings-search.js` — run by `Scripts/lint.sh` — fails when an anchor has no section
  or a row entry has no `SettingsRowTitle` marking it. Add the entry and its marker together.
- **A pane's question goes through Blitz's dialog.** Confirmations are `await core.confirm(…)` with
  the subject's own glyph, and a refusal is reported the same way — never a SwiftUI `.alert` or
  `.confirmationDialog`, which would draw a system sheet over the window.
- **No editor outlives the window.** Closing Settings — its close button or ⌘Q — hides the window
  and `SettingsEditorPresenter.dismissAll()` takes every open panel down with it.

## The window

`SettingsCoordinator` (owned by `AppCore`) keeps one `AppWindowController` with
`keepsContentWhenClosed`, so closing hides the window and reopening reuses its view tree.
`showSettings(tab:page:revealing:)` has three cases:

| The window is | A request with a tab | A request with none |
| --- | --- | --- |
| open | navigates there, as one step Back can undo | raises it, on whatever it shows |
| closed but built | restarts the session on that tab | restarts on the pane it was closed on |
| never built | builds it on that tab | builds it on General |

A restart bumps `SettingsNavigationState.session`, which keys `SettingsDetailView`'s `.id`, so the
pane remounts and its appear-time reads run again — the Permissions pane shows a grant made while
the window was closed. Settings has its own lifecycle: neither the palette nor Settings opens or
closes the other.

`SettingsRootView` is a `NavigationSplitView`: `SettingsSidebarView` on the left,
`SettingsDetailView` switching on the current tab on the right, and Back / Forward chevrons beside
the pane's title in the toolbar.

## Navigation

`SettingsLocation` is a pane plus an optional `page` string that only that pane interprets — an
extension's manifest name, a launcher entry's id, a quicklink's UUID. `SettingsHistory` keeps
browser semantics over locations: selecting truncates what was ahead, re-selecting the current
location is no move, and Back and Forward clamp at both ends. Choosing a pane in the sidebar lands
on its root.

A pane with pages wraps itself in `SettingsPagedPane` (`SettingsPages.swift`), which shows the list
or the page and scrolls the list back to the row it left on Back. Long lists draw read-only rows
through `SettingsPageRows`, each showing what its page sets as `SettingsEntryBadges`. Configure
Command in the launcher's ⌘K menu opens a row's page directly, through `AppEntry.settingsPage`.

## Search

The sidebar's `.searchable` field swaps the pane list for ranked results from
`SettingsSearchCatalog.results(for:)`: every term must hit an entry's title, its
`Pane › Section` breadcrumb or a keyword; a title hit outranks the rest, and a pane outranks its own
rows. An entry is `.init(anchor, title)` for one row, `.init(group:_:)` for a section no single row
answers, and `.init(pane:)` for the pane itself.

`SettingsAnchor` names one section once (`<pane><Section>`, e.g. `.generalSearch`), and an entry
takes its pane from the anchor, so a row filed under the wrong pane cannot be written. Picking a
result is an ordinary `SettingsNavigationState.select(_:page:revealing:)`: the pane's
`.settingsScrollTarget(_:)` (`SettingsScrollTarget.swift`) scrolls the target to centre and pulses
the matched name once. A long list marks its section with `.settingsFilterSeed`, so a result naming
a row that a lazy stack has not built yet narrows the list's filter onto it.

## Editor panels

`SettingsEditorPresenter` is one stack per window. `.settingsEditorPanel(isPresented:)` and
`.settingsEditorPanel(item:)` present a pane's editor in an activating, transparent child `NSPanel`
over a dimming blocker that covers the parent, titlebar included; the presenting binding stays the
source of truth for dismissal. `settingsEnvironment(core:navigation:editorPresenter:)` injects every
store a pane or editor reads.

## Panes kept here

Most panes live in their feature's `Settings/` folder. The ones with no feature of their own live in
`Features/Settings/Panes/`:

- **General** — the launcher's shortcut (`ShortcutRecorder(action: .togglePalette)` under Global
  Shortcuts), launch at login, the menu-bar item, Pop to Root, Escape behaviour, input-source
  switching, the Welcome Tour, the calculator's number format, and search behaviour.
- **Appearance** — Theme (`AppAppearance`; `.system` maps to a `nil` `NSApp.appearance` so AppKit
  follows macOS), Interface Size, window mode, favorites in compact mode, following the cursor across
  displays, and dragging the palette.
- **Permissions** — Accessibility, Calendars, Reminders and Contacts. The four statuses are read
  together in a `Task.detached`, because each is a round trip to TCC, and polled each second while
  the pane is open, since nothing announces a grant made in System Settings.
- **Navigation** — the switch for [Switch Windows and Search Menu Bar Items](navigation.md).

## Testing

`Tests/settings-history-test.swift` compiles `SettingsTab`, `SettingsHistory`, `SettingsAnchor`,
`SettingsNavigationState` and `SettingsSearchCatalog`, and pins the history's browser semantics,
pages as steps of their own, that every pane sits in exactly one sidebar group, that the catalog
covers every pane, and that entry identities are unique. `appearance-test` covers `AppAppearance`. `Scripts/check-settings-search.js` covers the half
the compiler cannot. The window itself is in the manual sweep's
[Settings and backup](../testing.md#settings-and-backup) section.
