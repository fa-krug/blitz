import Foundation

/// Where the reader could answer a chat right now; a chat shown nowhere here is off screen.
struct ChatPresence: Equatable, Sendable {
    enum Surface: Equatable, Sendable {
        case window
        case quickAI
    }

    /// The chat window is visible and Blitz is the active app, so a dialog lands where they look.
    let windowInFront: Bool
    /// The palette is up on Quick AI's conversation; its history is a list, not the conversation.
    let quickAIInFront: Bool

    init(windowVisible: Bool, appActive: Bool, paletteVisible: Bool, paletteOnQuickAI: Bool) {
        windowInFront = windowVisible && appActive
        quickAIInFront = paletteVisible && paletteOnQuickAI
    }

    /// Nil is a chat neither surface holds: one left answering while another took the window.
    func shows(_ surface: Surface?) -> Bool {
        switch surface {
        case .window: windowInFront
        case .quickAI: quickAIInFront
        case nil: false
        }
    }
}
