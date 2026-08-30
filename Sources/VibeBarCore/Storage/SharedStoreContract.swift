import Foundation

/// The versioning and ownership vocabulary every Vibe Bar client must share
/// before it writes under the common data root.
///
/// This is deliberately metadata only: it has no user-home paths, account
/// identifiers, or credentials. `exportFixtureJSON()` is therefore safe to
/// commit as a Swift/Rust conformance fixture.
public enum SharedStoreDurability: String, Codable, CaseIterable, Sendable {
  /// User intent or history that cannot be reconstructed without loss.
  case durable
  /// Rebuildable only from another authoritative local source.
  case reconstructible
  /// Runtime-only state which is valid solely while its owner runs.
  case ephemeral
}

public enum SharedStoreSchemaKind: String, Codable, CaseIterable, Sendable {
  case jsonUnversioned = "json_unversioned"
  case jsonSchemaVersion = "json_schema_version"
  case sqliteUserVersion = "sqlite_user_version"
  case sqliteMetadataVersion = "sqlite_metadata_version"
  case keychainEnvelope = "keychain_envelope"
  case unixSocket = "unix_socket"
  case directory
}

public enum SharedStoreLocatorKind: String, Codable, CaseIterable, Sendable {
  case filesystemRelative = "filesystem_relative"
  case keychainItem = "keychain_item"
  case endpoint
}

/// Describes the native implementation today, rather than promising that a
/// future cross-client writer may safely use the store already.
public enum SharedStoreImplementationStatus: String, Codable, CaseIterable, Sendable {
  case legacyUnsafe = "legacy_unsafe"
  case nativeOnlyCredentialEndpoint = "native_only_credential_endpoint"
  case endpointOwned = "endpoint_owned"
}

public enum SharedStoreShareEligibility: String, Codable, CaseIterable, Sendable {
  /// The current files are not yet writable through this contract.
  case notEligible = "not_eligible"
  /// Existing mismatch/recovery behavior is destructive or otherwise unsafe.
  case legacyUnsafe = "legacy_unsafe"
  /// A non-filesystem endpoint with a separately specified owner protocol.
  case endpointOnly = "endpoint_only"
}

/// A client which cannot prove that it understands a store must not mutate it.
/// There intentionally is no reset, delete, or rebuild case here.
public enum SharedStoreUnknownVersionPolicy: String, Codable, CaseIterable, Sendable {
  case failClosed = "fail_closed"
}

/// Recovery is an explicit future operation under the migrator lease. The
/// policy describes what a UI may offer after a backup/marker exists; it never
/// authorizes an opportunistic write while opening an unknown store.
public enum SharedStoreRecoveryPolicy: String, Codable, CaseIterable, Sendable {
  case requireExplicitMigration = "require_explicit_migration"
  case rebuildFromAuthoritativeSource = "rebuild_from_authoritative_source"
  case recreateEphemeralOwnerState = "recreate_ephemeral_owner_state"
}

/// Required shutdown behavior once a store is wired to the lease protocol.
public enum SharedStoreFlushPolicy: String, Codable, CaseIterable, Sendable {
  case immediate = "immediate"
  case flushOnShutdown = "flush_on_shutdown"
  case checkpointWalOnShutdown = "checkpoint_wal_on_shutdown"
  case removeOnOwnerShutdown = "remove_on_owner_shutdown"
}

/// Locks are role-scoped so independent collectors can progress while an
/// exclusive migration still fences every writer that could reinterpret data.
/// Raw values are part of the cross-language on-disk protocol.
public enum SharedStoreLeaseRole: String, Codable, CaseIterable, Sendable {
  case settingsEditor = "settings_editor"
  case quotaCollector = "quota_collector"
  case statusCollector = "status_collector"
  case usageScanner = "usage_scanner"
  case pricingRefresher = "pricing_refresher"
  case sessionIndexer = "session_indexer"
  case layoutEditor = "layout_editor"
  case miniWindowManager = "mini_window_manager"
  case credentialManager = "credential_manager"
  case migrator
  case pruner
  case skillsManager = "skills_manager"
  case remoteSync = "remote_sync"
  case mcpOwner = "mcp_owner"
}

