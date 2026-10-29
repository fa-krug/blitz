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
            {"title": "…", "when": "…" or null, "due": "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM" or null, \
            "notes": "…" or null}

            title: a short task to act on, starting with a verb, in the language of the note. \
            Keep every name, fix obvious misspellings, and leave the date and time out of it.
            when: the exact words of the note that name a day or time, copied letter for letter, \
            or null when it names none.
            due: only the day or time those words name, resolved against the dates below. \
            Add a time only when the note names one: morning is 09:00, noon 12:00, \
            afternoon 15:00, evening 18:00, tonight 20:00; a time with no day is today. \
            When the note names no day and no time, due is null. Never guess one, and never \
            default to today or tomorrow: a reminder without a due date is a valid answer.
            notes: any detail of the note the title leaves out, otherwise null. \
            Never add anything the note does not say.

            Example: "Greg wants tomorrow a cake" becomes \
            {"title": "Give Greg a cake", "when": "tomorrow", "due": "\(day(tomorrow, calendar))", \
            "notes": null}
            Example: "ask Anna about the sildes" becomes \
            {"title": "Ask Anna about the slides", "when": null, "due": null, "notes": null}

            Now: \(weekday(now, calendar)) \(day(now, calendar)) \(clock(now, calendar)), \
            time zone \(calendar.timeZone.identifier).
            The next seven days: \(upcomingDays(after: now, calendar: calendar)).
            """
    }

    /// Nil when the reply holds no title; a due date it cannot read or ground is dropped.
    static func draft(
        from reply: String, note: String, now: Date, calendar: Calendar
    ) -> ReminderDraft? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
            open < close,
            let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[open...close].utf8))
        else { return nil }
        let when = groundedWhen(decoded.when, in: note)
        let draft = ReminderDraft(
            title: title(decoded.title ?? "", without: when), notes: decoded.notes ?? "",
            due: when.flatMap {
                corrected(
                    decoded.due.flatMap { due(from: $0, calendar: calendar) }, when: $0, now: now,
                    calendar: calendar)
            })
        return draft.isValid ? draft : nil
    }

    /// Small models echo the prompt's own `Now` as a due date, so a date must quote the note.
    static func groundedWhen(_ when: String?, in note: String) -> String? {
        guard let when = when?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty,
            note.range(of: when, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        else { return nil }
        return when
    }

    /// `YYYY-MM-DD`, optionally followed by `THH:MM`; the same spelling every Blitz tool reads.
    static func due(from text: String, calendar: Calendar) -> ReminderDue? {
        AIToolDate(parsing: text, calendar: calendar).map(ReminderDue.init)
    }

    /// Lenient field by field: a model that writes a number where a string goes loses that field.
    private struct Reply: Decodable {
        let title: String?
        let when: String?
        let due: String?
        let notes: String?

        private enum CodingKeys: String, CodingKey {
            case title, when, due, notes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            when = try? container.decodeIfPresent(String.self, forKey: .when)
            due = try? container.decodeIfPresent(String.self, forKey: .due)
            notes = try? container.decodeIfPresent(String.self, forKey: .notes)
        }
    }

    // MARK: - Overruling the model

    /// A small model miscounts days and copies `Now`'s clock, so the quoted words overrule it.
    private static func corrected(
        _ due: ReminderDue?, when: String, now: Date, calendar: Calendar
    ) -> ReminderDue? {
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let echoesNow =
            due?.time == ReminderDue.Time(hour: clock.hour ?? -1, minute: clock.minute ?? -1)
            && !when.contains(where: \.isNumber)
        let time = echoesNow ? nil : due?.time
        let named = dayOffset(named: when, now: now, calendar: calendar).flatMap {
            calendar.date(byAdding: .day, value: $0, to: now)
        }
        guard let named else {
            return due.map { ReminderDue(year: $0.year, month: $0.month, day: $0.day, time: time) }
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: named)
        return ReminderDue(
            year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1, time: time)
    }

    /// Days from today for the words that name one outright; nil leaves the model's answer.
    static func dayOffset(named when: String, now: Date, calendar: Calendar) -> Int? {
        let folded = when.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = Set(folded.split { !$0.isLetter }.map(String.init))
        if folded.contains("day after tomorrow") || words.contains("ubermorgen") { return 2 }
        // Before `morgen`: German `heute morgen` is this morning, not tomorrow.
        if !words.isDisjoint(with: ["today", "tonight", "heute"]) { return 0 }
        if !words.isDisjoint(with: ["tomorrow", "morgen"]) { return 1 }
        guard let weekday = words.lazy.compactMap({ weekdays[$0] }).first else { return nil }
        let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
        return ahead == 0 ? 7 : ahead
    }

    /// `Calendar` weekday numbers, Sunday first, in the two languages Blitz is typed in most.
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6,
        "saturday": 7, "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5,
        "freitag": 6, "samstag": 7, "sonnabend": 7
    ]

    /// The instructions keep the date out of the title, but a small model copies the note whole.
    static func title(_ title: String, without when: String?) -> String {
        guard let when else { return title }
        let pattern =
            #"(?:(?<!\w)(?:on|at|by|am|um)\s+)?(?<!\w)"#
            + NSRegularExpression.escapedPattern(for: when) + #"(?![\w'’])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return title }
        let stripped = regex.stringByReplacingMatches(
            in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        let words = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-").union(.whitespaces))
        guard let first = words.first else { return title }
        guard title.first?.isUppercase == true else { return words }
        return first.uppercased() + words.dropFirst()
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
