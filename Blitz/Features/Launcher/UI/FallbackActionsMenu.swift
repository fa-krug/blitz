import Foundation

/// A fallback row answers the query rather than naming a thing, so it is never pinned or ranked.
@MainActor
enum FallbackActionsMenu {
    static func content(
        fallback: Fallback, entry: AppEntry, query: String, core: AppCore
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: entry.name,
            items: [
                PopoverMenuItem(
                    title: fallback.openVerb, systemImage: "list.bullet.rectangle", shortcut: "↵"
                ) { core.fallbackCoordinator.run(fallback, query: query) },
                PopoverMenuItem(
                    title: "Configure Fallbacks…", systemImage: "slider.horizontal.3", startsSection: true
                ) {
                    core.fallbackCoordinator.showSettings()
                }
            ])
    }
}
