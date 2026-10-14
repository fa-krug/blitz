import Foundation

/// What a chat model may do with the user's files, and how its calls and answers are spelled.
enum FileToolCatalog {
    static let origin = "Files"
    static let listName = "files_list"
    static let readName = "files_read"
    static let writeName = "files_write"
    static let moveName = "files_move"
    static let trashName = "files_trash"

    static let listDepth = 3
    static let listLimit = 500
    /// Text the model reads per call, so a long file floods neither its context nor Blitz's memory.
    static let readLimit = 64 * 1024
    /// Bytes read from a file at most; a larger file's tail is out of reach.
    static let scanLimit = 8 * 1024 * 1024
    static let writeLimit = 1024 * 1024
    /// How far in a file without a byte-order mark looks for the zero bytes of UTF-16.
    private static let sampleSize = 8 * 1024

    private typealias Invalid = AIToolArguments.Invalid

    enum WriteMode: String, CaseIterable, Equatable, Sendable {
        case create, overwrite, append
    }

    /// A call, already checked; its paths are absolute, and canonical once the runner resolves.
    enum Request: Equatable, Sendable {
        case list(path: String, recursive: Bool, includeHidden: Bool)
        case read(path: String, offset: Int, limit: Int?)
        case write(path: String, content: String, mode: WriteMode, createFolders: Bool)
        case move(from: String, to: String)
        case trash(path: String)

        var tool: AgentTool {
            switch self {
            case .list, .read: .filesRead
            case .write, .move, .trash: .filesWrite
            }
        }

        var paths: [String] {
            switch self {
            case .list(let path, _, _), .read(let path, _, _), .write(let path, _, _, _),
                .trash(let path):
                [path]
            case .move(let from, let to): [from, to]
            }
        }

        /// A move or the Trash acts on the item itself, so a link there is moved, never followed.
        var keepsFinalLink: Bool {
            switch self {
            case .list, .read, .write: false
            case .move, .trash: true
            }
        }

        /// The same call on other paths, in `paths` order.
        func replacingPaths(_ paths: [String]) -> Request {
            guard paths.count == self.paths.count else { return self }
            switch self {
            case .list(_, let recursive, let includeHidden):
                return .list(path: paths[0], recursive: recursive, includeHidden: includeHidden)
            case .read(_, let offset, let limit):
                return .read(path: paths[0], offset: offset, limit: limit)
            case .write(_, let content, let mode, let createFolders):
                return .write(
                    path: paths[0], content: content, mode: mode, createFolders: createFolders)
            case .move: return .move(from: paths[0], to: paths[1])
            case .trash: return .trash(path: paths[0])
            }
        }
    }

    /// What the disk said no to, worded for the model to read and correct.
    struct Failure: Error, Equatable, Sendable {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// One item of a listing; `path` is relative to the folder listed.
    struct Entry: Equatable, Sendable {
        enum Kind: String, Sendable {
            case file, folder, link, package
        }

        let path: String
        let kind: Kind
        let size: Int?
        let modified: Date?
    }

    struct Listing: Equatable, Sendable {
        let folder: String
        let recursive: Bool
        var entries: [Entry]
        /// Items a flat listing counted past `listLimit`.
        var omitted = 0
        /// A recursive listing stopped at `listLimit`, so how much more there is was not counted.
        var stoppedAtLimit = false
        /// Folders at `listDepth` that hold something, listed but not entered.
        var tooDeep = 0
        /// Folders not entered because a Deny rule covers them, relative to the folder listed.
        var denied: [String] = []
        var unreadable: [String] = []
    }

    static func handles(_ name: String) -> Bool {
        [listName, readName, writeName, moveName, trashName].contains(name)
    }

    private static let consent =
        " Blitz supplies this tool with the user's permission: the user may be asked to confirm "
        + "and may decline, and some folders, such as keys and Blitz's own data, are always "
        + "refused."

    private static let pathHelp = "absolute, starting with ~, or relative to the user's home folder"

    static func tools(read: Bool, write: Bool) -> [AITool] {
        (read ? [list(), readFile()] : []) + (write ? [writeFile(), move(), trash()] : [])
    }

