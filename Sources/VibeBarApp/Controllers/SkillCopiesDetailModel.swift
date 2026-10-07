import Combine
import Foundation
import VibeBarCore

/// State behind the copies and differences sheet of one skill.
///
/// Everything that touches the disk — the version inventory, a tree
/// comparison, a file's line diff — runs on a detached task, and the result
/// is cached by the content hashes of both sides, so flipping back to a pair
/// already compared, or re-rendering, costs nothing. The view reads only
/// stored values.
@MainActor
final class SkillCopiesDetailModel: ObservableObject {
    enum DiffLayout: String, CaseIterable, Identifiable {
        case unified
        case sideBySide
        var id: String { rawValue }
    }

    /// A finished file diff plus its side-by-side pairing, both derived off
    /// the main thread.
    struct FileDiffDisplay: Equatable {
        let diff: SkillFileDiff
        let sideBySide: [[SkillLineDiff.Row]]
    }

    @Published private(set) var inventory: SkillVersionInventory?
    @Published private(set) var baseID: String?
    @Published private(set) var comparedID: String?
    @Published private(set) var comparison: SkillTreeComparison?
    @Published private(set) var isComparing = false
    @Published private(set) var comparisonFailed = false
    @Published private(set) var selectedPath: String?
    @Published private(set) var fileDiff: FileDiffDisplay?
    @Published private(set) var isDiffing = false
    @Published var layout: DiffLayout = .unified

    private let service: SkillsService
    private var comparisonCache: [String: SkillTreeComparison] = [:]
    private var fileDiffCache: [String: FileDiffDisplay] = [:]
    /// Bumped on every request; a result that comes back for an older one is
    /// dropped instead of overwriting the newer selection.
    private var generation = 0
    private var loadedSignature: String?

    init(service: SkillsService) {
        self.service = service
    }

    var versions: [SkillVersion] { inventory?.versions ?? [] }

    func version(id: String?) -> SkillVersion? {
        guard let id else { return nil }
        return inventory?.versions.first { $0.id == id }
    }

    /// Rebuilds the inventory when the skill's on-disk state moved — content
    /// hashes, copies, projections. Called on appear and whenever the page's
    /// reload hands the sheet a different `Skill`.
    func load(_ skill: Skill) {
        let signature = Self.signature(of: skill)
        guard signature != loadedSignature else { return }
        loadedSignature = signature
        let service = self.service
        Task {
            let inventory = await Task.detached(priority: .userInitiated) {
                service.versionInventory(for: skill)
            }.value
            guard loadedSignature == signature else { return }
            apply(inventory)
        }
    }

    func setBase(_ id: String?) {
        guard id != baseID else { return }
        // Picking the compared version as the base swaps the pair, the same
        // as the other picker does.
        if comparedID == id { comparedID = baseID }
        baseID = id
        compare()
    }

    func setCompared(_ id: String?) {
        guard id != comparedID else { return }
        if id == baseID {
            // Picking the base as the other side swaps the pair rather than
            // comparing a version with itself.
            baseID = comparedID
        }
        comparedID = id
        compare()
    }

    func select(path: String?) {
        guard path != selectedPath else { return }
        selectedPath = path
        diffSelectedFile()
    }

    // MARK: - Internals

    private func apply(_ inventory: SkillVersionInventory) {
        self.inventory = inventory
        let ids = Set(inventory.versions.map(\.id))
        // Keep the user's pair while both sides still exist; otherwise start
        // from the most telling one.
        if let baseID, let comparedID, ids.contains(baseID), ids.contains(comparedID) {
            compare()
            return
        }
        if let baseline = inventory.recordedBaseline, let shared = inventory.shared {
            baseID = baseline.id
            comparedID = shared.id
        } else {
            baseID = inventory.shared?.id
            comparedID = defaultCompared(excluding: baseID)
        }
        compare()
    }

    private func defaultCompared(excluding base: String?) -> String? {
        let candidates = versions.filter { $0.id != base && $0.isReadable && $0.kind != .shared }
        return candidates.first { $0.comparison == .differs }?.id
            ?? candidates.first { $0.linkState != .shared }?.id
    }

    private func compare() {
        generation += 1
        let token = generation
        comparisonFailed = false
        guard let base = version(id: baseID), let compared = version(id: comparedID) else {
            comparison = nil
            fileDiff = nil
            selectedPath = nil
            return
        }
        guard base.isReadable || compared.isReadable else {
            comparison = nil
            fileDiff = nil
            selectedPath = nil
            comparisonFailed = true
            return
        }
        let key = Self.key(base, compared)
        if let cached = comparisonCache[key] {
            show(cached)
            return
        }
        // The pickers already name the new pair; the previous pair's file
        // list must not sit under them while the new scan runs.
        comparison = nil
        fileDiff = nil
        isComparing = true
        let scope = service.readScope
        let left = base.readableURL
        let right = compared.readableURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try? SkillContentDiff.compare(left: left, right: right, scope: scope)
            }.value
            guard token == generation else { return }
            isComparing = false
            guard let result else {
                comparison = nil
                fileDiff = nil
                comparisonFailed = true
                return
            }
            comparisonCache[key] = result
            show(result)
        }
    }

    private func show(_ result: SkillTreeComparison) {
        isComparing = false
        comparison = result
        // Stay on the open file when the new pair has it too.
        if let selectedPath, result.files.contains(where: { $0.path == selectedPath }) {
            diffSelectedFile()
        } else {
            selectedPath = result.defaultSelection
            diffSelectedFile()
        }
    }

    private func diffSelectedFile() {
        guard let path = selectedPath,
              let base = version(id: baseID),
              let compared = version(id: comparedID)
        else {
            fileDiff = nil
            return
        }
        let key = Self.key(base, compared) + "|" + path
        if let cached = fileDiffCache[key] {
            fileDiff = cached
            isDiffing = false
            return
        }
        let token = generation
        isDiffing = true
        let scope = service.readScope
        let left = base.readableURL
        let right = compared.readableURL
        Task {
            let display = await Task.detached(priority: .userInitiated) {
                let diff = SkillContentDiff.diffFile(path: path, left: left, right: right, scope: scope)
                let rows: [[SkillLineDiff.Row]] = if case let .text(lines) = diff {
                    lines.hunks.map(SkillLineDiff.sideBySideRows)
                } else {
                    []
                }
                return FileDiffDisplay(diff: diff, sideBySide: rows)
            }.value
            guard token == generation, selectedPath == path else { return }
            if fileDiffCache.count > 64 { fileDiffCache.removeAll() }
            fileDiffCache[key] = display
            fileDiff = display
            isDiffing = false
        }
    }

    /// Two versions are the same pair while their paths and content hashes
    /// are; a hash change (an edit, a replace) makes a new key.
    private static func key(_ base: SkillVersion, _ compared: SkillVersion) -> String {
        "\(base.id)#\(base.contentHash ?? "-")|\(compared.id)#\(compared.contentHash ?? "-")"
    }

    private static func signature(of skill: Skill) -> String {
        var parts = [skill.directory, skill.contentHash ?? "-", skill.localContentHash ?? "-"]
        parts += skill.otherCopies.map { "\($0.id)#\($0.contentHash ?? "-")" }
        parts += skill.apps.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.rawValue):\(skill.apps[$0]?.method.rawValue ?? "")" }
        return parts.joined(separator: "|")
    }
}
