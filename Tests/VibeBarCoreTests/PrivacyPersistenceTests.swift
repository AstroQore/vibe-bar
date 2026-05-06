import Foundation
import XCTest
@testable import VibeBarCore

final class PrivacyPersistenceTests: XCTestCase {
    func testClaudeCookieMinimizationKeepsOnlySessionKey() {
        let raw = "Cookie: other=value; sessionKey=test-session-key; analytics=abc"

        XCTAssertEqual(
            ClaudeWebCookieStore.minimizedCookieHeader(from: raw),
            "sessionKey=test-session-key"
        )
        XCTAssertNil(ClaudeWebCookieStore.minimizedCookieHeader(from: "other=value"))
    }

    func testQuotaStoredPayloadOmitsAccountIdentifiers() throws {
        let quota = AccountQuota(
            accountId: "acct_real_codex",
            tool: .codex,
            buckets: [QuotaBucket(id: "five_hour", title: "5h", shortLabel: "5h", usedPercent: 42)],
            plan: "Pro",
            email: "person@example.com",
            queriedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providerExtras: ProviderExtras(
                tool: .codex,
                creditsRemainingUSD: 12.34,
                creditsTopupURL: URL(string: "https://example.com/account/acct_real_codex"),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )

        let stored = QuotaCacheStore.StoredQuota(quota)
        let data = try JSONEncoder().encode(stored)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("acct_real_codex"))
        XCTAssertFalse(json.contains("person@example.com"))
        XCTAssertFalse(json.contains("accountId"))
        XCTAssertFalse(json.contains("email"))
        XCTAssertFalse(json.contains("creditsTopupURL"))

        let restored = stored.quota(accountId: quota.accountId)
        XCTAssertEqual(restored.accountId, quota.accountId)
        XCTAssertNil(restored.email)
        XCTAssertNil(restored.providerExtras)
    }

    func testQuotaCacheFileComponentDoesNotExposeAccountId() {
        let accountId = "acct_real_codex"
        let component = QuotaCacheStore.cacheFileComponent(for: accountId)

        XCTAssertTrue(component.hasPrefix("quota-v1-"))
        XCTAssertFalse(component.contains(accountId))
        XCTAssertEqual(component, QuotaCacheStore.cacheFileComponent(for: accountId))
        XCTAssertNotEqual(component, VibeBarLocalStore.safeFileComponent(accountId))
    }

    func testScanCacheStoresHashedPathKeys() throws {
        var cache = CostUsageScanCache()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Users/example/.codex/sessions/private-project/session.jsonl"
        let event = CostUsageScanCache.ParsedEvent(
            date: mtime,
            model: "gpt-5",
            input: 1,
            output: 2,
            cache: 3,
            costUSD: 0.04
        )

        cache.store([event], for: path, mtime: mtime, size: 123)

        XCTAssertNil(cache.entries[path])
        let key = try XCTUnwrap(cache.entries.keys.first)
        XCTAssertTrue(key.hasPrefix("path-v1-"))
        XCTAssertFalse(key.contains("/Users"))
        XCTAssertFalse(key.contains("private-project"))

        let data = try JSONEncoder().encode(cache)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("private-project"))
        XCTAssertEqual(cache.reusable(for: path, mtime: mtime, size: 123)?.count, 1)
    }

    func testScanCacheMigratesLegacyPlainPathKeyOnReuse() {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Users/example/.claude/projects/private-project/session.jsonl"
        let entry = CostUsageScanCache.FileEntry(mtime: mtime, size: 456, events: [])
        var cache = CostUsageScanCache(entries: [path: entry])

        XCTAssertNotNil(cache.reusable(for: path, mtime: mtime, size: 456))
        XCTAssertNil(cache.entries[path])
        XCTAssertNotNil(cache.entries[CostUsageScanCache.entryKey(for: path)])
    }
}
