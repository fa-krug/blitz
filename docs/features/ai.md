# AI providers and chat

Blitz has one app-wide provider layer for features that need text generation. Chat chooses its
model from Quick AI's header or the AI Agent window's composer, and `AIChatCoordinator.provider(for:)`
builds that chat's route through `AIProviderFactory` to stream an `AIRequest`.
Chat is the first consumer and [Quick Actions](quick-actions.md) the second; the provider layer
depends on neither, and Quick Actions carries its own route rather than borrowing this one.

Chat has two surfaces over one history, as Raycast's does. **Quick AI** is the palette screen: Tab
from the launcher asks what you typed, and the answer appears in place. **AI Agent** is a window —
saved conversations in a sidebar on the left, the open one on the right, and a composer at the
bottom with the model picker. ⌘J hands a Quick AI conversation to the window.

## Invariants

- **AI is off out of the box, and off means fully off.** `AppSettings.aiEnabled` is the flag:
  no `Quick AI` or `AI Agent` command in the launcher, no history database opened or created, no Codex
  helper for chat, no stop for it on Tab's ring, the palette leaves `.ai` and the window closes.
  Installed providers may still remain available for Quick Actions, which has its own switch and route. Turning AI off cancels
  every streaming reply and drops both transcripts, but touches neither the saved conversations in
  `ai-chats.sqlite3` nor a Keychain key. `aiEnabled` is excluded from settings backups like every
  other AI key, so an import can never arm a feature it cannot configure.
- **Installed model discovery is per-provider.** Settings → AI → Providers keeps Codex, Claude, Grok,
  OpenCode and Cursor visible with an individual toggle for each, all off by default. Turning one off cancels
  its check, clears its catalog and releases its process; Apple Intelligence is the default route when
  available, and saved API connections stay available.
- **A route that is off is off everywhere.** The on-device model and every API connection have the
  same switch an installed tool has (`aiDisabledRoutes`, by `AIModelSource.storageKey`). Off leaves
  the route configured — a connection keeps its key — but `AIModelOption.availableGroups` drops it
  from every picker, `AIProviderFactory` refuses it with a message, and a default that pointed at it
  moves to a route still on. `AISettingsStore.isRouteEnabled` is the one place that answers.
- **A picker lists what the reader ticked, and an untouched route lists everything.**
  `aiShownModels` holds, per route, the models its pickers show. No entry means all of them,
  including one the route starts offering later; ticking every box again drops the entry rather than
  storing the full list. The default model is always listed, since a picker must be able to show what
  it holds, and a removed connection takes its entry with it.
- **A set command path wins or fails.** `InstalledAILaunch.command` answers `.automatic`,
  `.executable` or `.missing`, and `.missing` fails the check and the turn. The lookup is never a
  fallback for a path that was set: falling back would run another copy and hide the mistake the path
  was set to fix.
- **A reader's variable never replaces one Blitz sets.** `InstalledAIKind.managedEnvironment` is
  what keeps a tool inside the chat — OpenCode's deny-all configuration, Claude's account MCP switch —
  and `InstalledAILaunch.inherited(for:)` drops a reader's variable of the same name, along with
  `NO_COLOR` and the `TC_MCP_` names that carry MCP secrets to Codex. Names are stored in
  `aiInstalledOverrides` and values in the login Keychain (`KeychainSecretStore.installedAIEnvironment`),
  read only for a tool that has variables.
