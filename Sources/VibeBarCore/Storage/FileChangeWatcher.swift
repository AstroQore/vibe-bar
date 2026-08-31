import Foundation

/// Notices when a file changes underneath this process.
///
/// Every store here writes atomically — a temporary file and a rename — which
/// is what makes this more than one `DispatchSource`. A rename puts a *new*
/// inode at the path, and a source watching the old file descriptor keeps
/// watching the old inode, which nothing will ever write to again. So a
/// delete or rename is not just an event to report, it is the signal to
/// re-open the path and start again.
///
/// Events are coalesced: one atomic replace can produce several, and a caller
/// re-reading the file wants to do it once, after the dust settles.
public final class FileChangeWatcher {
    private let url: URL
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    /// How often to look again for a file that is not there yet. Slower than
    /// the debounce on purpose: a path that never appears should not hold a
    /// timer at the rate a burst of writes is coalesced at.
    private static let retryInterval: DispatchTimeInterval = .milliseconds(500)
    /// Guards `source` and `pending` against `start`/`stop`/`cancel` racing.
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false
    /// Whether the last attempt to open the path found nothing there.
    private var awaitingFile = false

    public init(
        url: URL,
        debounceMilliseconds: Int = 150,
        queue: DispatchQueue = DispatchQueue(
            label: "com.astroqore.VibeBar.file-watch", qos: .utility
        ),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounce = .milliseconds(debounceMilliseconds)
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        arm()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let source = self.source
        let pending = self.pending
        self.source = nil
        self.pending = nil
        lock.unlock()
        pending?.cancel()
        source?.cancel()
    }

    /// Open the path and watch whatever is there now.
    ///
    /// A missing file is not a failure: settings.json does not exist until the
    /// first write, and a rename can be observed in the instant between the
    /// unlink and the link. Retry on the same timer the debounce uses, so a
    /// file that appears later is picked up without spinning.
    private func arm() {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            lock.lock()
            awaitingFile = true
            lock.unlock()
            queue.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                self?.arm()
            }
            return
        }
        // Opening what was missing a moment ago *is* the change: the write
        // that created the file happened before there was a descriptor to
        // watch, so no event will ever arrive for it.
        lock.lock()
        let appeared = awaitingFile
        awaitingFile = false
        lock.unlock()
        if appeared { schedule() }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.schedule()
            // The path now points at a different inode (or none), so this
            // source is watching a file nobody will write to again.
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                source.cancel()
                self.queue.asyncAfter(deadline: .now() + self.debounce) { [weak self] in
                    self?.arm()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }

        lock.lock()
        if self.stopped {
            lock.unlock()
            source.cancel()
            return
        }
        self.source?.cancel()
        self.source = source
        lock.unlock()
        source.resume()
    }

    private func schedule() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stopped = self.stopped
            self.lock.unlock()
            guard !stopped else { return }
            self.onChange()
        }
        lock.lock()
        pending?.cancel()
        pending = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
