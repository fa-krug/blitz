# Custom commands

Custom commands let users add a searchable name and a shell command in **Settings → Custom
Commands**. They appear in the launcher's Custom Commands section, share the normal fuzzy ranking,
and run from Return, a favorite slot, or an optional global shortcut. A command may declare
[arguments](#arguments) it is asked for first, and may [open in a terminal](#open-in-terminal) of
Blitz's own, which stays open as the user's shell once the command finishes.

The pane carries the feature switch — off out of the box — and its launcher-visibility companion,
both in `AppSettings` and in settings backups. Switching the feature off empties the launcher section and makes
`CustomCommandCoordinator.runCustomCommand` — the single funnel for palette activation and global shortcuts — refuse to
run anything; Carbon registrations and their bindings stay put, so re-enabling restores every shortcut
without re-registering. "Show in launcher" only hides the section; shortcuts keep working.

## Invariants

- **`Model/CustomCommand.swift`, `Service/ShellCommandRunner.swift` and `Platform/PseudoTerminal.swift`
  stay free of AppKit, SwiftUI and SwiftTerm** (Foundation, Darwin and `Synchronization`) so
  `custom-command-test` can compile them standalone. That is why the confirmation gate lives in
  `CustomCommandCoordinator` and not in the runner, and why the emulator only ever sees bytes.
- A command that runs arbitrary shell is a security surface: the confirmation step cannot be bypassed, and
  an import of executable commands warns before it applies.
- **A disabled command is inert, not gone.** `isEnabled == false` takes it out of the launcher slice
  and `runCustomCommand` refuses it, so neither a row nor its still-registered shortcut can run it.
  Name, command text, arguments, alias, favorite slot and shortcut stay exactly as they were, and the
  **Settings → Commands** row is the one place that turns it back on.
- **An argument value is never spliced into the command text.** It is handed to zsh as a positional
  parameter, so a value carrying `;`, backticks or `$(…)` is data the script reads, never syntax the
  shell runs. A terminal run keeps it too: the command text and every value are positional words of
  [the wrapper](#the-wrapper), whose only interpolated value is a UUID. `custom-command-test` asserts
  both paths directly.
- **One window per terminal run.** Nothing reuses, replaces or supersedes an open terminal window; a
  second run, or Run Again, always opens another.
- **Closing a terminal window hangs up everything in it**, opening command included — so "Blitz never
  kills a running command" holds only for a command without **Open in terminal**. The exceptions are
  listed under [Stop, ⌃C and hang-up](#stop-c-and-hang-up).

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

The Settings list is sorted by name and filtered by name or command text. Its rows are read-only
(`SettingsPageRows`, see [ui.md](../ui.md#settings)): the name, the command line, the alias and
shortcut as badges, and a dimmed label when disabled. A row opens the command's own page — Edit…
and Delete…, then the Enabled switch, the alias field and the shortcut recorder, acting at once —
and the editor sheet carries the enabled flag through an edit rather than resetting it.

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
- the last 4 KiB of standard output retained for [Show confirmation](#show-confirmation)'s line

**Open in terminal** takes a different route entirely — see [Open in terminal](#open-in-terminal).
Nothing else does.

This background path creates no terminal. The exit wait blocks for the whole life of the command, so
it runs on a private concurrent `DispatchQueue` rather than a cooperative-pool thread a long
`brew upgrade` would hold for minutes. A terminal's drain blocks the same queue on `read`.

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

In the background, interactive prompts cannot block. Standard input is `/dev/null`, so a `read` gets
EOF and returns non-zero, and a launchd-launched app has no controlling terminal, so `/dev/tty` fails
with `device not configured` — `sudo` cannot ask for a password. **Open in terminal** is the way to
run one: there the command has a real controlling terminal, so a prompt waits for what is typed and
`sudo` asks the way it would anywhere. A dev build launched _from a terminal_ inherits that
terminal's tty, so an rc file reading `/dev/tty` can hang a background run there but not for real
users. There is **no timeout**: Blitz never kills a background command, and one outlives Blitz
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

### Open in terminal

Off by default. With it on the command runs in **a terminal window of Blitz's own** —
`ShellCommandRunner.openTerminal` on a `PseudoTerminal`, drawn by
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — instead of `run` in the background. The
window opens **before the first byte**, output appears as it is printed, and once the command
finishes the same terminal stays open as the user's own login shell. It is a real terminal, not a
log: `vim`, `htop`, `less`, `ssh` and a `sudo` password prompt all work in it.

It replaced two surfaces that each did half of that: a log window that drew colour but no screen,
whose typed input could not reach a prompt reading `/dev/tty`; and a hand-off of a `.command` script
to the user's terminal app, which lost how the run ended. Blitz no longer opens an external terminal
app for anything.

The option is `opensTerminal` in Swift, stored under the old `showsOutput` key, so a command that
used to show its output now opens a terminal. A stored `runsInTerminal` from the removed option is
ignored; there is no migration.

#### Why a pty, and why a controlling one

A pipe cannot deliver live output, and both failures were measured rather than assumed:

- **Nothing is live.** libc switches stdout from line-buffered to fully buffered the moment it is not
  a terminal. A command printing a line every 0.4 s delivered all four lines within 20 ms of each
  other, at exit.
- **The order is wrong.** stderr stays unbuffered while stdout does not, so stderr overtakes the
  stdout it followed. `print` / `write(stderr)` / `print` came out as 2, 1, 3 — through a *single
  merged pipe*. Under a pty the same command printed 1, 2, 3.

A pty alone is not enough either: the terminal has to be the child's **controlling** terminal, and
`posix_spawn` cannot make it one on macOS — even with `POSIX_SPAWN_SETSID` the child read a TPGID of
0, and opening `/dev/tty` failed with `device not configured`. Without a controlling terminal a typed
⌃C sends no signal, `sudo` and `ssh` cannot prompt, and job control breaks. `PseudoTerminal.spawn`
therefore uses `forkpty`, which makes the child a session leader with the pty as its controlling
terminal. The harness asserts `: </dev/tty` succeeds and `[[ -t 0 ]]` holds.

Swift marks `fork` unavailable but not `forkpty`, and after a fork in a threaded process the child
may only make async-signal-safe calls. So everything it needs — the argv and envp C arrays, the
folder, a default `sigaction`, an empty mask, the descriptor-table size — is built **before** the
fork, and the child only:

- **resets every signal to its default and empties the mask.** A dispatch worker thread blocks
  nearly every signal, and zsh hands the mask it was born with to every command it forks — so a
  shell spawned from one runs commands that never see SIGINT, and Stop always fell through to the
  kill. The harness found that against the log window this replaced, and it holds just the same.
- **closes every descriptor from 3 up**, so a descriptor some library left without close-on-exec
  never reaches the user's shell. The harness opens one and checks the child's `/dev/fd`.
- `chdir`s to the folder and `execve`s, or `_exit(127)`s.

The parent marks its master end close-on-exec, so no other child of Blitz holds the pty open after a
window closes.

The terminal starts with **the kernel's own `termios` defaults** — read off a throwaway `openpty` —
plus `IUTF8`, so a canonical backspace erases a whole character rather than one byte of it. A
zeroed `termios` was the old trap: it makes NUL the end-of-file character, so a typed ⌃D arrived as
text. The harness asserts `eof = ^D`, `intr = ^C` and `iutf8`.

The environment is Blitz's own plus `TERM=xterm-256color` and `COLORTERM=truecolor`. `LANG` is
added **only when missing** — launchd gives an app none, and zsh's line editor needs UTF-8 to draw
an umlaut. It is `<language>_<REGION>.UTF-8` from the current locale when that locale is installed,
and `en_US.UTF-8` otherwise: English in Germany is a fine preference, but `en_DE` is not installed,
and naming it would mean ASCII. An inherited `BLITZ` is dropped; the wrapper sets it on the command
alone.

#### The wrapper

The child is `/bin/zsh -fc <wrapper> blitz <command> <value1> <value2> …` — `-f` so the wrapper
itself reads no rc file — and `terminalScript` builds the wrapper:

```zsh
__blitz_command=$1; shift
trap : INT
BLITZ=1 /bin/zsh -lc "$__blitz_command" blitz "$@"     # -i +m -lc under Load shell environment
__blitz_status=$?
trap - INT
printf '\e]6973;<nonce>;%d\a' $__blitz_status
exec "${SHELL:-/bin/zsh}" -l
```

- **The command text and its values are positional.** `$1` is the command, and what follows it
  reaches the command as `$1`, `$2`, … exactly as in the background — the
  [never-spliced invariant](#invariants). The only value written into the script is the nonce, a
  UUID. The harness runs `it's`, `a; touch …` and `$(touch …)` through it and checks nothing ran.
- **`trap :`, not `trap ''`.** An ignored signal stays ignored across `exec`, so `trap ''` would make
  the command deaf to ⌃C as well. A handler is reset to the default by `exec`, so the command dies on
  ⌃C while the wrapper survives it, reports 130 and still opens the shell.
- **`-i +m` under Load shell environment.** `-i` makes zsh read `.zshrc`; `+m` keeps job control
  off. Plain `-i` turns job control on, so the interactive zsh takes the terminal's foreground process
  group for itself and leaves the shell exec'd after it outside the foreground — the
  `zsh: suspended (tty output)` the old `.command` hand-off showed. The harness's
  regression test resolves an rc-file alias with the flag on, then types a line into the shell that
  follows and waits for its answer.
- **The status comes back as a private OSC marker**, `ESC ] 6973 ; <nonce> ; <status> BEL`, and is
  never shown. `ShellMarkerScanner` cuts it out of the byte stream wherever reads split it: it holds
  back what could be the start of a marker until the rest arrives, and releases those bytes once
  they turn out not to be one. The per-session nonce means a command printing a marker-like sequence
  cannot fake its status — without the nonce it is ordinary output, passed through to the emulator.
  The marker comes once; after it the scanner retires and the user's shell passes straight through.
  A wrapper killed before its marker, by a hang-up say, reports its own death instead.
- **`exec "${SHELL:-/bin/zsh}" -l`** turns the window into the user's own login shell, with their
  prompt and their rc file, in the command's **Run In** folder — a `cd` inside the command ran in a
  child shell and does not carry over. `BLITZ` is not set there, so the shell skips nothing.

One measured caveat: an interactive `zsh -i +m -c` **ignores a ⌃C that lands between commands**,
while nothing it started is running to take it — during a slow rc file's builtins, say. A typed ⌃C
there does nothing; Stop's backstop below still ends it, and the harness covers that case.

#### Stop, ⌃C and hang-up

- **A typed ⌃C is the terminal's own.** SwiftTerm sends the byte, and the line discipline turns it
  into SIGINT for the foreground process group; Blitz does nothing. `sleep 30; echo nope` reports 130,
  the rest of the line is abandoned, and the shell opens.
- **Stop exists only while the opening command runs** — after that the shell is the user's, and a
  signal would reach it. It sends SIGINT to the terminal's foreground group, as ⌃C would. Whatever is
  still running `stopGrace` (2 s) later is SIGKILLed: every member of the wrapper's process group and
  of the foreground group **except the wrapper**, listed with `proc_listpgrppids` over a few passes
  so a process forked in between is caught. The wrapper lives on to report the outcome as **Stopped**
  and to open the shell. The harness stops `trap '' INT; sleep 45` and checks with `pgrep` that
  nothing survived and that the shell still opened.
- **Closing the window hangs up at once**, like closing a Terminal tab: SIGHUP to the session
  leader's group and to the foreground group, opening command included. ⌘W closes it — a view wrapping
  the emulator catches ⌘W, since no Blitz menu owns it and SwiftTerm seals its own
  `performKeyEquivalent` — and so does the close button. **Escape does
  not**: it belongs to the terminal, and `vim` needs it.
- **Quitting Blitz closes the master end**, and the kernel hangs the terminal up the same way. Cancelling
  the task that reads a terminal's events hangs it up too, so a torn-down reader never leaves a
  shell running.

So the background path's "Blitz never kills a running command" holds for a terminal run only until
Stop, ⌘W or quitting Blitz.

#### What the window shows

One flat surface on `Theme.Colors.terminalSurface`, no rules, top to bottom:

- **A header** — the command's symbol and name, and under it the folder the foreground process sits
  in, following every `cd`. `PseudoTerminal.foregroundDirectory` reads the foreground group leader's
  working directory with `proc_pidinfo(PROC_PIDVNODEPATHINFO)`; the drain polls it every 500 ms and
  reports it only when it changes. The starting folder is reported first, resolved with `realpath`,
  or the first poll would show `/tmp` moving to `/private/tmp`. On the right, **Stop** while the
  opening command runs, **Run Again** once it has finished.
- **The terminal** — `CommandTerminalEmulatorView`, a SwiftTerm `TerminalView` the presenter creates
  once and hosts through an `NSViewRepresentable`, so a SwiftUI rebuild never makes a fresh terminal.
  Monospaced system font at 12 pt, a clear background over the window's surface, and first responder
  as soon as the window shows. It refuses `mouseDownCanMoveWindow`: the window moves by its
  background, which would otherwise swallow a selection drag.
- **A hint row**, only when the command exited 127 with **Load shell environment** off: the same hint
  the failure dialog gives, and **Open Settings**, which lands on the Commands pane.
- **A footer** — a status dot, then **Running** and the elapsed time while the opening command runs,
  or its outcome and duration once it has finished; **Shell exited** at the trailing edge once the
  shell has gone. The window stays open with its scrollback until it is closed.

There is no Copy button: select in the terminal and ⌘C, or ⌘A for everything. **Option types
characters** rather than acting as Meta (`optionAsMetaKey = false`), because German and other layouts
type `@ | { } [ ]` with it; SwiftTerm's own ⌥⌘O flips that for a window. A launch failure — a **Run
In** folder that has gone — prints its reason into the terminal, the way a shell would, and the
footer reports the failure.

**Colours are the system's.** The 16 ANSI slots come from the system hues, black and white are greys
read against the surface, and the bright variants are blended a quarter toward white in Dark and
toward black in Light. Light maps yellow to orange and white to grey, which would otherwise vanish
on the near-white page. SwiftTerm keeps resolved colours, so the palette is re-applied on every
appearance change rather than relying on dynamic colours.

Output reaches the window as raw bytes, the marker already removed. The drain reads the master
16 KiB at a time into an outbox that merges whatever the window has not taken yet into one event,
and the presenter feeds each to SwiftTerm on the main actor. **The outbox is bounded:** past
`pendingOutputLimit` (256 KiB) of undelivered output the drain stops reading the pty until the
window catches up, so a command flooding it blocks on its own writes — the backpressure any terminal
applies — rather than Blitz's memory growing with it. A hang-up drops whatever is still waiting,
since nobody is left to show it.

#### Windows

**Every run gets its own window**, opening at 720 × 460. The first restores the frame saved under
`CommandTerminalWindow`; one opened while another is still open cascades off **the newest open
one** — `AppWindowController(cascadingFrom:)` — and claims the saved name only once no sibling holds
it, so two windows never fight over one frame. `CustomCommandCoordinator` keeps the open presenters,
oldest first, and each removes itself when its window closes. A Dock click goes to
`focusTerminalWindow`, which raises the newest still open, before falling back to the launcher.

**Run Again opens a new window** through the funnel that started the run —
`runCustomCommand(id:values:)` with the same argument values — so the confirmation asks again, an
edit made since applies, and the finished window stays where it is. A command deleted since runs
nothing.

**The window replaces the failure dialog and the success pill** rather than joining them, so a run
is never reported twice — which is why the editor dims **Show confirmation** while **Open in
terminal** is on.

#### Consequences worth knowing

- **rc-file noise is visible.** With **Load shell environment** on, anything `~/.zshrc` writes
  reaches the terminal. The guard is the documented `[[ -n $BLITZ ]] && return`.
- **A command waiting on input waits.** In the background it read EOF and moved on; in a terminal
  it waits for what is typed, or for ⌃D.
- **Closing the window is not neutral.** It ends whatever runs in it, a half-finished `brew upgrade`
  included — the same as a Terminal tab, and the opposite of the background path.
- **The shell afterwards is the user's**, not the command's: its rc file runs, `BLITZ` is unset, and
  nothing the command exported or `cd`'d into carries over.

#### The ad-hoc run

The launcher's **Run Shell Command** fallback (see [launcher.md](launcher.md#fallbacks)) is a
`CustomCommand` that is built, run and thrown away, and it **always opens a terminal window** — same
window, same Stop button. It loads the shell environment (`ll` should mean the reader's own alias),
starts in the home directory and never asks for confirmation. It is not gated on
`customCommandsEnabled`: that switch governs a library of saved commands, not a line someone types on
purpose, and the fallback's own checkbox is its switch. Having no library entry, its Run Again
re-runs the same text through `runShellCommand` rather than looking up an id the store never held.

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
it — the launcher row, the Settings list, the confirmation and failure dialogs, and the terminal
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
the background path fills this: `run` keeps a 4 KiB stdout tail purely to find that line. A
command with **Open in terminal** reports through its window instead, so the editor dims this option
while that one is on.

### Reporting

Blitz dismisses an open palette before starting a custom command. In the background a zero exit
status is silent; a launch failure or non-zero status opens a Blitz dialog with the bounded error
detail. When the status is 127 and **Load shell environment** is off, the dialog adds a one-line hint
and an **Open Settings…** button that lands on the Commands pane — the hint is gated on the status
alone, not on grepping stderr, since 127 is equally a plain typo. With **Open in terminal** on,
nothing is reported outside the window: its footer carries the outcome and its hint row the same 127
hint and button. The command string itself is never logged.

### Manual checks

The confirmation gate lives in `CustomCommandCoordinator` and the terminal window in AppKit and
SwiftTerm, so both are out of reach of the Foundation-only harness. Verify by hand:

1. Activating a gated command from the palette hides the palette _before_ the dialog appears.
2. ↵ at the dialog runs the command; Escape or clicking **Cancel** cancels.
3. Pressing the command's hotkey while its dialog is up does not stack a second dialog.
4. A gated command triggered by hotkey with no palette open still confirms.
5. An rc-file-only alias with the flag off shows the 127 hint — in the failure dialog, and in a
   terminal window's hint row — and **Open Settings** opens the pane from both.
6. A command with arguments triggered by hotkey opens root search on that row alone, first required
   field focused — including a command hidden from the launcher.
7. A gated command with arguments asks for every value first, and confirms only once.
8. **Import Raycast Scripts** opens a folder chooser, then a warning dialog; Cancel there imports
   nothing. A folder holding no script commands says so instead of reporting zero.
9. Re-importing the same folder says nothing was left to import, rather than reporting zero.
10. An imported command with arguments asks for them and the script receives them — the `"$@"`
    forwarding has no harness coverage of the inline fields that fill it.
11. Two arguments sharing a name are separate fields; ↵ with a required one empty focuses it.
12. In a terminal window `vim` and `htop` draw their full screens, resize with the window, and leave
    the shell clean when quit.
13. A typed ⌃C ends `sleep 30; echo nope` without printing `nope`, and the shell prompt follows.
14. Stop during `brew update` ends it and opens the shell; Stop on `trap '' INT; sleep 60` takes
    about 2 s, reads **Stopped**, and `pgrep -f 'sleep 60'` then finds nothing.
15. `sudo -k; sudo true` asks for the password in the window and accepts it.
16. On a German layout ⌥L types `@` and ⌥7 types `|`, in the shell and in `vim`.
17. Escape inside `vim` reaches `vim` and leaves the window open; ⌘W closes the window while
    `sleep 120` runs, and `pgrep -f 'sleep 120'` finds nothing afterwards.
18. Run Again opens a second window cascaded off the first, asks for confirmation again on a gated
    command, and leaves the first window untouched.
19. With two terminal windows open and Blitz in the background, a Dock click raises the newer one.
20. Switching between Light and Dark recolours an open terminal — `ls -G` and a coloured prompt stay
    readable in both, yellow included.
21. `cd /tmp` in the shell moves the header's folder within a second.
22. A command whose **Run In** folder has been deleted prints the reason into the terminal and the
    footer reports the failure; nothing runs in the home directory instead.
23. The **Run Shell Command** fallback opens a terminal window in the home directory with the user's
    aliases loaded, and its Run Again re-runs the same line.

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
| `@raycast.mode` | `compact` / `fullOutput` turn **Open in terminal** on; `silent` and `inline` leave it off |
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
