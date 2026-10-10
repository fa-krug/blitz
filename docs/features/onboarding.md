# Onboarding

A five-page first-launch wizard — the **Welcome Tour** — that binds the launcher's shortcut, asks for
Accessibility, offers a Raycast import and teaches three habits before dropping the user into the
launcher. It opens once on its own, and on request afterwards.

## Invariants

- **First run is a file, not a default.** `OnboardingState` checks for an empty `onboarded` marker in
  `AppPaths.applicationSupport()`, because cfprefsd resurrects a deleted default. The marker is
  per channel, so `Blitz Dev.app` onboards separately from an installed copy.
- **The marker is written at show-time**, before the window appears, so quitting mid-tour never shows
  it again on the next launch. `AppCore.start()` shows it last, after every sink is wired.
- **Nothing in the tour is required, and nothing is only there.** Accessibility and the Raycast
  import offer Skip, Continue on the first page works with no shortcut bound, and each page names
  the Settings pane that does the same later.
- **The tour is built from the app's own controls.** The shortcut row is the real
  `ShortcutRecorder(action: .togglePalette)`, the import calls `BackupActions.importRaycast` with the
  same `RaycastImportSelection` the Backup pane uses, and Accessibility goes through `Permissions`.
  It never grows a second implementation of a setting.
- **The Tab card never promises a place ⇥ does not go.** `OnboardingTip.TabDestination` is resolved
  from `PaletteTabAction.resolve(mode: .launcher, …)` with the live `aiEnabled` and
  `clipboardEnabled`, the same resolver the palette uses.
- **The card look is Onboarding's own.** `OnboardingCard`, `OnboardingRow` and `OnboardingKeycaps`
  are private to this window; Settings panes are stock `Form` sections, and
  [Support](support.md) does not borrow these either.

## The pages

`OnboardingStep` is the order, and Continue walks it one step at a time:

| Step | Title | Holds |
| --- | --- | --- |
| `.shortcut` | Welcome to Blitz | the launcher's recorder with a **Use ⌘Space** button, and Launch at login |
| `.accessibility` | Enable Pasting | a live Granted / Not granted badge; the primary button opens System Settings |
| `.raycastImport` | Import from Raycast | a `.rayconfig` picker, its passphrase, the category selection |
| `.tips` | Three Things to Try | the ⌘K actions menu, aliases (⇧⌘,), and where ⇥ goes |
| `.done` | You're all set | names the chosen launcher chord; Get Started opens the launcher |

**Use ⌘Space** is `SpotlightHandoffSession`'s, described under
[Taking ⌘Space from Spotlight](hotkeys.md#taking-space-from-spotlight): it binds at once when the
chord is free, or shows `SpotlightShortcutGuide` and binds when the user comes back from System
Settings. The view refreshes the session on every `didBecomeActiveNotification`, and polls
`Permissions.isAccessibilityTrusted()` once a second from a `.task`, so the badge turns green on its
own after a grant.

The import step is `OnboardingModel`, an `@Observable` kept off the view: it recognises the chosen
file through `BackupActions.isRaycastExport` before asking for anything, enables Import only with a
Raycast export, a passphrase and at least one category, and reports the import's own summary line.
The passphrase is cleared after a successful import. See [raycast-import.md](raycast-import.md).

When ⇥ leads nowhere useful — AI off — the tips page adds **Turn on AI in Settings › AI**, since
that switch is the one that sends ⇥ to Quick AI (`OnboardingTip.offersAISettings`).

## The window

`OnboardingCoordinator` (owned by `AppCore`) holds one `AppWindowController` titled "Welcome to
Blitz". The view reports its ideal height through `onGeometryChange` and the coordinator resizes the
window to it, so no page is clipped or padded out; the view is `fixedSize` vertically so the
measurement converges rather than feeding back. Showing it while it is open raises the existing
window rather than rebuilding it. `finishOnboarding()` closes it and opens the palette on the launcher.

## Reopening it

Three paths reach `showOnboarding()`:

- first launch, from `AppCore.start()`, when the marker is absent;
- the **Show Welcome Tour** command (`CommandID.welcomeTour`, `command:welcome-tour`);
- **Settings › General › Welcome Tour › Show Tour**.

## Where it lives

| File | Holds |
| --- | --- |
| `Onboarding/Model/OnboardingStep.swift` | the page order, titles and subtitles |
| `Onboarding/Model/OnboardingTip.swift` | the three tips, their keycaps, the ⇥ destination |
| `Onboarding/Service/OnboardingState.swift` | the `onboarded` marker |
| `Onboarding/UI/OnboardingCoordinator.swift` | the window, its height, finishing into the launcher |
| `Onboarding/UI/OnboardingView.swift` | the pages, the footer, and `OnboardingModel` for the import |
| `Onboarding/UI/OnboardingCard.swift` | the card, row, divider and keycap views |

## Testing

`Tests/onboarding-test.swift` (`onboarding-test`) compiles `Onboarding/Model/` with
`PaletteTabAction` and pins the page order and its back-and-forth walk, that every page but Done has
its own subtitle, the three tips and their keycaps, and the ⇥ card against every combination of AI
and Clipboard. The window, the polling and the import are covered by the manual sweep in
[testing.md](../testing.md#onboarding).
