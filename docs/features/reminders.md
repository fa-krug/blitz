# Reminders

Three surfaces over the Mac's own Reminders: **My Reminders**, a palette screen listing every open
reminder to edit, complete or delete; **Create Reminder**, a prompt for a title, notes and a due date;
and **Smart Reminder**, which takes one sentence typed inline in root search — `Greg wants tomorrow
a cake` — and asks the AI model to turn it into `Give Greg a cake`, due tomorrow, written at once and previewed in a banner
whose **Open** shows it in Reminders.

## Invariants

- **`remindersEnabled` doubles as consent**, so it is in `SettingsBackupCoverage.deliberatelyExcluded`
  and only `RemindersCoordinator.setRemindersEnabled` may write it. Blitz's own dialog comes first,
  the macOS prompt second, and only from the gesture that asked. **It is written only after macOS
  grants**, exactly as `calendarEnabled` is — see [calendar.md](calendar.md). The Reminders pane and
  the Permissions pane both re-offer it whenever access is anything but granted.
- **Nothing polls.** `.EKEventStoreChanged` is the reload signal, held through the RAII
  `NotificationToken`, so a reminder ticked off on a phone leaves the list on its own. Opening My
  Reminders re-reads once, because access revoked in System Settings announces nothing. Sections are
  worked out from the clock as the list draws, never stored, so a list left open across midnight
  regroups without a fetch.
- **The fetch is the only thing off main.** `fetchReminders(matching:)` has no synchronous form, so
  its completion is built inside a `nonisolated` function — a closure formed on the main actor would
  carry a main-actor check into a block EventKit calls on its own queue, and trap. It flattens to
  `ReminderItem` there, and nothing EventKit-shaped leaves `RemindersStore`. A newer reload cancels
  the one in flight.
- **`ReminderAgenda` is the one place that orders and buckets.** The screen's `rows` and the drawn list
  both come from `grouping`, so the selection always indexes what is on screen. Buckets keep due order,
  and a day-only reminder leads its day: overdue means the time has passed for a timed reminder, and the
  whole day for a day-only one.
- **An edit writes only what changed.** Title and notes always go back; the due date — and the dated
  alarm that follows it — only when the draft's due differs from the reminder's, so fixing a typo never
  strips an alarm set in Reminders.app. Location and relative alarms are never touched.
- **Smart Reminder exists only while AI is on.** It runs on `AISettingsStore.smartReminderRoute`
  through `AppCore.smartReminderProvider`: the model chosen in the Reminders pane, or the AI default
  when none is, or when the chosen one's route is switched off. A connection, model or route that
  goes away drops the choice rather than rerouting it, and `aiSmartReminderModel` stays out of
  backups like `aiDefaultModel`. `RemindersCoordinator.applyCommands` takes it out of the launcher —
  its shortcut with it — when either switch is off. Turning AI off cancels a run in flight.
  The model is sent the typed sentence and today's date, never a reminder already on the Mac.
- **A model's reply is read, never trusted.** `SmartReminderPrompt.draft(from:)` takes the first `{`
  to the last `}` and decodes it field by field. No title is no reminder; a due date that is not a
  real day is dropped rather than guessed. A clean reply is written straight away — the reader typed
  the sentence and asked for it — and the banner shows what landed, its **Open** the way to fix a
  misread. Whatever fails, the sentence is not lost: `Write It Myself` opens the New Reminder prompt
  with it as the title.
- **Per-list switches live on `RemindersStore`, not `AppSettings`.** List identifiers are
  machine-specific, so they stay out of the backup, as the calendar's do. They store exclusions, so a
  list added later defaults to on.
