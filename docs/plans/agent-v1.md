# Blitz Agent — v1 plan

Status: Phase 1 built; phases 2–4 planned. Builds on PR #49 (web search on Claude routes, the shell tool). Codex is out of
scope; it keeps MCP servers only.

## Concept

- **There is one agent.** Every conversation is a session of it, Quick AI included. It answers
  directly, or calls the tools its rules allow. There are no profiles, so there is no `agent_id` and no
  chat-history migration: today's chats are sessions as they are.
- **Work happens only while a turn is processing.** A running turn already survives a closed window
  (`AIChatSurfacesState`: "leaving never cancels it"). Once a turn is answered, nothing runs.
- **One rule table decides every tool call**: Allow, Ask or Deny per tool, plus ordered command
  patterns for the shell. The table replaces this PR's scattered switches: Calendar access, Reminders
  access, the shell master switch, and the per-chat Confirm/Auto-run toggle.
- **A session can only narrow.** The composer can switch tools off for the session or turn every
  Allow into Ask. It can never widen past the table, and the narrowing is not stored.
- **Asks are answered in Blitz, never from a notification.** A turn that waits shows a badge in the
  sidebar and posts an alert-only notification (phase 2).
- **Routes:** API connections run through `AIToolLoopProvider`, and the Claude command runs through
  `ClaudeHostedServer`. Both reach the same tool runtime and the same rules. Codex keeps MCP servers
  only. Apple Intelligence answers only.

## Invariants to hold (as built, in [`docs/features/agent.md`](../features/agent.md))

- **`AgentPolicy` is the whole rule, and it is pure** (Model/, harness-pinned): `(call, table,
  session scope) → .allow | .ask | .deny`. Nothing else decides.
- **A denied tool is never offered.** The model never sees a tool it may not call. This is today's
  Read Only rule, generalized.
- **Every call re-reads the table**, since Settings can change mid-reply. The decision is read again
  after an Ask dialog closes, the way the shell tool does today.
- **The shell matcher fails toward Ask.**
  - A command is split on `;`, `&&`, `||`, `|`, `&` and newlines. A segment any Deny pattern matches
    is Deny; otherwise it takes its first matching pattern, or the row's own decision when none
    matches, and the narrowest segment decides:
    on an Ask row every segment must match an Allow pattern, and any Deny segment denies the whole.
  - Command substitution (`$(`, backticks, `<(`, `>(`), unbalanced quotes, heredocs, or anything the
    splitter cannot read with confidence means Ask, never Allow.
  - Patterns are globs over a whole segment (`git *`, `ls`, `brew list*`).
  - A Deny row is final; within a segment a matching Deny pattern wins, and otherwise the first
    matching pattern does, so order is the user's; a session's "ask everything" caps Allow at Ask. Deny patterns are a backstop, not a sandbox.
- **The table is a capability grant.** It is excluded from backups (`SettingsBackupCoverage.
  deliberatelyExcluded`) and has no `settings.json` key, like `aiCalendarAccess` today.
- **The feature switches stay the ceiling.** Calendar and Reminders still need their own feature
  switch (the macOS consent), and an MCP server still needs to be enabled. The table can never reach
  past them.
- **MCP trust is not copied.** The table's MCP rows read and write `MCPServer.trust` itself
  (`.always` ↔ Allow, `.ask` ↔ Ask, `.never` ↔ Deny). "Allow This Chat" is a session grant held on
  the chat's session scope, offered for MCP servers and for the calendar and reminders reads.
- **Web search has no Ask.** The search runs on the provider's side, so Blitz never sees an
  individual call. Its row is Allow or Deny, and Allow means the composer toggle is offered.

## Phase 1: the rule engine (this plan's scope)

### Model (pure, `Blitz/Features/AI/Model/`)

