// M6-4a — Theme.Mode + ThemeManager + WCAG AA contrast scaffolding.
//
// Three concerns:
//   1. Theme.Mode persistence + label + resolved-light/dark mapping.
//   2. ThemeManager singleton fires `themeDidChange` on setMode().
//   3. Programmatic WCAG AA contrast assertion for text-primary /
//      bg-base. Dark-mode assertion is active and pinning the baseline;
//      light-mode assertion is XCTSkip-gated until M6-4b lands the
//      spec-keeper's light-token derivation per
//      `spec/design-tokens.md:119-126`.
//
// `contrastRatio(_:_:)` follows WCAG 2.1's "relative luminance" formula
// — both inputs are linear-space SIMD4<Float> tokens, so the gamma
// expansion happened upstream in `SRGBLinearLUT.unpackLinear`.

import XCTest
import simd

@testable import SolidTerm

@MainActor
final class ThemeModeTests: XCTestCase {

    // MARK: Theme.Mode

    func test_mode_label_is_user_facing() {
        // Three built-in modes — system / light / dark.
        XCTAssertEqual(Theme.Mode.system.label, "System")
        XCTAssertEqual(Theme.Mode.light.label, "Light")
        XCTAssertEqual(Theme.Mode.dark.label, "Dark")
        XCTAssertEqual(Theme.Mode.allCases.count, 3)
    }

    func test_mode_resolved_explicit_light_dark() {
        XCTAssertEqual(Theme.Mode.light.resolved, .light)
        XCTAssertEqual(Theme.Mode.dark.resolved, .dark)
    }

    func test_mode_rawvalue_is_codable_token() {
        // `rawValue` is the on-disk persistence token. Pinning it
        // catches accidental case renames that would orphan the user's
        // saved preference.
        XCTAssertEqual(Theme.Mode.system.rawValue, "system")
        XCTAssertEqual(Theme.Mode.light.rawValue, "light")
        XCTAssertEqual(Theme.Mode.dark.rawValue, "dark")
    }

    // MARK: ThemeManager broadcast

    func test_setMode_fires_themeDidChange_notification() {
        let manager = ThemeManager.shared
        // Park at a known mode so the test isn't sensitive to whatever
        // the user's `UserDefaults` happens to contain.
        manager.setMode(.dark)
        let expectation = expectation(forNotification: ThemeManager.themeDidChange, object: nil)
        manager.setMode(.light)
        wait(for: [expectation], timeout: 1.0)
    }

    func test_setMode_idempotent_does_not_fire_when_unchanged() {
        let manager = ThemeManager.shared
        manager.setMode(.dark)
        var fireCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChange, object: nil, queue: .main
        ) { _ in fireCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        manager.setMode(.dark)  // same mode → no broadcast
        // Allow any pending notifications to drain — none should fire.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(fireCount, 0, "setMode to the current mode must be a no-op")
    }

    // MARK: WCAG AA contrast

    /// WCAG 2.1 relative luminance per
    /// https://www.w3.org/WAI/WCAG21/Techniques/general/G18 — operates
    /// on linear-space components (which our Theme tokens already store).
    private func relativeLuminance(_ linear: SIMD4<Float>) -> Float {
        return 0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
    }

    /// WCAG contrast ratio: `(L1 + 0.05) / (L2 + 0.05)` with L1 the
    /// lighter luminance. Range [1, 21]; AA normal text requires ≥ 4.5.
    private func contrastRatio(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Dark-mode contrast pin: text-primary on bg-base ≥ 4.5:1 (WCAG
    /// AA normal text). This is the **active baseline** — if the
    /// dark-mode tokens drift in a future commit, this fires.
    func test_dark_mode_text_primary_on_bg_base_meets_AA() {
        let fg = Theme.Color.textPrimaryLinear(for: .dark)
        let bg = Theme.Color.bgBaseLinear(for: .dark)
        let ratio = contrastRatio(fg, bg)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "dark-mode text-primary on bg-base must meet WCAG AA (4.5:1); got \(ratio)")
    }

    /// Light-mode contrast pin (M6-4b activated). Catppuccin Latte
    /// Text `#4c4f69` on Latte Base `#eff1f5` per
    /// `spec/design-tokens.md:141` — 7.0:1 (AA + AAA).
    func test_light_mode_text_primary_on_bg_base_meets_AA() {
        let fg = Theme.Color.textPrimaryLinear(for: .light)
        let bg = Theme.Color.bgBaseLinear(for: .light)
        let ratio = contrastRatio(fg, bg)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "light-mode text-primary on bg-base must meet WCAG AA (4.5:1); got \(ratio)")
    }

    // MARK: M6-4b — pin the 6 spec-keeper darkening calls
    //
    // Each of the 6 tokens darkened from raw Catppuccin Latte for AA on
    // `bg-base #eff1f5` gets an explicit contrast pin. If a future drift
    // reverts to the raw Latte value (or any other lighter shade), the
    // pin fires before the visual regression ships. Spec ratios per
    // `spec/design-tokens.md` §"Accents" + §"Team mode" — pinned to
    // 4.5:1 which is the WCAG AA floor; the spec calls out specific
    // higher ratios in its rationale column.

    func test_light_accent_running_meets_AA() {
        let r = contrastRatio(
            Theme.Color.accentRunningLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "accent-running darkened from Latte Blue #1e66f5 (4.4:1) to #1a5ce0 (4.9:1); got \(r)"
        )
    }

    func test_light_accent_success_meets_AA() {
        let r = contrastRatio(
            Theme.Color.accentSuccessLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "accent-success darkened from Latte Green #40a02b (3.0:1) to #2d6b1c (4.9:1); got \(r)"
        )
    }

    func test_light_accent_warning_meets_AA() {
        let r = contrastRatio(
            Theme.Color.accentWarningLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "accent-warning shifted from Latte Yellow #df8e1d (2.3:1) to dark amber #9e5c00 (6.9:1); got \(r)"
        )
    }

    func test_light_team_orange_meets_AA() {
        let r = contrastRatio(
            Theme.Color.teamOrangeLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "team-orange darkened from Latte Peach #fe640b (3.2:1) to #b94800 (5.1:1); got \(r)"
        )
    }

    func test_light_team_pink_meets_AA() {
        let r = contrastRatio(
            Theme.Color.teamPinkLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "team-pink darkened to #a8166b (5.3:1) for AA on light bg; got \(r)")
    }

    func test_light_team_cyan_meets_AA() {
        let r = contrastRatio(
            Theme.Color.teamCyanLinear(for: .light),
            Theme.Color.bgBaseLinear(for: .light))
        XCTAssertGreaterThanOrEqual(
            r, 4.5,
            "team-cyan re-darkened to #06768c (4.67:1) per spec-keeper's programmatic verification; prior #0893b0 was 3.20:1; got \(r)"
        )
    }
}
