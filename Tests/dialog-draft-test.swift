import Foundation

@main
@MainActor
struct FormDraftMemoryTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        let blank = EventDraft()
        var typed = EventDraft()
        typed.title = "Standup"
        typed.durationMinutes = 15

        let fresh = FormDraftMemory<EventDraft>()
        expect(fresh.draft(openingOn: blank) == blank, "nothing kept opens on the opening draft")

        let clickedAway = FormDraftMemory<EventDraft>()
        clickedAway.settle(typed, openedOn: blank, clickedAway: true)
        expect(clickedAway.draft(openingOn: blank) == typed, "a click-away keeps the edit")
        expect(
            clickedAway.draft(openingOn: blank) == typed,
            "reading the kept edit leaves it kept, so a refused reopen loses nothing")

        let escaped = FormDraftMemory<EventDraft>()
        escaped.settle(typed, openedOn: blank, clickedAway: true)
        escaped.settle(typed, openedOn: blank, clickedAway: false)
        expect(escaped.draft(openingOn: blank) == blank, "Escape or Cancel drops a kept edit")

        let submitted = FormDraftMemory<EventDraft>()
        submitted.settle(typed, openedOn: blank, clickedAway: false)
        expect(submitted.draft(openingOn: blank) == blank, "a submitted form keeps nothing")

        let untouched = FormDraftMemory<EventDraft>()
        untouched.settle(typed, openedOn: blank, clickedAway: true)
        untouched.settle(blank, openedOn: blank, clickedAway: true)
        expect(untouched.draft(openingOn: blank) == blank, "an unedited click-away keeps nothing")

        var other = EventDraft()
        other.title = "Retro"
        let subject = FormDraftMemory<EventDraft>()
        subject.settle(typed, openedOn: blank, clickedAway: true)
        expect(
            subject.draft(openingOn: other) == other,
            "an edit kept for one subject never opens on another")
        expect(
            subject.draft(openingOn: blank) == typed,
            "opening another subject leaves the kept edit for its own")
        subject.settle(other, openedOn: other, clickedAway: false)
        expect(
            subject.draft(openingOn: blank) == typed,
            "cancelling another subject leaves the kept edit for its own")
        subject.settle(other, openedOn: other, clickedAway: true)
        expect(
            subject.draft(openingOn: blank) == typed,
            "an unedited click-away on another subject leaves the kept edit alone")
        var retitled = other
        retitled.title = "Retro notes"
        subject.settle(retitled, openedOn: other, clickedAway: true)
        expect(
            subject.draft(openingOn: other) == retitled, "one edit is kept: the newest replaces it")
        expect(subject.draft(openingOn: blank) == blank, "so the older subject opens fresh again")

        var further = typed
        further.startOffsetMinutes = 30
        let reopened = FormDraftMemory<EventDraft>()
        reopened.settle(typed, openedOn: blank, clickedAway: true)
        reopened.settle(further, openedOn: blank, clickedAway: true)
        expect(
            reopened.draft(openingOn: blank) == further, "a second click-away keeps the newer edit")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
