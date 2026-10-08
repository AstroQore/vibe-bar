import Foundation

/// What "Reveal in Finder" selects for a session.
///
/// A session's `sourcePath` is usually its own log, but not always a file:
/// Devin addresses each session by a locator *inside* one shared database,
/// and a log can vanish between the last sweep and the click. Finder handed
/// a path that does not exist opens nothing useful, so the reveal walks up to
/// the nearest ancestor that does exist — the database for a Devin locator,
/// the folder a moved log used to sit in.
public enum SessionSourceReveal {
    /// The URL to select, or `nil` when nothing on the way up to `/` exists.
    public static func target(
        forSourcePath path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !fileExists(url.path) {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            guard parent.path != url.path, parent.path != "/" else { return nil }
            url = parent
        }
        return url
    }
}

/// Runs a "Reveal in Finder" without probing the filesystem on the main
/// actor.
///
/// `SessionSourceReveal.target` stats the path and may walk several of its
/// ancestors. On a network-mounted home, an unavailable volume or a File
/// Provider location that has to wake up, each of those calls can take
/// seconds, and on the main actor that is a frozen Workbench. So the probe
/// runs in `resolve` — off the main actor — and only showing the result in
/// Finder comes back to it. A reveal of a path whose probe is still running
/// is ignored, so repeated clicks on a slow path start one probe, not a
/// queue of them.
@MainActor
public final class SessionSourceRevealer {
    /// Finds what to select for a source path. Called off the main actor.
    public typealias Resolver = @Sendable (_ sourcePath: String) async -> URL?
    /// Shows the target. Called on the main actor.
    public typealias Presenter = @MainActor (_ target: URL) -> Void

    private let resolve: Resolver
    private let present: Presenter
    private var inFlight: Set<String> = []

    public init(resolve: @escaping Resolver = SessionSourceRevealer.offMainResolver(), present: @escaping Presenter) {
        self.resolve = resolve
        self.present = present
    }

    /// `SessionSourceReveal.target` on a detached task, never on the caller's
    /// executor — which for the Workbench is the main actor.
    public nonisolated static func offMainResolver(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Resolver {
        { path in
            await Task.detached(priority: .userInitiated) {
                SessionSourceReveal.target(forSourcePath: path, fileExists: fileExists)
            }.value
        }
    }

    /// True while the probe for this path has not come back.
    public func isRevealing(sourcePath: String) -> Bool {
        inFlight.contains(sourcePath)
    }

    /// Probe off the main actor, then show the target. Returns false when a
    /// reveal of the same path is already running and this one was dropped,
    /// or when nothing on the way up from the path exists. The in-flight mark
    /// is set before the first suspension, so two clicks delivered back to
    /// back cannot both start a probe.
    @discardableResult
    public func reveal(sourcePath: String) async -> Bool {
        guard inFlight.insert(sourcePath).inserted else { return false }
        defer { inFlight.remove(sourcePath) }
        guard let target = await resolve(sourcePath) else { return false }
        present(target)
        return true
    }
}