    private static func list() -> AITool {
        AITool(
            name: listName,
            description: "List a folder on the user's Mac: each item's name, whether it is a "
                + "file or a folder, its size and when it was last modified. With recursive, the "
                + "folders inside are listed too, \(listDepth) levels deep; at most \(listLimit) "
                + "items come back." + consent,
            parameters: AIToolJSON.object(properties: [
                "path": AIToolJSON.string("The folder, \(pathHelp). Default: the home folder."),
                "recursive": AIToolJSON.boolean("List the folders inside too. Default: false."),
                "includeHidden": AIToolJSON.boolean(
                    "Include hidden items, such as names starting with a dot. Default: false.")
            ]),
            origin: origin, title: "List Folder")
    }

    private static func readFile() -> AITool {
        AITool(
            name: readName,
            description: "Read a text file on the user's Mac, UTF-8 or UTF-16; any other file "
                + "is refused. Read part of a long file with offset and limit. At most "
                + "\(readLimit / 1024) KB of text comes back per call, and the answer says where "
                + "it stopped." + consent,
            parameters: AIToolJSON.object(
                properties: [
                    "path": AIToolJSON.string("The file, \(pathHelp)."),
                    "offset": AIToolJSON.integer("The first line to read, from 1. Default: 1."),
                    "limit": AIToolJSON.integer("How many lines to read. Default: all that fit.")
                ],
                required: ["path"]),
            origin: origin, title: "Read File")
    }

