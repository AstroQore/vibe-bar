import Foundation

struct AgentInstructionProjectionReceipt: Codable {
    let target: AgentLibraryTarget
    let destination: String
    let backupID: String
    let installed: Bool
}

extension AgentLibraryService {
    public func instructionInventory() -> [AgentInstructionSummary] {
        let receipts = try? instructionReceipts()
        let canonicalEnd = files.linkInfo(AgentLibraryFiles.canonical).resolved
        var rows = [instructionSummary(id: "canonical", target: nil, relative: AgentLibraryFiles.canonical,
                                       receipts: receipts, canonicalEnd: canonicalEnd)]
        for target in AgentLibraryTarget.allCases {
            if let relative = target.instructionRelativePath {
                rows.append(instructionSummary(id: target.rawValue, target: target, relative: relative,
                                               receipts: receipts, canonicalEnd: canonicalEnd))
            } else {
                rows.append(.init(id: target.rawValue, target: target, path: "", resolvedPath: nil,
                                  revision: "unavailable", status: .unsupported, isSymlink: false,
                                  isCanonical: false, overridePath: nil, projectionOwned: false,
                                  errorCode: AgentLibraryError.unsupportedTarget.code,
                                  linkDestination: nil, sharesCanonical: false))
            }
        }
        return rows
    }

