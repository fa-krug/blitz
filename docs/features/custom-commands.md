# Custom commands

Custom commands let users add a searchable name and a shell command in **Settings → Custom
Commands**. They appear in the launcher's Custom Commands section, share the normal fuzzy ranking,
and run from Return, a favorite slot, or an optional global shortcut. A command may declare
[arguments](#arguments) it is asked for first, and may [show what it printed](#show-output) when it
finishes.

The pane carries the feature switch — off out of the box — and its launcher-visibility companion,
both in `AppSettings` and in settings backups. Switching the feature off empties the launcher section and makes
`CustomCommandCoordinator.runCustomCommand` — the single funnel for palette activation and global shortcuts — refuse to
run anything; Carbon registrations and their bindings stay put, so re-enabling restores every shortcut
without re-registering. "Show in launcher" only hides the section; shortcuts keep working.

## Invariants

- **`Model/CustomCommand.swift` and `Service/ShellCommandRunner.swift` stay free of AppKit and
  SwiftUI** (Foundation plus Darwin for `mkstemp`) so `custom-command-test` can compile them standalone. That is why the confirmation gate
  lives in `CustomCommandCoordinator` and not in the runner.
- A command that runs arbitrary shell is a security surface: the confirmation step cannot be bypassed, and
  an import of executable commands warns before it applies.
- **A disabled command is inert, not gone.** `isEnabled == false` takes it out of the launcher slice
  and `runCustomCommand` refuses it, so neither a row nor its still-registered shortcut can run it.
  Name, command text, arguments, alias, favorite slot and shortcut stay exactly as they were, and the
  **Settings → Commands** row is the one place that turns it back on.
- **An argument value is never spliced into the command text.** It is handed to zsh as a positional
  parameter, so a value carrying `;`, backticks or `$(…)` is data the script reads, never syntax the
  shell runs. `custom-command-test` asserts this directly.

## Ownership and persistence

`CustomCommandStore` is owned by `AppCore` and persists the ordered command array as JSON in
bundle-scoped `UserDefaults`. Each command has a stable UUID. Its launcher entry id is
`custom-command:<uuid>`, and its hotkey uses
`hotkey.customCommand.<uuid>` plus the `boundCustomCommandIDs` index.

Editing preserves the UUID and therefore its alias, favorite, visibility, and hotkey references. The row's
**Enabled** checkbox is the only writer of `isEnabled`, so the editor panel carries the flag through a
save rather than offering a second control for it. Deleting
goes through `AppCore`, which unregisters the hotkey and clears those references before removing the
command. Native settings backups include both commands and bindings; import warns before accepting
executable content.

The Settings list is sorted by name and filtered by name or command text. Past a screenful it is a
`SettingsRowsTable` (see `SettingsRowsTablePolicy`), since each row carries an alias field and a
shortcut recorder. Its rows read `AppSettings` from the environment rather than a captured value,
so "Show in launcher" dims every visible alias at once.

## Launcher integration

`AppIndex` owns two slices: applications/System Settings discovered off-main and custom command
entries supplied on the main actor. It publishes the custom command slice ahead of the alphabetized
`CommandCatalog` built-ins, each its own launcher section. This keeps the visible row order identical
to the flat palette selection while allowing edits to invalidate fuzzy results without rescanning disk.

The command text is deliberately not searchable. Only the user-facing name enters fuzzy matching.

## Execution contract

`ShellCommandRunner` executes asynchronously with:

- `/bin/zsh -lc <command>`, or `/bin/zsh -ilc <command>` when the command's **Load shell
  environment** flag is on
- `blitz` as `$0`, then the collected argument values as `$1`, `$2`, …
- the command's own **Run In** folder, or the home directory when it names none
- standard input reading EOF immediately
- `BLITZ=1` added to the inherited environment
- up to 8 KiB of standard error retained for a failure dialog
- standard output discarded

**Show output** takes a different route entirely — see [Show output](#show-output). Nothing else does.

No Terminal window or pseudo-terminal is created. The exit wait blocks for the whole life of the
command, so it runs on a private concurrent `DispatchQueue` rather than a cooperative-pool thread a
long `brew upgrade` would hold for minutes. A session's drain blocks the same queue on `read`.

### Load shell environment

zsh reads `~/.zshrc` **only for interactive shells**, so the default `-lc` sees `.zprofile` and
`.zlogin` and nothing else — a user's aliases, functions and `PATH` edits are all absent, and the
command exits **127**. That is the single most common way a custom command fails. The flag switches to
`-ilc`, which sources the rc file.

It is per-command and off by default, because turning it on runs whatever the user's shell startup
does — oh-my-zsh's auto-update (`git pull`, network, seconds), powerlevel10k's `gitstatusd`,
`compinit` rewriting `~/.zcompdump`, or an `exec` that replaces the shell so the command never runs at
all. `BLITZ=1` exists so an rc file can skip those sections: `[[ -n $BLITZ ]] && return`.

Measured cost: ~10 ms for `-lc`, ~65 ms for `-ilc` against a real-world `~/.zshrc` (~11 ms against a
minimal one — the interactive shell itself is ~2 ms, the rest is the user's own config).

Without **Show output**, interactive prompts cannot block. Standard input is `/dev/null`, so a
`read` gets EOF and returns non-zero. Under **Show output** standard input is the window's terminal
and stays open, so a prompt waits for the [input line](#the-input-line) instead. Either way a
launchd-launched app has no controlling terminal, so `/dev/tty` fails with `device not configured` —
which is why `sudo` cannot ask for a password in the window, and **Open in Terminal** is the way to
run it. A dev build launched _from a terminal_ inherits that terminal's tty, so an rc file reading
`/dev/tty` can hang there but not for real users. There is **no timeout** — Blitz never kills a
running command except through the output window's Stop button, and a command outlives Blitz
quitting.

Because standard error surfaces only on a non-zero exit and only its last 8 KiB, rc-file startup noise
is dropped while the actual error survives.

### Arguments

A command may declare **up to three** arguments, each a name and an optional/required flag — Raycast's
own cap, and what keeps the fields on screen. `CustomCommandArgument.sanitized` enforces it on every
path in, so a stored or imported command carrying more keeps its first three and drops the rest, the
way Raycast ignores an `argument4`. The editor's **Add** stops at three.

They are filled **inline beside the search field** when the command's row is selected in root search,
as a quicklink's are (see [palette.md](palette.md#inline-row-arguments)).
`CustomCommandArgumentsAccessory` builds the strip; Tab walks into it, and ↵ with a required field
still empty focuses that field instead of running — Raycast's rule. An optional field left empty is
never marked as owed.

**The fields are keyed by position, not name** — `CustomCommandArgument.fieldID(at:)`, `$1` to `$3` —
because two arguments may share a name, and keying by name would give them one value and one focus.
`CustomCommand.positionalValues(from:)` turns the fields back into `$n` order, or nil while a required
one is empty.

`runCustomCommand(id:values:)` is still the one funnel for every entry point. A launcher row hands it
the typed values; a **global hotkey or favorite slot** hands it none; a **`blitz://run/` deep link**
hands it its `arguments` JSON, which `CustomCommand.fieldValues(fromLink:)` keys by `$n` or by an
argument's name — the name a link author reaches for, filling every field that shares it — and
drops any key the command does not declare. Either way, a required value still
missing opens root search onto that command alone — the query seeded with its name, its row the only
one listed, its first empty field focused — through `PaletteCoordinator.showArguments(of:values:)`.
That is what Raycast does for a hotkey. The row is listed even when the command is hidden from the
launcher, since its shortcut still has to be answered; typing anything else returns to a normal search.

Values reach zsh as **positional parameters**, never as text substituted into the command:

```
/bin/zsh -lc '<command>' blitz <value1> <value2> …
```

so the script reads them as `$1`, `$2`, and a value containing `; rm -rf ~` is a string, not a second
command. An optional argument submitted empty still occupies its slot, so `$2` never becomes `$3`.

### Show output

Off by default. With it on the command runs in a **session** — `ShellCommandRunner.openSession` on a
`PseudoTerminal` instead of `run` and a pipe. The window opens **before the first byte**, the log
fills in as the command prints it, and the shell stays open afterwards so the next line can be typed
into the same window, in the folder and environment the last one left.

#### Why a pty and not a pipe

A pipe cannot deliver either half of what this promises, and both failures were measured rather than
assumed:

- **Nothing is live.** libc switches stdout from line-buffered to fully buffered the moment it is not
  a terminal. A command printing a line every 0.4 s delivered all four lines within 20 ms of each
  other, at exit.
- **The order is wrong.** stderr stays unbuffered while stdout does not, so stderr overtakes the
  stdout it followed. `print` / `write(stderr)` / `print` came out as 2, 1, 3 — through a *single
  merged pipe*. Merging is not enough; only a terminal restores line buffering, and with it the
  order. Under a pty the same command printed 1, 2, 3.

`PseudoTerminal` also spawns with `POSIX_SPAWN_SETSID`, which is what makes Stop honest: the shell
leads its own session, so one `kill(-pid)` reaches the whole `a && b && c` chain. `Process.terminate`
signals only zsh — a `sleep` started behind it survives, verified. It spawns with
`POSIX_SPAWN_CLOEXEC_DEFAULT` too, and marks its own ends close-on-exec, so no other child of Blitz
holds a session's descriptors open.

Two spawn details that look optional and are not, both found by the harness:

- **An empty signal mask and default dispositions** (`SETSIGMASK`, `SETSIGDEF`). A dispatch worker
  thread blocks nearly every signal, and zsh hands the mask it was born with to every command it
  forks — so a shell spawned from one runs commands that never see SIGINT, and Stop always fell
  through to the kill.
- **`VEOF` set to ⌃D.** `cfmakeraw` leaves the control characters alone, and a zeroed `termios`
  makes NUL the end-of-file character, so a typed ⌃D arrived as text and `cat` waited forever.

#### A session, not a run

One zsh lives for as long as the window shows it. It does not read commands from the terminal —
that would bring a prompt, a line editor and the user's prompt theme into the log — but from a pipe
on **descriptor 3**, which `sessionScript` loops over:

- each line arrives NUL-terminated, is `eval`'d with descriptor 3 closed so the command never sees
  the pipe, and is followed by a private OSC marker, `ESC ] 6973 ; <nonce> ; <status> ; <PWD> BEL`;
- `LineEndScanner` cuts the marker out of the output it arrives inside, wherever a read splits it,
  and the session reports `finished` with the status and the folder the shell is now in;
- the per-session nonce keeps a command that prints a marker-like sequence from faking one;
- the shell's `$1`, `$2` are the command's arguments for the session's whole life, so the opening
  command reads them as before and a later line may too.

Because the line runs inside a function, `typeset` and `local` in a typed line stay local to it and
`$0` reads `__blitz_run`; `cd`, `export`, plain assignments, aliases and functions all persist.

**Stop is ⌃C, not a kill.** It sends SIGINT to the session; the script's `TRAPINT` returns non-zero,
so zsh abandons the rest of the line — `sleep 30; echo next` never reaches `echo` — and an `always`
block with `TRY_BLOCK_INTERRUPT=0` clears the interrupt so the loop, and the shell, carry on. A line
still running `stopGrace` (2 s) later gets SIGKILL, which ends the session with it. A stop with
nothing running sends nothing, so it can never reach the shell idling in `read`.

The script starts with `unsetopt monitor`: interactive zsh — **Load shell environment** — turns job
control on even without a controlling terminal, giving every command its own process group that
`kill(-pid)` misses. That is measured, not assumed, and the harness covers it.

The terminal echoes what is typed (`ECHO` on), so an answer appears in the log where a terminal
would show it — and a command reading a password turns echo off itself, so it never does.
`ANSIInterpreter` drops the control bytes an echoed ⌃D can leave and treats a backspace as erasing.

A prompt never ends its line, so the drain cannot wait for a newline to show one: once output pauses
for `flushInterval` (`awaitOutput`, a `select` — `poll` refuses character devices on macOS), the
held text is shown as it is.

#### What the window shows

One flat surface, no rules. The command's name, the folder the shell is in under it, the log, the
input line, and a footer with a status dot, the outcome and the elapsed time of the latest line.
Every line, the opening command included, is written into the log as a dimmed `❯` and the line in
bold, so the log reads as a transcript. Copy and **Open in Terminal** are always there; the third
control is **Stop** while a line runs and **Run Again** once the shell has exited.

#### The input line

Return sends what is typed: **the next line to run** while the shell is idle, or **input for the
running command** — a `y`, a name, an empty Return — while one runs. ⌃C stops the running line, ⌃D
sends end-of-input, and ↑/↓ walk back through the lines typed into this window. History holds only
what was typed into the field: neither the opening command, which may have needed a confirmation,
nor anything typed as input, which may have been a secret. Typing a line pulls a reader who had
scrolled up back to the tail.

#### Open in Terminal

The log draws colour and carriage returns, not a screen, so `vim`, `htop`, `less` or `ssh` belong in
a real terminal. ⌘↵, or the button, writes a self-deleting `.command` script to the temporary folder
— `cd` to the session's folder, the typed line if there is one, then `exec $SHELL -l` — and hands it
to whichever app opens `.command` files, which is Terminal unless the user chose another. That needs
no Automation permission and no setting. `TerminalHandoff` builds the script — the same one
[Run in Terminal](#run-in-terminal) uses — and single-quotes every word it adds. The session's
exports and functions do not travel; only its folder does.

Because a terminal makes tools colour their output, `ANSIInterpreter` renders SGR colour rather than
printing the escapes — that is what replaces the old red-stderr tint, which was a mistake: stderr is
where most tools log progress, so colouring it as an error made a successful `brew update` look
broken. A bare carriage return rewinds its line, so a progress bar redraws in place instead of
stacking a line per frame.

The log is an `NSTextView` and only the undrawn tail is appended; a quarter-megabyte of output
re-laid-out per line is seconds of work. The run publishes each append as an explicit `delta` and
`revision`, so the view adds just that when it is exactly one step behind and redraws from the whole
log otherwise — a new session, a trim, or a window reopened onto a finished one. Past 256 KiB the
head is dropped. Following the tail stops when the reader scrolls up and resumes when they reach the
bottom, the same band the chat transcript uses.

**The window replaces the failure dialog rather than joining it**, so a run is never reported twice;
the success pill is skipped for the same reason.

#### Consequences worth knowing

- **rc-file noise is now visible.** With **Load shell environment** on, anything `~/.zshrc` writes
  reaches the log. The guard is the documented `[[ -n $BLITZ ]] && return`.
- **Stop is the one exception** to "Blitz never kills a running command". Only the button or ⌃C does
  it; a second command superseding the window never touches the first.
- **Closing the window, or a second command superseding it, ends the session gently.** The control
  pipe closes, so the shell reads EOF and exits once its current line is done — never cutting it
  short. Escape closes the window. Quitting Blitz closes the pipe the same way.
- **A command waiting on input now waits.** Without the window it read EOF and moved on; in a
  session it waits for the input line, or for ⌃D.

#### The ad-hoc run

The launcher's **Run Shell Command** fallback (see [launcher.md](launcher.md#fallbacks)) is a
`CustomCommand` that is built, run and thrown away — same `streamOutput`, same window, same Stop
button. It is not gated on `customCommandsEnabled`: that switch governs a library of saved commands,
not a line someone types on purpose, and the fallback's own checkbox is its switch. Because it has no
library entry, `rerunOutput` checks `lastShellCommand` before falling through to `runCustomCommand`,
or the window's Run Again would look up an id the store has never held and do nothing.

### Run in Terminal

A command can skip Blitz's own surfaces entirely and open in the user's terminal app through its
own **Run in Terminal** option. The **Run Shell Command** fallback has the equivalent switch where
the fallback is configured — Settings → Fallbacks → Run Shell Command → **Open in Terminal** — and
it governs that fallback alone; a saved command only ever follows its own option.
`CustomCommandCoordinator.execute` is the one place that picks where a run goes — terminal, output
window, or the background — reading only `runsInTerminal`; the fallback's ad-hoc command takes the
switch into that field when it is built. It runs after the confirmation gate and after the arguments
are collected, so neither can be skipped this way.

The run goes through `TerminalHandoff`, the same self-deleting `.command` script as the output
window's **Open in Terminal**, and keeps the [execution contract](#execution-contract) word for word:

```
cd -- '<Run In folder>' || exit
BLITZ=1 /bin/zsh -lc '<command>' blitz '<value1>' '<value2>' …
exec "${SHELL:-/bin/zsh}" -l
```

`-ilc` replaces `-lc` under **Load shell environment**. Each value is its own single-quoted word, so a
value carrying `'`, `;` or `$(…)` still reaches the script as `$1` and never as syntax — the
[never-spliced invariant](#invariants) holds across the hop, and the harness runs a value built to
break it. A line typed into the output window and handed off always loads the shell environment: it
is the user's own typing, and their own terminal would.

What Blitz gives up is knowing how the run ended. **Show output** and **Show confirmation** have
nothing to act on, so the editor dims them while the option is on; the terminal shows both itself.
A folder that has gone is reported by the terminal's `cd`, which stops the script before the
command, rather than by a Blitz dialog.

The fallback's switch, `shellCommandRunsInTerminal`, is an `AppSettings` preference with its
`SettingsFileKey` (`fallbacks.runShellCommandInTerminal`), and rides settings backups: it moves
where a typed line runs and arms nothing that was not already armed — unlike the fallback's own
checkbox, which stays out of backups. Its section dims while the fallback is unchecked.

### Run In

Each command may name the folder it starts in; empty means the home directory, which is what every
command did before. The path is stored abbreviated, so a `~` one survives a home directory that
moves, and expanded at run time.

A folder that has gone is **reported rather than ignored** — `resolvedWorkingDirectory` returns nil
and the run fails with the path in the message. Falling back to home would run a command somewhere it
did not expect, which is worse than not running it. A path that exists but is a file is refused the
same way.

### Icon

A command may carry its own SF Symbol; without one it draws `CustomCommand.sfSymbol`, the shared
terminal glyph. `CustomCommand.symbol` is the one place that fallback lives, and every surface reads
it — the launcher row, the Settings list, the confirmation and failure dialogs, and the output
window's header. The picker is `DesignSystem/SymbolPicker`, shared with the quicklink editor, which
supplies its own symbol list: what reads as a quicklink is not what reads as a script.

### Needs confirmation

`CustomCommandCoordinator.runCustomCommand(id:)` is the one funnel both palette activation and the global hotkey reach,
so the gate lives there and neither path can bypass it. The palette hides before the dialog it is a
floating panel and would sit above it. The dialog shows the command text as well as its name; ↵ runs
it and Escape cancels, with Cancel rendered on the left of the two buttons. It carries the `terminal`
glyph the command's launcher row uses, and reads neutral rather than destructive — running a command the
user wrote themselves wants a deliberate second tap, not a red alarm. The gate is Blitz's own
dialog, not an `NSAlert` ([ui.md](../ui.md#dialogs--hud)): presentation is `async` with no nested run loop,
and the presenter itself refuses a second dialog while one is up, so a held shortcut can't stack them.

### Show confirmation

The pill shows the command's **last line of output**, falling back to `Ran <name>` for one that
printed nothing — a command that says "3 files cleaned" is worth more than one that says it ran. Only
the non-streaming path fills this: `run` keeps a 4 KiB stdout tail purely to find that line, and a
command showing its output reports through the window instead.

### Reporting

Blitz dismisses an open palette before starting a custom command. With **Show output** off, a zero
exit status is silent; a launch failure or non-zero status opens a Blitz dialog with the bounded
error detail. When the
status is 127 and **Load shell environment** is off, the dialog adds a one-line hint and an **Open
Settings…** button that lands on the Commands pane — the hint is gated on the status alone, not
on grepping stderr, since 127 is equally a plain typo. The command string itself is never logged.

### Manual checks

`requiresConfirmation` lives in `AppCore` (AppKit, `@MainActor`) and so is out of reach of the
Foundation-only harness. Verify by hand:

1. Activating a gated command from the palette hides the palette _before_ the dialog appears.
2. ↵ at the dialog runs the command; Escape or clicking **Cancel** cancels.
3. Pressing the command's hotkey while its dialog is up does not stack a second dialog.
4. A gated command triggered by hotkey with no palette open still confirms.
5. An rc-file-only alias with the flag off shows the 127 hint, and **Open Settings…** opens the
   pane.
6. A command with arguments triggered by hotkey opens root search on that row alone, first required
   field focused — including a command hidden from the launcher.
7. A gated command with arguments asks for every value first, and confirms only once.
8. Running a second output-showing command reuses the one window and does **not** kill the first.
9. A long command's output appears while it runs, not at the end; scrolling up stops the follow.
10. Stop during `brew update` leaves nothing behind — check with `pgrep -f brew` — and the input
    line then runs a follow-up in the same shell.
11. Clicking the Dock icon while a command runs raises the output window, not the launcher.
12. **Run Again clears the log before the new session prints.** The view draws deltas, so it keys
    what it has drawn on the transcript's id as well as the trim counter — a fresh session starts
    back at revision zero, and keying on the counter alone left the previous output on screen.
13. **Import Raycast Scripts** opens a folder chooser, then a warning dialog; Cancel there imports
    nothing. A folder holding no script commands says so instead of reporting zero.
14. Re-importing the same folder says nothing was left to import, rather than reporting zero.
15. An imported command with arguments asks for them and the script receives them — the `"$@"`
    forwarding has no harness coverage of the inline fields that fill it.
16. Two arguments sharing a name are separate fields; ↵ with a required one empty focuses it.
17. `cd /tmp` in the input line moves the header's folder, and `pwd` on the next line agrees.
18. A command asking `[y/N]` shows the question before an answer is typed, and the typed answer
    appears once in the log; ⌃C in the field stops a running line, ⌃D answers `cat` with EOF.
19. ↑ in the idle field recalls typed lines but never the opening command.
20. ⌘↵ with `htop` typed opens Terminal in the session's folder running it, and quitting `htop`
    leaves a shell there; with the field empty it opens just the shell.
21. Closing the window while `sleep 5; say done` runs still says "done", and no zsh is left after.
22. A command with **Run in Terminal** opens Terminal in its Run In folder, asks for its arguments
    and its confirmation first, and leaves a shell there once it finishes. Show output and Show
    confirmation are dimmed in its editor.
23. Settings → Fallbacks → Run Shell Command → **Open in Terminal** sends a typed launcher line to
    Terminal, and leaves every saved custom command where its own option puts it.

## Importing Raycast scripts

**Settings → Commands → Import Raycast Scripts** reads a folder of
[Raycast script commands](https://github.com/raycast/script-commands) and adds one custom command per
script. It is a one-shot import, not a watched folder: the drafts become ordinary commands, editable
and deletable like any other, and nothing keeps pointing back at the folder afterwards.

`Model/RaycastScriptImport.swift` does the parsing, and stays Foundation-only like the rest of
`Model/`. The scan is non-recursive and skips hidden files, matching Raycast's own script directories,
and runs on a detached task because it opens every file in the folder.

A file becomes a command only when it has **both** a shebang and an `@raycast.title`. Both are
mandatory in Raycast's own format, so anything failing either is a helper script the user keeps
alongside their commands, not a command — leaving them out is what lets one folder hold both. Only the
first 8 KiB of a file is read: the shebang and the metadata block are always at the top, and a
script's body can run to megabytes.

| Directive | Becomes |
| --- | --- |
| `@raycast.title` | the command name, and the only thing fuzzy search matches |
| `@raycast.mode` | `compact` / `fullOutput` turn **Show output** on; `silent` and `inline` leave it off |
| `@raycast.needsConfirmation` | **Needs confirmation** |
| `@raycast.argument1…3` | the [arguments](#arguments), named by each one's `placeholder` |
| `@raycast.currentDirectoryPath` | **Run In**, otherwise the script's own folder |

`@raycast.icon` is deliberately **not** imported. Raycast's icon is an emoji or an `.icns` path, and
`iconSymbol` holds an SF Symbol name; there is nothing to map one onto the other, and rendering
either would mean a second icon field on every surface that draws a command. Imported commands take
the shared terminal glyph, and the editor's picker is there to change it.
`@raycast.description`, `@raycast.packageName` and the authorship keys have nowhere to go and are
dropped.

The generated command text is the shebang's interpreter, the script's path single-quoted, and
`"$@"`:

```
/bin/bash '/Users/me/scripts/chrome cdp.sh' "$@"
```

Naming the interpreter rather than executing the file means the import never has to `chmod` a user's
script. The `"$@"` matters: [the runner](#execution-contract) puts argument values on **zsh's**
positional list, so without forwarding them the script would see none — and forwarding them quoted is
what keeps the [never-spliced invariant](#invariants) true across the extra hop.

An import warns before it applies, the same as a backup carrying custom commands, and it goes in as
one `CustomCommandStore.add(contentsOf:)` — one persist and one launcher rebuild for the whole folder
rather than one per script. A name already in the library is skipped and counted, so re-importing a
folder after adding one script to it adds only that script.
