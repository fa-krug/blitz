import Darwin
import Foundation

/// gitignore-flavoured: a bare pattern matches any component, one with `/` the path.
struct FileSearchIgnoreList: Sendable, Equatable {
    /// Compiled in, not stored, so changing the shipped rules reaches existing installs.
    static let defaults = [
        "node_modules", "DerivedData", "build", "dist", "target", "Pods", "*.photoslibrary"
    ]

    /// A shipped rule is governed by `removedDefaults` alone, even when `added` repeats it.
    static func patterns(added: [String], removedDefaults: [String]) -> [String] {
        var seen = Set(defaults)
        return defaults.filter { !removedDefaults.contains($0) }
            + added.filter { seen.insert($0).inserted }
    }

    private let literalNames: Set<String>
    private let nameGlobs: [Glob]
    private let pathGlobs: [Glob]

    init(patterns: [String]) {
        var literalNames: Set<String> = []
        var nameGlobs: [Glob] = []
        var pathGlobs: [Glob] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            // An interior NUL would silently truncate the pattern once it reaches `fnmatch`.
            guard !trimmed.isEmpty, !trimmed.contains("\0") else { continue }
            if trimmed.contains("/") {
                pathGlobs.append(Glob(trimmed))
            } else if trimmed.contains(where: Glob.isMetacharacter) {
                nameGlobs.append(Glob(trimmed))
            } else {
                literalNames.insert(trimmed.lowercased())
            }
        }
        self.literalNames = literalNames
        self.nameGlobs = nameGlobs
        self.pathGlobs = pathGlobs
    }

    func excludes(path: String) -> Bool {
        var name = ""
        for component in path.split(separator: "/") {
            name = String(component)
            if literalNames.contains(name.lowercased()) { return true }
            if nameGlobs.contains(where: { $0.matches(name) }) { return true }
        }
        return pathGlobs.contains { $0.couldMatchName(name) && $0.matches(path) }
    }

    /// Name globs Spotlight can evaluate itself, so ignored files never fill the candidate cap.
    var spotlightNameExclusions: [String] {
        nameGlobs.filter(\.isSpotlightExpressible).map(\.pattern)
    }
}

/// One compiled pattern; `fnmatch` runs without `FNM_PATHNAME`, so `*` spans `/`.
private struct Glob: Sendable, Equatable {
    let pattern: String
    private let terminated: ContiguousArray<CChar>
    /// A literal path matches only a candidate whose own name is its last component.
    private let literalPathName: ContiguousArray<CChar>?

    init(_ pattern: String) {
        self.pattern = pattern
        terminated = pattern.utf8CString
        if let slash = pattern.lastIndex(of: "/"), !pattern.hasSuffix("/"),
            !pattern.contains(where: { Self.isMetacharacter($0) || $0 == "\\" })
        {
            literalPathName = String(pattern[pattern.index(after: slash)...]).utf8CString
        } else {
            literalPathName = nil
        }
    }

    static func isMetacharacter(_ character: Character) -> Bool {
        character == "*" || character == "?" || character == "["
    }

    /// Spotlight reads `?` and `[` as literals and knows only `*`, so anything else stays local.
    var isSpotlightExpressible: Bool {
        !pattern.contains(where: { $0 == "?" || $0 == "[" || $0 == "\"" || $0 == "\\" })
    }

    func couldMatchName(_ name: String) -> Bool {
        guard let literalPathName else { return true }
        return literalPathName.withUnsafeBufferPointer { pattern in
            name.withCString { fnmatch(pattern.baseAddress!, $0, FNM_CASEFOLD) == 0 }
        }
    }

    func matches(_ candidate: String) -> Bool {
        terminated.withUnsafeBufferPointer { pattern in
            candidate.withCString { fnmatch(pattern.baseAddress!, $0, FNM_CASEFOLD) == 0 }
        }
    }
}
