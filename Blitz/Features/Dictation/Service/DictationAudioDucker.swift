import CoreAudio
import Foundation
import OSLog

/// Fades the default output down while dictating, and back; a crash leaves a record to undo it.
@MainActor
final class DictationAudioDucker {
    /// One output device's volume, injected so the harness never touches the real one.
    struct Output {
        let deviceUID: String
        let read: () throws -> Float
        let write: (Float) throws -> Void
    }

    private struct Ducked {
        let output: Output
        var volume: DictationVolumeSnapshot
    }

    /// Quiet enough to hear yourself think, loud enough to notice something still playing.
    static let duckedFraction: Float = 0.1
    private static let fadeSteps = 16
    private static let fadeStep = Duration.milliseconds(30)
    private static let logger = Logger(subsystem: "de.fa-krug.blitz", category: "DictationVolume")

    private let fileURL: URL
    private let defaultOutput: () throws -> Output?
    private let resolveOutput: (String) throws -> Output?
    private var ducked: Ducked?
    private var transition: Task<Void, Never>?

    init(
        fileURL: URL = AppPaths.applicationSupport().appending(path: "dictation-volume.json"),
        defaultOutput: @escaping () throws -> Output? = {
            try AudioHardwareSystem.shared.defaultOutputDevice.flatMap(DictationAudioDucker.output)
        },
        resolveOutput: @escaping (String) throws -> Output? = { uid in
            try AudioHardwareSystem.shared.device(forUID: uid).flatMap(DictationAudioDucker.output)
        }
    ) {
        self.fileURL = fileURL
        self.defaultOutput = defaultOutput
        self.resolveOutput = resolveOutput
    }

    isolated deinit { transition?.cancel() }

    /// Puts back a volume a crash left ducked, even with Dictation off.
    func recover() {
        schedule { _ = try await $0.recoverSavedVolume() }
    }

    func begin() {
        schedule { ducker in
            if ducker.ducked == nil {
                // An output still awaiting its own recovery must not be ducked a second time.
                guard try await ducker.recoverSavedVolume(), let output = try ducker.defaultOutput()
                else { return }
                let original = try output.read()
                let volume = DictationVolumeSnapshot(
                    deviceUID: output.deviceUID, original: original, lastSet: original)
                guard volume.isValid, original > 0 else { return }
                ducker.ducked = Ducked(output: output, volume: volume)
            }
            guard let ducked = ducker.ducked else { return }
            try await ducker.fade(to: ducked.volume.original * Self.duckedFraction, release: false)
        }
    }

    func end() {
        guard ducked != nil || transition != nil else { return }
        schedule { ducker in
            guard let ducked = ducker.ducked else { return }
            try await ducker.fade(to: ducked.volume.original, release: true)
        }
    }

    /// No fade: a stop cue must play at full volume, and quitting cannot wait for one.
    func restoreImmediately() {
        transition?.cancel()
        if let ducked, let current = try? ducked.output.read(), ducked.volume.matches(current) {
            do { try ducked.output.write(ducked.volume.original) } catch {
                Self.logger.error("Couldn't restore dictation volume: \(error.localizedDescription)")
            }
        }
        ducked = nil
        recover()
    }

    /// For the harness: lets every scheduled change land.
    func waitForTransition() async {
        while let transition { await transition.value }
    }

    /// Serial: each change waits for the one before it, so a fade never races its own reversal.
    private func schedule(_ operation: @escaping @MainActor (DictationAudioDucker) async throws -> Void) {
        let previous = transition
        previous?.cancel()
        transition = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            do { try await operation(self) } catch is CancellationError {
            } catch {
                Self.logger.error("Couldn't update dictation volume: \(error.localizedDescription)")
                if ducked != nil { restoreImmediately() }
            }
            if !Task.isCancelled { transition = nil }
        }
    }

    private func fade(to target: Float, release: Bool) async throws {
        guard let ducked else { return }
        let start = try ducked.output.read()
        guard ducked.volume.matches(start) else {
            try await clear()
            return
        }
        for step in 1...Self.fadeSteps {
            try Task.checkCancellation()
            guard let current = self.ducked else { return }
            let volume = start + (target - start) * Float(step) / Float(Self.fadeSteps)
            var saved = current.volume
            saved.previous = saved.lastSet
            saved.lastSet = volume
            // Written before the hardware, so a crash between the two can restore either volume.
            try await persist(saved)
            try Task.checkCancellation()
            guard current.volume.matches(try current.output.read()) else {
                try await clear()
                return
            }
            try current.output.write(volume)
            self.ducked?.volume.lastSet = try current.output.read()
            self.ducked?.volume.previous = nil
            if step < Self.fadeSteps { try await Task.sleep(for: Self.fadeStep) }
        }
        if release { try await clear() }
    }

    /// False while the recorded device is unplugged: its record waits, and nothing new ducks.
    private func recoverSavedVolume() async throws -> Bool {
        let fileURL = fileURL
        let volume = try await Task.detached(priority: .utility) { () -> DictationVolumeSnapshot? in
            do {
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder().decode(DictationVolumeSnapshot.self, from: data)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }.value
        try Task.checkCancellation()
        guard let volume else { return true }
        guard volume.isValid else {
            try await persist(nil)
            return true
        }
        guard let output = try resolveOutput(volume.deviceUID) else { return false }
        let current = try output.read()
        if volume.matches(current), current != volume.original { try output.write(volume.original) }
        try await persist(nil)
        return true
    }

    private func clear() async throws {
        ducked = nil
        try await persist(nil)
    }

    private func persist(_ volume: DictationVolumeSnapshot?) async throws {
        let fileURL = fileURL
        try await Task.detached(priority: .utility) {
            guard let volume else {
                do { try FileManager.default.removeItem(at: fileURL) } catch let error as CocoaError
                    where error.code == .fileNoSuchFile
                {}
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(volume).write(to: fileURL, options: .atomic)
        }.value
    }

    nonisolated static func output(for device: AudioHardwareDevice) throws -> Output? {
        guard let control = try device.controls.first(where: isMainOutputVolume) else { return nil }
        return Output(
            deviceUID: try device.uid,
            read: { try control.volumeScalarValue },
            write: { try control.setVolumeScalarValue($0) })
    }

    nonisolated private static func isMainOutputVolume(_ control: AudioHardwareControl) -> Bool {
        guard (try? control.classID) == kAudioVolumeControlClassID else { return false }
        func value(for selector: AudioObjectPropertySelector) -> UInt32? {
            let address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard let data = try? control.propertyData(address: address, qualifier: nil),
                data.count == MemoryLayout<UInt32>.size
            else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        return value(for: kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput
            && value(for: kAudioControlPropertyElement) == kAudioObjectPropertyElementMain
    }
}
