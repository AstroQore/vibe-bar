import Foundation

/// How a quota slot spells itself: in words, or with the provider's mark
/// standing in for the words that name it.
///
/// The owner's panel carries names like "ChatGPT Agentic · GPT-5.3 Codex
/// Spark · Weekly", and the first tier of that is the one a reader already
/// knows by its logo — the menu bar has been identifying the same providers
/// with the same 1-bit marks all along. Swapping the SubProvider for its mark
/// buys back 60–100 px of a 284 px row, which is the difference between a
/// two-line slot and a one-line one.
public enum EInkSlotLabelStyle: String, Codable, CaseIterable, Hashable, Sendable {
    /// The whole name, in words. What every slide drew before.
    case text
    /// The mark, then the group and the window: "GPT-5.3 Codex Spark · Weekly".
    case logoAndGroup
    /// The mark, then the window alone: "Weekly".
    case logoAndWindow
    /// The mark and nothing else.
    case logoOnly

    public var drawsLogo: Bool { self != .text }

    /// English, like every other string the panel itself draws.
    public var identifierName: String {
        switch self {
        case .text: "Full Name"
        case .logoAndGroup: "Logo and Group"
        case .logoAndWindow: "Logo and Window"
        case .logoOnly: "Logo Only"
        }
    }

    /// Which part of the name survives beside the mark.
    ///
    /// `nil` means nothing does. Every style maps onto a part rather than a
    /// string so an exploded element still follows its bucket — the mark is an
    /// image and the words beside it are still a binding.
    public var part: EInkSlotLabelPart? {
        switch self {
        case .text: .whole
        case .logoAndGroup: .window
        case .logoAndWindow: .period
        case .logoOnly: nil
        }
    }

    /// What this style prints for one row, beside the mark.
    public func text(of row: EInkQuotaRow) -> String {
        part.map { $0.text(of: row) } ?? ""
    }
}

// MARK: - The mark itself

/// Where a provider's 1-bit mark comes from.
///
/// Core cannot read the app's SVGs — `VibeBarCore` has no AppKit asset
/// catalogue and no business knowing where the art lives — so the App
/// rasterizes `ProviderBrandIcon`'s mark and hands the bytes over, exactly
/// like the quota and forecast closures the assembler already takes. Anything
/// the provider has no mark for falls back to a monogram drawn here, so a
/// slide set to a logo style never draws a blank where a name used to be.
public protocol EInkLogoProviding: Sendable {
    /// A `data:image/png;base64,…` for this tool's mark at `size` device
    /// pixels, 1-bit and already thresholded. `nil` when there is no mark.
    func logoDataURI(tool: ToolType, size: Int) -> String?
}

public enum EInkLogo {
    /// The two sizes the layouts draw: a row's mark and a cell's.
    public static let rowSize = 14
    public static let cellSize = 16
    public static let sizes = [rowSize, cellSize]

    /// How a snapshot files one mark.
    public static func key(fieldID: String, size: Int) -> String { "\(fieldID)@\(size)" }

    /// The mark for one slot, or the monogram that stands in for it.
    public static func dataURI(
        fieldID: String,
        subProvider: String,
        size: Int,
        provider: (any EInkLogoProviding)?
    ) -> String? {
        if let tool = EInkDataAssembler.selector(fieldID: fieldID)?.tool,
           let uri = provider?.logoDataURI(tool: tool, size: size)
        {
            return uri
        }
        return try? EInkMonogramRasterizer.dataURI(initials: monogram(for: subProvider), size: size)
    }

    /// Two letters for a provider with no art: the initials of its first two
    /// words, else its first two letters. "ChatGPT Agentic" is "CA",
    /// "Claude" is "CL".
    public static func monogram(for name: String) -> String {
        let words = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
        guard let first = words.first else { return "??" }
        return String(first.prefix(2)).uppercased()
    }
}
