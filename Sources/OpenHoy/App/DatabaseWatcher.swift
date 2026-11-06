import CoreServices
import Foundation

/// Watches the Messages folder with FSEvents and calls `onChange` shortly after a write
/// to chat.db, its -wal or -shm. Events are only a hint: the refresh that follows
/// asks SQLite (`PRAGMA data_version`) whether anything was actually committed.
final class DatabaseWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init?(directory: URL, latency: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // Only chat.db and its -wal / -shm matter; ignore attachments, caches and the rest.
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let relevant = (0..<count).contains { i in
                (String(cString: names[i]) as NSString).lastPathComponent.hasPrefix("chat.db")
            }
            if relevant { Unmanaged<DatabaseWatcher>.fromOpaque(info).takeUnretainedValue().onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [directory.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
