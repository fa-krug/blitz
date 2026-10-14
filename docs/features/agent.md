# Agent

There is one agent, and every chat is a session of it, Quick AI included. It answers directly, or
calls the tools one rule table allows: the shell, files, web fetch, the reader's other chats, Mac
actions, the calendar, reminders, contacts, the note, clipboard history, snippets and quicklinks,
the app the reader is in, its selected text and the clipboard, its own memory, web search and each
MCP server. The
table says Allow, Ask or Deny per tool, plus ordered command patterns for the shell and path
patterns for files; a session's mode — Manual, Auto or Plan — decides what an Ask does, and
nothing a session holds lifts a Deny. Two more tools talk only to the chat and have no row:
`ask_user` and, in Plan, `write_plan`. What the reader asked it to remember rides in every turn's
instructions ([Memory](#memory)).
`AgentPolicy` decides, `AgentGateCoordinator` enforces and asks — only while the asking chat is on
screen; a chat left waiting shows a badge and posts a notification — and the tools themselves stay
with their features — [AI](ai.md#invariants) for the shell runner, the question and the plan,
[File tools](#file-tools), [Web fetch](#web-fetch), [Session tools](#session-tools),
[Mac tools](#mac-tools), [Personal and context tools](#personal-and-context-tools) and
[Memory](#memory) below,
[Calendar](calendar.md#chat-tools), [Reminders](reminders.md#chat-tools) and [MCP](mcp.md).

## Invariants

- **`AgentPolicy` is the whole rule, and it is pure.** `decision(for:rules:mcpTrust:scope:)` takes
  an `AgentCall`, the table, each server's trust and the session's `AgentSessionScope`, mode
  included, and answers `.allow`, `.ask` or `.deny`. It lives in `Model/`, and `agent-policy-test`
  pins it. Nothing else decides.
- **A denied tool is never offered.** Every offer list — Blitz's own tools, the loop's MCP tools,
  the servers handed to Codex or Claude — goes through `AgentPolicy.isOffered`, which is the
  decision for a bare call to the tool. A shell row on Deny hides the tool whatever its patterns
  say, and calendar and reminders offer their read and write halves independently.
- **Nothing a session holds lifts a Deny.** The tools menu switches tools off, "Allow This Chat"
  answers one row's Ask ahead of time, Auto answers every Ask but a local-network fetch's, and Plan
  narrows to what only looks; a row or pattern on Deny refuses under all of them, and a denied tool
  is still not offered. All of it lives on the session scope, so it ends with the scope and is
  never stored.
- **The mode is the session's.** `AgentSessionScope.mode` is an `AgentMode`, never stored: a new
  chat, a reopened one or deleting the open one starts in Manual, and picking a route with no mode
  picker puts the chat back there. Auto shows no dialog but a local-network fetch's, and Plan lets
  through only calls that look, plus commands it asks about one by one. See [Modes](#modes).
- **A local-network fetch always asks.** `AgentCall.webFetch(isLocalNetwork:)` carries
  `LocalNetworkPolicy`'s word on the URL, and `AgentPolicy.decision` holds such a call at
  `min(decision, Ask)` after everything else: an Allow row, a chat grant and Auto all still ask,
  its dialog never offers Allow This Chat, and a Deny row still denies. See [Web fetch](#web-fetch).
- **Read-only is the row's or the server's word, never the model's.** `AgentTool.isReadOnly` is true
  for every row that only looks — the calendar, reminders, contacts, note, clipboard history and
  snippets reads, Read Files, both web rows, the three context rows, Read Other Chats and Read
  Memory. An MCP
  tool is read-only only when its server listed it with `annotations.readOnlyHint` set to `true` (`MCPTool.isReadOnly`); a missing,
  `false` or non-boolean hint, or a tool Blitz never saw listed, changes things. A server's bare row
  says nothing for all its tools, so Plan weighs them one at a time.
- **Asking the reader and writing a plan are no capability.** `ask_user` and `write_plan`
  (`AgentChatTool`) have no row and never pass the gate. `AgentPolicy.isOffered(_:scope:)` offers
  `ask_user` in every mode and `write_plan` only in Plan, and neither with Use Tools off.
- **Every call is decided when it arrives, not when it was offered.** The gate reads the table at
  the call, again when a queued call's turn comes, and again once its dialog closes, so a Settings
  change mid-reply binds the next call. A call the model makes to a tool that went to Deny after
  the turn started is refused with a sentence.
- **An Ask dialog comes up only while its chat is on screen.** `AgentGateCoordinator.authorize`
  asks `AIChatCoordinator.isOnScreen` first; a request from a chat off screen is held on its
  `AIChatState` with no dialog until the chat comes on screen. See
  [Waiting off screen](#waiting-off-screen).
- **The shared queue serialises shown dialogs only.** A held request takes no place in
  `AIConsentQueue`, so a chat left waiting never stalls another chat's dialog, and one whose chat
  leaves the screen while it queues is held again when its turn comes rather than shown.
- **Whatever still waits is declined, exactly once.** Stop, deleting the chat or clearing the
  history it is in, AI going off, quitting and the turn ending any other way all go through
  `AIChatState.cancel` or the turn's finish, which end every open request (`AgentApprovals.endAll`)
  and resume each held one with a decline. A later release or end finds nothing to resume.
- **A wait is derived, never stored.** `AIChatState.awaiting: AgentWait?` is
  `AgentWait.of(isStreaming:pendingApprovals:hasQuestion:)`: `.approval` while any Ask request is
  open, held or with its dialog up, else `.answer` while an `ask_user` question waits, and nil
  whenever no turn runs, so a badge can never outlive its turn.
- **A row with no runner is never offered.** `AgentTool.isHosted` is true only for a row some
  catalog's wire name maps to (`builtInToolNames`), so a toolbox row added to the table ahead of its
  runner shows in Settings and nowhere else: the ⌘K Tools menu and the context card list
  `builtIn.filter(\.isHosted)`, and the model's own offer list is built from the catalogs. Adding
  a group's wire names is what makes its rows offerable.
- **The stored table decodes field by field.** A row, `shellRules` or `pathRules` missing from
  `aiAgentRules` decodes as its default (`decodeIfPresent ?? default`), so a table stored before a
  row existed keeps every row it has; this is ordinary evolution of the table, not a migration. A
  value no `AgentDecision` spells still fails the whole table, which then reads as the defaults.
- **The shell matcher fails toward Ask.** A command the splitter cannot read with confidence never
  reaches a pattern; it asks, or is denied by a Deny row. See [Shell patterns](#shell-patterns).
- **A Deny pattern is a backstop, not a sandbox.** Patterns match a segment's text, not the program
  it runs: `env rm x`, `/bin/rm x` and `xargs rm` all slip past a `rm *` Deny. Under an Ask row they
  take the row and still ask; under an Allow row they run. An Allow row plus Deny patterns is a
  blocklist, and the Settings footer says so.
- **A matching Deny pattern always wins.** Order decides only among the rest, so no Allow pattern,
  wherever it sits, can shadow a Deny one. Path rules work the same way.
- **Path rules see canonical paths only.** `PathRule.matches` resolves `~`, `.`, `..` and repeated
  slashes itself, but never touches the disk: a runner resolves symlinks
  (`URL.resolvingSymlinksInPath()`) before it builds `AgentCall.files`. A path that is not absolute
  cannot be weighed and takes `min(row, Ask)`. See [Path rules](#path-rules).
- **A Mac tool never does what cannot be undone, and never past a coordinator.** Restart, Shut
  Down, Log Out, Empty Trash and the rest of `SystemActionToolCatalog.excluded` are not offered at
  all; `mac_open` refuses a file that would run or install something and every link scheme but
  `http`, `https` and `mailto`. Each Mac row runs through its feature's coordinator, which checks
  its feature's switch again after the dialog. See [Mac tools](#mac-tools).
- **A personal read never reaches past its feature's own exclusions.** A contact comes back without
  its note or photo, which are never fetched; clipboard history never held a copy marked secret and
  leaves out whatever an app the history now ignores copied; the current clipboard refuses a copy
  marked secret or transient before reading anything else off it; the selected text is read through
  Accessibility only, never a borrowed ⌘C; and the note is only ever added to, at its end. See
  [Personal and context tools](#personal-and-context-tools).
- **The feature switches stay the ceiling.** Each row with a feature behind it needs that feature's
  switch (`AgentFeatureCeiling`), and a server needs MCP on and itself enabled.
  `AgentGateCoordinator.rules` reads a row as Deny while its ceiling is not met, and a server that
  is off or gone answers Deny. See [The rule table](#the-rule-table) for each row's ceiling.
- **MCP trust is not copied.** A server's row is its `MCPServer.trust` — `.always` ↔ Allow, `.ask` ↔
  Ask, `.never` ↔ Deny (`MCPAgentMapping.swift`) — read and written in place, so the Agent table and
  the server editor cannot disagree.
- **Web search has no Ask.** The provider runs the search, so Blitz never sees a call it could stop.
  `AgentRules` stores an Ask on that row as Deny, no mode makes it ask, and Allow only means the
  ⌘K menu offers its Web Search switch.
- **Memory is read into every turn, never called.** Read Memory has no Ask and no wire name, so it
  is not hosted: on Allow every turn's instructions carry the memories, on every route, Use Tools
  off and Plan included, unless the chat's Use Memory is off (`AgentPolicy.readsMemory`); on Deny
  no turn carries any. See [Memory](#memory).
- **A memory is added only by the reader or through a dialog.** Change Memory starts on Ask, is
  never allowed for the chat and never offered in Plan, since one remembered sentence rides every
  later chat: a page the agent read cannot plant one unasked. Only the row on Allow, or Auto,
  lets `memory_remember` through without a dialog.
- **Memory stays on this Mac.** `AgentMemoryStore` keeps it in `agent-memory.json` in Blitz's own
  Application Support folder, which the path rules' seed denies; no backup category and no
  `settings.json` key carries it, and a file that will not decode is refused rather than replaced.
- **The table is a capability grant.** `aiAgentRules` is in
  `SettingsBackupCoverage.deliberatelyExcluded` and has no `SettingsFileKey`, so neither a backup
  nor `settings.json` can arm a tool.
- **The old access settings are migrated once.** A Mac with no `aiAgentRules` but any of
  `aiCalendarAccess`, `aiRemindersAccess` or `aiShellCommands` gets `AgentRules.migrated`, and the
  three keys are removed. This is one of the codebase's two migrations, explicitly requested; see
  [Settings and storage](#settings-and-storage).

## The rule table

`AgentRules` is one decision per built-in row plus `shellRules` and `pathRules`; an MCP server's row
is its own trust. `AgentDecision` orders `deny < ask < allow`, so `min` is the narrower of two.
`AgentRules.defaultDecision(for:)` is the whole default rule: a read-only row asks, every row that
writes or acts is denied, and web search is Allow, its ⌘K switch being the opt-in. Memory is
the exception both ways: Read Memory is Allow, since every memory in it was the reader's own word
or a dialog's, and Change Memory is Ask.

`AgentTool.builtIn` is Settings order, and runs group by group (`AgentTool.Group`): Commands,
Files, Web, Mac, Calendar & Reminders, Personal, Context, Sessions, Memory.

| Group | Row (`AgentTool`) | Settings title | Covers | Read-only | Default | Ceiling |
| --- | --- | --- | --- | --- | --- | --- |
| Commands | `.shell` | Run Commands | `shell_run_command` | no | Deny | — |
| Files | `.filesRead` | Read Files | `files_list`, `files_read` | yes | Ask | — |
| | `.filesWrite` | Change Files | `files_write`, `files_move`, `files_trash` | no | Deny | — |
| Web | `.webSearch` | Web Search | the route's own search | yes | Allow (no Ask) | — |
| | `.webFetch` | Fetch Web Pages | `web_fetch` | yes | Ask | — |
| Mac | `.openItems` | Open Apps, Files and Links | `mac_open` | no | Deny | — |
| | `.shortcuts` | Run Shortcuts | `shortcuts_list`, `shortcuts_run` | no | Deny | Apple Shortcuts on |
| | `.systemActions` | Run System Actions | `system_actions_list`, `system_action_run` | no | Deny | System Actions on (`VisibilityStore`) |
| | `.windowLayouts` | Apply Window Layouts | `window_layouts_list`, `window_layout_apply` | no | Deny | Window Management on |
| Calendar & Reminders | `.calendarRead` | Read Calendar | `calendar_list_events` | yes | Ask | Calendar on |
| | `.calendarWrite` | Add Calendar Events | `calendar_create_event` | no | Deny | Calendar on |
| | `.remindersRead` | Read Reminders | `reminders_list` | yes | Ask | Reminders on |
| | `.remindersWrite` | Change Reminders | `reminders_create`, `reminders_update`, `reminders_complete` | no | Deny | Reminders on |
| Personal | `.contactsRead` | Read Contacts | `contacts_search` | yes | Ask | Contacts on |
| | `.noteRead` | Read the Note | `note_read` | yes | Ask | Notes on |
| | `.noteWrite` | Add to the Note | `note_append` | no | Deny | Notes on |
| | `.clipboardRead` | Read Clipboard History | `clipboard_history` | yes | Ask | Clipboard on |
| | `.snippetsRead` | Read Snippets and Quicklinks | `snippets_list`, `snippets_read`, `quicklinks_list` | yes | Ask | Snippets or Quicklinks on |
| Context | `.frontmostApp` | See the Frontmost App | `context_frontmost_app` | yes | Ask | — |
| | `.selectedText` | Read Selected Text | `context_selected_text` | yes | Ask | Accessibility granted |
| | `.currentClipboard` | Read the Clipboard | `context_clipboard` | yes | Ask | — |
| Sessions | `.sessionsRead` | Read Other Chats | `sessions_list`, `sessions_read` | yes | Ask | — |
| | `.sessionsArchive` | Archive Chats | `sessions_archive`, `sessions_unarchive` | no | Deny | — |
| Memory | `.memoryRead` | Read Memory | every turn's instructions, no tool | yes | Allow (no Ask) | — |
| | `.memoryWrite` | Change Memory | `memory_remember`, `memory_forget` | no | Ask | — |
| — | `.mcp(slug)` | the server's title | every tool of that server | per tool | its trust, `.ask` | MCP and the server on |

Every row is hosted but web search, which the provider runs, and Read Memory, which is read into
the turn rather than called. Every read-only row but those two can be allowed for the chat; a row
with no Ask stores one as Deny.
`AgentFeatureCeiling` is the one place that says each row's ceiling and the sentence Settings shows
under a row held below it ("Turn on Contacts first."); Selected Text's is the Accessibility grant,
read through `Permissions.isAccessibilityTrusted()` at each decision and polled once a second while
Settings shows the Agent pane.

`AgentTool(wireName:)` maps a model's call onto its row — the built-in names first, then
`MCPToolName.parse` — and `AgentCall(toolCall:)` adds the command a shell call would run. A name
neither Blitz nor a server spells has no row.

`AgentPolicy.decision` applies, in order: a tool the session switched off is Deny; the row's own
decision, with Deny final; a chat grant turning that row's Ask into Allow; for the shell, the
patterns below, and for a file call or an open, the path rules; then the session's mode, which
never touches a Deny; and last, a local-network fetch held at Ask.

## Modes

`AgentMode` is the composer's mode pill, held on `AgentSessionScope.mode`:

| Mode | Glyph | An Ask | Otherwise |
| --- | --- | --- | --- |
| Manual (default) | `hand.raised` | Blitz's dialog | the table as written |
| Auto | `bolt` | runs, with no dialog — but a local-network fetch asks | Allow and Deny as written, so it offers exactly what Manual does |
| Plan | `list.bullet.clipboard` | Blitz's dialog | only read-only calls keep their decision; every command asks; everything else is Deny |

Plan's read-only set is `AgentCall.isReadOnly`: every read-only row — Read Files, both web rows,
the calendar, reminders and personal reads, the three context rows and Read Other Chats — and an
MCP tool its server
marked read-only, each still at its own decision, path rules and grants included. The shell
is offered while its row is not Deny, and every command asks, under any Allow pattern — Always
Allow's included, so the new pattern takes effect once the chat leaves Plan — while a Deny pattern
still refuses. Every row that writes or acts — Change Files, the Mac rows, the calendar,
reminders and note writes, Archive Chats, Change Memory — and every other MCP tool are Deny. A
Plan turn still carries the memories, which no call reads. `ask_user` and
`write_plan` are offered besides, and `AgentModeInstructions.plan` rides each Plan turn: look
without changing anything, ask where the answer changes the plan, finish with `write_plan`, and
never start carrying it out. [AI](ai.md#plans) has the plan card that carries it out.

`AgentCall.mcp(_:readOnly:)` carries the hint; `AgentCall(_:)` builds it from a listed `MCPTool`,
`AgentCall.mcp(_:listed:)` from a CLI's call matched by server and tool name, and
`AgentCall.server(_:listed:)` for a whole server, read-only while any one of its tools is. A bare
`AgentCall(tool: .mcp(slug))` is never read-only, so `isOffered` on a server's row says no in
Plan.

## Shell patterns

`ShellCommandSegments.segments(of:)` splits a command on `;`, newlines, `&&`, `||`, `|`, `|&` and
`&`, honouring quotes and backslash escapes; redirections such as `>`, `2>&1` and `&>` stay in their
segment. It answers nil — cannot read — for:

- `$(`, a backtick, `<(`, `>(`, `<<` (heredocs and here-strings), `${(` or `$'` anywhere, quoted
  or not, since `eval`, `trap` and arithmetic can run a quoted string
- an unbalanced quote, a trailing backslash, an unquoted `(`, `)` or `#`, a control character, a
  carriage return, or nothing but separators and whitespace
- a segment whose command word is a keyword or a word that runs another command — `if`, `for`,
  `eval`, `exec`, `source`, `.`, `command`, `builtin`, `time`, `export`, `alias`, `trap` and the rest
  of `opaqueLeadingWords` — or that contains quoting, `$`, `=`, glob characters, braces, a
  redirection or a backslash; `[` alone is fine, and so is a path

Each segment is Deny if any Deny `ShellRule` matches it, wherever that rule sits; otherwise it takes
the first matching rule, or the row's decision when none matches. The command takes the narrowest of
its segments. So any Deny segment denies the whole command, an Allow pattern raises a segment above
an Ask row, and an Ask or Deny pattern narrows an Allow row. An unreadable command takes
`min(row, Ask)`. A Deny row is Deny before any of this.

`ShellRule.matches` is a glob over the whole segment: `*` spans anything, spaces included, `?` is one
character, and everything else — `[` too — is literal and case-sensitive. Runs of spaces and tabs
collapse on both sides, and a pattern ending in ` *` also matches the bare command, so `ls *` covers
`ls`. Matching walks Unicode scalars, as the splitter does, so a combining mark cannot fuse a space
into a word. Patterns see the command only, never the folder it runs in.

**Always Allow** proposes `AgentPolicy.suggestedPattern`: the command word plus ` *`, only for a
readable single-segment command whose word is not a path and not in `AgentPolicy.neverSuggested` —
words that delete, escalate, reach the network, run code or run another command (`rm`, `sudo`,
`curl`, `python3`, `env`, `xargs`, `find`, `open`…). `AgentRules.allow(_:for:)` then makes it take
effect for the command that asked, without ever adding a second rule for one pattern:

- A rule whose pattern is the same once spaces collapse becomes Allow and moves up, if it must, to
  just before the first non-Deny rule that matches any segment of that command.
- Otherwise a new Allow rule goes in at that same place, or at the end when no such rule matches.

So `[git push * → Ask]` plus Always Allow `git *` for `git push origin` puts `git *` first, and that
command now runs. A Deny is never a place to insert before, and since a matching Deny always wins,
the new rule cannot shadow one.

## Path rules

`AgentRules.pathRules` is an ordered `[PathRule]`, each a pattern, an `Access` — Read & Write, Read
or Write, the file rows it weighs, with Read also weighing `mac_open` (`AgentTool.readsPaths`) — and
a decision. `AgentCall.files(_:paths:homeDirectory:)`
carries every path a call touches, a move's source and destination both; `AgentPolicy` weighs each
path on its own and the call takes the narrowest:

- A path any applicable Deny rule matches is Deny, wherever that rule sits.
- Otherwise the first applicable rule that matches decides, so an Allow pattern raises a path above
  an Ask row, and an Ask or Deny pattern narrows an Allow row.
- A path no rule matches takes the row's decision; a Deny row is Deny before any of this.
- A path that is not absolute, or a home folder that is not, takes `min(row, Ask)`.
- A call with no path — the bare row, as `isOffered` asks — takes the row.
- An open takes the narrower of its path's decision and its row: a Deny or Ask rule holds it back,
  but an Allow rule, written for reading, never lifts an open above Open Apps, Files and Links.

`PathRule.matches(_:homeDirectory:)` is pure. Both the pattern and the path have `~` and `~/`
expanded to the home folder (`~user` is not), `.` and empty components dropped and `..` resolved,
never above `/`; a pattern that is not absolute then matches nothing, nor does an empty one. Then,
component by component:

- `*` matches any run of characters within one component, `?` one character.
- `**` as a whole component matches no component or any number, so `~/Downloads/**` covers the
  folder itself and everything in it, and `~/**/*.pdf` a PDF at any depth.
- Matching ignores case, since a Mac volume usually does, and compares characters as canonical
  equivalents, so a decomposed `é` matches a precomposed one. On a case-sensitive volume a pattern
  can therefore match more than the disk would.

Symlinks are the runner's: it resolves each path with `URL.resolvingSymlinksInPath()` before it asks,
so a link inside an allowed folder cannot reach a denied one.

**Seeds.** A table with no `pathRules` — a fresh one, the migrated one or one stored before path
rules existed — gets `PathRule.seeds`, every one Deny, with fixed IDs so seeding twice gives the same
rules:

| Pattern | Access | Why |
| --- | --- | --- |
| `~/.ssh/**`, `~/.gnupg/**`, `~/.aws/**` | Read & Write | keys and credentials |
| `~/Library/Keychains/**`, `~/Library/Cookies/**` | Read & Write | the keychain files and Safari's cookies |
| `~/Library/Application Support/*/Cookies*/**` | Read & Write | an app's cookie store, file or folder |
| `~/Library/Application Support/<bundle id>/**` | Read & Write | Blitz's own folder (`AppPaths.applicationSupport`): chat history and the rest |
| `~/Library/Preferences/<bundle id>.plist` | Read & Write | Blitz's preferences, where the rule table itself is stored |
| `/System/**` | Write | the sealed system volume |

The bundle ID is the running build's, so a Dev build seeds `de.fa-krug.blitz.dev`. Seeds are ordinary
rules: Settings can edit or remove them, and a table that removed them keeps them removed.

**Always Allow** for a file call proposes `AgentPolicy.suggestedPathPattern(for:homeDirectory:)`:
the canonical folder holding the path, spelled under `~` where it can be, plus `/**`. It proposes
nothing for a path that is not absolute, for `/`, for the home folder or a folder holding it
(compared ignoring case, as matching is), or for a folder or path any Deny seed matches.
`AgentRules.allowPath(_:for:)` places it as `allow(_:for:)` places a shell pattern, as a Read rule
for a read and a Write rule for a write: a rule with the same pattern and access becomes Allow and
moves up if it must; otherwise a new one goes in just before the first non-Deny rule that would
decide one of the call's paths, or at the end. `AISettingsStore.allowPathPattern(_:for:)` persists
it, from the file dialogs' **Always Allow** choice. For a listing, the folder listed is the one
proposed (`isFolder`), so listing `~/Projects` offers `~/Projects/**`.

A write no Allow pattern matches takes the row's decision, as every path does: Change Files on
Allow writes anywhere no Deny rule covers, without a dialog. That was decided with the runner (3b),
rather than capping such a write at Ask: the row is the reader's own word, and it starts on Deny.

## File tools

`FileToolCatalog` (`Model/`) spells five tools and `FileToolRunner` (`Service/`) carries them out.
There is deliberately no delete tool: the most a model can do to a file is move it to the Trash.

| Tool | Row | Arguments | What comes back |
| --- | --- | --- | --- |
| `files_list` | Read Files | `path` (a folder, default `~`), `recursive`, `includeHidden` (both default false) | a header, then a tab-separated row per item: name, type (file, folder, link, package), size, modified |
| `files_read` | Read Files | `path`, `offset` (first line, from 1), `limit` (lines) | a header naming the lines and how many there are, then the text |
| `files_write` | Change Files | `path`, `content`, `mode` (`create` default, `overwrite`, `append`), `createFolders` (default false) | what was written, and how much |
| `files_move` | Change Files | `from`, `to` | where it went |
| `files_trash` | Change Files | `path` | that it is in the Trash, where the user can put it back |

A path is absolute, starts with `~`, or is taken from the home folder, as the shell tool reads its
folder (`ShellToolCatalog.resolved`); `.` and `..` resolve first. The caps:

- **A listing** holds at most 500 items (`listLimit`). A flat one counts what it left out; a
  recursive one, three levels deep (`listDepth`), stops at the cap and says so, notes the folders
  at the bottom it did not enter, never follows a link or enters a package, and never enters a
  folder a Deny rule for that row covers, naming it instead. Hidden items, by the Finder's flag or
  a leading dot, are left out unless asked for.
- **A read** is text only: UTF-8, or UTF-16 told by its byte-order mark or by where ASCII's zero
  bytes fall. Anything else, or text with a NUL in it, is refused with a sentence naming its type
  (`UTType`'s description, "PNG image"). At most the first 8 MB of a file is read (`scanLimit`), and
  at most 64 KB of text comes back (`readLimit`), cut at a line, with a note saying where to read on
  with `offset`; one line longer than that shows its start. A pipe or a device is never read, so a
  read cannot hang.
- **A write** carries at most 1 MB of text (`writeLimit`), refused with a pointer to `append`. It
  is UTF-8; `create` never replaces anything (`.withoutOverwriting`), `append` makes a missing
  file, and only `createFolders` makes a missing folder. A folder is never written.
- **A move** never replaces: anything already at `to` refuses it, and `to`'s folder must exist.
  The root, the home folder and a folder holding it are never moved or put in the Trash
  (`FileToolCatalog.isProtected`), whatever the rules say.

### Canonical paths

The policy weighs the path the disk would use, never the model's spelling. Before the gate is
asked, `FileToolRunner.resolved` gives each path:

- **For a list, read or write**, the deepest part that exists (checked with `lstat`, so a link
  counts) resolved through `URL.resolvingSymlinksInPath()`, and the rest appended as named; a
  path through a link to nothing is refused. So `~/Documents/key`, a link to `~/.ssh/id_ed25519`,
  is weighed as the key, which the Deny seed catches, and a new file in a linked folder as one in
  the real folder.
- **For a move's `from` and `to` and the Trash**, the folder resolved that way and the last name
  kept, since those act on the item itself: a link is moved or trashed, not what it points to.

`resolvingSymlinksInPath` drops `/private` from a path whose shorter spelling exists, so
`/private/tmp/x` is weighed as `/tmp/x`; the runner's own walk spells child paths from the resolved
folder for the same reason.

### Order of a call

`AIChatCoordinator.runFileTool`, with every disk access in `Task.detached`:

1. **Read and resolve** (`FileToolRunner.prepare`). A malformed call is a sentence and never a
   dialog.
2. **Denied?** The gate's decision for `AgentCall.files` over the resolved paths. A Deny refuses
   before the disk is asked anything else, so a denied path's existence is never told.
3. **Preflight** (`FileToolRunner.preflight`): a file that is not there, a folder where a file
   should be, a `create` over something, a missing folder without `createFolders`, a move onto
   something. Refused without asking.
4. **Ask**, through `AgentGateCoordinator.authorization(for:in:)`, with `FileToolCatalog.prompt`.
5. **Act** (`FileToolRunner.run`): resolve again from the model's spelling and refuse, with "…
   changed while the user was asked, so nothing was done.", if anything now resolves elsewhere —
   a folder swapped for a link while the dialog was up — then the preflight again, then the call.
   This narrows the window between check and act rather than closing it; `create`'s
   `.withoutOverwriting` is the one step that holds even inside it.

## Web fetch

`WebFetchToolCatalog` (`Model/`) spells one tool, `web_fetch`, under Fetch Web Pages;
`WebFetchRunner` (`Service/`) fetches, `HTMLTextEngine` (`Model/`) reads the HTML, and
`LocalNetworkPolicy` (`Model/`) says whether a URL is local. Its wire name is what makes the row
hosted. It is read-only, so Plan offers it and a public page may be allowed for the chat.

| Argument | Meaning |
| --- | --- |
| `url` | required: `http` or `https`, with a host and no user name or password; anything else is refused with a sentence the model can correct, and one with no scheme is refused with its `https://` spelling suggested |
| `maxCharacters` | text returned at most, default 20 000 (`defaultCharacters`); more is capped at 100 000 (`characterLimit`), less than 1 refused |

The session is `WebFetchRunner.session`, built as `CurrencyRateStore`'s is and narrower: a private
`.ephemeral` configuration with `urlCache = nil`, no cookie storage, `httpShouldSetCookies` false,
no credential storage, and a User-Agent naming Blitz and its version. The caps:

- **Time.** 15 s of silence per request (`requestTimeout`), and 30 s for the whole fetch,
  redirects included (`totalTimeout`), raced against it so a slow page is cancelled.
- **Size.** The body is streamed and reading stops at 5 MB (`byteLimit`); the answer says only
  the start was read.
- **Redirects.** The session declines every redirect (`RedirectRefusal`), so `follow` sees each
  3xx and checks its target with `WebFetchToolCatalog.redirectTarget` — `http` or `https`, no
  credentials, a host — before taking it; a sixth is refused. A 3xx without a `Location` is the
  answer.
- **Types.** Decided from the headers, before the body is read: HTML (`text/html`,
  `application/xhtml+xml`) is read as text, other `text/*`, JSON, XML, YAML and Markdown pass
  through as sent, and everything else — images, PDFs, archives — is refused naming the type. A
  page with no type, or `application/octet-stream`, is refused if its first 8 KB hold a NUL,
  else read as HTML when it looks like it and as text otherwise.
- **Charset.** A byte-order mark, then the header's `charset`, then a `<meta charset>` or
  `http-equiv` one in the first 8 KB; Latin-1 and ASCII labels mean Windows-1252, as browsers
  read them. Anything else, or bytes the named charset rejects, is UTF-8 with bad bytes replaced.

The answer opens with `URL:` (the final one), `Redirected from:` when it moved, `Status:` (the
code and a fixed English reason, so a 404's text comes back too), `Type:` and `Title:`, then a blank
line and the text, cut at `maxCharacters` with a note saying how many characters were left out. A
network failure is a sentence from the `URLError` code, never `localizedDescription`.

`HTMLTextEngine.page` walks the UTF-8 bytes once: comments, doctypes, `<script>` and `<style>`
(skipped to their end tag as raw text) and everything in `<noscript>`, `<svg>`, `<template>`,
`<math>` and `<head>` are dropped, except the first `<title>`, which is the answer's title; a start
tag that cannot sit in `<head>` ends it, as in a browser. Block elements break the line,
paragraph-like ones leave a blank line, `<br>` breaks once, list items start with "- ", table
cells are joined with " | ", and `<pre>` keeps its whitespace; elsewhere runs of whitespace are one
space. A link becomes "text (URL)", resolved against the final URL or a `<base href>`, for `http`,
`https` and `mailto` only, and not when its text already is the URL; an in-page `#…` link keeps
its text alone. Named and numeric entities are decoded, 128–159 as Windows-1252.

### The local network

`LocalNetworkPolicy.isLocal` reads the URL's host and never resolves it. Local is `localhost` and
anything under `.localhost`, `.local`, `.home.arpa` or `.internal`; an IPv4 literal in any spelling
the resolver takes (`127.1`, `0x7f.0.0.1`, `2130706433`) in `0/8`, `10/8`, `127/8`,
`169.254/16`, `172.16/12`, `192.168/16` or the shared `100.64/10`; an IPv6 literal that is
unspecified, loopback, `fc00::/7`, `fe80::/10` or the old site-local `fec0::/10`, or that carries
such an IPv4 address (mapped, compatible or NAT64's `64:ff9b::/96`); and an empty host.

A local-network fetch always asks, as [Invariants](#invariants) says, and its dialog adds that the
address is on this Mac or its local network. A redirect into the local network is refused with a
sentence, not asked: the user approved one URL, so a public page that bounces to `127.0.0.1` or a
router's address is never followed, and the model is told to fetch that URL itself, which asks. A
local page may still redirect on its own host — `http://192.168.1.5/` to its `/login` — since that
is the host the user allowed.

Known limits:

- **DNS is not checked.** A public name that resolves to a private address, such as a
  `*.nip.io` name or a rebinding domain, is weighed by its spelling and so as public. Resolving
  first would not close it either, since the address can change between the check and the fetch.
- **App Transport Security.** Blitz declares no ATS exception, so plain `http` to a public name
  fails; the answer suggests the `https` address. Local names and IP literals are exempt from ATS.
- **No domain rules yet.** There is no Always Allow for a site and no per-domain pattern; a row on
  Allow fetches every public page, and Ask asks per call or per chat.

## Session tools

`SessionToolCatalog` (`Model/`) spells four tools over the AI chat history, `SessionToolEngine`
(`Model/`) writes their answers, and `AIChatCoordinator.runSessionTool` runs them against
`ChatHistoryStore` and the live chats. Their wire names are what make both Sessions rows hosted.

| Tool | Row | Arguments | What comes back |
| --- | --- | --- | --- |
| `sessions_list` | Read Other Chats | `scope` (`recent` default, `archived`, `all`), `query`, `limit` (default 20, at most 50) | a count line, then a tab-separated row per chat, newest first: id, title, last active, messages, archived |
| `sessions_read` | Read Other Chats | `id`, `fromMessage` (from 1), `limit` (messages) | a header — title, id, archived, last active, message count — then each message numbered with its speaker and time |
| `sessions_archive` | Archive Chats | `id` | that it is under Archived, where the user can open it |
| `sessions_unarchive` | Archive Chats | `id` | that it is back in the sidebar |

- **Never this chat.** A listing leaves out the chat that asks, and any call naming it is refused
  without a dialog: its messages are already in the conversation, and it cannot archive itself.
- **Scope and search.** `recent` is what the sidebar lists (`ChatHistoryStore.conversations`),
  `archived` the archive, `all` both (`saved`); `query` matches the shown title or the last message,
  as the history's own search does. A listing past its limit says how many more there are.
- **A transcript** walks `ChatMessage.segments`: text as written, and one bracketed line per web
  search, tool call (origin, title, done or failed), question (with its answer) and plan (its
  title). Thinking is left out, images are counted and documents named, never inlined, and a
  reply that did not finish says so. Times are fixed digits in the Mac's time zone. At most 64 KB
  of UTF-8 comes back (`readLimit`), 100 bytes of it kept for the closing note: reading stops before
  the message that would not fit and says "Read on with fromMessage N"; a first message longer
  than the cap shows its start, cut on a character. A `fromMessage` past the end is refused with
  the count. A chat a surface holds is read live, a reply still arriving included.
- **Archive and unarchive** go through the same rules as the sidebar's Archive
  (`AIChatSurfacesState.archive`), and are narrower: a chat still answering, one open on either
  surface and a pinned one are refused with a sentence and no dialog. Archiving one already
  archived, or unarchiving one that is not, changes nothing and says so, also without a dialog.

**Order of a call.** Read the arguments (a malformed id is a sentence, never a dialog); refuse if
the row is Deny before any id is looked up, so a denied row never tells which chats exist;
settle what needs no dialog (`SessionToolEngine.settled`: this chat, an id no chat has, and the
archive refusals above), so a dialog never names a chat that is not there; ask through the gate
with `SessionToolCatalog.prompt`; settle again, since the chat may have been deleted, opened or
pinned while the dialog was up; then act. The history is read on the main actor, where
`ChatHistoryStore` lives and where opening a chat reads it too; the listing and the transcript are
written in `Task.detached`.

## Mac tools

Four rows act on the Mac, so each starts on Deny, is not read-only — Plan never offers it — and is
never allowed for the chat: an Ask is a dialog with **Allow** and **Don't Allow**, every time. Each
runs through its feature's coordinator, and the catalogs that read the calls and word the answers
live in that feature's `Model/`, harness-pinned by `mac-tool-test`.

| Tool | Row | Arguments | What comes back |
| --- | --- | --- | --- |
| `mac_open` | Open Apps, Files and Links | `target`: an app's name or bundle id, a path starting with `/` or `~`, or an `http`, `https` or `mailto` link | that it opened, and where |
| `shortcuts_list` | Run Shortcuts | `query` | a count, then one name per line |
| `shortcuts_run` | Run Shortcuts | `name` (or identifier), `input` text, at most 20 000 characters | that it ran, and what it returned as text, cut at 20 000 characters |
| `system_actions_list` | Run System Actions | none | id and name, one offered action per line |
| `system_action_run` | Run System Actions | `id` (or the action's name) | that it ran, with the launcher's feedback or the volume it landed on |
| `window_layouts_list` | Apply Window Layouts | none | name and what it arranges, one layout per line |
| `window_layout_apply` | Apply Window Layouts | `name` (or id) | the windows placed and apps opened, and what did not happen |

- **A listing asks nothing.** A `*_list` call is refused while its row is Deny, before anything is
  looked up, and otherwise answers without a dialog, an Ask row included: it names only what the
  user built and changes nothing. Running is what asks.
- **Names.** `AgentNameMatch` (AI `Model/`) finds what the model named: exactly, once case, accents
  and width are folded. Several matches are refused naming each with what tells them apart; none is
  refused with at most five near names — those starting with it, then those holding it, then
  those it holds. So a dialog never names something that is not there.
- **Order of a call.** Read the arguments (a malformed call is a sentence, never a dialog); refuse
  on a Deny row; look the name up; ask through the gate with the catalog's `AgentPrompt`; check the
  feature again, since its switch or the item may have gone while the dialog was up; then act. The
  palette is never hidden, since the chat may be on it.

### Opening

`OpenToolCatalog` (`Model/`) reads the target, `OpenToolRunner` (`Service/`) reads a path on disk,
and `LauncherCoordinator.openForAgent` opens it: an app through `AppLauncher.launch`, anything else
through `NSWorkspace.open`. Text starting with `/` or `~` is a path, text starting with a scheme is a
link, and anything else is an app's name.

- **An app** is named against the launcher's own index (`LauncherCoordinator.openToolApps`, the
  `.application` entries of `AppIndex`): by bundle id, then by its name or any alternate one — the
  localised names and a renamed copy's — with a trailing `.app` dropped. A Deny row refuses before
  the index is asked, so it never tells which apps are installed.
- **A link** is `http` or `https` with a host and no user name or password, or `mailto` with a
  recipient. `file:` is refused pointing at paths, and every other scheme is refused outright:
  `shortcuts:`, `x-apple.systempreferences:` or an app's own scheme can make an app act on its own.
  A mail link opens a new message; nothing is sent.
- **A path** goes the file tools' way: canonical, every link resolved (`FileToolRunner.resolved`,
  since opening a link opens what it points to), then the gate over `AgentCall.files(.openItems, …)`
  before the disk is asked anything else — so `~/.ssh/id_rsa`, or a link to it, is refused by its
  seed without its existence told — then the item read, then the dialog, then the path resolved and
  read again, refusing with "… changed while the user was asked, so nothing was opened." if it
  moved. Path rules only narrow an open (see [Path rules](#path-rules)), and its dialog offers no
  Always Allow.

Refused without asking, since opening them would do more than show them (`OpenToolCatalog.hazards`):

| Opening it | Extensions |
| --- | --- |
| runs code | `command`, `tool`, `terminal`, `sh`, `bash`, `zsh`, `csh`, `ksh`, `tcsh`, `fish`, `py`, `pyw`, `pyc`, `rb`, `pl`, `php`, `jar`, `jnlp`, `workflow`, `action` |
| installs into macOS | `pkg`, `mpkg`, `mobileconfig`, `prefpane`, `saver`, `qlgenerator`, `mdimporter`, `kext`, `dext`, `systemextension`, `appex`, `plugin`, `bundle`, `osax`, `component`, `xpc`, `shortcut`, `wdgt` |
| follows an address of its own | `webloc`, `inetloc`, `fileloc`, `url` |

So is a regular file with no extension and an execute bit, which Finder would run in Terminal, and a
pipe, device or socket. A folder named `.app` opens as an app. There is no tool listing apps: it
would sit under an acting row with nothing to act on, and a name that misses comes back with near
ones.

### Shortcuts

`ShortcutToolCatalog` and `AppleShortcutCoordinator.runTool`. The library is read fresh for each
call (`AppleShortcutRunner.list`), falling back to the last good read. A run is
`AppleShortcutRunner.run(id:input:)`: `shortcuts run <uuid> --output-path <file>`, with
`--input-path` naming a file that holds the input, in a temporary folder removed afterwards. As in
the launcher there is no timeout, since a shortcut may wait on a dialog of its own, but stopping the
chat ends it: `ToolRunner` terminates its tool when its task is cancelled. Output that is UTF-8 with
no NUL comes back trimmed and cut at 20 000 characters; anything else is said not to be text, and a
failure is the tool's last lines.

### System actions

`SystemActionToolCatalog` and `SystemActionCoordinator.runTool`. With the category off the row is
Deny by its ceiling; hiding one action from the launcher does not withhold it. These are excluded
entirely — never in the schema's `enum`, never listed, refused by id or name with the reason:

| Action | Why |
| --- | --- |
| Restart, Shut Down, Log Out | it ends the session, closing every app and this chat |
| Empty Trash | it deletes what is in the Trash for good |
| Quit All Applications | it quits every app at once, and unsaved work may be lost |
| Eject All Disks | a disk comes back only once someone plugs it in again |
| Toggle Bluetooth | turning it off can cut off the keyboard and mouse that would turn it back on |
| Dismiss Notifications | a dismissed notification cannot be brought back |
| Set Volume… | it asks for a level in a dialog of its own; the fixed levels are offered instead |

Every action the launcher confirms first is among them, and the harness pins that. The rest run as
the launcher runs them, against `PaletteCoordinator.targetApp`: volume and mute still show the
volume HUD and answer the level, another action answers its pill's text, and a failure is its
message, never a dialog. A microphone toggle while one is pending is refused.

### Window layouts

`WindowLayoutToolCatalog` and `WindowLayoutCoordinator.runTool`. Accessibility is checked, never
prompted for: without it the call is refused with a sentence before any dialog, since macOS's own
request belongs to a gesture of the user's. After the dialog the switch and the layout are read
again; the run replaces any run in progress, as the funnel's does, and the answer counts the windows
placed and apps opened, adding the launcher's own summary of what did not happen. A run that placed
nothing is an error. There is no tool to move one window: while the agent runs, the frontmost window
is usually the chat itself.

## Personal and context tools

Eight read rows and one write, each run through its feature's coordinator — or, for the context
rows, which belong to no feature, `ContextToolRunner` (`Service/`) — with the catalog that reads
the calls and words the answers in that feature's `Model/` (`ContextToolCatalog` in AI's),
harness-pinned by `personal-tool-test`. Every read is offered in Plan and may be allowed for the
chat; Add to the Note is Deny by default, never in Plan and asked every time.

| Tool | Row | Arguments | What comes back |
| --- | --- | --- | --- |
| `contacts_search` | Read Contacts | `query` (name, email, phone or company), `limit` (default 10, at most 25) | JSON: the query, how many cards matched, how many are shown, and each card's name, company, labelled emails, phones and postal addresses, and birthday |
| `note_read` | Read the Note | none | the note the Notes window shows, by its title, cut at 64 KB |
| `note_append` | Add to the Note | `text`, at most 20 000 characters | how much was added, and to which note |
| `clipboard_history` | Read Clipboard History | `query`, `limit` (default 10, at most 50) | a count, then each entry numbered, newest first, with when it was copied, the app it came from, pinned and its title; text cut at 2 000 characters, an image as "[image]" with its pixel size, a file as "[file]" and its path |
| `snippets_list` | Read Snippets and Quicklinks | `query` | a count, then name, keyword and the first 80 characters of each enabled snippet |
| `snippets_read` | Read Snippets and Quicklinks | `name` (or keyword) | the template as written, placeholders unfilled, cut at 64 KB |
| `quicklinks_list` | Read Snippets and Quicklinks | `query` | a count, then name, link template and tags of each enabled quicklink |
| `context_frontmost_app` | See the Frontmost App | none | the app's name and bundle ID, and its focused window's title — or that it has none, or that Accessibility is not granted |
| `context_selected_text` | Read Selected Text | none | the selection in that app, cut at 64 KB |
| `context_clipboard` | Read the Clipboard | none | the text on the pasteboard, cut at 64 KB; else copied files' paths; else what kind of content it is and its first five types |

- **Order of a call** is the Mac tools': read the arguments (a malformed call is a sentence,
  never a dialog); refuse on a Deny row before anything is looked up
  (`AIChatCoordinator.runFeatureTool`); then the feature checks its switch and settles what needs
  no dialog; asks through the gate with its `AgentPrompt`; checks its switch again, since it may
  have gone off while the dialog was up; then reads.
- **One row, two features.** Read Snippets and Quicklinks is available while either feature is
  on, but `snippets_*` is offered only while Snippets is on and `quicklinks_list` only while
  Quicklinks is (`SnippetCoordinator.chatTools`, `QuicklinkCoordinator.chatTools`), and each
  refuses with the denied sentence while its own feature is off. A disabled snippet or quicklink
  is offered nowhere, so neither lists it, and a snippet is never expanded: expanding would read
  the clipboard and the date.

### Contacts

`ContactsCoordinator.runTool` reads nothing before the dialog. A search needs Contacts on, macOS's
grant and the address book's first read finished (`ContactsStore.hasLoaded`), each checked before
and after asking. It then matches with `ContactDirectory.matching` — the list's own search, every
word in a name, an email address or the company, or a dialled number — and only the cards it
returns are read again, off main, by `ContactsStore.toolCards`, which fetches the full-name keys
plus `ContactToolCatalog.fetchedKeys`: company, phones, emails, postal addresses and birthday.
`CNContactNoteKey` and the image keys are never asked for, so a note or a photo cannot come back;
the harness pins that list. A birthday kept without its year comes back as `--MM-DD`.

### The note

`NotesCoordinator.runTool` acts on the active note — the one the Notes window shows, or would
show — loading the collection first, as showing the window does, if nothing has yet; with no note
at all it refuses. The dialog names the note, and if another note became active while it was up
the call is refused. An addition goes on a line of its own at the end
(`NoteToolCatalog.addition`): when the editor holds the note it lands as one undoable edit through
`NoteTextView.performEdit`, leaving the caret where it was, so it reaches the draft, autosave and
the formatting the way typing does; otherwise it is written into the draft. Either way the draft is
flushed before the answer, and a save that fails is reported to the reader as any save is and
refused to the model. Nothing already in the note is ever changed.

### Clipboard history

`ClipboardCoordinator.runTool` reads the history the palette holds — the newest 1000 entries and
every pin (`ClipboardStore.items`) — never the full-text index or recognised text. What capture
never stored stays out: copies marked `org.nspasteboard.ConcealedType`,
`org.nspasteboard.TransientType` or `com.apple.is-sensitive` (`PasteboardSensitivity`, shared with
`ClipboardManager`), and anything copied in an app on the clipboard's ignore list at the time. An
entry whose source app was added to that list since is left out too
(`ClipboardToolCatalog.entries`). The source app is named through Launch Services, and an image's
pixel size is read off main with `ImageThumbnail.pixelSize`; its pixels never go.

### Context

The context rows read the reader's app, never Blitz. `ExternalAppMonitor` (`Platform/`, owned by
`AppCore` and started in `start()`) records every app other than Blitz that becomes active
(`NSWorkspace.didActivateApplicationNotification`); its `app` is the frontmost app when that is not
Blitz — the palette is non-activating, so the app behind it stays frontmost — else the last other
app to be, unless it has quit. So a chat in the AI Agent window reads the app the reader left to
type in it.

- **The frontmost app** is named in the dialog. Its focused window's title is read through
  Accessibility (`AccessibilityText.windowTitle`, off main) only when the grant is there, and the
  answer says when it is not.
- **The selected text** is `AccessibilityText.read`, off main, as Quick Actions reads it, but
  without the borrowed ⌘C fallback: posting a keystroke into the reader's app is not a read.
  Accessibility is checked, never prompted for. No app, no focused text element and an empty
  selection are each refused with a sentence before any dialog; the text read then is what goes
  back once allowed.
- **The clipboard** is read on the main actor. A copy carrying a `PasteboardSensitivity` marker is
  refused before its text or files are read, and an empty clipboard is a sentence; neither asks.
  Copied files win over the names Finder adds as text. The dialog names only the kind and size —
  "text, 42 characters" — and a pasteboard whose `changeCount` moved while the dialog was up is
  refused rather than read.

## Memory

The agent keeps what the reader asked it to remember: short facts and preferences, one sentence
each, that every later chat should know. Two rows govern it — Read Memory, whether turns carry the
memories, and Change Memory, the two tools that add and take out — and the reader edits the list
in Settings.

### Storage

`AgentMemoryStore` (`Service/`, owned by `AppCore` as `agentMemory`) holds `[AgentMemory]`, oldest
first, in `agent-memory.json` under the bundle's Application Support folder — a dedicated file, not
a table in `ai-chats.sqlite3`. `ChatHistoryStore` owns transcripts and their lifecycle: Delete All
Chats, retention's prune and `VACUUM`, and closing the handle when AI goes off. A memory outlives
every chat, so it has no place in that lifecycle, and a second owner on one SQLite file would split
it; 12 KB of text needs no SQL either. Each memory is:

| Field | Meaning |
| --- | --- |
| `id` | an integer from a counter stored beside the list that only grows, so `m3` never names a later memory, even after Forget All |
| `text` | at most 500 characters (`textLimit`), on one line: runs of whitespace collapse to one space |
| `createdAt` | when it was added; an edit keeps it, and the id |
| `sourceConversation` | the chat that remembered it, nil from Settings; informational, so deleting that chat keeps the memory |

- **Limits.** At most 100 memories (`countLimit`) and 12 KB of UTF-8 across them (`byteLimit`),
  since every one rides in every turn. `AgentMemory.admission` is the one rule, for the tool and
  Settings alike: blank is empty, over 500 characters is too long, identical once case and
  whitespace are set aside is a duplicate, and past either limit is full. An edit is weighed
  without its own old text.
- **Loading.** `load()` runs once, from `AIChatCoordinator.applyEnabled` with AI on and from the
  Settings section; nothing is read with AI off, and nothing is written until something is kept. A
  missing file is an empty memory. One that will not decode leaves the store unavailable: the file
  is the reader's own words, so it is never replaced, and every change is refused.
- **Writes** are atomic, the whole file each time.

### What a turn carries

`AIChatCoordinator.instructions(for:)` appends `AgentMemoryInstructions.block` after the preamble
and the reader's prompt and before a mode's instruction, whenever `AgentPolicy.readsMemory` — Read
Memory on Allow and the chat's `usesMemory` on — and something is remembered:

```
The user asked you to remember these, oldest first. Use them where they help. To forget one, call memory_forget with its id.
- m1: Prefers metric units
- m3: Lives in Berlin
```

The forget sentence is there only while the turn can call `memory_forget`: the route reaches
Blitz's tools and Change Memory is offered to the chat. Every route carries the block, Apple
Intelligence, Codex and the CLIs included, and so does a turn with Use Tools off or in Plan, since
no call reads it. On Apple Intelligence it is held to `AgentMemoryInstructions.onDeviceBudget`,
1 500 bytes: the newest memories that fit, still oldest first, then "(N older ones left out.)".
Codex starts a new thread when the instructions change, so remembering something there costs the
retained context of the conversation, as a system prompt edit does.

There is no tool to list memories: the block is the read path, already in the model's
instructions with the ids it needs.

### The tools

`MemoryToolCatalog` (`Model/`) spells both, under Change Memory; `AgentMemoryCoordinator.runTool`
runs them, reached through `AIChatCoordinator.runFeatureTool`, which refuses a Deny row before
anything remembered is looked up.

| Tool | Arguments | What comes back |
| --- | --- | --- |
| `memory_remember` | `text`, required, at most 500 characters | "Remembered as m4.", and that it is in every chat's instructions from now on |
| `memory_forget` | `id` (`m3`, `M3` or `3`) or, without one, the exact `text` | "Forgot m3: “…”." |

**Order of a call.** Read the arguments (a malformed call is a sentence, never a dialog); refuse on
a Deny row; settle what needs no dialog (`MemoryToolCatalog.settled`) — a duplicate answers "That
is already remembered as m3; nothing was added." without being an error, a full memory refuses
asking the model to have the reader forget something first, and a memory to forget that is not
there is refused; ask through the gate with `AgentPrompt.remember` or `.forget`; settle again,
since Settings may have changed the memories while the dialog was up, and refuse a forget whose
memory was edited meanwhile; then act. A write that fails is a sentence, and nothing changes.

### Settings

**Settings → AI → Memory** (`AgentMemorySettingsView` around `AgentMemorySection`), its own pane
after Rules, lists every memory newest first, as its text over its id and date, with **Edit** and
**Forget** buttons. Edit turns that one row into a field — one at a time, so a hundred memories still list as plain text, as
[UI](../ui.md#settings) asks of a long list — where Return saves and Escape cancels; leaving the
field saves too. A refused edit stays open on Return and is dropped on leaving, the HUD saying why
(a duplicate, full). **Add Memory** opens the same field above the list. **Forget All…** asks
through Blitz's own confirmation (`AgentMemoryCoordinator.forgetAll`). The footer says that while
Read Memory is Allow every memory goes to the model's provider with every turn, and that memories
stay on this Mac and are never in a backup. Every change goes through `AgentMemoryCoordinator`.

The tools menu's **Use Memory** is the per-chat opt-out, offered while Read Memory is Allow. It
lives in the menu a route that cannot call tools shows disabled, so on Apple Intelligence the
Settings row is the only switch. Quick AI has no menu: its turns always carry the memories while
the row allows them.

## The gate and its dialogs

`AgentGateCoordinator`, owned by `AIChatCoordinator`, is the one gate. Every route reaches it:

- **Blitz's own tools.** `AIHostedTools` serves the loop and the Claude command alike. Each runner
  reads its arguments first, so a malformed call is a sentence and never a dialog, then puts its
  `AgentPrompt` to the `AgentAuthorization` the gate bound to that call.
- **MCP on the loop.** `AIChatCoordinator` asks the gate first; `MCPCoordinator.invoke` only runs
  what the gate let through.
- **MCP on Codex and Claude.** `AIToolServerSession.consent` — Codex's elicitation, Claude's
  `can_use_tool` — calls `AgentGateCoordinator.authorize`. A Claude question about Blitz's own
  `ClaudeHostedServer` is allowed there, because the runner behind it asks the gate itself.

`authorize` weighs an MCP call by what its server listed, `MCPCoordinator.listedTools(slug:)`, so in
Plan a CLI's call to a tool without the hint, or to one the list lacks, is Deny. `ask_user` and
`write_plan` never reach the gate: their runners check `AgentPolicy.isOffered(_:scope:)` and answer
themselves.

On Allow the call runs. On Deny it fails with `AgentRefusal.denied`'s sentence, "Blitz's agent rules
do not let the model …". On Ask the gate opens a request on the chat (`AIChatState.beginApproval`),
which is what makes the chat's `awaiting` read `.approval`, and then:

1. **Held.** While the chat is off screen the request waits on the chat (`holdApproval`), with no
   dialog and no place in the queue, until the chat comes on screen
   ([what releases it](#held-requests)) or the request ends.
2. **Queued.** On screen, it joins the gate's `AIConsentQueue`, one dialog for every chat, since
   `DialogController` refuses a second.
3. **Its turn.** A request that ended while it queued is declined without being shown; one whose
   chat has left the screen goes back to step 1. Otherwise the decision is read again — an earlier
   dialog may have answered it — then Blitz's own dialog goes up through `core.choose`, the choice
   is applied, and the decision is read once more, so a row set to Deny while the dialog was up
   still refuses.

However it ends, the request closes (`endApproval`). A decline is `AgentRefusal.declined`, "The
user declined to let the model …"; the CLI routes send their own fixed decline instead.

| Call | Title | Choices (↵ marked) |
| --- | --- | --- |
| Shell | Run this command? — the command verbatim and its folder | **Run** ↵, Always Allow "`<pattern>`" when one is suggested, Don't Run |
| Calendar or reminders read | Let the agent read your calendar? / your reminders? | **Allow** ↵, Allow This Chat, Don't Allow |
| Calendar write | Add "`<title>`" to your calendar? — the event summary | **Allow** ↵, Don't Allow |
| Reminders write | Add "`<title>`" to Reminders? / Change "`<title>`"? / Complete "`<title>`"? | **Allow** ↵, Don't Allow |
| MCP server | Let `<server>` run its tools? — the tool's name | Always Allow, **Allow This Chat** ↵, Don't Allow |
| `files_list` | Let the agent list "`<folder>`"? — what it sees, how deep, and that it goes to the provider | **Allow** ↵, Allow This Chat, Always Allow "`<folder>/**`", Don't Allow |
| `files_read` | Let the agent read "`<file>`"? — that it goes to the provider | **Allow** ↵, Allow This Chat, Always Allow "`<folder>/**`", Don't Allow |
| `files_write` | Let the agent write to "`<file>`"? — create, replace or add to the end, with the size | **Allow** ↵, Always Allow "`<folder>/**`", Don't Allow |
| `files_move` | Let the agent move "`<from>`"? — To "`<to>`" | **Allow** ↵, Always Allow "`<folder>/**`", Don't Allow |
| `files_trash` | Let the agent move "`<path>`" to the Trash? — It can be put back from the Trash. | **Allow** ↵, Always Allow "`<folder>/**`", Don't Allow |
| `web_fetch` | Let the agent open `<host>`? — the full URL, and that it goes to the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `web_fetch`, local network | Let the agent open `<host>`? — the URL, the provider, and that the address is local | **Allow** ↵, Don't Allow |
| `sessions_list` | Let the agent list your chats? — what it sees and can search, and that it goes to the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `sessions_read` | Let the agent read your chat "`<title>`"? — that it goes to the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `sessions_archive` / `sessions_unarchive` | Let the agent archive "`<title>`"? / unarchive "`<title>`"? — where it goes | **Allow** ↵, Don't Allow |
| `mac_open`, an app | Let the agent open `<app>`? — that it launches or comes forward | **Allow** ↵, Don't Allow |
| `mac_open`, a path | Let the agent open "`<path>`"? — its default app, Finder, or the app it is | **Allow** ↵, Don't Allow |
| `mac_open`, a link | Let the agent open `<host>` in your browser? / a new mail to `<address>`? — the link | **Allow** ↵, Don't Allow |
| `shortcuts_run` | Let the agent run the shortcut "`<name>`"? — the input, clipped, and that its output goes to the provider | **Allow** ↵, Don't Allow |
| `system_action_run` | Let the agent run "`<action>`"? | **Allow** ↵, Don't Allow |
| `window_layout_apply` | Let the agent apply the window layout "`<name>`"? — what it arranges, and that it opens apps | **Allow** ↵, Don't Allow |
| `contacts_search` | Let the agent search your contacts for "`<query>`"? — the fields it sees, never notes or photos, and the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `note_read` | Let the agent read your note? — the note's title and the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `note_append` | Let the agent add to your note? — the note's title and the text, clipped | **Allow** ↵, Don't Allow |
| `clipboard_history` | Let the agent read your clipboard history? — how many entries, the query, and the provider | **Allow** ↵, Allow This Chat, Don't Allow |
| `snippets_list` / `snippets_read` | Let the agent list your snippets? / read the snippet "`<name>`"? | **Allow** ↵, Allow This Chat, Don't Allow |
| `quicklinks_list` | Let the agent list your quicklinks? | **Allow** ↵, Allow This Chat, Don't Allow |
| `context_frontmost_app` | Let the agent see that you are using `<app>`? — name, bundle ID and window title | **Allow** ↵, Allow This Chat, Don't Allow |
| `context_selected_text` | Let the agent read the text selected in `<app>`? | **Allow** ↵, Allow This Chat, Don't Allow |
| `context_clipboard` | Let the agent read the clipboard? — its kind and size, never its content | **Allow** ↵, Allow This Chat, Don't Allow |
| `memory_remember` | Let the agent remember this? — the text as stored, that it goes to the provider with every chat, and where to forget it | **Allow** ↵, Don't Allow |
| `memory_forget` | Let the agent forget "`<text>`"? | **Allow** ↵, Don't Allow |

The wording and choices are `AgentPrompt`'s, in `Model/`. Escape is always the last choice, a
refusal of that one call; only Settings withholds a tool for good.

- **Always Allow "`<pattern>`"** places the pattern through `AISettingsStore.allowShellPattern`, as
  [Shell patterns](#shell-patterns) describes; Settings' Add Shell Rule appends through
  `addShellRule` instead.
- **Always Allow "`<folder>/**`"** on a file dialog places a Read rule for a read and a Write rule
  for a write through `AISettingsStore.allowPathPattern`, as [Path rules](#path-rules) describes.
  The paths shown are the resolved ones. It is offered only when every path of the call proposes
  the same pattern (`FileToolCatalog.suggestedPattern`), so a move between two folders, a path in
  home, at the root or under a seed offers none.
- **Always Allow** on a server sets its trust to `.always` through `MCPCoordinator.setTrust`.
- **Allow This Chat** is offered only where `AgentTool.canAllowForSession` — every read-only row but
  web search and Read Memory, and MCP servers; a write or a command is asked each time. The gate writes the grant onto the asking chat's
  `AgentSessionScope.granted`, and only while that chat still shows the conversation that asked;
  `AgentPolicy` turns that row's Ask into Allow from it, in Plan too. It never lifts a Deny, and
  never answers a local-network fetch, whose dialog does not offer it.

Auto raises no dialog but one: every Ask is Allow before the gate would ask, except a
local-network fetch, which the policy holds at Ask.

## The session scope and the composer

`AgentSessionScope` lives on `AIChatState.agentScope` and is never stored: a new chat, a reopened
one, or deleting the open one starts it fresh. It holds `isEnabled`, the `excluded` tools, the
`mode`, `usesMemory` and the `granted` tools, so a chat grant ends exactly when the scope does. A server added
later arrives switched on.

The AI Agent window's ⌘K menu has a Tools submenu (`AIChatActionsMenu.toolsItem`) that edits what
the chat may call:

- **Use Tools** — off offers nothing, Blitz's tools, `ask_user` and every server alike.
- **Blitz** — one switch per hosted built-in row the table does not deny, on a route that reaches
  Blitz's tools (`AIChatCoordinator.listedBuiltInTools`); web search, the provider's own, is not
  among them.
- **MCP Servers** — one switch per server the table does not deny.
- **Memory** — **Use Memory**, while Read Memory is Allow. Off keeps this chat's turns from
  carrying the memories; on by default, and Use Tools leaves it alone, since memory is no tool.
- **Agent Settings…** opens Settings → AI → Agent.

Its badge counts what is on, "`n` of `m`". A route that cannot call tools has no Tools row, and
with nothing the table allows the submenu says so. The menu lists the table's reach in
Manual whatever the mode, so a switch never vanishes when Plan would refuse its tool.

The composer's mode pill (`AIModePicker`) follows the model menu, only where `AIChatCoordinator.offersModes`:
a route that calls tools and reaches Blitz's — an API connection or the Claude command, never
Codex, which reaches no `write_plan` to plan with. Each entry is the mode's title, `summary` and
glyph, and the pill shows the current one. Auto's pill is filled and tinted with the warning
colour, since its calls run without a dialog. `setMode` keeps a chat with no picker in Manual, and
`selectModel` drops the chat back to Manual when the new route has none, so a mode nobody can see
never applies.

Quick AI has neither menu nor pill, so its scope stays open and Manual: the same gate and rules,
every tool the table offers, `ask_user` included.

The ⌘K menu's Web Search switch appears only where the route searches and the Web Search row is
Allow (`AIChatCoordinator.offersWebSearch`). It flips `aiWebSearch`, off by default, and a turn
searches only with both. The context card's **Tools** section opens on a **Mode** row where the
route offers modes, then lists each tool the next turn is offered with the decision a bare call to
it would get, grants, scope and mode included, or one "Offered: None" row; its **Web search** row
says whether the next turn searches, and its **Memory** row how many memories it carries — the
newest that fit on Apple Intelligence — "None", or "Off". A server's row is `AgentCall.server(_:listed:)` over
`MCPCoordinator.listedTools(slug:)`, so in Plan it shows while any listed tool is read-only, and a
CLI route's server Blitz has never listed is missing until a Plan turn lists it.

## Waiting off screen

A turn keeps running while its chat is left — the window closed or behind another app, the palette
dismissed, another chat opened — and so do its Ask requests and questions. Nothing is shown where
nobody looks: the request is held, and the chat shows that it waits.

### On screen

`AIChatCoordinator.isOnScreen(_:)` is the one definition, and the gate and the notifications both
ask it. It feeds `ChatPresence` (`Model/`) the facts, and `AIChatSurfacesState.surface(of:)` says
which surface holds the chat:

- **The window's chat** is on screen while the window is open, not minimized, visible and not wholly
  covered or on another Space (`AppWindowController.isOnScreen`, from `occlusionState`), and Blitz
  is the active app, so a dialog lands where the reader looks.
- **Quick AI's chat** is on screen while the palette is up on Quick AI's conversation
  (`PaletteMode.ai`); its Chat History is a list, not the conversation.
- **A chat parked answering** while another took the window is on screen nowhere.

### Held requests

`AIChatState` keeps the turn's requests in an `AgentApprovals`: each one is begun, may be held once
with its waiter, and ends once. `AIChatCoordinator` releases every live chat's held requests that
are now on screen, oldest first (`AIChatState.releaseApprovals`), whenever something could have
brought one on screen:

- Blitz becomes active (`NSApplication.didBecomeActiveNotification`);
- any window's occlusion changes (`NSWindow.didChangeOcclusionStateNotification`), which covers the
  window being opened, uncovered, unminimized or brought to this Space;
- the window's chat or Quick AI's changes, or the palette shows, hides or changes mode — read through
  Observation, never a reply's text.

The observers start with the feature, in `applyEnabled`, and stay; with AI off nothing waits. A
released request joins the dialog queue as any other, and a task cancelled while it is held is
declined at once.

### The badge and the dot

`AIChatCoordinator.trackWaits` re-reads every live chat's `awaiting` under Observation and keeps the
reading on `AIChatSurfacesState.waits`, written only when a chat's wait starts, ends or changes kind,
so a streaming reply's flushes reach nothing else.

- **Sidebar.** A row whose chat waits shows `AgentWait.symbol` — `hand.raised.fill` for an
  approval, `questionmark.bubble.fill` for a question — in `Theme.Colors.warning`, in place of the
  spinner, labelled "Waiting for approval" or "Waiting for an answer".
- **Menu bar.** `MenuBarLabel` swaps in a dot cut into the icon's corner while
  `AIChatSurfacesState.isAnyWaiting`, labelled "the agent is waiting". It counts every live chat,
  on screen or not.

### Notifications

`AgentNotificationPresenter` posts and withdraws them; `AppCore` owns it as `agentNotifications`
and makes it `UNUserNotificationCenter`'s delegate in `start()`, before any notification can be
clicked. It is the app's only notification delegate.

- **One per wait that starts off screen.** `AgentWaitEpisodes.changes(from:to:)` turns two readings
  of `waits` into the waits that started and ended; a wait that changes kind ends and starts again,
  since its notification names the old kind. A start posts only while
  `AISettingsStore.notifiesWhenWaiting` is on and the chat is off screen at that moment. A wait that
  started on screen posts nothing, even once the chat is left; its badge and the dot still show.
- **What it says** is `AgentWaitNotice`'s: "Blitz is waiting for approval" over the chat's title, or
  "Blitz has a question" over the title and the question on one line, cut at a word near 140
  characters (`AgentWaitNotice.clipped`). The app's display name stands in for Blitz, so a Dev build
  says Blitz Dev. It plays the default sound and carries no actions: an Ask is answered in Blitz,
  never from the notification.
- **One identifier per chat**, `agent-wait-` and the chat's UUID (`AgentWaitNotice.identifier(for:)`),
  so a later wait replaces an earlier one rather than stacking; `userInfo` carries the chat's ID
  under `AgentWaitNotice.chatKey`.
- **Withdrawn when the wait ends**, pending or delivered (`withdraw(chatID:)`), however it ended. A
  post that lands after its wait ended withdraws itself, and quitting withdraws every one still
  showing (`withdrawAll`, from `AppCore.prepareForTermination`).
- **Permission is asked on first need**, for alerts and sound, never at launch. Denied or never
  answered posts nothing; the badge and the dot are the whole signal then.
- **`willPresent`** shows the banner even with Blitz in front, since the waiting chat may not be the
  one on screen, unless the wait has been withdrawn or its chat is on screen by then.
- **A click** calls `AIChatCoordinator.openWaitingChat(id:)`: nothing with AI off; otherwise it hides
  the palette, opens the chat in the window — a Quick AI chat moves over whole, reply and all — and
  shows the window. The chat is then on screen, so its held request goes on to its dialog, or its
  question card is there to answer.

**Settings → AI → Agent → Notify when the agent is waiting** is `notifiesWhenWaiting`, on by
default, stored under `AppSettingsKey.aiNotifyWhenWaiting`. Off withholds the notification only.
Unlike the rule table it grants nothing, so `settings.json` carries it as `ai.notifyWhenWaiting`;
it stays out of backups with the rest of the AI setup (`SettingsBackupCoverage.deliberatelyExcluded`).

## Settings and storage

The agent has three panes of its own in Settings' AI group, after AI and before Providers, each
dimmed with "Turn on AI first." (`AITurnedOffNotice`) above it while AI is off:

- **Agent** (`AgentSettingsView` around `AgentSettingsSection`) — the built-in rows under a small
  header per `AgentTool.Group`, in `builtIn` order, each a picker disabled with its ceiling's
  sentence ("Turn on Contacts first.", "Allow Blitz Accessibility access first.") while
  `AgentFeatureCeiling` holds it; then, under an MCP Servers header, a picker per server, written to
  its trust and disabled while MCP or the server is off; **Tool call rounds**; and **Notify when the
  agent is waiting** ([Notifications](#notifications)). Three groups build with the pane and the
  rest follow one per frame, at once for a search result into the pane ([UI](../ui.md#settings)).
- **Rules** (`AgentRulesSettingsView`) — **Shell rules** and **Path rules**, each a list of
  read-only `AgentRuleRow`s: the rule's place (the first match wins), its pattern in code type
  ("Empty pattern" when blank), a badge for its access on a path rule and its decision, and a
  chevron. A row opens the rule's page (`AgentRulePage`, page string `shell:<uuid>` or
  `path:<uuid>`, `AgentRuleRoute`) with its pattern field, a Decision picker, an Applies to picker
  (Read & Write, Read, Write) for a path rule, Move Up and Move Down, and **Delete…**, which asks
  first; a page whose rule is gone falls back to the list. **Add Shell Rule** and **Add Path Rule**
  add an empty Allow pattern and open its page with the field focused. An empty pattern matches
  nothing. Each footer — on the list and the page — explains matching: for paths `~`, `*` and
  `**`, that a Deny always wins, and that paths are checked once symlinks resolve, ignoring case.
- **Memory** (`AgentMemorySettingsView`) — what the agent was asked to remember; see
  [Memory](#memory).

`AISettingsStore.agentRules` is the table, encoded as JSON under `AppSettingsKey.aiAgentRules`.
Loading it:

| Stored | Result |
| --- | --- |
| `aiAgentRules` that decodes | that table; a row, `shellRules` or `pathRules` it lacks takes its default or the seeds |
| `aiAgentRules` that does not decode | `AgentRules.defaults`; no old key is read or removed |
| no `aiAgentRules`, no old key | `AgentRules.defaults`, written under the new key |
| no `aiAgentRules`, any old key | `AgentRules.migrated`, written under the new key; the old keys are removed |

`AgentRules.migrated` keeps what the old settings did:

| Old value | Read row | Write row |
| --- | --- | --- |
| Calendar or Reminders Off | Deny | Deny |
| Calendar or Reminders Read Only | Allow | Deny |
| Calendar Read & Write | Allow | Ask — it always confirmed |
| Reminders Read & Write | Allow | Allow — it wrote straight away |
| `aiShellCommands` on / off | shell Ask / Deny | |

Web search migrates as Allow, every row added since takes its default and `pathRules` its seeds.
`AIDataAccess` survives only to read the old values, and the three
old keys stay in `SettingsBackupCoverage.deliberatelyExcluded` until this migration is deleted.

## Routes

| Route | Blitz's tools | MCP servers | Who asks |
| --- | --- | --- | --- |
| API connection | through `AIToolLoopProvider` | through the loop, Blitz as client | the gate, per call |
| Claude command | `ClaudeHostedServer`, an in-process `sdk` server | handed to the CLI | the gate: Blitz's tools in their runners, servers through `can_use_tool` |
| Codex | never | handed to the CLI | the gate, through Codex's elicitation |
| Apple Intelligence, Grok, OpenCode, Cursor | none | none | — |

`AIModelSelection.reachesBlitzTools` is false only for Codex, and `AIModelCapabilities.tools` is
false for the last row. `@server` addresses one server, so Blitz's own tools — `ask_user` and
`write_plan` included — sit that turn out, and the loop refuses a call to either with its
`notOffered` sentence. A Codex chat's title request borrows the reply's servers and refuses every
call.

Each route honours the mode where it decides what to offer:

- **API connection.** The loop is offered Blitz's tools and each MCP tool on its own,
  `AgentCall(_:)` over the listing Blitz's own connection holds, so Plan offers only a server's
  read-only tools; every call is decided again at the gate.
- **Claude command.** Blitz's tools as on the loop, through `ClaudeHostedServer`. The CLI is handed
  whole servers, so outside Plan a server goes while its row is not Deny, and in Plan only once one
  of its tools is read-only. `MCPCoordinator.listTools(of:)` answers that: Blitz's own listing
  while its connection is ready, else one short-lived connection of its own, kept by server until
  the server is saved or removed or MCP goes off. A server whose list was empty is listed again on
  every Plan turn. Consent then weighs each call by that list, as [the gate](#the-gate-and-its-dialogs)
  says. The CLI's own boundary follows the mode too: an armed Plan turn
  (`AIToolServerSession.readsOnly`) is told the supplied tools may only read, investigate, ask the
  user or write the plan and that nothing may be changed, where any other armed turn is told
  whatever a supplied tool does is allowed. Consent enforces Plan either way; the wording only keeps
  the boundary from contradicting Plan's instruction.
- **Codex.** No mode pill, so always Manual; it reaches neither `ask_user` nor `write_plan`.

## Harnesses

- `agent-policy-test` — the splitter's splits and refusals, glob matching, decision order, wire
  names, the rows' groups and order, which rows are hosted, the MCP trust mapping, defaults and the
  web-search rule, migration, `Codable` and its tolerance of a table stored before later rows, path
  matching (`*` and `**`, `~`, a trailing `/**`, `..`, case, relative paths), the seeds, path
  precedence and a move's narrowest path, the suggested path pattern (a listed folder's own too),
  Always Allow for a path, the file dialogs' choices, the
  session
  scope, the policy's precedence and offers, the suggested pattern and `neverSuggested`, calls from
  the wire, every `AgentPrompt`, both refusals, chat grants on the scope, Always Allow's placement,
  each mode's decisions and offers, the new reads offered in Plan and the new writes refused, MCP
  tools weighed one at a time and servers handed to a CLI in
  Plan, `ask_user` and `write_plan` offered by mode, their schemas, argument checks and results,
  the plan instruction, and the context card's rows per mode; `web_fetch`'s wire name and row; the
  Sessions rows — their group and order, wire names, hosting, defaults, Plan offering the read and
  refusing the archive, tolerant decoding without them — and their three dialogs; the Mac rows'
  wire names and hosting, and which rows weigh paths and take Read rules; the personal and
  context catalogs' wire names, and each read catalog's names on a read row; the Memory rows —
  their group, wire names, Read Memory unhosted with no Ask and Allow by default, Change Memory on
  Ask, never for the chat and never in Plan, tolerant decoding without them — and
  `AgentPolicy.readsMemory` under Use Memory, Use Tools off and each mode.
- `personal-tool-test` — the ten personal and context schemas, wire names and rows, each read
  allowable for the chat and the addition never; call reading and its refusals (queries, limits
  and their caps, a blank or oversized addition, arguments that are not an object); contact cards
  as JSON, a birthday without its year, and `fetchedKeys` without the note or any image key; the
  addition on its own line, the note and a selection cut at 64 KB between characters; clipboard
  entries newest first without an ignored app's copies, matched by text or title, each line's time,
  source, pin and title, images with and without a size, files, and a long entry cut; snippets
  listed without disabled ones, previewed on one line, found by name or keyword, two of one name
  told apart, near names, and a template read whole or cut; quicklinks with their templates and
  tags; the frontmost answer with a title, none, or no Accessibility; each `PasteboardSensitivity`
  marker refusing a fixture pasteboard, files before Finder's names, empty and non-text contents;
  and every dialog's wording and choices.
- `memory-test` — `AgentMemory`: cleaning, the key, ids read from a handle, and admission (empty,
  500 characters and 501, a duplicate ignoring case and spacing, an edit never its own twin, the
  101st memory, the byte budget in UTF-8); both schemas and wire names, call reading and its
  refusals, what settles without a dialog (a duplicate as no error, full, an unknown id or text,
  nothing remembered), both dialogs' wording and choices, the answers and both refusals; the block
  a turn carries — format, ids, oldest first, the forget sentence only when offered, clipping to a
  budget from the oldest with its note, nothing for no memories — and where it is appended; and
  `AgentMemoryStore` in a scratch folder — nothing written before a load or until something is
  kept, a reload, an edit keeping id and date, removal, ids never reused across Forget All and a
  reload, and a file that will not decode refused and left as it was.
- `quicklink-coordinator-test` — `QuicklinkCoordinator.runTool` asks once before listing, answers
  a decline with it, and with Quicklinks off refuses before asking and offers nothing.
- `mac-tool-test` — the seven Mac schemas and wire names, the rows not read-only and never allowed
  for the chat, Deny by default and never offered in Plan; `mac_open`'s target reading (paths, apps,
  links, every refused scheme and credentials), app lookup (bundle id, case, `.app`, localised
  names, accents, two apps of one name, near names), the refused extensions and programs, path
  rules narrowing an open but never lifting it, the seeds denying a key and a link to it, and
  `OpenToolRunner` in a scratch home — kinds, refusals and a path swapped for a link after asking;
  shortcut calls, lookup, listing, output (none, text, bytes, clipped) and the input cap; the
  excluded system actions, refused by id and by name, every confirming action among them and the
  schema's `enum`; layout lookup, listing, the Accessibility sentence and each outcome; every
  dialog's wording and choices, and the four refusals. Nothing is opened or run.
- `session-tool-test` — the four schemas and wire names, call reading and its refusals (scope,
  limits, ids, `fromMessage`), the dialogs and refusal sentences, what settles before a dialog
  (this chat, an unknown id, a chat answering, open or pinned, an archive that changes nothing),
  listings (format, this chat left out, query, limit and its note, empty scopes), transcripts (one
  line per search, call, question and plan, thinking left out, attachments named, an unfinished
  reply), paging with `fromMessage` and `limit`, and clipping at the cap.
- `file-tool-test` — the five schemas and wire names, call reading and its refusals, each dialog's
  wording and choices (no Always Allow for home, the root or a seed, nor for a move between
  folders), the answers' wording and caps, text decoding, canonical resolution against links in a
  scratch folder — a link into a fake `.ssh` resolves to it and the seed then denies it — and the
  runner there: list, read with offset and limit, the three write modes and `createFolders`, a move
  that refuses an existing target, the Trash (a scratch folder stands in, so the user's Trash is
  never touched) and a folder swapped for a link after asking.
- `web-fetch-test` — the schema and wire name, call reading and its refusals (schemes,
  credentials, an empty host, the length cap), the local-network classifier over hosts, IPv4 in
  every spelling and IPv6 literals, the policy (an Allow row, Auto, a chat grant and Plan each still
  asking for a local URL), both dialogs, the HTML reader on fixtures, content types, clipping,
  charsets, redirect targets, and the fetcher against a `URLProtocol` stub on its own session —
  redirects and their cap, a scheme or local-network hop refused, the byte cap, refused types,
  charsets, the status, a cookie never sent back and the total timeout. Nothing reaches a network.
- `agent-wait-test` — `AgentWait.of`'s precedence and wording, `AgentApprovals` holding each request
  once and handing every waiter back once, `ChatPresence` per surface, `AgentWaitEpisodes` with a
  wait that changes kind, and each `AgentWaitNotice`: its wording, one identifier per chat, the
  click's chat ID read back and the question's clipping.
- `ai-provider-test` — `AISettingsStore`: every old combination migrates once and leaves no old key,
  a fresh install starts on the defaults, a broken table falls back without migrating, a table
  missing rows keeps the rest and fills those in, shell and path rules keep their order, Always
  Allow persists a pattern once, and the waiting notification is on by default and persists off.
- `ai-chat-test` — the archive behind the session tools (see [AI](ai.md#manual-sweep)'s harness
  list); the scope per chat, open, in Manual and without grants on a new or deleted chat;
  requests held off screen, let go on screen and declined exactly once by Stop, a cancelled task,
  a delete or the turn's end; `awaiting` derived from the turn; and which surface holds a chat.
- `installed-ai-test` — the Claude command's boundary: an armed turn outside Plan is told whatever a
  supplied tool does is allowed, and a Plan turn that nothing may be changed, search or not.
- `mcp-test` — `MCPTool.isReadOnly` from a plain `true` hint alone, and the `AgentCall` built from a
  listing, a CLI's call and a whole server.
- `calendar-test` and `reminders-test` — read and write halves offered independently, and the
  reminder dialogs' summary.
- `settings-backup-test` and `settings-file-test` — `aiAgentRules` and the old keys excluded, and no
  `settings.json` key for any of them; `aiNotifyWhenWaiting` excluded from backups and carried as
  `ai.notifyWhenWaiting`.

## Manual sweep

- With the shell row on Ask, a chat that runs `ls` asks; `Always Allow "ls *"` adds the rule to
  Settings → AI → Rules under Shell rules, and the next `ls -la` runs straight away.
- On the same row, `rm x` under a `rm *` Deny pattern is refused without a dialog, even with a `*`
  Allow pattern above it, and `ls $(pwd)` asks even with `ls *` allowed.
- With a `git push * → Ask` rule, `Always Allow "git *"` on `git push origin` lands above it, and
  the next `git push` runs.
- In Auto, with the shell row on Ask, `ls` runs with no dialog and `rm x` under a `rm *` Deny
  pattern is still refused; the pill is tinted, and a new chat starts in Manual with no grant from
  the last one.
- In Plan, a command asks even under `ls *`, Add Calendar Events is not offered even on Allow, and
  of a server whose tools carry `readOnlyHint`, only those are offered — on the Claude command too,
  where a call to one of its other tools is refused without a dialog.
- Switching a chat in Plan to a Codex model hides the pill, and the context card shows no Mode row.
- Switching Calendar off greys its rows in the Agent pane and removes them from the tools menu.
- Settings → AI → Agent lists the rows under Commands, Files, Web, Mac, Calendar & Reminders,
  Personal, Context and Sessions; switching Contacts off greys Read Contacts with "Turn on Contacts
  first.", and with Accessibility not granted Read Selected Text says so. Every row the table
  does not deny but Web Search appears in the ⌘K Tools menu and the context card.
- With Read Contacts on Ask, ask a chat for a colleague's phone number: the dialog names the
  query, and the answer carries numbers, addresses and the birthday, never the card's note. With
  Contacts off, Read Contacts is greyed and the tool is not offered.
- With Notes on and Add to the Note on Ask, ask a chat to add a to-do to your note while the Notes
  window shows it: the dialog names the note and shows the text, Allow puts it on a new line at the
  end, and ⌘Z in the note takes it back out. Reading the note asks with Allow This Chat.
- Copy a password from a password manager, then ask a chat what is on the clipboard: it is refused
  without a dialog. Copy ordinary text: the dialog says "text, N characters", and the text comes
  back. Ask for clipboard history: a copy from an app on the clipboard's ignore list is not there.
- Select text in Safari, switch to the AI Agent window and ask what is selected: the dialog names
  Safari, and the text comes back; ask which app you are using and it names Safari and the page's
  title. With nothing selected it says so without a dialog.
- With Snippets off and Quicklinks on, the agent is offered `quicklinks_list` but not the snippet
  tools; a disabled snippet or quicklink is never listed.
- With Open Apps, Files and Links on Ask, ask a chat to open Calculator, `~/Downloads`, a PDF and
  `https://example.com`: each dialog names what opens, and Allow opens it. Asking for
  `~/.ssh/id_rsa`, a `.command` file or a `shortcuts://` link is refused without a dialog.
- With Run Shortcuts on Ask, ask a chat which shortcuts you have: it lists them without a dialog;
  running one with some text shows the input in the dialog, and its output comes back. With Run
  System Actions on Ask, ask it to empty the Trash or restart: it says it cannot, with no dialog;
  turning the volume to 50% asks, then shows the volume HUD. With Apply Window Layouts on Ask and
  Accessibility granted, applying a saved layout by name asks, then arranges the windows; without
  the grant it says so without a dialog. In Plan, none of the Mac tools is offered.
- With Read Files on Ask, ask a chat to read a file in `~/Projects/app`: the dialog names it, and
  **Always Allow "~/Projects/app/**"** adds a Read rule to Path rules, after which the next read
  there runs straight away; a write there still asks, or is refused while Change Files is Deny.
- Make `~/Documents/key` a link to `~/.ssh/id_ed25519` and ask for it to be read: it is refused
  without a dialog. In Plan, `files_write` is not offered whatever Change Files says.
- With Fetch Web Pages on Ask, ask a chat to read `https://example.com`: the dialog names the host
  and the URL, and Allow This Chat lets a second page through without asking. Ask for
  `http://localhost:8080` or a router's `192.168.…` address: it asks, without Allow This Chat,
  even with the row on Allow, after the chat grant, and in Auto. A PDF link is refused naming
  `application/pdf`.
- With Read Other Chats on Ask, ask a chat what you talked about yesterday: listing asks first,
  then reading the chat it picks names that chat; Allow This Chat lets the next read through. Ask
  it to read the chat it is in: it is refused without a dialog. With Archive Chats on Ask, ask it
  to archive an old chat: the dialog names it, and the chat moves under Archived; asking it to
  archive the chat open in the window, a pinned one or one still answering is refused without a
  dialog. In Plan, `sessions_archive` is not offered whatever its row says.
- Settings → AI → Rules lists the Deny seeds under Path rules, numbered; a rule's row opens its
  page, where an edit, a move or a Delete… (which asks first) shows on the list on Back and is
  still so after a relaunch. Add Path Rule opens a new rule's page with its pattern field focused.
- The Agent pane opens without a stall: the Commands to Web groups paint first, the rest a group
  per frame; a search for Tool call rounds still lands on that row.
- A server set to Never Allow from the Agent pane reads Never Allow in its editor, and the model
  is not offered it.
- Leave a chat that asks: with the shell row on Ask, send a request that runs a command, then switch
  to another app before the model calls it. No dialog comes up; the sidebar row shows the raised
  hand, the menu bar icon a dot, and a notification says Blitz is waiting for approval, under the
  chat's title. Clicking it brings the window forward on that chat and the Run dialog comes up;
  answering clears the badge, the dot and the notification.
- Do the same from Quick AI and dismiss the palette: the click moves the chat into the window, reply
  and all, and its dialog comes up there.
- In the window, send the same request and press ⌘N before the model calls the command: no dialog
  comes up, the old chat's row shows the raised hand, and the banner shows though Blitz is in
  front. Delete that chat from the sidebar: no dialog ever comes up for it, and the badge, the dot
  and the notification go.
- Switch Notify when the agent is waiting off: a chat left waiting posts nothing, and its badge and
  the dot still show.
- With Change Memory on Ask, tell a chat "remember that I prefer metric units": the dialog shows
  the sentence, and Allow adds it to Settings → AI → Memory as m1. A new chat asked for a
  distance answers in kilometres; its context card's Memory row reads "1 memory". Asking again to
  remember the same sentence in other capitals answers that it is already remembered, with no
  dialog. Asking it to forget that preference names it in a dialog, and Allow removes it.
- Switch Use Memory off in a chat's tools menu: its next turn carries no memory, and the context
  card says Off; a new chat has it on again. With Read Memory on Deny no chat carries any, and the
  menu has no Use Memory.
- In Settings → AI → Memory, edit a memory and press Return: the list shows the new text with the
  same id. Add one that duplicates another: the HUD says it is already remembered. Forget All…
  asks first, then empties the list; the next memory the agent keeps is not m1.
