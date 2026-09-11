import CoreText
import Foundation

/// The two typefaces the e-ink preview draws with, and the one place that
/// teaches CoreText about them.
///
/// ## Why these two files
///
/// A Dot. Quote/0 renders Canvas text with its own built-in fonts; Vibe Bar
/// only ever gets a 296×152 1-bit PNG back. For the in-app preview (and the
/// Studio's "this text will overflow" warnings) to mean anything, the Mac has
/// to measure and draw the *same* glyphs the device does.
///
/// - `text-pixel-12` on the device was identified, by pixel-for-pixel
///   comparison of a device render against local renders of every candidate,
///   as **Fusion Pixel 12px, proportional, `zh_hans` variant**
///   (<https://github.com/TakWolf/fusion-pixel-font>, OFL 1.1). Four sample
///   strings — Latin, digits + currency, and CJK — matched with **zero**
///   differing pixels, and `"AntiGravity"` advances 62 pt at 12 pt in both.
/// - The device's other pixel class, `text-pixel-12-zpix`, is zpix. zpix is
///   **not** redistributable with a commercial product, so it is deliberately
///   absent here; Fusion Pixel is the OFL stand-in, and the presets should
///   prefer the unsuffixed `text-pixel-12` class so preview and device agree
///   exactly.
/// - `text-[Npx]-chillduansans` is 寒蝉端黑体 (ChillDuanSans, OFL 1.1).
///   ``sansRegularPostScriptName`` / ``sansBoldPostScriptName`` are Latin-only
///   subsets of it. The OFL reserves the font name "Duan" for the upstream
///   project, and a subset is a Modified Version, so the subsets carry a
///   neutral family name. Text with CJK in it falls back to the system font in
///   the preview; the device still draws it in the real typeface.
///
/// ## Why the pinned Fusion Pixel revision
///
/// The bundled file is release **2025.08.24**, not the newest upstream tag.
/// Fusion Pixel redrew `1` and `y` after 2025.08.24, and the device's firmware
/// (2.0.8, tested 2026-09) still carries the older shapes — bundling the newest
/// release would put a visible 1–3 px lie in the preview. Re-run the device
/// comparison before moving this pin, and update
/// ``pixelPostScriptName`` with it: upstream also renamed the PostScript name
/// from `…-12px-P-…` to `…-12px-Prop-…` in a later release.
public enum EInkFonts {
    /// Which of the bundled faces a caller wants.
    public enum Role: String, Sendable, CaseIterable {
        /// The 12 px bitmap face that matches the device's `text-pixel-12`.
        case pixel
        /// Latin-only ChillDuanSans subset, regular weight.
        case sans
        /// Latin-only ChillDuanSans subset, bold weight.
        case sansBold
    }

    // MARK: - PostScript names

    public static let pixelPostScriptName = "Fusion-Pixel-12px-P-zh_hans-Regular"
    public static let sansRegularPostScriptName = "VibeBarPaperSans-Regular"
    public static let sansBoldPostScriptName = "VibeBarPaperSans-Bold"

    // MARK: - Sizes

    /// The pixel face is a bitmap design on a 12 px em: any other size is
    /// interpolation, so presets and the Studio only ever offer this one.
    public static let pixelPointSize: CGFloat = 12

    /// The sizes the Studio offers for the sans face. Kept integral because
    /// the e-ink panel has no subpixels to hide a fractional advance in.
    public static let sansPointSizes: [CGFloat] = [13, 14, 16, 18, 24, 32]

    /// Upstream release of the bundled pixel face — see the type's note on why
    /// it is pinned rather than tracking the newest tag.
    public static let pixelFontRelease = "2025.08.24"

    // MARK: - Resources

    /// Base name (no extension) of the file backing each role.
    public static func resourceName(for role: Role) -> String {
        switch role {
        case .pixel: "FusionPixel-12px-Proportional-zh_hans"
        case .sans: "VibeBarPaperSans-Regular"
        case .sansBold: "VibeBarPaperSans-Bold"
        }
    }

    /// PostScript name CoreText resolves each role by, once ``register()`` has run.
    public static func postScriptName(for role: Role) -> String {
        switch role {
        case .pixel: pixelPostScriptName
        case .sans: sansRegularPostScriptName
        case .sansBold: sansBoldPostScriptName
        }
    }

