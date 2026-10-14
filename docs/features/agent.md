# Agent

There is one agent, and every chat is a session of it, Quick AI included. It answers directly, or
calls the tools one rule table allows: the shell, files, web fetch, the reader's other chats, the
calendar, reminders, web search and each MCP server, with rows already in the table for the rest of
the Phase 3 toolbox —
Mac actions, personal data and context — whose runners have not landed. The table says Allow, Ask or Deny per
tool, plus ordered command patterns for the shell and path patterns for files; a
session's mode — Manual, Auto or Plan — decides what an Ask does, and nothing a session holds lifts
a Deny. Two more tools talk only to the chat and have no row: `ask_user` and, in Plan, `write_plan`.
`AgentPolicy` decides, `AgentGateCoordinator` enforces and asks — only while the asking chat is on
screen; a chat left waiting shows a badge and posts a notification — and the tools themselves stay
with their features — [AI](ai.md#invariants) for the shell runner, the question and the plan,
[File tools](#file-tools), [Web fetch](#web-fetch) and [Session tools](#session-tools) below,
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
  snippets reads, Read Files, both web rows, the three context rows and Read Other Chats. An MCP
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
  runner shows in Settings and nowhere else: the composer's menu and the context card list
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
- **The feature switches stay the ceiling.** Each row with a feature behind it needs that feature's
  switch (`AgentFeatureCeiling`), and a server needs MCP on and itself enabled.
  `AgentGateCoordinator.rules` reads a row as Deny while its ceiling is not met, and a server that
  is off or gone answers Deny. See [The rule table](#the-rule-table) for each row's ceiling.
- **MCP trust is not copied.** A server's row is its `MCPServer.trust` — `.always` ↔ Allow, `.ask` ↔
  Ask, `.never` ↔ Deny (`MCPAgentMapping.swift`) — read and written in place, so the Agent table and
  the server editor cannot disagree.
- **Web search has no Ask.** The provider runs the search, so Blitz never sees a call it could stop.
  `AgentRules` stores an Ask on that row as Deny, no mode makes it ask, and Allow only means the
  composer offers its globe.
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
writes or acts is denied, and web search is Allow, its composer globe being the opt-in.

`AgentTool.builtIn` is Settings order, and runs group by group (`AgentTool.Group`): Commands,
Files, Web, Mac, Calendar & Reminders, Personal, Context, Sessions.

| Group | Row (`AgentTool`) | Settings title | Covers | Read-only | Default | Ceiling |
| --- | --- | --- | --- | --- | --- | --- |
| Commands | `.shell` | Run Commands | `shell_run_command` | no | Deny | — |
| Files | `.filesRead` | Read Files | `files_list`, `files_read` | yes | Ask | — |
| | `.filesWrite` | Change Files | `files_write`, `files_move`, `files_trash` | no | Deny | — |
| Web | `.webSearch` | Web Search | the route's own search | yes | Allow (no Ask) | — |
| | `.webFetch` | Fetch Web Pages | `web_fetch` | yes | Ask | — |
| Mac | `.openItems` | Open Apps, Files and Links | (3e) | no | Deny | — |
| | `.shortcuts` | Run Shortcuts | an Apple Shortcut (3e) | no | Deny | Apple Shortcuts on |
| | `.systemActions` | Run System Actions | Blitz's system actions (3e) | no | Deny | System Actions on (`VisibilityStore`) |
| | `.windowLayouts` | Apply Window Layouts | a window layout (3e) | no | Deny | Window Management on |
| Calendar & Reminders | `.calendarRead` | Read Calendar | `calendar_list_events` | yes | Ask | Calendar on |
| | `.calendarWrite` | Add Calendar Events | `calendar_create_event` | no | Deny | Calendar on |
| | `.remindersRead` | Read Reminders | `reminders_list` | yes | Ask | Reminders on |
| | `.remindersWrite` | Change Reminders | `reminders_create`, `reminders_update`, `reminders_complete` | no | Deny | Reminders on |
| Personal | `.contactsRead` | Read Contacts | (3f) | yes | Ask | Contacts on |
| | `.noteRead` | Read the Note | the floating note (3f) | yes | Ask | Notes on |
| | `.noteWrite` | Add to the Note | append (3f) | no | Deny | Notes on |
| | `.clipboardRead` | Read Clipboard History | (3f) | yes | Ask | Clipboard on |
| | `.snippetsRead` | Read Snippets and Quicklinks | (3f) | yes | Ask | Snippets or Quicklinks on |
| Context | `.frontmostApp` | See the Frontmost App | (3f) | yes | Ask | — |
| | `.selectedText` | Read Selected Text | (3f) | yes | Ask | Accessibility granted |
| | `.currentClipboard` | Read the Clipboard | (3f) | yes | Ask | — |
| Sessions | `.sessionsRead` | Read Other Chats | `sessions_list`, `sessions_read` | yes | Ask | — |
| | `.sessionsArchive` | Archive Chats | `sessions_archive`, `sessions_unarchive` | no | Deny | — |
| — | `.mcp(slug)` | the server's title | every tool of that server | per tool | its trust, `.ask` | MCP and the server on |

A step in parentheses names the Phase 3 step that brings the row's runner; until then the row is not
hosted, so nothing offers it. Every read-only row but web search can be allowed for the chat.
`AgentFeatureCeiling` is the one place that says each row's ceiling and the sentence Settings shows
under a row held below it ("Turn on Contacts first."); Selected Text's is the Accessibility grant,
read through `Permissions.isAccessibilityTrusted()` at each decision and polled once a second while
Settings shows the Agent section.

`AgentTool(wireName:)` maps a model's call onto its row — the built-in names first, then
`MCPToolName.parse` — and `AgentCall(toolCall:)` adds the command a shell call would run. A name
neither Blitz nor a server spells has no row.

`AgentPolicy.decision` applies, in order: a tool the session switched off is Deny; the row's own
decision, with Deny final; a chat grant turning that row's Ask into Allow; for the shell, the
patterns below, and for a file call, the path rules; then the session's mode, which never touches a
Deny; and last, a local-network fetch held at Ask.

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
reminders and note writes, Archive Chats — and every other MCP tool are Deny. `ask_user` and
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
or Write, the file rows it weighs — and a decision. `AgentCall.files(_:paths:homeDirectory:)`
carries every path a call touches, a move's source and destination both; `AgentPolicy` weighs each
path on its own and the call takes the narrowest:

- A path any applicable Deny rule matches is Deny, wherever that rule sits.
- Otherwise the first applicable rule that matches decides, so an Allow pattern raises a path above
  an Ask row, and an Ask or Deny pattern narrows an Allow row.
- A path no rule matches takes the row's decision; a Deny row is Deny before any of this.
- A path that is not absolute, or a home folder that is not, takes `min(row, Ask)`.
- A call with no path — the bare row, as `isOffered` asks — takes the row.

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
  web search, and MCP servers; a write or a command is asked each time. The gate writes the grant onto the asking chat's
  `AgentSessionScope.granted`, and only while that chat still shows the conversation that asked;
  `AgentPolicy` turns that row's Ask into Allow from it, in Plan too. It never lifts a Deny, and
  never answers a local-network fetch, whose dialog does not offer it.

Auto raises no dialog but one: every Ask is Allow before the gate would ask, except a
local-network fetch, which the policy holds at Ask.

## The session scope and the composer

`AgentSessionScope` lives on `AIChatState.agentScope` and is never stored: a new chat, a reopened
one, or deleting the open one starts it fresh. It holds `isEnabled`, the `excluded` tools, the
`mode` and the `granted` tools, so a chat grant ends exactly when the scope does. A server added
later arrives switched on.

The AI Agent window's composer has a tools menu (`AIToolsPicker`) that edits what the chat may call:

- **Use Tools** — off offers nothing, Blitz's tools, `ask_user` and every server alike.
- **Blitz** — one switch per hosted built-in row the table does not deny, on a route that reaches
  Blitz's tools (`AIChatCoordinator.listedBuiltInTools`); web search, the provider's own, and the
  toolbox rows with no runner yet are not among them.
- **MCP Servers** — one switch per server the table does not deny.
- **Agent Settings…** opens Settings → AI on the Agent section.

The label counts what is on, "`n` of `m`". A route that cannot call tools shows the menu disabled
and says why, and with nothing the table allows it says so. The menu lists the table's reach in
Manual whatever the mode, so a switch never vanishes when Plan would refuse its tool.

The mode pill (`AIModePicker`) follows the tools menu, only where `AIChatCoordinator.offersModes`:
a route that calls tools and reaches Blitz's — an API connection or the Claude command, never
Codex, which reaches no `write_plan` to plan with. Each entry is the mode's title, `summary` and
glyph, and the pill shows the current one. Auto's pill is filled and tinted with the warning
colour, since its calls run without a dialog. `setMode` keeps a chat with no picker in Manual, and
`selectModel` drops the chat back to Manual when the new route has none, so a mode nobody can see
never applies.

Quick AI has neither menu nor pill, so its scope stays open and Manual: the same gate and rules,
every tool the table offers, `ask_user` included.

The composer's web-search globe appears only where the route searches and the Web Search row is
Allow (`AIChatCoordinator.offersWebSearch`). It flips `aiWebSearch`, off by default, and a turn
searches only with both. The context card's **Tools** section opens on a **Mode** row where the
route offers modes, then lists each tool the next turn is offered with the decision a bare call to
it would get, grants, scope and mode included, or one "Offered: None" row; its **Web search** row
says whether the next turn searches. A server's row is `AgentCall.server(_:listed:)` over
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

Settings → AI holds two sections, between Default model and Conversations:

- **Agent** (`AgentSettingsSection`) — the built-in rows under a small header per
  `AgentTool.Group`, in `builtIn` order, each a picker disabled with its ceiling's sentence ("Turn
  on Contacts first.", "Allow Blitz Accessibility access first.") while `AgentFeatureCeiling` holds
  it; then, under an MCP Servers header, a picker per server, written to its trust and disabled
  while MCP or the server is off; **Tool call rounds**; and **Notify when the agent is waiting**
  ([Notifications](#notifications)). A toolbox row whose runner has not landed is listed and
  editable like any other.
- **Shell rules** (`ShellRulesSection`) — the ordered patterns, each with a pattern field, a
  decision, Move Up, Move Down and Remove, then **Add Shell Rule**, which adds an empty Allow
  pattern and focuses it. An empty pattern matches nothing.
- **Path rules** (`PathRulesSection`) — the same, with an Applies to picker (Read & Write, Read,
  Write) beside each decision, then **Add Path Rule**; the footer explains `~`, `*` and `**`, that
  a Deny always wins, and that paths are checked once symlinks resolve, ignoring case. Both lists
  draw their rows with `AgentRuleRow`.

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
  refusing the archive, tolerant decoding without them — and their three dialogs.
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
  Settings → AI → Shell rules, and the next `ls -la` runs straight away.
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
- Switching Calendar off greys its rows in the Agent section and removes them from the tools menu.
- Settings → AI → Agent lists the rows under Commands, Files, Web, Mac, Calendar & Reminders,
  Personal, Context and Sessions; switching Contacts off greys Read Contacts with "Turn on Contacts
  first.", and with Accessibility not granted Read Selected Text says so. Of the toolbox rows only
  Read Files, Change Files, Fetch Web Pages, Read Other Chats and Archive Chats appear in the
  composer's tools menu and the context card.
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
- Settings → AI → Path rules starts with the Deny seeds; a rule edited, moved or removed there is
  still so after a relaunch.
- A server set to Never Allow from the Agent section reads Never Allow in its editor, and the model
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
