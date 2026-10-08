import XCTest
@testable import VibeBarCore

/// Adopted linked skills: `~/.agents/skills/<name>` is a symlink into a
/// folder Vibe Bar does not manage. Every test here checks the same promise
/// from a different side — the linked folder is never written, never hashed,
/// and never copied, except by the one explicit conversion.
final class LinkedSkillTests: XCTestCase {
    private let skillName = "a1-video-agent"

    /// A synthetic checkout holding one skill, linked into the shared root
    /// the way a user links a repository they work on.
    private struct Fixture {
        let home: SkillTestHome
        let repository: URL
        let external: URL
        let link: URL
        let service: SkillsService
    }

    private func makeFixture(name: String? = nil) throws -> Fixture {
        let name = name ?? skillName
        let home = try SkillTestHome()
        let repository = home.url.appendingPathComponent("Coding/media-skills", isDirectory: true)
        let external = repository.appendingPathComponent(".agent/skills/\(name)", isDirectory: true)
        try home.makeSkillDirectory(
            at: external,
            name: name,
            description: "Synthetic linked source",
            extraFiles: ["scripts/run.py": "print('synthetic')", "references/notes.md": "notes"]
        )
        try home.write("repository readme", to: repository.appendingPathComponent("README.md"))
        try home.makeDirectory(home.ssot)
        let link = home.ssot.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        return Fixture(
            home: home,
            repository: repository,
            external: external,
            link: link,
            service: SkillsService(homeDirectory: home.path)
        )
    }

    private func assertRefused<T>(
        _ expected: SkillError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SkillError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func rawTarget(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    // MARK: - Registry format

    func testARegistryWithoutReceiptsDecodesEveryRowAsOwned() async throws {
        let home = try SkillTestHome()
        let json = """
        {"schemaVersion":1,"skills":[
          {"id":"local:alpha","name":"alpha","directory":"alpha","installedAt":0,"contentHash":"abc",
           "apps":{"claude":{"method":"symlink","adopted":true}}}
        ]}
        """
        try home.write(json, to: VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path))
        let rows = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.origin, .owned)
        XCTAssertNil(rows.first?.linkReceipt)
        XCTAssertEqual(rows.first?.contentHash, "abc")
    }

    func testALinkReceiptRoundTripsUnderTheNewSchemaVersion() async throws {
        let home = try SkillTestHome()
        let receipt = SkillLinkReceipt(
            target: "/Users/example/Coding/media-skills/.agent/skills/alpha",
            resolvedPath: "/Users/example/Coding/media-skills/.agent/skills/alpha",
            device: 16_777_220,
            inode: 4_242,
            confirmedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await SkillsStore(homeDirectory: home.path).upsert(Skill(
            id: .local(directory: "alpha"),
            name: "alpha",
            directory: "alpha",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .linked(receipt)
        ))
        let url = VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, SkillsStore.currentSchemaVersion)
        XCTAssertEqual(SkillsStore.currentSchemaVersion, 2)
        let row = try XCTUnwrap((object["skills"] as? [[String: Any]])?.first)
        XCTAssertEqual((row["link"] as? [String: Any])?["target"] as? String, receipt.target)
        XCTAssertNil(row["contentHash"], "a linked row carries no content hash")
        XCTAssertNil(row["linkCheck"], "live verification is never persisted")

        let reloaded = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(reloaded.first?.origin, .linked(receipt))
        XCTAssertNil(reloaded.first?.linkCheck)
    }