public enum SharedStoreID: String, Codable, CaseIterable, Sendable {
  case settings
  case quotaCache = "quota_cache"
  case quotaFieldRegistry = "quota_field_registry"
  case serviceStatus = "service_status"
  case scanCache = "scan_cache"
  case costSnapshots = "cost_snapshots"
  case costHistory = "cost_history"
  case subscriptionHistory = "subscription_history"
  case fillTimeline = "fill_timeline"
  case forecastTimeline = "forecast_timeline"
  case usageEvents = "usage_events"
  case sessionIndex = "session_index"
  case sessionIndexMaintenance = "session_index_maintenance"
  case sessionIndexScratch = "session_index_scratch"
  case pageLayout = "page_layout"
  case miniWindowGeometry = "mini_window_geometry"
  case antigravityModelLabels = "antigravity_model_labels"
  case geminiWebUsageRecipe = "gemini_web_usage_recipe"
  case pricingCache = "pricing_cache"
  case pricingSources = "pricing_sources"
  case pricingRefreshStatus = "pricing_refresh_status"
  case skillsRegistry = "skills_registry"
  case skillBackups = "skill_backups"
  case remoteCoreConfig = "remote_core_config"
  case remoteUsage = "remote_usage"
  case credentialVault = "credential_vault"
  case mcpSocket = "mcp_socket"
}

public struct SharedStoreContract: Codable, Equatable, Sendable {
  public let storeID: SharedStoreID
  public let locatorKind: SharedStoreLocatorKind
  /// Relative only; fixture consumers must resolve this below their own data root.
  public let relativeLocator: String
  public let keychainService: String?
  public let keychainAccount: String?
  public let endpointProtocol: String?
  /// The endpoint's wire-level protocol revision. This is a string because
  /// MCP revisions are dates such as `2025-06-18`, not integer schema numbers.
  public let endpointVersion: String?
  /// Filename/member shape below `relativeLocator`, when it is a directory.
  public let memberPattern: String?
  public let keyEncoding: String?
  public let sidecars: [String]
  public let durability: SharedStoreDurability
  public let schemaKind: SharedStoreSchemaKind
  /// `nil` means the existing representation has no explicit schema marker.
  /// It does *not* mean a client may guess its shape.
  public let currentSchemaVersion: Int?
  public let writerRoles: [SharedStoreLeaseRole]
  public let unknownVersionPolicy: SharedStoreUnknownVersionPolicy
  public let recoveryPolicy: SharedStoreRecoveryPolicy
  public let flushPolicy: SharedStoreFlushPolicy
  public let shareEligibility: SharedStoreShareEligibility
  public let implementationStatus: SharedStoreImplementationStatus

  public init(
    storeID: SharedStoreID,
    locatorKind: SharedStoreLocatorKind = .filesystemRelative,
    relativeLocator: String,
    keychainService: String? = nil,
    keychainAccount: String? = nil,
    endpointProtocol: String? = nil,
    endpointVersion: String? = nil,
    memberPattern: String? = nil,
    keyEncoding: String? = nil,
    sidecars: [String] = [],
    durability: SharedStoreDurability,
    schemaKind: SharedStoreSchemaKind,
    currentSchemaVersion: Int?,
    writerRoles: [SharedStoreLeaseRole],
    unknownVersionPolicy: SharedStoreUnknownVersionPolicy = .failClosed,
    recoveryPolicy: SharedStoreRecoveryPolicy,
    flushPolicy: SharedStoreFlushPolicy,
    shareEligibility: SharedStoreShareEligibility,
    implementationStatus: SharedStoreImplementationStatus
  ) {
    self.storeID = storeID
    self.locatorKind = locatorKind
    self.relativeLocator = relativeLocator
    self.keychainService = keychainService
    self.keychainAccount = keychainAccount
    self.endpointProtocol = endpointProtocol
    self.endpointVersion = endpointVersion
    self.memberPattern = memberPattern
    self.keyEncoding = keyEncoding
    self.sidecars = sidecars
    self.durability = durability
    self.schemaKind = schemaKind
    self.currentSchemaVersion = currentSchemaVersion
    self.writerRoles = writerRoles
    self.unknownVersionPolicy = unknownVersionPolicy
    self.recoveryPolicy = recoveryPolicy
    self.flushPolicy = flushPolicy
    self.shareEligibility = shareEligibility
    self.implementationStatus = implementationStatus
  }
}

