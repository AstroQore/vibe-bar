import Foundation

/// User-facing copy of a misc provider.
///
/// The default instance keeps `id == tool.rawValue`, which preserves
/// existing settings and Keychain account names. Cloned instances get
/// their own stable id, account id, quota cache, and Keychain slots.
public struct MiscProviderInstance: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var tool: ToolType
    public var settings: MiscProviderSettings
    public var isVisible: Bool
    public var displayName: String?

    public init(
        id: String,
        tool: ToolType,
        settings: MiscProviderSettings = .default,
        isVisible: Bool = true,
        displayName: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.settings = settings.automaticSourceSelection
        self.isVisible = isVisible
        self.displayName = Self.normalizedDisplayName(displayName)
    }

    public static func defaultInstance(
        for tool: ToolType,
        settings: MiscProviderSettings = .default,
        isVisible: Bool = true,
        displayName: String? = nil
    ) -> MiscProviderInstance {
        MiscProviderInstance(
            id: tool.rawValue,
            tool: tool,
            settings: settings,
            isVisible: isVisible,
            displayName: displayName
        )
    }

    public var isDefault: Bool {
        id == tool.rawValue
    }

    public var title: String {
        tool.menuTitle
    }

    public func displayTitle(fallback: String) -> String {
        displayName ?? fallback
    }

    public static func normalizedDisplayName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
