import Foundation

/// A day, and a clock time when one was given, spelled the way tool arguments and results are.
struct AIToolDate: Hashable, Sendable {
    struct Time: Hashable, Sendable {
        let hour: Int
        let minute: Int
    }

    let year: Int
    let month: Int
    let day: Int
    /// Nil for a whole day.
    let time: Time?

    init(year: Int, month: Int, day: Int, time: Time? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.time = time
    }

    init(date: Date, includesTime: Bool, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let time = Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        self.init(
            year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1,
            time: includesTime ? time : nil)
    }

    /// `YYYY-MM-DD`, optionally followed by `THH:MM`; seconds and a zone suffix are ignored.
    init?(parsing text: String, calendar: Calendar) {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "T" || $0 == " " })
        guard (1...2).contains(parts.count) else { return nil }
        let date = parts[0].split(separator: "-").map { Int($0) }
        guard date.count == 3, let year = date[0], let month = date[1], let day = date[2] else {
            return nil
        }
        var time: Time?
        if parts.count == 2 {
            let clock = parts[1].prefix(5).split(separator: ":").map { Int($0) }
            guard clock.count == 2, let hour = clock[0], let minute = clock[1] else { return nil }
            time = Time(hour: hour, minute: minute)
        }
        self.init(year: year, month: month, day: day, time: time)
        guard isValid(in: calendar) else { return nil }
    }

    var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: time?.hour, minute: time?.minute)
    }

    /// The moment it names; a whole day counts from its midnight.
    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: components)
    }

    /// False for a day the calendar would roll over, such as February 30 or 25:00.
    func isValid(in calendar: Calendar) -> Bool {
        guard let date = date(in: calendar) else { return false }
        return AIToolDate(date: date, includesTime: time != nil, calendar: calendar) == self
    }

    var text: String {
        let day = String(format: "%04d-%02d-%02d", year, month, self.day)
        guard let time else { return day }
        return day + String(format: "T%02d:%02d", time.hour, time.minute)
    }

    /// A model cannot know the date, so every tool that takes one is told it, weekday first.
    static func describeNow(_ now: Date, calendar: Calendar) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = names[(calendar.component(.weekday, from: now) - 1 + 7) % 7]
        let moment = AIToolDate(date: now, includesTime: true, calendar: calendar).text
        return "\(weekday) \(moment.replacing("T", with: " ")), time zone "
            + calendar.timeZone.identifier
    }
}
