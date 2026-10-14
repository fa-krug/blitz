import Foundation

/// One ordered path pattern: `*` stays within a path component, `**` crosses them.
struct PathRule: Codable, Equatable, Identifiable, Sendable {
    /// Which rows a rule weighs, so a folder can be readable but not writable; Read covers opening.
    enum Access: String, CaseIterable, Codable, Identifiable, Sendable {
        case readAndWrite
        case read
        case write

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readAndWrite: "Read & Write"
            case .read: "Read"
            case .write: "Write"
            }
        }
    }

    let id: UUID
    var pattern: String
    var access: Access
    var decision: AgentDecision

    init(
        id: UUID = UUID(), pattern: String, access: Access = .readAndWrite,
        decision: AgentDecision
    ) {
        self.id = id
        self.pattern = pattern
        self.access = access
        self.decision = decision
    }

    func applies(to tool: AgentTool) -> Bool {
        switch access {
        case .readAndWrite: tool.usesPathRules
        case .read: tool.readsPaths
        case .write: tool == .filesWrite
        }
    }

    /// `path` must already have its symlinks resolved; this only resolves `~`, `.` and `..`.
    func matches(_ path: String, homeDirectory: String) -> Bool {
        guard let path = Self.canonical(path, homeDirectory: homeDirectory),
            let pattern = Self.components(of: pattern, homeDirectory: homeDirectory)
        else { return false }
        return Self.glob(pattern, matches: Self.split(path))
    }

    /// Pure, so it never touches the disk: a runner resolves symlinks before it asks.
    static func canonical(_ path: String, homeDirectory: String) -> String? {
        guard let components = components(of: path, homeDirectory: homeDirectory) else {
            return nil
        }
        return "/" + components.joined(separator: "/")
    }

    /// Deny where secrets or Blitz's own state live, the folder spelled as `AppPaths` does.
    static func seeds(bundleID: String) -> [PathRule] {
        let secret = [
            "~/.ssh/**", "~/.gnupg/**", "~/.aws/**", "~/Library/Keychains/**",
            "~/Library/Cookies/**", "~/Library/Application Support/*/Cookies*/**",
            "~/Library/Application Support/\(bundleID)/**",
            "~/Library/Preferences/\(bundleID).plist"
        ]
        let denied =
            secret.map { (pattern: $0, access: Access.readAndWrite) }
            + [(pattern: "/System/**", access: Access.write)]
        return denied.enumerated().map { index, seed in
            PathRule(
                id: seedID(index), pattern: seed.pattern, access: seed.access, decision: .deny)
        }
    }

    static var seeds: [PathRule] {
        seeds(bundleID: Bundle.main.bundleIdentifier ?? "de.fa-krug.blitz")
    }

    /// Two spellings of one pattern collapse to one, so Always Allow never adds a twin.
    static func collapsed(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        let lead = trimmed.hasPrefix("/") ? "/" : ""
        return lead + split(trimmed).joined(separator: "/")
    }

    /// Fixed, so a table given its seeds twice holds the same rules both times.
    private static func seedID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012d", index + 1)) ?? UUID()
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Nil for anything not absolute once `~` is expanded, so a relative path matches nothing.
    private static func components(of path: String, homeDirectory: String) -> [String]? {
        let expanded: String
        if path.hasPrefix("~"), !homeDirectory.hasPrefix("/") {
            return nil
        } else if path == "~" {
            expanded = homeDirectory
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory + path.dropFirst()
        } else {
            expanded = path
        }
        guard expanded.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in split(expanded) where component != "." {
            if component == ".." {
                _ = components.popLast()
            } else {
                components.append(component)
            }
        }
        return components
    }

    /// One row per pattern component: `**` keeps every reachable position, else one step.
    private static func glob(_ pattern: [String], matches path: [String]) -> Bool {
        var reachable = [Bool](repeating: false, count: path.count + 1)
        reachable[0] = true
        for component in pattern {
            var next = [Bool](repeating: false, count: path.count + 1)
            if component == "**" {
                var seen = false
                for index in reachable.indices {
                    seen = seen || reachable[index]
                    next[index] = seen
                }
            } else {
                for index in path.indices
                where reachable[index] && Self.component(component, matches: path[index]) {
                    next[index + 1] = true
                }
            }
            reachable = next
        }
        return reachable[path.count]
    }

    /// Case-insensitive, as a Mac volume usually is; characters compare as canonical equivalents.
    private static func component(_ pattern: String, matches text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var starTextIndex = 0
        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starTextIndex = textIndex
                patternIndex += 1
            } else if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex]
            {
                patternIndex += 1
                textIndex += 1
            } else if let star = starIndex {
                patternIndex = star + 1
                starTextIndex += 1
                textIndex = starTextIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == pattern.count
    }
}
