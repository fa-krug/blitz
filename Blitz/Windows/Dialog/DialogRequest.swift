import Foundation

/// One button; role decides its colour, severity living separately in `DialogTone`.
struct DialogAction {
    enum Role {
        case standard
        case destructive
        case cancel
    }

    let title: String
    var role: Role = .standard
}

/// How serious a dialog is; it tints the glyph but never picks one. See docs/ui.md.
enum DialogTone: Sendable {
    case neutral
    case success
    case danger
}

struct DialogRequest {
    let title: String
    var message: String?
    /// Nil where the title already names the subject and a glyph would repeat it.
    let symbol: String?
    /// The subject's own picture, drawn in place of `symbol`: a quicklink's favicon file.
    var artwork: String?
    var tone: DialogTone = .neutral
    var actions: [DialogAction]
    /// The button ↵ fires, normally the primary action.
    var defaultIndex: Int
    /// Resolved when the dialog goes without a choice: Esc, or losing key status.
    var cancelIndex: Int
    /// The caller reads the result back out of the state object it passed in.
    var accessory: DialogAccessory?
}

/// A dialog carries at most one control, so the cases are exclusive by construction.
enum DialogAccessory {
    case volume(VolumeState)
    case eventDraft(EventDraftState)
    case reminderDraft(ReminderDraftState)
    case contactDraft(ContactDraftState)
    case snippetArguments(SnippetArgumentsState)
    case text(DialogTextState)
    case multilineText(DialogTextState)

    /// A form is filled in rather than answered, so it takes the wider, one-line-header layout.
    var isForm: Bool {
        if case .volume = self { return false }
        return true
    }

    /// Whether ←/→/↑/↓ belong to the control rather than to whatever has focus inside it.
    var claimsArrowKeys: Bool {
        if case .volume = self { return true }
        return false
    }

    /// Return types a newline in a multi-line box, so only ⌘↵ may confirm.
    var confirmsWithCommandReturn: Bool {
        if case .multilineText = self { return true }
        return false
    }

    /// False while the primary action has nothing it could write, as a greyed-out button would be.
    @MainActor var acceptsPrimaryAction: Bool {
        switch self {
        case .eventDraft(let state): state.draft.isValid
        case .reminderDraft(let state): state.draft.isValid
        case .contactDraft(let state): state.draft.isValid
        case .multilineText(let state): !state.isBlank
        case .volume, .snippetArguments, .text: true
        }
    }
}
