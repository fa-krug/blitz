import Foundation
import Synchronization

extension Process {
    /// Use instead of `waitUntilExit`, whose run loop can miss the exit on a GCD thread and hang.
    func runObservingExit() throws -> ProcessExit {
        let exit = ProcessExit()
        terminationHandler = { _ in exit.signal() }
        try run()
        return exit
    }
}

/// Every wait after the exit returns at once; `exited()` suspends where `wait()` would block.
final class ProcessExit: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    /// `nil` once the child has exited, so a late waiter resumes at once.
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]?>([])

    fileprivate func signal() {
        semaphore.signal()
        let waiting = waiters.withLock { waiters in
            defer { waiters = nil }
            return waiters ?? []
        }
        for waiter in waiting { waiter.resume() }
    }

    /// Blocks without a run loop: only for a thread of the caller's own, never the shared pool.
    func wait() {
        semaphore.wait()
        semaphore.signal()
    }

    func exited() async {
        await withCheckedContinuation { continuation in
            let queued = waiters.withLock { waiters in
                guard waiters != nil else { return false }
                waiters?.append(continuation)
                return true
            }
            if !queued { continuation.resume() }
        }
    }
}

extension FileHandle {
    /// Read on the handle's own dispatch source, so no thread sits blocked on a child's output.
    func collect(
        upTo limit: Int = .max, until answered: @escaping @Sendable (Data) -> Bool = { _ in false }
    ) async -> Data {
        let collector = OutputCollector(limit: limit, answered: answered)
        return await withCheckedContinuation { continuation in
            collector.start(continuation)
            readabilityHandler = { handle in collector.receive(handle.availableData, from: handle) }
        }
    }
}

private final class OutputCollector: Sendable {
    private struct State {
        var data = Data()
        var continuation: CheckedContinuation<Data, Never>?
    }

    private let limit: Int
    private let answered: @Sendable (Data) -> Bool
    private let state = Mutex(State())

    init(limit: Int, answered: @escaping @Sendable (Data) -> Bool) {
        self.limit = limit
        self.answered = answered
    }

    func start(_ continuation: CheckedContinuation<Data, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// An empty chunk is end of file; the handler is dropped there, or at the cap or the answer.
    func receive(_ chunk: Data, from handle: FileHandle) {
        let finished = state.withLock { state -> (CheckedContinuation<Data, Never>, Data)? in
            guard let continuation = state.continuation else { return nil }
            state.data.append(chunk.prefix(limit - state.data.count))
            guard chunk.isEmpty || state.data.count >= limit || answered(state.data) else {
                return nil
            }
            state.continuation = nil
            return (continuation, state.data)
        }
        guard let (continuation, data) = finished else { return }
        handle.readabilityHandler = nil
        continuation.resume(returning: data)
    }
}
