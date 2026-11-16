import Foundation

/// The crash-safe record of a ducked output: what to restore, and the volumes Blitz itself set.
struct DictationVolumeSnapshot: Codable, Equatable, Sendable {
    let deviceUID: String
    let original: Float
    var lastSet: Float
    /// The step before `lastSet`: a crash between writing this file and the hardware leaves either.
    var previous: Float?

    /// Matching within this is "still ours"; anything further is a change the user made.
    static let tolerance: Float = 0.01

    var isValid: Bool {
        !deviceUID.isEmpty && (0...1).contains(original) && (0...1).contains(lastSet)
            && previous.map { (0...1).contains($0) } != false
    }

    /// A volume Blitz set; anything else is the user's, and is never overwritten on restore.
    func matches(_ volume: Float) -> Bool {
        isValid
            && (abs(volume - lastSet) < Self.tolerance
                || previous.map { abs(volume - $0) < Self.tolerance } == true)
    }
}