| File | Holds |
| --- | --- |
| `AgentTool.swift` | `AgentTool`: `.shell`, `.calendarRead`, `.calendarWrite`, `.remindersRead`, `.remindersWrite`, `.webSearch`, `.mcp(slug)`. Title, glyph, and whether Ask is possible (not for `.webSearch`). The catalog's tool names map onto it. |
| `AgentDecision.swift` | `.allow`, `.ask`, `.deny`, ordered for narrowing (`min`). |
| `AgentRules.swift` | `Codable` table: a default per built-in tool, plus `[ShellRule]` (pattern + decision, ordered). Defaults: everything Deny except Calendar/Reminders read = Ask once their feature is on, and web search = Allow (its composer toggle stays the opt-in). Encodes to one JSON blob. |
| `ShellCommandSegments.swift` | The conservative splitter: `segments(of:) -> [String]?`, where nil means "cannot read, Ask". |
| `AgentPolicy.swift` | `decision(for: AgentCall, rules:, scope:) -> AgentDecision`. `AgentCall` is the tool plus its arguments (the command, for the shell). Also `offered(_ tools:, rules:, scope:)` for the offer list, and `suggestedPattern(for command:)`, the first word + ` *` that "Always Allow" proposes. |
| `AgentSessionScope.swift` | Replaces `ChatToolScope` and `ShellCommandApproval`: `isEnabled`, `excluded: Set<AgentTool>` (MCP slugs included), `asksForEverything`. |

### Service / settings

- `AISettingsStore`: replace `calendarAccess`, `remindersAccess` and `shellCommandsEnabled` with
  `agentRules: AgentRules`, stored as JSON under one new `AppSettingsKey.aiAgentRules`.
- **One migration (explicitly requested):** when `aiAgentRules` is absent, the table is derived once
  from the old keys, and the old keys are then removed:

  | Old value | Read row | Write row |
  | --- | --- | --- |
  | Calendar Off / Reminders Off | Deny | Deny |
  | Calendar Read Only / Reminders Read Only | Allow | Deny |
  | Calendar Read & Write | Allow | Ask (it always confirmed) |
  | Reminders Read & Write | Allow | Allow (it wrote straight away) |
  | `aiShellCommands` on / off | shell Ask / Deny | |

  This is the codebase's second migration; AGENTS.md's "carries one migration" line is updated.
- `SettingsBackupCoverage`: exclude `aiAgentRules`; the three old keys stay listed as excluded until
  the migration that reads them is deleted. `SettingsFileSchema`:
  no key.

### Wiring (`AIChatCoordinator`, the tool runners)

- Every offer list comes from `AgentPolicy.offered`: `blitzTools()`, and the MCP tools in
  `tools(for:scopedTo:)` and `toolServers(for:scopedTo:)`. The calendar and reminders coordinators'
  `chatTools(now:)` stop reading `AIDataAccess`; they take the allowed tool set instead.
- One gate, built as `AgentGateCoordinator` (owned by `AIChatCoordinator`), called by every Blitz
  tool runner before it acts and by every MCP consent. It reads the policy. On `.ask` it queues the
  request on the shared `AIConsentQueue` and shows Blitz's dialog, worded by `AgentPrompt`:
  - Shell: **Run**, **Always Allow `<pattern>`** (an Allow `ShellRule`, placed so it decides that command), **Don't Run**.
  - Calendar/Reminders reads: **Allow**, **Allow This Chat**, **Don't Allow**.
  - Calendar/Reminders writes: **Allow** / **Don't Allow**, with the event or reminder summary.
  - MCP: the three-way dialog, reached through the same gate.
- `calendarCoordinator.runTool` and `remindersCoordinator.runTool` lose their own confirm and
  access checks; the gate replaces both. Every reminder write, completion included, runs straight
  away on Allow and asks on Ask.
- Web search: `webSearch(for:)` also requires `rules.webSearch == .allow`. The global `aiWebSearch`
  toggle stays as the composer's on/off memory.

### UI

