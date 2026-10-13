# Blitz Agent — v1 plan

Status: Phases 1, 1b and 2 built; phases 3–4 planned. Builds on PR #49 (web search on Claude routes, the shell tool). Codex is out of
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
  Allow into Ask. It can never widen past the table, and the narrowing is not stored. (Phase 1b's
  modes replace the Ask toggle: Auto answers every Ask, Plan narrows to reads, and neither lifts a
  Deny.)
- **Asks are answered in Blitz, never from a notification.** A turn that waits shows a badge in the
  sidebar and posts a notification with no actions (phase 2).
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
    matching pattern does, so order is the user's; the session's mode applies last and never lifts a
    Deny. Deny patterns are a backstop, not a sandbox.
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
| `AgentSessionScope.swift` | Replaces `ChatToolScope` and `ShellCommandApproval`: `isEnabled`, `excluded: Set<AgentTool>` (MCP slugs included), `asksForEverything` (Phase 1b's `mode` replaces it). |

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
  - An **Ask for everything** toggle, which replaces the terminal Confirm/Auto-run glyph; Phase 1b's
    mode pill replaces it in turn.
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

## Phase 1b: modes, questions and plans (built)

### Modes

`AgentMode` is per session, on `AgentSessionScope`: never stored, and every new or reopened chat
starts in Manual, as does one switched to a route with no mode picker. The composer's mode picker
replaces the "Ask for Everything" toggle, which goes. Only a route that reaches Blitz's tools — an
API connection or the Claude command — has the picker; Codex has none and stays in Manual.

| Mode | What it does |
| --- | --- |
| **Manual** (default) | The rule table as written: Allow runs, Ask asks, Deny refuses. |
| **Auto** | Every Ask is confirmed without a dialog. Deny still refuses and a denied tool is still not offered: the table stays the ceiling. |
| **Plan** | Read-only. Offered: calendar and reminders read, web search, MCP tools whose server marks them `annotations.readOnlyHint: true`, the shell (every command asks, whatever the rules say), `ask_user`, `write_plan`. Never offered: calendar and reminders writes, other MCP tools. Each still needs its table row past Deny. |

Plan mode adds an instruction for that turn: investigate read-only, ask with `ask_user` where the
answer changes the plan, and finish by calling `write_plan`. A plan never changes anything by itself.

### `ask_user`

- A Blitz tool on every route that reaches Blitz's tools, in every mode, while Use Tools is on and
  outside an `@server` turn. It has no rule row: asking the reader is never a capability.
- Arguments: `question`, `options` (2–6 short strings), `multiSelect` (default false). A free-text
  answer is always possible.
- The turn pauses. The transcript shows the question with its options as chips. A chip, or text
  typed in the composer while a question is pending, is the answer; it does not start a new turn.
- The answer is the tool result. The question and answer are stored with the message, the way
  searches and tool calls are, so a reopened chat shows both.
- Stop, or deleting the chat, answers "The user did not answer." and the turn ends as stopped
  does. As built, leaving the chat does not: the turn is parked, as any reply is, and its question
  keeps waiting until the chat is reopened and answered.
- As built, a second question while one waits is refused with a sentence asking the model for one
  at a time, rather than queued.

### `write_plan`

- Offered only in Plan mode. Arguments: `title`, `markdown`. A second call replaces the chat's live
  plan; as built, the earlier card stays in the transcript, folded and marked "Replaced".
- The plan is a card in the transcript, rendered Markdown, stored with the conversation, and
  editable from the card — the live plan only, and never while a turn runs.
- The card offers **Execute** (switches the chat to Manual) and **Execute in Auto**. Either one sends
  a message that carries the plan's current text and asks the agent to carry it out.

### Steps (subagents, in order)

1. **Model:** `AgentMode` and its policy (replacing `asksForEverything`, with a read-only MCP input),
   the `ask_user` and `write_plan` catalogs (schemas, argument reading, results), the plan-mode
   instruction, harness coverage.
2. **Questions:** the pending-question state, the transcript card and the composer routing, storage,
   Stop and leave handling, on both routes.
3. **Modes and plans:** the composer mode picker, the plan card with editing and Execute, plan
   storage, MCP `readOnlyHint` plumbing, the per-turn instruction.
4. **Docs and verification:** `agent.md`, `ai.md`, the full suite, build, lint.

### Known limits

- On the Claude command a server is handed over in Plan only once Blitz has its tool list. One Blitz
  has never listed is missing from the context card's Tools rows in Plan until a Plan turn lists it.
- A server that lists no tools is listed again on every Plan turn, since an empty list reads as
  never listed.

## Phase 2: turns you can leave (built)

As built, in [`docs/features/agent.md`](../features/agent.md#waiting-off-screen):

- **A derived wait, not a stored flag.** `AIChatState.awaiting: AgentWait?` is `.approval` while
  an Ask request is open, `.answer` while an `ask_user` question waits, and nil whenever no turn
  runs, so it covers questions as well as approvals.
- **The sidebar and the menu bar.** A waiting chat's row shows a raised hand or a question bubble in
  place of the spinner, and the menu bar icon a dot while any chat waits.
- **Held until on screen.** An Ask dialog comes up only while its chat is on screen
  (`AIChatCoordinator.isOnScreen`, over `ChatPresence`): the window in front on that chat with Blitz
  active, or the palette up on Quick AI's. Otherwise the request is held on the chat, outside the
  shared dialog queue, and released when the chat comes on screen.
- **A notification** (`AgentNotificationPresenter`, `UNUserNotificationCenter`; macOS asks on first
  use) for a wait that starts off screen: "Blitz is waiting for approval" or "Blitz has a question",
  over the chat's title. It has no actions. Clicking it opens the AI Agent window on that chat, and
  the dialog comes up. It is withdrawn when the wait ends. Settings → AI → Agent → **Notify when the
  agent is waiting** turns it off; `aiNotifyWhenWaiting` stays out of backups and has the
  `settings.json` key `ai.notifyWhenWaiting`.
- **Stop and the round cap are unchanged.** Stop, deleting or clearing the chat, AI going off and the
  turn ending any other way decline whatever still waits, exactly once.
- **"Agent" where it reads better.** The window and its launcher command are **AI Agent** (found by
  `chat` and `agent`), and Quick AI's menus offer **Continue in AI Agent**. Command IDs and type
  names stay as they are.

Known limits:

- A wait that started on screen and was then left posts no notification; the badge and the dot
  still show.
- Neither an API connection nor the Claude command gives up on a held request within a day: the
  loop holds no request open while a tool waits, and the Claude CLI (2.1.285) awaits a
  `can_use_tool` answer with no deadline, until it is answered, the turn is interrupted or stdin
  closes; its 5-minute dialog deadline (CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS) is for its other
  dialogs, not permission requests. A request held inside one of Blitz's own tools rides that
  call's MCP timeout, which Blitz sets to 24 h (`ClaudeHostedServer.callTimeoutMilliseconds`); past
  it the CLI fails that call, while the request stays open in Blitz until answered or the turn
  ends. Blitz's Codex client puts no timeout on an elicitation it answers and keeps the app-server
  up while a turn runs; the app-server itself was not available to check, so whether it ever
  abandons an elicitation is unverified. Nothing needs doing in Blitz for now.

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

## Phase 4: memory

- **Memory:** a small store the agent reads at each session start and appends to through a
  `remember` tool, which has its own rule (Ask by default). It is editable and clearable in Settings,
  excluded from backups, and stays on this Mac.

## Decided

1. Calendar and Reminders access are migrated, as in the table above.
2. Built-in defaults: everything Deny; calendar/reminders read = Ask once their feature is on; web
   search = Allow, since its composer toggle is the opt-in.
3. "Always Allow" never proposes a pattern for `rm`, `sudo`, `curl` and the rest of the built-in list.
