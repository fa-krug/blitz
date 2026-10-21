import Foundation

@main
@MainActor
struct HIDKeyMappingTests {
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

    static let ours = HIDKeyMapping.capsLockToF18
    static let capsToEscape = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_0029)
    static let rightOptionToRightCommand = HIDKeyMapping(source: 0x7_0000_00E6, destination: 0x7_0000_00E7)
    static let homeToEnd = HIDKeyMapping(source: 0x7_0000_004A, destination: 0x7_0000_004D)

    static func main() {
        parsing()
        serializing()
        turningOn()
        turningOff()

        print("hid-key-mapping-test: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func parsing() {
        expect(HIDKeyMapping.mappings(fromHIDUtilOutput: "(null)\n") == [], "(null) is no mapping")
        expect(HIDKeyMapping.mappings(fromHIDUtilOutput: "(\n)\n") == [], "an empty list is no mapping")

        let output = """
            (
                    {
                    HIDKeyboardModifierMappingDst = 30064771181;
                    HIDKeyboardModifierMappingSrc = 30064771129;
                },
                    {
                    HIDKeyboardModifierMappingDst = 30064771303;
                    HIDKeyboardModifierMappingSrc = 30064771302;
                }
            )

            """
        expect(
            HIDKeyMapping.mappings(fromHIDUtilOutput: output) == [ours, rightOptionToRightCommand],
            "hidutil's decimal strings parse in order")

        let partial = """
            (
                    {
                    HIDKeyboardModifierMappingSrc = 30064771129;
                },
                    {
                    HIDKeyboardModifierMappingDst = 30064771181;
                    HIDKeyboardModifierMappingSrc = 30064771129;
                }
            )
            """
        expect(
            HIDKeyMapping.mappings(fromHIDUtilOutput: partial) == [ours],
            "an entry missing its destination is skipped")

        expect(HIDKeyMapping.mappings(fromHIDUtilOutput: "") == nil, "empty output is unreadable")
        expect(
            HIDKeyMapping.mappings(fromHIDUtilOutput: "hidutil: error") == nil,
            "an error message is unreadable")
    }

    static func serializing() {
        expect(
            HIDKeyMapping.hidutilArgument(for: []) == #"{"UserKeyMapping":[]}"#,
            "no mappings serialize to an empty list")
        let argument = HIDKeyMapping.hidutilArgument(for: [ours, homeToEnd])
        expect(
            argument
                == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"#
                + #""HIDKeyboardModifierMappingDst":30064771181},{"HIDKeyboardModifierMappingSrc":"#
                + #"30064771146,"HIDKeyboardModifierMappingDst":30064771149}]}"#,
            "mappings serialize as decimal JSON numbers, got \(argument)")
        let decoded = try? JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any]
        expect((decoded?["UserKeyMapping"] as? [Any])?.count == 2, "the argument is valid JSON")
    }

    static func turningOn() {
        expect(ours.replacingSource(in: []) == [ours], "on an empty table, ours is the only entry")
        expect(
            ours.replacingSource(in: [homeToEnd, rightOptionToRightCommand])
                == [homeToEnd, rightOptionToRightCommand, ours],
            "other keys' mappings survive")
        expect(
            ours.replacingSource(in: [capsToEscape, homeToEnd]) == [homeToEnd, ours],
            "another Caps Lock mapping gives way")
        expect(ours.replacingSource(in: [ours]) == [ours], "turning on twice keeps one entry")

        expect(
            ours.displaced(in: [capsToEscape, homeToEnd]) == [capsToEscape],
            "the Caps Lock entry is displaced")
        expect(ours.displaced(in: [homeToEnd]) == [], "nothing is displaced without a Caps Lock entry")
        expect(ours.displaced(in: [ours, homeToEnd]) == [], "our own pair is never displaced")
    }

    static func turningOff() {
        expect(ours.restoring([], in: [ours]) == [], "with nothing displaced, off empties the table")
        expect(
            ours.restoring([], in: [homeToEnd, ours, rightOptionToRightCommand])
                == [homeToEnd, rightOptionToRightCommand],
            "off removes only our pair")
        expect(
            ours.restoring([capsToEscape], in: [homeToEnd, ours]) == [homeToEnd, capsToEscape],
            "off puts the displaced entry back")
        expect(
            ours.restoring([capsToEscape], in: [homeToEnd]) == [homeToEnd],
            "with our pair already gone, nothing changes")
        let changed = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_00E0)
        expect(
            ours.restoring([capsToEscape], in: [changed, homeToEnd]) == [changed, homeToEnd],
            "a Caps Lock entry someone else set since is left alone")
        expect(
            ours.restoring([capsToEscape], in: [ours, changed]) == [ours, changed],
            "a second Caps Lock entry beside ours is left alone")

        let before = [capsToEscape, homeToEnd]
        let on = ours.replacingSource(in: before)
        let off = ours.restoring(ours.displaced(in: before), in: on)
        expect(Set(off) == Set(before), "on then off restores the original table")
    }
}
