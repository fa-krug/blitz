import Foundation

typealias AIProviderStream = AsyncThrowingStream<AIStreamEvent, Error>

/// Never main-bound: a stream does its own IO and decoding, and hands the main actor only events.
protocol AIProvider: Sendable {
    func stream(_ request: AIRequest) -> AIProviderStream
}

extension AsyncThrowingStream.Continuation where Element == AIStreamEvent, Failure == Error {
    /// Yields a barrier to wait at; a consumer already gone has nothing left to apply.
    func barrier() -> AIStreamBarrier {
        let barrier = AIStreamBarrier()
        if case .enqueued = yield(.barrier(barrier)) { return barrier }
        barrier.pass()
        return barrier
    }
}
