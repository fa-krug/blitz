import Foundation

/// One form's edit left by click-away, kept for that form's next opening. See docs/ui.md.
final class FormDraftMemory<Draft: Equatable> {
    private var kept: (opening: Draft, edited: Draft)?

    /// Keyed on the opening draft, so another record, a changed one or a new prefill opens fresh.
    func draft(openingOn opening: Draft) -> Draft {
        guard let kept, kept.opening == opening else { return opening }
        return kept.edited
    }

    /// Only a click-away keeps an edit: ↵, Escape and Cancel all say the user is done with it.
    func settle(_ edited: Draft, openedOn opening: Draft, clickedAway: Bool) {
        if clickedAway, edited != opening {
            kept = (opening, edited)
        } else if kept?.opening == opening {
            kept = nil
        }
    }
}
