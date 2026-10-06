import AppKit

/// Owns emoji delivery: frequency tallies the base glyph, the configured tone applies at copy time.
@MainActor
final class EmojiCoordinator {
    private let frequentEmoji: FrequentEmojiStore
    private let keywords: EmojiKeywordStore
    private let settings: AppSettings
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, so they stay owned by `AppCore`.
    private unowned let core: AppCore

    init(
        frequentEmoji: FrequentEmojiStore,
        keywords: EmojiKeywordStore,
        settings: AppSettings,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.frequentEmoji = frequentEmoji
        self.keywords = keywords
        self.settings = settings
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// `tone` overrides the default for this one paste; nil uses the Settings choice.
    func pasteEmoji(_ entry: EmojiEntry, tone: EmojiSkinTone? = nil) {
        frequentEmoji.record(entry.glyph)
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteString(entry.display(tone: tone ?? settings.emojiSkinTone), previousApp: previous)
    }

    func copyEmoji(_ entry: EmojiEntry, tone: EmojiSkinTone? = nil) {
        frequentEmoji.record(entry.glyph)
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyString(entry.display(tone: tone ?? settings.emojiSkinTone))
    }

    func pasteEmojiKeepingWindowOpen(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        windowController.pasteStringKeepingWindowOpen(entry.display(tone: settings.emojiSkinTone))
    }

    func editKeywords(_ entry: EmojiEntry) {
        Task {
            guard
                let input = await core.editText(
                    title: "Edit Keywords",
                    message: "Comma-separated words that find \(entry.displayName) in search.",
                    symbol: "tag",
                    text: EmojiKeywords.input(for: keywords.terms(for: entry.glyph)),
                    placeholder: "yes, approve, lgtm", label: "Keywords", confirmTitle: "Save")
            else { return }
            keywords.setTerms(EmojiKeywords.terms(from: input), for: entry.glyph)
        }
    }
}
