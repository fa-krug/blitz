// Reminder due dates, ordering and sections, and reading a Smart Reminder reply.
import Foundation

@main
@MainActor
struct RemindersTests {
    static var failures = 0
    static var passes = 0

    /// Injected everywhere a date is built, so no assertion depends on the machine's zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Saturday, October 3 2026, 14:00 UTC.
    static let now = calendar.date(
        from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 0))!

    static func main() {
        dueComponents()
        dueValidity()
        overdue()
        dueTitles()
        ordering()
        sections()
        matching()
        drafts()
        replies()
        replyDates()
        instructions()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Due dates

    static func dueComponents() {
        let dayOnly = ReminderDue(components: DateComponents(year: 2026, month: 10, day: 4))
        expect(dayOnly?.time == nil, "components with no hour are a day-only reminder")
        let timed = ReminderDue(
            components: DateComponents(year: 2026, month: 10, day: 4, hour: 9))
        expect(timed?.time == ReminderDue.Time(hour: 9, minute: 0), "a missing minute reads as :00")
        expect(
            ReminderDue(components: DateComponents(year: 2026, month: 10)) == nil,
            "a reminder with no day has no due date")
        expect(
            ReminderDue(date: now, includesTime: false, calendar: calendar)
                == ReminderDue(year: 2026, month: 10, day: 3),
            "a date read without its time keeps only the day")
        expect(
            ReminderDue(date: now, includesTime: true, calendar: calendar).time
                == ReminderDue.Time(hour: 14, minute: 0),
            "and with it keeps the clock")
        let round = ReminderDue(year: 2026, month: 12, day: 24, time: .init(hour: 18, minute: 30))
        expect(ReminderDue(components: round.components) == round, "components round-trip")
    }

    static func dueValidity() {
        expect(ReminderDue(year: 2026, month: 2, day: 28).isValid(in: calendar), "Feb 28 is a day")
        expect(!ReminderDue(year: 2026, month: 2, day: 30).isValid(in: calendar), "Feb 30 is not")
        expect(
            !ReminderDue(year: 2026, month: 10, day: 3, time: .init(hour: 25, minute: 0))
                .isValid(in: calendar),
            "25:00 is not a time")
        expect(ReminderDue(year: 2028, month: 2, day: 29).isValid(in: calendar), "a leap day is")
    }

    static func overdue() {
        let earlierToday = ReminderDue(year: 2026, month: 10, day: 3, time: .init(hour: 9, minute: 0))
        expect(earlierToday.isOverdue(now: now, calendar: calendar), "a passed time today is overdue")
        let laterToday = ReminderDue(year: 2026, month: 10, day: 3, time: .init(hour: 18, minute: 0))
        expect(!laterToday.isOverdue(now: now, calendar: calendar), "a later time today is not")
        expect(
            !ReminderDue(year: 2026, month: 10, day: 3).isOverdue(now: now, calendar: calendar),
            "a day-only reminder is not overdue on its own day")
        expect(
            ReminderDue(year: 2026, month: 10, day: 2).isOverdue(now: now, calendar: calendar),
            "but is the day after")
    }

    static func dueTitles() {
        func title(_ day: Int, month: Int = 10, year: Int = 2026, time: ReminderDue.Time? = nil)
            -> String
        {
            ReminderDue(year: year, month: month, day: day, time: time)
                .title(now: now, calendar: calendar)
        }
        expect(title(3) == "Today", "today reads as Today")
        expect(title(4) == "Tomorrow", "tomorrow reads as Tomorrow")
        expect(title(2) == "Yesterday", "yesterday reads as Yesterday")
        expect(title(9) == "Friday", "a day within the week reads as its weekday — got \(title(9))")
        expect(title(10) == "Oct 10", "a week out reads as a date — got \(title(10))")
        expect(title(1) == "Oct 1", "so does a day overdue by more than one")
        expect(
            title(5, month: 1, year: 2027) == "Jan 5, 2027",
            "another year names the year — got \(title(5, month: 1, year: 2027))")
        let timed = title(4, time: .init(hour: 9, minute: 30))
        expect(
            timed.hasPrefix("Tomorrow, ") && timed.contains("9:30"),
            "a timed reminder adds its clock — got \(timed)")
    }

    // MARK: - Ordering and sections

    static func ordering() {
        let items = [
            item("undated-b", title: "b"),
            item("later", due: .init(year: 2026, month: 10, day: 9)),
            item("undated-a", title: "a"),
            item("timed", due: .init(year: 2026, month: 10, day: 4, time: .init(hour: 8, minute: 0))),
            item("day", due: .init(year: 2026, month: 10, day: 4))
        ]
        let order = ReminderAgenda.sorted(items, calendar: calendar).map(\.id)
        expect(
            order == ["day", "timed", "later", "undated-a", "undated-b"],
            "soonest first, a day-only reminder leads its day, undated last by title — got \(order)")
    }

    static func sections() {
        let items = [
            item("today-day", due: .init(year: 2026, month: 10, day: 3)),
            item("passed", due: .init(year: 2026, month: 10, day: 3, time: .init(hour: 8, minute: 0))),
            item("yesterday", due: .init(year: 2026, month: 10, day: 2)),
            item("tonight", due: .init(year: 2026, month: 10, day: 3, time: .init(hour: 20, minute: 0))),
            item("tomorrow", due: .init(year: 2026, month: 10, day: 4)),
            item("next-week", due: .init(year: 2026, month: 10, day: 12)),
            item("someday")
        ]
        let groups = ReminderAgenda.grouping(items, now: now, calendar: calendar)
        expect(
            groups.map(\.section) == [.overdue, .today, .tomorrow, .upcoming, .noDate],
            "sections come in display order")
        expect(
            groups.first?.reminders.map(\.id) == ["yesterday", "passed"],
            "overdue keeps due order even with a day-only reminder today sorting between")
        expect(
            groups.dropFirst().first?.reminders.map(\.id) == ["today-day", "tonight"],
            "today holds the day-only reminder and the time still to come")
        expect(
            ReminderAgenda.grouping([item("only")], now: now, calendar: calendar).map(\.section)
                == [.noDate],
            "an empty section is left out")
    }

    static func matching() {
        let items = [
            item("cake", title: "Give Greg a cake"),
            item("milk", title: "Milk", list: "Groceries"),
            item("call", title: "Call", notes: "about the cake order")
        ]
        let found = { ReminderAgenda.matching(items, query: $0).map(\.id) }
        expect(found("CAKE") == ["cake", "call"], "the query matches titles and notes alike")
        expect(found("grocer") == ["milk"], "and the list a reminder is on")
        expect(found("  ") == ["cake", "milk", "call"], "a blank query keeps everything")
    }

    // MARK: - Drafts

    static func drafts() {
        expect(!ReminderDraft(title: "  \n").isValid, "a blank title cannot be written")
        expect(ReminderDraft(title: " Milk ").trimmedTitle == "Milk", "the title is trimmed")
        expect(ReminderDraft(title: "x", notes: "  ").trimmedNotes == nil, "blank notes clear")
        let editing = ReminderDraft(editing: item("e", title: "Edit me", notes: "n"))
        expect(
            editing.title == "Edit me" && editing.notes == "n" && editing.due == nil,
            "an edit starts from the reminder as it is")
    }

    // MARK: - Smart Reminder replies

    static func replies() {
        let plain = SmartReminderPrompt.draft(
            from: #"{"title": "Give Greg a cake", "due": "2026-10-04", "notes": null}"#,
            calendar: calendar)
        expect(plain?.title == "Give Greg a cake", "the title is read")
        expect(plain?.due == ReminderDue(year: 2026, month: 10, day: 4), "and the day it is due")
        expect(plain?.trimmedNotes == nil, "a null note stays empty")

        let fenced = SmartReminderPrompt.draft(
            from: "Sure!\n```json\n{\"title\": \"Call mum\", \"due\": null}\n```", calendar: calendar)
        expect(fenced?.title == "Call mum", "prose and a code fence around the object are ignored")
        expect(fenced?.due == nil, "a null due date means no due date")

        let timed = SmartReminderPrompt.draft(
            from: #"{"title": "Gym", "due": "2026-10-05T18:00", "notes": "bring towel"}"#,
            calendar: calendar)
        expect(
            timed?.due == ReminderDue(year: 2026, month: 10, day: 5, time: .init(hour: 18, minute: 0)),
            "a time rides along when the reply gives one")
        expect(timed?.notes == "bring towel", "and so do notes")

        let numericDue = SmartReminderPrompt.draft(
            from: #"{"title": "Pay rent", "due": 20261005}"#, calendar: calendar)
        expect(
            numericDue?.title == "Pay rent" && numericDue?.due == nil,
            "a due date of the wrong type is dropped, not the whole reminder")
        expect(
            SmartReminderPrompt.draft(from: #"{"title": "  ", "due": "2026-10-04"}"#, calendar: calendar)
                == nil,
            "a reply with no title is no reminder")
        expect(
            SmartReminderPrompt.draft(from: "I can't help with that.", calendar: calendar) == nil,
            "a refusal is no reminder")
    }

    static func replyDates() {
        let due = { SmartReminderPrompt.due(from: $0, calendar: calendar) }
        expect(due("2026-10-04") == ReminderDue(year: 2026, month: 10, day: 4), "a bare day reads")
        expect(
            due("2026-10-04 07:05") == ReminderDue(
                year: 2026, month: 10, day: 4, time: .init(hour: 7, minute: 5)),
            "a space may separate the day from the time")
        expect(
            due("2026-10-04T07:05:00Z")?.time == ReminderDue.Time(hour: 7, minute: 5),
            "seconds and a zone suffix are ignored")
        expect(due("2026-02-30") == nil, "an impossible day is dropped")
        expect(due("tomorrow") == nil, "words are not a date")
        expect(due("2026-10-04T7") == nil, "nor is an hour with no minute")
    }

    static func instructions() {
        let text = SmartReminderPrompt.instructions(now: now, calendar: calendar)
        expect(text.contains("Saturday 2026-10-03 14:00"), "the prompt names now, weekday first")
        expect(
            text.contains("time zone \(calendar.timeZone.identifier)"), "and the zone it is in")
        expect(
            text.contains("Sunday 2026-10-04") && text.contains("Saturday 2026-10-10"),
            "and the seven days ahead, so a weekday resolves without arithmetic")
        expect(
            text.contains(#""due": "2026-10-04""#),
            "the worked example's tomorrow is the real tomorrow")
    }

    // MARK: - Helpers

    static func item(
        _ id: String, title: String? = nil, notes: String? = nil, due: ReminderDue? = nil,
        list: String = "Reminders"
    ) -> ReminderItem {
        ReminderItem(
            id: id, title: title ?? id, notes: notes, due: due, listID: list, listName: list,
            listColor: nil)
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}
