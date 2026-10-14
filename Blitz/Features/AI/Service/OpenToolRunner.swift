import Darwin
import Foundation

/// Reads what a `mac_open` path is on disk; the catalog decides, and the launcher opens it.
enum OpenToolRunner {
    typealias Failure = FileToolCatalog.Failure

    /// Every link resolved, since opening a link opens what it points to.
    nonisolated static func resolved(_ path: String, homeDirectory: String) -> Result<String, Failure> {
        Result { () throws(Failure) in
            try FileToolRunner.resolved(path, keepsFinalLink: false, homeDirectory: homeDirectory)
        }
    }

    /// What is refused without asking: nothing there, or an item that would run or install.
    nonisolated static func inspect(
        _ path: String, homeDirectory: String
    ) -> Result<OpenToolCatalog.ItemKind, Failure> {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .failure(Failure(OpenToolCatalog.missing(path, homeDirectory: homeDirectory)))
        }
        let type = info.st_mode & S_IFMT
        let isProgram =
            type == S_IFREG && (path as NSString).pathExtension.isEmpty && info.st_mode & 0o111 != 0
        if let refusal = OpenToolCatalog.refusal(
            forPath: path, isProgram: isProgram, homeDirectory: homeDirectory)
        {
            return .failure(Failure(refusal))
        }
        return OpenToolCatalog.kind(
            of: path, isFolder: type == S_IFDIR, isFile: type == S_IFREG,
            homeDirectory: homeDirectory)
    }

    /// Nil while the path still resolves, and reads, as it did when the user was asked.
    nonisolated static func recheck(
        _ path: String, as resolved: String, kind: OpenToolCatalog.ItemKind, homeDirectory: String
    ) -> Failure? {
        guard case .success(let now) = self.resolved(path, homeDirectory: homeDirectory),
            now == resolved, case .success(kind) = inspect(now, homeDirectory: homeDirectory)
        else { return Failure(OpenToolCatalog.changed(resolved, homeDirectory: homeDirectory)) }
        return nil
    }
}