- **Settings → AI → Agent** replaces "Personal data", "Shell" and "Chat" (its web-search switch
  became the Web Search row; the on/off memory is the composer's globe):
  - One row per tool with an Allow/Ask/Deny picker (`.popover` is fine in Settings).
  - Rows whose feature is off are disabled, and the footnote says why ("Turn on Calendar first").
  - MCP servers are listed beneath, bound to their trust.
  - A **Shell rules** list: pattern field, decision picker, reorder, delete, add.
  - The round cap moves here from Chat.
- **Composer:** the tools menu becomes the session scope.
  - Per-tool on/off for the session, MCP servers included.
  - An **Ask for everything** toggle, which replaces the terminal Confirm/Auto-run glyph.
  - The context card lists the effective decision per tool.
- **Settings search catalog and anchors** are updated for the moved rows.

### Tests

- New `agent-policy-test` (registered in `Scripts/run-tests.sh`):
  - splitter cases: operators, quotes, substitution, heredoc, empty input
  - precedence: Deny > Allow > default, plus scope narrowing
  - web search can never be Ask
  - offer filtering, MCP trust mapping, and the suggested pattern
- `shell-tool-test` and `ai-chat-test` are adjusted for the removed approval enum.
- `settings-backup-test` and `settings-file-test` cover the new key and the removed old ones.
- The full suite, Debug build without new warnings, lint and the Model import grep, as in AGENTS.md.

### Docs

- New `docs/features/agent.md` (invariants first).
- `ai.md`: the calendar/reminders/shell bullets point at it; composer and context-card text.
- `calendar.md` and `reminders.md` "Chat tools": access is now an agent rule.
- `mcp.md`: trust is edited from the agent table too.

### Execution (subagent-driven, in order; parallel only where the files don't overlap)

1. **Model:** the six pure files plus `agent-policy-test`. No app wiring yet. *(one agent)*
2. **Settings storage and the Agent pane:** `AISettingsStore`, keys, backup coverage, the Settings
   UI, search catalog, and the settings harnesses. *(one agent, after 1)*
3. **Wiring and composer:** the coordinator gate, offer lists, the calendar/reminders/shell runners,
   the composer scope menu, the context card, and `ai-chat-test`/`shell-tool-test`. *(one agent,
   after 1; it shares no files with 2, so it may run beside 2)*
4. **Docs and verification:** docs, the full suite, build, lint, and a real run in the Dev build
   (`ls` → Ask → Always Allow `ls *` → the next `ls` runs straight away). *(the parent)*

## Phase 2: turns you can leave

- A waiting state on `AIChatState` (`isAwaitingApproval`). The sidebar row shows a badge, and the
  menu bar icon a dot while any session waits.
- An Ask dialog is presented only when its session is on screen. Otherwise the request waits in the
  queue, and a **notification** (`UNUserNotificationCenter`; first use asks macOS) says "Blitz is
  waiting for approval: <session title>". The notification has no actions. Clicking it opens the AI
  window on that session, and the dialog comes up.
- Stop and the round cap are unchanged. A turn that is stopped while waiting answers its pending
  request as declined.
- User-facing renaming from "chat" to "agent" where it reads better (window title, command names).
  Command IDs stay as they are.

## Phase 3: toolbox (one tool group per step, each with its catalog, runner, rule row and harness)

1. **Files:** list, read (clipped), write, move to Trash. Path patterns like the shell's
   (`~/Downloads/**`). Writing outside an Allow pattern always asks.
2. **Web fetch:** a URL as readable text, on a private `.ephemeral`, `urlCache = nil` session
   (`CurrencyRateStore` shape), with a size and time cap.
3. **Mac:** open an app or URL, run an Apple Shortcut, system actions, window layouts.
4. **Personal:** contacts (read), the floating note (read/append), clipboard history (read),
   snippets and quicklinks (read).
5. **Context on request:** the frontmost app, selected text, and the current clipboard. Each is a
   tool under the same rules, never pushed into a turn by itself.

## Phase 4: memory and plans

- **Memory:** a small store the agent reads at each session start and appends to through a
  `remember` tool, which has its own rule (Ask by default). It is editable and clearable in Settings,
  excluded from backups, and stays on this Mac.
- **Plan tool:** a checklist the agent keeps for multi-step turns, drawn pinned above the turn and
  stored with the message like searches and tool calls are.

## Decided

1. Calendar and Reminders access are migrated, as in the table above.
2. Built-in defaults: everything Deny; calendar/reminders read = Ask once their feature is on; web
   search = Allow, since its composer toggle is the opt-in.
3. "Always Allow" never proposes a pattern for `rm`, `sudo`, `curl` and the rest of the built-in list.
