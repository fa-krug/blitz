import AVFoundation
import Synchronization
import Vision

/// Watches a video output's frames and reports every QR payload it reads, one frame at a time.
final class QRCodeMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    /// AVFoundation delivers frames on a queue it is handed, never on an executor.
    let queue = DispatchQueue(label: "de.fa-krug.blitz.qr-frames")
    private let continuation = Mutex<AsyncStream<String>.Continuation?>(nil)
    private let reading = Mutex(false)

    /// Fresh per reader: a cancelled `for await` ends its stream for good.
    func codes() -> AsyncStream<String> {
        let (codes, next) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingNewest(1))
        continuation.withLock { current in
            current?.finish()
            current = next
        }
        return codes
    }

    func finish() {
        continuation.withLock { current in
            current?.finish()
            current = nil
        }
    }

    /// Frames arriving mid-read are dropped, so detection never queues up behind the camera.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = sampleBuffer.imageBuffer, claimReader() else { return }
        let frame = Frame(pixels: pixels)
        Task.detached { [self] in
            defer { reading.withLock { $0 = false } }
            var request = DetectBarcodesRequest()
            request.symbologies = [.qr]
            let found = try? await request.perform(on: frame.pixels)
            guard let payload = found?.lazy.compactMap(\.payloadString).first else { return }
            _ = continuation.withLock { $0?.yield(payload) }
        }
    }

    private func claimReader() -> Bool {
        reading.withLock { reading in
            guard !reading else { return false }
            reading = true
            return true
        }
    }
}

/// Unchecked because the buffer is only read once captured, and only by the one detection task.
private struct Frame: @unchecked Sendable {
    let pixels: CVPixelBuffer
}
