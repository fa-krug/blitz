import Foundation

/// Where the Search the Web fallback sends the typed query.
enum WebSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google
    case duckDuckGo
    case bing
    case brave
    case ecosia
    case kagi
    case startpage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
        }
    }

    private var endpoint: (host: String, path: String, parameter: String) {
        switch self {
        case .google: return ("www.google.com", "/search", "q")
        case .duckDuckGo: return ("duckduckgo.com", "/", "q")
        case .bing: return ("www.bing.com", "/search", "q")
        case .brave: return ("search.brave.com", "/search", "q")
        case .ecosia: return ("www.ecosia.org", "/search", "q")
        case .kagi: return ("kagi.com", "/search", "q")
        case .startpage: return ("www.startpage.com", "/sp/search", "query")
        }
    }

    /// The query only ever fills the one parameter, so no typed text can reshape the URL.
    func url(searching query: String) -> URL? {
        let endpoint = endpoint
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.path = endpoint.path
        components.queryItems = [URLQueryItem(name: endpoint.parameter, value: query)]
        // URLComponents leaves `+` bare, which every engine reads back as a space: `c++` → `c `.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
