import AVFoundation
import AudioToolbox
import CoreMedia
import Synchronization

/// One recording from the chosen microphone, held in memory as mono 16 kHz samples.
@MainActor
final class DictationCapture {
    enum Failure: LocalizedError {
        case microphoneUnavailable
        case microphoneDenied
        case captureUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: "No microphone is available."
            case .microphoneDenied: "Allow Blitz to use the microphone in System Settings."
            case .captureUnavailable: "Couldn’t start recording from this microphone."
            }
        }
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    /// Smoothed band levels, at most twenty times a second.
    var onLevels: (([Float]) -> Void)?
    /// The five-minute buffer filled.
    var onLimit: (() -> Void)?

    /// A Bluetooth headset drops its output while it switches to its microphone.
    private(set) var isBluetooth = false
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var collector: DictationAudioCollector?

    var isRunning: Bool { session != nil }

    func start(microphoneID: String?) async throws {
        var access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            access = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard access == .authorized else { throw Failure.microphoneDenied }
        let chosen = microphoneID.flatMap { id in Self.microphones.first { $0.uniqueID == id } }
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio) else {
            throw Failure.microphoneUnavailable
        }
        isBluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
            .contains(UInt32(bitPattern: device.transportType))
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw Failure.captureUnavailable
        }

        let capture = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: DictationAudioChunks.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard capture.canAddInput(input), capture.canAddOutput(output) else {
            throw Failure.captureUnavailable
        }
        capture.addInput(input)
        capture.addOutput(output)
        let collector = try DictationAudioCollector(
            onLevels: { [weak self] levels in
                Task { @MainActor [weak self] in self?.onLevels?(levels) }
            },
            onLimit: { [weak self] in
                Task { @MainActor [weak self] in self?.onLimit?() }
            })
        output.setSampleBufferDelegate(collector, queue: collector.queue)
        session = capture
        self.output = output
        self.collector = collector
        let box = CaptureSessionBox(session: capture)
        await Task.detached { box.session.startRunning() }.value
        guard capture.isRunning else {
            _ = await stop()
            throw Failure.captureUnavailable
        }
    }

    /// Everything recorded; the microphone is off by the time it returns.
    func stop() async -> [Float] {
        guard let session else { return [] }
        self.session = nil
        let box = CaptureSessionBox(session: session)
        await Task.detached { box.session.stopRunning() }.value
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        let samples = collector?.samples() ?? []
        collector = nil
        return samples
    }

    /// The recording so far, for live insertion.
    func snapshot() -> [Float] {
        guard session != nil else { return [] }
        return collector?.samples() ?? []
    }
}

/// Unchecked because the session is configured on main and only started or stopped off it.
private struct CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Receives the microphone's buffers on AVFoundation's queue and keeps them behind one lock.
private final class DictationAudioCollector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
    Sendable
{
    private struct State {
        var samples: [Float] = []
        var displayed = [Float](repeating: 0, count: DictationSpectrum.barCount)
        let spectrum: DictationSpectrum
        var levelsFrom = 0
        var lastLevels: TimeInterval = 0
        var reachedLimit = false
    }

    /// The panel needs no more than this, and a transform per buffer would be wasted.
    private static let levelInterval: TimeInterval = 0.05

    /// AVFoundation delivers buffers on a queue it is handed, never on an executor.
    let queue = DispatchQueue(label: "de.fa-krug.blitz.dictation-audio")
    private let state: Mutex<State>
    private let onLevels: @Sendable ([Float]) -> Void
    private let onLimit: @Sendable () -> Void

    init(
        onLevels: @escaping @Sendable ([Float]) -> Void, onLimit: @escaping @Sendable () -> Void
    ) throws {
        state = Mutex(State(spectrum: try DictationSpectrum()))
        self.onLevels = onLevels
        self.onLimit = onLimit
    }

    func samples() -> [Float] {
        state.withLock { $0.samples }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = bufferList.mBuffers.mData else { return }
        let count = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let incoming = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: count)
        let now = ProcessInfo.processInfo.systemUptime
        let (levels, filled) = state.withLock { state -> ([Float]?, Bool) in
            let room = DictationAudioChunks.maximumSamples - state.samples.count
            guard room > 0 else { return (nil, false) }
            state.samples.append(contentsOf: incoming.prefix(room))
            var filled = false
            if state.samples.count == DictationAudioChunks.maximumSamples, !state.reachedLimit {
                state.reachedLimit = true
                filled = true
            }
            guard now - state.lastLevels >= Self.levelInterval else { return (nil, filled) }
            state.lastLevels = now
            let fresh = state.spectrum.levels(for: state.samples[state.levelsFrom...])
            state.levelsFrom = state.samples.count
            for index in fresh.indices {
                // Rises fast and falls slowly, so a syllable reads as a pulse and not a flicker.
                let response: Float = fresh[index] > state.displayed[index] ? 0.6 : 0.25
                state.displayed[index] += (fresh[index] - state.displayed[index]) * response
            }
            return (state.displayed, filled)
        }
        if let levels { onLevels(levels) }
        if filled { onLimit() }
    }
}
