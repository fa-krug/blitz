# Contacts

The Mac's own address book, from the palette: **Search Contacts** lists every card to edit, call,
email or open in Contacts; the same list is a **fallback** for any launcher query; and a card you
**mark** joins the launcher's own search, beside your apps.

## Invariants

- **`contactsEnabled` doubles as consent**, so it is in `SettingsBackupCoverage.deliberatelyExcluded`
  and only `ContactsCoordinator.setContactsEnabled` may write it. Blitz's own dialog comes first, the
  macOS prompt second, and only from the gesture that asked. **It is written only after macOS
  grants**, exactly as `remindersEnabled` is — see [reminders.md](reminders.md). The Contacts pane and
  the Permissions pane both re-offer it whenever access is anything but granted.
- **Nothing polls.** `CNContactStoreDidChange` is the reload signal, held through the RAII
  `NotificationToken`, so a card edited on a phone follows on its own. Opening Search Contacts re-reads
  once, because access revoked in System Settings announces nothing. A sync posts changes in bursts,
  so a change that lands while a read is in flight queues **one** more read rather than starting
  another.
- **The read is the only thing off main.** The whole book is enumerated in a `nonisolated static`
  function driven by `Task.detached`, on a `CNContactStore` of its own, and flattened to `ContactItem`
  there; nothing Contacts-shaped leaves `ContactsStore`. Writes stay on the main actor, like
  `RemindersStore`'s.
- **`ContactDirectory` is the one place that orders, buckets and searches.** The screen's `rows` and
  the drawn list both come from it — `matching` keeps the store's sorted order and `grouping` cuts
  that order into letter runs without re-sorting — so the selection always indexes what is on screen.
- **An edit writes only what changed.** Names and company always go back; the phone and email lists
  only when they differ from the card's, so fixing a typo never rewrites a number synced elsewhere.
  A kept value keeps its identifier and label; a cleared row removes that value; a new row takes
  `mobile` or `home`. Anything the prompt does not show — photo, addresses, notes, dates — is never
  touched.
- **Marks live on `ContactsStore`, not `AppSettings`.** Contact identifiers are machine-specific, so
  they stay out of the backup, as reminder lists and calendars do. They store inclusions: a card is
  in root search only once someone asked for it, and an address book of thousands never floods it.
- **`Model/` stays Foundation-only**; `contacts-test` compiles the shipped sources.

## The pure layer

- **`ContactItem`** / **`ContactField`** — one card and one labelled number or address, flattened.
  The card titles itself by its formatted name, else its company, else its first address or number.
  Its entry id is `contact:` plus the identifier, colon and all.
- **`ContactDraft`** — what the prompt collects, and whether its lists changed.
- **`ContactDirectory`** — the order (title, case and accent aside), the letter runs, and the
  search: every word must hit a name, the company or an address, and a query that reads as a number
  matches phone digits with formatting and a trunk `0` ignored, so `0151 234` finds `+49 151 234…`.
- **`ContactLink`** — the `tel:` and `mailto:` URLs; a stored value never reaches a handler raw.

## Search Contacts

`ContactsScreen` lists the store's snapshot under one header per letter, with the card's initials in
a disc — Blitz never reads photos.

| Key | Does |
| --- | --- |
| ↵ | Edit Contact — the prompt, filled in. The palette stays up behind it, so the edit lands in view. |
| ⌘↵ | Call the first number, through `tel:` and the Mac's phone handler |
| ⌃⌘↵ | Email the first address, through `mailto:` and the default mail app |
| ⌘O | Open in Contacts, through `addressbook://`, or the bare app with no handler |

⌘K lists every number and address as its own Call or Email row, then Copy Phone Number and Copy
Email Address for the first of each, Open in Contacts, and Show in / Remove from Launcher Search. A
miss — no number, nothing to place calls — reports through the HUD, not a dialog.

Without access the empty list offers the way back, as Calendar's and Reminders' do: a denial opens
**Privacy Settings**, and `.notDetermined` — which System Settings cannot list — offers **Allow
Access**, rerunning `setContactsEnabled(true)` with the palette hidden.

## Launcher search

A marked card is an `AppEntry.Kind.contact` entry under its own **Contacts** section, published by
`ContactsCoordinator.publishEntries` through `AppIndex.setContacts` whenever the snapshot or the marks
move. It carries the company as its subtitle and its addresses as keywords, and is owned by the
Contacts pane, so no category switch gates it. `canHideFromSearch` is false: unmarking is the way
out, and both places that mark — the row's ⌘K menu and the pane — unmark too.

↵ opens Search Contacts on that card, where every action is a key away; ⌘↵, ⌃⌘↵ and ⌘O call, email
and open it straight from root search, and its ⌘K menu leads with the same rows as in the list.

## Fallback

**Search Contacts** is a built-in fallback, offered while the feature is on: `Use “greg” with…` opens
the list already narrowed to `greg`. See [launcher.md](launcher.md#fallbacks).

## Commands

| Command | Does | Bindable |
| --- | --- | --- |
| Search Contacts | Opens the `.contacts` palette mode. | yes |

## The prompt

`ContactDraftFields` is a dialog accessory: first and last name, company, then one field per number
and per address, each prompted with its label, and one blank row after each list to add a value. A
dialog is measured once as it is presented, so the blank row is laid out up front rather than grown
on demand.

## Settings

The Contacts pane carries the master switch, routed through the coordinator so the consent gate
cannot be bypassed, the command's alias and shortcut, and **Launcher Search**: the marked cards with
a checkbox each, or — once something is typed — the first fifty matches to mark. A `Form` realizes
every row it is handed, so the pane never lists the whole book.

The app declares `NSContactsUsageDescription` and the hardened runtime's
`com.apple.security.personal-information.addressbook` entitlement; without the entitlement, tccd
refuses the prompt outright.
