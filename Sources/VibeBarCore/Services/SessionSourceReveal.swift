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
