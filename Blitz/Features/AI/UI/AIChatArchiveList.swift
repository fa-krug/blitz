import SwiftUI

/// The archived chats, newest first; opening one brings it back to the sidebar.
struct AIChatArchiveList: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    let query: String
    let onOpen: () -> Void

    private var history: ChatHistoryStore { coordinator.history }

    var body: some View {
        let archived = history.searchArchived(query)
        if archived.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(archived) { conversation in
                    ArchivedChatRow(conversation: conversation).tag(conversation.id)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, history.conversation(id: id) != nil {
                    menu(for: id)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No Archived Chats", systemImage: "archivebox",
                description: Text("Archived chats stay on this Mac until you delete them."))
        }
    }

    @ViewBuilder private func menu(for id: UUID) -> some View {
        Button("Open Chat", systemImage: "bubble.left") { open(id) }
        Button("Unarchive Chat", systemImage: "tray.and.arrow.up") {
            coordinator.unarchiveChat(id: id)
        }
        Divider()
        Button("Delete Chat…", systemImage: "trash", role: .destructive) {
            Task { await coordinator.deleteChat(id: id) }
        }
    }

    private func open(_ id: UUID) {
        coordinator.openArchivedChat(id: id)
        onOpen()
    }

    /// Nothing stays selected here: choosing a row opens it, and the sidebar goes back to the rest.
    private var selection: Binding<UUID?> {
        Binding(get: { nil }, set: { id in if let id { open(id) } })
    }
}

/// An archived chat's title, and when it was last used.
private struct ArchivedChatRow: View {
    let conversation: ChatConversation

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(conversation.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(conversation.displayTitle)
    }
}
