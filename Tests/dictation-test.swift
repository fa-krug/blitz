// Dictation's pure decisions, and the volume ducker against injected outputs and a private file.

import Foundation

@main
@MainActor
struct DictationTest {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func main() async {
        formatting()
        echoes()
        chunking()
        options()
        languages()
        volumeRecord()
        await ducking()
        settingsKeys()
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Formatting

    static func formatting() {
        typealias Context = DictationTextFormatter.Context
        func format(_ text: String, _ before: Substring, _ after: Substring = "", adapt: Bool = true) -> String {
            DictationTextFormatter.format(
                text, context: Context(before: before, after: after), adaptCapitalization: adapt)
        }
        check(
            "no context inserts the plain transcript, trimmed",
            DictationTextFormatter.format("  Hello. \n", context: nil) == "Hello.")
        check("an empty field starts a sentence", format("hello", "") == "Hello")
        check("mid-sentence lowercases and spaces", format("World", "Hello") == " world")
        check("after a full stop it capitalizes and spaces", format("world", "Hello.") == " World")
        check("a trailing space needs no second one", format("hello", "Wait. ") == "Hello")
        check("a new paragraph starts a sentence", format("hello", "Wait\n  ") == "Hello")
        check("text after the caret gets a space", format("World", "Hello ", "again") == "world ")
        check("brackets hug the transcript", format("hello", "(", ")") == "hello")
        check("an apostrophe hugs it", format("application", "l’") == "application")
        check(
            "capitalization can be left alone while spacing still adapts",
            format("Blitz", "Use", "again", adapt: false) == " Blitz ")
        check("left alone, a lowercase word stays", format("world", "Hello.", adapt: false) == " world")
        check(
            "punctuation leading the transcript needs no space",
            format("World.", "Hello ", ")", adapt: false) == "World.")
        let document = "prefix. Text to replace suffix"
        check(
            "a selection is replaced with the text either side considered",
            format("world", document.prefix(7), document.suffix(6)) == " World ")
    }

    static func echoes() {
        check(
            "a repeated word at the cut is dropped",
            DictationTextFormatter.stripEcho(" world peace", after: "Hello world") == " peace")
        check(
            "a word that merely starts like the tail stays",
            DictationTextFormatter.stripEcho("theatre tickets", after: "said the") == "theatre tickets")
        check(
            "a chunk that only repeats becomes nothing",
            DictationTextFormatter.stripEcho(" world", after: "Hello world").isEmpty)
        check(
            "unrelated text is untouched",
            DictationTextFormatter.stripEcho("good morning", after: "Hello world") == "good morning")
        check(
            "nothing pasted yet means nothing to strip",
            DictationTextFormatter.stripEcho(" hello", after: "") == " hello")
        check(
            "case and punctuation variants still count as the same word",
            DictationTextFormatter.stripEcho("Für, Jonathan", after: "kein kuchen für") == " Jonathan")
        check(
            "a longer repeated run is dropped whole",
            DictationTextFormatter.stripEcho("ein Kuchen für Jonathan", after: "aber kein Kuchen für")
                == " Jonathan")
        check(
            "a fragment followed by one shared word is chance, not an echo",
            DictationTextFormatter.stripEcho("äh also weiter gehts", after: "und dann")
                == "äh also weiter gehts")
    }

    // MARK: - Live chunks

    /// Speech-like noise at `level`, so the energy windows have something to measure.
    static func signal(seconds: Double, level: Float) -> [Float] {
        let count = Int(seconds * Double(DictationAudioChunks.sampleRate))
        return (0..<count).map { index in level * sin(Float(index) * 0.3) }
    }

