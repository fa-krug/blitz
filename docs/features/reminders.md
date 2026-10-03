# Reminders

Three surfaces over the Mac's own Reminders: **My Reminders**, a palette screen listing every open
reminder to edit, complete or delete; **Create Reminder**, a prompt for a title, notes and a due date;
and **Smart Reminder**, which takes one sentence — `Greg wants tomorrow a cake` — and asks the AI
model to turn it into `Give Greg a cake`, due tomorrow, filled into the same prompt for a ↵ to save.

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
- **Smart Reminder exists only while AI is on.** It runs on the app's default model through
  `AppCore.smartReminderProvider`, and `RemindersCoordinator.applyCommands` takes it out of the
  launcher — its shortcut with it — when either switch is off. Turning AI off cancels a run in flight.
  The model is sent the typed sentence and today's date, never a reminder already on the Mac.
- **A model's reply is read, never trusted, and never written unseen.** `SmartReminderPrompt.draft(from:)`
  takes the first `{` to the last `}` and decodes it field by field. No title is no reminder; a due
  date that is not a real day is dropped rather than guessed. Even a clean reply only fills the New
  Reminder prompt — ↵ saves it, Esc drops it — so a misread sentence never reaches Reminders. Whatever
  fails, the sentence is not lost: `Write It Myself` opens the same prompt with it as the title.
- **Per-list switches live on `RemindersStore`, not `AppSettings`.** List identifiers are
  machine-specific, so they stay out of the backup, as the calendar's do. They store exclusions, so a
  list added later defaults to on.
- **`Model/` stays Foundation-only**; `reminders-test` compiles the shipped sources.

## The pure layer

- **`ReminderDue`** — the day, and a time only when one was set; EventKit's date components, flat.
  It titles itself `Today`, `Tomorrow`, `Friday` within the week, then `Oct 12`, adding the clock for
  a timed reminder.
- **`ReminderItem`** / **`ReminderList`** — one open reminder and one list, flattened out of EventKit.
- **`ReminderDraft`** — what a prompt collects, before anything touches Reminders.
- **`ReminderAgenda`** — the order, the five sections (`Overdue`, `Today`, `Tomorrow`, `Upcoming`,
  `No Due Date`) and the query match over title, notes and list name.
- **`SmartReminderPrompt`** — the instructions and the reading of the reply.

## Smart Reminder

The model cannot know the date, so the instructions carry it: now as weekday, day, clock and zone,
then the seven days ahead spelled the same way, so `next Friday` resolves by lookup rather than by
arithmetic a small on-device model gets wrong. One worked example uses the real tomorrow. The reply
is one JSON object — `title`, `due` as `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`, `notes` — and a time is
added only when the sentence names one, with `morning`, `noon`, `afternoon`, `evening` and `tonight`
pinned to fixed hours.

The progress pill says the model is working and its ✕ cancels the run. Guardrails are
`.permissiveContentTransformations`: the sentence is the reader's own, which the default filter can
refuse. A timed due date gets a dated alarm, as Reminders.app adds one; a day-only one gets none, and
Reminders' own all-day notification time applies.

## My Reminders

`RemindersScreen` lists the store's snapshot through `ReminderAgenda`. The row's circle, in the list's
colour, completes the reminder on a click.

| Key | Does |
| --- | --- |
| ↵ | Edit Reminder — the prompt, filled in. The palette stays up behind it, so the edit lands in view. |
| ⌘↵ | Complete Reminder |
| ⌘O | Open in Reminders, through `x-apple-reminderkit://`, or the bare app with no handler |
| ⌘N | New Reminder |
| ⌘⌫ | Delete Reminder — always confirmed: it goes from every device the list syncs to |

Reminders are not individual launcher entries, unlike meetings: My Reminders is one search away, and a
to-do list long enough to need search would crowd apps out of the root.

## Commands

| Command | Does | Bindable |
| --- | --- | --- |
| My Reminders | Opens the `.reminders` palette mode. | yes |
| Create Reminder | Prompts for a title, notes and a due date, and writes the reminder. | yes |
| Smart Reminder | Prompts for one sentence, then shows the AI model's reminder in the prompt to save. | yes |

New reminders go on the default Reminders list. A miss — the feature off, no access, AI off — reports
through the HUD, not a dialog.

## The prompt

`ReminderDraftFields` is a dialog accessory: title, notes, a `No Date` · `Date` · `Date & Time` choice
and a date field. The field is laid out even under `No Date`, disabled, because a dialog is measured
once as it is presented and a field that came and went would be clipped. The choice row is
`DialogChoiceRow`, shared with New Event.