- **Every request carries Blitz's own preamble, and the user's text goes after it.**
  `AIInstructions.compose` builds `AIRequest.instructions`: the preamble
  `AIChatCoordinator.preamble(for:)` assembles, then whatever Settings → AI holds.
  `AIPreamble.text(for:environment:)` joins up to three parts, each paid only where it applies:
  - **The core** says who the model is, how a reply renders (choices, linked sources), that what
    changes may be stale, and what Blitz is. Apple Intelligence gets `AIPreamble.onDevice`, a brief
    of it, since its window holds the prompt, history and reply together.
  - **The agent half** rides only on a turn offered tools — the route takes them and the tools menu
    is on — and names `ask_user` only where it is offered. It covers working with the gate (never
    ask in chat for a permission a dialog asks; a declined call is final and never routed around),
    the most specific tool, independent calls together, care weighed by what cannot be undone, tool
    output as information inside its fence ([Agent](agent.md#invariants)), and checking a result
    rather than claiming it.
  - **The environment** comes last: the day, time zone and macOS version. It is day-precise, so the
    instructions read the same all day; the tools that take a date carry the minute. A Codex thread
    is rebuilt when its instructions change, so the first turn of a new day starts a fresh one.

  The preamble keeps the model a general-purpose assistant — the app facts are reference for when
  the user asks, never a scope limit — and asks for honest comparisons; it does not instruct the
  model to favour Blitz over anything else. It is not shown in the pane, and `AIPreamble.swift`
  holds the only copy of it — edit the prompt there, not here. `compose` returns `nil` when the user
  has turned the system prompt off, agent half and environment included, and every transport drops
  a nil instruction, so a turn then carries none.
  After it, `AIChatCoordinator.instructions(for:)` appends the memory block while Read Memory is
  Allow and the chat's Use Memory is on (`AgentMemoryInstructions.appending`,
  [Agent](agent.md#memory)), then a mode's instruction (`AgentModeInstructions.appending`); each
  has its own switch, so the system prompt switch withholds neither.
- **API keys live only in the login Keychain.** `AIConnection` persists the provider, endpoint and
  model identifiers in `UserDefaults`; it never contains a key. Keys are addressed by connection UUID
  through `KeychainSecretStore.aiAPIKeys`, and never enter logs, errors or settings backups. A key is issued for one
  endpoint and never follows a connection retargeted at another — change the provider or base URL and
  both model discovery and Save ask for a new key, rather than introduce the saved one to a host it
  was never meant to reach (`AIEndpointPolicy.sameDestination`).
- **Remote endpoints require HTTPS.** Plain HTTP is accepted only for `localhost`, `127.0.0.1` and
  `::1`, where a key is optional, and any other scheme is rejected outright — a loopback host does
  not excuse `ftp://`. `AIEndpointPolicy` is the one place that decides this.
- **MCP OAuth is separate from the model provider's login.** The HTTP MCP client can sign into a
  hosted server from Settings and keep its client credentials and tokens in that server's Keychain
  item. API chat uses this session without receiving its credentials. A rejected refresh becomes
  Sign-in required on the server, an unserved one does not end the session, and either way a
  running tool loop receives an explainable failure result. The same session is lent to the Codex
  and Claude routes as a bearer header, so a hosted server is signed into once for every route.
  See [MCP](mcp.md).
- **The chat model is the routing decision.** It names the on-device model, a model exposed by the
  installed Codex, Claude, Grok, OpenCode or Cursor command, or one saved API connection and model. Installed
  routes also carry their reasoning effort when the selected model supports one. A removed route
  falls forward to the on-device model when this Mac
  has one, then to another usable API model, then to no selection. Discovering an installed command
  never silently selects a networked model.
- **Every chat keeps its own model.** `ChatSession.model` is stamped on the first send and changed by
  either surface's picker; `conversation_details` stores it, so reopening a chat reopens its model and
  effort. A pick also moves the app default, which is only what a *new* chat starts on. A chat whose
  route was removed in Settings answers on the default rather than failing
  (`AIChatCoordinator.model(for:)`), and keeps its stored pick in case the route comes back.
- **Reasoning is shown, folded, and never resent.** `AIStreamEvent.reasoning` carries the text a route
  shares — OpenAI-shaped `reasoning` / `reasoning_content` / `reasoning_details`, Anthropic and
  Claude-CLI `thinking_delta`, Codex's reasoning summary — into `ChatMessage.reasoning`, a list of
  `ChatReasoning` blocks. Thinking that resumes after answer text opens a new block pinned at that
  text offset, so `segments` places it where it happened, like a search or a tool call; each block
  is timed until the answer resumes. The transcript folds each under "Thought for Ns";
  `message_thinking` keeps them; `requestMessages` never sends them back. A route that only says
  it is thinking still just shows "Thinking…". How much there is to read is the route's call:
  Claude streams full summaries, while Grok's CLI sends a line or two in the clear and the rest of
  its reasoning encrypted, so a Grok fold is short by design, not by truncation. An OpenAI-shaped
  route also counts a `<think>…</think>` block that opens its content, and only there, so a
  literal `<think>` later in an answer stays text.
- **A chat is named by its harness.** As soon as a chat's first question is sent — so the title
  lands while the answer streams — again after an answer if that failed, and never over a rename,
  `AIChatCoordinator.nameIfNeeded` asks for a title: Claude's CLI through its own
  `generate_session_title` control request (`persist: false`, so nothing enters its history), every
  other route with one side request to the chat's own model (`ChatTitle.instructions`). The Claude
  request holds stdin open and reads with `availableData` until the answering line is whole: a
  `read(upToCount:)` waits for a full chunk or EOF, which left every title waiting on the watchdog.
  `ChatTitle.sanitize` strips labels, quotes and full stops; `conversation_details` keeps the
  result, and `displayTitle` prefers a rename, then this, then the first question.
- **A reply's links are its sources.** `ChatReferences.extract` gathers the web links of a finished
  reply — Markdown links by their own names, bare URLs by host and path — in the order cited, one
  per page, skipping code, and both surfaces list them under the reply as numbered glass chips that
  open in the browser. The same numbers close the sentence that cited each source, as a raised,
  linked `[n]`: `ChatCitations` finds each link's sentence end in the drawn text and inserts after
  it, two sources in one sentence sharing it, so prose and chips always agree. The preamble asks the model to link a page it relies on inline, so a cited
  answer carries its sources without a second request.
- **Every tool call answers to the agent's one rule table.** Shell, files, the Mac, calendar,
  reminders, personal data, context, other chats, web search and each MCP server are rows of
  `AgentRules`, decided by `AgentPolicy` and enforced by
  `AgentGateCoordinator`, which `AIChatCoordinator` owns: a denied tool is never offered, every call
  is decided when it arrives, and an Ask is Blitz's own dialog. The ⌘K Tools menu — Use
  Tools and a switch per tool — and the composer's mode pill — Manual, Auto or Plan — edit the chat's
  `AgentSessionScope`, held on `AIChatState.agentScope` and never stored; nothing in it lifts a
  Deny, and `@server` still narrows one turn inside it. A route that cannot call tools has no
  Tools row. All of it is [Agent](agent.md).
- **A reply can stop to ask, and the answer is only ever a tool result.** `ask_user` is offered
  wherever Blitz's tools reach, Use Tools is on and no `@server` narrows the turn, in every mode. The turn waits on the reader,
  one question at a time; the answer goes back to the model as the call's result and never starts
  a turn, and every way the wait can end resolves it exactly once. See [Questions](#questions).
- **A plan changes nothing until the reader carries it out.** `write_plan` is offered only in
  Plan, and its plan is a card in the transcript: the chat's live plan is the last one written, the
  reader may edit it between turns, and only its **Execute** buttons act on it, by sending it as
  the reader's next message. See [Plans](#plans).
- **The Mac's own calendar and reminders are tools Blitz runs.** Their read and write halves are
  separate rows, offered only while the feature's own switch is on — that switch is where macOS was
  asked — and only to a route that can call Blitz back: an API connection, through Blitz's loop, or
  the Claude command, through the in-process server `ClaudeHostedServer` answers (see below). Codex
  is handed servers alone, never Blitz's tools; Apple Intelligence calls none. A reminder is edited
  in place by id rather than duplicated, and the result tells the model what was actually saved.
  The tools themselves live with their features — see [Calendar](calendar.md#chat-tools) and
  [Reminders](reminders.md#chat-tools).
- **A model can run shell commands as the user, only as the agent's rules allow.**
  `shell_run_command` (`ShellToolCatalog`) is offered to exactly the routes the calendar is, while
  the Run Commands row is not Deny; each command is decided by its row and the ordered shell
  patterns, and an Ask puts the command verbatim and its folder in Blitz's own dialog — see
  [Agent](agent.md#shell-patterns). `ShellToolRunner` runs `$SHELL -l -c` (else the account's
  shell, else zsh) in the folder asked for, home by default, with stdin empty and `BLITZ=1`; at
  60 s it signals the command's process group, TERM then KILL. Each stream keeps its first 16 KB and
  counts the rest, and the model reads the exit status, both streams and what was cut; a declined
  or refused call is a failure result. `shell-tool-test` pins the schema, call reading and answers,
  and runs the runner against zsh.
- **A model can list, read and change the user's files, only as the path rules allow.**
  `files_list` and `files_read` (Read Files), and `files_write`, `files_move` and `files_trash`
  (Change Files), from `FileToolCatalog`, go to the same routes as the shell. Every path is weighed
  with its symlinks resolved, resolved again just before the runner acts, and nothing is ever
  deleted for good — the Trash is the furthest it goes. See [Agent](agent.md#file-tools).
- **A model can list and read the reader's other chats, and archive them, only as the rules
  allow.** `sessions_list` and `sessions_read` (Read Other Chats), and `sessions_archive` and
  `sessions_unarchive` (Archive Chats), from `SessionToolCatalog`, go to the same routes; a chat
  never reads or archives itself, and a transcript comes back as text, 64 KB at a time. See
  [Agent](agent.md#session-tools).
- **A model can act on the Mac, only as the rules allow and never past undoing.** `mac_open`
  (`OpenToolCatalog`, Open Apps, Files and Links) opens an installed app, a file or folder by path,
  or an `http`, `https` or `mailto` link; `shortcuts_list` and `shortcuts_run` (Run Shortcuts) list
  and run an Apple Shortcut with optional text input; `system_actions_list` and `system_action_run`
  (Run System Actions) run a Blitz system action; `window_layouts_list` and `window_layout_apply`
  (Apply Window Layouts) apply a saved layout. They go to the same routes, all four rows start on
  Deny, Plan never offers them and each run asks every time. A path is weighed as a read with its
  links resolved; a script, installer or link file, every other scheme and the system actions that
  end the session or lose something are refused outright. See [Agent](agent.md#mac-tools).
- **A model can read the reader's own data and context, and add to the note, only as the rules
  allow.** `contacts_search` (Read Contacts), `note_read` (Read the Note), `clipboard_history`
  (Read Clipboard History), `snippets_list`, `snippets_read` and `quicklinks_list` (Read Snippets
  and Quicklinks), and `context_frontmost_app`, `context_selected_text` and `context_clipboard`
  (the three Context rows) only read; each asks by default, may be allowed for the chat and is
  offered in Plan. `note_append` (Add to the Note) adds to the end of the open note, starts on
  Deny and asks every time. Each runs through its feature's coordinator under that feature's
  switch, never past its exclusions: no contact note or photo, no copy marked secret, nothing an
  ignored app copied. The context rows read the app the reader was in before Blitz, never Blitz
  itself. See [Agent](agent.md#personal-and-context-tools).
- **A model can read one web page as text, and a local address always asks.** `web_fetch`
  (`WebFetchToolCatalog`, under Fetch Web Pages) goes to the same routes, fetches an `http` or
  `https` URL on its own cacheless, cookieless `.ephemeral` session (`WebFetchRunner`) — 30 s, 5 MB
  and five redirects at most, each redirect checked again — and answers with the final URL, the
  status, the title and the page's readable text (`HTMLTextEngine`), cut at `maxCharacters`. Images,
  PDFs and other files are refused naming their type. A URL on this Mac or its local network asks
  whatever the row, a chat grant or Auto say. See [Agent](agent.md#web-fetch).
- **A reply can end on choices, and a choice is only ever a message.** The preamble lets the model
  close a reply with a fenced `choices` block, one option per line. `ChatChoices.split` lifts the
  fence out of the prose (an unclosed one mid-stream too, so it never flashes as code). Apple's
  on-device model tends to drop the fence and write a bare `choices` line over a list, so a
  label on its own line with nothing but list items after it, to the reply's end, counts too; and
  `ChatSuggestionChips` draws the options as `ChatChoiceChip` glass capsules — the chip a waiting
  question's options use too: in the window they rise out of the
  composer, sitting on its top edge until the reader starts typing; in Quick AI they close the
  transcript. A click sends the option as the reader's next message, through the same `send` a
  typed one takes. Older replies lose their chips, since only the last question is still open. It is text in, text out, so it
  works on every route — and not at all with the system prompt switched off, which drops the
  preamble that describes it.
- **Token usage belongs to the reply that reported it.** `AIUsage` carries input, output, cached
  prompt and thinking tokens, and the model's window and cost where a route says them — Claude's CLI
  reports all of it, the Anthropic API its cache, OpenAI-shaped routes their reasoning tokens and
  OpenRouter its cost. `ChatMessage.usage` holds it and `message_details` keeps it, so a reopened chat
  still knows its last turn.
- **The on-device route is configured by having a Mac.** `.appleIntelligence` takes no key, opens no
  socket and names no endpoint, so the Keychain, HTTPS and ephemeral-session rules below have nothing
  to bind to — the Settings pane must never grow a credential field for it. It is text-only and
  offers no web search, its brief preamble still rides ahead of every turn, and history is bounded to
  `AppleIntelligence.contextBudget` rather than the cloud routes' ~100 KB because the on-device window
  holds a prompt and its reply together. Availability is asked for each time, never cached at launch:
  the model finishes downloading mid-session, and reading it inside a view body leaves SwiftUI
  observing the framework's own state.
- **An unavailable on-device model is reported, never rerouted.** Fall-forward exists for a route the
  reader *removed*; a Mac with Apple Intelligence switched off keeps its stored selection and is told
  why, because silently moving someone from a free, private, local model onto a billed endpoint is
  the one redirection this feature must never perform.
- **Installed commands reuse their own login.** Blitz launches the user's `codex`, `claude`, `grok` or
  `opencode` executable without asking for or storing another key. Codex inherits the user's normal
  home and credential-store setting; Claude, Grok, OpenCode and Cursor inherit their normal configuration. Blitz
  never reads those credential files, browser cookies or undocumented web endpoints. A Codex route
  with no account is ready only when `account/read` explicitly says `requiresOpenaiAuth: false`.
- **Codex runs Blitz's MCP servers and nothing else.** The app-server still launches with every
  feature flag off and a read-only, network-disabled sandbox, and every server request but one is
  declined. The servers the reader configured for their own Codex are disabled by name at launch,
  so none of them starts inside a Blitz thread, and the servers [MCP](mcp.md) supplies take their
  place when a chat has any, under names of their own (`blitz-<handle>`) so that no table of the
  reader's merges into one. A launch that cannot read the reader's list, or cannot address a name on it, does not start. A turn
  that arms none keeps `approvalPolicy: "never"`; a turn that arms some uses `"untrusted"`, where
  a tool call becomes an elicitation Blitz answers from the reader's own trust setting.
- **Tool calling is a decorator, except where the CLI is the client.** `AIToolLoopProvider` wraps a
  route and re-streams the turn until the model stops asking, so a route with no tools behaves
  exactly as it did and `AIChatState` reduces one more pair of events. Codex and the Claude command
  run that loop themselves, so `AIModelSelection.runsItsOwnTools` hands them an
  `AIToolServerSession` instead of a wrapper — same servers, same trust, same rows, and the same
  round cap counted in whatever unit the CLI counts in. Only chat wraps or arms: `quickActionProvider()`
  rewrites the reader's own selected text and has nothing to call. Since `ask_user` rides every
  chat turn with Use Tools on, every such turn on an API connection or the Claude command is
  wrapped or armed. `AITool.showsCallRow` is false for `ask_user` and `write_plan`, whose own cards
  stand in: the loop yields no `.toolCall` or `.toolResult` for them, and the Claude stream decoder
  drops their `tool_use` row. Each such call — the loop's, or a hosted one on Claude's pipe — first
  yields `.barrier` and runs only once `AIChatState` has applied the text before it and passed it, so
  a card never lands ahead of that text; Stop or a turn ending frees it. A turn's tool messages stay inside
  the loop — what the transcript keeps is a `ChatToolUse` record, pinned at a text offset like a
  search, so `boundedContext` can never separate a stored call from its result.
- **Every HTTP request uses a private ephemeral `URLSession` with no URL cache.** Provider traffic must
  not create a second credential or response cache on disk.
- **A refusal shows what the provider said.** `HTTPAIProvider` reads a non-200 body before the turn
  fails, up to `AIProviderFailure.bodyLimit` (8,000 bytes) and for at most five seconds, and the
  failed reply is the status's own line with the provider's message under it.
  `AIProviderFailure.providerMessage` finds that message in OpenAI's shape and its copies',
  Anthropic's, Gemini's array, vLLM's and OpenRouter's nested `metadata.raw`; a plain-text body is
  shown as sent, an HTML error page is left out wherever it sits, and a JSON body the cap cut gives up
  only a message that is still whole. The connection's key, bearer tokens and key-shaped strings are
  replaced with `[redacted]`, and then the message is cut at `messageLimit` (600 characters). A key
  under eight characters is redacted only as a whole word, so it cannot eat into a longer one; a
  local server's placeholder key is redacted like any other. A mid-stream error is treated the same
  way: the decoder is handed the key, an Anthropic `error` event shows its message under its line,
  and an OpenAI-compatible one reads through `metadata.raw` too, or says the provider stopped the
  response when there is no sentence to show.
- **Wire shapes live in `Model/`, where a harness reaches them.** `ai-provider-test` compiles the
  shipped provider models and pins endpoints, request bodies, stream parsing, persistence repair,
  Codex protocol framing and both CLI routes' MCP launch encodings. Request bodies are
  `AIRequestBody`'s, in `Model/`, precisely so a wrong shape fails a harness rather than a
  conversation. `installed-ai-test` runs the Claude, Grok, OpenCode and Cursor adapters against real
  subprocess stubs and pins their safety boundaries.
- **Grok, OpenCode and Cursor are text transports, not agents, and so is Claude with nothing to
  call.** Claude runs one turn with no tools, browser integration, slash commands or persisted
  session — but never `--bare`, which reads neither
  OAuth nor the keychain and so refuses the very sign-in this route reuses. Given servers by
  [MCP](mcp.md) it becomes an agent for that turn and only over those: `--tools ""` still withholds
  every built-in, the turn keeps its stream-json stdin open so consent has a pipe to answer on,
  `--disallowedTools "*"` comes off because it removes the MCP tools too, `--max-turns` carries
  the round cap instead of the constant 1, or is left out on Unlimited, and
  `--permission-mode default` with an ask rule per server keeps the reader's own allow rules and
  default mode from answering before Blitz does. Blitz's own tools — the calendar, reminders, the
  shell, `ask_user` and `write_plan` — arm a turn the same way with no server at all: the
  configuration names `blitz_data` as an `sdk` server, which the CLI
  reaches as `mcp_message` control requests on the turn's own pipe, and `ClaudeHostedServer`
  answers its JSON-RPC from the tools resolved when the turn started. A call runs through the same
  code the loop calls, so it passes the agent's gate and asks there itself; its `can_use_tool`
  question is allowed without a second dialog for that reason. The entry carries a `timeout` of
  `ClaudeHostedServer.callTimeoutMilliseconds`, 24 h, because a call may wait on the reader — a
  question, or an Ask dialog — and a server's own timeout outranks a short `MCP_TOOL_TIMEOUT` the
  reader set for their own servers. `MCPSlug` never
  yields `_`, so no server the reader adds can take that handle. `@server` and the chat's Use
  Tools switch withhold it as they do in the loop. Since `ask_user` is offered whenever Use Tools
  is on, a Claude chat turn is left with nothing to call only with Use Tools off, on an `@server`
  turn whose server is not handed over, or under a managed MCP policy.
  Grok runs with `--deny *`,
  `dontAsk` permissions and a workspace sandbox, and never `--always-approve`, so a user's always-approve
  config cannot arm tools for this route. OpenCode runs `--pure` with deny-all permissions, disabled
  sharing and a private working directory. Cursor runs `agent -p --mode ask` with `--trust` against
  Blitz's private workspace and never `--force` / `--yolo` / `--approve-mcps`; ask mode blocks edits.
  Each deletes the session or chat it created once the child exits, and Blitz never reaches into the
  user's own config to do it. **Only Claude keeps the user's MCP servers out of the process**, through
  `--strict-mcp-config` — whether the config it names is empty or Blitz's own — and even that
  yields to an installed managed MCP policy, which makes the CLI reject both flags and leaves MCP
  on that route the organization's decision; its Providers page says so.
  Grok, OpenCode and Cursor load the global config either way,
  because their configs merge with no opt-out; what refuses the call is `--deny *` for Grok,
  `permission: deny` for OpenCode and withheld MCP approval for Cursor. Cursor's is the only one resting
  on an approval prompt rather than an explicit deny, which is why its Providers page says so and the
  others do not. That is also why none of the three may be handed a server: there is no way to offer
  one without offering the reader's own. Only Claude searches the web, and only on a turn whose
  web-search toggle is on: `--tools WebSearch` hands it that one built-in, never WebFetch. Unarmed,
  `--allowedTools WebSearch` and `--permission-mode dontAsk` replace the deny-all, which would
  outrank the allow, so nothing else runs whatever the reader's default mode; `--max-turns` rises
  to 6 for a search and an answer. Armed, the `--settings` rules add `allow: [WebSearch]` beside the
  ask rules, and the boundary prompt names WebSearch beside the MCP tools. Only Claude also
  takes images: every Claude turn is one `--input-format stream-json` user message, the newest
  question's pictures as base64 `image` blocks beside the framed prompt. Claude also runs with
  `--thinking-display summarized` — a hidden flag, and the only switch that works: a `-p` run forces
  its display to `omitted` unless one is named explicitly, and the `showThinkingSummaries` setting
  is read only by an interactive session. Without it Sonnet and Opus stream every thinking block
  empty, so the fold would show one opening line.
- **A conversation is live in one place at a time.** `AIChatSurfacesState` holds Quick AI's
  `AIChatState`, the window's, and any window chat left mid-reply. Opening a chat anywhere takes the
  live state from wherever it already is — ⌘J moves Quick AI's whole state object, reply, staged
  files and all, into the window — and Quick AI will not take a chat the window has: its open policy
  starts fresh instead, and Chat History opens that chat in the window. Two states editing one
  transcript would each save over the other, and `ChatHistoryStore.save` rewrites the stored tail
  from memory.
- **Leaving a chat never cancels it.** Switching the window to another conversation, or starting a
  new one, parks a streaming reply rather than stopping it; it saves itself when it ends, the sidebar
  shows its spinner meanwhile, and reopening it resumes the same live state. Only Stop, deleting the
  chat, turning AI off or quitting cut a reply short. A reply is the conversation's, which is
  `AppCore`'s, so closing the window cancels nothing either.
  Codex chats run side by side too: each chat keeps its own ephemeral app-server thread, and
  `CodexTurnRunner` routes every notification and every tool-call question to its turn by
  `threadId`, so a Stop ends only its own. The app-server's server list is fixed at launch, so a
  turn armed with a different one relaunches it and ends the other chats' live threads with a
  reason, rather than leaving them waiting on a process that is gone.
- **Quick AI's lifetime is decided on the way in.** Pop to Root forgets the screen and the query;
  whether the next summon resumes the transcript is Settings → AI's `Quick AI opens to`, applied in
  `QuickAICoordinator.applyOpenPolicy` on the way into `.ai`. It is not Pop to Root's job, because
  that fires on every hide, so no chat would survive Escape; and deciding at open time from
  a timestamp leaves one clock instead of two racing over the same state, and a verdict that still
  holds after a relaunch. A reply still streaming is never reset out from under the reader — it was
  asked for — and the transcript is saved regardless, so the old conversation is one ⌘K → Chat
  History away, and in the window's sidebar. The window has no policy: it reopens on whatever it
  last showed.
- **Arriving with a question skips the open policy entirely.** `ask(_:)` — ⇥ from the launcher, and
  the Quick AI fallback row — always starts a new chat and submits the text, because a question asked
  outright is not a summon: resuming a transcript to append an unrelated line to it would be the one
  reading of `Quick AI opens to` nobody wants. It is `showPalette(mode: .ai)` and `send`, never
  `show`.
- **Staged files survive a re-summon; only the typed draft does not.** `applyOpenPolicy` treats a
  pasted-but-unsent attachment as resident state: `Recent Conversation` will not open a saved chat
  over one, and `A New Conversation` resets only a chat that actually has messages, since an empty
  chat is already new and resetting it would drop the file for nothing. A file cost a read and a
  decode, which is not the same as a half-typed line — that is still dropped by `prepare`.
  ⌘J carries them into the window with the conversation; opening another chat there still disowns
  a state's own, which is the rule they belong to.
- **`AIConversationOpenPolicy` is the whole rule, and it is pure.** `Recent Conversation` resumes the
  resident transcript, or reopens the newest saved one when nothing is resident, unless it has been
  idle past `Start a new conversation after`; `A New Conversation` always starts fresh. There is no
  third setting for "immediately" because that *is* `A New Conversation` — two controls able to
  express one state would only ever disagree.
- **History is local and lazy.** Conversation summaries stay in memory while transcripts load from the
  system SQLite database only for the opened chat. Empty chats are never saved.
- **A rename and a pin are the reader's, and nothing derived overwrites them.** Both live in
  `conversation_details` beside `conversations`, whose `title` stays the first question: every save
  rewrites that summary, so a rename stored there would be undone by the next turn. A blank rename
  hands the title back. The same row holds the harness's title and the chat's model, each column
  upserted on its own so no write clobbers another; `message_details` is its per-message twin, for a
  question's `@server` scope and a reply's usage. Both tables are `CREATE TABLE IF NOT EXISTS` with
  `ON DELETE CASCADE`, so they needed no migration and a deleted chat takes its facts with it.
- **Pinned chats are the ones asked to be kept.** Retention skips them, and so does Delete All Chats
  — which says so in its confirmation — the way a clipboard clear keeps its pins.
- **Archiving puts a chat away and never loses it.** `chat_archive` (`conversation_id` keyed to
  `conversations` with `ON DELETE CASCADE`, `archived_at`) is `CREATE TABLE IF NOT EXISTS` like the
  rest, so it needed no migration. `ChatHistoryStore.saved` holds every chat; `conversations`, which
  the sidebar, ⌃⇥, Quick AI's Chat History and its open policy read, leaves archived ones out, and
  `archived` holds only those. Only a delete or retention removes an archived chat: Delete All Chats
  spares it as it spares a pinned one, while `Keep conversations` still prunes it. A pinned chat is
  never archived — `archive` refuses it, and nothing offers to — and neither is a chat whose reply
  is still arriving. A chat that takes a turn leaves the archive (`save` drops its row), and opening
  one from Archived unarchives it first, so an archived chat is never live on a surface. See
  **Archive** under [AI Agent](#ai-agent).
- **Retention is enforced only while AI is on.** `Keep conversations` prunes on the enable transition
  and whenever the setting changes, through `AIChatCoordinator.applyRetention` — never on a schedule
  and never while `aiEnabled` is false, because age passes while the feature is off and "off means
  fully off" promises the file is untouched. A Mac left off for four months keeps its chats.
  `ChatHistoryStore.prune(before:)` is one `DELETE`, sparing pinned chats but not archived ones, that cascades to messages, images, searches and the archive row,
  and it `VACUUM`s only when something actually went: pictures live inline as BLOBs, so this is the
  one store where a delete alone frees pages without ever shrinking the file.
- **Everything but the newest message is bounded.** `ChatSession.boundedContext` sends that message
  whole — truncating what someone just typed is worse than the provider's own error — keeps images
  and documents only on that turn and only up to `AIAttachmentBudget`, inlining an attached text
  file into that turn alone, and walks older text newest-first into a
  budget the *route* names: ~100 KB for a cloud endpoint, `AppleIntelligence.contextBudget` for the
  on-device model. Every transport funnels through `requestMessages(textBudget:)`, so no route can
  resend every image each turn or let history grow the payload as a chat goes on. The composer refuses a picture
  past the budget and says so, rather than letting send time drop it silently.

## Connections and routing

`AIModelSelection` has seven cases: `.appleIntelligence`, `.codex`, `.claude`, `.grok`, `.openCode`,
`.cursor` and `.api`.
The first needs no connection at all. The next five name a model from an installed command and carry
no credential. `.api` points at one `AIConnection`; `AIProviderKind` exposes four named presets plus a
custom OpenAI-compatible route.

| Setting | Transport | Default base URL |
| --- | --- | --- |
| Apple Intelligence | Foundation Models, on device | none |
| Codex | installed `codex app-server` | user's Codex account |
| Claude | installed `claude -p` | user's Claude login |
| Grok | installed `grok --prompt-file` | user's Grok login |
| OpenCode | installed `opencode run` | providers already configured in OpenCode |
| Cursor | installed `agent -p --mode ask` | user's Cursor login |
| OpenAI API | OpenAI Chat Completions | `https://api.openai.com/v1` |
| Anthropic Claude | Anthropic Messages | `https://api.anthropic.com` |
| Google Gemini | Gemini's OpenAI-compatible API | `https://generativelanguage.googleapis.com/v1beta/openai` |
| OpenRouter | OpenAI-compatible | `https://openrouter.ai/api/v1` |
| OpenAI Compatible | OpenAI-compatible | user-editable |

The base URL stays editable for every preset because gateways and organization proxies are legitimate
destinations. `AIHTTPConfiguration.endpointURL` accepts a complete endpoint or appends the transport's
completion path. Gemini requests identify Blitz through `x-goog-api-client`; OpenRouter requests
carry the app title.

Each connection has an ordered, deduplicated list of exact model identifiers. While its editor is open,
Blitz asks the configured provider for the models available to the entered key and uses the result
to list the models the user can add, which typing filters and ranks. A catalog can run to hundreds,
so the list shows ten at a time with a Show More row. Selected models stay visible above the list and
drop out of it. A catalog field Blitz cannot read — a gateway's `"reasoning": true` where OpenRouter
sends an object — is dropped and the model kept, so one odd entry never empties the list. Discovery is
debounced, cacheless and never persists the typed key. A
custom gateway may not implement a model-list endpoint, so exact identifiers can always be entered
manually. A gateway can also list an incomplete catalog under any preset, so search offers the typed
identifier ("Use … anyway") whenever no loaded model is named by it exactly, even beside partial
matches; Return still adds only an exact catalog match (`AIModelDiscovery.exactMatch`, an ID before a
display name), so a typed prefix never becomes a stored identifier. Blitz does not ship or guess an API catalog that can become stale. Codex gets its models
and reasoning efforts from `model/list`; OpenCode gets identifiers and model-specific variants from
`opencode models --pure --verbose`. Claude answers an `initialize` control request — written to a
stream-json `-p` run that then gets no prompt, so no model is called — with its own `/model` list;
`InstalledAIModel.claudeCatalog` keeps one row per resolved model (dropping `default`, which restates
another), names each by the version its alias points at today ("Claude Opus 5.5"), and takes each
one's `supportedEffortLevels`. The version is in `description` before a " · " on an older CLI and in
`displayName` on a newer one, which describes a model without it; the name is read from whichever
has it. The same answer carries the account, which `claudeAccount` reads for the Overview page. A model the CLI starts offering appears without a Blitz release. Cursor lists models
from `agent --list-models` after `agent status --format json` confirms a login.

Turning thinking off is a reasoning effort, not a second control: `reasoningOptions(for:)` answers with
the connection's catalogued efforts, or — for a connection with no catalog to publish one — `Default`
and `None`. `takesThinkingField` decides who gets that pair: an OpenAI-shaped preset whose base URL is
not that preset's own, because a preset pointed away from its own API is a gateway, and a gateway is
the only destination Blitz can offer the switch to honestly. Picking `None` sends
`"thinking": {"type": "disabled"}`, which is how DeepSeek and the endpoints that copied its contract
answer without reasoning first. A vendor API is never offered the pair and so is never sent a field it
does not define — which matters precisely because the preset alone says nothing about the destination
when every base URL is editable. Only `None` is ever written, so every other body is the one it always
was, and the choice rides in `AIModelSelection.effort` like every other route's.

## Provider interface

`AIProvider.stream(_:)` accepts provider-neutral messages, optional instructions, a maximum output
token count and the tools the turn may call. It returns an `AsyncThrowingStream` of text, thinking
state, tool activity, usage and completion. OpenAI-compatible reasoning fields and a response's
leading `<think>…</think>` content block are surfaced as `.thinking` and `.reasoning`, never mixed
into answer text. `AIThinkTagDecoder` holds back a tag split across deltas, drops the whitespace
between the closing tag and the answer, and flushes an unclosed block as reasoning. Anthropic
system messages are lifted into its top-level `system` field; the other HTTP routes keep system
messages in the OpenAI message array.

`AIProviderFactory` resolves the selection, validates an API endpoint, reads an API key at the last
possible moment and returns `AppleIntelligenceProvider`, `HTTPAIProvider`, `CodexInstalledProvider`
or `InstalledCLIProvider`. A consumer should hold neither settings nor credentials itself. The
`selection` and `guardrails` overload lets Quick Actions pick its own route and ask for permissive
content transformations without a second factory.

`AIModelOption.groupedCatalog` is the Settings picker catalog for both AI and Quick Actions. Provider
sections, ordering and model labels therefore cannot drift between the panes. Each route stores its
own complete `AIModelSelection`, including the selected reasoning effort for installed models and
OpenRouter models that offer one.

`AppleIntelligenceProvider` is the only route whose model is a local process. It builds a `Transcript`
from the turns ahead of the newest user message and streams the rest as the prompt, so a conversation
resumes rather than being replayed as one blob. Foundation Models reports the whole answer so far in
every snapshot while every other transport speaks in deltas; `AppleIntelligenceDelta` is the one place
that difference lives. Guardrails are a construction parameter rather than a constant: chat writes
fresh prose, where the default filter belongs, and a later text-rewrite feature transforms text the
reader already wrote, which is what `permissiveContentTransformations` exists for — so that feature
needs no second provider. `GenerationError` never reaches the transcript as-is; its `Context` carries
a debug description written for a log, so each case maps to a plain sentence instead.

## Chat surfaces

### Quick AI

The built-in `Quick AI` launcher command enters `AIScreen`, and carries a bindable global shortcut
(`HotKeyAction.command(.quickAI)`) that does the same thing from any app; Tab from the launcher is the
third way in. Settings → AI holds the recorder and a checkbox for the command's place in launcher
search, beside `AI Agent`'s; either shortcut keeps working while its command is hidden, and does
nothing at all while the feature is off. The palette search field becomes the single-line composer.
The footer pill and Return are one action, `activate`: Send, Answer while a question waits, or Stop
while a response streams — an empty composer sends nothing, so the pill never needs a disabled
state. While a question waits the field's placeholder is "Answer the question…", and Stop is ⌘K →
Stop Response (`⌘.`). The header's trailing model
switcher opens by click or ⌘P, uses the same in-window menu control as Clipboard's type filter and
changes the chat route for the next message. For installed routes and OpenRouter models whose catalog
reports the capability, it also shows the supported reasoning efforts and changes the chat effort for
the next message. Other API routes keep their provider default because their model catalogs expose no
portable effort contract. Neither change interrupts a response already streaming; stopping one is
the pill's job, so the header never has to fit a third control beside the switcher.

The second footer control is the palette's normal Actions (`⌘K`) menu. It owns Continue in AI Agent
(`⌘J`; Open AI Agent while the chat is empty), New Chat (`⌘N`), Chat History (`⌘Y`) and AI Settings
(`⌥⌘,`), plus Stop Response (`⌘.`), Regenerate Response (`⌘R`), Copy Last Response (`⇧⌘C`) and
Remove Attachments when those apply. The chords are Raycast's where it has one, and `AIScreen.perform`
maps each `PaletteShortcut` to its action. AI Settings takes ⌥⌘, because ⌘, stays the app's own
Settings on every screen. Continuing closes the palette and carries the half-typed line into the
window's composer with the conversation. Chat History is the palette's own browser over the same
saved chats the window's sidebar lists: ↵ opens one in Quick AI, or in the window when the window
already holds it, and Continue in AI Agent (`⌘J`) takes it to the window either way.

### AI Agent

The `AI Agent` command (`command:ai-chat-window`, `HotKeyAction.command(.aiChat)`; the ID and the
type names keep "chat") opens a titled `AppWindowController` window owned by `AIChatCoordinator`,
created with the title "AI Agent", which the chrome replaces with the open chat's, and autosaved
as `AIChatWindow`. The launcher finds it by `chat` and `agent`
alike ([boosted terms](launcher.md#kind-priority-and-boosts)). Its shortcut
toggles: `toggleWindow` closes the window when it is key, as Escape would, and one open behind
another app comes forward instead. The palette row always opens it, since `LauncherCoordinator`
reads whether the palette was up before hiding it can hand key status back to the chat. It is built
the way Settings is — an `AIChatSplitViewController` with a native sidebar item, here collapsible, and a
unified toolbar whose title is the open chat's — so it takes the system's own sidebar, toolbar and
menus rather than the palette's scrim. `AIChatWindowChrome` owns the toolbar — the sidebar toggle
and New Chat as two round buttons at the sidebar's trailing edge, then Find in Chat and Actions
alone at the window's — the title, and one key monitor for ⌘V, ⌘B, ⌃⇥ / ⌃⇧⇥, ⌘F, ⌘G / ⇧⌘G, ⌘K
and the Actions menu's own chords, and dies with the window.

- **Find in Chat** (⌘F): the system's `NSSearchToolbarItem`, as is. `ChatFindState` is one per
  window and steps match by match, not message by message:
  `ChatFindIndex` walks each message exactly as the transcript draws it — reasoning folds, every
  paragraph, list item, code block and table cell, in order — and lists every occurrence as
  (message, drawn text, index within it). A reply's hidden choices fence never matches; a plan's
  Markdown does, and a replaced plan holding a match unfolds, while a question card is not
  searched. A drawn
  text is named by its position path (segment, block, item or cell), not its content, so two
  identical table cells are two matches. An equation draws as one character, so find never matches
  inside its source. `ChatTextHighlight` rides the environment into every text
  a message draws, which marks all its matches in the Mac's find yellow and the current one solid;
  a clear marker over the current match takes the scroll anchor, so the transcript centres on the
  word itself.
- **A reply's text is one selectable text view.** SwiftUI's `Text` selects within itself only, so
  a reply drawn paragraph by paragraph could be dragged across one paragraph at most.
  `ChatMarkdownText` draws each text segment into one read-only `NSTextView`, and
  `ChatMarkdownRenderer` builds its single attributed string: lists with hanging indents, quotes,
  code as `NSTextBlock`s, tables as an `NSTextTable`, with find's marks and the citation numbers
  in it. Its leaf paths are `ChatFindIndex.leaves`'s, which `chat-markdown-test` pins. A code
  block's language and Copy sit in a strip its block leaves above the code. Thinking folds, search
  and tool rows stay separate views, so a drag spans one segment's text. A fold holding a match
  opens. A glass counter at the transcript's top edge says "3 of 17" with the same steps as
  Return / ⇧↩ in the field and ⌘G / ⇧⌘G anywhere. The sidebar's own filter is still there, by click.
- **Math is typeset natively, in that same text.** `\(…\)` and `$…$` are inline math, `\[…\]` and
  `$$…$$` display math. `MarkdownMath` finds them before Foundation's Markdown parse, which would
  eat their backslashes. A `$` pairs only by Pandoc's rule — hugging its content, no digit after the
  closer — so "$5 and $10" stays prose, and code spans and `\$` are never math. `MathNode` parses a
  bounded LaTeX subset: at a command it does not know, past 40 levels of nesting or past 4,000
  characters, a formula shows as its source (a display one as a `latex` code block) rather than as a
  guess. `MathLayoutEngine` sets it by TeX's rules in STIX Two Math, which macOS ships, reading sizes,
  gaps and stretchy glyphs from the font's OpenType MATH table, so no dependency is involved. Each
  formula is one `MathAttachmentCell` character carrying its source: selection, citations and find
  keep their offsets, copying or dragging gives back the LaTeX as written
  (`ChatSelectableTextView.writeSelection`), and a formula wider than its line scales down to fit.
  While a reply streams, `MarkdownBlock.parse(_:midStream:)` holds back an equation still open at
  the very end — a display one as a centred, muted `…`, an inline one withheld — so it neither
  flashes as source nor jumps from the left to the centre. Only the last segment of a streaming reply
  is mid-stream, an opener the stream has passed stays visible, and a lone `$` is never held back,
  since it may be a price.
- **Actions** (⌘K): Quick AI's ⌘K menu for a window, on the same chords — Stop Response (`⌘.`), New
  Chat (`⌘N`), Regenerate (`⌘R`), Copy Last Response (`⇧⌘C`), Remove Attachments, Find in Chat
  (`⌘F`) and AI Settings (`⌥⌘,`) — plus what only a saved chat has: Copy Chat, Pin, Archive (not
  for a pinned chat, nor while it answers) and Delete. Its middle group holds the chat options the
  composer leaves out: **Reasoning** (a submenu of the model's efforts, shown only when it has
  some), **Tools** ([Agent](agent.md#the-session-scope-and-the-composer)) — each with its current
  value as the row's badge — and a **Web Search** switch when the route searches and the agent's
  Web Search row is Allow.
  `AIChatActionsMenu` builds it per open from the chat's state, as an `NSMenu` hung under the
  toolbar button whether the click or ⌘K opened it.
- **Escape closes the window** (`closesOnEscape`), the composer focused or not. An open menu, Find
  in Chat or a rename takes Escape first, and the sidebar clears a non-empty filter before the next
  Escape closes. Closing keeps the draft and leaves a reply streaming.

- **Sidebar** (`AIChatSidebarView`): a filter field over a `List` of every saved chat not archived, Pinned
  first and then bucketed by day like Clipboard. The open chat is the selected row; ⌃⇥ / ⌃⇧⇥ open
  the next or previous one, wrapping, over every saved chat whatever the filter shows, in the same
  `pinnedFirst` order the sections are built from. ⌘B shows or hides the sidebar. A new chat has
  none until its first message saves it, so starting one or leaving an empty one never adds or
  drops a row under the pointer. A row shows the agent's waiting badge while its turn waits on the
  reader — a raised hand for an approval, a question bubble for a question
  ([Agent](agent.md#the-badge-and-the-dot)) — else a spinner while its reply streams, else a pin
  when pinned. Its content fills the whole cell, so hover — a fainter fill in the selection's own
  shape — never blinks off crossing between rows.
  The context menu pins, archives — offered for an unpinned chat, disabled while it answers —
  renames in place, copies or exports the chat as Markdown
  (`ChatSession.markdownTranscript`: each turn's text and its plans under "**Plan: title**", never
  its questions and answers), and deletes one or all through `DialogController`; ⌫ deletes
  the selected chat the same way. Delete All's confirmation says archived chats are kept.
  While anything is archived, an **Archived** row with the count sits under the list.
- **Archive**: archiving the window's chat (`AIChatCoordinator.archiveChat`, through
  `AIChatSurfacesState.archive`) starts a new chat in its place, as deleting it does, and archiving
  Quick AI's empties Quick AI; nothing else changes. The **Archived** row swaps the list for
  `AIChatArchiveList`: a back chevron and the title over the same search field, which now searches
  archived chats (`searchArchived`, title and last message as the history's search does), then
  their rows, newest first, each with the day it was last active. Choosing a row opens it — it is
  unarchived first and appears in its day as any chat — and the sidebar goes back to the list. The
  context menu opens, unarchives or deletes it through the usual confirmation. Escape clears the
  field, then goes back, then closes the window. Quick AI's Chat History lists no archived chats.
- **Transcript**: `ChatTranscriptView` with `surface: .window`, which drops the palette's edge
  dissolve and thin scrollbar (both are measured against the palette's bars) and centres the column
  at `aiChatReadingWidth`. The last finished reply offers Regenerate beside Copy: `AIChatState`
  drops only a trailing reply and asks again with the question and its attachments, of whichever
  model is selected now.
- **Composer** (`AIChatDetailView`): one pane of untinted Liquid Glass, stacked under the transcript
  rather than floated over it, with glass capsules for its menus, the glass on a background layer.
  The title bar keeps the system's own band, as a native document window's does.
  Transcript text runs `spacing.chatLine` apart, both surfaces. `ChatComposerTextView` is an `NSTextView`, not a `TextEditor`: its delegate sees
  `insertNewline:` only outside input-method composition, so Return sends and ⇧↩ or ⌥↩ breaks the
  line without Return ever stealing an IME's confirm. It grows with its text to
  `aiChatComposerMaxHeight`, then scrolls. Under it: the paperclip (an `NSOpenPanel`), the model
  menu, the mode pill ([Agent](agent.md#the-session-scope-and-the-composer)), a context gauge,
  and Send/Stop; reasoning, tools and web search live in the ⌘K menu. While a
  question waits, Send is Answer, the placeholder reads "Answer the question…", and Stop gets a
  button of its own beside it.
  One paperclip takes every kind; its help names what this chat's model can read. The gauge is the
  last reply's `contextTokens` against the model's window when the route reported one, and
  `ChatSession.historyBytes` against Blitz's history budget otherwise — orange from 80%, red at
  100%. Hovering it raises Blitz's own card (never a popover), drawn inside the transcript's
  frame at its bottom edge — just above the composer and inside the window whatever its size — and
  solid under its glass so the transcript cannot show through. `ChatContextReport`
  lays it out: tokens in context of the window, input with its cached share, output with its
  thinking share and cost; then what the next message sends — model, history of budget, messages
  sent of total, staged files, and whether the system prompt and web search ride along; then **Tools**: the chat's **Mode** where the route offers modes, and a row per tool the next turn is offered, with what a call to it would get — Allow or Ask. The model menu and ⌘K's Reasoning are this chat's, as Quick AI's header is Quick AI's. Files arrive by ⌘V, a drop anywhere on the pane, or the paperclip, and all three take
  the refusals a paste does. The unsent text lives on `AIChatState.draft`, so it survives closing
  the window.

`AIChatState` turns provider-neutral stream events into one live assistant message. Thinking state is
shown without entering the transcript, partial text is preserved on failure, cancellation invalidates
the active generation, and only completed assistant messages become context for the next request —
as `ChatMessage.contextText`, the reply's text with each answered question and each plan set in
where it happened.
Assistant replies render Markdown and LaTeX math; user messages remain literal. A reply keeps streaming while the
palette is hidden, the window is closed or showing another chat — the state is `AppCore`'s, not the
view's — and is saved when it finishes.

Tool activity persists in `message_tools` beside `message_searches`, and `ChatMessage.segments`
interleaves the two by text offset so a reply renders what it did in the order it did it. Offsets tie
whenever no text arrived between two of them, so each search and call also takes a `sequence` — its
place among the reply's searches, calls, questions and plans (`nextSequence`) — as it is created,
and that breaks the tie. Both tables
store it as their `position`, so no column was added; a chat saved earlier holds each table's own
index there, so its ties go by that index and then to the search. Consecutive tool calls render as
one run: the latest running call while live, then an expandable count with any failures once done.
Text and searches separate runs; a single call keeps its own row. A call loaded still marked running
belonged to a process that is gone, so it reads back as failed — the same repair a message left
streaming gets.

`ChatHistoryStore` writes `ai-chats.sqlite3` below the bundle-specific Application Support directory.
It uses the system SQLite already linked by Blitz, stores no provider credentials, and repairs a
reply left streaming by a prior process into an interrupted failure when loaded. The agent's
memories are not in it: they outlive every chat — Delete All Chats, retention and deleting the
chat a memory came from all leave it — so `AgentMemoryStore` keeps them in `agent-memory.json`
beside it ([Agent](agent.md#memory)).

## Questions and plans

`ask_user` (`AskUserToolCatalog`) and `write_plan` (`PlanToolCatalog`) are Blitz's tools with no
rule row ([Agent](agent.md#modes)). `AIChatCoordinator` runs both itself, on the loop and through
`ClaudeHostedServer` alike, and neither passes the gate. Each is pinned in the reply where it
happened, like a search or a call — `ChatMessage.questions` as `ChatSegment.question`,
`ChatMessage.plans` as `ChatSegment.plan` — and stored with its message in `message_questions` and
`message_plans`, `CREATE TABLE IF NOT EXISTS` with `ON DELETE CASCADE` like the rest.

### Questions

- **The call** is `question`, 2–6 distinct `options` of under 80 characters each, and
  `multiSelect`, false unless set. A malformed one is a failure result the model can correct, never
  a card.
- **The turn waits.** `AIChatState.ask` pins a `ChatQuestion` to the streaming reply and suspends
  the call on it. `ChatQuestionCard` draws the question and its options as `ChatChoiceChip`s: a
  single-choice chip answers at once; a multi-select one toggles, and the card's Send answers with
  what is picked. Text typed while a question waits answers it too, with any picked chips:
  `AIChatCoordinator.send` hands it to the question instead of starting a turn. Answered, the card
  is a record of the chosen options and typed text, or "Not answered".
- **The answer is the result**: "The user chose: …", "The user answered: …", "The user added: …"
  after chips, or "The user did not answer."
- **One question at a time.** A second `ask_user` while one waits is refused with
  `AskUserToolCatalog.oneAtATime` and draws no card; one asked after its turn ended draws nothing
  and answers that nobody did.
- **Every path resolves the wait exactly once.** An answer, Stop, deleting the chat, turning AI
  off, the turn ending any other way or its task being cancelled all go through one resolve, and a
  later answer finds nothing to resume. Stop answers "did not answer" and the turn ends as Stop
  ends it. Leaving the chat does not end it: the parked chat keeps its question waiting, picked
  chips and all, and reopening it shows the same card live. A question stored unanswered belonged
  to a process that is gone, and reads back as not answered.
- **Later turns read the exchange** where it was asked, through `contextText`
  (`AskUserToolCatalog.record`: `ask_user:` and the question, then the answer). Copy Chat leaves
  questions out.

### Plans

- **The call** is `title`, under 120 characters, and `markdown`, under 32 KB
  (`PlanToolCatalog.markdownLimit`); a larger plan is refused with its size, so the model can
  shorten it. Outside Plan it is refused with `notOffered`, after its turn ended with `turnEnded`,
  and otherwise its result tells the model to stop rather than carry the plan out.
- **The live plan is the last one written.** `AIChatState.writePlan` pins a `ChatWrittenPlan`, and
  `ChatSession.livePlan` is the last any reply wrote. `ChatPlanCard` renders it as Markdown with
  **Edit**, **Execute** and **Execute in Auto**; each earlier one folds under its title, marked
  "Replaced", and stays the record it was.
- **Edit is the live plan's, and never mid-turn.** It opens a monospaced editor
  `Theme.Size.chatPlanEditor` tall. Save writes the plan where it was written —
  `ChatSession.editedLivePlan` works the edit out, `ChatHistoryStore.savePlan` stores it, an
  `UPDATE` of its row, since the save after a turn rewrites only the stored tail, and only then does
  `ChatSession.replacePlan` land it in the chat. While a reply streams every control on the card
  is disabled and `AIChatState.editPlan` refuses, because the turn may still replace the plan.
- **An edit that is not saved is not shown.** When the `UPDATE` fails or matches no row,
  `AIChatState.editPlan` answers `.unsaved` and leaves the plan as it was, so the card, Execute and
  a reopened chat all read the same text, and `AIChatCoordinator` reports "The plan edit could not
  be saved." through the message HUD. The editor has closed by then, so the edit is lost.
- **Execute carries out the plan as it reads now.** Execute sets Manual and Execute in Auto sets
  Auto, through `setMode`, then sends `AgentModeInstructions.execute` — "Carry out this plan:", the
  title and the current, possibly edited, Markdown — as the reader's next message. Only the window
  carries a plan out; in Quick AI a plan card is a record.
- **Plan's instruction rides every Plan turn.** `AgentModeInstructions.appending` puts
  `AgentModeInstructions.plan` after the preamble and the reader's prompt, or alone with the system
  prompt switched off, so the mode holds either way. It answers a plain question without a plan,
  and asks a plan to name its steps, what each one changes and how to check it worked.
- **A reply that only wrote a plan completes as it is**, without the "No response" fallback.
- **Later turns read each plan** where it was written (`PlanToolCatalog.record`: `write_plan:` and
  the title, then the Markdown as last saved). Copy Chat includes every plan.

## Palette integration

Two palette modes carry Quick AI, and neither changes the shell's rules:

| Mode | Screen | Body |
| --- | --- | --- |
| `.ai` | `AIScreen` | `ChatTranscriptView` (`surface: .palette`) |
| `.aiHistory` | `ChatHistoryScreen` | `ChatHistoryList` + preview, bucketed by day like Clipboard |

Chat History backs out to Quick AI; both are sub-screens, so the header shows the back chevron.
Quick AI's command is `command:quick-ai`; the window's is `command:ai-chat-window`. The search field
is the composer: Return submits, answers a waiting question, or stops a streaming response, and the
footer pill reads Send `↵` / Answer `↵` / Stop `↵` to match. The model switcher is a `HeaderMenuButton` — the
active label, glyph and disclosure chevron layered over `BarButton` — which is also what Clipboard's
type filter is, so the two header menus hover and open identically. Its menu is the palette's
fourth `OpenMenu` case, `.topTrailing` like the type filter, and it opens on the selected model. Each
row leads with the vendor's mark — `AIBrand` resolves it from a native connection's provider, or for
OpenRouter and OpenAI-compatible endpoints from the model id (`anthropic/claude-…`, `deepseek-chat`,
`o4-mini`). The marks are ~300 B–2 KB monochrome template SVGs in `Assets.xcassets` (`AIBrand*`),
thirteen from Simple Icons, Grok and Z.ai from `@lobehub/icons` and OpenCode drawn after its own, so
they tint with the row like a symbol. OpenCode's inner block is the one second tone among them, and
is drawn with `opacity`: the asset compiler drops `fill-opacity` without a warning. An
unrecognised model keeps the generic sparkle. Provenance, the MIT notice and the trademark position
are recorded in [`NOTICE.md`](../../NOTICE.md) — the CC0 on the Simple Icons project does not extend
to the brands it depicts. The header's model switcher shows the selected model's mark the same way.

The palette's click-away lives in `PalettePanel.sendEvent`, not in a SwiftUI overlay. An overlay
inserted on open and removed on close stranded SwiftUI's hover target on the header button
underneath — AppKit kept delivering clicks, but neither the button nor the overlay saw them until an
unrelated render recomputed hover — and one left mounted let part of the dismissing click replay into
the rows. Consuming the whole press at the window avoids both; see
[palette.md](palette.md#one-menu-at-a-time).

Eight more `@MainActor @Observable` types join the shared state: `AISettingsStore`,
`CodexSubscriptionManager`, `InstalledAIManager`, `ChatHistoryStore`, `AgentMemoryStore`,
`AIChatSurfacesState` (which owns every live `AIChatState`), `MCPSettingsStore` and
`MCPServerManager`. `AIChatCoordinator` — the window, and every chat action either surface sends —
is the nineteenth feature coordinator, `MCPCoordinator` the twentieth, `QuickAICoordinator` the
twenty-first and `AgentMemoryCoordinator` ([Agent](agent.md#memory)) the twenty-second.

### Manual sweep

- The selected model appears at the right of the composer and truncates without crowding typed text.
- An `@server` chip — the tools glyph alone, since the handle is still in the text — or a staged
  pill follows the typed text with a clear gap, and a long draft stops it right before the model
  name, the same gap with a reasoning menu and without.
- Clicking it or pressing ⌘P opens the same anchored menu shape as Clipboard's type filter;
  arrows, Return and Escape operate the menu without changing the draft.
- Pressing ⌘P again closes the model menu and returns focus to the composer.
- Repeatedly clicking either the model switcher or the type filter opens and closes every time, even
  when the next click lands immediately after dismissal or a few points off the first one.
- Selecting a model updates the button immediately and the next message reaches that route.
- Switching while a response streams does not stop or reroute that response; the new model applies to
  the following message.
- With no available model, the menu offers Configure AI and opens Settings › AI › Providers.
- With Apple Intelligence available and nothing else configured, opening chat or the AI pane leaves
  the selection reading **Apple Intelligence** without asking for anything.
- With it switched off in System Settings, the pane says so and chat says so; neither moves the
  reader onto a configured API connection.
- Install and sign in to each supported command outside Blitz, choose one of its discovered models,
  and confirm Chat and each model-backed Quick Action use it without showing a credential field.
- Sign out of an installed command, press Check Again, and confirm its models leave both pickers while
  the stored selection is repaired according to the normal routing rule.
- On Codex and on the Claude command, with an MCP server enabled, a question answered with a tool
  shows the same rows the API routes show and the reply continues after them; with MCP off, both
  routes stream exactly as they did before.
- With `Quick AI opens to: Recent Conversation` and a five-minute window, Escape out and summon again inside
  five minutes resumes the transcript; past it, the composer is empty. Quitting and relaunching still
  reopens the last conversation. `A New Conversation` is always empty.
- Setting `Keep conversations` to 7 days drops older unpinned chats from the window's sidebar and
  shrinks `ai-chats.sqlite3`; a pinned one stays. Switching AI off, waiting past a boundary and switching back on prunes nothing
  that was saved before it went off.
- Ask in Quick AI, press ⌘J while it streams: the window opens on that chat, still streaming, with
  the unsent line in its composer, and Quick AI is empty on the next summon.
- In the window, send, then press ⌘N before the reply ends: the old chat keeps its sidebar spinner,
  finishes, and reopens complete. Rename one, send another turn in it, and the name holds.
- Ask for the quadratic formula in LaTeX: while the reply streams, its display equation is a centred
  `…` that turns into the equation in place; selecting across it and copying pastes its `$$…$$`
  source. A reply that mentions "$5 and $10" keeps both prices as prose, and in a narrow Quick AI a
  long equation shrinks to fit rather than running off the edge.
- Return sends, ⇧↩ breaks the line, and a Japanese IME's Return confirms its text without sending.
- Ask a question the model must clarify, on an API connection and on the Claude command: the card
  shows its chips, Send reads Answer with Stop beside it, and a chip or a typed answer continues the
  same reply. Stop instead ends the turn with the card reading "Not answered". In Quick AI the pill
  reads Answer.
- In Plan, ask for a plan: it arrives as a card; a second one folds the first as "Replaced". Edit
  and Save, reopen the chat, and the edit holds; Execute in Auto switches the pill to Auto and sends
  the edited text.
- Drop a PDF on the pane with a text-only model selected: the HUD refuses it, as a paste would.
- ⌃⇥ steps down the sidebar and wraps from the last chat to the first pinned one; ⌃⇧⇥ goes back.
- Archive a chat from the sidebar's context menu: it leaves the list, an Archived row with a count
  appears at the bottom, and ⌃⇥ and Quick AI's Chat History skip it. Archive the open chat from ⌘K:
  the window starts a new chat. A pinned chat offers no Archive, and one still answering shows it
  disabled. In Archived, search finds the chat; choosing it opens it back in the sidebar; Unarchive
  and Delete work from its context menu, and Escape goes back. Delete All Chats keeps archived
  chats, and `Keep conversations` still prunes an old one.
- Collapse the sidebar with the toolbar button or ⌘B; ⌘N and ⌘Q (Close Window) still work, and ⌘Q
  with Settings in front closes Settings instead.
- Press the AI Agent shortcut twice: the window opens, then closes; with it open behind another app,
  the shortcut brings it forward. Summon the palette over the open window and run AI Agent: it stays
  open.
- Escape with the composer focused closes AI Agent; reopening shows the draft, and a reply that was
  streaming has kept going. With a sidebar filter typed, the first Escape clears it, the second
  closes; a rename field and Find in Chat each cancel before a further Escape closes.
- Harnesses: `ai-provider-test` (endpoints, request bodies, stream decoding including leading
  think tags across content and SSE splits, persistence repair,
  Codex framing, on-device routing, the two MCP launch encodings and the two consent channels, the
  shown-model and switched-off-route rules, a tool's override from settings to launch, and the
  agent table's storage and one-off migration),
  `agent-policy-test` (the agent's rules, dialogs and refusals — see [Agent](agent.md#harnesses)),
  `ai-chat-test` (`ChatSession`, `MarkdownBlock` with its math delimiters, LaTeX subset and
  mid-stream hold-back, `ChatHistoryStore` with renames, pins and the archive — kept out of the
  lists and their search, found by the archive's, never for a pinned chat, surviving a reopen, left
  by a new turn, spared by Delete All, still pruned by retention and cascading with a delete —
  archiving refused while a reply arrives and making a surface start over,
  `AIToolLoopProvider`, regenerate, the sidebar order ⌃⇥ steps through, the agent scope each chat
  starts open and in Manual, `AIChatSurfacesState`'s one-live-place rule, questions — answers from
  chips and text, their place and their context, the paused turn, Stop, leaving and deleting each
  resolving once, one at a time — plans — their place and context, storage, replacement,
  editing, an edit that waits out the turn and one the store cannot save — and Ask requests held
  off screen, with the wait each chat reports),
  `agent-wait-test` (the waiting state, held requests, on screen and the notification — see
  [Agent](agent.md#harnesses)),
  `codex-turn-test` (the Stop path, driven against a stub app-server stalled where Stop races the
  turn ID, plus the MCP launch boundary, one launch for concurrent starts, the elicitation, the
  rows, the call cap, a custom provider's access without an account, and when a chat's thread is
  resumed and when it starts afresh),
  `installed-ai-test` (Claude/Grok/OpenCode/Cursor flags, prompt
  framing, streaming and cleanup, and Claude's private MCP configuration with the hosted server's
  timeout, control channel, round cap and managed-policy branch, an `ask_user` call drawing no row,
  the boundary a Plan turn is told,
  a reader's variables against Blitz's own, and a set command
  path that runs or fails) and `apple-intelligence-test` (status copy, snapshot deltas,
  transcript assembly, error mapping, plus one real generation when this Mac can run one), all in
  `run-tests.sh`.

## Installed commands

`ExecutableLocator` finds `codex`, `claude`, `grok`, `opencode` and `agent` by asking the account's
login shell, so a stale copy in another prefix never shadows the one Terminal runs. zsh, bash and fish
are asked in their own syntax, any other shell through zsh, and the answer comes back behind a marker,
so an rc or logout file that prints cannot hide it. Only when the shell names no absolute executable does
it fall back to the app's PATH, the normal Homebrew and local-bin locations, mise's and asdf's shims and
every nvm Node version, newest first — a fallback that can pick a different copy. What a
found command runs under is `ExecutableLocator.environment`: its own folder, `/opt/homebrew/bin` and
`/usr/local/bin` ahead of the inherited PATH, for every probe, turn, Codex `mcp list` read and local MCP
server — a Finder-launched app's PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, and an npm or Homebrew CLI is
`#!/usr/bin/env node`, which would find no `node` on it.

A reader can replace the lookup and add to that environment, per tool, on the tool's Advanced page.
The path is used as written, a leading `~` expanded, and never searched for. The variables lie over
the app's own before `ExecutableLocator.environment` builds the PATH, so a reader's `PATH` is the one
the tool's folder is put ahead of. Both reach every spawn: the probes, a CLI turn and the session it
deletes afterwards, Claude's title request, and Codex's app-server and its `mcp list` read.
`InstalledAIManager` and `CodexAppServerClient` ask for them at each launch through `launchSettings`,
so an edit takes the next one, and `AISettingsStore.launchRevisions` lets `AppCore` check again only
the tool that was edited — Codex by stopping its server, which restarts on demand. The
commands are never installed by Blitz; Settings links to their own install docs and offers a sign-in
command to copy. `InstalledAIManager` probes Claude, Grok, OpenCode and Cursor off-main, in parallel.
Claude's auth status gates an `initialize` control request, and `InstalledAIModel.claudeCatalog` builds
its model list from the answer. OpenCode's successful model list is both its auth check and catalog.
Grok's `models` output is the catalog, but a signed-out CLI still exits 0 and prints that catalog under
"You are not authenticated." — that banner is the auth check, not the exit status. Cursor's
`status --format json` gates `--list-models`.

`CodexSubscriptionManager` owns the installed Codex app-server lifecycle and discovered account
metadata. Production never sets `CODEX_HOME`, so the
server uses the same login and credential store as the user's normal Codex command. Blitz supplies
only a private working directory. The server stops after ten idle minutes, when AI is switched off or
when the app terminates, and restarts on demand. Account state, model availability and rate-limit
windows come from the supported app-server protocol. A custom Codex provider can report no account
and `requiresOpenaiAuth: false`; Blitz then loads its models and runs turns without inventing an
account or asking for `codex login`. A missing or true flag still requires sign-in. A running server
rereads `config.toml` at every `account/read`, but Blitz keeps what a check found, account or
provider, beside the models and rate limits it read with it, until the next check; a turn that finds
nothing to run on leaves Codex signed out and stops the server, as a check does.

MCP is the one thing about that server that is fixed at `exec`: its overrides and its environment
both are, so `CodexAppServerClient` remembers the list it was launched with and relaunches when the
next turn wants a different one — a server added or removed, or an OAuth token refreshed. A check
is not a turn and keeps whatever is already running. The account survives the relaunch because it
was never the process's to begin with. See [MCP](mcp.md) for what goes on the launch line.

`CodexTurnRunner` is the generation half behind `CodexInstalledProvider`.

A chat's request carries its `conversationID`, and the runner keeps that chat's ephemeral thread
after a reply completes, because the thread holds what the transcript does not: the pages a web
search read. The next request resumes it only when its history equals what the thread has seen and
the model, the developer instructions and web search are unchanged, and only on the process that
holds it, since a relaunched or crashed helper has forgotten it. Anything else starts a fresh
thread and injects the supplied user/assistant history: a regenerated, failed or stopped reply, a
transcript trimmed to the context budget, a changed model or setting, or a turn with an
attachment, which is never kept. Titles and Quick Actions carry no ID and always start fresh. Deleting a chat drops its
thread, and a reset, a relaunch or the idle shutdown drops them all; nothing of it is persisted.

The runner streams agent-message deltas, plus `item/started` for the reasoning and web-search items
that feed the bubble's status line. System messages become developer instructions alongside Blitz's
fixed boundary, which permits only web search when it is on and the MCP tools an armed turn
supplies, and tells a follow-up to search again rather than ask the reader for a link.
Cancellation interrupts the active turn, including one the server has started but
not yet named: Stop arms that thread, and whichever of `turn/started` or the `turn/start` response
names the turn first spends a single `turn/interrupt` on it.

Web search is thread-scoped config (`thread/start.config.web_search`, `live` or `disabled`) and
reasoning effort belongs to `turn/start`; neither is written to the user's Codex configuration. The
developer instructions say whether the model may reach the web so the two cannot disagree. Images go
out as `image` input parts with data URLs, and as `input_image` when prior turns are injected.

`InstalledCLITurnRunner` handles Claude, Grok, OpenCode and Cursor behind the same provider protocol. It
frames Blitz's instructions and bounded conversation history as stdin (or a private `--prompt-file` for
Grok, whose CLI requires a path), consumes newline-delimited JSON, and never puts prompt text on the
process command line. Claude uses stream JSON, `--effort` and no session persistence, and takes every
turn as one framed `stream-json` user line. With servers armed it keeps stdin open for the consent
channel and closes it on the CLI's own result frame; writes are chained rather than concurrent,
because two racing the same pipe would interleave a line.
Grok uses `streaming-messages-json` and `--effort`, with `--deny *` so tools cannot run even when the
user's Grok config is always-approve; it captures the session id, then calls `grok sessions delete`.
An error result omits `result` and carries the cause in `errors`; that text is the failure, not
Claude's missing-`result` fallback.
OpenCode runs pure with an inline deny-all configuration and passes the selected
model variant through `--variant`; it captures the returned session identifier, then calls
`opencode session delete` after the process exits. Cursor runs ask mode with `--trust`,
`stream-json` and `--stream-partial-output`, never `--force` / `--yolo` / `--approve-mcps`, then removes
the local chat under `~/.cursor/chats/<workspace>/<session_id>` because the CLI has no delete-chat.
A turn finishes on its own completion frame; both cleanups run detached after the child exits, so
housekeeping never holds the composer shut.
Cancellation terminates the child process; only one installed-CLI turn can own a runner at a time.

## Web search and attachments

`AIRequest.webSearch`, `AIMessage.images` and `AIMessage.documents` are provider-neutral; each
route maps them itself:

A text-ish file is deliberately absent from this table: it is inlined as text before any transport
sees the turn, so every route — the on-device model and all installed CLI transports included — takes one with no
transport code at all.

| Route | Web search | Images | PDFs | MCP tools |
| --- | --- | --- | --- | --- |
| Apple Intelligence | never — it reaches nothing | never — the model is text-only | never | never |
| Codex | thread-scoped `web_search` config | `image` input part | never — the app-server takes no document part | Blitz's servers, added as launch overrides; the reader's own are disabled by name |
| Claude command | its built-in `WebSearch`, alone: `--tools WebSearch` plus an allow rule | base64 `image` block in its stream-json user message | never | Blitz's servers, through `--strict-mcp-config` and a private config file — an empty one when there are none, and neither flag under a managed MCP policy |
| Grok command | never | never | never | the global config still loads — `--deny *` refuses the call |
| OpenCode command | never | never | never | the global config still loads — `permission: deny` refuses the call |
| Cursor command | never | never | never | the global config still loads — ask mode and withheld approval refuse the call |
| OpenRouter | `plugins: [{id: "web"}]` — OpenRouter's own layer, any model | `image_url` part, only for models whose catalog lists the `image` modality | never yet — its catalog publishes a `file` modality Blitz does not read | `tools` + `role: "tool"` turns |
| OpenAI | not offered | `image_url` part, assumed supported | `file` part with `filename` and a `file_data` data URL | `tools` + `role: "tool"` turns |
| Gemini / compatible | not offered | `image_url` part, assumed supported | never — a gateway that has not implemented the part bills the upload before rejecting it | `tools` + `role: "tool"` turns |
| Anthropic | the server `web_search` tool, `max_uses` 5 — `web_search_20260209` from Opus and Sonnet 4.6 on, `web_search_20250305` otherwise | base64 `image` block | base64 `document` block, ahead of the text block | `tools` + `tool_use` / `tool_result` blocks |

A search is part of the reply, not a status: `item/started` for a `webSearch` item appends a
`ChatSearch` to the streaming message pinned at the text length so far, `item/completed` (or the
next text delta, or the turn ending) marks it finished and fills in the query if the start didn't
carry it. `ChatMessage.segments` splits the text around its searches so the transcript renders
text, a search row (spinner → globe, "Searching web" → "Searched web · query"), then the rest, in
the order it happened. Searches persist in `message_searches`. OpenRouter's web plugin is invisible
to the stream, so it shows none. Anthropic's arrives as a `server_tool_use` block, kept apart
from the tool loop's calls, and its `web_search_tool_result` completes the row; the Claude command's
is a `WebSearch` `tool_use` and its `tool_result`, never a tool row. A paused server loop
(`pause_turn`) ends the reply where it stopped: Blitz keeps no server blocks to resume it with.
Anthropic's own citation blocks are ignored, since sources come from the reply's links. The web-search instructions ask for citations linked by the
publication's name — the model otherwise labels them "Read more".

`AIModelCapabilities` says what the footer may offer for the selected model. OpenRouter is the only
catalog that reports `architecture.input_modalities`, so it is the only provider gated on it:
Settings records a model into `AIConnection.visionModels` when it is added from that catalog, and a
model added by hand is assumed text-only. A vendor API is assumed to take images; a model that
doesn't simply returns the provider's error.

Web search is the ⌘K menu's Web Search switch, `aiWebSearch`, off by default: a prompt reaches a
search engine only once the user has opted in. The switch is offered only while the agent's Web Search row is
Allow ([Agent](agent.md#the-rule-table)), which has no Ask because the provider runs the search.
It's still excluded from backups — which Mac may send prompts to a search engine is that Mac's call.
Nothing *guesses* at a capability: images ride on what the model's own catalog said, and a vendor
API that does not take one simply returns its error. What is gated is only what a route provably
cannot carry — a PDF to a text transport — refused at the composer with a HUD naming the reason.
`AIModelCapabilities.documents` is true only for the two HTTP shapes whose bodies Blitz writes;
a gateway that has not implemented the `file` part would bill the upload before rejecting it, which
is why documents are *not* assumed the way images are. An attachment is never dropped on the way
out: answering a question about a document the model never received is the one outcome this must
not produce.

In Quick AI attachments arrive by ⌘V; the window also takes a drop and the paperclip. They come in
three kinds: an **image**, a **PDF** sent as a native document block,
and a **text-ish file** whose contents are inlined as fenced, named text.
`PaletteWindowController`'s command-shortcut hook gives chat the chord first; a pasteboard holding
file URLs or a bare image (a screenshot) stages them, while anything else carrying text falls
through to the field editor as a normal paste. **Only `isFileURL` URLs are read** — without that
filter a copied `https://…/a.png` reaches `Data(contentsOf:)`, turning a keystroke into a network
request. Every file is **sized before it is read**, so a huge CSV can never be slurped into memory.

**A text file is inlined by `ChatSession.boundedContext`, never into `ChatMessage.text`.** That seam
is load-bearing: `ChatSession.title` summarises the first user message, so folding a CSV into the
stored text would make the dump the conversation's title in the AI Agent window's sidebar, its
preview, and what the user bubble renders back. Inlining after the transcript and before the
transport also means only the newest turn carries it, so a chat's payload cannot grow turn on turn.
The block names the file and fences it with a run longer than any inside it, so a Markdown file
holding its own fence cannot escape; a staged name is stripped of newlines and capped, so a file
called `a\nAttached file: passwd` cannot forge a second header. Undecodable bytes are refused rather
than guessed at, and a file past `AIAttachmentBudget.maxInlinedTextBytes` is refused rather than
truncated — a silently truncated CSV is a lie the model then answers confidently.

`AIAttachmentPolicy` is the one place deciding what may be attached and as what. It is pure and
Foundation-only, so `ai-chat-test` pins it. It uses **extension allowlists rather than
`UTType.conforms(to:)`**: a machine's installed apps declare types, so a conformance answer differs
between two Macs and would make a harness machine-dependent — the exact environment coupling
`Model/` exists to keep out. Adding a type is a one-line change; a type answer that differs per Mac
is a bug you cannot reproduce.
Images are re-encoded to PNG and bounded to 1568px on the long edge, off-main on a detached task so
a display-sized screenshot does not decode on the keystroke; one past `AIAttachmentBudget` is refused
with a HUD instead of being staged. Because that decode outlives the keystroke, it shares the staged
images' lifetime exactly: whatever consumes or clears them — a send, a new chat, Remove Attachments,
or leaving the conversation for another in the window — disowns one still in flight and says so,
rather than letting it surface on a later message. The counter that decides this sits on
`AIChatState` beside the staged images, so a route that drops them cannot forget to move it.
**Staged attachments share one pill beside the typed text**: the newest one's kind as a glyph — a
photo, a PDF, a text file — and `+N` for the rest, because the strip's width is taken out of the
search field and a named pill per file left too little room to read what you are typing. The names
are a hover away, one per line, and clicking the pill opens a header menu listing every file, an
image by its own thumbnail, with its ✕, so a mispaste is taken back without clearing the rest — ⌘K → Remove Attachments
and bare backspace stay as the bulk and last-one routes. A row runs by its index, so the open menu
is re-laid whenever the staged list changes and closes once it empties; left stale, a file decoded
under it would shift the rows, and clicking Remove All would take back only that file. The menu's
thumbnail is the ~1 KB PNG downsampled on the same detached task that encodes the attachment and
carried on the staged attachment itself, decoded once per row, so there is no cache whose lifetime
could drift from the staging counter's. The strip states its own width — `AttachmentsPill.width(for:)`, the `@`
chip's, and every gap it lays out, the one between the two chips included — which
`RootPaletteView.searchFieldWidth(for:)` subtracts from the search field, so they must move together
or the caret drifts. Pills ride the same `headerAccessory` the launcher's argument fields use, so the field shrinks to
its text and the chip follows it rather than the composer growing. Nothing is reserved for the model
menu: the row itself squeezes a long draft, so the strip stops right before that menu however wide
its title is. Bare backspace on an empty composer removes the last
chip before it backs out of chat; ⌘K → Remove Attachments clears them all. Sent images persist in `message_images` and sent PDFs in `message_documents` beside their message;
the bubble renders images as thumbnails and documents as named chips.
A text file is already in the message's text and needs no table. The schema is
`CREATE TABLE IF NOT EXISTS` re-applied on every open, so the table needed no migration, and its
`ON DELETE CASCADE` leaves `prune` unchanged.

The switcher's glyph comes from the selection. Codex uses OpenAI's mark; Claude and Grok use their own
marks; OpenCode resolves a brand from the model id or falls back to a sparkle; Cursor uses an SF Symbol;
an API model resolves through its connection. It never depends on `modelOptions`, which for
Codex is empty until the app-server has answered `model/list`; opening the chat on a Codex model warms that list so the title is the
display name from the first frame. Tab hands Quick AI on to the clipboard, and Escape on an empty
composer takes its own back step — to whatever opened it, or out of the palette when its hotkey
did; either way the unsent draft is dropped rather than carried into a field that would search it.
History is pushed over Quick AI and pops back to it, and Tab carries its query to the launcher
because there the field really is a search. Neither exit touches the conversation: it lives on
`AIChatState`, so Tab away and back resumes the same transcript.

The model switcher is `fixedSize` with its title shortened in `AIChatCoordinator` (26 characters,
middle ellipsis) rather than truncated by layout: a flexible label claimed the row up to its max
width and clipped the search field well short of the button.

## Settings and backup boundary

AI has its own Settings sidebar group: **AI**, **Agent**, **Rules**, **Memory**, **Providers**,
**MCP Servers** and **Quick Actions**, each a normal grouped `Form` inside Blitz's existing Settings
window. The AI pane's top section owns
the feature switch and a **Providers** summary row that opens the Providers pane, and **Default
model** below it picks the app-wide route and its reasoning effort. A pick in Quick AI's header or
the AI Agent window's composer sets that chat's model and moves this default with it, while Quick
Actions keeps its own model selection. **Conversations** and **System prompt** follow it. The
agent's tool decisions, its shell and path rules and its memory are the Agent, Rules and Memory
panes ([Agent](agent.md#settings-and-storage)); MCP servers have their own pane, described in
[mcp.md](mcp.md#settings).

The Providers pane (`AIProvidersSettingsView`) is a paged pane: a list of every route — **On This
Mac**, **Installed**, **API Connections** — each a read-only row with its mark, a one-line state
(dimmed and reading Off when switched off) and a chevron, and each opening that route's own page
(`AIProviderPage`). The page string is the route's (`AIProviderRoute.page`): `apple-intelligence`,
`installed:<kind>` or `api:<uuid>`; a page whose connection is gone falls back to the list. **Add…**
under API Connections is a menu of the five connection presets; an installed tool cannot be
removed, only switched off, from the switch in its page header, where a connection also has
**Edit…** and **Remove…**. The page has tabs behind a segmented control (`AIProviderTab`), and the
chosen tab is kept from one provider to the next:

- **Overview** reports an installed tool as checking, ready, sign-in required, missing or failed,
  with the account, Codex's usage windows and the command that ran (`AIInstalledStatusRows`). It
  never contains a credential field: installation and sign-in happen in each command's own flow. For
  a connection it shows the provider, base URL and whether a key is stored; **Edit…** in the header
  opens the connection editor panel, which remains the explicit Keychain-backed path.
- **Models** is the checklist behind the second invariant above, with Show All, Hide All and a
  filter once a route offers more than eight. The rows are an `NSTableView` in one `Form` row
  (`AIModelChecklist`): a `Form` realizes every row it holds, and OpenCode offers over four hundred.
- **Advanced**, on an installed tool only, holds the command path and the variables, saved as each
  field is left. It stays while the tool is off, so a wrong path can be fixed before it is switched
  on. A name Blitz sets itself says its value is not used.

An API connection has the first two tabs, and the on-device model, with one, shows no control.

The signed-in Codex or Claude address is the one thing on the pane that names a person, and a Settings pane
is what gets screenshotted into a bug report or left on screen in a recording, so `RedactedText`
shows it scrambled and blurred until it is clicked. `RedactedPlaceholder` derives the stand-in from
the address itself — stable across redraws, same length, `@ . - _` left in place — because a blurred
real address can be recovered from a still frame while a blurred fake one cannot. It hides an
address from a camera, not a secret from an attacker: the length still shows and one click undoes
it. The scramble is not selectable, since dragging it out would only ever yield the stand-in.

The System prompt box appends to the preamble rather than replacing it, so the model never loses
the ground truth about where it is. `SystemPromptEditor` opens blurred and non-editable whenever it
already holds something — a Settings pane is exactly what ends up in a screenshot or a stream — and
opens plain when it is empty, since a blurred empty box is only a puzzle. The footer says the text
rides along on every turn, because it is billed on every turn and nothing else in the pane is.

`Send a system prompt` governs the whole instruction, not just the half the user typed. Clearing the
box already withholds their own text, so a switch that spared the preamble would add nothing; the
preamble is the part that is billed on every turn for every user and has no other way off. Off
disables the editor rather than hiding it, so what is being withheld stays readable. One thing it
deliberately cannot reach: every installed CLI route prepends its own instruction never to run
commands or touch files, and never to invoke a tool beyond the MCP tools an armed Codex or Claude
turn supplies — on a Claude Plan turn, only to look ([Agent](agent.md#routes)). That is a sandbox
boundary on a local CLI, not Blitz describing itself, and a user switch must not be able to lift it.
Nor does it reach Plan's instruction, which is the chat's mode speaking, not a prompt: a Plan turn
carries it with the switch off ([Plans](#plans)). The memory block is the same: Read Memory and
the chat's Use Memory are its switches ([Agent](agent.md#memory)).

`mcpEnabled` and `mcpServers` are excluded for the reasons in [mcp.md](mcp.md).
`aiConnections`, `aiDefaultModel`, `aiSmartReminderModel`, `aiSystemPrompt` and
`aiSystemPromptEnabled` are deliberately excluded from settings backups. The first is meaningless
without machine-local Keychain items; the two models name an external destination and must not
silently redirect AI traffic after an import; the last two are standing instructions and the switch that sends them, both of which change every
answer and must not arrive on another Mac unread. `aiRetention`, `aiOpensTo` and `aiNewChatAfter`
join them: all three are decisions about conversations that never leave the Mac that had them, and
an import must not arrive carrying an instruction to delete them. `aiToolRounds` stays behind too: it
limits what a tool-driven reply may spend, and an import must not raise that unasked.
`aiNotifyWhenWaiting`, Settings → AI → Agent → **Notify when the agent is waiting**
([Agent](agent.md#notifications)), stays behind with the rest of the AI setup, though as an
ordinary preference it has a `settings.json` key, `ai.notifyWhenWaiting`.
`aiAgentRules` decides which tools a model may call, from the calendar to the shell; a table that
grants capabilities travels in neither a backup nor `settings.json`, and the three keys it was
migrated from stay excluded beside it ([Agent](agent.md#settings-and-storage)). The agent's memories
are no preference at all: `agent-memory.json` is personal data every turn sends, so no backup
category and no `settings.json` key carries it ([Agent](agent.md#memory)).
`aiShownModels` and `aiDisabledRoutes` name this Mac's own tools, connections and their models, which
another Mac may not have. `aiInstalledOverrides` names a command to run and the variables to run it
with, and an import must never decide which program a Mac launches. None of the three has a
`settings.json` key, for the same reasons: they are machine state, and the last grants a capability.
