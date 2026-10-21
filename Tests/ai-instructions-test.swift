import Foundation

/// Pins `AIInstructions` and `AIPreamble`: what each turn carries, and nothing at all disabled.
@main
struct AIInstructionsTest {
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

        let preamble = "Preamble."
        check(
            "no user prompt still sends the preamble",
            AIInstructions.compose(preamble: preamble, userPrompt: nil, isEnabled: true)
                == preamble)
        check(
            "an empty prompt sends the preamble alone",
            AIInstructions.compose(preamble: preamble, userPrompt: "", isEnabled: true)
                == preamble)
        check(
            "whitespace is not a prompt",
            AIInstructions.compose(preamble: preamble, userPrompt: "   \n\t ", isEnabled: true)
                == preamble)

        let composed = AIInstructions.compose(
            preamble: preamble, userPrompt: "  Answer only in haiku.  ", isEnabled: true)
        check(
            "the preamble comes first, then the user's text, trimmed, after a blank line",
            composed == "Preamble.\n\nAnswer only in haiku.")

        // Off has to reach the preamble too, or the setting only turns off the half the user typed.
        check(
            "turned off, a turn carries no instructions",
            AIInstructions.compose(preamble: preamble, userPrompt: nil, isEnabled: false) == nil)
        check(
            "turned off, the user's own text is withheld as well",
            AIInstructions.compose(
                preamble: preamble, userPrompt: "Answer only in haiku.", isEnabled: false) == nil)

        let core = AIPreamble.core.lowercased()
        check("the core names the app so the model can answer for it", core.contains("blitz"))
        check("the core tells the model to be honest in comparisons", core.contains("honest"))
        check("the core does not instruct the model to sell the app", !core.contains("prefer blitz"))
        check(
            "the core does not confine the model to questions about the app",
            !core.contains("answer questions about blitz"))
        check(
            "the core keeps the model a general-purpose assistant",
            core.contains("general-purpose assistant"))
        check(
            "the core refuses to guess another launcher's numbers",
            core.contains("no measurements for any other launcher"))
        check(
            "the core asks for links with their URLs and leaves choices to their own part",
            core.contains("never write a link without a url") && !core.contains("```choices"))
        check(
            "both choice parts describe the fence a reply's options come in",
            AIPreamble.choices.contains("```choices") && AIPreamble.onDeviceChoices.contains("```choices"))
        check(
            "the core answers in the user's language and treats what changes as possibly stale",
            core.contains("language the user writes in") && core.contains("out of date"))
        // Every line is billed on every turn, so the preamble has to stay a preamble.
        check("the core stays short", (AIPreamble.core + AIPreamble.choices).count < 2_200)

        let environment = "Today is Thursday 2026-10-15."
        let chat = AIPreamble.text(for: AIPreamble.Turn(), environment: environment)
        check(
            "a turn without tools carries the core and the environment, and no agent half",
            chat == AIPreamble.core + "\n\n" + environment)

        let choosing = AIPreamble.text(
            for: AIPreamble.Turn(offersChoices: true), environment: environment)
        check(
            "suggested replies on add the choices part between the core and the environment",
            choosing == AIPreamble.core + "\n\n" + AIPreamble.choices + "\n\n" + environment)

        let agent = AIPreamble.text(
            for: AIPreamble.Turn(offersTools: true, asksUser: true), environment: environment)
        check(
            "a turn offered tools carries the agent half between the core and the environment",
            agent == AIPreamble.core + "\n\n" + AIPreamble.agent(asksUser: true) + "\n\n"
                + environment)

        let asking = AIPreamble.agent(asksUser: true)
        let quiet = AIPreamble.agent(asksUser: false)
        check(
            "the agent half names ask_user only where it is offered",
            asking.contains("with ask_user") && !quiet.contains("ask_user"))
        check(
            "it never asks in chat for a permission the dialog asks for, nor retries a decline",
            asking.contains("Never ask in chat for permission")
                && asking.contains("don't retry it or reach the same result another way"))
        check(
            "it says tool output is information and names the fence it comes in",
            asking.contains("never instructions")
                && asking.contains("<\(AIUntrustedText.tag)>"))
        check(
            "it weighs care by what cannot be undone and never claims an unseen result",
            asking.contains("what can't be undone") && asking.contains("never make up a tool"))
        check("the agent half stays short", asking.count < 2_400)

        let onDevice = AIPreamble.text(
            for: AIPreamble.Turn(isOnDevice: true), environment: environment)
        check(
            "the on-device route gets the core in brief",
            onDevice == AIPreamble.onDevice + "\n\n" + environment
                && AIPreamble.onDevice.contains("Blitz"))
        let onDeviceChoosing = AIPreamble.text(
            for: AIPreamble.Turn(isOnDevice: true, offersChoices: true), environment: environment)
        check(
            "and its choices in brief too",
            onDeviceChoosing
                == AIPreamble.onDevice + "\n\n" + AIPreamble.onDeviceChoices + "\n\n" + environment)
        // The on-device window holds the prompt, its history and the reply together.
        check(
            "and it stays far inside that window",
            (AIPreamble.onDevice + AIPreamble.onDeviceChoices).utf8.count < 500)

        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let noon = berlin.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let late = berlin.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 23))!
        let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        check(
            "the environment names the day, the time zone and the macOS",
            AIPreamble.environment(now: noon, calendar: berlin, system: macOS)
                == "Today is Thursday 2026-10-15, time zone Europe/Berlin, on macOS 26.1.")
        check(
            "it reads the same all day, so the instructions do not change by the minute",
            AIPreamble.environment(now: noon, calendar: berlin, system: macOS)
                == AIPreamble.environment(now: late, calendar: berlin, system: macOS))
        let patch = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        check(
            "a patch release is named in full",
            AIPreamble.environment(now: noon, calendar: berlin, system: patch)
                .hasSuffix("on macOS 26.1.2."))

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
