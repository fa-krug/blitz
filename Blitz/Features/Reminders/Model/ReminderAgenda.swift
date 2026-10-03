import Foundation

/// Where an open reminder sits in My Reminders; declaration order is display order.
enum ReminderSection: Int, CaseIterable, Sendable {
    case overdue
    case today
    case tomorrow
    case upcoming
    case noDate

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .upcoming: "Upcoming"
        case .noDate: "No Due Date"
        }
    }
}

/// One section's reminders, in due order: a header and the rows beneath it.
struct ReminderGroup: Identifiable, Sendable {
    let section: ReminderSection
    let reminders: [ReminderItem]

    var id: ReminderSection { section }
}

/// The one place that orders and buckets open reminders, so the list and its selection agree.
enum ReminderAgenda {
    /// Soonest first and undated last; a day-only reminder leads the timed ones on its day.
    static func sorted(_ reminders: [ReminderItem], calendar: Calendar) -> [ReminderItem] {
        let keyed = reminders.map { ($0, $0.due?.date(in: calendar)) }
        return keyed.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case (let left?, let right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let order = lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title)
                return order == .orderedSame ? lhs.0.id < rhs.0.id : order == .orderedAscending
            }
        }
        .map(\.0)
    }

    static func section(
        of reminder: ReminderItem, now: Date, calendar: Calendar
    ) -> ReminderSection {
        guard let due = reminder.due else { return .noDate }
        if due.isOverdue(now: now, calendar: calendar) { return .overdue }
        switch due.dayOffset(now: now, calendar: calendar) {
        case 0: return .today
        case 1: return .tomorrow
        default: return .upcoming
        }
    }

    /// Buckets keep `sorted`'s order, so a day-only reminder today never splits the overdue run.
    static func grouping(
        _ reminders: [ReminderItem], now: Date, calendar: Calendar
    ) -> [ReminderGroup] {
        let buckets = Dictionary(grouping: sorted(reminders, calendar: calendar)) {
            section(of: $0, now: now, calendar: calendar)
        }
        return ReminderSection.allCases.compactMap { section in
            buckets[section].map { ReminderGroup(section: section, reminders: $0) }
        }
    }

    /// Title, notes and list name, so "groceries" finds everything on that list.
    static func matching(_ reminders: [ReminderItem], query: String) -> [ReminderItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return reminders }
        return reminders.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.listName.localizedCaseInsensitiveContains(query)
                || ($0.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}
