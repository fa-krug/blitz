import Foundation

/// Lists and runs shortcuts through Apple's own `shortcuts` tool, which needs no permission.
enum AppleShortcutRunner {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func list() async throws(Failure) -> [AppleShortcut] {
        let result = try await invoke(["list", "--show-identifiers"], timeout: 10)
        return AppleShortcut.parseList(result.output)
    }

    /// Never timed out: a shortcut can legitimately sit waiting on a dialog of its own.
    static func run(id: UUID) async throws(Failure) {
        _ = try await invoke(["run", id.uuidString], timeout: nil)
    }

    /// For the agent: text in through a file, and whatever the shortcut returns read back as bytes.
    static func run(id: UUID, input: String?) async throws(Failure) -> Data? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-shortcut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        var arguments = ["run", id.uuidString, "--output-path", output.path]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let input {
                let file = folder.appendingPathComponent("input.txt")
                try Data(input.utf8).write(to: file)
                arguments += ["--input-path", file.path]
            }
        } catch {
            throw Failure(errorDescription: error.localizedDescription)
        }
        _ = try await invoke(arguments, timeout: nil)
        return try? Data(contentsOf: output)
    }

    private static func invoke(
        _ arguments: [String], timeout: TimeInterval?
    ) async throws(Failure) -> ToolRunner.Result {
        let result: ToolRunner.Result
        do {
            result = try await ToolRunner.run(executable, arguments, timeout: timeout)
        } catch {
            throw Failure(errorDescription: error.localizedDescription)
        }
        guard result.succeeded else { throw Failure(errorDescription: result.tail) }
        return result
    }
}
