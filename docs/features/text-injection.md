# Text injection

The one way Blitz writes text into something the user is typing in — another app, or one of its own
editors. Snippets expand through it, Quick Actions read and replace a selection through it, and
Quicklinks read `{selection}` through it. It has no Settings pane and no launcher rows of its own.

The full five-rule delivery contract for another app — renderer surfaces, keyword convergence,
read-back, the event fallback and its four-unit keystrokes, the pasteboard loan — is written down
once, in [snippets.md](snippets.md#text-delivery-and-pasteboard-safety), where its hardest case
lives. This page is the map.

## Invariants

- **One injector, owned by `AppCore`.** `TextInjector` is built once and handed to
  `SnippetCoordinator`, `QuickActionCoordinator` / `QuickActionRunner` and `QuicklinkCoordinator`.
  Its serial `DeliveryQueue` is what stops two features fighting over the pasteboard, so no feature
  posts paste events or borrows the pasteboard on its own.
- **The target is where the caret is, not the frontmost app.** Blitz's panels never activate, so a
  key window of ours can hold the keystrokes while `frontmostApplication` names the app behind it.
  `InjectionTarget.current()` reads `NSApp.keyWindow` first and falls back to the frontmost app only
  when no window of ours is key; a key window whose first responder is not an `InjectableTextView`
  resolves to no target at all. From the palette, `PaletteWindowController.previousTarget` resolves
  what the palette covered through `InjectionTarget.behindPalette`.
- **Our own editors opt in, and only by protocol.** `InjectableTextView` is an empty protocol on
  `NSTextView`; adopting it is the whole contract. `NoteTextView` is the one adopter. In process
  there is nothing to grant, activate, lend or post: `inject(_:over:)` calls
  `insertText(_:replacementRange:)`, so the edit is undoable in the view's own manager.
- **Blitz never injects into itself over events.** `targetAcceptsInjection` refuses a terminated
  app, Blitz's own bundle identifier and Secure Event Input, before every delivery.
- **The pasteboard is lent, then given back whole.** A temporary paste lends a board holding only
  the text and Blitz's marker type, restores the full snapshot afterwards, and skips the restore if
  the change count moved — a newer copy is never overwritten. `ClipboardManager` is told before and
  after, so neither the loan nor the restore lands in history.
- **Every delivery settles exactly once.** `DeliveryCompletion.settle()` runs from a `defer`, so a
  delivery that returned early still reports failure; callers decide whether that is news.

## How a delivery runs

`TextInjector.deliver(_:target:expectedKeyword:keywordLength:automaticGeneration:…)` is the entry
point; `replaceSelection(with:in:…)` is the same call with no keyword.

1. **Gate.** An automatic expansion checks its generation, `snippetsEnabled`, Accessibility and the
   target; an interactive one (`prepareInteractiveExpansion`) checks the target and asks for
   Accessibility, handing focus back if refused.
2. **Queue.** The work goes on `DeliveryQueue`, marked automatic or not, so
   `cancelAutomaticExpansion` can drop speculative work without touching an explicit one, and
   `prepareForTermination` cancels everything.
3. **Pick the tier by target.** `.ownEditor` takes `deliverInProcess`; `.external` takes the
   Accessibility write with read-back, then the event fallback — keystrokes for short single-line
   text, a temporary paste for the rest.
4. **Settle.** `onDelivered` or `onFailed`, once.

**Reading a selection.** `captureExpansionContext(target:…)` reads the selection for a template's
`{selection}` — from the editor directly, or over Accessibility. `copySelection(from:)` is the
fallback Quick Actions use when Accessibility yields nothing: it drains the queue, borrows a ⌘C,
polls the change count for up to a second, and restores the snapshot either way. A change count that
never moves means nothing was selected.

**Handing focus back.** `InjectionTarget.restoreFocus()` reactivates the external app or makes the
editor first responder again — after a modal argument prompt, or an expansion that went nowhere.

## Where it lives

| File | Holds |
| --- | --- |
| `TextInjection/Service/InjectionTarget.swift` | `.external` / `.ownEditor`, resolving the target, restoring focus |
| `TextInjection/Service/InjectableTextView.swift` | the opt-in protocol and `injectableSelection` |
| `TextInjection/Service/InProcessInjection.swift` | keyword state and `inject(_:over:)` for our own views |
| `TextInjection/Service/TextInjector.swift` | `TextInjector`, `InjectedText`, `TextReplacementPolicy`, `DeliveryCompletion`, `DeliveryQueue`, `UnicodeTypingChunk`, `PasteConfirmationPolicy`, `TemporaryPasteboardLease`, `PasteboardSnapshot` |

[Window management](window-management.md) resolves its own target the same way for the same reason:
a command run from a non-activating panel must not act on whatever happens to be frontmost.

## Testing

`snippets-test` compiles every file in `TextInjection/Service/` with the snippets model and service,
and drives the pure judgements — `TextReplacementPolicy`'s keyword states and read-back,
`UnicodeTypingChunk`'s four-unit split, `PasteConfirmationPolicy` — plus the pasteboard lease and
`copySelection` against a stub `PasteboardAccess`. `notes-editor-test` compiles
`InjectableTextView.swift` alongside `NoteTextView`. Delivery into real apps — Chromium, Monaco, a
native field, our own Notes editor — is in the [snippets manual sweep](snippets.md#manual-sweep).
