import Foundation

/// What a chat model may ask of the calendar, and how its calls and answers are spelled.
enum CalendarToolCatalog {
    static let origin = "Calendar"
    static let listEventsName = "calendar_list_events"
    static let createEventName = "calendar_create_event"
    /// A wider window would answer with more than one tool result can carry.
    static let maxSpanDays = 92
    static let maxEvents = 150
    static let maxNotesLength = 400
    static let defaultDurationMinutes = 30
    static let maxDurationMinutes = 14 * 24 * 60

    private typealias Invalid = AIToolArguments.Invalid

    enum Request: Equatable, Sendable {
        case list(DateInterval, query: String?)
        case create(NewEvent)
    }

    /// A create call, already checked; an all-day event's `end` is the midnight of its last day.
    struct NewEvent: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
    }

    static func handles(_ name: String) -> Bool {
        name == listEventsName || name == createEventName
    }

    /// Writing is offered only where the reader allowed it, so a read-only model never sees it.
    static func tools(canWrite: Bool, now: Date, calendar: Calendar) -> [AITool] {
        let now = AIToolDate.describeNow(now, calendar: calendar)
        let list = AITool(
            name: listEventsName,
            description: "List the events on the user's calendars from start to end, in the "
                + "user's local time. Now: \(now). At most \(maxSpanDays) days per call.",
            parameters: AIToolJSON.object(
                properties: [
                    "start": AIToolJSON.string(
                        "First day as YYYY-MM-DD, or a moment as YYYY-MM-DDTHH:MM."),
                    "end": AIToolJSON.string(
                        "Last day, inclusive, as YYYY-MM-DD, or an exact end as YYYY-MM-DDTHH:MM."),
                    "query": AIToolJSON.string(
                        "Optional text to find in the title, location, notes or calendar name.")
                ],
                required: ["start", "end"]),
            origin: origin, title: "List Events")
        guard canWrite else { return [list] }
        let create = AITool(
            name: createEventName,
            description: "Add an event to the user's default calendar, in the user's local "
                + "time. Now: \(now). The user sees it and confirms before it is saved.",
            parameters: AIToolJSON.object(
                properties: [
                    "title": AIToolJSON.string("What the event is called."),
                    "start": AIToolJSON.string(
                        "YYYY-MM-DDTHH:MM for a timed event, YYYY-MM-DD for an all-day one."),
                    "end": AIToolJSON.string(
                        "Optional. The end as YYYY-MM-DDTHH:MM, or an all-day event's last day."),
                    "durationMinutes": AIToolJSON.integer(
                        "Optional, for a timed event with no end. Default "
                            + "\(defaultDurationMinutes)."),
                    "location": AIToolJSON.string("Optional."),
                    "notes": AIToolJSON.string("Optional.")
                ],
                required: ["title", "start"]),
            origin: origin, title: "Create Event")
        return [list, create]
    }

    static func request(
        name: String, arguments: String, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        switch name {
        case listEventsName: return try listRequest(arguments, calendar: calendar)
        case createEventName: return .create(try newEvent(arguments, calendar: calendar))
        default: throw Invalid("There is no calendar tool named \u{201C}\(name)\u{201D}.")
        }
    }

    private static func listRequest(
        _ arguments: AIToolArguments, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> Request {
        guard let start = try arguments.date("start", calendar: calendar) else {
            throw Invalid("\u{201C}start\u{201D} is required.")
        }
        let end =
            try arguments.date("end", calendar: calendar)
            ?? AIToolDate(year: start.year, month: start.month, day: start.day)
        guard let from = start.date(in: calendar),
            let to = boundary(after: end, calendar: calendar), from < to
        else { throw Invalid("\u{201C}end\u{201D} must come after \u{201C}start\u{201D}.") }
        guard let limit = calendar.date(byAdding: .day, value: maxSpanDays, to: from), to <= limit
        else { throw Invalid("Ask for at most \(maxSpanDays) days at a time.") }
        return .list(DateInterval(start: from, end: to), query: arguments.string("query"))
    }

    /// An inclusive last day ends at the next midnight; an exact moment ends where it says.
    private static func boundary(after end: AIToolDate, calendar: Calendar) -> Date? {
        guard let date = end.date(in: calendar) else { return nil }
        guard end.time == nil else { return date }
        return calendar.date(byAdding: .day, value: 1, to: date)
    }

    private static func newEvent(
        _ arguments: AIToolArguments, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> NewEvent {
        let title = try arguments.requiredString("title")
        guard let start = try arguments.date("start", calendar: calendar),
            let startDate = start.date(in: calendar)
        else { throw Invalid("\u{201C}start\u{201D} is required.") }
        let end = try arguments.date("end", calendar: calendar)
        let endDate =
            start.time == nil
            ? try lastDay(of: end, after: startDate, calendar: calendar)
            : try timedEnd(
                end, after: startDate, minutes: arguments.int("durationMinutes"),
                calendar: calendar)
        return NewEvent(
            title: title, start: startDate, end: endDate, isAllDay: start.time == nil,
            location: arguments.string("location"), notes: arguments.string("notes"))
    }

    private static func lastDay(
        of end: AIToolDate?, after start: Date, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> Date {
        guard let end else { return start }
        guard end.time == nil, let date = end.date(in: calendar) else {
            throw Invalid("An all-day event takes \u{201C}end\u{201D} as YYYY-MM-DD.")
        }
        guard date >= start else {
            throw Invalid("\u{201C}end\u{201D} must not come before \u{201C}start\u{201D}.")
        }
        return date
    }

    private static func timedEnd(
        _ end: AIToolDate?, after start: Date, minutes: Int?, calendar: Calendar
    ) throws(AIToolArguments.Invalid) -> Date {
        let date: Date
        if let end {
            guard end.time != nil, let exact = end.date(in: calendar) else {
                throw Invalid("A timed event takes \u{201C}end\u{201D} as YYYY-MM-DDTHH:MM.")
            }
            date = exact
        } else {
            let minutes = minutes ?? defaultDurationMinutes
            guard (1...maxDurationMinutes).contains(minutes) else {
                throw Invalid(
                    "\u{201C}durationMinutes\u{201D} must be between 1 and \(maxDurationMinutes).")
            }
            date = start.addingTimeInterval(TimeInterval(minutes * 60))
        }
        guard date > start else {
            throw Invalid("\u{201C}end\u{201D} must come after \u{201C}start\u{201D}.")
        }
        return date
    }

    // MARK: - Answers

    /// What the model reads back: the window, then its events in start order, capped.
    static func render(
        _ events: [CalendarToolEvent], in interval: DateInterval, query: String?,
        calendar: Calendar
    ) -> String {
        let matched = matching(events, query: query).sorted {
            ($0.start, $0.title) < ($1.start, $1.title)
        }
        var answer: [String: JSONValue] = [
            "from": .string(stamp(interval.start, calendar: calendar)),
            "to": .string(stamp(interval.end, calendar: calendar)),
            "events": .array(matched.prefix(maxEvents).map { record(of: $0, calendar: calendar) })
        ]
        if matched.count > maxEvents {
            answer["omitted"] = .number(Double(matched.count - maxEvents))
        }
        return AIToolJSON.text(.object(answer))
    }

    /// Title, location, notes and calendar name, so "work" finds everything on that calendar.
    static func matching(_ events: [CalendarToolEvent], query: String?) -> [CalendarToolEvent] {
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return events
        }
        return events.filter { event in
            [event.title, event.calendarName, event.location, event.notes].contains {
                $0?.localizedCaseInsensitiveContains(query) == true
            }
        }
    }

    private static func record(of event: CalendarToolEvent, calendar: Calendar) -> JSONValue {
        var record: [String: JSONValue] = [
            "title": .string(event.title),
            "calendar": .string(event.calendarName),
            "start": .string(
                AIToolDate(date: event.start, includesTime: !event.isAllDay, calendar: calendar)
                    .text),
            "end": .string(endText(of: event, calendar: calendar))
        ]
        if event.isAllDay { record["allDay"] = .bool(true) }
        if event.isDeclined { record["declined"] = .bool(true) }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty
        {
            record["location"] = .string(location)
        }
        if let url = event.url { record["url"] = .string(url) }
        if let notes = event.notes.flatMap(MeetingDetails.plainText(fromNotes:)) {
            record["notes"] = .string(AIToolJSON.clipped(notes, to: maxNotesLength))
        }
        return .object(record)
    }

    /// An all-day event names its last day, whether EventKit ends it at 23:59:59 or at midnight.
    private static func endText(of event: CalendarToolEvent, calendar: Calendar) -> String {
        guard event.isAllDay else { return stamp(event.end, calendar: calendar) }
        let last = max(event.start, event.end.addingTimeInterval(-1))
        return AIToolDate(date: last, includesTime: false, calendar: calendar).text
    }

    private static func stamp(_ date: Date, calendar: Calendar) -> String {
        AIToolDate(date: date, includesTime: true, calendar: calendar).text
    }

    // MARK: - Confirmation

    /// The dialog's line under the title: when, on which calendar, and where if the model said.
    static func summary(of event: NewEvent, calendarName: String?, calendar: Calendar) -> String {
        let style = Date.FormatStyle(
            locale: calendar.locale ?? Locale(identifier: "en_US"), calendar: calendar,
            timeZone: calendar.timeZone)
        let day = style.weekday(.wide).month(.abbreviated).day()
        let clock = style.hour().minute()
        let when: String
        if event.isAllDay {
            when =
                calendar.isDate(event.start, inSameDayAs: event.end)
                ? "\(event.start.formatted(day)), all day"
                : "\(event.start.formatted(day)) \u{2013} \(event.end.formatted(day)), all day"
        } else if calendar.isDate(event.start, inSameDayAs: event.end) {
            when =
                "\(event.start.formatted(day)), \(event.start.formatted(clock)) \u{2013} "
                + event.end.formatted(clock)
        } else {
            when =
                "\(event.start.formatted(day)), \(event.start.formatted(clock)) \u{2013} "
                + "\(event.end.formatted(day)), \(event.end.formatted(clock))"
        }
        let line = calendarName.map { "\(when) \u{00B7} \($0)" } ?? when
        guard let location = event.location else { return line }
        return "\(line)\n\(location)"
    }
}