    /// Location of the bundled font file, or `nil` if the resource bundle is
    /// missing (a broken `.app`, never a normal run).
    public static func resourceURL(for role: Role) -> URL? {
        bundledFontURL(named: resourceName(for: role))
    }

    // MARK: - Registration

    /// Registers both bundled faces with CoreText for this process.
    ///
    /// Idempotent and safe to call from anywhere: the work happens once, in a
    /// `static let` initializer, and every later call returns the same answer.
    /// Registration is `.process` scope — nothing is installed for the user or
    /// left behind after the app quits.
    @discardableResult
    public static func register() -> Bool {
        registrationResult
    }

    private static let registrationResult: Bool = {
        var allRegistered = true
        for role in Role.allCases {
            guard let url = resourceURL(for: role) else {
                allRegistered = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // A font already registered by an earlier process-scope call
                // (or by a second copy of the bundle) reports failure with
                // `kCTFontManagerErrorAlreadyRegistered`. That is a success
                // for our purposes: the name resolves either way.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    allRegistered = false
                }
            }
        }
        return allRegistered
    }()

    // MARK: - Fonts and metrics

    /// A `CTFont` for the given role, registering the bundled files on first use.
    ///
    /// Falls back to the system font at the same size if the bundle is missing,
    /// so a damaged install degrades to "the preview looks wrong" rather than
    /// a crash.
    public static func font(_ role: Role, size: CGFloat) -> CTFont {
        register()
        let name = postScriptName(for: role) as CFString
        let font = CTFontCreateWithName(name, size, nil)
        guard (CTFontCopyPostScriptName(font) as String) == postScriptName(for: role) else {
            return CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        return font
    }

    /// Total horizontal advance of `string` in points.
    ///
    /// This is the measurement the Studio's overflow warnings are built on: a
    /// text box on a 296 px panel either fits or it does not, and the device
    /// will not reflow it.
    ///
    /// It measures a **shaped** `CTLine`, not raw per-glyph advances, for two
    /// reasons. The Latin-only sans subsets have no Han glyphs, and summing
    /// raw advances would map every one of them to glyph 0 and add 0 — so an
    /// all-Chinese label would measure near zero and silently *suppress* the
    /// overflow warning it should raise. Shaping instead lets CoreText's
    /// cascade substitute the system font, which is exactly what the preview
    /// renderer draws. Shaping also applies kerning and ligatures, which raw
    /// advances skip.
    ///
    /// Use ``coversEveryCharacter(of:role:)`` when the question is "is this
    /// the device's own typeface?" rather than "how wide is it here?".
    public static func advanceWidth(
        of string: String,
        role: Role,
        size: CGFloat = pixelPointSize
    ) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributed = NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(role, size: size)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Whether `role`'s own face carries a glyph for every character of
    /// `string`, i.e. whether ``advanceWidth(of:role:size:)`` measured it
    /// without falling back to a substituted font.
    ///
    /// The Latin-only sans subsets answer `false` for any CJK text: the device
    /// still draws it in the real ChillDuanSans, but the local preview cannot.
    public static func coversEveryCharacter(of string: String, role: Role) -> Bool {
        guard !string.isEmpty else { return true }
        let font = font(role, size: pixelPointSize)
        let characters = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }

    // MARK: - Bundle resolution

    /// SwiftPM's generated `Bundle.module` accessor only knows the absolute
    /// build directory and a bundle next to `Bundle.main.bundleURL`. Neither
    /// location survives installation into a signed `.app`, so
    /// `Scripts/build_app.sh` embeds the generated resource bundle in
    /// `Contents/Resources` and that copy is checked first — the same order
    /// `PricingResolver` uses.
    private static func bundledFontURL(named name: String) -> URL? {
        if let resourcesURL = Bundle.main.resourceURL {
            let embeddedBundleURL = resourcesURL
                .appendingPathComponent("VibeBar_VibeBarCore.bundle", isDirectory: true)
            if let embeddedBundle = Bundle(url: embeddedBundleURL),
               let url = fontURL(named: name, in: embeddedBundle)
            {
                return url
            }
        }
        return fontURL(named: name, in: .module)
    }

    /// SwiftPM's `.process` rule flattens some resource directories and keeps
    /// others, so ask for both spellings rather than depending on which.
    private static func fontURL(named name: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "otf", subdirectory: "Fonts")
            ?? bundle.url(forResource: name, withExtension: "otf")
    }
}
