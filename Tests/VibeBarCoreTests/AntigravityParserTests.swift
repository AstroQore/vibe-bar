import XCTest
@testable import VibeBarCore

final class AntigravityParserTests: XCTestCase {
    func testParsesQuotaSummaryIntoFourStableBuckets() throws {
        let json = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit",
                    "remaining": {"remainingFraction": 0.64},
                    "resetTime": "2026-06-20T00:39:54Z"
                  },
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit",
                    "remaining": {"remainingFraction": 0.73},
                    "resetTime": "2026-06-15T12:52:10Z"
                  }
                ]
              },
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit",
                    "remaining": {"remainingFraction": 0.82},
                    "resetTime": "2026-06-19T08:45:39Z"
                  },
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit",
                    "remaining": {"remainingFraction": 0.91},
                    "resetTime": "2026-06-15T11:39:34Z"
                  }
                ]
              }
            ]
          }
        }
        """
        let snap = try AntigravityResponseParser.parseQuotaSummary(data: Data(json.utf8))

        XCTAssertEqual(snap.buckets.map(\.id), [
            "gemini_five_hour",
            "gemini_weekly",
            "claude_gpt_five_hour",
            "claude_gpt_weekly"
        ])
        XCTAssertEqual(snap.buckets.map(\.title), ["5 Hours", "Weekly", "5 Hours", "Weekly"])
        XCTAssertEqual(snap.buckets.map(\.shortLabel), ["G 5h", "G wk", "C+G 5h", "C+G wk"])
        XCTAssertEqual(snap.buckets.map(\.groupTitle), [
            "Gemini Models",
            "Gemini Models",
            "Claude and GPT Models",
            "Claude and GPT Models"
        ])
        XCTAssertEqual(snap.buckets.map(\.rawWindowSeconds), [18_000, 604_800, 18_000, 604_800])
        XCTAssertEqual(snap.buckets[0].remainingPercent, 91, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].remainingPercent, 82, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[2].remainingPercent, 73, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[3].remainingPercent, 64, accuracy: 0.01)
        XCTAssertTrue(snap.buckets.allSatisfy { $0.resetAt != nil })
    }

    func testParsesSupportedRemainingFractionShapesAndSnakeCase() throws {
        let json = """
        {
          "groups": [
            {
              "display_name": "Gemini Models",
              "buckets": [
                {
                  "bucket_id": "gemini_session",
                  "display_name": "Session",
                  "remaining_fraction": 0.5
                },
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": {"case": "remainingFraction", "value": 0.25}
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-five-hour",
                  "displayName": "Five Hour Limit",
                  "remaining": {"remainingFraction": 0.75}
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit",
                  "remainingFraction": 0.0
                }
              ]
            }
          ]
        }
        """
        let snap = try AntigravityResponseParser.parseQuotaSummary(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.map(\.remainingPercent), [50, 25, 75, 0])
    }

    func testSkipsUnknownDisabledAndFractionlessQuotaSummaryBuckets() throws {
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit",
                  "remaining": {"remainingFraction": 0.9}
                },
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit"
                },
                {
                  "bucketId": "gemini-monthly",
                  "displayName": "Monthly Limit",
                  "remaining": {"remainingFraction": 0.8}
                },
                {
                  "bucketId": "gemini-session-disabled",
                  "displayName": "Session",
                  "disabled": true,
                  "remaining": {"remainingFraction": 0.7}
                }
              ]
            }
          ]
        }
        """
        let snap = try AntigravityResponseParser.parseQuotaSummary(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.map(\.id), ["gemini_five_hour"])
    }

    func testQuotaSummaryWithoutUsableKnownBucketsThrows() {
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {"bucketId": "gemini-weekly", "displayName": "Weekly Limit"}
              ]
            }
          ]
        }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseQuotaSummary(data: Data(json.utf8)))
    }

    func testFetchLocalSnapshotUsesSummaryThenMergesIdentity() async throws {
        var paths: [String] = []
        var bodies: [String] = []
        let snapshot = try await AntigravityQuotaAdapter.fetchLocalSnapshot { path, body in
            paths.append(path)
            bodies.append(String(decoding: body, as: UTF8.self))
            if path.contains("RetrieveUserQuotaSummary") {
                return Data(Self.fourBucketQuotaSummaryJSON.utf8)
            }
            return Data(Self.userStatusIdentityJSON.utf8)
        }

        XCTAssertEqual(paths, [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus"
        ])
        XCTAssertEqual(bodies, [#"{"forceRefresh":true}"#, "{}"])
        XCTAssertEqual(snapshot.buckets.count, 4)
        XCTAssertEqual(snapshot.email, "user@example.com")
        XCTAssertEqual(snapshot.planName, "Ultra Lite")
        XCTAssertEqual(snapshot.modelLabels["MODEL_PLACEHOLDER_M132"], "Gemini Flash")
    }

    func testFetchLocalSnapshotKeepsFourBucketsWhenIdentityFails() async throws {
        let snapshot = try await AntigravityQuotaAdapter.fetchLocalSnapshot { path, _ in
            if path.contains("RetrieveUserQuotaSummary") {
                return Data(Self.fourBucketQuotaSummaryJSON.utf8)
            }
            throw QuotaError.network("identity unavailable")
        }
        XCTAssertEqual(snapshot.buckets.count, 4)
        XCTAssertNil(snapshot.email)
        XCTAssertNil(snapshot.planName)
    }

    func testUserStatusProvidesIdentityAndLabelsButNoLegacyQuotaRows() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "user@example.com",
            "userTier": {"id": "tier-paid", "name": "Pro"},
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini Flash",
                  "modelOrAlias": {"model": "MODEL_PLACEHOLDER_M132"},
                  "quotaInfo": {"remainingFraction": 0.42}
                }
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.email, "user@example.com")
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertTrue(snap.buckets.isEmpty, "GetUserStatus must no longer restore per-model quota rows.")
        XCTAssertEqual(snap.modelLabels["MODEL_PLACEHOLDER_M132"], "Gemini Flash")
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

    private static let fourBucketQuotaSummaryJSON = """
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "buckets": [
              {"bucketId": "gemini-5h", "displayName": "Five Hour Limit", "remaining": {"remainingFraction": 0.91}},
              {"bucketId": "gemini-weekly", "displayName": "Weekly Limit", "remaining": {"remainingFraction": 0.82}}
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "buckets": [
              {"bucketId": "3p-5h", "displayName": "Five Hour Limit", "remaining": {"remainingFraction": 0.73}},
              {"bucketId": "3p-weekly", "displayName": "Weekly Limit", "remaining": {"remainingFraction": 0.64}}
            ]
          }
        ]
      }
    }
    """

    private static let userStatusIdentityJSON = """
    {
      "code": "OK",
      "userStatus": {
        "email": "user@example.com",
        "userTier": {"id": "g1-ultra-lite-tier", "name": "Ultra Lite"},
        "cascadeModelConfigData": {
          "clientModelConfigs": [
            {"label": "Gemini Flash", "modelOrAlias": {"model": "MODEL_PLACEHOLDER_M132"}}
          ]
        }
      }
    }
    """

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
