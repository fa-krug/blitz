import Foundation

/// Smart Reminder's whole contract with a model: what it is told, and how its reply is read.
enum SmartReminderPrompt {
    /// One short JSON object; the on-device window counts this against the prompt.
    static let maxOutputTokens = 256

    /// The model cannot know today's date, so every relative day is resolved against these.
    static func instructions(now: Date, calendar: Calendar) -> String {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return """
            You turn a note someone typed into one reminder for their to-do list.

            Reply with one JSON object and nothing else, no prose and no code fence:
            {"title": "…", "due": "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM" or null, "notes": "…" or null}

            title: a short task to act on, starting with a verb, in the language of the note. \
            Keep every name, and leave the date and time out of it.
            due: when it is due, resolved against the dates below. Add a time only when the note \
            names one: morning is 09:00, noon 12:00, afternoon 15:00, evening 18:00, \
            tonight 20:00. null when the note names no day.
            notes: any detail the title leaves out, otherwise null.

            Example: "Greg wants tomorrow a cake" becomes \
            {"title": "Give Greg a cake", "due": "\(day(tomorrow, calendar))", "notes": null}

            Now: \(weekday(now, calendar)) \(day(now, calendar)) \(clock(now, calendar)), \
            time zone \(calendar.timeZone.identifier).
            The next seven days: \(upcomingDays(after: now, calendar: calendar)).
            """
    }

    /// Nil when the reply holds no title; a due date it cannot read is dropped, never guessed.
    static func draft(from reply: String, calendar: Calendar) -> ReminderDraft? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
            open < close,
            let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[open...close].utf8))
        else { return nil }
        let draft = ReminderDraft(
            title: decoded.title ?? "", notes: decoded.notes ?? "",
            due: decoded.due.flatMap { due(from: $0, calendar: calendar) })
        return draft.isValid ? draft : nil
    }

    /// `YYYY-MM-DD`, optionally followed by `THH:MM`; the same spelling every Blitz tool reads.
    static func due(from text: String, calendar: Calendar) -> ReminderDue? {
        AIToolDate(parsing: text, calendar: calendar).map(ReminderDue.init)
    }

    /// Lenient field by field: a model that writes a number where a string goes loses that field.
    private struct Reply: Decodable {
        let title: String?
        let due: String?
        let notes: String?

        private enum CodingKeys: String, CodingKey {
            case title, due, notes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            due = try? container.decodeIfPresent(String.self, forKey: .due)
            notes = try? container.decodeIfPresent(String.self, forKey: .notes)
        }
    }

    // MARK: - Dates, spelled the way the reply must spell them

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// English whatever the locale, so the names match the English the instructions are written in.
    private static func weekday(_ date: Date, _ calendar: Calendar) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
    }

    private static func upcomingDays(after now: Date, calendar: Calendar) -> String {
        (1...7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: now).map {
                "\(weekday($0, calendar)) \(day($0, calendar))"
            }
        }
        .joined(separator: ", ")
    }
}
