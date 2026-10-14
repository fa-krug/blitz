import Foundation

@main
struct AgentWaitTests {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // MARK: What a turn waits on

        check(
            "a turn that is not running waits on nobody, whatever is left open",
            AgentWait.of(isStreaming: false, pendingApprovals: 2, hasQuestion: true) == nil)
        check(
            "a running turn that asks nothing is not waiting",
            AgentWait.of(isStreaming: true, pendingApprovals: 0, hasQuestion: false) == nil)
        check(
            "an open Ask is a wait for approval",
            AgentWait.of(isStreaming: true, pendingApprovals: 1, hasQuestion: false) == .approval)
        check(
            "a pending question is a wait for an answer",
            AgentWait.of(isStreaming: true, pendingApprovals: 0, hasQuestion: true) == .answer)
        check(
            "an approval outranks a question, since its dialog comes first",
            AgentWait.of(isStreaming: true, pendingApprovals: 1, hasQuestion: true) == .approval)
        check(
            "each wait has its own badge",
            AgentWait.approval.symbol == "hand.raised.fill"
                && AgentWait.answer.symbol == "questionmark.bubble.fill")
        check(
            "and says what it waits for",
            AgentWait.approval.label == "Waiting for approval"
                && AgentWait.answer.label == "Waiting for an answer")

        // MARK: Approvals held off screen

        var approvals = AgentApprovals<String>()
        let first = approvals.begin()
        let second = approvals.begin()
        check("each request is pending until it ends", approvals.count == 2)
        check("nothing is held before it asks to be", !approvals.hasHeld)
        check("a pending request can be held", approvals.hold(first, "first"))
        check("the same request is never held twice", !approvals.hold(first, "again"))
        check("a second is held beside it", approvals.hold(second, "second"))
        check("coming on screen lets every held one go, oldest first",
            approvals.release() == ["first", "second"])
        check("and holds nothing after", !approvals.hasHeld && approvals.release().isEmpty)
        check("a released request is still pending until its dialog closes", approvals.count == 2)
        check("its end hands back no waiter, since none is held", approvals.end(first) == nil)
        check("an ended request is no longer pending", !approvals.isPending(first))
        check("an ended request cannot be held", !approvals.hold(first, "late"))

        _ = approvals.hold(second, "held")
        check("ending a held request hands its waiter back to be told no",
            approvals.end(second) == "held")
        check("and leaves nothing open", approvals.count == 0 && !approvals.hasHeld)

        let third = approvals.begin()
        let fourth = approvals.begin()
        _ = approvals.hold(third, "third")
        _ = approvals.hold(fourth, "fourth")
        check("a cancelled task takes back only its own waiter", approvals.unhold(third) == "third")
        check("which is then gone", approvals.unhold(third) == nil)
        check("Stop ends every request and hands back the rest", approvals.endAll() == ["fourth"])
        check(
            "leaving nothing pending, held or to hand back twice",
            approvals.count == 0 && !approvals.isPending(fourth) && approvals.endAll().isEmpty)

        // MARK: On screen

        func presence(
            window: Bool = false, active: Bool = false, palette: Bool = false, quickAI: Bool = false
        ) -> ChatPresence {
            ChatPresence(
                windowVisible: window, appActive: active, paletteVisible: palette,
                paletteOnQuickAI: quickAI)
        }
        check("the window in front shows its chat", presence(window: true, active: true).shows(.window))
        check(
            "a visible window behind another app does not",
            !presence(window: true, active: false).shows(.window))
        check("Blitz active with the window closed does not", !presence(active: true).shows(.window))
        check(
            "the palette on Quick AI shows Quick AI's chat",
            presence(palette: true, quickAI: true).shows(.quickAI))
        check(
            "the palette on another screen does not",
            !presence(palette: true, quickAI: false).shows(.quickAI))
        check("a hidden palette does not", !presence(quickAI: true).shows(.quickAI))
        check(
            "one surface in front never shows the other's chat",
            !presence(window: true, active: true).shows(.quickAI)
                && !presence(palette: true, quickAI: true).shows(.window))
        check(
            "a chat no surface holds is never on screen",
            !presence(window: true, active: true, palette: true, quickAI: true).shows(nil))

        // MARK: Episodes

        let a = UUID()
        let b = UUID()
        let started = AgentWaitEpisodes.changes(from: [:], to: [a: .approval])
        check("a new wait starts an episode", started.started == [a: .approval] && started.ended.isEmpty)
        let same = AgentWaitEpisodes.changes(from: [a: .approval], to: [a: .approval])
        check("the same wait read again changes nothing", same == AgentWaitEpisodes.Changes())
        let ended = AgentWaitEpisodes.changes(from: [a: .approval, b: .answer], to: [b: .answer])
        check("a wait that is over ends its episode", ended.ended == [a] && ended.started.isEmpty)
        let switched = AgentWaitEpisodes.changes(from: [a: .approval], to: [a: .answer])
        check(
            "a wait that changes kind ends and starts again",
            switched.ended == [a] && switched.started == [a: .answer])

        // MARK: The notification

        let chat = UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000001")!
        let approval = AgentWaitNotice(
            wait: .approval, chatID: chat, chatTitle: "Tidy Downloads", question: "ignored",
            appName: "Blitz")
        check("an approval says Blitz is waiting", approval.title == "Blitz is waiting for approval")
        check("and names the chat", approval.body == "Tidy Downloads")
        check(
            "one identifier per chat, so a later wait replaces the earlier one",
            approval.identifier == "agent-wait-6F1D2C3B-0000-4000-8000-000000000001"
                && approval.identifier == AgentWaitNotice.identifier(for: chat))
        check(
            "the click finds its chat again",
            AgentWaitNotice.chatID(in: approval.userInfo) == chat)
        check(
            "a notification of someone else's finds none",
            AgentWaitNotice.chatID(in: ["other": "x"]) == nil
                && AgentWaitNotice.chatID(in: [AgentWaitNotice.chatKey: "not a uuid"]) == nil)
        let dev = AgentWaitNotice(
            wait: .approval, chatID: chat, chatTitle: "x", question: nil, appName: "Blitz Dev")
        check("the channel's own name leads", dev.title == "Blitz Dev is waiting for approval")

        let question = AgentWaitNotice(
            wait: .answer, chatID: chat, chatTitle: "Export", question: "Which\n  format?",
            appName: "Blitz")
        check("a question says Blitz has one", question.title == "Blitz has a question")
        check(
            "and carries it on one line under the chat's title",
            question.body == "Export\nWhich format?")
        let unasked = AgentWaitNotice(
            wait: .answer, chatID: chat, chatTitle: "Export", question: "  ", appName: "Blitz")
        check("a blank question leaves only the title", unasked.body == "Export")

        let long = String(repeating: "word ", count: 60)
        let clipped = AgentWaitNotice.clipped(long)
        check(
            "a long question is cut at a word, with an ellipsis",
            clipped.count <= AgentWaitNotice.maxQuestionLength && clipped.hasSuffix("word\u{2026}"))
        let unbroken = String(repeating: "x", count: 300)
        check(
            "one with no space to cut at is cut at the limit",
            AgentWaitNotice.clipped(unbroken).count == AgentWaitNotice.maxQuestionLength)
        check(
            "a short one is kept whole",
            AgentWaitNotice.clipped("Which format?") == "Which format?")

        print(failures == 0 ? "All agent wait checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
