import AppKit

/// macOS's own dictation sounds, so Blitz's recording starts and stops the way the system's does.
@MainActor
final class DictationCueRunner {
    enum Cue {
        case start
        case stop

        /// Undocumented resources of a private framework; a missing one is skipped, never fatal.
        var url: URL {
            DictationCueRunner.resources.appending(path: self == .start ? "dt-begin.caf" : "dt-confirm.caf")
        }
    }

    nonisolated static let resources = URL(
        filePath: "/System/Library/PrivateFrameworks/AssistantServices.framework/Resources",
        directoryHint: .isDirectory)

    private let startSound = NSSound(contentsOf: Cue.start.url, byReference: true)
    private let stopSound = NSSound(contentsOf: Cue.stop.url, byReference: true)

    func play(_ cue: Cue) {
        startSound?.stop()
        stopSound?.stop()
        (cue == .start ? startSound : stopSound)?.play()
    }
}