    static func chunking() {
        let rate = DictationAudioChunks.sampleRate
        check("five minutes are held in memory", DictationAudioChunks.maximumSamples == 300 * rate)
        check("a chunk waits for two seconds of audio", DictationAudioChunks.minimumLiveSamples == 2 * rate)
        check("eight seconds force a flush", DictationAudioChunks.maximumLiveSamples == 8 * rate)

        let paused = signal(seconds: 3, level: 0.5) + signal(seconds: 1, level: 0)
        check(
            "speech then silence ends in a pause",
            DictationAudioChunks.endsInPause(in: paused, from: 0, to: paused.count))
        let speaking = signal(seconds: 4, level: 0.5)
        check(
            "unbroken speech does not",
            !DictationAudioChunks.endsInPause(in: speaking, from: 0, to: speaking.count))
        let silent = signal(seconds: 4, level: 0)
        check(
            "silence alone is no pause to cut at",
            !DictationAudioChunks.endsInPause(in: silent, from: 0, to: silent.count))
        let short = signal(seconds: 1, level: 0.5)
        check(
            "too little audio is never cut",
            DictationAudioChunks.liveCut(in: short, from: 0, to: short.count) == 0
                && !DictationAudioChunks.endsInPause(in: short, from: 0, to: short.count))

        let gap = signal(seconds: 3, level: 0.5) + signal(seconds: 0.4, level: 0)
            + signal(seconds: 2, level: 0.5)
        let cut = DictationAudioChunks.liveCut(in: gap, from: 0, to: gap.count)
        check(
            "a forced cut lands in the quiet gap, not mid-word",
            cut > 3 * rate && cut < Int(3.4 * Double(rate)))

        check(
            "the first chunk has nothing before it to overlap",
            DictationAudioChunks.liveOverlapStart(in: gap, before: rate) == 0)
        let overlap = DictationAudioChunks.liveOverlapStart(in: gap, before: gap.count)
        check(
            "the overlap starts at a quiet spot within three seconds",
            overlap >= gap.count - 3 * rate && overlap <= gap.count - 2 * rate
                && overlap > 3 * rate && overlap < Int(3.4 * Double(rate)))
    }

    // MARK: - Options

    static func options() {
        check(
            "modes persist by name",
            DictationMode.allCases.map(\.rawValue) == ["toggle", "hold"])
        check("destinations persist by name", DictationDestination.allCases.map(\.rawValue) == [
            "paste", "copy", "both"
        ])
        check(
            "paste and both paste, copy and both copy",
            DictationDestination.paste.pastes && !DictationDestination.paste.copies
                && !DictationDestination.copy.pastes && DictationDestination.copy.copies
                && DictationDestination.both.pastes && DictationDestination.both.copies)
        check(
            "only a running download reads as downloading",
            DictationAssetStatus.downloading(fraction: 0.5).isDownloading
                && !DictationAssetStatus.installed.isDownloading)
    }

    static func languages() {
        let supported = ["en_US", "en_GB", "de_DE", "fr_FR", "fr_CA"].map(Locale.init(identifier:))
        func resolve(_ choice: String?, _ preferred: [String]) -> String? {
            DictationLanguage.resolve(choice: choice, preferred: preferred, supported: supported)?
                .identifier
        }
        check("a supported choice wins", resolve("de_DE", ["en-US"]) == "de_DE")
        check("a choice matches however it is spelled", resolve("fr-CA", ["en-US"]) == "fr_CA")
        check("an unsupported choice falls back to the system", resolve("ja_JP", ["en-GB"]) == "en_GB")
        check("no choice takes the first preferred language", resolve(nil, ["fr-CA", "en-US"]) == "fr_CA")
        check("a missing region takes the same language", resolve(nil, ["de-AT"]) == "de_DE")
        check("a later preferred language is tried", resolve(nil, ["ja-JP", "de-CH"]) == "de_DE")
        check("nothing covered resolves to nothing", resolve(nil, ["ja-JP"]) == nil)
        let english = Locale(identifier: "en_US")
        check(
            "names follow the reader's language",
            DictationLanguage.name(of: english, in: Locale(identifier: "de_DE")).hasPrefix("Englisch"))
        let sorted = DictationLanguage.sorted(supported, in: Locale(identifier: "de_DE"))
        check("the picker sorts by name, as the reader spells it", sorted.first?.identifier == "de_DE")
    }

    // MARK: - Volume

    static func volumeRecord() {
        var record = DictationVolumeSnapshot(deviceUID: "out", original: 0.8, lastSet: 0.08)
        check("a set volume is ours", record.matches(0.08) && record.matches(0.085))
        check("a volume the user chose is not", !record.matches(0.5))
        record.previous = 0.2
        check("the step before a crash is ours too", record.matches(0.2))
        check("a record without a device is invalid", !DictationVolumeSnapshot(
            deviceUID: "", original: 0.5, lastSet: 0.5
        ).isValid)
        check("an out-of-range volume is invalid", !DictationVolumeSnapshot(
            deviceUID: "out", original: 1.5, lastSet: 0.5
        ).isValid)
        let encoded = try? JSONEncoder().encode(record)
        check(
            "the record round-trips through its file",
            encoded.flatMap { try? JSONDecoder().decode(DictationVolumeSnapshot.self, from: $0) }
                == record)
    }

