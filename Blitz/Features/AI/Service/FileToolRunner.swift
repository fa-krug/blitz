import Darwin
import Foundation
import UniformTypeIdentifiers

/// Resolves and carries out one file call a chat model asked for; every function touches the disk.
enum FileToolRunner {
    typealias Request = FileToolCatalog.Request
    typealias Failure = FileToolCatalog.Failure

    /// A call read and resolved, with the home folder its `~` and the dialogs were spelled against.
    struct Prepared: Equatable, Sendable {
        let request: Request
        let resolved: Request
        let homeDirectory: String
    }

    nonisolated static func homeDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    nonisolated static func prepare(
        name: String, arguments: String, homeDirectory: String = homeDirectory()
    ) -> Result<Prepared, Failure> {
        let request: Request
        do throws(AIToolArguments.Invalid) {
            request = try FileToolCatalog.request(
                name: name, arguments: arguments, homeDirectory: homeDirectory)
        } catch {
            return .failure(Failure(error.message))
        }
        return Result { () throws(Failure) in
            Prepared(
                request: request, resolved: try resolved(request, homeDirectory: homeDirectory),
                homeDirectory: homeDirectory)
        }
    }

    /// Every path with its symlinks resolved, as `PathRule` needs; a move keeps a final link.
    nonisolated static func resolved(
        _ request: Request, homeDirectory: String
    ) throws(Failure) -> Request {
        var paths: [String] = []
        for path in request.paths {
            paths.append(
                try resolved(
                    path, keepsFinalLink: request.keepsFinalLink, homeDirectory: homeDirectory))
        }
        return request.replacingPaths(paths)
    }

