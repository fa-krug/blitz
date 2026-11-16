import AVFoundation
import Speech

/// Apple's on-device `SpeechAnalyzer`: the locale, whether its model is here, one transcription.
enum DictationTranscriber {
    enum Failure: LocalizedError {
        case unsupportedLanguage
        case audioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: "On-device dictation doesn’t support this language."
            case .audioFormat: "The speech model can’t read this recording."
            }
        }
    }

    /// What `DictationCapture` records, before the analyzer's own format.
    nonisolated private static var recordedFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(DictationAudioChunks.sampleRate),
            channels: 1, interleaved: false)
    }

    /// One preset for every pass, so a live chunk and the final pass hear the same way.
    nonisolated private static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    nonisolated static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// The chosen language, or the system's first one the transcriber covers.
    nonisolated static func locale(choice: String?) async -> Locale? {
        DictationLanguage.resolve(
            choice: choice, preferred: Locale.preferredLanguages,
            supported: await supportedLocales())
    }

    /// `.supported` is a model macOS can fetch that Blitz has not reserved yet.
    nonisolated static func status(of locale: Locale) async -> DictationAssetStatus {
        switch await AssetInventory.status(forModules: [module(for: locale)]) {
        case .unsupported: .unsupported
        case .supported: .notInstalled
        case .downloading: .downloading(fraction: nil)
        case .installed: .installed
        @unknown default: .unsupported
        }
    }

    /// Nil when the model is already in place; otherwise the download to run, with its progress.
    nonisolated static func installation(for locale: Locale) async throws
        -> AssetInstallationRequest?
    {
        await makeRoom(for: locale)
        return try await AssetInventory.assetInstallationRequest(supporting: [module(for: locale)])
    }

    /// Fetches a missing model first, so a first dictation needs no visit to Settings.
    nonisolated static func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        let transcriber = module(for: locale)
        if let request = try await installation(for: locale) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let recordedFormat = Self.recordedFormat,
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: recordedFormat)
        else { throw Failure.unsupportedLanguage }
        let input = try buffer(samples, in: format)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputSequence: stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                collected.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await collected.value
        } onCancel: {
            collected.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The recording as one buffer in the analyzer's format, converted only when it differs.
    nonisolated private static func buffer(
        _ samples: [Float], in format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(samples.count)
        guard let recordedFormat = Self.recordedFormat,
            let recorded = AVAudioPCMBuffer(pcmFormat: recordedFormat, frameCapacity: frames),
            let channel = recorded.floatChannelData?[0]
        else { throw Failure.audioFormat }
        recorded.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        guard format != recordedFormat else { return recorded }
        // The simple conversion needs equal rates, which holds: both sides are 16 kHz mono.
        guard format.sampleRate == recordedFormat.sampleRate,
            let converter = AVAudioConverter(from: recordedFormat, to: format),
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw Failure.audioFormat }
        try converter.convert(to: converted, from: recorded)
        return converted
    }

    /// macOS reserves a few locales per app; switching language must not fail on the old ones.
    nonisolated private static func makeRoom(for locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { DictationLanguage.matches($0, locale.identifier) }),
            reserved.count >= AssetInventory.maximumReservedLocales,
            let oldest = reserved.first
        else { return }
        await AssetInventory.release(reservedLocale: oldest)
    }
}
