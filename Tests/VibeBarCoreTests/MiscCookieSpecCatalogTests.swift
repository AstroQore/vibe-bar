import XCTest
@testable import VibeBarCore

final class MiscCookieSpecCatalogTests: XCTestCase {
    /// The providers that authenticate with something other than a
    /// browser cookie jar: API keys, a device-login flow, AK/SK signing,
    /// or a local process probe. Listed explicitly so the coverage test
    /// below can insist every misc-page provider is classified — a new
    /// cookie provider that nobody registered in the catalog would
    /// silently drop out of the batch import.
    private let nonCookieMiscProviders: Set<ToolType> = [
        .copilot,            // GitHub device login
        .zai,                // API key
        .minimax,            // API key
        .volcengineAgentPlan, // AK/SK signed Ark API
        .kilo,               // API key / ~/.local/share/kilo/auth.json
        .kiro,               // local `kiro-cli` probe
        .openRouter,         // API key
        .warp,               // API key
        .antigravity         // local language-server probe
    ]

    func testEveryMiscPageProviderIsClassified() {
        let cookieSourced = Set(MiscCookieSpecCatalog.allCookieSourcedTools)
        for tool in ToolType.miscPageProviders {
            XCTAssertTrue(
                cookieSourced.contains(tool) || nonCookieMiscProviders.contains(tool),
                "\(tool.rawValue) is neither in MiscCookieSpecCatalog nor listed as non-cookie. "
                    + "Register its cookieSpec in the catalog, or add it to nonCookieMiscProviders."
            )
        }
        XCTAssertTrue(
            cookieSourced.isDisjoint(with: nonCookieMiscProviders),
            "A provider cannot be both cookie-sourced and non-cookie."
        )
    }

    func testCatalogCoversExactlyTheTwelveCookieProviders() {
        XCTAssertEqual(
            MiscCookieSpecCatalog.allCookieSourcedTools,
            [
                .alibaba,
                .alibabaTokenPlan,
                .kimi,
                .cursor,
                .mimo,
                .iflytek,
                .tencentHunyuan,
                .tencentTokenPlan,
                .volcengine,
                .baiduQianfan,
                .openCodeGo,
                .ollama
            ],
            "allCookieSourcedTools should follow ToolType declaration order."
        )
        XCTAssertEqual(MiscCookieSpecCatalog.allSpecs.count, 12)
    }

    /// Guards the copy-paste failure mode the catalog invites: a switch
    /// arm returning the *wrong* adapter's spec compiles fine and would
    /// silently import Cursor's cookies for Kimi.
    func testCatalogEntriesMatchTheAdapterStatics() {
        let expected: [ToolType: MiscCookieResolver.Spec] = [
            .alibaba: AlibabaQuotaAdapter.cookieSpec,
            .alibabaTokenPlan: AlibabaTokenPlanQuotaAdapter.cookieSpec,
            .baiduQianfan: BaiduQianfanQuotaAdapter.cookieSpec,
            .cursor: CursorQuotaAdapter.cookieSpec,
            .iflytek: IFlyTekQuotaAdapter.cookieSpec,
            .kimi: KimiQuotaAdapter.cookieSpec,
            .mimo: MimoQuotaAdapter.cookieSpec,
            .ollama: OllamaQuotaAdapter.cookieSpec,
            .openCodeGo: OpenCodeGoQuotaAdapter.cookieSpec,
            .tencentHunyuan: TencentHunyuanQuotaAdapter.cookieSpec,
            .tencentTokenPlan: TencentTokenPlanQuotaAdapter.cookieSpec,
            .volcengine: VolcengineQuotaAdapter.cookieSpec
        ]
        for (tool, adapterSpec) in expected {
            guard let catalogSpec = MiscCookieSpecCatalog.spec(for: tool) else {
                return XCTFail("No catalog spec for \(tool.rawValue)")
            }
            XCTAssertEqual(catalogSpec.tool, tool, "\(tool.rawValue) spec points at the wrong tool")
            XCTAssertEqual(catalogSpec.tool, adapterSpec.tool)
            XCTAssertEqual(catalogSpec.domains, adapterSpec.domains, "\(tool.rawValue) domains")
            XCTAssertEqual(catalogSpec.requiredNames, adapterSpec.requiredNames, "\(tool.rawValue) requiredNames")
            XCTAssertEqual(
                catalogSpec.credentialNames,
                adapterSpec.credentialNames,
                "\(tool.rawValue) credentialNames"
            )
            XCTAssertEqual(
                catalogSpec.supportsSystemBrowserImport,
                adapterSpec.supportsSystemBrowserImport,
                "\(tool.rawValue) browser-import capability"
            )
        }
    }

    func testOnlyKimiRequiresProviderSpecificWebLogin() {
        for spec in MiscCookieSpecCatalog.allSpecs {
            XCTAssertEqual(
                spec.supportsSystemBrowserImport,
                spec.tool != .kimi,
                "\(spec.tool.rawValue) browser-import capability"
            )
        }
    }

    func testKimiBrowserImportIsRejectedBeforeBrowserOrKeychainAccess() {
        XCTAssertNil(MiscCookieResolver.appendBrowserImport(for: KimiQuotaAdapter.cookieSpec))
        let outcomes = MiscCookieResolver.appendBrowserImports(for: [
            .init(spec: KimiQuotaAdapter.cookieSpec, instanceID: "kimi")
        ])
        XCTAssertEqual(outcomes.map(\.result), [.browserImportUnsupported])
    }

    func testNonCookieProvidersHaveNoSpec() {
        for tool in nonCookieMiscProviders {
            XCTAssertNil(MiscCookieSpecCatalog.spec(for: tool), tool.rawValue)
            XCTAssertFalse(MiscCookieSpecCatalog.isCookieSourced(tool), tool.rawValue)
        }
        // Primary / partial-primary families carry their own credential
        // paths and must not appear in the misc cookie catalog.
        for tool in [ToolType.codex, .claude, .gemini, .grok] {
            XCTAssertNil(MiscCookieSpecCatalog.spec(for: tool), tool.rawValue)
        }
    }
}
