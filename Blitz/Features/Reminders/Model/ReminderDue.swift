import Foundation

/// When a reminder falls due: a day, and a time only when one was set. EventKit's components, flat.
struct ReminderDue: Hashable, Sendable {
    struct Time: Hashable, Sendable {
        let hour: Int
        let minute: Int
    }

    let year: Int
    let month: Int
    let day: Int
    /// Nil for a reminder due on a day rather than at a moment.
    let time: Time?

    init(year: Int, month: Int, day: Int, time: Time? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.time = time
    }

    init?(components: DateComponents) {
        guard let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        let time = components.hour.map { Time(hour: $0, minute: components.minute ?? 0) }
        self.init(year: year, month: month, day: day, time: time)
    }

    init(_ date: AIToolDate) {
        self.init(
            year: date.year, month: date.month, day: date.day,
            time: date.time.map { Time(hour: $0.hour, minute: $0.minute) })
    }

    init(date: Date, includesTime: Bool, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let time = Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        self.init(
            year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1,
            time: includesTime ? time : nil)
    }

    var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: time?.hour, minute: time?.minute)
    }

    /// The moment it falls due; a day-only reminder counts from that day's midnight.
    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: components)
    }

    /// False for a day the calendar would roll over, such as February 30 or 25:00.
    func isValid(in calendar: Calendar) -> Bool {
        guard let date = date(in: calendar) else { return false }
        return ReminderDue(date: date, includesTime: time != nil, calendar: calendar) == self
    }

    /// A day-only reminder is overdue only once its whole day has passed.
    func isOverdue(now: Date, calendar: Calendar) -> Bool {
        guard let date = date(in: calendar) else { return false }
        return time == nil ? date < calendar.startOfDay(for: now) : date < now
    }

    /// Whole days from today, negative once the day has passed.
    func dayOffset(now: Date, calendar: Calendar) -> Int? {
        let day = calendar.date(from: DateComponents(year: year, month: month, day: self.day))
        guard let day else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day
    }

    /// `Today`, `Tomorrow`, a weekday within the week, or the date; then the time when it has one.
    func title(now: Date, calendar: Calendar) -> String {
        guard let date = date(in: calendar) else { return "" }
        let style = Self.formatStyle(of: calendar)
        let dayTitle: String =
            switch dayOffset(now: now, calendar: calendar) {
            case -1: "Yesterday"
            case 0: "Today"
            case 1: "Tomorrow"
            case let offset? where (2...6).contains(offset): date.formatted(style.weekday(.wide))
            default:
                calendar.component(.year, from: now) == year
                    ? date.formatted(style.month(.abbreviated).day())
                    : date.formatted(style.month(.abbreviated).day().year())
            }
        guard time != nil else { return dayTitle }
        return "\(dayTitle), \(date.formatted(style.hour().minute()))"
    }

    /// The calendar's own locale and zone, so a test calendar formats exactly like a user's.
    private static func formatStyle(of calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(
            locale: calendar.locale ?? Locale(identifier: "en_US"), calendar: calendar,
            timeZone: calendar.timeZone)
    }
}