    private static func writeFile() -> AITool {
        AITool(
            name: writeName,
            description: "Write text to a file on the user's Mac, as UTF-8. Mode create makes a "
                + "new file and fails if one exists; overwrite replaces the file's contents; "
                + "append adds to its end. Missing folders are made only with createFolders. "
                + "At most \(writeLimit / 1024 / 1024) MB of text per call." + consent,
            parameters: AIToolJSON.object(
                properties: [
                    "path": AIToolJSON.string("The file, \(pathHelp)."),
                    "content": AIToolJSON.string("The text to write."),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array(WriteMode.allCases.map { .string($0.rawValue) }),
                        "description": .string("create, overwrite or append. Default: create.")
                    ]),
                    "createFolders": AIToolJSON.boolean(
                        "Make any missing folders on the way. Default: false.")
                ],
                required: ["path", "content"]),
            origin: origin, title: "Write File")
    }

    private static func move() -> AITool {
        AITool(
            name: moveName,
            description: "Move or rename a file or folder on the user's Mac. It fails if "
                + "anything is already at the destination: nothing is ever replaced." + consent,
            parameters: AIToolJSON.object(
                properties: [
                    "from": AIToolJSON.string("What to move, \(pathHelp)."),
                    "to": AIToolJSON.string(
                        "Its new path, name included, \(pathHelp); its folder must exist.")
                ],
                required: ["from", "to"]),
            origin: origin, title: "Move File")
    }

    private static func trash() -> AITool {
        AITool(
            name: trashName,
            description: "Move a file or folder on the user's Mac to the Trash, where the user "
                + "can put it back. No tool deletes anything for good." + consent,
            parameters: AIToolJSON.object(
                properties: ["path": AIToolJSON.string("What to move to the Trash, \(pathHelp).")],
                required: ["path"]),
            origin: origin, title: "Move to Trash")
    }

    // MARK: - Reading a call

    static func request(
        name: String, arguments: String, homeDirectory: String
    ) throws(AIToolArguments.Invalid) -> Request {
        let arguments = try AIToolArguments(arguments)
        func path(_ key: String) throws(Invalid) -> String {
            absolute(try arguments.requiredString(key), homeDirectory: homeDirectory)
        }
        switch name {
        case listName:
            return .list(
                path: absolute(arguments.string("path") ?? "~", homeDirectory: homeDirectory),
                recursive: try flag("recursive", in: arguments),
                includeHidden: try flag("includeHidden", in: arguments))
        case readName:
            let offset = try count("offset", in: arguments) ?? 1
            return .read(
                path: try path("path"), offset: offset, limit: try count("limit", in: arguments))
        case writeName:
            guard let content = arguments.text("content") else {
                throw Invalid("\u{201C}content\u{201D} is required.")
            }
            let size = content.utf8.count
            guard size <= writeLimit else {
                throw Invalid(
                    "\u{201C}content\u{201D} is \(byteCount(size)); files_write takes at most "
                        + "\(byteCount(writeLimit)) a call. Write the rest with mode append.")
            }
            return .write(
                path: try path("path"), content: content, mode: try mode(in: arguments),
                createFolders: try flag("createFolders", in: arguments))
        case moveName:
            return .move(from: try path("from"), to: try path("to"))
        case trashName:
            return .trash(path: try path("path"))
        default:
            throw Invalid("Blitz has no file tool called \u{201C}\(name)\u{201D}.")
        }
    }

    /// `~` and a relative path as the shell tool reads a folder, with `.` and `..` resolved.
    static func absolute(_ path: String, homeDirectory: String) -> String {
        let resolved = ShellToolCatalog.resolved(path, homeDirectory: homeDirectory)
        return PathRule.canonical(resolved, homeDirectory: homeDirectory) ?? resolved
    }

    private static func flag(_ key: String, in arguments: AIToolArguments) throws(Invalid) -> Bool {
        guard arguments.contains(key) else { return false }
        guard let value = arguments.bool(key) else {
            throw Invalid("\u{201C}\(key)\u{201D} must be true or false.")
        }
        return value
    }

    private static func count(
        _ key: String, in arguments: AIToolArguments
    ) throws(Invalid) -> Int? {
        guard arguments.contains(key) else { return nil }
        guard let value = arguments.int(key), value >= 1 else {
            throw Invalid("\u{201C}\(key)\u{201D} must be a whole number from 1.")
        }
        return value
    }

    private static func mode(in arguments: AIToolArguments) throws(Invalid) -> WriteMode {
        guard let named = arguments.string("mode") else { return .create }
        guard let mode = WriteMode(rawValue: named.lowercased()) else {
            throw Invalid("\u{201C}mode\u{201D} must be create, overwrite or append.")
        }
        return mode
    }

    // MARK: - Asking

    /// `request` has its paths resolved, so the dialog names what would really be touched.
    static func prompt(
        for request: Request, homeDirectory: String, seeds: [PathRule] = PathRule.seeds
    ) -> AgentPrompt {
        let named = request.paths.map { shown($0, homeDirectory: homeDirectory) }
        let provider = "What it reads is sent to the model\u{2019}s provider."
        let title: String
        let message: String?
        switch request {
        case .list(_, let recursive, _):
            title = "Let the agent list \(named[0])?"
            let reach = recursive ? ", and of the folders inside it, \(listDepth) levels deep" : ""
            message = "It sees the names, sizes and dates of what the folder holds\(reach). "
                + provider
        case .read:
            title = "Let the agent read \(named[0])?"
            message = provider
        case .write(_, let content, let mode, let createFolders):
            title = "Let the agent write to \(named[0])?"
            let size = byteCount(content.utf8.count)
            let folders = createFolders ? ", making any folders it needs" : ""
            message =
                switch mode {
                case .create: "It would create this file with \(size) of text\(folders)."
                case .overwrite:
                    "It would replace whatever the file holds with \(size) of text\(folders)."
                case .append: "It would add \(size) of text to the end of the file\(folders)."
                }
        case .move:
            title = "Let the agent move \(named[0])?"
            message = "To \(named[1])"
        case .trash:
            title = "Let the agent move \(named[0]) to the Trash?"
            message = "It can be put back from the Trash."
        }
        return .files(
            request.tool, title: title, message: message,
            pattern: suggestedPattern(for: request, homeDirectory: homeDirectory, seeds: seeds))
    }

    /// One pattern covering every path of the call, or none: Always Allow must decide the call.
    static func suggestedPattern(
        for request: Request, homeDirectory: String, seeds: [PathRule] = PathRule.seeds
    ) -> String? {
        if case .list(let folder, _, _) = request {
            return AgentPolicy.suggestedPathPattern(
                for: folder, homeDirectory: homeDirectory, seeds: seeds, isFolder: true)
        }
        let patterns = request.paths.compactMap {
            AgentPolicy.suggestedPathPattern(for: $0, homeDirectory: homeDirectory, seeds: seeds)
        }
        guard patterns.count == request.paths.count, let first = patterns.first,
            patterns.allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    /// The root, the home folder and a folder holding it are never moved, even on an Allow row.
    static func isProtected(_ path: String, homeDirectory: String) -> Bool {
        let (path, home) = (path.lowercased(), homeDirectory.lowercased())
        return path == "/" || path == home || home.hasPrefix(path + "/")
    }

    // MARK: - Answers

    static func listing(_ listing: Listing, timeZone: TimeZone = .current) -> String {
        let depth = listing.recursive ? ", \(listDepth) levels deep" : ""
        guard !listing.entries.isEmpty else {
            return notes(for: listing, in: ["\(listing.folder) is empty."])
        }
        let total = listing.entries.count + listing.omitted
        let items =
            listing.stoppedAtLimit ? "the first \(listing.entries.count) items" : "\(total) items"
        let dates = Date.ISO8601FormatStyle(
            dateSeparator: .dash, dateTimeSeparator: .space, timeSeparator: .colon,
            timeZone: timeZone
        ).year().month().day().time(includingFractionalSeconds: false)
        let rows = listing.entries.map { entry in
            [
                entry.path, entry.kind.rawValue, entry.size.map(byteCount) ?? "-",
                entry.modified?.formatted(dates) ?? "-"
            ].joined(separator: "\t")
        }
        return notes(
            for: listing,
            in: ["\(listing.folder)\(depth), \(items):", "name\ttype\tsize\tmodified"] + rows)
    }

    private static func notes(for listing: Listing, in lines: [String]) -> String {
        var lines = lines
        if listing.omitted > 0 {
            lines.append(
                "[\(listing.omitted) more not listed: at most \(listLimit) items come back.]")
        }
        if listing.stoppedAtLimit {
            lines.append(
                "[Stopped at \(listLimit) items; there are more. List a folder inside for the "
                    + "rest.]")
        }
        if listing.tooDeep > 0 {
            lines.append(
                "[\(listing.tooDeep) folders \(listDepth) levels down are listed, not entered.]")
        }
        if !listing.denied.isEmpty {
            let denied = listing.denied.joined(separator: ", ")
            lines.append("[Not entered, as the agent rules deny it: \(denied).]")
        }
        if !listing.unreadable.isEmpty {
            lines.append("[Could not be read: \(listing.unreadable.joined(separator: ", ")).]")
        }
        return lines.joined(separator: "\n")
    }

    /// From line `offset`, at most `limit` lines and `cap` bytes; `isWhole` is false if cut.
    static func excerpt(
        of text: String, path: String, offset: Int, limit: Int?, isWhole: Bool,
        cap: Int = readLimit
    ) throws(Failure) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        // The scan limit may have cut the last line, so it is not counted as one.
        if !isWhole, lines.count > 1 { lines.removeLast() }
        guard !lines.isEmpty else { return "\(path) is empty." }
        guard offset <= lines.count else {
            throw Failure(
                "\(path) has \(lines.count) lines, so offset \(offset) is past its end.")
        }
        let end = min(lines.count, limit.map { offset - 1 + $0 } ?? lines.count)
        var kept: [Substring] = []
        var bytes = 0
        var cutLine = false
        for line in lines[(offset - 1)..<end] {
            let size = line.utf8.count + 1
            guard bytes + size <= cap else {
                if kept.isEmpty {
                    kept.append(prefix(of: line, bytes: cap))
                    cutLine = true
                }
                break
            }
            kept.append(line)
            bytes += size
        }
        let last = offset - 1 + kept.count
        let total = isWhole ? "\(lines.count)" : "at least \(lines.count)"
        let reach = isWhole ? "" : " (only its first \(byteCount(scanLimit)) can be read)"
        var answer = "\(path), lines \(offset)\u{2013}\(last) of \(total)\(reach):\n"
            + kept.joined(separator: "\n")
        if cutLine {
            answer += "\n[Line \(last) is longer than \(byteCount(cap)); only its start is shown.]"
        }
        if last < end {
            answer +=
                "\n[Cut at \(byteCount(cap)) after line \(last). Read on with offset \(last + 1).]"
        }
        return answer
    }

    private static func prefix(of line: Substring, bytes: Int) -> Substring {
        var end = line.startIndex
        var used = 0
        for index in line.indices {
            used += line[index].utf8.count
            guard used <= bytes else { break }
            end = line.index(after: index)
        }
        return line[..<end]
    }

    /// UTF-8 or UTF-16, told by a byte-order mark or by where the zero bytes fall; else nil.
    static func decodedText(_ data: Data, isWhole: Bool) -> String? {
        let bytes = [UInt8](data)
        let text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = utf8(bytes.dropFirst(3), isWhole: isWhole)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            text = utf16(bytes.dropFirst(2), littleEndian: true, isWhole: isWhole)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = utf16(bytes.dropFirst(2), littleEndian: false, isWhole: isWhole)
        } else if bytes.prefix(sampleSize).contains(0) {
            text = unmarkedUTF16(bytes.prefix(sampleSize)).flatMap {
                utf16(bytes[...], littleEndian: $0, isWhole: isWhole)
            }
        } else {
            text = utf8(bytes[...], isWhole: isWhole)
        }
        guard let text, !text.unicodeScalars.contains("\0") else { return nil }
        return text
    }

    private static func utf8(_ bytes: ArraySlice<UInt8>, isWhole: Bool) -> String? {
        String(
            validating: isWhole ? bytes : ShellToolCatalog.droppingPartialScalar(bytes),
            as: UTF8.self)
    }

    private static func utf16(
        _ bytes: ArraySlice<UInt8>, littleEndian: Bool, isWhole: Bool
    ) -> String? {
        var units = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).map { index in
            let (low, high) = littleEndian
                ? (bytes[index], bytes[index + 1]) : (bytes[index + 1], bytes[index])
            return UInt16(high) << 8 | UInt16(low)
        }
        if !isWhole, let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(validating: units, as: UTF16.self)
    }

    /// ASCII in UTF-16 puts a zero in every other byte: odd ones for little-endian, even for big.
    private static func unmarkedUTF16(_ sample: ArraySlice<UInt8>) -> Bool? {
        let pairs = sample.count / 2
        guard pairs > 0 else { return nil }
        let offsets = Array(sample)
        let evenZeros = stride(from: 0, to: pairs * 2, by: 2).count { offsets[$0] == 0 }
        let oddZeros = stride(from: 1, to: pairs * 2, by: 2).count { offsets[$0] == 0 }
        let threshold = pairs * 2 / 5
        if oddZeros >= threshold, evenZeros < pairs / 20 + 1 { return true }
        if evenZeros >= threshold, oddZeros < pairs / 20 + 1 { return false }
        return nil
    }

    static func notText(path: String, kind: String?) -> String {
        let named = kind.map { " (\($0))" } ?? ""
        return "\(path) cannot be read as text\(named): files_read reads UTF-8 and UTF-16 "
            + "text only."
    }

    static func written(_ mode: WriteMode, path: String, bytes: Int) -> String {
        switch mode {
        case .create: "Created \(path) with \(byteCount(bytes)) of text."
        case .overwrite: "Replaced the contents of \(path) with \(byteCount(bytes)) of text."
        case .append: "Added \(byteCount(bytes)) of text to the end of \(path)."
        }
    }

    static func moved(from: String, to: String) -> String { "Moved \(from) to \(to)." }

    static func trashed(_ path: String) -> String {
        "Moved \(path) to the Trash, where the user can put it back."
    }

    /// Fixed spelling, never the locale's, so the model and a harness read the same text.
    static func byteCount(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let rounded = (value * 10).rounded() / 10
        let number =
            rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) \(units[unit])"
    }

    /// A path as the model and the dialogs name it: under `~` where it can be, in quotes.
    static func shown(_ path: String, homeDirectory: String) -> String {
        quoted(ShellToolCatalog.abbreviated(path, homeDirectory: homeDirectory))
    }

    private static func quoted(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
}
