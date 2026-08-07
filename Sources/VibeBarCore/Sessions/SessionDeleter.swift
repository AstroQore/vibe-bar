import Darwin
import Foundation

/// Removes session logs on explicit user request.
///
/// Session logs are read-only inputs everywhere else in Vibe Bar
/// (AGENTS.md § 5); this is the one documented exception, so it is
/// deliberately paranoid. Before anything is removed:
///
/// 1. an adapter must claim the provider — no adapter means no delete;
/// 2. every target and every provider root is canonicalized, and each
///    target must resolve strictly *below* one of the roots;
/// 3. the target is `lstat`ed — if the entry is itself a symlink we
///    refuse, because removing it would be acting on a path the
///    provider never wrote;
/// 4. the session file is re-parsed and its id must still match the
///    plan's expectation, so a summary that went stale between listing
///    and confirming cannot delete a different session.
///
/// A batch keeps going past a failed item and reports one outcome per
/// input, in input order.
public struct SessionDeleter: Sendable {
    private let homeDirectory: String

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    /// The registry is explicit rather than defaulted: its adapters
    /// supply the containment roots, so it has to have been built for
    /// the same home directory this deleter was.
    public func delete(
        _ summaries: [SessionSummary],
        registry: SessionProviderRegistry
    ) -> [SessionDeleteOutcome] {
        summaries.map { delete(one: $0, registry: registry) }
    }

    private func delete(one summary: SessionSummary, registry: SessionProviderRegistry) -> SessionDeleteOutcome {
        guard let adapter = registry.adapter(for: summary.provider) else {
            return .failed(summary, .unsupportedProvider)
        }

        let plan: SessionDeletionPlan
        do {
            plan = try adapter.deletionPlan(for: summary, homeDirectory: homeDirectory)
        } catch let error as SessionDeleteError {
            return .failed(summary, error)
        } catch {
            return .failed(summary, .validationUnreadable)
        }
        guard !plan.pathsToRemove.isEmpty else {
            return .failed(summary, .validationUnreadable)
        }

        let roots = adapter.roots(homeDirectory: homeDirectory)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !roots.isEmpty else { return .failed(summary, .pathEscapesProviderRoot) }

        let targets = plan.pathsToRemove + [plan.validationSourcePath]
        for path in targets {
            guard Self.isContained(path, in: roots) else {
                return .failed(summary, .pathEscapesProviderRoot)
            }
            if Self.isSymbolicLink(path) {
                return .failed(summary, .symlinkedTarget)
            }
        }

        let validationURL = URL(fileURLWithPath: plan.validationSourcePath)
        guard let reparsed = try? adapter.extractMetadata(fileURL: validationURL) else {
            return .failed(summary, .validationUnreadable)
        }
        guard reparsed.sessionID == plan.expectedSessionID else {
            return .failed(summary, .sessionIDMismatch)
        }

        for path in plan.pathsToRemove {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                return .failed(summary, .removalFailed(URL(fileURLWithPath: path).lastPathComponent))
            }
        }
        return .succeeded(summary)
    }

    /// Strictly below one of `roots` after symlink resolution. The root
    /// itself never qualifies, and a link that points outside the
    /// provider's tree resolves out of every root's prefix.
    static func isContained(_ path: String, in roots: [String]) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for root in roots where resolved.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
