import AppKit
import AuthenticationServices

struct ExtensionOAuthAuthorizeOptions: Sendable {
    let url: URL
    let state: String?
    let callbackScheme: String
}

struct ExtensionOAuthAuthorizeResult: Sendable {
    let authorizationCode: String
    let accessToken: String?
    let state: String?
}

/// One browser sign-in. It catches its own redirect, so an installed Raycast cannot take it.
@MainActor
final class ExtensionOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private nonisolated let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    enum OAuthError: LocalizedError {
        case canceled
        case failed(String)
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .canceled: return "Authentication was canceled."
            case .failed(let message): return message
            case .stateMismatch: return "OAuth state mismatch. Please try authenticating again."
            }
        }
    }

    init(anchor: NSWindow?) {
        self.anchor = anchor ?? NSApp.keyWindow ?? ASPresentationAnchor()
        super.init()
    }

    func authorize(options: ExtensionOAuthAuthorizeOptions) async throws -> ExtensionOAuthAuthorizeResult {
        let redirect = try await run(url: options.url, callbackScheme: options.callbackScheme)
        let params = Self.parseCallback(url: redirect)
        if let error = params["error"] {
            throw OAuthError.failed(params["error_description"] ?? error)
        }
        // Raycast's web redirect page can drop `state`, so only a returned one can be checked.
        if let expected = options.state, !expected.isEmpty, let received = params["state"],
            received != expected
        {
            throw OAuthError.stateMismatch
        }
        return ExtensionOAuthAuthorizeResult(
            authorizationCode: params["code"] ?? "", accessToken: params["access_token"],
            state: params["state"])
    }

    /// Closes the sign-in window; the waiting `authorize` throws `canceled`.
    func cancel() {
        let session = session
        finish(.failure(OAuthError.canceled))
        session?.cancel()
    }

    private func run(url: URL, callbackScheme: String) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url, callback: .customScheme(callbackScheme)
                ) { @Sendable redirect, error in
                    Task { @MainActor in self.complete(redirect: redirect, error: error) }
                }
                session.presentationContextProvider = self
                // Shares browser cookies, so a provider the user is signed in to skips its login.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    self.finish(.failure(OAuthError.failed("Couldn't open the sign-in window.")))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func complete(redirect: URL?, error: Error?) {
        if let redirect {
            finish(.success(redirect))
        } else if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
            finish(.failure(error))
        } else {
            finish(.failure(OAuthError.canceled))
        }
    }

    /// The only resume: `cancel()` and the session's own completion can both arrive.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }

    // MARK: - URL Parsing

    static func parseCallback(url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        var result: [String: String] = [:]
        if let queryItems = components.queryItems {
            for item in queryItems {
                result[item.name] = item.value ?? ""
            }
        }
        // Implicit and hash callbacks arrive as `raycast://oauth#code=…`.
        if let fragment = components.fragment, !fragment.isEmpty {
            let pairs = fragment.split(separator: "&")
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    let val = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    result[key] = val
                }
            }
        }
        return result
    }
}