    func testAnUnreadableReceiptFallsBackToOwnedRatherThanDroppingTheRow() async throws {
        let home = try SkillTestHome()
        let json = """
        {"schemaVersion":2,"skills":[
          {"id":"local:alpha","name":"alpha","directory":"alpha","installedAt":0,"apps":{},
           "link":{"target":5}}
        ]}
        """
        try home.write(json, to: VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path))
        let rows = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(rows.map(\.directory), ["alpha"])
        XCTAssertEqual(rows.first?.origin, .owned)
    }

    // MARK: - Adoption

    func testAdoptingALinkWritesOnlyTheRegistry() async throws {
        let fixture = try makeFixture()
        let home = fixture.home
        // Created up front so writing skills.json touches nothing outside it.
        try home.makeDirectory(VibeBarLocalStore.baseDirectory(homeDirectory: home.path))
        let before = home.lstatSnapshot(under: home.url, excluding: ["/.vibebar"])
        let contents = home.fileContents(under: fixture.repository)

        let adopted = try await fixture.service.adoptLinkedSkill(directoryName: skillName)

        XCTAssertEqual(home.lstatSnapshot(under: home.url, excluding: ["/.vibebar"]), before)
        XCTAssertEqual(home.fileContents(under: fixture.repository), contents)
        XCTAssertEqual(adopted.id, .local(directory: skillName))
        XCTAssertEqual(adopted.name, skillName)
        XCTAssertEqual(adopted.description, "Synthetic linked source")
        XCTAssertNil(adopted.contentHash)
        let receipt = try XCTUnwrap(adopted.linkReceipt)
        XCTAssertEqual(receipt.target, try rawTarget(fixture.link))
        XCTAssertEqual(receipt.resolvedPath, fixture.external.resolvingSymlinksInPath().standardizedFileURL.path)

        // Reloading verifies the receipt at stat level and hashes nothing.
        let rehashBefore = await fixture.service.reloadRehashCount
        let copyHashesBefore = await fixture.service.copyHashComputations
        let inventory = await fixture.service.inventory()
        let rehashAfter = await fixture.service.reloadRehashCount
        let copyHashesAfter = await fixture.service.copyHashComputations
        XCTAssertEqual(rehashAfter, rehashBefore)
        XCTAssertEqual(copyHashesAfter, copyHashesBefore)
        let row = try XCTUnwrap(inventory.installed.first)
        XCTAssertEqual(row.linkCheck, .matches)
        XCTAssertNil(row.localContentHash)
        XCTAssertFalse(row.isLocallyModified)
        XCTAssertTrue(inventory.discoveredShared.isEmpty, "an adopted link is listed once, as managed")
        // Claude and AntiGravity read only their own folders: nothing was
        // invented for them, and the toggle offers to project it.
        XCTAssertEqual(row.activationState(for: .claude), .notProjected)
        XCTAssertEqual(row.activationState(for: .antigravity), .notProjected)
        XCTAssertEqual(row.activationState(for: .codex), .enabled)
        XCTAssertEqual(home.lstatSnapshot(under: home.url, excluding: ["/.vibebar"]), before)
    }

    func testImportScanOffersLinksAndAdoptionKeepsExistingHarnessLinks() async throws {
        let fixture = try makeFixture(name: "admin-cli")
        let home = fixture.home
        // Two levels: Claude's entry links to the shared entry, which links out.
        try home.makeAbsoluteSymlink("admin-cli", in: .claude, toSSOT: "admin-cli")
        // A real folder of the same name in a harness directory is a conflict,
        // not a skill to copy into the slot the link already holds.
        try home.makeSkillDirectory(at: home.appDirectory(.grok).appendingPathComponent("admin-cli"))
        let before = home.lstatSnapshot()

        let report = SkillImportScanner.scan(homeDirectory: home.path)

        XCTAssertEqual(home.lstatSnapshot(), before)
        XCTAssertTrue(report.adopted.isEmpty, "a link is never recorded without being picked")
        let candidate = try XCTUnwrap(report.linkedCandidates.first)
        XCTAssertEqual(report.linkedCandidates.count, 1)
        XCTAssertEqual(candidate.directoryName, "admin-cli")
        XCTAssertEqual(candidate.linkTarget, try rawTarget(fixture.link))
        XCTAssertEqual(candidate.projectedApps, [.claude])
        XCTAssertEqual(report.conflicts, [SkillImportConflict(directoryName: "admin-cli", app: .grok)])
        XCTAssertTrue(report.unmanagedDirectories.isEmpty)

        let adopted = try await fixture.service.adoptLinkedSkill(directoryName: "admin-cli")
        XCTAssertEqual(adopted.apps[.claude], SkillMaterialization(method: .symlink, adopted: true))
        let rowCandidates = await fixture.service.inventory().installed.first
        let row = try XCTUnwrap(rowCandidates)
        XCTAssertEqual(row.activationState(for: .claude), .enabled)
    }

    func testALinkToAnAncestorOfTheSharedRootIsNotAdoptable() async throws {
        let home = try SkillTestHome()
        let agents = home.url.appendingPathComponent(".agents", isDirectory: true)
        try home.write("---\nname: everything\n---\n", to: agents.appendingPathComponent("SKILL.md"))
        try home.makeDirectory(home.ssot)
        try FileManager.default.createSymbolicLink(
            at: home.ssot.appendingPathComponent("everything"),
            withDestinationURL: agents
        )
        let service = SkillsService(homeDirectory: home.path)
        await assertRefused(.linkTargetUnsupported("everything")) {
            try await service.adoptLinkedSkill(directoryName: "everything")
        }
        let rows = await service.store.all()
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Projection

    func testEnablingClaudeLinksToTheSharedPathAndNeverCopies() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        let externalBefore = fixture.home.lstatSnapshot(under: fixture.repository)
        let contents = fixture.home.fileContents(under: fixture.repository)

        // The default method asks for a copy; a linked skill is linked anyway.
        let changed = try await service.setActivation(skill.id, app: .claude, action: .enable, method: .copy)
        XCTAssertTrue(changed)
        let projection = fixture.home.appDirectory(.claude).appendingPathComponent(skillName)
        XCTAssertEqual(SkillFileSystem.kind(of: projection), .symlink)
        XCTAssertEqual(try rawTarget(projection), fixture.link.standardizedFileURL.path,
                       "the projection names the shared path, not the external folder")
        _ = try await service.setActivation(skill.id, app: .antigravity, action: .enable)
        XCTAssertEqual(
            try rawTarget(fixture.home.appDirectory(.antigravity).appendingPathComponent(skillName)),
            fixture.link.standardizedFileURL.path
        )

        let rowCandidates = await service.inventory().installed.first

        let row = try XCTUnwrap(rowCandidates)
        XCTAssertEqual(row.activationState(for: .claude), .enabled)
        XCTAssertEqual(row.apps[.claude]?.method, .symlink)
        XCTAssertEqual(row.activationState(for: .antigravity), .enabled)

        // The engine itself refuses a copy of a linked skill, and refuses a
        // link it has no receipt for.
        let engine = SkillSyncEngine(homeDirectory: fixture.home.path)
        XCTAssertThrowsError(try engine.materialize(
            skillDirectoryName: skillName, into: .grok, method: .copy, linkReceipt: skill.linkReceipt
        )) { XCTAssertEqual($0 as? SkillError, .linkedSkillUnsupported(self.skillName)) }
        XCTAssertThrowsError(try engine.materialize(skillDirectoryName: skillName, into: .grok, method: .symlink)) {
            XCTAssertEqual($0 as? SkillError, .sourceNotADirectory(self.skillName))
        }

        _ = try await service.setActivation(skill.id, app: .claude, action: .disableInHarness)
        let removed = try await service.setActivation(skill.id, app: .claude, action: .removeProjection)
        XCTAssertTrue(removed)
        XCTAssertEqual(SkillFileSystem.kind(of: projection), .missing)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .symlink)
        XCTAssertEqual(fixture.home.lstatSnapshot(under: fixture.repository), externalBefore)
        XCTAssertEqual(fixture.home.fileContents(under: fixture.repository), contents)
    }

    func testBulkActionsCoverLinkedRows() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let owned = try fixture.home.makeSkillDirectory(at: fixture.home.url.appendingPathComponent("Downloads/owned"))
        _ = try await service.installLocal(from: owned, name: "owned")
        let linked = try await service.adoptLinkedSkill(directoryName: skillName)
        let externalBefore = fixture.home.lstatSnapshot(under: fixture.repository)

        let rows = await service.inventory().installed
        XCTAssertEqual(Set(rows.map(\.directory)), ["owned", skillName])
        let plan = SkillBulkPlan(app: .claude, direction: .enable, skills: rows)
        XCTAssertEqual(Set(plan.steps.map(\.id)), [linked.id, .local(directory: "owned")])
        let outcome = await plan.run { step in
            try await service.setActivation(step.id, app: .claude, action: step.action, method: .copy)
        }
        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(outcome.notChanged, 0)
        let projection = fixture.home.appDirectory(.claude).appendingPathComponent(skillName)
        XCTAssertEqual(try rawTarget(projection), fixture.link.standardizedFileURL.path)

        let enabled = await service.inventory().installed
        XCTAssertTrue(enabled.allSatisfy { $0.activationState(for: .claude) == .enabled })
        let disable = SkillBulkPlan(app: .claude, direction: .disable, skills: enabled)
        XCTAssertEqual(disable.steps.map(\.action), [.disableInHarness, .disableInHarness])
        let disabled = await disable.run { step in
            try await service.setActivation(step.id, app: .claude, action: step.action)
        }
        XCTAssertEqual(disabled.succeeded, 2)
        XCTAssertEqual(fixture.home.lstatSnapshot(under: fixture.repository), externalBefore)
    }

    // MARK: - A changed link

    func testARepointedLinkPausesEveryWriteUntilItIsReconfirmed() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let home = fixture.home
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        _ = try await service.setActivation(skill.id, app: .claude, action: .enable)
        let other = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Coding/fork/\(skillName)"),
            name: skillName,
            description: "Fork"
        )
        try FileManager.default.removeItem(at: fixture.link)
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: other)

        let inventory = await service.inventory()
        XCTAssertTrue(inventory.installed.isEmpty, "a changed link is not a managed row")
        let entry = try XCTUnwrap(inventory.discoveredShared.first)
        XCTAssertEqual(entry.registration, .receiptMismatch(skill.id, .retargeted))
        XCTAssertTrue(entry.canReconfirmLink)
        XCTAssertFalse(entry.canUnlink, "the link on disk is not the one that was adopted")
        XCTAssertFalse(entry.canAdoptLink)

        let snapshot = home.lstatSnapshot(under: home.url, excluding: ["/.vibebar"])
        let mismatch = SkillError.linkReceiptMismatch(skillName)
        await assertRefused(mismatch) { try await service.setActivation(skill.id, app: .claude, action: .removeProjection) }
        await assertRefused(mismatch) { try await service.setActivation(skill.id, app: .antigravity, action: .enable) }
        await assertRefused(mismatch) { try await service.setActivation(skill.id, app: .codex, action: .disableInHarness) }
        await assertRefused(mismatch) { try await service.uninstall(skill.id) }
        await assertRefused(mismatch) { try await service.convertLinkedSkillToCopy(skill.id) }
        await assertRefused(.linkedSkillUnsupported(skillName)) { try await service.acceptLocalChanges(skill.id) }
        XCTAssertEqual(home.lstatSnapshot(under: home.url, excluding: ["/.vibebar"]), snapshot)
        let stored = await service.store.skill(with: skill.id)
        XCTAssertNotNil(stored?.apps[.claude], "a poll does not rewrite a changed row's projections")

        let reconfirmed = try await service.reconfirmLinkedSkill(skill.id)
        XCTAssertEqual(reconfirmed.linkReceipt?.resolvedPath, other.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(reconfirmed.description, "Fork")
        let after = await service.inventory()
        XCTAssertTrue(after.discoveredShared.isEmpty)
        let row = try XCTUnwrap(after.installed.first)
        XCTAssertEqual(row.linkCheck, .matches)
        XCTAssertEqual(row.activationState(for: .claude), .enabled)
        let removed = try await service.setActivation(skill.id, app: .claude, action: .removeProjection)
        XCTAssertTrue(removed)
    }

    func testAFolderRecreatedBehindTheSameLinkIsChangedButCanBeUnlinked() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        try FileManager.default.removeItem(at: fixture.external)
        try fixture.home.makeSkillDirectory(at: fixture.external, name: skillName)

        let entryCandidates = await service.inventory().discoveredShared.first

        let entry = try XCTUnwrap(entryCandidates)
        XCTAssertEqual(entry.registration, .receiptMismatch(skill.id, .replaced))
        XCTAssertTrue(entry.canUnlink)
        await assertRefused(.linkReceiptMismatch(skillName)) {
            try await service.setActivation(skill.id, app: .claude, action: .enable)
        }

        _ = try await service.uninstall(skill.id)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .missing)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.external), .directory)
        let rows = await service.store.all()
        XCTAssertTrue(rows.isEmpty)
    }

    func testARemovedLinkStaysListedSoItsProjectionsCanBeCleanedUp() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        _ = try await service.setActivation(skill.id, app: .claude, action: .enable)
        try FileManager.default.removeItem(at: fixture.link)

        let inventory = await service.inventory()
        XCTAssertTrue(inventory.installed.isEmpty)
        let entry = try XCTUnwrap(inventory.discoveredShared.first)
        XCTAssertEqual(entry.state, .missing)
        XCTAssertEqual(entry.registration, .receiptMismatch(skill.id, .missing))
        XCTAssertTrue(entry.canUnlink)
        XCTAssertFalse(entry.canReconfirmLink)

        let result = try await service.uninstall(skill.id)
        XCTAssertEqual(result.removedByApp[.claude], true)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.home.appDirectory(.claude).appendingPathComponent(skillName)), .missing)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.external), .directory)
        let after = await service.inventory()
        XCTAssertTrue(after.discoveredShared.isEmpty)
    }

    // MARK: - Unlink

    func testUnlinkRemovesOnlyTheLinkAndItsProjectionsAndBacksUpTheTarget() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let home = fixture.home
        let settings = home.url.appendingPathComponent(".claude/settings.json")
        try home.write("{\"theme\":\"dark\"}\n", to: settings)
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        _ = try await service.setActivation(skill.id, app: .claude, action: .enable)
        _ = try await service.setActivation(skill.id, app: .claude, action: .disableInHarness)
        XCTAssertTrue(home.contents(of: settings)?.contains("\"off\"") == true)
        let target = try rawTarget(fixture.link)
        let externalBefore = home.lstatSnapshot(under: fixture.repository)
        let contents = home.fileContents(under: fixture.repository)

        let result = try await service.uninstall(skill.id)

        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .missing)
        XCTAssertEqual(SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent(skillName)), .missing)
        XCTAssertTrue(result.retainedApps.isEmpty)
        XCTAssertEqual(home.lstatSnapshot(under: fixture.repository), externalBefore)
        XCTAssertEqual(home.fileContents(under: fixture.repository), contents)
        let rows = await service.store.all()
        XCTAssertTrue(rows.isEmpty)

        // The backup is the pointer: no payload, the target string in meta.
        XCTAssertEqual(SkillFileSystem.kind(of: result.backupURL.appendingPathComponent("skill")), .missing)
        let metadata = try JSONDecoder().decode(
            SkillBackupManager.Metadata.self,
            from: Data(contentsOf: result.backupURL.appendingPathComponent("meta.json"))
        )
        XCTAssertEqual(metadata.linkTarget, target)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: result.backupURL.path),
            ["meta.json"]
        )

        // The native disable written for it went with it; the rest stayed.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertNil(root["skillOverrides"])
        XCTAssertEqual(root["theme"] as? String, "dark")

        // Restoring recreates the same link and a fresh receipt.
        let restored = try await service.restoreBackup(result.backupURL)
        XCTAssertEqual(try rawTarget(fixture.link), target)
        XCTAssertNotNil(restored.linkReceipt)
        let rowCandidates = await service.inventory().installed.first
        let row = try XCTUnwrap(rowCandidates)
        XCTAssertEqual(row.linkCheck, .matches)
        XCTAssertEqual(home.lstatSnapshot(under: fixture.repository), externalBefore)
    }

    func testUnlinkKeepsANameKeyedSwitchAnotherSkillStillAnswersTo() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let home = fixture.home
        let settings = home.url.appendingPathComponent(".claude/settings.json")
        try home.write("{\"skillOverrides\":{\"\(skillName)\":\"off\"}}\n", to: settings)
        // Claude's own folder holds another skill with the same name.
        try home.makeSkillDirectory(
            at: home.appDirectory(.claude).appendingPathComponent("handmade"),
            name: skillName
        )
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)

        let result = try await service.uninstall(skill.id)

        XCTAssertEqual(result.retainedNativeApps, [.claude])
        XCTAssertTrue(home.contents(of: settings)?.contains("\"off\"") == true)
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .missing)
    }

    // MARK: - Convert to copy

    func testConvertingToACopyMakesAnOwnedSkillAndLeavesTheFolderAlone() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let home = fixture.home
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        _ = try await service.setActivation(skill.id, app: .claude, action: .enable)
        let externalBefore = home.lstatSnapshot(under: fixture.repository)
        let contents = home.fileContents(under: fixture.repository)

        let converted = try await service.convertLinkedSkillToCopy(skill.id)

        XCTAssertEqual(converted.origin, .owned)
        XCTAssertEqual(converted.id, .local(directory: skillName))
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .directory)
        XCTAssertEqual(converted.contentHash, try SkillDirectoryHasher.hash(directory: fixture.link))
        XCTAssertEqual(home.contents(of: fixture.link.appendingPathComponent("scripts/run.py")), "print('synthetic')")
        XCTAssertEqual(home.lstatSnapshot(under: fixture.repository), externalBefore)
        XCTAssertEqual(home.fileContents(under: fixture.repository), contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.ssot.path), [skillName],
                       "no staging directory is left behind")

        let rowCandidates = await service.inventory().installed.first

        let row = try XCTUnwrap(rowCandidates)
        XCTAssertNil(row.linkReceipt)
        XCTAssertFalse(row.isLocallyModified)
        XCTAssertEqual(row.activationState(for: .claude), .enabled, "the Claude link now leads to the copy")
        let stored = await service.store.skill(with: skill.id)
        XCTAssertNil(stored?.linkReceipt)
    }

    func testAConversionOverTheBudgetLeavesTheLinkInPlace() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        await assertRefused(.copyLimitExceeded(skillName)) {
            try await service.convertLinkedSkillToCopy(skill.id, budget: SkillLinkConversionBudget(maxEntries: 2))
        }
        XCTAssertEqual(SkillFileSystem.kind(of: fixture.link), .symlink)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.ssot.path), [skillName])
        let stored = await service.store.skill(with: skill.id)
        XCTAssertNotNil(stored?.linkReceipt)
    }

    // MARK: - Never hashed, never compared

    func testTheHasherNeverWalksThroughALinkedRoot() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try SkillDirectoryHasher.hash(directory: fixture.link))
        XCTAssertThrowsError(try SkillDirectoryHasher.treeMetadata(directory: fixture.link))
        XCTAssertNoThrow(try SkillDirectoryHasher.hash(directory: fixture.external))
    }

    func testCopiesOfALinkedSkillAreListedButNeverCompared() async throws {
        let fixture = try makeFixture()
        let service = fixture.service
        let home = fixture.home
        let skill = try await service.adoptLinkedSkill(directoryName: skillName)
        _ = try await service.setActivation(skill.id, app: .claude, action: .enable)
        try home.makeSkillDirectory(at: home.appDirectory(.grok).appendingPathComponent(skillName), name: skillName)

        let copyHashesBefore = await service.copyHashComputations
        let rowCandidates = await service.inventory().installed.first
        let row = try XCTUnwrap(rowCandidates)
        let copyHashesAfter = await service.copyHashComputations
        XCTAssertEqual(copyHashesAfter, copyHashesBefore)
        XCTAssertEqual(row.otherCopies.count, 1)
        XCTAssertNil(row.otherCopies.first?.contentHash)
        XCTAssertEqual(row.otherCopies.first?.sameAsShared, false)
        XCTAssertEqual(row.sharedCopy?.location, .shared)
        XCTAssertNil(row.sharedCopy?.contentHash)

        let versions = service.versionInventory(for: row)
        let shared = try XCTUnwrap(versions.shared)
        XCTAssertNil(shared.readableURL, "the linked folder is outside the read scope")
        XCTAssertNil(shared.contentHash)
        let claude = try XCTUnwrap(versions.versions.first { $0.kind == .symlink(.claude) })
        XCTAssertEqual(claude.linkState, .shared)
        XCTAssertNil(claude.readableURL)
        let grok = try XCTUnwrap(versions.versions.first { $0.kind == .independentCopy(.grok) })
        XCTAssertEqual(grok.comparison, .unknown)
        XCTAssertNil(grok.contentHash)
        XCTAssertNil(service.readScope.resolvedSkillDirectory(fixture.link))

        await assertRefused(.linkedSkillUnsupported(skillName)) {
            try await service.replaceSharedCopy(skill.id, with: try XCTUnwrap(row.otherCopies.first))
        }
        await assertRefused(.linkedSkillUnsupported(skillName)) { try await service.update(skill.id) }
    }
}
