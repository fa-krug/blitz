import SwiftUI

/// Every saved conversation, pinned first and then by day; selecting one opens it on the right.
struct AIChatSidebarView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @State private var query = ""
    /// Archived chats take the list's place until one is opened or the reader backs out.
    @State private var showsArchive = false
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private var chats: AIChatSurfacesState { coordinator.chats }
    private var history: ChatHistoryStore { coordinator.history }

    private struct ChatSection: Identifiable {
        let title: String
        var conversations: [ChatConversation]
        var id: String { title }
    }

    /// Recency order already groups each day together, so a bucket only ever opens once.
    private var sections: [ChatSection] {
        var sections: [ChatSection] = []
        let buckets = DateBuckets()
        for conversation in history.search(query).pinnedFirst {
            let title =
                conversation.isPinned ? "Pinned" : buckets.bucket(for: conversation.updatedAt).title
            if sections.last?.title == title {
                sections[sections.count - 1].conversations.append(conversation)
            } else {
                sections.append(ChatSection(title: title, conversations: [conversation]))
            }
        }
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsArchive {
                ArchiveHeader { leaveArchive() }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }
            ChatSearchField(query: $query, focused: $searchFocused)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)
            if showsArchive {
                AIChatArchiveList(query: query) { leaveArchive() }
            } else {
                list
                archiveEntry
            }
        }
        // The field sits under the toolbar's material, so it needs its own clearance from the top.
        .padding(.top, Theme.Spacing.md)
        .onExitCommand {
            if !query.isEmpty {
                query = ""
            } else if showsArchive {
                leaveArchive()
            } else {
                _ = coordinator.closeWindowIfKey()
            }
        }
    }

    /// Shown only while something is archived, so an empty archive costs the sidebar nothing.
    @ViewBuilder private var archiveEntry: some View {
        let count = history.archived.count
        if count > 0 {
            Divider()
            ArchiveEntryButton(count: count) {
                query = ""
                showsArchive = true
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private func leaveArchive() {
        query = ""
        showsArchive = false
    }

    @ViewBuilder private var list: some View {
        let sections = sections
        let answering = chats.answeringIDs
        let waits = chats.waits
        let openID = chats.window.session.id
        if sections.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.conversations) { conversation in
                            ChatSidebarRow(
                                conversation: conversation,
                                isAnswering: answering.contains(conversation.id),
                                wait: waits[conversation.id],
                                isSelected: conversation.id == openID
                            ) {
                                title(of: conversation)
                            }
                            .tag(conversation.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let conversation = history.conversation(id: id) {
                    menu(for: conversation)
                }
            }
            .onDeleteCommand {
                guard let id = selection.wrappedValue, history.conversation(id: id) != nil
                else { return }
                Task { await coordinator.deleteChat(id: id) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !history.isAvailable {
            ContentUnavailableView(
                "History Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Chats can't be saved on this Mac right now."))
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                description: Text("Conversations stay on this Mac."))
        }
    }

    /// Only the title swaps for a rename field; an if/else row makes the List diff quadratically.
    @ViewBuilder private func title(of conversation: ChatConversation) -> some View {
        if renaming == conversation.id {
            TextField("Chat name", text: $renameText, prompt: Text(conversation.title))
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onSubmit { commitRename(conversation.id) }
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused { commitRename(conversation.id) }
                }
        } else {
            Text(conversation.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private func menu(for conversation: ChatConversation) -> some View {
        Button(
            conversation.isPinned ? "Unpin Chat" : "Pin Chat",
            systemImage: conversation.isPinned ? "pin.slash" : "pin"
        ) {
            coordinator.togglePin(id: conversation.id)
        }
        if !conversation.isPinned {
            Button("Archive Chat", systemImage: "archivebox") {
                coordinator.archiveChat(id: conversation.id)
            }
            .disabled(!coordinator.canArchive(id: conversation.id))
        }
        Button("Rename…", systemImage: "pencil") { beginRename(conversation) }
        Divider()
        Button("Copy Chat", systemImage: "doc.on.doc") { coordinator.copyChat(id: conversation.id) }
        Button("Export as Markdown…", systemImage: "square.and.arrow.up") {
            coordinator.exportChat(id: conversation.id)
        }
        Divider()
        Button("Delete Chat…", systemImage: "trash", role: .destructive) {
            Task { await coordinator.deleteChat(id: conversation.id) }
        }
        Button("Delete All Chats…", systemImage: "trash.slash", role: .destructive) {
            Task { await coordinator.deleteAllChats() }
        }
    }

    private func beginRename(_ conversation: ChatConversation) {
        renameText = conversation.customTitle ?? ""
        renaming = conversation.id
        Task { @MainActor in renameFocused = true }
    }

    private func commitRename(_ id: UUID) {
        guard renaming == id else { return }
        renaming = nil
        coordinator.rename(id: id, to: renameText)
    }

    /// The open chat is the selected row; a new one has no row until its first message.
    private var selection: Binding<UUID?> {
        Binding(
            get: { chats.window.session.id },
            set: { id in
                guard let id, id != chats.window.session.id else { return }
                coordinator.openChat(id: id)
            }
        )
    }

}

/// A chat's title, then its wait, a spinner or a pin; hover is a fainter selection.
private struct ChatSidebarRow<Title: View>: View {
    let conversation: ChatConversation
    let isAnswering: Bool
    let wait: AgentWait?
    let isSelected: Bool
    @ViewBuilder let title: Title
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            title
            Spacer(minLength: 0)
            if let wait {
                Image(systemName: wait.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .accessibilityLabel(wait.label)
            } else if isAnswering {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Answering")
            } else if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Pinned")
            }
        }
        // The whole cell, so the pointer never crosses a gap where no row is hovered.
        .frame(maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .listRowBackground(hoverFill)
        .help(conversation.displayTitle)
    }

    /// Inset and rounded as the system's selection is, so the two read as one shape.
    @ViewBuilder private var hoverFill: some View {
        if isHovered, !isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Colors.rowHover)
                .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

/// The foot of the sidebar: the way into the archived chats, with how many there are.
private struct ArchiveEntryButton: View {
    let count: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                Text("Archived")
                Spacer(minLength: 0)
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.Colors.rowHover)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Archived chats, \(count)")
    }
}

/// Above the archive's search field: the way back to every other chat.
private struct ArchiveHeader: View {
    let back: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: back) {
                Image(systemName: "chevron.backward")
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Back to chats")
            .help("Back to chats")
            Text("Archived")
                .font(.headline)
            Spacer(minLength: 0)
        }
    }
}

/// The sidebar's search field, drawn the way Settings' own is so the two windows match.
private struct ChatSearchField: View {
    @Binding var query: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .pointerStyle(.horizontalText)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Theme.Size.aiChatSearchField)
        .background { Color.clear.frosted(in: Capsule()) }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .accessibilityLabel("Search chats")
    }
}