    public func readInstruction(id: String, expectedRevision: String) throws -> AgentInstructionDocument {
        let relative = try instructionPath(id)
        let snapshot = try files.guarded(relative, revision: expectedRevision)
        guard let data = snapshot.data else { throw AgentLibraryError.notFound }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentLibraryError.invalidDocument }
        return .init(id: id, text: text, revision: snapshot.revision)
    }

    public func saveInstruction(id: String, text: String, expectedRevision: String) throws -> AgentLibraryMutationResult {
        let relative = try instructionPath(id)
        let snapshot = try files.guarded(relative, revision: expectedRevision)
        if snapshot.data == Data(text.utf8) {
            return .init(unchanged: AgentLibraryTarget(rawValue: id).map { [$0] } ?? [])
        }
        let backup = try files.write(relative, data: Data(text.utf8), expectedRevision: expectedRevision,
                                     allowInstructionLink: true)
        return .init(changed: AgentLibraryTarget(rawValue: id).map { [$0] } ?? [], backups: [backup])
    }

    public func linkCanonicalInstructions(targets: [AgentLibraryTarget: String]) throws -> AgentLibraryMutationResult {
        let canonical = try files.snapshot(AgentLibraryFiles.canonical)
        guard let text = canonical.data else { throw AgentLibraryError.missingCanonical }
        var receipts = try instructionReceipts()
        var result = AgentLibraryMutationResult()
        for target in AgentLibraryTarget.allCases where targets[target] != nil {
            do {
                guard let relative = target.instructionRelativePath else { throw AgentLibraryError.unsupportedTarget }
                _ = try files.guarded(AgentLibraryFiles.canonical, revision: canonical.revision)
                let before = try files.guarded(relative, revision: targets[target]!)
                // The canonical file may already point to this agent's own
                // file. Replacing that source with a reverse link creates a
                // cycle, so keep the existing shared source intact.
                if before.logical == canonical.resolved {
                    result.unchanged.append(target)
                    continue
                }
                if before.isSymlink {
                    // Existing shared-source links belong to the user. Reuse
                    // them without claiming ownership or breaking the chain.
                    guard before.resolved == canonical.resolved else { throw AgentLibraryError.sameNameConflict }
                    result.unchanged.append(target)
                    continue
                }
                if let old = before.data, old != text { throw AgentLibraryError.sameNameConflict }
                let backup = try files.backupFile(relative)
                _ = try files.guarded(relative, revision: targets[target]!)
                let destination = try files.url(AgentLibraryFiles.canonical).path
                let receipt = AgentInstructionProjectionReceipt(target: target, destination: destination, backupID: backup.id, installed: false)
                // Persist ownership before installing the projection. If the
                // link fails, removal still refuses a non-matching leaf.
                receipts[target.rawValue] = receipt
                try saveInstructionReceipts(receipts)
                try files.atomicSymlink(destination, to: files.url(relative))
                result.changed.append(target); result.backups.append(backup)
                receipts[target.rawValue] = .init(target: target, destination: destination, backupID: backup.id, installed: true)
                try saveInstructionReceipts(receipts)
            } catch { result.problems.append(.init(target: target, code: Self.code(error))) }
        }
        return result
    }

    public func removeInstructionProjection(target: AgentLibraryTarget, expectedRevision: String) throws -> AgentLibraryMutationResult {
        guard let relative = target.instructionRelativePath else { throw AgentLibraryError.unsupportedTarget }
        var receipts = try instructionReceipts()
        guard let receipt = receipts[target.rawValue], receipt.installed else { throw AgentLibraryError.notOwnedProjection }
        let snapshot = try files.guarded(relative, revision: expectedRevision)
        guard snapshot.isSymlink,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: snapshot.logical.path)) == receipt.destination else {
            throw AgentLibraryError.projectionModified
        }
        let record = try files.backup(receipt.backupID)
        guard record.relativePath == relative else { throw AgentLibraryError.invalidReceipt }
        let safetyCopy = try files.restore(record, expectedRevision: expectedRevision)
        receipts.removeValue(forKey: target.rawValue)
        try saveInstructionReceipts(receipts)
        return .init(changed: [target], backups: [safetyCopy])
    }

    func instructionPath(_ id: String) throws -> String {
        if id == "canonical" { return AgentLibraryFiles.canonical }
        guard let target = AgentLibraryTarget(rawValue: id), let path = target.instructionRelativePath else {
            throw AgentLibraryError.unsupportedTarget
        }
        return path
    }
    func instructionSummary(id: String, target: AgentLibraryTarget?, relative: String,
                            receipts: [String: AgentInstructionProjectionReceipt]?,
                            canonicalEnd: String?) -> AgentInstructionSummary {
        let link = files.linkInfo(relative)
        // Path identity only. A chain that ends outside the managed files is
        // still recognised as shared when the canonical file's chain ends at
        // the same place; reading and writing through it stay refused.
        let shares = target != nil && canonicalEnd != nil && link.resolved == canonicalEnd
        do {
            let snapshot = try files.snapshot(relative)
            let overrideSnapshot = target == .codex ? (try? files.snapshot(AgentLibraryFiles.codexOverride)) : nil
            let overrideText = overrideSnapshot?.data.flatMap { String(data: $0, encoding: .utf8) }
            let hasOverride = overrideText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let owned = snapshot.isSymlink && receipts?[id]?.installed == true && receipts?[id]?.destination ==
                (try? FileManager.default.destinationOfSymbolicLink(atPath: snapshot.logical.path))
            return .init(id: id, target: target, path: snapshot.logical.path, resolvedPath: snapshot.resolved.path,
                         revision: snapshot.revision, status: snapshot.data == nil ? .missing : .ready,
                         isSymlink: snapshot.isSymlink, isCanonical: id == "canonical",
                         overridePath: hasOverride ? overrideSnapshot?.logical.path : nil,
                         projectionOwned: owned, errorCode: receipts == nil ? AgentLibraryError.invalidReceipt.code : nil,
                         linkDestination: link.destination, sharesCanonical: shares)
        } catch {
            // Refused for reading, but the link and where it leads are still
            // shown, so a link into an unmanaged source is visible as one.
            return .init(id: id, target: target, path: files.home.appendingPathComponent(relative).path,
                         resolvedPath: link.destination == nil ? nil : link.resolved,
                         revision: "unavailable", status: Self.status(error),
                         isSymlink: link.destination != nil, isCanonical: id == "canonical", overridePath: nil,
                         projectionOwned: false, errorCode: Self.code(error),
                         linkDestination: link.destination, sharesCanonical: shares)
        }
    }
    func instructionReceipts() throws -> [String: AgentInstructionProjectionReceipt] {
        let stored = try files.readStorage("projections.json")
        instructionReceiptRevision = stored.map(AgentLibraryFiles.digest) ?? "missing"
        guard let data = stored else { return [:] }
        guard let receipts = try? JSONDecoder().decode([String: AgentInstructionProjectionReceipt].self, from: data) else {
            throw AgentLibraryError.invalidReceipt
        }
        for (key, receipt) in receipts {
            guard key == receipt.target.rawValue, receipt.target.instructionRelativePath != nil,
                  receipt.destination == files.home.appendingPathComponent(AgentLibraryFiles.canonical).path,
                  UUID(uuidString: receipt.backupID) != nil else { throw AgentLibraryError.invalidReceipt }
        }
        return receipts
    }
    func saveInstructionReceipts(_ receipts: [String: AgentInstructionProjectionReceipt]) throws {
        let current = try files.readStorage("projections.json").map(AgentLibraryFiles.digest) ?? "missing"
        guard current == instructionReceiptRevision else { throw AgentLibraryError.staleRevision }
        let data = try JSONEncoder().encode(receipts)
        try files.atomic(data, to: files.storageURL("projections.json"))
        instructionReceiptRevision = AgentLibraryFiles.digest(data)
    }
}
