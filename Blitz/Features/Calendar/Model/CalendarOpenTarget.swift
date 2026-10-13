import Foundation

/// Where a calendar's meetings open: per calendar, since an iCloud one can live in Outlook too.
enum CalendarOpenTarget: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case outlook
    case outlookWeb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .outlook: return "Outlook"
        case .outlookWeb: return "Outlook on the web"
        }
    }

    var actionTitle: String {
        switch self {
        case .calendar: return "Open in Calendar"
        case .outlook, .outlookWeb: return "Open in Outlook"
        }
    }

    /// Outlook links only reach a day: EventKit never exposes the Exchange item's own ID.
    func url(for start: Date, calendar: Calendar) -> URL? {
        let day = calendar.dateComponents([.year, .month, .day], from: start)
        guard let year = day.year, let month = day.month, let date = day.day else { return nil }
        switch self {
        case .calendar:
            return nil
        case .outlook:
            let stamp = String(format: "%04d-%02d-%02d", year, month, date)
            return URL(string: "ms-outlook://events?view=day&date=\(stamp)")
        case .outlookWeb:
            return URL(
                string: "https://outlook.office.com/calendar/view/day/\(year)/\(month)/\(date)")
        }
    }
}
