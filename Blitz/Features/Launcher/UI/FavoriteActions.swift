import Foundation

/// Resolved by the screen that owns the visible order; every row runs its chord's call.
@MainActor
struct FavoriteActions {
    let isFavorite: Bool
    var canMoveUp = false
    var canMoveDown = false
    let toggle: () -> Void
    var move: (Int) -> Void = { _ in }

    /// A move row is only built in a direction that exists.
    var items: [PopoverMenuItem] {
        var items = [
            PopoverMenuItem(
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "star.slash" : "star", startsSection: true,
                shortcut: "⇧⌘F", action: toggle)
        ]
        if canMoveUp {
            items.append(
                PopoverMenuItem(title: "Move Favorite Up", systemImage: "arrow.up", shortcut: "⌥⌘↑") {
                    move(-1)
                })
        }
        if canMoveDown {
            items.append(
                PopoverMenuItem(
                    title: "Move Favorite Down", systemImage: "arrow.down", shortcut: "⌥⌘↓"
                ) { move(1) })
        }
        return items
    }
}
