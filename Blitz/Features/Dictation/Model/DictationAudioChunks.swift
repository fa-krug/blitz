import Foundation

/// Where live insertion cuts the recording: at a pause, or at the length that bounds staleness.
enum DictationAudioChunks {
    /// Mono Float32 at the rate the capture asks for, which is also what the chunk sizes count.
    static let sampleRate = 16_000
    /// Five minutes held in memory; the recording finishes itself when it fills.
    static let maximumSamples = 5 * 60 * sampleRate
    /// Audio shorter than this never leaves the microphone: a round-trip costs more than it says.
    static let minimumLiveSamples = 2 * sampleRate
    /// Forced flush without a pause: bounds the final pass and how stale visible text gets.
    static let maximumLiveSamples = 8 * sampleRate
    /// Re-transcribed with every flush, so a word split at the cut rarely duplicates.
    static let liveOverlapSamples = 2 * sampleRate
    /// Too short to transcribe at all: a tap of the shortcut, not speech.
    static let minimumSpeechSamples = sampleRate / 10

    /// 200 ms, the window the energy of a passage is measured over.
    private static let window = sampleRate / 5
    /// How far back from a cut the quietest window is looked for.
    private static let searchSpan = 3 * sampleRate
    private static let step = sampleRate / 100

    /// Where the overlap re-transcribed before `start` begins: a quiet spot near two seconds back.
    static func liveOverlapStart(in samples: [Float], before start: Int) -> Int {
        precondition(start >= 0 && start <= samples.count)
        guard start > liveOverlapSamples else { return 0 }
        var cut = start - liveOverlapSamples
        var best = energy(samples, at: cut)
        var offset = max(0, start - searchSpan)
        while offset + window <= start {
            let candidate = energy(samples, at: offset)
            if candidate < best {
                best = candidate
                cut = offset + window / 2
            }
            offset += step
        }
        return cut
    }

    /// Where a flush of `start..<end` ends: its quietest late moment, or `start` if too short.
    static func liveCut(in samples: [Float], from start: Int, to end: Int) -> Int {
        precondition(start >= 0 && start <= end && end <= samples.count)
        guard end - start >= minimumLiveSamples else { return start }
        var cut = end
        var quietest: Float = .infinity
        for offset in stride(from: max(start, end - searchSpan), through: end - window, by: step) {
            let candidate = energy(samples, at: offset)
            if candidate <= quietest {
                quietest = candidate
                cut = offset + window / 2
            }
        }
        return cut
    }

    /// A pause: the last half second is a twentieth as loud as the loudest moment before it.
    static func endsInPause(in samples: [Float], from start: Int, to end: Int) -> Bool {
        precondition(start >= 0 && start <= end && end <= samples.count)
        guard end - start >= minimumLiveSamples else { return false }
        let hop = window / 2
        var peak: Float = 0
        var offset = start
        while offset + window <= end {
            peak = max(peak, energy(samples, at: offset))
            offset += hop
        }
        guard peak > 0 else { return false }
        var tail: Float = 0
        var count = 0
        offset = max(start, end - sampleRate / 2)
        while offset + window <= end {
            tail += energy(samples, at: offset)
            count += 1
            offset += hop
        }
        guard count > 0 else { return false }
        return tail / Float(count) <= peak * 0.05
    }

    private static func energy(_ samples: [Float], at offset: Int) -> Float {
        samples[offset..<(offset + window)].reduce(Float.zero) { $0 + $1 * $1 }
    }
}