    /// A fake output device with a volume the test can read and move.
    final class FakeOutput {
        var volume: Float
        var connected = true
        init(volume: Float) { self.volume = volume }

        var output: DictationAudioDucker.Output {
            DictationAudioDucker.Output(
                deviceUID: "fake", read: { self.volume }, write: { self.volume = $0 })
        }
    }

    static func ducking() async {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "dictation-volume.json")
        let device = FakeOutput(volume: 0.8)
        func ducker() -> DictationAudioDucker {
            DictationAudioDucker(
                fileURL: file, defaultOutput: { device.output },
                resolveOutput: { device.connected && $0 == "fake" ? device.output : nil })
        }
        let fraction = DictationAudioDucker.duckedFraction

        let normal = ducker()
        normal.begin()
        await normal.waitForTransition()
        check("ducking fades to a tenth", abs(device.volume - 0.8 * fraction) < 0.001)
        check("and leaves a record behind", FileManager.default.fileExists(atPath: file.path))
        normal.end()
        await normal.waitForTransition()
        check("ending restores the original", abs(device.volume - 0.8) < 0.001)
        check("and removes the record", !FileManager.default.fileExists(atPath: file.path))

        func writeRecord(lastSet: Float) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let record = DictationVolumeSnapshot(deviceUID: "fake", original: 0.8, lastSet: lastSet)
            try? JSONEncoder().encode(record).write(to: file)
        }

        writeRecord(lastSet: 0.08)
        device.volume = 0.08
        let relaunched = ducker()
        relaunched.recover()
        await relaunched.waitForTransition()
        check("a crash's ducked volume is put back on relaunch", abs(device.volume - 0.8) < 0.001)
        check("and its record cleared", !FileManager.default.fileExists(atPath: file.path))

        writeRecord(lastSet: 0.08)
        device.volume = 0.5
        let changed = ducker()
        changed.recover()
        await changed.waitForTransition()
        check("a volume the user changed since is left alone", device.volume == 0.5)

        writeRecord(lastSet: 0.08)
        device.volume = 0.08
        device.connected = false
        let unplugged = ducker()
        unplugged.recover()
        await unplugged.waitForTransition()
        check(
            "an unplugged device keeps its record for later",
            FileManager.default.fileExists(atPath: file.path))
        unplugged.begin()
        await unplugged.waitForTransition()
        check("and nothing new is ducked meanwhile", device.volume == 0.08)
        device.connected = true
        unplugged.recover()
        await unplugged.waitForTransition()
        check("once it is back, it is restored", abs(device.volume - 0.8) < 0.001)

        let interrupted = ducker()
        interrupted.begin()
        try? await Task.sleep(for: .milliseconds(100))
        device.volume = 0.3
        await interrupted.waitForTransition()
        interrupted.end()
        await interrupted.waitForTransition()
        check("turning the volume mid-fade hands it back to the user", device.volume == 0.3)
        check("and drops the record", !FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Settings

    static func settingsKeys() {
        let excluded = SettingsBackupCoverage.deliberatelyExcluded
        let mirrored = SettingsBackupCoverage.mirrored
        for key: AppSettingsKey in [.dictationEnabled, .dictationMicrophone] {
            check(
                "\(key.rawValue) never rides a backup",
                excluded[key.rawValue] != nil && mirrored.values.allSatisfy { $0 != key })
        }
        for key: AppSettingsKey in [
            .dictationMode, .dictationLanguage, .dictationDestination, .dictationPlaysSounds,
            .dictationLiveInsertion, .dictationAdaptsCapitalization
        ] {
            check("\(key.rawValue) rides a backup", mirrored.values.contains(key))
        }
        check(
            "the file cannot switch Dictation on or name a microphone",
            SettingsFileKey(rawValue: "dictation.enabled") == nil
                && SettingsFileKey(rawValue: "dictation.microphone") == nil)
        check(
            "the file carries the ordinary preferences",
            SettingsFileKey(rawValue: "dictation.mode") == .dictationMode
                && SettingsFileKey(rawValue: "dictation.language") == .dictationLanguage
                && SettingsFileKey(rawValue: "dictation.insertsWhileRecording") == .dictationLiveInsertion)
    }
}
