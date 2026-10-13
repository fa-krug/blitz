# Agent

There is one agent, and every chat is a session of it, Quick AI included. It answers directly, or
calls the tools one rule table allows: the shell, the calendar, reminders, web search and each MCP
server. The table says Allow, Ask or Deny per tool, plus ordered command patterns for the shell; a
session can only narrow it. `AgentPolicy` decides, `AgentGateCoordinator` enforces and asks, and the
tools themselves stay with their features — [AI](ai.md#invariants) for the shell runner,
[Calendar](calendar.md#chat-tools), [Reminders](reminders.md#chat-tools) and [MCP](mcp.md).

## Invariants

- **`AgentPolicy` is the whole rule, and it is pure.** `decision(for:rules:mcpTrust:scope:)` takes
  an `AgentCall`, the table, each server's trust and the session's `AgentSessionScope`, and answers
  `.allow`, `.ask` or `.deny`. It lives in `Model/`, and `agent-policy-test` pins it. Nothing else
  decides.
- **A denied tool is never offered.** Every offer list — Blitz's own tools, the loop's MCP tools,
  the servers handed to Codex or Claude — goes through `AgentPolicy.isOffered`, which is the
  decision for a bare call to the tool. A shell row on Deny hides the tool whatever its patterns
  say, and calendar and reminders offer their read and write halves independently.
- **Every call is decided when it arrives, not when it was offered.** The gate reads the table at
  the call, again when a queued call's turn comes, and again once its dialog closes, so a Settings
  change mid-reply binds the next call. A call the model makes to a tool that went to Deny after
  the turn started is refused with a sentence.
- **The shell matcher fails toward Ask.** A command the splitter cannot read with confidence never
  reaches a pattern; it asks, or is denied by a Deny row. See [Shell patterns](#shell-patterns).
- **A Deny pattern is a backstop, not a sandbox.** Patterns match a segment's text, not the program
  it runs: `env rm x`, `/bin/rm x` and `xargs rm` all slip past a `rm *` Deny. Under an Ask row they
  take the row and still ask; under an Allow row they run. An Allow row plus Deny patterns is a
  blocklist, and the Settings footer says so.
- **A session can only narrow.** The composer's tools menu switches tools off for the chat or turns
  every Allow into Ask; it never widens past the table. "Allow This Chat" answers a read's or a
  server's Ask ahead of time and never lifts a Deny. All of it lives on the session scope, so it
  ends with the scope and is never stored.
- **A matching Deny pattern always wins.** Order decides only among the rest, so no Allow pattern,
  wherever it sits, can shadow a Deny one.
- **The feature switches stay the ceiling.** Calendar and Reminders each need their own switch,
  which is where macOS was asked, and a server needs MCP on and itself enabled.
  `AgentGateCoordinator.rules` reads a calendar or reminders row as Deny while its feature is off,
  and a server that is off or gone answers Deny.
- **MCP trust is not copied.** A server's row is its `MCPServer.trust` — `.always` ↔ Allow, `.ask` ↔
  Ask, `.never` ↔ Deny (`MCPAgentMapping.swift`) — read and written in place, so the Agent table and
  the server editor cannot disagree.
- **Web search has no Ask.** The provider runs the search, so Blitz never sees a call it could stop.
  `AgentRules` stores an Ask on that row as Deny, Ask for Everything leaves it alone, and Allow only
  means the composer offers its globe.
- **The table is a capability grant.** `aiAgentRules` is in
  `SettingsBackupCoverage.deliberatelyExcluded` and has no `SettingsFileKey`, so neither a backup
  nor `settings.json` can arm a tool.
- **The old access settings are migrated once.** A Mac with no `aiAgentRules` but any of
  `aiCalendarAccess`, `aiRemindersAccess` or `aiShellCommands` gets `AgentRules.migrated`, and the
  three keys are removed. This is one of the codebase's two migrations, explicitly requested; see
  [Settings and storage](#settings-and-storage).

## The rule table

`AgentRules` is one decision per built-in row plus `shellRules`; an MCP server's row is its own
trust. `AgentDecision` orders `deny < ask < allow`, so `min` is the narrower of two.

| Row (`AgentTool`) | Settings title | Covers | Choices | Default |
| --- | --- | --- | --- | --- |
| `.shell` | Run Commands | `shell_run_command` | Allow, Ask, Deny | Deny |
| `.calendarRead` | Read Calendar | `calendar_list_events` | Allow, Ask, Deny | Ask |
| `.calendarWrite` | Add Calendar Events | `calendar_create_event` | Allow, Ask, Deny | Deny |
| `.remindersRead` | Read Reminders | `reminders_list` | Allow, Ask, Deny | Ask |
| `.remindersWrite` | Change Reminders | `reminders_create`, `reminders_update`, `reminders_complete` | Allow, Ask, Deny | Deny |
| `.webSearch` | Web Search | the route's own search | Allow, Deny | Allow |
| `.mcp(slug)` | the server's title | every tool of that server | Allow, Ask, Deny | its trust, `.ask` |

`AgentTool(wireName:)` maps a model's call onto its row — the built-in names first, then
`MCPToolName.parse` — and `AgentCall(toolCall:)` adds the command a shell call would run. A name
neither Blitz nor a server spells has no row.

`AgentPolicy.decision` applies, in order: a tool the session switched off is Deny; the row's own
decision, with Deny final; a chat grant turning that row's Ask into Allow; for the shell, the
patterns below; then Ask for Everything caps the result at Ask for every row that can ask, grants
included.

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

On Allow the call runs. On Deny it fails with `AgentRefusal.denied`'s sentence, "Blitz's agent rules
do not let the model …". On Ask the gate queues the question on its `AIConsentQueue`, one dialog
for every chat, since `DialogController` refuses a second. When the question's turn comes the
decision is read again — an earlier dialog may have answered it — then Blitz's own dialog goes up
through `core.choose`, the choice is applied, and the decision is read once more, so a row set to
Deny while the dialog was up still refuses. A question whose turn was cancelled while it waited is
declined without being shown. A decline is `AgentRefusal.declined`, "The user declined to let the
model …"; the CLI routes send their own fixed decline instead.

| Call | Title | Choices (↵ marked) |
| --- | --- | --- |
| Shell | Run this command? — the command verbatim and its folder | **Run** ↵, Always Allow "`<pattern>`" when one is suggested, Don't Run |
| Calendar or reminders read | Let the agent read your calendar? / your reminders? | **Allow** ↵, Allow This Chat, Don't Allow |
| Calendar write | Add "`<title>`" to your calendar? — the event summary | **Allow** ↵, Don't Allow |
| Reminders write | Add "`<title>`" to Reminders? / Change "`<title>`"? / Complete "`<title>`"? | **Allow** ↵, Don't Allow |
| MCP server | Let `<server>` run its tools? — the tool's name | Always Allow, **Allow This Chat** ↵, Don't Allow |

The wording and choices are `AgentPrompt`'s, in `Model/`. Escape is always the last choice, a
refusal of that one call; only Settings withholds a tool for good.

- **Always Allow "`<pattern>`"** places the pattern through `AISettingsStore.allowShellPattern`, as
  [Shell patterns](#shell-patterns) describes; Settings' Add Shell Rule appends through
  `addShellRule` instead.
- **Always Allow** on a server sets its trust to `.always` through `MCPCoordinator.setTrust`.
- **Allow This Chat** is offered only where `AgentTool.canAllowForSession` — the two reads and MCP
  servers; a write or a command is asked each time. The gate writes the grant onto the asking chat's
  `AgentSessionScope.granted`, and only while that chat still shows the conversation that asked;
  `AgentPolicy` turns that row's Ask into Allow from it. It never lifts a Deny.
- **Under Ask for Everything** a grant would be capped straight back to Ask, so the gate shows
  `AgentPrompt.scoped(to:)`: a read offers **Allow** ↵ and Don't Allow, and a server offers Always
  Allow, **Allow** ↵ — once — and Don't Allow. Always Allow writes the table, not the chat, so it
  stays.

## The session scope and the composer

`AgentSessionScope` lives on `AIChatState.agentScope` and is never stored: a new chat, a reopened
one, or deleting the open one starts it fresh. It holds `isEnabled`, the `excluded` tools,
`asksForEverything` and the `granted` tools, so a chat grant ends exactly when the scope does. A
server added later arrives switched on.

The AI Chat composer's tools menu (`AIToolsPicker`) is the scope's only editor:

- **Use Tools** — off offers nothing, Blitz's tools and every server alike.
- **Ask for Everything** — every Allow becomes Ask for the chat; the menu's glyph becomes a raised
  hand.
- **Blitz** — one switch per built-in row the table does not deny, on a route that reaches Blitz's
  tools (`AIChatCoordinator.listedBuiltInTools`); web search is not among them.
- **MCP Servers** — one switch per server the table does not deny.
- **Agent Settings…** opens Settings → AI on the Agent section.

The label counts what is on, "`n` of `m`". A route that cannot call tools shows the menu disabled
and says why, and with nothing the table allows it says so. Quick AI has no menu, so its scope stays
open: the same gate and rules, every tool the table offers, nothing forced to ask.

The composer's web-search globe appears only where the route searches and the Web Search row is
Allow (`AIChatCoordinator.offersWebSearch`). It flips `aiWebSearch`, off by default, and a turn
searches only with both. The context card's **Tools** rows list each tool the next turn is offered
with the decision a bare call to it would get, grants and scope included, or one "Offered: None"
row; its **Web search** row says whether the next turn searches.

## Settings and storage

Settings → AI holds two sections, between Default model and Conversations:

- **Agent** (`AgentSettingsSection`) — a picker per built-in row, disabled with "Turn on Calendar
  first." or "Turn on Reminders first." while that feature is off; a picker per MCP server, written
  to its trust and disabled while MCP or the server is off; and **Tool call rounds**.
- **Shell rules** (`ShellRulesSection`) — the ordered patterns, each with a pattern field, a
  decision, Move Up, Move Down and Remove, then **Add Shell Rule**, which adds an empty Allow
  pattern and focuses it. An empty pattern matches nothing.

`AISettingsStore.agentRules` is the table, encoded as JSON under `AppSettingsKey.aiAgentRules`.
Loading it:

| Stored | Result |
| --- | --- |
| `aiAgentRules` that decodes | that table |
| `aiAgentRules` that does not decode, or lacks a row | `AgentRules.defaults`; no old key is read or removed |
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

Web search migrates as Allow. `AIDataAccess` survives only to read the old values, and the three
old keys stay in `SettingsBackupCoverage.deliberatelyExcluded` until this migration is deleted.

## Routes

| Route | Blitz's tools | MCP servers | Who asks |
| --- | --- | --- | --- |
| API connection | through `AIToolLoopProvider` | through the loop, Blitz as client | the gate, per call |
| Claude command | `ClaudeHostedServer`, an in-process `sdk` server | handed to the CLI | the gate: Blitz's tools in their runners, servers through `can_use_tool` |
| Codex | never | handed to the CLI | the gate, through Codex's elicitation |
| Apple Intelligence, Grok, OpenCode, Cursor | none | none | — |

`AIModelSelection.reachesBlitzTools` is false only for Codex, and `AIModelCapabilities.tools` is
false for the last row. `@server` addresses one server, so Blitz's own tools sit that turn out. A
Codex chat's title request borrows the reply's servers and refuses every call.

## Harnesses

- `agent-policy-test` — the splitter's splits and refusals, glob matching, decision order, wire
  names, the MCP trust mapping, defaults and the web-search rule, migration, `Codable`, the session
  scope, the policy's precedence and offers, the suggested pattern and `neverSuggested`, calls from
  the wire, every `AgentPrompt` and its scoped form, both refusals, chat grants on the scope,
  Always Allow's placement and the context card's rows.
- `ai-provider-test` — `AISettingsStore`: every old combination migrates once and leaves no old key,
  a fresh install starts on the defaults, a broken table falls back without migrating, shell
  rules keep their order, and Always Allow persists a pattern once.
- `ai-chat-test` — the scope per chat, open and without grants on a new or deleted chat.
- `calendar-test` and `reminders-test` — read and write halves offered independently, and the
  reminder dialogs' summary.
- `settings-backup-test` and `settings-file-test` — `aiAgentRules` and the old keys excluded, and no
  `settings.json` key for any of them.

## Manual sweep

- With the shell row on Ask, a chat that runs `ls` asks; `Always Allow "ls *"` adds the rule to
  Settings → AI → Shell rules, and the next `ls -la` runs straight away.
- On the same row, `rm x` under a `rm *` Deny pattern is refused without a dialog, even with a `*`
  Allow pattern above it, and `ls $(pwd)` asks even with `ls *` allowed.
- With a `git push * → Ask` rule, `Always Allow "git *"` on `git push origin` lands above it, and
  the next `git push` runs.
- Ask for Everything makes an allowed command ask, and a read's dialog offers no Allow This Chat; a
  new chat starts with it off, and with no grant from the last one.
- Switching Calendar off greys its rows in the Agent section and removes them from the tools menu.
- A server set to Never Allow from the Agent section reads Never Allow in its editor, and the model
  is not offered it.
