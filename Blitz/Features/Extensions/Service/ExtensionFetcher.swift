import Foundation
import Synchronization

/// Bodies cross the bridge base64-encoded, so binary responses survive.
final class ExtensionFetcher: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    enum FetchError: LocalizedError {
        case badURL(String)
        case socketUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let url): return "Invalid URL: \(url)"
            case .socketUnavailable(let path):
                return "Could not connect to the local service at \(path). Start its app or check the path."
            }
        }
    }

    func request(_ spec: RenderValue?) async throws -> [String: Any] {
        let fields = spec?.objectValue ?? [:]
        let urlString = fields["url"]?.stringValue ?? ""
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw FetchError.badURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = fields["method"]?.stringValue ?? "GET"
        for (name, value) in fields["headers"]?.objectValue ?? [:] {
            guard let text = value.stringValue else { continue }
            request.setValue(text, forHTTPHeaderField: name)
        }
        if let base64 = fields["bodyBase64"]?.stringValue, let body = Data(base64Encoded: base64) {
            request.httpBody = body
        }

        let (data, response) =
            if let socketPath = fields["socketPath"]?.stringValue, !socketPath.isEmpty {
                try await Self.unixSocketResponse(for: request, socketPath: socketPath)
            } else {
                try await session.data(for: request)
            }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        let status = http?.statusCode ?? 200
        return [
            "status": status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
            "headers": headers,
            "url": response.url?.absoluteString ?? urlString,
            "bodyBase64": data.base64EncodedString()
        ]
    }

    /// URLSession has no Unix-socket transport, so the system curl carries the request instead.
    private nonisolated static func unixSocketResponse(
        for request: URLRequest, socketPath: String
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.scheme == "http" || url.scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bodyFile = scratch.appendingPathComponent("response")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = try curlArguments(
            for: request, url: url, socketPath: socketPath, scratch: scratch, output: bodyFile)
        let report = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = report
        process.standardError = FileHandle.nullDevice

        let written = try await withTaskCancellationHandler {
            let exit = try process.runObservingExit()
            if Task.isCancelled, process.isRunning { process.terminate() }
            let written = try await drain(report, until: exit)
            try Task.checkCancellation()
            switch process.terminationStatus {
            case 0: return written
            case 7: throw FetchError.socketUnavailable(socketPath)
            case 28: throw URLError(.timedOut)
            default: throw URLError(.cannotConnectToHost)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        guard let metadata = try JSONSerialization.jsonObject(with: written) as? [String: Any],
            let status = (metadata["info"] as? [String: Any])?["http_code"] as? Int,
            let headers = metadata["headers"] as? [String: [String]],
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers.mapValues { $0.joined(separator: ", ") })
        else { throw URLError(.badServerResponse) }
        let body = request.httpMethod == "HEAD" ? Data() : (try? Data(contentsOf: bodyFile)) ?? Data()
        return (body, response)
    }

    /// `--disable` must come first, so a user's `~/.curlrc` never shapes an extension's request.
    private nonisolated static func curlArguments(
        for request: URLRequest, url: URL, socketPath: String, scratch: URL, output: URL
    ) throws -> [String] {
        let method = request.httpMethod ?? "GET"
        var arguments = [
            "--disable", "--silent", "--globoff", "--noproxy", "*", "--compressed",
            "--speed-limit", "1", "--speed-time", "60", "--unix-socket", socketPath,
            "--request", method, "--output", output.path,
            "--write-out", #"{"info":%{json},"headers":%{header_json}}"#
        ]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            arguments += ["--header", value.isEmpty ? "\(name);" : "\(name): \(value)"]
        }
        if let body = request.httpBody {
            let file = scratch.appendingPathComponent("request")
            try body.write(to: file)
            arguments += ["--data-binary", "@\(file.path)"]
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                arguments += ["--header", "Content-Type:"]
            }
        }
        // Without `--head`, curl waits for the body a HEAD response never sends.
        if method == "HEAD" { arguments.append("--head") }
        return arguments + ["--url", url.absoluteString]
    }

    /// The read blocks until curl exits, so it runs on a Dispatch worker, not the cooperative pool.
    private nonisolated static func drain(_ pipe: Pipe, until exit: ProcessExit) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        defer { exit.wait() }
                        return try pipe.fileHandleForReading.readToEnd() ?? Data()
                    })
            }
        }
    }
}

/// `ExtensionNodeShims` launches a child on the JS thread; `wait` collects it off that thread.
enum ExtensionAsyncProcess {
    enum ProcessError: LocalizedError {
        case notStarted

        var errorDescription: String? { "No running child process with that pid." }
    }

    struct Child: Sendable {
        let task: Process
        let exit: ProcessExit
        let stdout: Pipe
        let stderr: Pipe

        /// A child filling the 64 KB pipe blocks before it can exit, so the drain comes first.
        func collect(timeout: Double?) -> [String: Any] {
            var watchdog: DispatchSourceTimer?
            if let timeout, timeout > 0 { watchdog = terminationWatchdog(after: timeout / 1000) }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            exit.wait()
            watchdog?.cancel()

            return [
                "stdout": outData.base64EncodedString(),
                "stderr": errData.base64EncodedString(),
                "status": Int(task.terminationStatus),
                "signal": task.terminationReason == .uncaughtSignal ? "SIGTERM" : NSNull()
            ]
        }

        /// Signals the pid, not the `Process`, which a `@Sendable` timer handler cannot capture.
        fileprivate func terminationWatchdog(after seconds: Double) -> DispatchSourceTimer {
            let pid = task.processIdentifier
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { kill(pid, SIGTERM) }
            timer.resume()
            return timer
        }
    }

    /// Started by `enqueue` and not yet claimed by `wait`, keyed by pid.
    private static let uncollected = Mutex<[Int32: (child: Child, watchdog: DispatchSourceTimer?)]>([:])

    /// An app bundle inherits no login shell, so a bare `brew` would otherwise fail.
    static func resolveExecutable(_ command: String) -> URL? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        }
        let search =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
                "/sbin"
            ]
        for directory in search {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func enqueue(_ child: Child, timeout: Double?) {
        // Armed at launch: `wait` only starts once streaming output has ended.
        let watchdog = timeout.flatMap { $0 > 0 ? child.terminationWatchdog(after: $0 / 1000) : nil }
        uncollected.withLock { $0[child.task.processIdentifier] = (child, watchdog) }
    }

    /// Next chunk of fd 1 or 2, nil at EOF; `wait` then finds both pipes drained.
    static func read(_ arguments: [RenderValue]) async throws -> String? {
        guard let pid = arguments.first?.doubleValue.flatMap({ Int32(exactly: $0) }),
            let child = uncollected.withLock({ $0[pid]?.child })
        else { throw ProcessError.notStarted }
        let pipe = arguments[safe: 1]?.doubleValue == 2 ? child.stderr : child.stdout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.availableData
                continuation.resume(returning: data.isEmpty ? nil : data.base64EncodedString())
            }
        }
    }

    static func wait(_ pid: RenderValue?) async throws -> [String: Any] {
        guard let pid = pid?.doubleValue.flatMap({ Int32(exactly: $0) }),
            let entry = uncollected.withLock({ $0.removeValue(forKey: pid) })
        else { throw ProcessError.notStarted }

        let child = entry.child
        let result = await withCheckedContinuation { continuation in
            // The drain blocks until the child closes its output, which can be minutes away.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: child.collect(timeout: nil))
            }
        }
        entry.watchdog?.cancel()
        return result
    }
}
