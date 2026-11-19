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
- **Reads are the only thing off main.** The whole book is enumerated in a `nonisolated static`
  function driven by `Task.detached`, on a `CNContactStore` of its own, and flattened to `ContactItem`
  there — as a chat search's few cards are to `ContactToolCatalog.Card` — so nothing Contacts-shaped
  leaves `ContactsStore`. Writes stay on the main actor, like
  `RemindersStore`'s.
- **`ContactDirectory` is the one place that orders, buckets and searches.** The screen's `rows` and
  the drawn list both come from it — `matching` keeps the store's sorted order and `grouping` cuts
  that order into letter runs without re-sorting — so the selection always indexes what is on screen.
- **An edit writes only what changed.** Names and company always go back; the phone and email lists
  only when they differ from the card's, so fixing a typo never rewrites a number synced elsewhere.
  A kept value keeps its identifier and label; a cleared row removes that value; a new row takes
  `mobile` or `home`. Anything the editor does not show — photo, addresses, notes, dates — is never
  touched.
- **The card and its editor are palette pages, never a window of their own.** Both are pushed with
  `PaletteCoordinator.navigate`, so Escape or a save steps back to the row that opened them. Which card
  they show, and the editor's fields, live on `ContactsStore` (`presentedID`, `editor`) — a palette
  hidden mid-edit re-summons on the same edit — and `RootPaletteView` ends both once the palette
  leaves the two pages.
- **Marks live on `ContactsStore`, not `AppSettings`.** Contact identifiers are machine-specific, so
  they stay out of the backup, as reminder lists and calendars do. They store inclusions: a card is
  in root search only once someone asked for it, and an address book of thousands never floods it.

## The pure layer

- **`ContactItem`** / **`ContactField`** — one card and one labelled number or address, flattened.
  The card titles itself by its formatted name, else its company, else its first address or number.
  Its entry id is `contact:` plus the identifier, colon and all.
- **`ContactDraft`** — what the editor collects, and whether its lists changed.
- **`ContactDirectory`** — the order (title, case and accent aside), the letter runs, and the
  search: every word must hit a name, the company or an address, and a query that reads as a number
  matches phone digits with formatting and a trunk `0` ignored, so `0151 234` finds `+49 151 234…`.
- **`ContactLink`** — the `tel:` and `mailto:` URLs; a stored value never reaches a handler raw.
- **`ContactToolCatalog`** — the chat's `contacts_search`: its schema, the reading of a call, the
  keys a search may fetch, and the JSON answer. See [Chat tools](#chat-tools).

## Search Contacts

`ContactsScreen` lists the store's snapshot under one header per letter, with the card's initials in
a disc — Blitz never reads photos.

| Key | Does |
| --- | --- |
| ↵ | Show Contact — the card's page, one back step from the list |
| ⌘E | Edit Contact — the editor page |
| ⌘↵ | Call the first number, through `tel:` and the Mac's phone handler |
| ⌃⌘↵ | Email the first address, through `mailto:` and the default mail app |
| ⌘O | Open in Contacts, through `addressbook://`, or the bare app with no handler |
| ⇧⌘C | Copy the first phone number |
| ⌥⌘C | Copy the first email address |

⌘K lists Show Contact, every number and address as its own Call or Email row, then Copy Phone Number
and Copy Email Address for the first of each, Edit Contact, Open in Contacts, and Show in / Remove
from Launcher Search. A
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

↵ opens the card's page over root search, so Escape comes back to the query; ⌘↵, ⌃⌘↵, ⌘O, ⌘E,
⇧⌘C and ⌥⌘C call, email, open, edit and copy it straight from root search — a contact has no
deeplink, so ⇧⌘C is free for its number — and its ⌘K menu is the list's own.

## Fallback

**Search Contacts** is a built-in fallback, offered while the feature is on: `Use “greg” with…` opens
the list already narrowed to `greg`. See [launcher.md](launcher.md#fallbacks).

## Commands

| Command | Does | Bindable |
| --- | --- | --- |
| Search Contacts | Opens the `.contacts` palette mode. | yes |

## Chat tools

With Contacts on, a chat on an API connection or the Claude command is offered `contacts_search`
while the agent's Read Contacts row is not Deny. The row, its dialog and who gets offered what are
[Agent](agent.md#personal-and-context-tools)'s; `ContactsCoordinator.runTool` reads the call, asks
the gate, and only then searches.

A search is `ContactDirectory.matching` over the store's snapshot — the same words, numbers and
fields Search Contacts matches — and the first `limit` matches (10 by default, at most 25) are read
again, off main, by `ContactsStore.toolCards`: the formatted name, company, labelled emails and
phones, postal addresses on one line each, and the birthday. `ContactToolCatalog.fetchedKeys` is
every key it asks for besides the name, and the note and image keys are not among them, so neither
can reach a model; `contacts-test` and `personal-tool-test` compile the catalog. The answer is
JSON, with how many cards matched in all. Without macOS's grant, or before the first read lands,
the call is refused with a sentence.

## The card

`.contactCard` is `ContactCardScreen`: the monogram, name and company, then a row per number under
**Phone** and per address under **Email**, in the card's own order. The search field narrows those
rows by value or label. A card with neither still answers ↵, by opening the editor.

| Key | Does |
| --- | --- |
| ↵ | Call the selected number, or write to the selected address |
| ⌘↵ | Copy the selected line |
| ⌘E | Edit Contact |
| ⌘O | Open in Contacts |
| ⇧⌘C | Copy the selected number, else the first |
| ⌥⌘C | Copy the selected address, else the first |

A copy hides the palette and confirms through the HUD. ⌘K leads with the selected line's two actions, then Edit Contact, Open in Contacts and Show in /
Remove from Launcher Search.

## The editor

`.contactEditor` is `ContactEditorScreen`: the search field steps aside and a labelled field per
name part, company, number and address takes the keyboard. ↑/↓ and ⇥ walk the fields, wrapping as a
form's do; ↵ in any field or ⌘↵ saves, and Escape steps back without writing. Each list ends on one
blank row to add a value, and typing into it grows the next, so a card can gain any number of lines.
An unchanged page writes nothing; a page with nothing left to name the card refuses through the HUD.
`ContactDraftState` holds the fields and the card's draft as it opened, which is what an unchanged
save is measured against.

## Settings

The Contacts pane carries the master switch, routed through the coordinator so the consent gate
cannot be bypassed, the command's alias and shortcut, and **Launcher Search**: the marked cards with
a checkbox each, or — once something is typed — the first fifty matches to mark. A `Form` realizes
every row it is handed, so the pane never lists the whole book.

The app declares `NSContactsUsageDescription` and the hardened runtime's
`com.apple.security.personal-information.addressbook` entitlement; without the entitlement, tccd
refuses the prompt outright.
