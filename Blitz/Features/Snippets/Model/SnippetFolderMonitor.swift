import CoreServices
import Darwin
import Foundation

/// One FSEvents stream over the snippets folder, so a library of any size holds no descriptors.
@MainActor
final class SnippetFolderMonitor {
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    /// File-level, so an in-place write to an existing snippet reports like a create or a rename.
    private static let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
    private static let latency: CFTimeInterval = 0.05

    /// Nil when the stream cannot start; path-based, so a replaced folder stays watched.
    init?(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let paths = [Self.canonicalPath(of: directory)] as CFArray
        guard
            let stream = FSEventStreamCreate(
                nil, Self.callback, &context, paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, Self.flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    // Isolated: invalidating on the callback's own queue is what guarantees no late delivery.
    isolated deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// FSEvents reports real paths, so `/var/folders` must be watched as `/private/var/folders`.
    private static func canonicalPath(of directory: URL) -> String {
        guard let resolved = realpath(directory.path, nil) else { return directory.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let monitor = Unmanaged<SnippetFolderMonitor>.fromOpaque(info).takeUnretainedValue()
        // The stream's dispatch queue is `.main`, so this always lands on the main actor.
        MainActor.assumeIsolated { monitor.onChange() }
    }
}
