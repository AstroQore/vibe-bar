import CoreText
import XCTest
@testable import VibeBarCore

/// The e-ink preview is only worth drawing if it measures the same glyphs the
/// Dot. panel does, so these tests guard the three things that can silently
/// break that: the files falling out of the resource bundle, CoreText refusing
/// them, and a font swap that moves the advances.
final class EInkFontsTests: XCTestCase {
    func testEveryRoleHasABundledResource() throws {
        for role in EInkFonts.Role.allCases {
            let url = try XCTUnwrap(
                EInkFonts.resourceURL(for: role),
                "no bundled font file for \(role.rawValue)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let size = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
            ).intValue
            XCTAssertGreaterThan(size, 0)
        }
    }

    func testTheLatinSubsetsStaySmall() throws {
        // The whole point of subsetting ChillDuanSans is that the app does not
        // grow by 15 MB for a Latin-only preview face.
        for role in [EInkFonts.Role.sans, .sansBold] {
            let url = try XCTUnwrap(EInkFonts.resourceURL(for: role))
            let size = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
            ).intValue
            XCTAssertLessThan(size, 256 * 1024, "\(role.rawValue) subset grew unexpectedly")
        }
    }

    func testRegistrationSucceedsAndIsIdempotent() {
        XCTAssertTrue(EInkFonts.register())
        XCTAssertTrue(EInkFonts.register())
    }

    func testEveryRoleResolvesByItsPostScriptName() {
        EInkFonts.register()
        for role in EInkFonts.Role.allCases {
            let expected = EInkFonts.postScriptName(for: role)
            let font = CTFontCreateWithName(expected as CFString, 12, nil)
            XCTAssertEqual(
                CTFontCopyPostScriptName(font) as String,
                expected,
                "CoreText did not resolve \(expected) — the bundled file was renamed or not registered"
            )
        }
    }

    func testFontHelperReturnsTheRequestedFaceAndSize() {
        let pixel = EInkFonts.font(.pixel, size: EInkFonts.pixelPointSize)
        XCTAssertEqual(CTFontCopyPostScriptName(pixel) as String, EInkFonts.pixelPostScriptName)
        XCTAssertEqual(CTFontGetSize(pixel), EInkFonts.pixelPointSize, accuracy: 0.001)

        let bold = EInkFonts.font(.sansBold, size: 16)
        XCTAssertEqual(CTFontCopyPostScriptName(bold) as String, EInkFonts.sansBoldPostScriptName)
        XCTAssertEqual(CTFontGetSize(bold), 16, accuracy: 0.001)
    }

    /// The number the Studio's overflow warnings will be built on.
    ///
    /// `"AntiGravity"` is 62 pt wide at 12 pt in Fusion Pixel 12px
    /// proportional, and a device render of the same string in the Dot.'s
    /// unsuffixed `text-pixel-12` class measured the same 62 px. The exact
    /// equality is the contract; the range keeps the failure message useful if
    /// the face is ever swapped.
    func testPixelAdvanceWidthOfAntiGravity() {
        let width = EInkFonts.advanceWidth(of: "AntiGravity", role: .pixel)
        XCTAssertGreaterThanOrEqual(width, 44)
        XCTAssertLessThanOrEqual(width, 88)
        XCTAssertEqual(width, 62, accuracy: 0.001)
        // 296 px is the panel's long edge: the label has to leave room for a value.
        XCTAssertLessThan(width, 296 / 2)
    }

    func testPixelFaceIsCJKCapableAndFullWidthForHan() {
        // 12 px per Han glyph is what the box-tree layout budgets for.
        XCTAssertEqual(EInkFonts.advanceWidth(of: "像素", role: .pixel), 24, accuracy: 0.001)
        XCTAssertEqual(EInkFonts.advanceWidth(of: "缝合怪", role: .pixel), 36, accuracy: 0.001)
    }

    func testSansSubsetsCoverTheCharactersThePresetsUse() {
        // Every glyph the quota/usage presets can emit must have a real
        // advance; a missing one measures 0 and would silently under-report.
        let sample = "AntiGravity · Weekly 82% 5d 23h · Claude Code $6,272 316M tokens"
        for role in [EInkFonts.Role.sans, .sansBold] {
            let width = EInkFonts.advanceWidth(of: sample, role: role, size: 14)
            XCTAssertGreaterThan(width, CGFloat(sample.count) * 3)
            for scalar in Set(sample) where !scalar.isWhitespace {
                // Asked of the face itself, not of the measurement: since
                // `advanceWidth` shapes a line, a missing glyph would be
                // substituted and still measure > 0.
                XCTAssertTrue(
                    EInkFonts.coversEveryCharacter(of: String(scalar), role: role),
                    "\(role.rawValue) has no glyph for \(scalar)"
                )
            }
        }
    }

    /// The Latin-only sans subsets have no Han glyphs. Summing raw glyph
    /// advances mapped every one of them to glyph 0 and returned ~0, which
    /// would make an all-Chinese label look like it fit any box and silently
    /// suppress the Studio's overflow warning. Shaping a `CTLine` lets
    /// CoreText substitute the system font — the same thing the preview
    /// renderer draws — so the width is real.
    func testCJKInTheLatinOnlySansMeasuresThroughTheFontCascade() {
        for role in [EInkFonts.Role.sans, .sansBold] {
            XCTAssertFalse(EInkFonts.coversEveryCharacter(of: "缝合怪", role: role))
            let width = EInkFonts.advanceWidth(of: "缝合怪", role: role, size: 16)
            XCTAssertGreaterThan(width, 16, "\(role.rawValue) measured CJK as if it were empty")
            let mixed = EInkFonts.advanceWidth(of: "Claude 缝合怪", role: role, size: 16)
            XCTAssertGreaterThan(
                mixed,
                EInkFonts.advanceWidth(of: "Claude ", role: role, size: 16)
            )
        }
    }

    /// ChillDuanSans's bold weight tracks the regular's advances closely, and
    /// not always upward — "Claude Code" is very slightly *narrower* in bold
    /// while "AntiGravity" is ~5% wider. So the Studio cannot assume "bold is
    /// wider"; it has to measure the weight it is actually drawing. The bound
    /// here is the margin an overflow check can rely on.
    func testBoldTracksRegularWidthWithinAKnownMargin() {
        for sample in ["Claude Code", "AntiGravity", "$6,272", "316M tokens"] {
            let regular = EInkFonts.advanceWidth(of: sample, role: .sans, size: 16)
            let bold = EInkFonts.advanceWidth(of: sample, role: .sansBold, size: 16)
            XCTAssertGreaterThan(regular, 0)
            XCTAssertEqual(bold / regular, 1, accuracy: 0.08, "bold moved \(sample) by more than 8%")
        }
    }

    func testAdvanceWidthScalesLinearlyWithSize() {
        let at12 = EInkFonts.advanceWidth(of: "316M tokens", role: .sans, size: 12)
        let at24 = EInkFonts.advanceWidth(of: "316M tokens", role: .sans, size: 24)
        XCTAssertEqual(at24, at12 * 2, accuracy: 0.01)
    }

    func testEmptyStringMeasuresZero() {
        XCTAssertEqual(EInkFonts.advanceWidth(of: "", role: .pixel), 0)
    }

    func testTheSansSubsetsDoNotCarryTheUpstreamReservedFontName() throws {
        // The OFL reserves "Duan" for the upstream project and a subset is a
        // Modified Version, so the shipped names must not contain it.
        for role in [EInkFonts.Role.sans, .sansBold] {
            XCTAssertFalse(EInkFonts.postScriptName(for: role).contains("Duan"))
            let url = try XCTUnwrap(EInkFonts.resourceURL(for: role))
            let descriptors = try XCTUnwrap(
                CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
            )
            for descriptor in descriptors {
                let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
                XCTAssertFalse(family?.contains("Duan") ?? false)
            }
        }
    }
}
