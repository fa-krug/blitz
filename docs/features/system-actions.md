# System actions

A fixed catalog of macOS actions — lock, sleep, restart, media keys, volume, Show Desktop, Toggle
System Appearance, Stage Manager, Trash, Eject All Disks, hidden files, hide/unhide/quit apps,
Dismiss Notifications, Bluetooth — run from the launcher or a global shortcut. They have their own
launcher section and their own Settings pane, **Settings › System Actions**.

## Invariants

- **`SystemActionCoordinator.runSystemAction(id:)` is the one execution funnel**, shared by palette
  activation and a global hotkey, so no confirmation or permission gate can be bypassed. It hides the
  palette (`restoreFocus: false`) before any confirmation or value dialog.
- **The target is the app the palette covered.** With the palette closed it is the frontmost app,
  so Hide Others and Quit All act on the same window a palette launch would have.
- **`SystemAction.ID`'s raw values are persisted identity.** `entryID` is `system-action:<raw>`, and
  the shortcut (`hotkey.systemAction.<raw>`), favorite, alias, visibility and ranking stores all key
  off it, so a raw value never changes.
- **`Model/` decides; `Service/` acts; `UI/` talks.** `SystemActionCatalog` holds the names, symbols
  and confirmation policy; `SystemActionRunner` performs effects and never presents UI — a failure
  raised after `run` returned goes through `onAsyncFailure`; the coordinator owns every dialog and
  HUD.
- **Every dialog is Blitz's own.** Confirmations, failure reports and the Set Volume slider render
  through `DialogController` via `core.confirm`, `core.reportFailure` and `core.pickVolume` — never
  `NSAlert` (see [ui.md](../ui.md#dialogs--hud)).
- **A permission is asked for only on explicit activation.** Automation, Accessibility or Bluetooth
  is requested at first use; a denial is reported with **Open System Settings…** onto the right
  Privacy pane.
- **Nothing-to-do is an outcome, not a failure** — reported as a neutral pill, never an error.

## Running an action

`SystemAction.Confirmation` says whether it asks first:

| Case | Actions | Behaviour |
| --- | --- | --- |
| `.required` | Restart, Shut Down, Log Out | ↵ runs, Escape cancels; the dialog carries the action's own icon |
| `.followsFinder` | Empty Trash | asks only while Finder's "Show warning before emptying the Trash" is on |
| `.computed` | Quit All Applications | counts its targets, then asks "Quit N applications?" |
| `.none` | everything else | runs at once |

`SystemActionRunner.finderWarnsBeforeEmptyingTrash` reads `com.apple.finder`'s `WarnOnEmptyTrash`
at call time; an absent key counts as on, because Finder writes it only once the box is changed.

Public AppKit, CoreAudio and workspace APIs are preferred. Actions with no stable public API use
fixed system tools, Apple Events (off the main actor, since a cold Finder answers in seconds),
Accessibility, or a dynamically resolved Bluetooth power API. Toggle System Appearance changes
macOS; Blitz follows it only while its own Appearance is System.

## Feedback

An action whose effect is invisible reports back: `SystemActionRunner.run` returns a
`SystemActionFeedback` naming the state it landed in (`Trash Emptied`, `Hidden Files Shown`,
`Dark Appearance`, `Bluetooth Off`, `3 Disks Ejected`), and the coordinator shows it through
`core.showMessage` — `.success` when something changed, `.neutral` when `isNoOp`. Actions that are
their own confirmation — Show Desktop, Hide Others, Quit All, the power actions — return nothing.

Empty Trash asks Finder for `count items of trash` first and reports `Trash Is Already Empty`,
because Finder raises an error when told to empty an empty Trash. The count goes through Finder
rather than reading `~/.Trash`, which is TCC-protected: an unprivileged read fails in a way
indistinguishable from "empty". Eject All Disks, Dismiss Notifications and Unhide All Apps report the
same way when there is nothing to act on.

## Volume

Volume and mute actions show Blitz's own volume HUD (`VolumeHUDController`), since macOS draws its
own only for real media keys; that HUD carries a level and a number rather than a message.
`VolumeState` is the observable level behind both the HUD and the Set Volume slider, so a repeated
press refreshes in place.

`VolumeLevel` is the grid: Volume Up/Down walk 5% steps, and an off-grid level snaps to the next line
rather than past it, so from 37% up lands on 40% and down on 35%. `VolumeLevel.symbol` is shared by
the HUD and the slider so one level never draws two icons. Volume and mute fall back to the output's
preferred stereo channels when the device has no master element (common on HDMI), and Toggle Mute
parks the level at zero when there is no mute control at all.

## The rest of the catalog

- **Eject All Disks** takes every external or ejectable volume — a dock's fixed-media disk reports
  as neither ejectable nor removable, so external alone qualifies — and excludes internal, network
  and root volumes. A sibling volume the same physical eject already unmounted counts as done, and so
  does one whose eject errored but whose mount is gone; remaining failures are reported together.
- **Preference-backed toggles** (hidden files, Stage Manager) refuse to write when the current value
  cannot be read, and return the state they settled into.
- **Dismiss Notifications** matches Accessibility subroles and custom actions rather than English
  labels, so it works in any UI language.

## The launcher and the pane

Each action is an `AppEntry` of kind `.systemAction` in its own launcher section, so search,
favorites, aliases, visibility and learned ranking work as for any entry. The pane is a
`LauncherItemsPane` — the category switch and the searchable list — and each row's page holds its
shortcut recorder (see [hotkeys.md](hotkeys.md)) and alias.

## Where it lives

| File | Holds |
| --- | --- |
| `SystemActions/Model/SystemAction.swift` | `SystemAction`, its `ID`s and `Confirmation`, `SystemActionCatalog` |
| `SystemActions/Model/VolumeLevel.swift` | the 5% grid, percentage text, the speaker symbol |
| `SystemActions/Service/SystemActionRunner.swift` | every effect, `SystemActionFeedback`, `SystemActionFailure`, CoreAudio |
| `SystemActions/Service/VolumeState.swift` | the observable level the HUD and slider draw |
| `SystemActions/UI/SystemActionCoordinator.swift` | the funnel: confirm, run, feedback, failure |
| `SystemActions/Settings/SystemActionsSettingsView.swift` | the pane |

## Testing

`Tests/system-action-test.swift` pins the catalog: every ID once, unique non-empty names and
symbols, stable entry IDs, and which actions confirm. `Tests/volume-test.swift` pins `VolumeLevel`'s
stepping, clamping and symbols. The runner's effects need a real Mac and are in the manual sweep's
[System actions and window management](../testing.md#system-actions-and-window-management) section.
