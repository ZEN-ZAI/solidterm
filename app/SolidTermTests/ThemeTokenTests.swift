// Pin spec/design-tokens.md token values to code. If a token's value
// changes here without a corresponding spec update, this fails — forces
// spec ↔ implementation drift to surface in CI rather than at design-
// review time.
//
// The token vocabulary is documented in spec/design-tokens.md; the
// rationale for the values (warm-shifted Zenzai Dark base, Tokyo Night
// accent family, 8-point spacing grid, 150ms motion baseline) lives in
// decisions/13-visual-design-direction.md §Locks.

import XCTest
import simd

@testable import SolidTerm

final class ThemeTokenTests: XCTestCase {

    // MARK: Color tokens

    /// `bg-base` — `#1a1e1a` (user's zenzai). Stored linear so
    /// `.bgra8Unorm_srgb` framebuffer encode-on-store hands back
    /// `#1a1e1a` on screen.
    func testBgBaseMatchesSpec() {
        assertLinearMatchesHex(Theme.Color.bgBaseLinear, hex: 0x1c24_18ff)
    }

    /// `bg-elevated` — `#16161e` per spec/design-tokens.md §"Surface
    /// levels". Sidebar, command palette container, settings panel.
    func testBgElevatedMatchesSpec() {
        assertLinearMatchesHex(Theme.Color.bgElevatedLinear, hex: 0x1616_1eff)
    }

    /// `bg-overlay` — `#1a1b26` per spec/design-tokens.md §"Surface
    /// levels". Modal, dialog, permission prompt sheet.
    func testBgOverlayMatchesSpec() {
        assertLinearMatchesHex(Theme.Color.bgOverlayLinear, hex: 0x1a1b_26ff)
    }

