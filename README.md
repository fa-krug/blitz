# Blitz

**A tiny, fully native macOS launcher. One hotkey, everything you reach for all day, under 100 MB of
RAM.**

<p align="center">
  <img alt="Swift 6.0"
       src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat&logo=swift&logoColor=white">
  <img alt="macOS 26 or later"
       src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat&logo=apple&logoColor=white">
  <a href="LICENSE">
    <img alt="License: AGPL-3.0"
         src="https://img.shields.io/badge/License-AGPL--3.0-3DA639?style=flat"></a>
  <a href="https://github.com/sponsors/fa-krug">
    <img alt="Support Blitz"
         src="https://img.shields.io/badge/Support-Tip%20the%20dev-EA4AAA?style=flat&logo=polar&logoColor=white"></a>
</p>

SwiftUI and AppKit, **zero third-party dependencies**, no Electron and no telemetry.
It also **runs real Raycast extensions**, rendered as native SwiftUI.

Blitz is a fork of [Tinycast](https://github.com/abue-ammar/tinycast) by Abue Ammar, renamed and
shipped through the same release pipeline as [Pointa](https://github.com/fa-krug/pointa).

<p align="center">
  <img src="docs/screenshot.png" alt="Blitz command palette" width="720">
</p>

## Support

If Blitz earns a place in your daily flow, you can support it through
[GitHub Sponsors](https://github.com/sponsors/fa-krug).

## Features

- **App launcher** — fuzzy-search and launch anything, pin favorites, see what's running, quit an app
  or every app at once.
- **Global hotkey** — one shortcut summons the palette from anywhere.
- **Per-app hotkeys** — bind a key to an app; press it to toggle (focus/hide).
- **Search Files** — open files and folders from the folders you choose, through Spotlight, with no
  index of our own.
- **Dictionary** — look a word up with the Define Word command, or define whatever you typed from the
  launcher's fallbacks, read from the Mac's own dictionaries.
- **Clipboard history** — text and images, searchable, pasted back into the app you were using.
- **Calculator** — do math, unit, live currency and crypto conversions inline, right in the palette.
- **Quicklinks** — turn a URL, search, file or deeplink into a command, with placeholders for typed
  input, the clipboard or the date.
- **Apple Shortcuts** — search and run the shortcuts you built in the Shortcuts app, with aliases and
  global hotkeys.
- **Snippets** — reusable Markdown templates with dynamic placeholders, arguments, nested references
  and optional keyword expansion.
- **Custom commands** — run named shell commands through fuzzy search or their own global hotkeys.
- **Window management** — 34 Rectangle-style actions: halves, quarters, thirds, sizing, nudging,
  display moves, fullscreen and Spaces.
- **System actions** — lock, sleep, restart, empty trash, toggle appearance, Bluetooth, mute, hidden
  files, and more.
- **Calendar and meetings** — your next meeting on the empty palette and in the menu bar, one key to
  join it, or let it join itself.
- **Notes** — an unlimited collection of plain Markdown files in one floating editor, searchable from
  the palette and rendered as you write.
- **Emoji picker** — a searchable emoji grid, one keystroke away.
- **AI chat** — use your own key or an installed AI account: ask Quick AI from the palette, or keep
  longer conversations in the AI Chat window, with a searchable, pinnable history. Off out of the box,
  like every AI feature.
- **Quick Actions** — fix grammar, rewrite, translate or summarize the selected text in any app.
- **Raycast extensions** — run the ones you already have natively, rendered as SwiftUI.
- **Backup and import** — export your settings to a file, or import your setup from Raycast.

## Install

Download the latest `Blitz-Universal-<version>.zip` from
[Releases](https://github.com/fa-krug/blitz/releases/latest), unzip it and move `Blitz.app` to
`/Applications`. Blitz is self-signed rather than notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Blitz.app
```

From then on Blitz updates itself from the same releases, with no further steps.

## Permissions

**Accessibility** — needed when Blitz pastes or expands text into another app, and the only
permission snippet keyword expansion needs. You're prompted when you first use a feature that needs
it; grant access in **System Settings → Privacy & Security → Accessibility**. Snippets ship
disabled, and keystrokes are matched locally, never stored and never sent anywhere.

## Using it

1. Open **Settings → General** and record a global shortcut to summon Blitz.
2. Press it anywhere → the palette floats in. Type to filter, **↵** to launch.
3. **Tab** switches between Apps and Clipboard; **↑/↓** move, **Esc** dismisses.
4. **Settings → Shortcuts** — search an app or custom command and record a global shortcut.
5. **Settings → Snippets** — enable the feature, then create templates with expansion keywords.

## Building from source

See **[docs/development.md](docs/development.md)** for the toolchain and build, and
**[docs/release.md](docs/release.md)** for how a push to `main` becomes an update. **[docs/](docs/README.md)** indexes everything else — architecture, engineering
standards, the design system and one document per feature.

## Contributing

Read **[CONTRIBUTING.md](CONTRIBUTING.md)** first — it covers the memory budget every PR is held to
and the before/after video requirement for visual changes. Every PR fills in the
**[pull request template](.github/PULL_REQUEST_TEMPLATE.md)**. Security issues go through
[SECURITY.md](SECURITY.md), not the issue tracker.

## License

[AGPL-3.0](LICENSE)