/// Canonical, path-free storage manifest. A client may use the registry to
/// decide whether it can open a store, but only a successful role lease may
/// authorize a mutation. Until existing stores are retrofitted, this registry
/// is intentionally descriptive and does not change their write paths.
public enum SharedStoreContractRegistry {
  public static let protocolVersion = 1

  public static let all: [SharedStoreContract] = [
    contract(
      .settings, "settings.json", .durable, .jsonUnversioned, nil, [.settingsEditor, .migrator],
      .requireExplicitMigration, .flushOnShutdown),
    contract(
      .quotaCache, "quotas", member: "quota-v1-<sha256(accountId)>.json", key: "sha256-v1",
      .reconstructible, .jsonUnversioned, nil, [.quotaCollector, .migrator],
      .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .quotaFieldRegistry, "quota_field_registry.json", .durable, .jsonUnversioned, nil,
      [.quotaCollector, .pruner, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .serviceStatus, "service_status.json", .reconstructible, .jsonUnversioned, nil,
      [.statusCollector, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .scanCache, "scan_cache", member: "<tool>.json", .reconstructible, .jsonSchemaVersion, 7,
      [.usageScanner, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .costSnapshots, "cost_snapshots", member: "<tool>.json", .reconstructible, .jsonUnversioned,
      nil, [.usageScanner, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .costHistory, "cost_history.json", .durable, .jsonSchemaVersion, 2,
      [.usageScanner, .pruner, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .subscriptionHistory, "subscription_history.json", .durable, .jsonSchemaVersion, 2,
      [.quotaCollector, .pruner, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .fillTimeline, "fill_timeline.sqlite3", sidecars: ["-wal", "-shm"], .durable,
      .sqliteUserVersion, 1, [.quotaCollector, .pruner, .migrator], .requireExplicitMigration,
      .checkpointWalOnShutdown),
    contract(
      .forecastTimeline, "forecast_timeline.sqlite3", sidecars: ["-wal", "-shm"], .durable,
      .sqliteUserVersion, 1, [.quotaCollector, .pruner, .migrator], .requireExplicitMigration,
      .checkpointWalOnShutdown),
    contract(
      .usageEvents, "usage_events.sqlite3", sidecars: ["-wal", "-shm"], .durable,
      .sqliteMetadataVersion, 4, [.usageScanner, .pruner, .migrator], .requireExplicitMigration,
      .checkpointWalOnShutdown),
    // Session-index schema is owned by agent-session-kit. This host may
    // compact only the version it understands; a future version remains
    // unavailable until the kit's explicit migrator accepts it.
    contract(
      .sessionIndex, "session_index.sqlite3", sidecars: ["-wal", "-shm"], .reconstructible,
      .sqliteUserVersion, 5, [.sessionIndexer, .pruner, .migrator], .rebuildFromAuthoritativeSource,
      .checkpointWalOnShutdown),
    contract(
      .sessionIndexMaintenance, "session_index_maintenance.json", .reconstructible,
      .jsonSchemaVersion, 1, [.pruner, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown
    ),
    contract(
      .sessionIndexScratch, "session_index_scratch", .ephemeral, .directory, nil,
      [.sessionIndexer, .pruner], .recreateEphemeralOwnerState, .removeOnOwnerShutdown),
    contract(
      .pageLayout, "layout.json", .durable, .jsonSchemaVersion, 1, [.layoutEditor, .migrator],
      .requireExplicitMigration, .flushOnShutdown),
    contract(
      .miniWindowGeometry, "mini_window_geometry.json", .durable, .jsonUnversioned, nil,
      [.miniWindowManager, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .antigravityModelLabels, "antigravity_model_labels.json", .reconstructible, .jsonUnversioned,
      nil, [.quotaCollector, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .geminiWebUsageRecipe, "gemini_web_usage_recipe.json", .reconstructible, .jsonUnversioned,
      nil, [.quotaCollector, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .pricingCache, "pricing_cache.json", .reconstructible, .jsonSchemaVersion, 1,
      [.pricingRefresher, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .pricingSources, "pricing_sources", member: "<source>.json", .reconstructible,
      .jsonSchemaVersion, 1, [.pricingRefresher, .migrator], .rebuildFromAuthoritativeSource,
      .flushOnShutdown),
    contract(
      .pricingRefreshStatus, "pricing_refresh_status.json", .reconstructible, .jsonUnversioned, nil,
      [.pricingRefresher, .migrator], .rebuildFromAuthoritativeSource, .flushOnShutdown),
    contract(
      .skillsRegistry, "skills.json", .durable, .jsonSchemaVersion, 1, [.skillsManager, .migrator],
      .requireExplicitMigration, .flushOnShutdown),
    contract(
      .skillBackups, "skill_backups", .durable, .directory, nil,
      [.skillsManager, .pruner, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .remoteCoreConfig, "remote_core.json", .durable, .jsonSchemaVersion, 1,
      [.remoteSync, .migrator], .requireExplicitMigration, .flushOnShutdown),
    contract(
      .remoteUsage, "remote_usage.sqlite3", sidecars: ["-wal", "-shm"], .durable,
      .sqliteMetadataVersion, nil, [.remoteSync, .migrator], .requireExplicitMigration,
      .checkpointWalOnShutdown),
    contract(
      .credentialVault, "", .durable, .keychainEnvelope, 1, [.credentialManager],
      .requireExplicitMigration, .flushOnShutdown, locatorKind: .keychainItem,
      keychainService: "com.astroqore.VibeBar.credential-vault", keychainAccount: "vault-v1",
      eligibility: .endpointOnly, status: .nativeOnlyCredentialEndpoint),
    contract(
      .mcpSocket, "mcp.sock", .ephemeral, .unixSocket, nil, [.mcpOwner],
      .recreateEphemeralOwnerState,
      .removeOnOwnerShutdown, locatorKind: .endpoint, endpointProtocol: "mcp-jsonrpc",
      endpointVersion: MCPServer.protocolVersion, eligibility: .endpointOnly,
      status: .endpointOwned),
  ]

  public static func contract(for storeID: SharedStoreID) -> SharedStoreContract {
    // The table is static and tests assert total coverage, making this
    // force unwrap a programming error rather than input handling.
    all.first(where: { $0.storeID == storeID })!
  }

  /// Stable fixture format shared with Rust: UTF-8 JSON, sorted object keys,
  /// no paths, and raw-value enums. Array order is `SharedStoreID` order.
  public static func exportFixtureJSON() throws -> Data {
    struct Fixture: Codable {
      let protocolVersion: Int
      let stores: [SharedStoreContract]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Fixture(protocolVersion: protocolVersion, stores: all))
  }

  private static func contract(
    _ storeID: SharedStoreID,
    _ locator: String,
    member: String? = nil,
    key: String? = nil,
    sidecars: [String] = [],
    _ durability: SharedStoreDurability,
    _ schemaKind: SharedStoreSchemaKind,
    _ version: Int?,
    _ roles: [SharedStoreLeaseRole],
    _ recovery: SharedStoreRecoveryPolicy,
    _ flush: SharedStoreFlushPolicy,
    locatorKind: SharedStoreLocatorKind = .filesystemRelative,
    keychainService: String? = nil,
    keychainAccount: String? = nil,
    endpointProtocol: String? = nil,
    endpointVersion: String? = nil,
    eligibility: SharedStoreShareEligibility = .legacyUnsafe,
    status: SharedStoreImplementationStatus = .legacyUnsafe
  ) -> SharedStoreContract {
    SharedStoreContract(
      storeID: storeID,
      locatorKind: locatorKind,
      relativeLocator: locator,
      keychainService: keychainService,
      keychainAccount: keychainAccount,
      endpointProtocol: endpointProtocol,
      endpointVersion: endpointVersion,
      memberPattern: member,
      keyEncoding: key,
      sidecars: sidecars,
      durability: durability,
      schemaKind: schemaKind,
      currentSchemaVersion: version,
      writerRoles: roles,
      recoveryPolicy: recovery,
      flushPolicy: flush,
      shareEligibility: eligibility,
      implementationStatus: status
    )
  }
}