- **A chat writes what it was asked, and edits rather than duplicates.** Read & Write is the consent:
  a create or update lands straight away and the transcript shows the call, while a completion is
  still confirmed first. An update changes the reminder in place by id, so moving a due date never
  leaves a second copy behind. See [Chat tools](#chat-tools).
- **`Model/` stays Foundation-only**; `reminders-test` compiles the shipped sources.

## The pure layer

- **`ReminderDue`** — the day, and a time only when one was set; EventKit's date components, flat.
  It titles itself `Today`, `Tomorrow`, `Friday` within the week, then `Oct 12`, adding the clock for
  a timed reminder.
- **`ReminderItem`** / **`ReminderList`** — one open reminder and one list, flattened out of EventKit.
- **`ReminderDraft`** — what a prompt collects, before anything touches Reminders.
- **`ReminderAgenda`** — the order, the five sections (`Overdue`, `Today`, `Tomorrow`, `Upcoming`,
  `No Due Date`) and the query match over title, notes and list name.
- **`SmartReminderPrompt`** — the instructions and the reading of the reply. Its dates are read by
  `AIToolDate`, the one spelling every Blitz tool uses.
- **`ReminderToolCatalog`** — the chat tools: their schemas, the reading of a call and the answers.

## Smart Reminder

The sentence is the row's one inline field in root search, `SmartReminderArgumentsAccessory`, drawn
with the same `InlineArgumentFields` a custom command's are (see
[palette.md](palette.md#inline-row-arguments)). There is no dialog: ↵ in the field hands the sentence
to `LauncherCoordinator.runCommand(_:arguments:)`, and run blank — from its shortcut, the My
Reminders menu, or ↵ on the row with nothing typed — `RemindersCoordinator.createSmartReminder` opens
root search on the row alone through `PaletteCoordinator.showArguments`, caret in the field. A miss
(Reminders or AI off) reports before the field opens, so nothing typed is lost to it.

The model cannot know the date, so the instructions carry it: now as weekday, day, clock and zone,
then the seven days ahead spelled the same way, so `next Friday` resolves by lookup rather than by
arithmetic a small on-device model gets wrong. One worked example uses the real tomorrow. The reply
is one JSON object — `title`, `due` as `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`, `notes` — and a time is
added only when the sentence names one, with `morning`, `noon`, `afternoon`, `evening` and `tonight`
pinned to fixed hours; a time with no day is today. **No day named is no due date**: the instructions forbid defaulting to today or
tomorrow, and a second example with `"due": null` shows it, since a small model copies its one
example's date otherwise.

The progress pill says the model is working and its ✕ cancels the run. Guardrails are
`.permissiveContentTransformations`: the sentence is the reader's own, which the default filter can
refuse. A timed due date gets a dated alarm, as Reminders.app adds one; a day-only one gets none, and
Reminders' own all-day notification time applies.

## My Reminders

`RemindersScreen` lists the store's snapshot through `ReminderAgenda`. The row's circle, in the list's
colour, completes the reminder on a click, through the same path as ⌘↵ and with the same banner.

| Key | Does |
| --- | --- |
| ↵ | Edit Reminder — the prompt, filled in. The palette stays up behind it, so the edit lands in view. |
| ⌘↵ | Complete Reminder — unconfirmed, so a banner offers **Undo**, which unchecks it again |
| ⌘O | Open in Reminders, through `x-apple-reminderkit://`, or the bare app with no handler |
| ⌘N | New Reminder — with no rows too, which the empty list's hint names |
| ⌘⌫ | Delete Reminder — always confirmed: it goes from every device the list syncs to |

A list Blitz cannot read says why and offers the way out, the same split Calendar makes: a denial
offers **Open Privacy Settings**, and `.notDetermined` — which System Settings cannot list — offers
**Allow Access**, rerunning `setRemindersEnabled(true)` with the palette hidden.

Reminders are not individual launcher entries, unlike meetings: My Reminders is one search away, and a
to-do list long enough to need search would crowd apps out of the root.

## Commands

| Command | Does | Bindable |
| --- | --- | --- |
| My Reminders | Opens the `.reminders` palette mode. | yes |
| Create Reminder | Prompts for a title, notes and a due date, and writes the reminder. | yes |
| Smart Reminder | Takes one sentence in its inline field, writes the AI model's reminder, and previews it in a banner. | yes |

New reminders go on the default Reminders list. A switch left off — Reminders or AI — reports
through the HUD, not a dialog: Settings is where to go, and there is nothing to acknowledge. Denied
access is different, because the fix is in System Settings, so it reports through a failure dialog
whose **Open Settings** goes to Privacy & Security → Reminders. Access TCC has no record of cannot be
fixed there at all, so it re-runs `setRemindersEnabled`'s consent path instead.

## Chat tools

With Reminders on and Settings → AI → Personal data → Reminders access set past Off, a chat on an
API connection is offered `reminders_list`, and with Read & Write `reminders_create`, `reminders_update` and
`reminders_complete` — see [AI](ai.md) for who gets offered what.
`RemindersCoordinator.chatTools` decides the list and `runTool` answers a call.

A listing is the store's own snapshot, so it covers exactly the lists switched on here, open
reminders only; a call that arrives before the first fetch lands waits for it rather than answering
empty. It answers JSON in `ReminderAgenda` order, at most `maxReminders`, each with the id a
completion names, its list, its due date in the `YYYY-MM-DD[THH:MM]` spelling the calls use, and
`overdue` where it is.

A create call writes to the default list with no prompt, and the answer is what was saved with its
id. An update names a reminder by that id and only the fields that change — `due` set to `none`
clears the date — and the create tool's description tells the model to update rather than add a
second. A due date the model wrote and Blitz cannot read is refused back to it, unlike Smart
Reminder's, which drops it: here the model can simply try again. Updating and completing look the
id up in EventKit through `RemindersStore.openReminder`, not the snapshot, so a reminder created a
moment ago is found before the reload lands; one that is completed or on a list switched off cannot
be reached. Completing asks before it ticks it off on every device.

## The prompt

`ReminderDraftFields` is a dialog accessory: title, notes, an unlabelled `No Date` · `Date` ·
`Date & Time` choice and a date field. The field is laid out even under `No Date`, disabled, because a dialog is measured
once as it is presented and a field that came and went would be clipped. The choice row is
`DialogChoiceRow`, shared with New Event.
