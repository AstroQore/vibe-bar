import XCTest
@testable import VibeBarCore

final class AgentLibraryTests: XCTestCase {
    var home: URL!
    var service: AgentLibraryService!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("VibeBarAgentLibrary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = try AgentLibraryService(homeDirectory: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func text(_ path: String) throws -> String { try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }
    func revision(_ target: AgentLibraryTarget) async throws -> String {
        let inventory = await service.mcpInventory()
        return try XCTUnwrap(inventory.files.first { $0.target == target }?.revision)
    }
    func instruction(_ id: String) async throws -> AgentInstructionSummary {
        let rows = await service.instructionInventory()
        return try XCTUnwrap(rows.first { $0.id == id })
    }
    func expect(_ code: AgentLibraryError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected " + code.rawValue) }
        catch { XCTAssertEqual(error as? AgentLibraryError, code) }
    }

    func testInventoryHasNoWritesAndNoInventedInstructionTargets() async throws {
        let inventory = await service.mcpInventory()
        XCTAssertEqual(inventory.files.count, 5)
        XCTAssertTrue(inventory.files.allSatisfy { $0.status == .missing && $0.revision == "missing" })
        XCTAssertTrue(inventory.definitions.isEmpty)
        let instructions = await service.instructionInventory()
        XCTAssertEqual(instructions.count, 6)
        XCTAssertEqual(instructions.first { $0.target == .cursor }?.status, .unsupported)
        XCTAssertEqual(instructions.first { $0.target == .grok }?.status, .unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".vibebar").path))
    }

    func testJSONEditPreservesUnknownFieldsOtherServersAndLargeIntegers() async throws {
        try write(".claude.json", #"{"large":9007199254740993,"unsigned":18446744073709551615,"custom":{"mode":"keep"},"mcpServers":{"one":{"type":"stdio","command":"old","args":["--secret","synthetic-plain-value"],"env":{"KEY":"synthetic-env-value"},"custom":{"flag":true}},"two":{"command":"other","vendor":"untouched"}}}"#)
        let rev = try await revision(.claude)
        var edit = try await service.readMCPDefinition(target: .claude, name: "one", expectedRevision: rev).definition
        edit.command = "new"
        let result = try await service.saveMCPDefinition(target: .claude, definition: edit, expectedRevision: rev, replaceExisting: true)
        XCTAssertEqual(result.changed, [.claude])
        let decoded = try JSONDecoder().decode([String: AgentLibraryValue].self, from: Data(text(".claude.json").utf8))
        XCTAssertEqual(decoded["large"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(decoded["unsigned"], .unsignedInteger(UInt64.max))
        XCTAssertEqual(decoded["custom"]?.object?["mode"], .string("keep"))
        let servers = try XCTUnwrap(decoded["mcpServers"]?.object)
        XCTAssertEqual(servers["two"]?.object?["vendor"], .string("untouched"))
        XCTAssertEqual(servers["one"]?.object?["custom"]?.object?["flag"], .bool(true))
        let inventory = await service.mcpInventory()
        for row in inventory.definitions {
            XCTAssertFalse(row.redactedDescription.contains("synthetic-plain-value"))
            XCTAssertFalse(row.redactedDescription.contains("synthetic-env-value"))
            XCTAssertFalse(row.redactedDescription.contains("old"))
        }
        let backup = try XCTUnwrap(result.backups.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".vibebar/agent_library/backups/" + backup.id + ".json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleRevisionAndSameNameConflictDoNotChangeFiles() async throws {
        try write(".cursor/mcp.json", #"{"mcpServers":{"one":{"command":"first"}}}"#)
        let rev = try await revision(.cursor)
        await expect(.sameNameConflict) {
            _ = try await self.service.saveMCPDefinition(target: .cursor, definition: .init(name: "one", command: "different"), expectedRevision: rev)
        }
        try write(".cursor/mcp.json", #"{"mcpServers":{"one":{"command":"externally-edited"}}}"#)
        let edited = try text(".cursor/mcp.json")
        await expect(.staleRevision) {
            _ = try await self.service.deleteMCPDefinition(target: .cursor, name: "one", expectedRevision: rev)
        }
        XCTAssertEqual(try text(".cursor/mcp.json"), edited)
    }

    func testSelectedSharingConvertsAllNativeStdioFormatsAndKeepsUnselectedFile() async throws {
        try write(".claude.json", #"{"mcpServers":{"shared":{"type":"stdio","command":"npx","args":["tool","arg with spaces"],"env":{"TOKEN":"synthetic-secret"}}}}"#)
        try write(".cursor/mcp.json", #"{"marker":"unselected","mcpServers":{}}"#)
        let cursorBefore = try text(".cursor/mcp.json")
        let sourceRevision = try await revision(.claude)
        let result = try await service.shareMCPDefinition(source: .claude, name: "shared", sourceRevision: sourceRevision,
                                                         targets: [.codex: "missing", .gemini: "missing", .grok: "missing"])
        XCTAssertEqual(Set(result.changed), [.codex, .gemini, .grok])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(try text(".cursor/mcp.json"), cursorBefore)
        let inventory = await service.mcpInventory()
        XCTAssertEqual(inventory.definitions.filter { $0.name == "shared" }.count, 4)
        XCTAssertEqual(inventory.definitions.first { $0.target == .claude }?.matchingTargets.count, 3)
        for target in [AgentLibraryTarget.codex, .gemini, .grok] {
            let rev = try await revision(target)
            let definition = try await service.readMCPDefinition(target: target, name: "shared", expectedRevision: rev).definition
            XCTAssertEqual(definition.args, ["tool", "arg with spaces"])
            XCTAssertEqual(definition.environment["TOKEN"], "synthetic-secret")
        }
    }

    func testRemoteHeadersAndSSEUseEachTargetsNativeFields() async throws {
        try write(".codex/config.toml", #"""
        [mcp_servers.remote]
        url = "https://example.invalid/mcp?key=synthetic-url-secret"
        http_headers = { Authorization = "synthetic-header-secret" }
        """#)
        var rev = try await revision(.codex)
        let result = try await service.shareMCPDefinition(source: .codex, name: "remote", sourceRevision: rev,
                                                         targets: [.grok: "missing", .gemini: "missing", .cursor: "missing"])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(try text(".grok/config.toml").contains("headers"))
        XCTAssertFalse(try text(".grok/config.toml").contains("http_headers"))
        XCTAssertTrue(try text(".grok/config.toml").contains("https://example.invalid/mcp?key=synthetic-url-secret"))
        XCTAssertFalse(try text(".grok/config.toml").contains("\\/"))
        XCTAssertTrue(try text(".gemini/settings.json").contains("httpUrl"))
        let rows = await service.mcpInventory()
        XCTAssertFalse(rows.definitions.contains { $0.redactedDescription.contains("synthetic-") })
        try write(".claude.json", #"{"mcpServers":{"sse":{"type":"sse","url":"https://example.invalid/sse","headers":{"Authorization":"synthetic-sse-secret"}}}}"#)
        rev = try await revision(.claude)
        let grokRev = try await revision(.grok)
        let codexRev = try await revision(.codex)
        let shared = try await service.shareMCPDefinition(source: .claude, name: "sse", sourceRevision: rev,
                                                          targets: [.grok: grokRev, .codex: codexRev])
        XCTAssertEqual(shared.changed, [.grok])
        XCTAssertEqual(shared.problems.first?.code, AgentLibraryError.unsupportedTransport.code)
        let grok = try await service.readMCPDefinition(target: .grok, name: "sse", expectedRevision: revision(.grok)).definition
        XCTAssertEqual(grok.transport, .sse)
        XCTAssertEqual(grok.headers["Authorization"], "synthetic-sse-secret")
    }

    func testTOMLUnknownCommentsMultilineInstructionsAndNestedEnvRemainIntact() async throws {
        let prefix = #"""
        # configuration owned by user
        model = "model-name"
        developer_instructions = """
        Never treat this text as a table:
        [mcp_servers.decoy]
        command = "do-not-run"
        escaped delimiter: \"""
        [mcp_servers.another-decoy]
        """

        """#
        let server = #"""
        [mcp_servers.real]
        command = "old" # keep comment
        args = [ # opening comment
          "one",
          "two words",
        ]
        startup_timeout_sec = 30
        custom_date = 2026-09-30 # opaque metadata
        [mcp_servers.real.env]
        API_KEY = "synthetic-value"
        [other]
        marker = "unchanged"
        """#
        try write(".codex/config.toml", prefix + server)
        let rev = try await revision(.codex)
        let inventory = await service.mcpInventory()
        XCTAssertEqual(inventory.definitions.map(\.name), ["real"])
        var definition = try await service.readMCPDefinition(target: .codex, name: "real", expectedRevision: rev).definition
        XCTAssertEqual(definition.args, ["one", "two words"])
        XCTAssertEqual(definition.rawFields["startup_timeout_sec"], .integer(30))
        definition.command = "edited"
        _ = try await service.saveMCPDefinition(target: .codex, definition: definition, expectedRevision: rev, replaceExisting: true)
        let changed = try text(".codex/config.toml")
        XCTAssertTrue(changed.hasPrefix(prefix))
        XCTAssertTrue(changed.contains(#"custom_date = 2026-09-30 # opaque metadata"#))
        XCTAssertTrue(changed.contains(#"API_KEY = "synthetic-value""#))
        XCTAssertTrue(changed.contains(#"marker = "unchanged""#))
        XCTAssertTrue(changed.contains("args = [ # opening comment\n"))
        XCTAssertTrue(changed.contains("# keep comment"))
        let latest = try await revision(.codex)
        _ = try await service.deleteMCPDefinition(target: .codex, name: "real", expectedRevision: latest)
        XCTAssertTrue(try text(".codex/config.toml").hasPrefix(prefix))
        XCTAssertFalse(try text(".codex/config.toml").contains("[mcp_servers.real]"))
        XCTAssertTrue(try text(".codex/config.toml").contains("[other]"))
    }

    func testUnknownMetadataRefusesCrossFormatSharing() async throws {
        try write(".claude.json", #"{"mcpServers":{"own":{"type":"stdio","command":"cmd","vendor_option":{"keep":true}}}}"#)
        let result = try await service.shareMCPDefinition(source: .claude, name: "own",
                                                          sourceRevision: revision(.claude), targets: [.codex: "missing"])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.unsupportedConversion.code)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testGrokEnabledMetadataAndIntegerTimeoutsHaveExplicitConversionRules() async throws {
        try write(".grok/config.toml", #"""
        [mcp_servers.server]
        command = "cmd"
        enabled = true
        startup_timeout_sec = 30
        """#)
        let result = try await service.shareMCPDefinition(source: .grok, name: "server",
                                                          sourceRevision: revision(.grok), targets: [.codex: "missing"])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(try text(".codex/config.toml").contains(#""startup_timeout_sec" = 30"#))
        XCTAssertFalse(try text(".codex/config.toml").contains("30.0"))
        try write(".grok/config.toml", #"""
        [mcp_servers.disabled]
        command = "cmd"
        enabled = false
        """#)
        let refused = try await service.shareMCPDefinition(source: .grok, name: "disabled",
                                                           sourceRevision: revision(.grok), targets: [.gemini: "missing"])
        XCTAssertEqual(refused.problems.first?.code, AgentLibraryError.unsupportedConversion.code)
        let supported = try await service.shareMCPDefinition(source: .grok, name: "disabled",
                                                             sourceRevision: revision(.grok), targets: [.codex: revision(.codex)])
        XCTAssertTrue(supported.problems.isEmpty)
        XCTAssertTrue(try text(".codex/config.toml").contains(#""enabled" = false"#))
    }

    func testSameNameSharingIsAConflictAndEqualDefinitionsAreNoOp() async throws {
        try write(".claude.json", #"{"mcpServers":{"same":{"command":"source"}}}"#)
        try write(".cursor/mcp.json", #"{"mcpServers":{"same":{"command":"different"}}}"#)
        try write(".gemini/settings.json", #"{"mcpServers":{"same":{"command":"source"}}}"#)
        let result = try await service.shareMCPDefinition(source: .claude, name: "same",
                                                          sourceRevision: revision(.claude),
                                                          targets: [.cursor: revision(.cursor), .gemini: revision(.gemini)])
        XCTAssertEqual(result.unchanged, [.gemini])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertTrue(try text(".cursor/mcp.json").contains("different"))
    }

    func testBackupRestoreIsGuardedAndRestoresExactOriginalBytes() async throws {
        let original = #"{"userMarker":123,"mcpServers":{"one":{"command":"before"}}}"#
        try write(".cursor/mcp.json", original)
        let saved = try await service.saveMCPDefinition(target: .cursor, definition: .init(name: "one", command: "after"),
                                                        expectedRevision: revision(.cursor), replaceExisting: true)
        let backup = try XCTUnwrap(saved.backups.first)
        await expect(.staleRevision) { _ = try await self.service.restoreBackup(id: backup.id, expectedRevision: "missing") }
        _ = try await service.restoreBackup(id: backup.id, expectedRevision: revision(.cursor))
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        await expect(.invalidBackup) { _ = try await self.service.restoreBackup(id: "../bad", expectedRevision: "missing") }
    }

    func testCreateCanonicalAndLinkMissingSupportedTargetsWithReceipts() async throws {
        _ = try await service.saveInstruction(id: "canonical", text: "Shared rules\n", expectedRevision: "missing")
        let shared = try await service.linkCanonicalInstructions(targets: [.codex: "missing", .claude: "missing",
                                                                          .gemini: "missing", .cursor: "unavailable"])
        XCTAssertEqual(Set(shared.changed), [.codex, .claude, .gemini])
        XCTAssertEqual(shared.problems.first?.code, AgentLibraryError.unsupportedTarget.code)
        let rows = await service.instructionInventory()
        for row in rows where [.codex, .claude, .gemini].contains(row.target) {
            XCTAssertTrue(row.isSymlink)
            XCTAssertTrue(row.projectionOwned)
            XCTAssertEqual(row.resolvedPath, home.appendingPathComponent(".agents/AGENTS.md").resolvingSymlinksInPath().path)
        }
        let codex = try await instruction("codex")
        _ = try await service.removeInstructionProjection(target: .codex, expectedRevision: codex.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
        XCTAssertEqual(try text(".agents/AGENTS.md"), "Shared rules\n")
    }

    func testExistingUserLinksAreReusedButNeverOwnedOrRemoved() async throws {
        try write(".agents/AGENTS.md", "User shared rules")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".claude/CLAUDE.md").path,
                                                   withDestinationPath: "../.agents/AGENTS.md")
        let before = try await instruction("claude")
        XCTAssertTrue(before.isSymlink)
        XCTAssertFalse(before.projectionOwned)
        let result = try await service.linkCanonicalInstructions(targets: [.claude: before.revision])
        XCTAssertEqual(result.unchanged, [.claude])
        await expect(.notOwnedProjection) {
            _ = try await self.service.removeInstructionProjection(target: .claude, expectedRevision: before.revision)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/CLAUDE.md").path), "../.agents/AGENTS.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".vibebar").path))
    }

    func testInstructionConflictPreservesDifferentUserTextAndOwnProjectionRestoresOriginal() async throws {
        try write(".agents/AGENTS.md", "shared")
        try write(".claude/CLAUDE.md", "different user rules")
        let before = try await instruction("claude")
        let conflict = try await service.linkCanonicalInstructions(targets: [.claude: before.revision])
        XCTAssertEqual(conflict.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertEqual(try text(".claude/CLAUDE.md"), "different user rules")
        try write(".gemini/GEMINI.md", "shared")
        _ = try await service.linkCanonicalInstructions(targets: [.gemini: instruction("gemini").revision])
        let canonical = try await instruction("canonical")
        _ = try await service.saveInstruction(id: "canonical", text: "updated shared", expectedRevision: canonical.revision)
        _ = try await service.removeInstructionProjection(target: .gemini, expectedRevision: instruction("gemini").revision)
        XCTAssertEqual(try text(".gemini/GEMINI.md"), "shared")
        XCTAssertEqual(try text(".agents/AGENTS.md"), "updated shared")
    }

    func testEditingLinkedInstructionUpdatesExplicitSourceWithoutReplacingLink() async throws {
        try write(".agents/AGENTS.md", "shared")
        _ = try await service.linkCanonicalInstructions(targets: [.claude: "missing"])
        let row = try await instruction("claude")
        _ = try await service.saveInstruction(id: "claude", text: "explicit edit", expectedRevision: row.revision)
        XCTAssertEqual(try text(".agents/AGENTS.md"), "explicit edit")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/CLAUDE.md").path),
                       home.resolvingSymlinksInPath().appendingPathComponent(".agents/AGENTS.md").path)
    }

    func testModifiedProjectionCannotBeRevoked() async throws {
        try write(".agents/AGENTS.md", "shared")
        try write(".gemini/GEMINI.md", "other source")
        _ = try await service.linkCanonicalInstructions(targets: [.claude: "missing"])
        let leaf = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.removeItem(at: leaf)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: home.appendingPathComponent(".gemini/GEMINI.md"))
        let row = try await instruction("claude")
        await expect(.projectionModified) {
            _ = try await self.service.removeInstructionProjection(target: .claude, expectedRevision: row.revision)
        }
        XCTAssertEqual(try text(".gemini/GEMINI.md"), "other source")
    }

    func testCrossResourceSymlinkOutsideHomeLoopAndDirectoryLinksAreRejected() async throws {
        try write(".claude.json", #"{"must":"remain JSON"}"#)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let codex = home.appendingPathComponent(".codex/AGENTS.md")
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: home.appendingPathComponent(".claude.json"))
        let wrongResource = try await instruction("codex")
        XCTAssertEqual(wrongResource.status, .unsafe)
        await expect(.unsafePath) {
            _ = try await self.service.saveInstruction(id: "codex", text: "not JSON", expectedRevision: "missing")
        }
        XCTAssertEqual(try text(".claude.json"), #"{"must":"remain JSON"}"#)
        try FileManager.default.removeItem(at: codex)
        try FileManager.default.createSymbolicLink(atPath: codex.path, withDestinationPath: "/Users/example/outside/AGENTS.md")
        let outside = try await instruction("codex")
        XCTAssertEqual(outside.status, .unsafe)
        try FileManager.default.removeItem(at: codex)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let claude = home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: claude)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: codex)
        let loop = try await instruction("claude")
        XCTAssertEqual(loop.errorCode, AgentLibraryError.symlinkLoop.code)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: home.appendingPathComponent(".claude"))
        let inventory = await service.mcpInventory()
        XCTAssertEqual(inventory.files.first { $0.target == .codex }?.status, .unsafe)
    }

    func testInstructionRevisionGuardAndEmptyCodexOverride() async throws {
        try write(".codex/AGENTS.md", "original")
        try write(".codex/AGENTS.override.md", "  \n")
        let row = try await instruction("codex")
        XCTAssertNil(row.overridePath)
        try write(".codex/AGENTS.md", "changed")
        await expect(.staleRevision) {
            _ = try await self.service.saveInstruction(id: "codex", text: "stale overwrite", expectedRevision: row.revision)
        }
        XCTAssertEqual(try text(".codex/AGENTS.md"), "changed")
        try write(".codex/AGENTS.override.md", "active override")
        let activeOverride = try await instruction("codex")
        XCTAssertNotNil(activeOverride.overridePath)
    }

    func testOwnedMCPSharingUpdatesSourceChangesAndRejectsExternalTargetEdits() async throws {
        try write(".claude.json", #"{"mcpServers":{"shared":{"type":"stdio","command":"first","env":{"TOKEN":"synthetic-secret"}}}}"#)
        _ = try await service.shareMCPDefinition(source: .claude, name: "shared",
                                                 sourceRevision: revision(.claude), targets: [.cursor: "missing"])
        let firstInventory = await service.mcpInventory()
        XCTAssertTrue(firstInventory.definitions.first { $0.target == .cursor }?.projectionOwned == true)
        let sourceRev = try await revision(.claude)
        var edit = try await service.readMCPDefinition(target: .claude, name: "shared", expectedRevision: sourceRev).definition
        edit.command = "second"
        _ = try await service.saveMCPDefinition(target: .claude, definition: edit, expectedRevision: sourceRev, replaceExisting: true)
        let copied = try await service.shareMCPDefinition(source: .claude, name: "shared",
                                                          sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor)])
        XCTAssertEqual(copied.changed, [.cursor])
        XCTAssertTrue(copied.problems.isEmpty)
        XCTAssertEqual(copied.backups.count, 1)
        let cursor = try await service.readMCPDefinition(target: .cursor, name: "shared", expectedRevision: revision(.cursor)).definition
        XCTAssertEqual(cursor.command, "second")
        let receiptText = try text(".vibebar/agent_library/mcp_projections.json")
        XCTAssertFalse(receiptText.contains("synthetic-secret"))
        XCTAssertFalse(receiptText.contains("second"))
        try write(".cursor/mcp.json", #"{"mcpServers":{"shared":{"command":"external-user-change"}}}"#)
        let before = try text(".cursor/mcp.json")
        let conflict = try await service.shareMCPDefinition(source: .claude, name: "shared",
                                                            sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor)])
        XCTAssertEqual(conflict.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertEqual(try text(".cursor/mcp.json"), before)
        let inventory = await service.mcpInventory()
        XCTAssertFalse(inventory.definitions.first { $0.target == .cursor }?.projectionOwned == true)
    }

    func testCanonicalAlreadyPointsToAgentSourceDoesNotCreateReverseLoop() async throws {
        try write(".codex/AGENTS.md", "canonical source owned by user")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".agents/AGENTS.md").path,
                                                   withDestinationPath: "../.codex/AGENTS.md")
        let result = try await service.linkCanonicalInstructions(targets: [.codex: instruction("codex").revision])
        XCTAssertEqual(result.unchanged, [.codex])
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertEqual(try text(".codex/AGENTS.md"), "canonical source owned by user")
        let source = try await instruction("codex")
        XCTAssertFalse(source.isSymlink)
        XCTAssertEqual(source.status, .ready)
    }

    func testGrokNameValidationLeavesOtherServersReadableAndInvalidRowsDeletable() async throws {
        for name in ["My server", "1server", "server__bad", "trailing_"] {
            await expect(.invalidDefinition) {
                _ = try await self.service.saveMCPDefinition(target: .grok, definition: .init(name: name, command: "cmd"),
                                                              expectedRevision: "missing")
            }
        }
        try write(".grok/config.toml", #"""
        [mcp_servers."My server"]
        command = "bad-name"
        [mcp_servers.good]
        command = "cmd"
        enabled = true
        """#)
        let rows = await service.mcpInventory()
        XCTAssertEqual(rows.definitions.first { $0.name == "My server" }?.status, .unsupported)
        XCTAssertEqual(rows.definitions.first { $0.name == "good" }?.status, .ready)
        let rev = try await revision(.grok)
        _ = try await service.deleteMCPDefinition(target: .grok, name: "My server", expectedRevision: rev)
        let remaining = await service.mcpInventory()
        XCTAssertEqual(remaining.definitions.map(\.name), ["good"])
        let shared = try await service.shareMCPDefinition(source: .grok, name: "good",
                                                          sourceRevision: revision(.grok), targets: [.claude: "missing"])
        XCTAssertTrue(shared.problems.isEmpty)
        XCTAssertEqual(shared.changed, [.claude])
    }

    func testRedactedNamesHaveOpaqueActionIdentity() async throws {
        let key = "sk-syntheticonlykey123456"
        try write(".cursor/mcp.json", "{\"mcpServers\":{\"\(key)\":{\"command\":\"cmd\"}}}")
        let inventory = await service.mcpInventory()
        let row = try XCTUnwrap(inventory.definitions.first)
        XCTAssertFalse(row.name.contains(key))
        XCTAssertFalse(row.id.contains(key))
        XCTAssertFalse(row.operationName.contains(key))
        let selected = try await service.readMCPDefinition(target: .cursor, name: row.operationName, expectedRevision: row.revision)
        XCTAssertEqual(selected.definition.name, key)
        _ = try await service.deleteMCPDefinition(target: .cursor, name: row.operationName, expectedRevision: row.revision)
        let remaining = await service.mcpInventory()
        XCTAssertTrue(remaining.definitions.isEmpty)
    }

    func testForeignFieldNamesArePreservedAndCannotDisappearDuringSharing() async throws {
        try write(".codex/config.toml", #"""
        [mcp_servers.example]
        command = "cmd"
        headers = { Future = "synthetic-value" }
        """#)
        let rev = try await revision(.codex)
        var definition = try await service.readMCPDefinition(target: .codex, name: "example", expectedRevision: rev).definition
        definition.command = "updated"
        _ = try await service.saveMCPDefinition(target: .codex, definition: definition, expectedRevision: rev, replaceExisting: true)
        XCTAssertTrue(try text(".codex/config.toml").contains(#"headers = { Future = "synthetic-value" }"#))
        let result = try await service.shareMCPDefinition(source: .codex, name: "example",
                                                          sourceRevision: revision(.codex), targets: [.claude: "missing"])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.unsupportedConversion.code)
    }

    private func ownedMCPFixture() async throws {
        try write(".claude.json", #"{"mcpServers":{"shared":{"type":"stdio","command":"first"},"keep":{"type":"stdio","command":"keep"}}}"#)
        for name in ["shared", "keep"] {
            _ = try await service.shareMCPDefinition(source: .claude, name: name,
                sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor), .gemini: revision(.gemini)])
        }
    }
    private func changeCommand(_ command: String, target: AgentLibraryTarget, name: String = "shared") async throws -> AgentLibraryMutationResult {
        let rev = try await revision(target)
        var definition = try await service.readMCPDefinition(target: target, name: name, expectedRevision: rev).definition
        definition.command = command
        return try await service.saveMCPDefinition(target: target, definition: definition,
                                                   expectedRevision: rev, replaceExisting: true)
    }
    private func receiptIdentities() throws -> [String: String] {
        let data = Data(try text(".vibebar/agent_library/mcp_projections.json").utf8)
        return try JSONDecoder().decode([String: AgentMCPProjectionReceipt].self, from: data).mapValues {
            $0.source.rawValue + ":" + $0.target.rawValue + ":" + $0.name + ":" + $0.fingerprint
        }
    }
    private func owned(_ name: String = "shared", target: AgentLibraryTarget) async -> Bool {
        let inventory = await service.mcpInventory()
        return inventory.definitions.first { $0.target == target && $0.name == name }?.projectionOwned == true
    }

    func testDeletingAndRecreatingIdenticalMCPDoesNotRestoreOwnership() async throws {
        try await ownedMCPFixture()
        let original = try text(".cursor/mcp.json")
        let otherReceipts = try receiptIdentities().filter { $0.key != AgentLibraryService.operationToken(target: .cursor, name: "shared") }
        _ = try await service.deleteMCPDefinition(target: .cursor, name: "shared", expectedRevision: revision(.cursor))
        XCTAssertEqual(try receiptIdentities(), otherReceipts)
        try write(".cursor/mcp.json", original)
        _ = try await changeCommand("source-changed", target: .claude)
        let result = try await service.shareMCPDefinition(source: .claude, name: "shared",
            sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor)])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        let ownership = await owned(target: .cursor)
        let keeper = await owned("keep", target: .cursor)
        let unaffected = await owned(target: .gemini)
        XCTAssertFalse(ownership)
        XCTAssertTrue(keeper)
        XCTAssertTrue(unaffected)
    }

    func testDirectMCPEditThenReturningToOldValuesDoesNotRestoreOwnership() async throws {
        try await ownedMCPFixture()
        _ = try await changeCommand("user-edited", target: .cursor)
        _ = try await changeCommand("first", target: .cursor)
        let original = try text(".cursor/mcp.json")
        _ = try await changeCommand("new-source", target: .claude)
        let result = try await service.shareMCPDefinition(source: .claude, name: "shared",
            sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor), .gemini: revision(.gemini)])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertEqual(result.changed, [.gemini], "editing the source keeps other owned destinations updateable")
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        let ownership = await owned(target: .cursor)
        let keeper = await owned("keep", target: .cursor)
        XCTAssertFalse(ownership)
        XCTAssertTrue(keeper)
    }

    func testWholeConfigRestoreRevokesOnlyThatTargetsMCPReceipts() async throws {
        try await ownedMCPFixture()
        let original = try text(".cursor/mcp.json")
        let gemini = try text(".gemini/settings.json")
        let otherReceipts = try receiptIdentities().filter { !$0.value.contains(":cursor:") }
        let edit = try await changeCommand("user-edit", target: .cursor)
        let backup = try XCTUnwrap(edit.backups.first)
        _ = try await service.restoreBackup(id: backup.id, expectedRevision: revision(.cursor))
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        XCTAssertEqual(try text(".gemini/settings.json"), gemini)
        XCTAssertEqual(try receiptIdentities(), otherReceipts)
        _ = try await changeCommand("source-changed", target: .claude)
        let result = try await service.shareMCPDefinition(source: .claude, name: "shared",
            sourceRevision: revision(.claude), targets: [.cursor: revision(.cursor)])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        let keeper = await owned("keep", target: .cursor)
        let unaffected = await owned("keep", target: .gemini)
        XCTAssertFalse(keeper, "a whole-file restore conservatively withdraws every incoming permission for that target")
        XCTAssertTrue(unaffected)
    }

    func testRejectedMutationsLeaveOwnershipReceiptsUntouched() async throws {
        try await ownedMCPFixture()
        let rev = try await revision(.cursor)
        let before = try text(".vibebar/agent_library/mcp_projections.json")
        await expect(.sameNameConflict) {
            _ = try await self.service.saveMCPDefinition(target: .cursor, definition: .init(name: "shared", command: "conflict"),
                                                         expectedRevision: rev)
        }
        await expect(.invalidDefinition) {
            _ = try await self.service.saveMCPDefinition(target: .cursor, definition: .init(name: "shared", command: ""),
                                                         expectedRevision: rev, replaceExisting: true)
        }
        try write(".cursor/mcp.json", text(".cursor/mcp.json") + "\n")
        await expect(.staleRevision) {
            _ = try await self.service.deleteMCPDefinition(target: .cursor, name: "shared", expectedRevision: rev)
        }
        let files = try AgentLibraryFiles(homeDirectory: home)
        let backup = try files.backupFile(".cursor/mcp.json")
        await expect(.staleRevision) {
            _ = try await self.service.restoreBackup(id: backup.id, expectedRevision: rev)
        }
        let malformed = AgentLibraryBackupRecord(id: backup.id, relativePath: ".cursor/mcp.json",
                                                 kind: "file", data: nil, link: nil, createdAt: Date())
        try JSONEncoder().encode(malformed).write(to: files.storageURL("backups/" + backup.id + ".json"))
        let current = try await revision(.cursor)
        await expect(.invalidBackup) {
            _ = try await self.service.restoreBackup(id: backup.id, expectedRevision: current)
        }
        XCTAssertEqual(try text(".vibebar/agent_library/mcp_projections.json"), before)
    }

    func testReceiptPublicationFailureAbortsBeforeNativeDeletion() async throws {
        try await ownedMCPFixture()
        let original = try text(".cursor/mcp.json")
        let receiptText = try text(".vibebar/agent_library/mcp_projections.json")
        let rev = try await revision(.cursor)
        let failing = try AgentLibraryService(homeDirectory: home, beforeMCPReceiptWrite: { url in
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("saved"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        })
        await expect(.ioFailure) {
            _ = try await failing.deleteMCPDefinition(target: .cursor, name: "shared", expectedRevision: rev)
        }
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        XCTAssertEqual(try text(".vibebar/agent_library/mcp_projections.json.saved"), receiptText)
    }

    func testBackupFailureAfterRevocationDoesNotClaimNativeSuccessOrRevivePermission() async throws {
        try await ownedMCPFixture()
        let original = try text(".cursor/mcp.json")
        let before = try receiptIdentities()
        let backups = home.appendingPathComponent(".vibebar/agent_library/backups")
        try FileManager.default.moveItem(at: backups, to: backups.appendingPathExtension("saved"))
        try Data("blocked synthetic directory".utf8).write(to: backups)
        let rev = try await revision(.cursor)
        await expect(.unsafePath) {
            _ = try await self.service.deleteMCPDefinition(target: .cursor, name: "shared", expectedRevision: rev)
        }
        XCTAssertEqual(try text(".cursor/mcp.json"), original)
        let key = AgentLibraryService.operationToken(target: .cursor, name: "shared")
        XCTAssertEqual(try receiptIdentities(), before.filter { $0.key != key })
        let ownership = await owned(target: .cursor)
        XCTAssertFalse(ownership)
    }

    func testConcurrentNativeChangeAfterRevocationIsNotRolledBack() async throws {
        try await ownedMCPFixture()
        let target = home.appendingPathComponent(".cursor/mcp.json")
        var root = try JSONDecoder().decode([String: AgentLibraryValue].self, from: Data(text(".cursor/mcp.json").utf8))
        var entries = try XCTUnwrap(root["mcpServers"]?.object)
        var definition = try XCTUnwrap(entries["shared"]?.object)
        definition["command"] = .string("concurrent-user-change")
        entries["shared"] = .object(definition)
        root["mcpServers"] = .object(entries)
        let concurrentData = try JSONEncoder().encode(root)
        let rev = try await revision(.cursor)
        let racing = try AgentLibraryService(homeDirectory: home, beforeMCPReceiptWrite: { _ in
            try concurrentData.write(to: target)
        })
        await expect(.staleRevision) {
            _ = try await racing.deleteMCPDefinition(target: .cursor, name: "shared", expectedRevision: rev)
        }
        XCTAssertEqual(try Data(contentsOf: target), concurrentData)
        let ownership = await owned(target: .cursor)
        let keeper = await owned("keep", target: .cursor)
        XCTAssertFalse(ownership)
        XCTAssertTrue(keeper)
    }

    func testPublicInstructionLeafRestoreDoesNotReclaimUsersRecreatedLink() async throws {
        try write(".agents/AGENTS.md", "shared rules")
        let projected = try await service.linkCanonicalInstructions(targets: [.claude: "missing", .gemini: "missing"])
        let backup = try XCTUnwrap(projected.backups.first { $0.relativePath == ".claude/CLAUDE.md" })
        _ = try await service.restoreBackup(id: backup.id, expectedRevision: instruction("claude").revision)
        let files = try AgentLibraryFiles(homeDirectory: home)
        try FileManager.default.createSymbolicLink(at: files.url(".claude/CLAUDE.md"),
                                                    withDestinationURL: files.url(".agents/AGENTS.md"))
        let recreated = try await instruction("claude")
        let unaffected = try await instruction("gemini")
        XCTAssertFalse(recreated.projectionOwned)
        XCTAssertTrue(unaffected.projectionOwned)
        await expect(.notOwnedProjection) {
            _ = try await self.service.removeInstructionProjection(target: .claude, expectedRevision: recreated.revision)
        }
        XCTAssertEqual(try text(".agents/AGENTS.md"), "shared rules")
    }

    // MARK: - Links the user made before Vibe Bar

    func link(_ path: String, to destination: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func testAbsoluteAndRelativeUserLinksWithDifferentFileNamesAreRecognisedAsShared() async throws {
        try write(".agents/AGENTS.md", "rules")
        let canonical = home.resolvingSymlinksInPath().appendingPathComponent(".agents/AGENTS.md").path
        try link(".codex/AGENTS.md", to: canonical)          // absolute, same file name
        try link(".claude/CLAUDE.md", to: canonical)         // absolute, CLAUDE.md -> AGENTS.md
        try link(".gemini/GEMINI.md", to: "../.agents/AGENTS.md") // relative
        for id in ["codex", "claude", "gemini"] {
            let row = try await instruction(id)
            XCTAssertEqual(row.status, .ready, id)
            XCTAssertTrue(row.isSymlink, id)
            XCTAssertTrue(row.sharesCanonical, id)
            XCTAssertFalse(row.projectionOwned, id)
            XCTAssertEqual(row.resolvedPath, canonical, id)
        }
        let gemini = try await instruction("gemini")
        XCTAssertEqual(gemini.linkDestination, "../.agents/AGENTS.md")
        let canonicalRow = try await instruction("canonical")
        XCTAssertFalse(canonicalRow.sharesCanonical)
        // Recognising a share claims nothing: turning it off is refused and
        // the user's links stay exactly as written.
        for target in [AgentLibraryTarget.codex, .claude, .gemini] {
            let row = try await instruction(target.rawValue)
            await expect(.notOwnedProjection) {
                _ = try await self.service.removeInstructionProjection(target: target, expectedRevision: row.revision)
            }
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/CLAUDE.md").path), canonical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".vibebar").path))
    }

    func testAbsoluteLinkThroughTheOtherSpellingOfHomeIsInsideHome() async throws {
        // /var/… and /private/var/… are one directory; a link written by
        // another tool through `realpath` must not read as leaving the home.
        let real = try XCTUnwrap(AgentLibraryFiles.realPath(home.path))
        try XCTSkipIf(real == home.resolvingSymlinksInPath().path, "temporary directory has a single spelling")
        try write(".agents/AGENTS.md", "rules")
        try link(".claude/CLAUDE.md", to: real + "/.agents/AGENTS.md")
        let row = try await instruction("claude")
        XCTAssertEqual(row.status, .ready)
        XCTAssertTrue(row.sharesCanonical)
        let reused = try await service.linkCanonicalInstructions(targets: [.claude: row.revision])
        XCTAssertEqual(reused.unchanged, [.claude])
        XCTAssertTrue(reused.problems.isEmpty)
        // Outside every spelling of the home is still refused.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/CLAUDE.md"))
        try link(".claude/CLAUDE.md", to: "/Users/example/elsewhere/AGENTS.md")
        let outside = try await instruction("claude")
        XCTAssertEqual(outside.status, .unsafe)
        XCTAssertFalse(outside.sharesCanonical)
        XCTAssertEqual(outside.resolvedPath, "/Users/example/elsewhere/AGENTS.md")
    }

    func testMultiLevelLinkChainAndReverseCanonicalAreShared() async throws {
        try write(".agents/AGENTS.md", "rules")
        try link(".codex/AGENTS.md", to: "../.agents/AGENTS.md")
        try link(".claude/CLAUDE.md", to: "../.codex/AGENTS.md") // claude -> codex -> canonical
        let claude = try await instruction("claude")
        XCTAssertTrue(claude.sharesCanonical)
        XCTAssertEqual(claude.linkDestination, "../.codex/AGENTS.md")
        XCTAssertEqual(claude.resolvedPath, home.resolvingSymlinksInPath().appendingPathComponent(".agents/AGENTS.md").path)
        let linked = try await service.linkCanonicalInstructions(targets: [.claude: claude.revision])
        XCTAssertEqual(linked.unchanged, [.claude])

        // The canonical file itself may be the link, into an agent's file.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".agents/AGENTS.md"))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex/AGENTS.md"))
        try write(".codex/AGENTS.md", "codex is the source")
        try link(".agents/AGENTS.md", to: "../.codex/AGENTS.md")
        let codex = try await instruction("codex")
        XCTAssertFalse(codex.isSymlink)
        XCTAssertTrue(codex.sharesCanonical)
        let claudeAfter = try await instruction("claude")
        let geminiAfter = try await instruction("gemini")
        XCTAssertTrue(claudeAfter.sharesCanonical)
        XCTAssertFalse(geminiAfter.sharesCanonical)
    }

    func testLinksIntoAnUnmanagedSourceAreShownButNeverRead() async throws {
        // An Obsidian-style vault file inside the home but outside the
        // managed files: the canonical file and an agent both link to it.
        try write("Vault/rules/AGENTS.md", "vault rules")
        let vault = home.resolvingSymlinksInPath().appendingPathComponent("Vault/rules/AGENTS.md").path
        try link(".agents/AGENTS.md", to: vault)
        try link(".codex/AGENTS.md", to: "../.agents/AGENTS.md")
        try link(".gemini/GEMINI.md", to: vault)
        try write(".claude/CLAUDE.md", "own rules")
        let canonical = try await instruction("canonical")
        XCTAssertEqual(canonical.status, .unsafe)
        XCTAssertTrue(canonical.isSymlink)
        XCTAssertEqual(canonical.resolvedPath, vault)
        for id in ["codex", "gemini"] {
            let row = try await instruction(id)
            XCTAssertEqual(row.status, .unsafe, id)
            XCTAssertTrue(row.isSymlink, id)
            XCTAssertTrue(row.sharesCanonical, id)
            XCTAssertEqual(row.resolvedPath, vault, id)
            XCTAssertFalse(row.projectionOwned, id)
        }
        let claude = try await instruction("claude")
        XCTAssertFalse(claude.sharesCanonical)
        XCTAssertEqual(claude.status, .ready)
        // Nothing is read or written through the unmanaged destination.
        await expect(.unsafePath) {
            _ = try await self.service.readInstruction(id: "gemini", expectedRevision: "unavailable")
        }
        await expect(.unsafePath) {
            _ = try await self.service.linkCanonicalInstructions(targets: [.claude: claude.revision])
        }
        XCTAssertEqual(try text("Vault/rules/AGENTS.md"), "vault rules")
        XCTAssertEqual(try text(".claude/CLAUDE.md"), "own rules")
    }

    func testLinkToADifferentAgentSourceIsNotSharedAndIsAConflict() async throws {
        try write(".agents/AGENTS.md", "rules")
        try write(".gemini/GEMINI.md", "gemini rules")
        try link(".claude/CLAUDE.md", to: "../.gemini/GEMINI.md")
        let claude = try await instruction("claude")
        XCTAssertTrue(claude.isSymlink)
        XCTAssertFalse(claude.sharesCanonical)
        let result = try await service.linkCanonicalInstructions(targets: [.claude: claude.revision])
        XCTAssertEqual(result.problems.first?.code, AgentLibraryError.sameNameConflict.code)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/CLAUDE.md").path),
                       "../.gemini/GEMINI.md")
    }

    func testOwnedProjectionIsSharedAndStillRemovable() async throws {
        try write(".agents/AGENTS.md", "rules")
        _ = try await service.linkCanonicalInstructions(targets: [.gemini: "missing"])
        let row = try await instruction("gemini")
        XCTAssertTrue(row.sharesCanonical)
        XCTAssertTrue(row.projectionOwned)
        _ = try await service.removeInstructionProjection(target: .gemini, expectedRevision: row.revision)
        let after = try await instruction("gemini")
        XCTAssertFalse(after.sharesCanonical)
        XCTAssertEqual(after.status, .missing)
    }

    // MARK: - MCP grouping and share capability

    func testMCPRowsForOneNameShareAGroupAndReportUnsupportedTargets() async throws {
        try write(".claude.json", #"{"mcpServers":{"remote":{"type":"sse","url":"https://example.invalid/sse"},"tool":{"command":"synthetic-tool","args":[]}}}"#)
        try write(".cursor/mcp.json", #"{"mcpServers":{"tool":{"command":"synthetic-tool","args":[]}}}"#)
        let inventory = await service.mcpInventory()
        let tools = inventory.definitions.filter { $0.name == "tool" }
        XCTAssertEqual(Set(tools.map(\.target)), [.claude, .cursor])
        XCTAssertEqual(Set(tools.map(\.groupID)).count, 1)
        let remote = try XCTUnwrap(inventory.definitions.first { $0.name == "remote" })
        XCTAssertNotEqual(remote.groupID, tools.first?.groupID)
        // Codex has no SSE transport; the toggle must say so up front.
        XCTAssertEqual(remote.unsupportedTargets[.codex], AgentLibraryError.unsupportedTransport.code)
        XCTAssertNil(remote.unsupportedTargets[.gemini])
        XCTAssertNil(remote.unsupportedTargets[.claude])
        XCTAssertTrue(tools.allSatisfy { $0.unsupportedTargets.isEmpty })
    }

    // MARK: - Share switch state

    func testInstructionShareStatesSeparateOwnedUserLinkedDifferentAndOff() async throws {
        try write(".agents/AGENTS.md", "rules")
        try link(".codex/AGENTS.md", to: home.resolvingSymlinksInPath().appendingPathComponent(".agents/AGENTS.md").path)
        _ = try await service.linkCanonicalInstructions(targets: [.gemini: "missing"])
        try write(".claude/CLAUDE.md", "own rules")
        var states = AgentLibraryShareState.instructionStates(await service.instructionInventory())
        XCTAssertEqual(states[.codex], .linked)
        XCTAssertEqual(states[.gemini], .shared(managed: true))
        XCTAssertEqual(states[.claude], .off)
        XCTAssertNil(states[.cursor])
        XCTAssertNil(states[.grok])
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/CLAUDE.md"))
        try link(".claude/CLAUDE.md", to: "../.gemini/GEMINI.md")
        states = AgentLibraryShareState.instructionStates(await service.instructionInventory())
        // Through the owned Gemini projection it does reach the shared file.
        XCTAssertEqual(states[.claude], .linked)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/CLAUDE.md"))
        try write(".codex/AGENTS.override.md", "")
        try link(".claude/CLAUDE.md", to: "../.codex/AGENTS.override.md")
        states = AgentLibraryShareState.instructionStates(await service.instructionInventory())
        XCTAssertEqual(states[.claude], .differs)
    }

    func testInstructionShareStatesWithoutCanonicalAreUnavailable() async throws {
        let states = AgentLibraryShareState.instructionStates(await service.instructionInventory())
        XCTAssertEqual(states[.codex], .unavailable(code: AgentLibraryError.missingCanonical.code))
        XCTAssertEqual(Set(states.keys), [.codex, .claude, .gemini])
    }

    func testMCPGroupStatesReflectEqualDifferentOwnedAndUnsupportedTargets() async throws {
        try write(".claude.json", #"{"mcpServers":{"tool":{"command":"synthetic-tool","args":["a"]},"remote":{"type":"sse","url":"https://example.invalid/sse"}}}"#)
        try write(".cursor/mcp.json", #"{"mcpServers":{"tool":{"command":"synthetic-tool","args":["a"]}}}"#)
        try write(".grok/config.toml", "[mcp_servers.tool]\ncommand = \"other-tool\"\nargs = []\n")
        try write(".gemini/settings.json", "{ not json")
        var groups = AgentMCPGroup.groups(await service.mcpInventory())
        var tool = try XCTUnwrap(groups.first { $0.name == "tool" })
        XCTAssertEqual(tool.primary.target, .claude)
        XCTAssertEqual(tool.states[.claude], .shared(managed: false))
        XCTAssertEqual(tool.states[.cursor], .shared(managed: false))
        XCTAssertEqual(tool.states[.grok], .differs)
        XCTAssertEqual(tool.states[.codex], .off)
        XCTAssertEqual(tool.states[.gemini], .unavailable(code: AgentLibraryError.invalidDocument.code))
        let remote = try XCTUnwrap(groups.first { $0.name == "remote" })
        XCTAssertEqual(remote.states[.codex], .unavailable(code: AgentLibraryError.unsupportedTransport.code))

        // Sharing into Codex through the toggle's path makes an owned copy,
        // and the group keeps Claude as the source.
        _ = try await service.shareMCPDefinition(source: .claude, name: tool.primary.operationName,
                                                 sourceRevision: tool.primary.revision,
                                                 targets: [.codex: revision(.codex)])
        groups = AgentMCPGroup.groups(await service.mcpInventory())
        tool = try XCTUnwrap(groups.first { $0.name == "tool" })
        XCTAssertEqual(tool.primary.target, .claude)
        XCTAssertEqual(tool.states[.codex], .shared(managed: true))
        XCTAssertEqual(tool.states[.cursor], .shared(managed: false))
    }
}