    /// A path not there yet resolves its deepest existing folder and keeps the rest as named.
    nonisolated static func resolved(
        _ path: String, keepsFinalLink: Bool, homeDirectory: String
    ) throws(Failure) -> String {
        let path = FileToolCatalog.absolute(path, homeDirectory: homeDirectory)
        if keepsFinalLink {
            guard path != "/" else { throw Failure("\u{201C}/\u{201D} cannot be moved.") }
            let parent = try resolved(
                (path as NSString).deletingLastPathComponent, keepsFinalLink: false,
                homeDirectory: homeDirectory)
            return (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        }
        var existing = path
        var missing: [String] = []
        while existing != "/", !itemExists(existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let real = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        guard !isLink(real) else {
            throw Failure(
                "\(FileToolCatalog.shown(path, homeDirectory: homeDirectory)) goes through a link "
                    + "to something that is not there.")
        }
        return missing.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// What is refused without asking: a file that is not there, a folder where a file should be.
    nonisolated static func preflight(_ prepared: Prepared) -> Failure? {
        let home = prepared.homeDirectory
        func shown(_ path: String) -> String { FileToolCatalog.shown(path, homeDirectory: home) }
        switch prepared.resolved {
        case .list(let path, _, _):
            guard itemExists(path) else { return Failure("There is no folder at \(shown(path)).") }
            guard isFolder(path) else {
                return Failure("\(shown(path)) is a file, not a folder; files_read reads it.")
            }
        case .read(let path, _, _):
            guard itemExists(path) else { return Failure("There is no file at \(shown(path)).") }
            guard !isFolder(path) else {
                return Failure("\(shown(path)) is a folder; files_list lists it.")
            }
            guard isRegularFile(path) else {
                return Failure("\(shown(path)) is not a regular file, so it cannot be read.")
            }
        case .write(let path, _, let mode, let createFolders):
            if itemExists(path) {
                guard !isFolder(path) else { return Failure("\(shown(path)) is a folder.") }
                guard mode != .create else {
                    return Failure(
                        "\(shown(path)) already exists; use mode overwrite or append to change it.")
                }
                guard isRegularFile(path) else {
                    return Failure("\(shown(path)) is not a regular file, so it cannot be written.")
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            if !itemExists(parent) {
                guard createFolders else {
                    return Failure(
                        "There is no folder at \(shown(parent)); pass createFolders true to "
                            + "make it.")
                }
            } else if !isFolder(parent) {
                return Failure("\(shown(parent)) is a file, not a folder.")
            }
        case .move(let from, let to):
            guard itemExists(from) else { return Failure("There is nothing at \(shown(from)).") }
            guard !FileToolCatalog.isProtected(from, homeDirectory: home) else {
                return Failure("\(shown(from)) is never moved.")
            }
            guard !itemExists(to) else {
                return Failure(
                    "Something is already at \(shown(to)), and files_move never replaces it. "
                        + "Pick another name, or move that to the Trash first.")
            }
            let parent = (to as NSString).deletingLastPathComponent
            guard isFolder(parent) else {
                return Failure("There is no folder at \(shown(parent)).")
            }
        case .trash(let path):
            guard itemExists(path) else { return Failure("There is nothing at \(shown(path)).") }
            guard !FileToolCatalog.isProtected(path, homeDirectory: home) else {
                return Failure("\(shown(path)) is never moved to the Trash.")
            }
        }
        return nil
    }

    /// Resolved again first: a path that resolves elsewhere now changed while the user was asked.
    nonisolated static func run(
        _ prepared: Prepared, deniedRules: [PathRule] = [],
        trash: (URL) throws -> Void = moveToTrash
    ) -> Result<String, Failure> {
        let home = prepared.homeDirectory
        let again = Result { () throws(Failure) in
            try resolved(prepared.request, homeDirectory: home)
        }
        guard case .success(let now) = again, now == prepared.resolved else {
            let path = FileToolCatalog.shown(prepared.resolved.paths[0], homeDirectory: home)
            return .failure(
                Failure("\(path) changed while the user was asked, so nothing was done."))
        }
        if let failure = preflight(prepared) { return .failure(failure) }
        return Result { () throws(Failure) in
            try perform(now, homeDirectory: home, deniedRules: deniedRules, trash: trash)
        }
    }

    nonisolated private static func perform(
        _ request: Request, homeDirectory home: String, deniedRules: [PathRule],
        trash: (URL) throws -> Void
    ) throws(Failure) -> String {
        func shown(_ path: String) -> String { FileToolCatalog.shown(path, homeDirectory: home) }
        switch request {
        case .list(let path, let recursive, let includeHidden):
            return FileToolCatalog.listing(
                try list(
                    path, shown: shown(path), recursive: recursive, includeHidden: includeHidden,
                    deniedRules: deniedRules, homeDirectory: home))
        case .read(let path, let offset, let limit):
            return try read(path, shown: shown(path), offset: offset, limit: limit)
        case .write(let path, let content, let mode, let createFolders):
            try write(
                content, to: path, shown: shown(path), mode: mode, createFolders: createFolders)
            return FileToolCatalog.written(mode, path: shown(path), bytes: content.utf8.count)
        case .move(let from, let to):
            try attempt("move \(shown(from))") {
                try FileManager.default.moveItem(atPath: from, toPath: to)
            }
            return FileToolCatalog.moved(from: shown(from), to: shown(to))
        case .trash(let path):
            try attempt("move \(shown(path)) to the Trash") {
                try trash(URL(fileURLWithPath: path))
            }
            return FileToolCatalog.trashed(shown(path))
        }
    }

    /// Never `removeItem`: there is deliberately no way for the agent to delete for good.
    nonisolated static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Listing

    private static let listedKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey
    ]

    nonisolated static func list(
        _ path: String, shown: String, recursive: Bool, includeHidden: Bool,
        deniedRules: [PathRule], homeDirectory: String
    ) throws(Failure) -> FileToolCatalog.Listing {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        func children(of folder: String) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true),
                includingPropertiesForKeys: listedKeys, options: options
            ).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        }
        let top: [URL]
        do {
            top = try children(of: path)
        } catch {
            throw Failure("\(shown) could not be read: \(error.localizedDescription)")
        }
        var listing = FileToolCatalog.Listing(folder: shown, recursive: recursive, entries: [])
        // Spelled from the resolved folder: the URLs a listing returns may gain `/private`.
        func visit(_ urls: [URL], in folder: String, under relative: String, depth: Int) {
            for (index, url) in urls.enumerated() {
                guard listing.entries.count < FileToolCatalog.listLimit else {
                    if recursive {
                        listing.stoppedAtLimit = true
                    } else {
                        listing.omitted = urls.count - index
                    }
                    return
                }
                let entry = Self.entry(url, relative: relative)
                listing.entries.append(entry)
                guard recursive, entry.kind == .folder else { continue }
                let child = (folder as NSString).appendingPathComponent(url.lastPathComponent)
                if deniedRules.contains(where: { $0.matches(child, homeDirectory: homeDirectory) })
                {
                    listing.denied.append(entry.path)
                    continue
                }
                guard let inside = try? children(of: child) else {
                    listing.unreadable.append(entry.path)
                    continue
                }
                guard depth < FileToolCatalog.listDepth else {
                    if !inside.isEmpty { listing.tooDeep += 1 }
                    continue
                }
                visit(inside, in: child, under: entry.path, depth: depth + 1)
                if listing.stoppedAtLimit { return }
            }
        }
        visit(top, in: path, under: "", depth: 1)
        return listing
    }

    nonisolated private static func entry(_ url: URL, relative: String) -> FileToolCatalog.Entry {
        let values = try? url.resourceValues(forKeys: Set(listedKeys))
        let kind: FileToolCatalog.Entry.Kind =
            if values?.isSymbolicLink == true {
                .link
            } else if values?.isPackage == true {
                .package
            } else if values?.isDirectory == true {
                .folder
            } else {
                .file
            }
        return FileToolCatalog.Entry(
            path: relative.isEmpty
                ? url.lastPathComponent : "\(relative)/\(url.lastPathComponent)",
            kind: kind, size: kind == .file ? values?.fileSize : nil,
            modified: values?.contentModificationDate)
    }

    // MARK: - Reading and writing

    nonisolated static func read(
        _ path: String, shown: String, offset: Int, limit: Int?
    ) throws(Failure) -> String {
        let data: Data
        let size: Int
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            data = try handle.read(upToCount: FileToolCatalog.scanLimit) ?? Data()
        } catch {
            throw Failure("\(shown) could not be read: \(error.localizedDescription)")
        }
        let isWhole = size <= data.count
        guard let text = FileToolCatalog.decodedText(data, isWhole: isWhole) else {
            let pathExtension = (path as NSString).pathExtension
            let kind = pathExtension.isEmpty
                ? nil : UTType(filenameExtension: pathExtension)?.localizedDescription
            throw Failure(FileToolCatalog.notText(path: shown, kind: kind))
        }
        return try FileToolCatalog.excerpt(
            of: text, path: shown, offset: offset, limit: limit, isWhole: isWhole)
    }

    /// Create never follows or replaces whatever appeared since it was checked.
    nonisolated static func write(
        _ content: String, to path: String, shown: String, mode: FileToolCatalog.WriteMode,
        createFolders: Bool
    ) throws(Failure) {
        let url = URL(fileURLWithPath: path)
        let data = Data(content.utf8)
        try attempt("write to \(shown)") {
            if createFolders {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            switch mode {
            case .create:
                try data.write(to: url, options: .withoutOverwriting)
            case .overwrite:
                try data.write(to: url)
            case .append:
                guard itemExists(path) else {
                    try data.write(to: url, options: .withoutOverwriting)
                    return
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        }
    }

    nonisolated private static func attempt(
        _ action: String, _ body: () throws -> Void
    ) throws(Failure) {
        do {
            try body()
        } catch {
            throw Failure("Could not \(action): \(error.localizedDescription)")
        }
    }

    // MARK: - The disk

    /// `lstat`, so a link counts as there even when what it points to is not.
    nonisolated static func itemExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    nonisolated private static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    nonisolated private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Not a pipe or a device, which a read could hang on forever.
    nonisolated private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
