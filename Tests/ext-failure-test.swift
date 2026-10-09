import Foundation

/// What a failed command shows and copies, the console it keeps, and which actions ↵ and ⌘↵ fire.
@main
@MainActor
struct ExtensionFailureTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        } else {
            print("PASS  \(message)")
        }
    }

    static func main() {
        failure()
        console()
        actionKeys()

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All extension failure checks passed")
    }

    static func failure() {
        let stacked = ExtensionFailure(message: "TypeError: x is undefined\nrender@cmd.js:1\nrun@cmd.js:9")
        expect(stacked.headline == "TypeError: x is undefined", "the headline is the first line")
        expect(stacked.detail == "render@cmd.js:1\nrun@cmd.js:9", "the stack is the detail")
        expect(stacked.reason == .error, "a thrown error is retried, not configured")

        let bare = ExtensionFailure(message: "Network down", reason: .missingPreferences)
        expect(bare.headline == "Network down" && bare.detail == nil, "one line has no detail")
        expect(bare.report(console: []) == "Network down", "nothing logged copies the message alone")
        expect(
            bare.report(console: ["[log] a", "[error] b"])
                == "Network down\n\nConsole:\n[log] a\n[error] b",
            "the report appends what the command logged")
        expect(
            !ExtensionFailure.unsupportedRoot("Chart").message.contains("docs"),
            "an unsupported root says so without pointing at a repository file")
    }

    static func console() {
        var log = ExtensionConsoleLog(capacity: 3)
        for index in 1...5 { log.append(level: "log", message: "line \(index)") }
        expect(log.lines == ["[log] line 3", "[log] line 4", "[log] line 5"], "only the newest lines stay")

        log.append(level: "error", message: String(repeating: "x", count: 5_000))
        expect(
            log.lines.last?.count == "[error] ".count + ExtensionConsoleLog.lineLimit + 1,
            "an enormous line is cut, not kept whole")

        log.clear()
        expect(log.lines.isEmpty, "a new launch starts empty")
        expect(ExtensionConsoleLog(capacity: 0).capacity == 1, "a capacity always holds a line")
    }

    static func actionKeys() {
        typealias Slot = ExtensionActionKeys.Slot
        let plain = [Slot(), Slot(ownCaps: "⌘D"), Slot(ownCaps: "⌘E")]
        expect(ExtensionActionKeys.secondary(in: plain, isForm: false) == 1, "⌘↵ is the second action")
        expect(
            ExtensionActionKeys.caps(for: plain, isForm: false) == ["↵", "⌘↵", "⌘E"],
            "the first two rows draw ↵ and ⌘↵, the rest their own shortcut")

        let claimed = [Slot(), Slot(ownCaps: "⌘D"), Slot(declaresCommandReturn: true, ownCaps: "⌘↵")]
        expect(
            ExtensionActionKeys.secondary(in: claimed, isForm: false) == 2,
            "an action declaring ⌘↵ outranks the second one")
        expect(
            ExtensionActionKeys.caps(for: claimed, isForm: false) == ["↵", "⌘D", "⌘↵"],
            "the second action keeps its own shortcut once ⌘↵ is claimed")

        expect(ExtensionActionKeys.secondary(in: plain, isForm: true) == nil, "a form's ⌘↵ submits")
        expect(
            ExtensionActionKeys.caps(for: plain, isForm: true) == ["⌘↵", "⌘D", "⌘E"],
            "a form draws ⌘↵ on its submit action only")

        expect(ExtensionActionKeys.secondary(in: [Slot()], isForm: false) == nil, "one action has no ⌘↵")
        let nested = [Slot(isInSubmenu: true), Slot(isInSubmenu: true)]
        expect(
            ExtensionActionKeys.secondary(in: nested, isForm: false) == nil
                && ExtensionActionKeys.caps(for: nested, isForm: false) == [nil, nil],
            "a submenu's leaves fire from the panel, so they draw no ↵ or ⌘↵")
    }
}
