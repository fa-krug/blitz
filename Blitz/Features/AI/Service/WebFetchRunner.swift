import Foundation

/// Fetches one page a chat model asked for, off the main actor, on a session that keeps nothing.
enum WebFetchRunner {
    typealias Catalog = WebFetchToolCatalog
    typealias Failure = WebFetchToolCatalog.Failure

    /// Cacheless and cookieless, never `URLSession.shared`, so a fetch leaves nothing on disk.
    nonisolated static let session = makeSession(configuration())

    nonisolated static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Catalog.requestTimeout
        configuration.timeoutIntervalForResource = Catalog.totalTimeout
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,application/json;q=0.8,"
                + "*/*;q=0.5"
        ]
        return configuration
    }

    /// Redirects come back to `fetch` as responses, so every hop is checked before it is taken.
    nonisolated static func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    nonisolated static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        let named = (version as? String).map { "Blitz/\($0)" } ?? "Blitz"
        return "Mozilla/5.0 (Macintosh; compatible; \(named); agent web fetch)"
    }

    /// The page as text for the model, or the sentence saying why there is none.
    nonisolated static func run(
        _ request: Catalog.Request, session: URLSession = session
    ) async -> Result<String, Failure> {
        switch await fetch(request, session: session) {
        case .success(let page): Catalog.answer(for: page, maxCharacters: request.maxCharacters)
        case .failure(let failure): .failure(failure)
        }
    }

    /// The whole fetch, redirects included, races `totalTimeout`; the loser is cancelled.
    nonisolated static func fetch(
        _ request: Catalog.Request, session: URLSession = session,
        totalTimeout: TimeInterval = Catalog.totalTimeout, byteLimit: Int = Catalog.byteLimit
    ) async -> Result<Catalog.Page, Failure> {
        await withTaskGroup(of: Result<Catalog.Page, Failure>?.self) { group in
            group.addTask { await follow(request.url, session: session, byteLimit: byteLimit) }
            group.addTask {
                try? await Task.sleep(for: .seconds(totalTimeout))
                return Task.isCancelled ? nil : .failure(Catalog.timedOut(request.url))
            }
            for await outcome in group {
                guard let outcome else { continue }
                group.cancelAll()
                return outcome
            }
            return .failure(Catalog.timedOut(request.url))
        }
    }

    private nonisolated static func follow(
        _ approved: URL, session: URLSession, byteLimit: Int
    ) async -> Result<Catalog.Page, Failure> {
        var url = approved
        var redirects = 0
        while true {
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(
                    for: URLRequest(url: url, timeoutInterval: Catalog.requestTimeout))
            } catch {
                return .failure(Catalog.failure(for: error, url: url))
            }
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .failure(Failure("\(url.absoluteString) did not answer over HTTP."))
            }
            if [301, 302, 303, 307, 308].contains(http.statusCode),
                let location = http.value(forHTTPHeaderField: "Location")
            {
                bytes.task.cancel()
                guard redirects < Catalog.redirectLimit else {
                    return .failure(Catalog.tooManyRedirects(from: approved))
                }
                do throws(Failure) {
                    url = try Catalog.redirectTarget(location, from: url, approved: approved)
                } catch {
                    return .failure(error)
                }
                redirects += 1
                continue
            }
            if Catalog.contentKind(of: http.mimeType) == nil {
                bytes.task.cancel()
                return .failure(Catalog.refusedType(http.mimeType ?? "unlabeled", url: url))
            }
            return await body(
                of: bytes, response: http, requested: approved, url: url, byteLimit: byteLimit)
        }
    }

    /// Stops reading at `byteLimit`, so a huge or endless body costs no more than that.
    private nonisolated static func body(
        of bytes: URLSession.AsyncBytes, response: HTTPURLResponse, requested: URL, url: URL,
        byteLimit: Int
    ) async -> Result<Catalog.Page, Failure> {
        var body: [UInt8] = []
        body.reserveCapacity(min(max(Int(response.expectedContentLength), 0), byteLimit))
        var isTruncated = false
        do {
            for try await byte in bytes {
                guard body.count < byteLimit else {
                    isTruncated = true
                    break
                }
                body.append(byte)
            }
        } catch {
            return .failure(Catalog.failure(for: error, url: url))
        }
        if isTruncated { bytes.task.cancel() }
        return .success(
            Catalog.Page(
                requestedURL: requested, finalURL: url, status: response.statusCode,
                mimeType: response.mimeType, charset: response.textEncodingName,
                body: Data(body), isTruncated: isTruncated))
    }

    /// Declines every redirect, so the session hands the 3xx back for `follow` to check.
    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
