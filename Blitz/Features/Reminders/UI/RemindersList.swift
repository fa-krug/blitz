import SwiftUI

/// The My Reminders list, one header per section.
struct RemindersList: View {
    @Environment(\.metrics) private var metrics
    let groups: [ReminderGroup]
    let selectedID: ReminderItem.ID?
    let now: Date
    let scroll: ScrollIntent
    let onActivate: (ReminderItem) -> Void
    let onComplete: (ReminderItem) -> Void
    let onActions: (ReminderItem) -> Void

    private enum Row: Identifiable {
        case header(ReminderSection, isFirst: Bool)
        case reminder(ReminderItem)

        var id: String {
            switch self {
            case .header(let section, _): return "header-\(section.rawValue)"
            case .reminder(let reminder): return reminder.id
            }
        }
    }

    private var rows: [Row] {
        groups.enumerated().flatMap { index, group in
            [.header(group.section, isFirst: index == 0)] + group.reminders.map(Row.reminder)
        }
    }

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == groups.first?.reminders.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let section, let isFirst):
                            SectionHeader(title: section.title, isFirst: isFirst)
                        case .reminder(let reminder):
                            ReminderRow(
                                reminder: reminder, now: now, selected: reminder.id == selectedID,
                                onComplete: { onComplete(reminder) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(reminder) }
                            .onRightClick { onActions(reminder) }
                            .selectionFrame(reminder.id == selectedID)
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct ReminderRow: View {
    @Environment(\.metrics) private var metrics
    let reminder: ReminderItem
    let now: Date
    let selected: Bool
    let onComplete: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    private var isOverdue: Bool {
        reminder.due?.isOverdue(now: now, calendar: .current) ?? false
    }

    private var dueTitle: String? {
        reminder.due?.title(now: now, calendar: .current)
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            Button(action: onComplete) {
                SymbolImage(name: "circle", size: metrics.size.resultRowIcon * 0.7)
                    .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
                    .foregroundStyle(reminder.listColor?.color ?? .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Complete")
            .accessibilityLabel("Complete \(reminder.title)")
            Text(reminder.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            if let notes = reminder.notes, !notes.isEmpty {
                Text(notes)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            HStack(spacing: metrics.spacing.md) {
                if let dueTitle {
                    Text(dueTitle)
                        .foregroundStyle(isOverdue ? Theme.Colors.destructive : .secondary)
                }
                Text(reminder.listName)
                    .foregroundStyle(.tertiary)
            }
            .font(metrics.typography.rowTrailing)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        let parts = [
            reminder.title, dueTitle.map { isOverdue ? "overdue, \($0)" : "due \($0)" },
            reminder.listName
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

extension ReminderItem.ListColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}
