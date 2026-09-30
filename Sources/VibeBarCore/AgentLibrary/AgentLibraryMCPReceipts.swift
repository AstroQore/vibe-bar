import Foundation

struct AgentMCPProjectionReceipt: Codable {
    let source: AgentLibraryTarget
    let target: AgentLibraryTarget
    let name: String
    let fingerprint: String
}

extension AgentLibraryService {
    func mcpReceipts() throws -> [String: AgentMCPProjectionReceipt] {
        let stored = try files.readStorage("mcp_projections.json")
        mcpReceiptRevision = stored.map(AgentLibraryFiles.digest) ?? "missing"
        guard let data = stored else { return [:] }
        guard let receipts = try? JSONDecoder().decode([String: AgentMCPProjectionReceipt].self, from: data) else {
            throw AgentLibraryError.invalidReceipt
        }
        for (key, receipt) in receipts {
            guard key == Self.operationToken(target: receipt.target, name: receipt.name),
                  !receipt.name.isEmpty, receipt.name.count <= 128,
                  receipt.fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw AgentLibraryError.invalidReceipt
            }
        }
        return receipts
    }
    func saveMCPReceipts(_ receipts: [String: AgentMCPProjectionReceipt]) throws {
        let current = try files.readStorage("mcp_projections.json").map(AgentLibraryFiles.digest) ?? "missing"
        guard current == mcpReceiptRevision else { throw AgentLibraryError.staleRevision }
        let data = try JSONEncoder().encode(receipts)
        try beforeMCPReceiptWrite?(files.storageURL("mcp_projections.json"))
        try files.atomic(data, to: files.storageURL("mcp_projections.json"))
        mcpReceiptRevision = AgentLibraryFiles.digest(data)
    }
    /// Direct mutation revokes the selected incoming receipt; whole-file
    /// restoration revokes this target's receipts. Outgoing destinations and
    /// all other targets remain intact. Failure aborts before the native write.
    func revokeMCPReceipts(target: AgentLibraryTarget, name: String? = nil) throws {
        let receipts = try mcpReceipts()
        let remaining = receipts.filter {
            $0.value.target != target || (name != nil && $0.value.name != name)
        }
        if remaining.count != receipts.count { try saveMCPReceipts(remaining) }
    }
}
