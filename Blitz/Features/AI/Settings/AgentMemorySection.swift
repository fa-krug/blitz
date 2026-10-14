import SwiftUI

/// Settings → AI → Memory: what the agent was asked to remember, newest first, edited in place.
struct AgentMemorySection: View {
    @Environment(AppCore.self) private var core
    /// One row at a time holds a field, so a hundred memories still list as plain text.
    @State private var editing: Editing?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private enum Editing: Equatable {
        case new
        case memory(Int)
    }

    var body: some View {
        let memory = core.agentMemoryCoordinator
        let memories = Array(memory.memories.reversed())
        Section {
            if editing == .new { field }
            ForEach(memories) { item in
                if editing == .memory(item.id) {
                    field
                } else {
                    AgentMemoryRow(
                        memory: item, onEdit: { begin(.memory(item.id), with: item.text) },
                        onForget: { memory.remove(id: item.id) })
                }
            }
            if memory.isLoaded, memories.isEmpty, editing == nil {
                Text("Nothing remembered yet.")
                    .foregroundStyle(.secondary)
            }
            Button {
                begin(.new, with: "")
            } label: {
                Label {
                    SettingsRowTitle(.aiMemory, "Add Memory")
                } icon: {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                }
            }
            Button {
                Task { await memory.forgetAll() }
            } label: {
                Label {
                    SettingsRowTitle(.aiMemory, "Forget All…")
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.primary)
                }
            }
            .settingsEnabled(!memories.isEmpty)
        } header: {
            SettingsSectionHeader(.aiMemory)
        } footer: {
            Text(
                "While Read Memory is Allow, every memory is sent to the model's provider with "
                    + "every turn. Memories stay on this Mac and are never in a backup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { memory.load() }
    }

    private var field: some View {
        TextField("Memory", text: $draft, prompt: Text("Prefers metric units"), axis: .vertical)
            .labelsHidden()
            .lineLimit(1...5)
            .focused($isFocused)
            .onSubmit { commit(staying: true) }
            .onExitCommand { editing = nil }
            .onChange(of: draft) {
                if draft.count > AgentMemory.textLimit {
                    draft = String(draft.prefix(AgentMemory.textLimit))
                }
            }
            .onChange(of: isFocused) {
                if !isFocused { commit(staying: false) }
            }
    }

    private func begin(_ target: Editing, with text: String) {
        draft = text
        editing = target
        isFocused = true
    }

    /// Return keeps a refused edit open to fix; leaving the field drops it, the HUD saying why.
    private func commit(staying: Bool) {
        let memory = core.agentMemoryCoordinator
        let saved: Bool
        switch editing {
        case nil: return
        case .new?:
            saved = AgentMemory.cleaned(draft).isEmpty || memory.add(draft)
        case .memory(let id)?:
            saved = memory.update(id: id, text: draft)
        }
        if saved || !staying { editing = nil }
    }
}

/// One memory as text, with its id and date; its buttons edit it in place or forget it.
private struct AgentMemoryRow: View {
    let memory: AgentMemory
    let onEdit: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(memory.text)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            iconButton("pencil", label: "Edit", action: onEdit)
            iconButton("minus.circle", label: "Forget", action: onForget)
        }
    }

    private var caption: String {
        "\(memory.handle) · \(memory.createdAt.formatted(.dateTime.day().month().year()))"
    }

    private func iconButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}
