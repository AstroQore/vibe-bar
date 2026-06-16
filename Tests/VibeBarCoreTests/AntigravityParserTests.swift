import XCTest
@testable import VibeBarCore

final class AntigravityParserTests: XCTestCase {
    func testParsesUserStatusWithModelQuotas() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "user@example.com",
            "userTier": {"id": "tier-paid", "name": "Pro"},
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude Sonnet 4",
                  "modelOrAlias": {"model": "claude-sonnet-4-20250514"},
                  "quotaInfo": {"remainingFraction": 0.42, "resetTime": "2026-06-01T00:00:00Z"}
                },
                {
                  "label": "Gemini 2.5 Pro",
                  "modelOrAlias": {"model": "gemini-2.5-pro"},
                  "quotaInfo": {"remainingFraction": 0.78}
                },
                {
                  "label": "Gemini Flash Lite",
                  "modelOrAlias": {"model": "gemini-2.5-flash-lite"},
                  "quotaInfo": {"remainingFraction": 0.95}
                }
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.email, "user@example.com")
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.buckets[0].title, "Claude Sonnet 4")
        XCTAssertEqual(snap.buckets[0].usedPercent, 58.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)
        XCTAssertEqual(snap.buckets[0].groupTitle, "Claude")

        XCTAssertEqual(snap.buckets[1].usedPercent, 22.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].groupTitle, "Gemini Pro")

        XCTAssertEqual(snap.buckets[2].usedPercent, 5.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[2].groupTitle, "Gemini Flash Lite")
    }

    /// Google's wire format omits `remainingFraction` (proto3 zero
    /// default) when a model's per-window quota is fully spent. The
    /// older parser dropped those entries entirely, hiding the
    /// exhausted state from the user — they would just stop seeing
    /// the affected model in Vibe Bar's card while still seeing the
    /// reset countdown in the official Antigravity dashboard.
    /// Treat a missing fraction as 0 so the bucket stays visible.
    func testKeepsDepletedModelsWithMissingRemainingFraction() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.5 Flash (High)",
                  "modelOrAlias": {"model": "gemini-3.5-flash-high"},
                  "quotaInfo": {"resetTime": "2026-05-23T01:05:00Z"}
                },
                {
                  "label": "Gemini 3.5 Flash (Medium)",
                  "modelOrAlias": {"model": "gemini-3.5-flash-medium"},
                  "quotaInfo": {"remainingFraction": 0.0, "resetTime": "2026-05-23T01:05:00Z"}
                },
                {
                  "label": "Claude Sonnet 4.6 (Thinking)",
                  "modelOrAlias": {"model": "claude-sonnet-4-6"},
                  "quotaInfo": {"remainingFraction": 0.42, "resetTime": "2026-05-23T05:55:00Z"}
                }
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 3, "All three models must surface — including the two depleted Gemini variants.")

        let flashHigh = try XCTUnwrap(snap.buckets.first { $0.title == "Gemini 3.5 Flash (High)" })
        XCTAssertEqual(flashHigh.usedPercent, 100.0, accuracy: 0.01, "Missing remainingFraction should map to 100% used.")
        XCTAssertNotNil(flashHigh.resetAt, "Reset countdown should still surface.")

        let flashMed = try XCTUnwrap(snap.buckets.first { $0.title == "Gemini 3.5 Flash (Medium)" })
        XCTAssertEqual(flashMed.usedPercent, 100.0, accuracy: 0.01, "Explicit zero fraction should also be 100% used.")

        let sonnet = try XCTUnwrap(snap.buckets.first { $0.title == "Claude Sonnet 4.6 (Thinking)" })
        XCTAssertEqual(sonnet.usedPercent, 58.0, accuracy: 0.01, "Non-depleted models continue to compute as before.")
    }

    /// Entries with no quotaInfo at all stay filtered out — without
    /// any quota object, we can't say anything meaningful about the
    /// model's usage and dragging a "no data" pill into the card is
    /// worse than omitting it.
    func testStillSkipsModelsWithoutQuotaInfo() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label": "Unknown Model A", "modelOrAlias": {"model": "unknown-a"}},
                {"label": "Claude Sonnet 4.6 (Thinking)", "modelOrAlias": {"model": "claude-sonnet"}, "quotaInfo": {"remainingFraction": 0.5}}
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].title, "Claude Sonnet 4.6 (Thinking)")
    }

    func testFallsBackToPlanInfoWhenUserTierMissing() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": null,
            "planStatus": {
              "planInfo": {"planDisplayName": "Pro Trial", "productName": "AntiGravity"}
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label": "x", "modelOrAlias": {"model": "x"}, "quotaInfo": {"remainingFraction": 1.0}}
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.planName, "Pro Trial")
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 0.0, accuracy: 0.01)
    }

    func testNormalizesCurrentPlaceholderModelsFromLabels() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.5 Flash (High)",
                  "modelOrAlias": {"model": "MODEL_PLACEHOLDER_M132"},
                  "quotaInfo": {"remainingFraction": 0.0}
                },
                {
                  "label": "Claude Sonnet 4.6 (Thinking)",
                  "modelOrAlias": {"model": "MODEL_PLACEHOLDER_M35"},
                  "quotaInfo": {"remainingFraction": 1.0}
                },
                {
                  "label": "GPT-OSS 120B (Medium)",
                  "modelOrAlias": {"model": "MODEL_OPENAI_GPT_OSS_120B_MEDIUM"},
                  "quotaInfo": {"remainingFraction": 0.25}
                }
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))

        XCTAssertEqual(snap.buckets.map(\.id), [
            "gemini-3.5-flash-high",
            "claude-sonnet-4.6-thinking",
            "gpt-oss-120b-medium"
        ])
        XCTAssertEqual(snap.buckets[0].usedPercent, 100.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].remainingPercent, 0.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].groupTitle, "Gemini Flash")
        XCTAssertEqual(snap.buckets[1].shortLabel, "Sonnet")
        XCTAssertEqual(snap.buckets[2].groupTitle, "GPT-OSS")
    }

    func testMissingUserStatusThrowsParseFailure() {
        let json = """
        { "code": 0 }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8)))
    }

    func testNonZeroNumericCodeThrowsNetwork() {
        let json = """
        { "code": 16, "message": "unauthenticated" }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testStringCodeUnauthenticatedThrowsNetwork() {
        let json = """
        { "code": "unauthenticated", "message": "session expired" }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testCodeOKStringIsAcceptedAsSuccess() throws {
        let json = """
        {
          "code": "OK",
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label": "Pro", "modelOrAlias": {"model": "x"}, "quotaInfo": {"remainingFraction": 0.6}}
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 40.0, accuracy: 0.01)
    }

    func testProcessLineParse() {
        let line = "  12345 /Applications/Antigravity/Resources/.../language_server_macos --csrf_token=abc --extension_server_port=44567"
        let parsed = AntigravityProcessLine.parse(line)
        XCTAssertEqual(parsed?.pid, 12345)
        XCTAssertTrue(parsed?.command.contains("language_server_macos") ?? false)
    }

    /// AntiGravity IDE 1.x shipped its language server as
    /// `language_server_macos`. The adapter must still recognise that
    /// older naming so users on legacy builds aren't broken when we
    /// loosen the substring match for v2.0.x.
    func testMatchesLegacyLanguageServerMacosBinary() {
        let command = "/Applications/Antigravity.app/Contents/Resources/bin/language_server_macos --app_data_dir antigravity --csrf_token 00000000-0000-0000-0000-000000000000"
        XCTAssertTrue(AntigravityQuotaAdapter.matchesAntigravityProcess(lowercasedCommand: command.lowercased()))
    }

    /// AntiGravity IDE v2.0.x renamed the binary to plain
    /// `language_server` (without the `_macos` suffix). The previous
    /// hard-coded `processName = "language_server_macos"` regressed
    /// detection for this build — this test pins the v2.0.x command
    /// shape (mirrored from a live AQ session, with the CSRF
    /// token scrubbed to a synthetic UUID).
    func testMatchesV2LanguageServerBinary() {
        let command = "/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.0.1 --override_user_agent_name antigravity --https_server_port 0 --csrf_token 00000000-0000-0000-0000-000000000000 --app_data_dir antigravity --api_server_url https://generativelanguage.googleapis.com --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com --enable_sidecars"
        XCTAssertTrue(AntigravityQuotaAdapter.matchesAntigravityProcess(lowercasedCommand: command.lowercased()))
    }

    /// Other vendors ship binaries called `language_server` too
    /// (e.g. Codeium, Cursor, Sourcegraph). Without an AntiGravity
    /// path or `--app_data_dir antigravity` flag, the match must
    /// reject — otherwise we'd dispatch CSRF tokens to the wrong LSP.
    func testRejectsForeignLanguageServer() {
        let command = "/Applications/Codeium.app/.../language_server --csrf_token=other"
        XCTAssertFalse(AntigravityQuotaAdapter.matchesAntigravityProcess(lowercasedCommand: command.lowercased()))
    }

    /// Conversely, a non-language-server process running inside an
    /// AntiGravity directory (e.g. a helper) must not get picked up —
    /// the language-server binary substring is the load-bearing
    /// filter for "this is the RPC endpoint we want."
    func testRejectsNonLanguageServerInAntigravityDir() {
        let command = "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/.../some-other-binary --app_data_dir antigravity"
        XCTAssertFalse(AntigravityQuotaAdapter.matchesAntigravityProcess(lowercasedCommand: command.lowercased()))
    }

    func testLocalhostTrustPolicyAcceptsLocalhostOnly() {
        XCTAssertTrue(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertTrue(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "localhost",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertFalse(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "evil.example.com",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertFalse(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                hasServerTrust: true
            )
        )
    }

    // MARK: - Multi-server process parsing

    func testParseProcessInfosFindsEveryAntigravityServer() {
        let ps = """
        83055 /Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity --csrf_token AAA --extension_server_port 1234 --extension_server_csrf_token EXT
        83474 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity-ide --csrf_token BBB
        99999 /Users/example/.local/bin/agy-language_server --app_data_dir antigravity-cli --csrf_token CCC
        42 /usr/bin/some_other_language_server --not-antigravity
        7 /usr/bin/unrelated
        """
        let infos = AntigravityLanguageServerClient.parseProcessInfos(psOutput: ps)
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(Set(infos.map(\.csrfToken)), ["AAA", "BBB", "CCC"])
        XCTAssertEqual(Set(infos.map(\.pid)), [83055, 83474, 99999])
        let hub = infos.first { $0.pid == 83055 }
        XCTAssertEqual(hub?.extensionPort, 1234)
        XCTAssertEqual(hub?.extensionCSRFToken, "EXT")
        XCTAssertTrue(AntigravityLanguageServerClient.sawAntigravityProcess(psOutput: ps))
    }

    func testParseProcessInfosEmptyWhenNoAntigravityServer() {
        let ps = """
        1 /usr/bin/foo
        2 /usr/bin/language_server --app_data_dir somethingelse --csrf_token X
        """
        XCTAssertTrue(AntigravityLanguageServerClient.parseProcessInfos(psOutput: ps).isEmpty)
        XCTAssertFalse(AntigravityLanguageServerClient.sawAntigravityProcess(psOutput: ps))
    }
}
