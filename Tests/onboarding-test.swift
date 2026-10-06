import Foundation

@main
@MainActor
struct OnboardingTests {
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
        stepsRunInOrder()
        everyStepIsNamed()
        tipsTeachTheThreeHabits()
        tabCardFollowsTheTabRing()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func stepsRunInOrder() {
        expect(
            OnboardingStep.allCases == [.shortcut, .accessibility, .raycastImport, .tips, .done],
            "the tour opens on the shortcut and closes on Done, with the tips just before it")
        expect(OnboardingStep.first == .shortcut, "the tour starts on the shortcut")
        expect(OnboardingStep.last == .done, "the tour ends on Done")
        expect(OnboardingStep.first.previous == nil, "nothing comes before the first step")
        expect(OnboardingStep.last.next == nil, "nothing comes after the last step")
        for step in OnboardingStep.allCases {
            if let next = step.next {
                expect(next.previous == step, "\(step) → \(next) walks back to \(step)")
            }
        }
        var walked: [OnboardingStep] = [OnboardingStep.first]
        while let next = walked.last?.next { walked.append(next) }
        expect(walked == OnboardingStep.allCases, "Continue visits every step exactly once")
    }

    static func everyStepIsNamed() {
        let titles = OnboardingStep.allCases.map(\.title)
        expect(!titles.contains(where: \.isEmpty), "every step has a title")
        expect(Set(titles).count == titles.count, "no two steps share a title")
        for step in OnboardingStep.allCases where step != .last {
            expect(step.subtitle?.isEmpty == false, "\(step) has its own subtitle")
        }
        expect(OnboardingStep.last.subtitle == nil, "Done's line names the chosen shortcut instead")
    }

    static func tipsTeachTheThreeHabits() {
        let tips = OnboardingTip.all(tab: .quickAI)
        expect(tips == [.actions, .aliases, .tab(.quickAI)], "⌘K, aliases, then Tab")
        expect(OnboardingTip.actions.keycaps == ["⌘", "K"], "the actions card shows ⌘K")
        expect(OnboardingTip.aliases.keycaps == ["⇧", "⌘", ","], "the alias card shows ⇧⌘,")
        expect(OnboardingTip.tab(.clipboard).keycaps == ["⇥"], "the Tab card shows ⇥")
        expect(
            OnboardingTip.aliases.message.contains("Space"),
            "the alias card says an alias and Space enter the row")
        for tip in tips {
            expect(!tip.title.isEmpty && !tip.message.isEmpty, "\(tip) has a title and message")
        }
    }

    static func tabCardFollowsTheTabRing() {
        func destination(ai: Bool, clipboard: Bool) -> OnboardingTip.TabDestination {
            OnboardingTip.TabDestination(
                PaletteTabAction.resolve(mode: .launcher, aiEnabled: ai, clipboardEnabled: clipboard))
        }
        expect(destination(ai: true, clipboard: true) == .quickAI, "AI on: Tab asks Quick AI")
        expect(destination(ai: true, clipboard: false) == .quickAI, "AI wins without a clipboard")
        expect(destination(ai: false, clipboard: true) == .clipboard, "AI off: Tab opens Clipboard")
        expect(destination(ai: false, clipboard: false) == .nowhere, "both off: Tab rings nowhere")

        expect(OnboardingTip.tab(.quickAI).message.contains("Quick AI"), "the AI card names Quick AI")
        expect(
            OnboardingTip.tab(.clipboard).message.contains("Clipboard"),
            "the clipboard card names Clipboard History")
        expect(!OnboardingTip.tab(.quickAI).offersAISettings, "AI on needs no Settings link")
        expect(OnboardingTip.tab(.clipboard).offersAISettings, "AI off links to Settings › AI")
        expect(OnboardingTip.tab(.nowhere).offersAISettings, "both off links to Settings › AI")
        expect(
            !OnboardingTip.actions.offersAISettings && !OnboardingTip.aliases.offersAISettings,
            "only the Tab card links to AI")
    }
}
