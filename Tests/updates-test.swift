import Foundation

@main
@MainActor
struct UpdatesTests {
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
        blocksWhileBusy()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - UpdateReadiness

    static func blocksWhileBusy() {
        expect(UpdateReadiness.evaluate(UpdateActivity()) == nil, "an idle app is ready to update")

        var busy = UpdateActivity()
        busy.isPaletteVisible = true
        expect(UpdateReadiness.evaluate(busy) == .paletteOpen, "an open palette holds the update")

        busy = UpdateActivity()
        busy.isShowingDialog = true
        expect(UpdateReadiness.evaluate(busy) == .dialogOpen, "an open dialog holds the update")

        busy = UpdateActivity()
        busy.isRecordingHotKey = true
        expect(UpdateReadiness.evaluate(busy) == .recordingHotKey, "a live recorder holds the update")

        busy = UpdateActivity()
        busy.isUninstalling = true
        expect(UpdateReadiness.evaluate(busy) == .uninstalling, "a running uninstall holds the update")

        busy = UpdateActivity()
        busy.isRunningExtension = true
        expect(
            UpdateReadiness.evaluate(busy) == .runningExtension,
            "a running extension command holds the update")

        busy = UpdateActivity()
        busy.isExpandingSnippet = true
        expect(
            UpdateReadiness.evaluate(busy) == .expandingSnippet,
            "a snippet mid-expansion holds the update")

        // Everything at once: the report names the one that would lose work, not the topmost panel.
        busy = UpdateActivity()
        busy.isPaletteVisible = true
        busy.isShowingDialog = true
        busy.isExpandingSnippet = true
        expect(
            UpdateReadiness.evaluate(busy) == .expandingSnippet,
            "the costliest interruption is the one reported")
    }
}
