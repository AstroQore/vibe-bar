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
}