    /// `bg-tint-subtle` — `#16161a` per spec/design-tokens.md §"Surface
    /// levels" ("`bg-base` + 4% lightness | Block hover; list-item
    /// rest"). M2-5b uses this as the AltScreenStub container
    /// background; M2-5c reuses it for the block hover state.
    func testBgTintSubtleMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.bgTintSubtleLinear, hex: 0x1616_1aff)
    }

    /// `bg-tint-active` — `#1f1e22` per spec/design-tokens.md §"Surface
    /// levels" ("`bg-base` + 8% lightness | Block focused; list-item
    /// selected"). M2-5c uses this as the keyboard-focus background
    /// on `BlockContainerView`. Concrete value derives from doubling
    /// `bg-tint-subtle`'s channel-shift over `bg-base` (+8% vs +4%
    /// lightness), staying inside the surface stack rather than
    /// crossing into the `bg-elevated` register.
    func testBgTintActiveMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.bgTintActiveLinear, hex: 0x1f1e_22ff)
    }

    /// `bg-tint-active` MUST sit above `bg-tint-subtle` in lightness
    /// per spec/design-tokens.md §"Surface levels" (+8% vs +4%). The
    /// visual distinction between hover (passive pointer-over) and
    /// focus (deliberate keyboard target) is load-bearing for the
    /// M2-5c interaction-state contract — if a future palette tweak
    /// quietly aliases the two tokens, hover and focus would collapse
    /// onto the same tint. Pin the inequality so the regression
    /// surfaces here, not at design-review time.
    func testBgTintActiveIsDistinctFromBgTintSubtle() {
        XCTAssertNotEqual(
            Theme.Color.bgTintActiveLinear,
            Theme.Color.bgTintSubtleLinear,
            "bg-tint-active (+8%) must read above bg-tint-subtle (+4%)")
        // Sanity: both must lift OFF `bg-base`, not collapse onto it.
        XCTAssertNotEqual(
            Theme.Color.bgTintActiveLinear,
            Theme.Color.bgBaseLinear,
            "bg-tint-active must read as a lift over bg-base")
    }

    /// `text-primary` — `#d4d8d0` (user's zenzai foreground).
    /// Aliases the engine's default-fg sentinel resolution.
    func testTextPrimaryMatchesSpec() {
        assertLinearMatchesHex(Theme.Color.textPrimaryLinear, hex: 0xc8d0_b8ff)
    }

    /// `text-secondary` — `#a9b1d6` per spec/design-tokens.md §"Text
    /// levels". Metadata, captions.
    func testTextSecondaryMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.textSecondaryLinear, hex: 0xa9b1_d6ff)
    }

    /// `accent-running` — `#7aa2f7` per spec/design-tokens.md §"Accents".
    func testAccentRunningMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.accentRunningLinear, hex: 0x7aa2_f7ff)
    }

    /// `accent-success` — `#9ece6a` per spec/design-tokens.md §"Accents".
    func testAccentSuccessMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.accentSuccessLinear, hex: 0x9ece_6aff)
    }

    /// `accent-error` — `#f7768e` per spec/design-tokens.md §"Accents".
    func testAccentErrorMatchesSpec() {
        assertLinearMatchesHex(Theme.Color.accentErrorLinear, hex: 0xf776_8eff)
    }

    /// `accent-warning` — `#e0af68` per spec/design-tokens.md §"Accents".
    func testAccentWarningMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.accentWarningLinear, hex: 0xe0af_68ff)
    }

    /// `accent-thinking` — `#bb9af7` per spec/design-tokens.md §"Accents".
    func testAccentThinkingMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.accentThinkingLinear, hex: 0xbb9a_f7ff)
    }

    /// `selection-bg` — `#2d4a2d` (user's zenzai selection).
    func testSelectionBgMatchesSpec() {
        assertLinearMatchesHex(
            Theme.Color.selectionBgLinear, hex: 0x2a34_24ff)
    }

    /// `cursor-default` ≡ `accent-running` per spec/design-tokens.md
    /// `cursor-default` — `#7dac7d` (user's zenzai cursor color).
    /// A desaturated green that contrasts against the zenzai bg
    /// `#1a1e1a` and stays visible on light-bg TUIs.
    func testCursorDefaultMatchesZenzai() {
        assertLinearMatchesHex(
            Theme.Color.cursorDefaultLinear, hex: 0xc491_9fff)
    }

    /// IME preedit underline aliases `text-primary` per
    /// `spec/swift-app-modules.md:200`. Users perceive preedit as
    /// "in-flight typing".
    func testImeUnderlineAliasesTextPrimary() {
        XCTAssertEqual(
            Theme.Color.imeUnderlineLinear,
            Theme.Color.textPrimaryLinear,
            "imeUnderline must alias text-primary so the preedit underline "
                + "reads as the same color the committed glyph will land in.")
    }

    /// M6-2 link underline aliases `accent-running` (`#7aa2f7`) so the
    /// `⌘+hover` underline reads as "clickable / interactive" — same
    /// hue users already learned means cursor-live and running-block.
    func testLinkUnderlineAliasesAccentRunning() {
        XCTAssertEqual(
            Theme.Color.linkUnderlineLinear,
            Theme.Color.accentRunningLinear,
            "linkUnderline must alias accent-running (#7aa2f7) so a "
                + "⌘+hovered file path reads as 'this is clickable'.")
    }

    /// Team palette — five reuse the accent palette per
    /// spec/design-tokens.md §"Team mode" rationale. Pinning the alias
    /// guards against a future drift where one of the team-* values
    /// gets a parallel hex literal that disagrees with its accent twin.
    func testTeamPaletteAliasesAccents() {
        XCTAssertEqual(Theme.Color.teamRedLinear, Theme.Color.accentErrorLinear)
        XCTAssertEqual(
            Theme.Color.teamBlueLinear, Theme.Color.accentRunningLinear)
        XCTAssertEqual(
            Theme.Color.teamGreenLinear, Theme.Color.accentSuccessLinear)
        XCTAssertEqual(
            Theme.Color.teamYellowLinear, Theme.Color.accentWarningLinear)
        XCTAssertEqual(
            Theme.Color.teamPurpleLinear, Theme.Color.accentThinkingLinear)
    }

    /// Team-cyan / team-orange / team-pink — the three non-aliased
    /// team colors. Cyan is the existing `ansi_cyan`; orange + pink
    /// are sprint-stage candidates per spec/design-tokens.md §"Team
    /// mode" §"Contrast verification". Test pins their candidate
    /// values so a sprint-time substitution surfaces here.
    func testTeamCandidatesPinSpecValues() {
        assertLinearMatchesHex(Theme.Color.teamCyanLinear, hex: 0x7dcf_ffff)
        assertLinearMatchesHex(Theme.Color.teamOrangeLinear, hex: 0xff9e_64ff)
        assertLinearMatchesHex(Theme.Color.teamPinkLinear, hex: 0xff7e_b6ff)
    }

    // MARK: Spacing scale

    /// 8-point grid with 4-point half-step per spec/design-tokens.md
    /// §"Spacing tokens".
    func testSpacingScaleMatchesSpec() {
        XCTAssertEqual(Theme.Spacing.zero, 0)
        XCTAssertEqual(Theme.Spacing.half, 4)
        XCTAssertEqual(Theme.Spacing.one, 8)
        XCTAssertEqual(Theme.Spacing.two, 16)
        XCTAssertEqual(Theme.Spacing.three, 24)
        XCTAssertEqual(Theme.Spacing.four, 32)
        XCTAssertEqual(Theme.Spacing.six, 48)
        XCTAssertEqual(Theme.Spacing.eight, 64)
    }

    // MARK: Radius scale

    /// Radius scale per spec/design-tokens.md §"Border radius tokens".
    /// `radius-md = 6pt` is the load-bearing block-container value
    /// from decisions/13 §Locks.
    func testRadiusScaleMatchesSpec() {
        XCTAssertEqual(Theme.Radius.none, 0)
        XCTAssertEqual(Theme.Radius.sm, 2)
        XCTAssertEqual(Theme.Radius.base, 4)
        XCTAssertEqual(Theme.Radius.md, 6)
        XCTAssertEqual(Theme.Radius.lg, 12)
    }

    // MARK: Motion durations

    /// Durations per spec/design-tokens.md §"Motion tokens" §"Duration".
    /// `motion-base = 150ms` is the locked baseline per decisions/13
    /// §Locks; the surrounding scale is derived (×0.67, ×2, ×3.3) so
    /// the rhythm reads as one motion system.
    func testMotionDurationsMatchSpec() {
        XCTAssertEqual(Theme.Motion.instant, 0)
        XCTAssertEqual(Theme.Motion.fast, 0.100, accuracy: 1e-9)
        XCTAssertEqual(Theme.Motion.base, 0.150, accuracy: 1e-9)
        XCTAssertEqual(Theme.Motion.slow, 0.300, accuracy: 1e-9)
        XCTAssertEqual(Theme.Motion.stretch, 0.500, accuracy: 1e-9)
    }

    // MARK: Easing curves

    /// Bezier control points per spec/design-tokens.md §"Motion tokens"
    /// §"Easing". `ease-out` is the default — appearing/opening reads
    /// natural with fast-start / slow-end.
    func testEasingCurvesMatchSpec() {
        XCTAssertEqual(Theme.Motion.easeOut.0, 0)
        XCTAssertEqual(Theme.Motion.easeOut.1, 0)
        XCTAssertEqual(Theme.Motion.easeOut.2, 0.2, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeOut.3, 1)

        XCTAssertEqual(Theme.Motion.easeIn.0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeIn.1, 0)
        XCTAssertEqual(Theme.Motion.easeIn.2, 1)
        XCTAssertEqual(Theme.Motion.easeIn.3, 1)

        XCTAssertEqual(Theme.Motion.easeInOut.0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeInOut.1, 0)
        XCTAssertEqual(Theme.Motion.easeInOut.2, 0.2, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeInOut.3, 1)

        XCTAssertEqual(Theme.Motion.easeEmphasized.0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeEmphasized.1, 0.7, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeEmphasized.2, 0.1, accuracy: 1e-6)
        XCTAssertEqual(Theme.Motion.easeEmphasized.3, 1)
    }

    // MARK: Sentinel-resolution palette

    /// `Theme.Color.defaultPalette` is the bundle `MetalRenderer.makeSlot`
    /// consults for `NamedColor` sentinel resolution. Both fields must
    /// alias the canonical tokens — drift here would mean the cells
    /// path and the chrome path render the same logical color
    /// differently.
    func testDefaultPaletteAliasesCanonicalTokens() {
        XCTAssertEqual(
            Theme.Color.defaultPalette.defaultFgLinear,
            Theme.Color.textPrimaryLinear)
        XCTAssertEqual(
            Theme.Color.defaultPalette.defaultBgLinear,
            Theme.Color.bgBaseLinear)
    }

    // MARK: helpers

    /// Asserts a stored `linear` token equals the closed-form sRGB→
    /// linear conversion of `hex` (engine `pack_rgba` encoding —
    /// `R<<24 | G<<16 | B<<8 | A`). Compares against
    /// `SRGBLinearLUT.referenceLinear` (the closed-form transfer)
    /// rather than precomputed floats so a future LUT-precision shift
    /// surfaces in `SRGBLinearLUTTests` (the dedicated guard) rather
    /// than here.
    private func assertLinearMatchesHex(
        _ linear: SIMD4<Float>, hex: UInt32,
        file: StaticString = #file, line: UInt = #line
    ) {
        let r = UInt8((hex >> 24) & 0xff)
        let g = UInt8((hex >> 16) & 0xff)
        let b = UInt8((hex >> 8) & 0xff)
        let a = UInt8(hex & 0xff)
        XCTAssertEqual(
            linear.x,
            SRGBLinearLUT.referenceLinear(forByte: r),
            accuracy: 1e-5,
            file: file, line: line)
        XCTAssertEqual(
            linear.y,
            SRGBLinearLUT.referenceLinear(forByte: g),
            accuracy: 1e-5,
            file: file, line: line)
        XCTAssertEqual(
            linear.z,
            SRGBLinearLUT.referenceLinear(forByte: b),
            accuracy: 1e-5,
            file: file, line: line)
        XCTAssertEqual(
            linear.w, Float(a) / 255.0, accuracy: 1e-6,
            file: file, line: line)
    }
}
