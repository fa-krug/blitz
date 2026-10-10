# Search Screenshots

Search Screenshots is a palette screen over the screen captures Spotlight knows about, newest first. A
query matches a capture's filename, or — once the reader opts in — the text recognized inside it. The
feature lives in `Blitz/Features/Screenshots/` and borrows File Search's list, preview, Quick Look and
actions rather than drawing its own.

## Invariants

- **Off by default, twice over.** `screenshotSearchEnabled` gates the command, its shortcut and the
  screen; `screenshotTextSearchEnabled` gates recognition and is off even when the feature is on. Off
  means no Spotlight query, no indexer, no helper and no database file.
- **Spotlight finds the captures; Blitz never walks the disk for them.** The list is one
  `kMDItemIsScreenCapture == 1` query, sorted on `kMDItemContentCreationDate` — `kMDItemFSCreationDate`
  reads 1970 on many captures — and capped at File Search's 1,000 candidates. A match is only ever one
  of those candidates: recognized text never resurrects a capture Spotlight did not list.
- **No recognition ever runs in the app process.** The indexer and Copy Text both go through
  `ClipboardTextWorker.extract(at:isPDF:executable:timeout:)`, which spawns the bundled
  `ClipboardTextHelper` and reaps it. The clipboard's bounds apply unchanged — 32 MB inputs, a 60 s
  timeout, 32 KB of text.
- **Recognized text is search metadata.** It lives in `screenshots.sqlite3` in Application Support,
  keyed by the bundle id like every other store, and is read only to match a query and for Copy Text.
  The text-search switch is per Mac: it has no `settings.json` key and no backup field, because a file
  or an import must never start background recognition.
- **`ScreenshotQuery`, `ScreenshotFile` and `ScreenshotTextStore` take the home directory and the
  capture location as parameters**, which is what lets `screenshot-test` run them against a scratch
  folder.

## Finding captures

`ScreenshotQuery.scopes` searches home, plus the `com.apple.screencapture` `location` default when the
user moved captures outside home. `ScreenshotService` runs the query through
`FileSearchService.execute`, reads only `kMDItemPath`, and drops anything under `~/Library` or a hidden
folder — app caches and containers hold captures nobody is looking for.

A blank query lists the newest 30. A `date:today`, `date:yesterday` or `date:week` first token narrows
the Spotlight query with its own `$time` literals, so no clock is injected; `week` is today and the six
days before. Any other `date:` token is an ordinary term. Remaining terms must all occur in the
filename, or all occur in the recognized text; matches keep recency order and stop at 200. A row is
stat'd before it is offered, because Spotlight lags a delete.

The screen runs on a second `FileSearchSession` owned by `AppCore`, so debounce, supersession and
cancellation are File Search's own. Its search operation reads the text-search switch per query.

## Recognition

When both switches are on, `AppCore` creates a `ScreenshotIndexer`. A pass lists every capture with its
modification time, prunes rows whose files have vanished, and recognizes each capture whose stamp
differs from the stored one, newest first — one helper at a time, a 250 ms pause between items, and
only after two seconds without input (`ClipboardTextIndexer.isSystemIdle`). An empty result is stored
too, so a capture with no words is read once. A failure is remembered for the session and retried on
the next launch.

A pass runs when the switches turn on, at launch, and whenever the Search Screenshots screen opens; a
request made during a pass earns one more pass afterwards. Nothing polls and nothing watches a folder,
so a capture taken while Blitz sits idle is read the next time the screen opens. Turning either switch
off cancels the pass in flight; the database stays on disk and is reused on re-enabling.

`ScreenshotTextStore` opens a connection per call, so it is a `Sendable` value any detached task can
use without an actor. Rows are `(path, modified, text)` with a trigram FTS5 index. Terms of three or
more characters match through the index; a shorter term falls back to an escaped `LIKE` scan. A read
never creates the file.

## Palette and actions

The list, preview and ⌘Y Quick Look are File Search's, with the header reading **Recent Screenshots**
on a blank query. The ⌘K menu is `FileSearchActionsMenu` — Open, Show in Finder, Quick Look, Share,
Copy File, Paste File, Copy Name, Copy Path, Move to Trash — plus **Copy Text** (⇧⌘T). Move to Trash
removes the row from the screenshot session rather than File Search's.

Copy Text hides the palette and shows a progress pill. It uses the indexed text when the switch is on
and the row was read from the file as it is now; otherwise it reads fresh in the helper. It reports
**Copied text**, **No text found**, **Clipboard changed, text not copied** or **Couldn’t read the
text**, exactly as the clipboard's Copy Text does.

## Invocation

Settings ▸ File Search seats a Screenshots section with the feature switch, the Search Screenshots
command row and the text-search switch. The command is owned by the File Search pane through
`SettingsTab.ownedCommands`, but its row sits in that section, so Configure Command lands there.
`ScreenshotCoordinator.applyEnabled` projects the command into the launcher and returns an open screen
to the launcher when the feature is switched off.
