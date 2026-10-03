# Updates

Blitz updates through [Sparkle](https://sparkle-project.org) 1.27.3 — the same vendored build and
the same feed layout Pointa uses. `UpdateCoordinator` is a thin wrapper: Sparkle owns the check, the
prompt, the download, EdDSA and code-signature verification, the install and the relaunch.

## Invariants

- **Only a CI release updates itself.** `release.yml` injects `BlitzUpdateFeedToken` into
  `Info.plist`; every other build carries an empty string, gets no `SUUpdater` at all, hides the
  Check for Updates command, and answers the menu item with a notice. That keeps `Blitz Dev.app`
  from ever being replaced by a release bundle.
- **The appcast is public, the binary is not.** `SUFeedURL` is
  `raw.githubusercontent.com/fa-krug/blitz-updates/main/appcast.xml` — a static host that ignores
  the `Accept: application/rss+xml` header Sparkle forces. Its `<enclosure>` is this private repo's
  Contents API URL on the `update-feed` branch, which Sparkle downloads with the token, sent as
  `Authorization: Bearer …` together with `Accept: application/vnd.github.raw` in `httpHeaders`.
- **Every update is signed twice.** The zip carries an EdDSA signature checked against
  `SUPublicEDKey`, and the app inside must carry the same Developer ID signature as the running copy.
- **Blitz schedules the checks, not Sparkle.** `automaticallyChecksForUpdates` is off and
  `SUEnableAutomaticChecks` is `false`, so Sparkle never asks for permission and never runs its own
  timer. `UpdateCoordinator.start()` checks 30 s after launch and then daily.
- **An automatic check defers to whatever the user is doing.** Sparkle's prompt would land on top of
  it, so the pump asks `AppCore.canInterruptUser` — `UpdateReadiness` over
  `AppCore.currentActivity`, the same gate the support reminder uses — and retries every two minutes
  while the user is busy. The manual command always checks.
- **Relaunching goes through `NSApp.terminate`.** Sparkle 1 quits the app that way after installing,
  which is what flushes a pending note draft and hands back the Hyper Key's HID-level remap.
- **Nothing about updates is persisted in `AppSettings`.** Sparkle keeps its own state (last check,
  skipped version) in the app's user defaults, keyed by the bundle id like everything else.
- **Sparkle's windows are the one exception to "Blitz presents its own dialogs".** The update alert,
  progress and relaunch windows are Sparkle's own AppKit UI.
- **Sparkle's networking is likewise its own.** It fetches the appcast and the zip on its own
  session, not the private `.ephemeral` one every Blitz-owned networked feature uses.

## Releasing into it

See [release.md](../release.md). In short, every push to `main` builds, signs, notarizes, zips with
`ditto -c -k --keepParent --sequesterRsrc`, signs the zip with `sign_update`, force-pushes the zip
alone to `update-feed`, and pushes a one-item `appcast.xml` to `fa-krug/blitz-updates`.
