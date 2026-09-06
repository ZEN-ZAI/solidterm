// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The design token primitives, in Swift (ADR-0004).
//
// Every value here carries a token name. Implementation details
// (sRGB→linear conversion, MTLClearColor wrapper, MTLHeap
// font-rasterization parameters) stay in this file. No raw hex or pixel
// values should appear in renderer code — go through these tokens.
//
// Scope at the time of landing: M1 ships only the renderer-facing color
// tokens (bg-base / text-primary / cursor-default / selection-bg /
// ime-underline). The wider token surface (other surface levels, accents,
// team palette, type scale, full spacing/radius/motion scales) is shipped
// here as constants so chrome work in M2+ has a single contract to
// consume — the values land first, the call sites land later.
//
// `ThemeManager` (full theme switching, ANSI palette overrides, user
// theme files) is M5. This file
// stays a single static enum until then — single source of truth for
// token values, no dynamic dispatch.
//
// M6-4a: `Theme.Mode` + `ThemeManager` land here. M6-4b: light-mode
// tokens (Catppuccin Latte anchor with 6 darkened for AA — the
// "Zenzai Light" table). The mode-aware `Color.*Linear(for:)` overloads are the
// public surface; `LightTokens` holds the implementation values.

import Foundation
import Metal
import SwiftUI
import simd

enum Theme {
    // MARK: - M7 feature flags

    /// Gates Claude block chrome (Claude/Tool/Permission/Diff/
    /// ThinkingDelta hosting views). Flipped to `true` to surface
    /// the M3 Native Core + M4 Team Mode UI. Per-pane intercept of
    /// the `claude` CLI is still opt-in via the
    /// `toggleClaudeNativeMode` palette action — a window where no
    /// pane has the intercept on will still render Claude as plain
    /// terminal output (no blocks arrive to render). The chrome flag
    /// only controls whether incoming blocks paint as SwiftUI
    /// variants vs. plain text. `BlockOverlayManager.applyClaude(...)`
    /// is the production gate.
    static var showClaudeBlockChrome: Bool = true

    /// M7-4: gates the slim left-margin OSC 133 accent rule. Default
    /// `false` so the M5.5 dogfood removal of the wide block stripes
    /// (`58d0b97`, "ลบ stripe ออกถาวร") stays the out-of-the-box
    /// behavior. Users opt in via Settings → Appearance → "Show
    /// command markers". Read live from `UserDefaults` so the toggle
    /// takes effect on the next render frame without needing an
    /// observer on `BlockOverlayManager`.
    static var showOSC133Accent: Bool {
        UserDefaults.standard.bool(forKey: OSC133.userDefaultsKey)
    }

    /// Layout + persistence constants for the M7-4 accent overlay.
    /// Kept as their own namespace so they don't bloat the existing
    /// `Gutter` enum (which still owns the M5.5 stripe constants for
    /// the eventual block-chrome gutter rework).
    enum OSC133 {
        /// `UserDefaults` key persisting the user's opt-in state.
        /// Bound from `Settings → Appearance` and read by
        /// `Theme.showOSC133Accent` on every render frame.
        static let userDefaultsKey = "solidterm.osc133Accent.enabled"

        /// Width of the slim rule in points. 2pt reads as a marker —
        /// narrow enough to coexist with the leftmost cell column
        /// (whose glyphs still occupy the full cell box) without
        /// dominating the surface, wide enough to be a clear visual
        /// signal at retina pixel density.
        static let markerWidthPt: CGFloat = 2
    }

    /// Color tokens (ADR-0004). Linear-space `SIMD4<Float>` is the
    /// renderer-facing form — Metal's `.bgra8Unorm_srgb` framebuffer
    /// applies the sRGB encode on store, so passing already-linear
    /// values means the on-screen pixel reads back as the token's sRGB
    /// hex when sampled.
    enum Color {
        // MARK: Surface levels

        /// `bg-base` — `#1c2418`. matcha background (zenzai-v2
        /// themes/matcha.toml — green-tinted dark). Terminal grid
        /// background; the floor of the surface stack. Doubles as
        /// the `MTLClearColor` for the drawable.
        static let bgBaseLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x1c24_18ff)

        /// `bg-elevated` — `#16161e`. Sidebar, command palette
        /// container, settings panel.
        static let bgElevatedLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x1616_1eff)

        /// `bg-overlay` — `#1a1b26`. Modal, dialog, permission prompt
        /// sheet.
        static let bgOverlayLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x1a1b_26ff)

        /// `bg-tint-subtle` — `#16161a`. Derived as `bg-base + 4%
        /// lightness` (ADR-0004) — the surface level for block hover
        /// and list-item rest. Used by the M2-5b `AltScreenStub`
        /// container background and the M2-5c block-hover state. The
        /// concrete `#16161a` lands the channel-shift roughly equal to
        /// `bg-base` (`#0e0d10`) + (+8, +9, +10) — a one-step lift from
        /// the floor that reads as "slightly raised" without crossing
        /// into `bg-elevated` territory.
        static let bgTintSubtleLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x1616_1aff)

        /// `bg-tint-active` — `#1f1e22`. Derived as `bg-base + 8%
        /// lightness` (ADR-0004) — the surface level for block focused
        /// and list-item selected. Used by the M2-5c keyboard-
        /// focus state on `BlockContainerView`. The concrete `#1f1e22`
        /// roughly doubles the `bg-tint-subtle` delta from `bg-base`
        /// (channel-shift `(+17, +17, +18)` vs subtle's `(+8, +9, +10)`)
        /// — a two-step lift that still reads as "still on the surface
        /// stack" without crossing into the `bg-elevated` register
        /// (`#16161e`, which steps the blue channel further than the
        /// red/green for elevation differentiation).
        static let bgTintActiveLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x1f1e_22ff)

        // MARK: Text levels

        /// `text-primary` — `#c8d0b8`. matcha foreground. Command
        /// output, body prose, default reading. Aliases the engine's
        /// default-fg sentinel (`0xffff_ffff`) resolution.
        static let textPrimaryLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xc8d0_b8ff)

        /// `text-secondary` — `#a9b1d6`. Metadata, captions.
        static let textSecondaryLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xa9b1_d6ff)

        /// `text-tertiary` — derived as `text-secondary × 60%`
        /// (ADR-0004). Multiplies the linear-space RGB channels and
        /// preserves alpha. Used by block-container chrome (3px accent
        /// stripe in pending / unknown / raw states, 1px edge border at
        /// 30% alpha). Muted hints, placeholders, and separators
        /// also key off this token.
        static let textTertiaryLinear: SIMD4<Float> = SIMD4(
            textSecondaryLinear.x * 0.6,
            textSecondaryLinear.y * 0.6,
            textSecondaryLinear.z * 0.6,
            textSecondaryLinear.w)

        // MARK: Accents

        /// `accent-running` — `#7aa2f7`. Active state; "live" cursor;
        /// default action button.
        static let accentRunningLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x7aa2_f7ff)

        /// `accent-success` — `#9ece6a`. Successful command, applied
        /// diff, completed task.
        static let accentSuccessLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x9ece_6aff)

        /// `accent-error` — `#f7768e`. Failed command, destructive
        /// action, error notice.
        static let accentErrorLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xf776_8eff)

        /// `accent-warning` — `#e0af68`. Permission required,
        /// caution-state surface.
        static let accentWarningLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xe0af_68ff)

        /// `accent-thinking` — `#bb9af7`. Claude streaming,
        /// plan-pending, extended-thinking.
        static let accentThinkingLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xbb9a_f7ff)

        // MARK: Selection / cursor

        /// `selection-bg` — `#2a3424`. matcha selection (same as
        /// ANSI black — a deeper green-shadow tint).
        /// Text-selection background;
        /// `MetalRenderer.encodeSelectionOverlay` modulates the alpha
        /// down to 0.35 via `colorLinear.a`, so the
        /// stored tint is straight-alpha and the shader stays
        /// kind-agnostic.
        static let selectionBgLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x2a34_24ff)

        /// `cursor-default` — `#c4919f`. matcha cursor (mauve, taken
        /// straight from themes/matcha.toml — contrasts strongly
        /// against the green-tinted bg). `MetalRenderer` feeds this
        /// into `OverlayUniforms.colorLinear` and modulates
        /// `colorLinear.a` per-frame via `blinkAlpha(...)` to drive
        /// DECSCUSR blink.
        static let cursorDefaultLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xc491_9fff)

        // MARK: IME

        /// IME preedit underline color. We alias `text-primary` so
        /// users perceive the preedit underline as "in-flight typing"
        /// rather than a separate UI element — the same color the
        /// committed glyph will land in once the IME confirms.
        static let imeUnderlineLinear: SIMD4<Float> = textPrimaryLinear

        /// M6-2 ⌘+hover link underline color. Aliases `accent-running`
        /// (`#7aa2f7`) so the underline reads as "clickable / live"
        /// — same hue as the cursor / running-block accent users
        /// already learn means "this is interactive." Reuses the same
        /// kind=3 shader path as `imeUnderlineLinear`, just a
        /// different color tint.
        static let linkUnderlineLinear: SIMD4<Float> = accentRunningLinear

        /// Scrollbar thumb color — translucent text-primary so the
        /// indicator reads as "secondary chrome" against any theme.
        /// Drawn as a solid quad in the overlay pass (kind=0).
        static let scrollbarThumbLinear: SIMD4<Float> = SIMD4<Float>(
            textPrimaryLinear.x, textPrimaryLinear.y, textPrimaryLinear.z, 0.35)

        // MARK: Team mode (8 teammate colors)

        /// `team-red` ≡ `accent-error` (`#f7768e`).
        static let teamRedLinear: SIMD4<Float> = accentErrorLinear

        /// `team-blue` ≡ `accent-running` (`#7aa2f7`).
        static let teamBlueLinear: SIMD4<Float> = accentRunningLinear

        /// `team-green` ≡ `accent-success` (`#9ece6a`).
        static let teamGreenLinear: SIMD4<Float> = accentSuccessLinear

        /// `team-yellow` ≡ `accent-warning` (`#e0af68`).
        static let teamYellowLinear: SIMD4<Float> = accentWarningLinear

        /// `team-purple` ≡ `accent-thinking` (`#bb9af7`).
        static let teamPurpleLinear: SIMD4<Float> = accentThinkingLinear

        /// `team-orange` candidate `#ff9e64`. WCAG AA contrast against
        /// `bg-base` deferred to sprint kickoff.
        static let teamOrangeLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xff9e_64ff)

        /// `team-pink` candidate `#ff7eb6`. WCAG AA contrast against
        /// `bg-base` deferred to sprint kickoff.
        static let teamPinkLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0xff7e_b6ff)

        /// `team-cyan` — `#7dcfff`. Existing `ansi_cyan`.
        static let teamCyanLinear: SIMD4<Float> =
            SRGBLinearLUT.unpackLinear(0x7dcf_ffff)

        // MARK: Renderer sentinel-resolution bundle

        /// Bundle of the two colors `MetalRenderer.makeSlot` consults
        /// when resolving the engine's `NamedColor` sentinels
        /// (`0xffff_ffff` = default fg, `0x0000_00ff` = default bg).
        /// Kept as a struct so the pure-function variant of `makeSlot`
        /// (used by `MetalRendererSGRColorTests` without a window /
        /// display link) takes a single injectable argument.
        ///
        /// Once `ThemeManager` lands at M5, this becomes an instance
        /// member sourced from the active theme — until then it's a
        /// static derivation from the locked Zenzai-Dark default.
        static let defaultPalette = Palette(
            defaultFgLinear: textPrimaryLinear,
            defaultBgLinear: bgBaseLinear)

        // MARK: M6-4a/b — mode-aware token resolution
        //
        // All `*(for:)` overloads route to the dark constants for `.dark`
        // and to `LightTokens.*` for `.light`. M6-4b activated the light
        // cascade (Zenzai Light) — Catppuccin Latte anchor with 6 tokens
        // darkened from raw Latte for AA on `bg-base #eff1f5`. Hue
        // families preserved; saturation/lightness adjusted only where
        // direct Latte values failed contrast.
        //
        // Renderer call sites that want mode-awareness migrate from
        // `Theme.Color.bgBaseLinear` to
        // `Theme.Color.bgBaseLinear(for: ThemeManager.shared.resolved)`.
        // Existing call sites that don't migrate continue to read the
        // dark constants — same pixels they get on dark mode today.

        /// Mode-aware `bg-base`.
        static func bgBaseLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return bgBaseLinear
            case .light: return LightTokens.bgBaseLinear
            }
        }

        /// Mode-aware `bg-elevated`.
        static func bgElevatedLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return bgElevatedLinear
            case .light: return LightTokens.bgElevatedLinear
            }
        }

        /// Mode-aware `bg-overlay`.
        static func bgOverlayLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return bgOverlayLinear
            case .light: return LightTokens.bgOverlayLinear
            }
        }

        /// Mode-aware `text-primary`.
        static func textPrimaryLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return textPrimaryLinear
            case .light: return LightTokens.textPrimaryLinear
            }
        }

        /// Mode-aware `text-secondary`.
        static func textSecondaryLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return textSecondaryLinear
            case .light: return LightTokens.textSecondaryLinear
            }
        }

        /// Mode-aware `text-tertiary`.
        static func textTertiaryLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return textTertiaryLinear
            case .light: return LightTokens.textTertiaryLinear
            }
        }

        /// Mode-aware `accent-running`. Catppuccin Latte Blue darkened
        /// to `#1a5ce0` (4.9:1 vs `bg-base #eff1f5`); raw Latte Blue
        /// `#1e66f5` was 4.4:1, just under AA.
        static func accentRunningLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return accentRunningLinear
            case .light: return LightTokens.accentRunningLinear
            }
        }

        /// Mode-aware `accent-success`. Latte Green darkened to
        /// `#2d6b1c` (4.9:1); raw Latte Green `#40a02b` was 3.0:1.
        static func accentSuccessLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return accentSuccessLinear
            case .light: return LightTokens.accentSuccessLinear
            }
        }

        /// Mode-aware `accent-error`. Direct Catppuccin Latte Red
        /// `#d20f39` (4.9:1) — no adjustment needed.
        static func accentErrorLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return accentErrorLinear
            case .light: return LightTokens.accentErrorLinear
            }
        }

        /// Mode-aware `accent-warning`. Latte Yellow `#df8e1d` was
        /// only 2.3:1 — shifted to dark amber `#9e5c00` (6.9:1). Hue
        /// family (warm yellow-orange) preserved; saturation +
        /// lightness adjusted. The one accent that required a
        /// deliberate departure from the direct Latte analog.
        static func accentWarningLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return accentWarningLinear
            case .light: return LightTokens.accentWarningLinear
            }
        }

        /// Mode-aware `accent-thinking`. Direct Catppuccin Latte Mauve
        /// `#8839ef` (4.8:1).
        static func accentThinkingLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return accentThinkingLinear
            case .light: return LightTokens.accentThinkingLinear
            }
        }

        /// Mode-aware `selection-bg`. Latte Surface2 `#ccd0da` —
        /// visible selection tint on light bg.
        static func selectionBgLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return selectionBgLinear
            case .light: return LightTokens.selectionBgLinear
            }
        }

        /// Mode-aware `cursor-default` (ADR-0004). Aliases
        /// `accent-running` in both modes.
        static func cursorDefaultLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            accentRunningLinear(for: mode)
        }

        /// Mode-aware `ime-underline`. Aliases `text-primary` in both
        /// modes (ADR-0004).
        static func imeUnderlineLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            textPrimaryLinear(for: mode)
        }

        /// Mode-aware `link-underline`. Aliases `accent-running` in
        /// both modes per the M6-2 wiring (`Theme.Color.linkUnderlineLinear`
        /// is on M6-2's branch).

        /// Mode-aware `team-red`. Latte Red darkened to `#c01c3a`
        /// (5.5:1) for light bg.
        static func teamRedLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return teamRedLinear
            case .light: return LightTokens.teamRedLinear
            }
        }

        /// Mode-aware `team-blue`. Aliases `accent-running` in both
        /// modes (`#1a5ce0` light / `#7aa2f7` dark).
        static func teamBlueLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            accentRunningLinear(for: mode)
        }

        /// Mode-aware `team-green`. Aliases `accent-success` (`#2d6b1c`
        /// light / `#9ece6a` dark).
        static func teamGreenLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            accentSuccessLinear(for: mode)
        }

        /// Mode-aware `team-yellow`. Aliases `accent-warning` —
        /// matches the warning's amber-shift `#9e5c00` on light.
        static func teamYellowLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            accentWarningLinear(for: mode)
        }

        /// Mode-aware `team-purple`. Aliases `accent-thinking`.
        static func teamPurpleLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            accentThinkingLinear(for: mode)
        }

        /// Mode-aware `team-orange`. Latte Peach darkened to `#b94800`
        /// (5.1:1); raw Peach `#fe640b` was 3.2:1.
        static func teamOrangeLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return teamOrangeLinear
            case .light: return LightTokens.teamOrangeLinear
            }
        }

        /// Mode-aware `team-pink`. Latte Pink darkened to `#a8166b`
        /// (5.3:1) for AA.
        static func teamPinkLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return teamPinkLinear
            case .light: return LightTokens.teamPinkLinear
            }
        }

        /// Mode-aware `team-cyan`. Latte Sky re-darkened to `#06768c`
        /// (4.67:1), from a programmatic contrast-verification pass.
        /// Raw Sky `#04a5e5` was 3.3:1; an earlier `#0893b0` candidate
        /// only reached 3.20:1 — the eyeballed darkening missed AA.
        static func teamCyanLinear(for mode: Theme.Mode.Resolved) -> SIMD4<Float> {
            switch mode {
            case .dark: return teamCyanLinear
            case .light: return LightTokens.teamCyanLinear
            }
        }

        /// Mode-aware default sentinel-resolution palette.
        static func defaultPalette(for mode: Theme.Mode.Resolved) -> Palette {
            Palette(
                defaultFgLinear: textPrimaryLinear(for: mode),
                defaultBgLinear: bgBaseLinear(for: mode))
        }
    }

    // MARK: M6-4b — Light-mode token values (Zenzai Light)
    //
    // Catppuccin Latte anchor with 6 tokens darkened from raw Latte for
    // AA on `bg-base #eff1f5`. Each darkened token's pre-darkening Latte
    // value + the WCAG ratio that triggered the shift is recorded in the
    // per-mode overload doc-comments above.
    //
    // Kept inside `Theme` namespace as a sibling enum to `Color` so
    // callers reach for `Theme.Color.bgBaseLinear(for: .light)` rather
    // than `Theme.LightTokens.bgBaseLinear` directly — the resolver
    // overloads are the public surface, these constants are the
    // implementation.

    enum LightTokens {
        // Surface levels
        static let bgBaseLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xeff1_f5ff)
        static let bgElevatedLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xe6e9_efff)
        static let bgOverlayLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xdce0_e8ff)

        // Text levels
        /// `#4c4f69` Catppuccin Latte Text. 7.0:1 vs bg-base — AA + AAA.
        static let textPrimaryLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x4c4f_69ff)
        /// `#5c5f77` Catppuccin Latte Subtext1. 5.2:1 vs bg-base — AA.
        static let textSecondaryLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x5c5f_77ff)
        /// `#6c6f85` Catppuccin Latte Subtext0. 3.9:1 vs bg-base —
        /// non-text AA.
        static let textTertiaryLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x6c6f_85ff)

        // Accents (6 darkened from raw Latte; the doc-comments above
        // carry the rationale)
        static let accentRunningLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x1a5c_e0ff)
        static let accentSuccessLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x2d6b_1cff)
        static let accentErrorLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xd20f_39ff)
        static let accentWarningLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x9e5c_00ff)
        static let accentThinkingLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x8839_efff)

        // Selection / cursor
        static let selectionBgLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xccd0_daff)

        // Team palette (5/8 alias accents above; 3/8 standalone darkened)
        static let teamRedLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xc01c_3aff)
        static let teamOrangeLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xb948_00ff)
        static let teamPinkLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0xa816_6bff)
        static let teamCyanLinear: SIMD4<Float> = SRGBLinearLUT.unpackLinear(0x0676_8cff)
    }

    /// Sentinel-resolution input for `MetalRenderer.makeSlot`. See
    /// `Theme.Color.defaultPalette` for the production instance.
    struct Palette {
        /// Default foreground in linear space. `MetalRenderer.makeSlot`
        /// returns this when the engine's per-cell `fg` u32 is
        /// `0xffff_ffff` (NamedColor::Foreground).
        let defaultFgLinear: SIMD4<Float>

        /// Default background in linear space. Returned when the
        /// engine's per-cell `bg` u32 is `0x0000_00ff`
        /// (NamedColor::Background). Doubles as the `MTLClearColor`
        /// for the drawable when the renderer reaches `clear-only`
        /// states.
        let defaultBgLinear: SIMD4<Float>
    }

    /// Spacing scale. 8-point grid with a 4-point half-step (ADR-0004).
    enum Spacing {
        /// `space-0` — 0pt. No gap.
        static let zero: CGFloat = 0
        /// `space-half` — 4pt. Half-step; tight gutter inside a
        /// single component.
        static let half: CGFloat = 4
        /// `space-1` — 8pt. Default gutter; block internal padding
        /// (a locked value, ADR-0004).
        static let one: CGFloat = 8
        /// `space-2` — 16pt. Section gap, list-item vertical padding.
        static let two: CGFloat = 16
        /// `space-3` — 24pt. Section margin, modal internal padding.
        static let three: CGFloat = 24
        /// `space-4` — 32pt. Major section break.
        static let four: CGFloat = 32
        /// `space-6` — 48pt. Rare; large container padding.
        static let six: CGFloat = 48
        /// `space-8` — 64pt. Rare; modal max-width breathing room.
        static let eight: CGFloat = 64
    }

    /// Border-radius scale (ADR-0004).
    enum Radius {
        /// `radius-none` — 0pt. Terminal grid (intentional sharp edges).
        static let none: CGFloat = 0
        /// `radius-sm` — 2pt. Subtle rounding — inline badges, status
        /// dots.
        static let sm: CGFloat = 2
        /// `radius-base` — 4pt. Buttons, inputs, palette items.
        static let base: CGFloat = 4
        /// `radius-md` — 6pt. Block containers, modal corners
        /// (a locked value, ADR-0004).
        static let md: CGFloat = 6
        /// `radius-lg` — 12pt. Large modals, sheet-style overlays.
        static let lg: CGFloat = 12
    }

    /// Motion tokens. Durations in seconds; easing curves as
    /// `CAMediaTimingFunction`-compatible control points (cubic-bezier
    /// `(c1.x, c1.y, c2.x, c2.y)`) — ADR-0004.
    enum Motion {
        /// `motion-instant` — 0ms. Reduced-motion fallback.
        static let instant: TimeInterval = 0
        /// `motion-fast` — 100ms. Hover state, focus ring.
        static let fast: TimeInterval = 0.100
        /// `motion-base` — 150ms. Existing baseline (palette, modal,
        /// block collapse). A locked value (ADR-0004).
        static let base: TimeInterval = 0.150
        /// `motion-slow` — 300ms. Multi-step orchestration, settings
        /// panel slide.
        static let slow: TimeInterval = 0.300
        /// `motion-stretch` — 500ms. Rare; "guided attention".
        static let stretch: TimeInterval = 0.500

        /// `ease-out` (default) — `cubic-bezier(0, 0, 0.2, 1)`.
        /// Appearing, opening.
        static let easeOut: (Float, Float, Float, Float) = (0, 0, 0.2, 1)
        /// `ease-in` — `cubic-bezier(0.4, 0, 1, 1)`. Disappearing,
        /// closing.
        static let easeIn: (Float, Float, Float, Float) = (0.4, 0, 1, 1)
        /// `ease-in-out` — `cubic-bezier(0.4, 0, 0.2, 1)`. Moving,
        /// transitioning between two visible states.
        static let easeInOut: (Float, Float, Float, Float) = (0.4, 0, 0.2, 1)
        /// `ease-emphasized` — Material's emphasized curve;
        /// `cubic-bezier(0.05, 0.7, 0.1, 1)`.
        static let easeEmphasized: (Float, Float, Float, Float) =
            (0.05, 0.7, 0.1, 1)
    }

    /// Block-chrome gutter (M5.5 / M6 prep) — 24pt left column that
    /// hosts per-block accent stripes outside the cell grid. Defined
    /// here so the constants survive the eventual deletion of
    /// `BlockContainerView`.
    enum Gutter {
        /// Full gutter column width. Set to 0 by user request — stripes
        /// disabled in `BlockOverlayManager.apply()`, so the gutter column
        /// is reclaimed for cells. Tokens kept for the eventual
        /// block-chrome gutter rework. The designed value
        /// (24pt = space-3) is preserved as a reference comment.
        static let widthPt: CGFloat = 0  // designed: 24
        /// Accent-stripe width — a 3px accent stripe. Slimmer
        /// than the column so the stripe reads as a marker, not a
        /// background fill.
        static let stripeWidthPt: CGFloat = 3
        /// X-offset of the 3pt stripe inside the 24pt gutter column.
        /// Right-biased — the stripe sits near the cell-grid edge so
        /// the visual anchor reads as "attached to the block".
        /// `widthPt - stripeWidthPt - 2` = 19pt leaves a 2pt breathing
        /// gap between stripe and grid.
        static let stripeXOffsetPt: CGFloat = 19
    }

    /// `MTLClearColor` mirror of `Color.bgBaseLinear`. Kept as a
    /// computed value rather than a stored constant so changes to the
    /// token flow through automatically.
    static var defaultClearMTL: MTLClearColor {
        let bg = Color.bgBaseLinear
        return MTLClearColor(
            red: Double(bg.x),
            green: Double(bg.y),
            blue: Double(bg.z),
            alpha: Double(bg.w))
    }

    /// M6-4a: mode-aware `MTLClearColor`. Routes through the same
    /// `bgBaseLinear(for:)` branch — light resolves to dark until
    /// M6-4b. Renderer calls this on theme-change broadcast to
    /// refresh its drawable clear color.
    static func defaultClearMTL(for mode: Mode.Resolved) -> MTLClearColor {
        let bg = Color.bgBaseLinear(for: mode)
        return MTLClearColor(
            red: Double(bg.x),
            green: Double(bg.y),
            blue: Double(bg.z),
            alpha: Double(bg.w))
    }

    // MARK: M6-4a — Theme.Mode + change broadcast

    /// User-selectable theme mode. M6-4a ships infrastructure (enum,
    /// observer, broadcast, picker UI) with light variants resolving
    /// to dark tokens; M6-4b activates the light token cascade.
    /// Built-in palette modes. Three only — `system` follows the OS
    /// appearance + flips between `light` and `dark` on change. The
    /// designs:
    ///
    /// - **dark** — zenzai-v2 canonical (`#0F0F12` bg, `#E4E2DE` fg,
    ///   16-color ANSI palette mirrored in the engine's `encode_named`)
    /// - **light** — Catppuccin Latte anchor with 6 tokens darkened
    ///   for AA contrast on `#eff1f5` bg (ADR-0004)
    ///
    /// File-backed themes from `~/.config/solidterm/themes/*.toml`
    /// (selected via Settings → Appearance "Theme file:") win over
    /// these modes when active.
    enum Mode: String, CaseIterable, Codable {
        /// Follow `NSApp.effectiveAppearance` — flip on system
        /// Appearance change.
        case system
        /// Light mode. Catppuccin Latte cascade.
        case light
        /// Dark mode. zenzai-v2 cascade.
        case dark

        /// User-facing label for the picker.
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// Resolve to a concrete light/dark choice. `.system` reads
        /// `NSApp.effectiveAppearance` — must run on main.
        @MainActor
        var resolved: Resolved {
            switch self {
            case .light: return .light
            case .dark: return .dark
            case .system:
                let isDark =
                    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua
                return isDark ? .dark : .light
            }
        }

        /// Concrete light/dark binary the renderer consumes — always
        /// either `.dark` or `.light` after resolution.
        enum Resolved {
            case light
            case dark
        }
    }
}

// MARK: M6-4a — ThemeManager singleton

/// Process-wide theme state. Holds the user's selected `Theme.Mode`,
/// observes `NSApp.effectiveAppearance` changes for `.system`, and
/// broadcasts `themeDidChange` notifications so cell grid + chrome
/// re-resolve their tokens.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    /// `UserDefaults` key for persisted mode. Per the M6-2 per-feature
    /// pattern (`solidterm.filePathClick.*`); no centralized
    /// SettingsStore abstraction.
    static let modeKey = "solidterm.theme.mode"

    /// Notification posted on theme change. AppKit consumers
    /// (`MetalRenderer`, `BlockOverlayManager`) observe this; SwiftUI
    /// consumers can use `@ObservedObject` against the singleton
    /// directly.
    static let themeDidChange = Notification.Name("solidTermThemeDidChange")

    @Published private(set) var mode: Theme.Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
        }
    }

    /// Current resolved light/dark — driven by `mode.resolved` plus
    /// the `effectiveAppearance` observer for `.system`.
    var resolved: Theme.Mode.Resolved { mode.resolved }

    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? Theme.Mode.system.rawValue
        self.mode = Theme.Mode(rawValue: raw) ?? .system
        observeSystemAppearance()
    }

    /// Update the user's selected mode. Idempotent — a no-op if the
    /// new mode equals the current.
    func setMode(_ newMode: Theme.Mode) {
        guard mode != newMode else { return }
        mode = newMode
    }

    /// Watch `NSApp.effectiveAppearance` for system Light/Dark flips.
    /// Only fires when `mode == .system` — for explicit modes the
    /// resolved value is fixed and the observer is cosmetic.
    private func observeSystemAppearance() {
        // `NSApp` is process-global; KVO on `effectiveAppearance` fires
        // when the user toggles macOS Appearance. We re-broadcast
        // `themeDidChange` so consumers re-resolve, even though the
        // `mode` itself didn't change — `mode.resolved` did.
        appearanceObservation = NSApp.observe(
            \.effectiveAppearance, options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode == .system {
                    NotificationCenter.default.post(
                        name: Self.themeDidChange, object: nil)
                }
            }
        }
    }
}

/// sRGB → linear transfer function lookup table for byte-valued sRGB
/// channels. Computed once at module load via the standard piecewise
/// formula:
///
/// ```
/// c_linear = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4
/// ```
///
/// Used by `MetalRenderer.makeSlot` to convert FFI-supplied
/// sRGB-encoded `fg`/`bg` u32 values into the linear-space colors the
/// grid shader's mix expects. 256 floats = 1 KB; lookup is one indexed
/// read per channel (3 reads per cell × 2 colors per cell).
enum SRGBLinearLUT {
    /// Closed-form reference — call once per byte at table-build time.
    /// Tests sample this against the LUT to guard against drift.
    @inline(__always)
    static func referenceLinear(forByte byte: UInt8) -> Float {
        let s = Float(byte) / 255.0
        if s <= 0.040_45 {
            return s / 12.92
        }
        return pow((s + 0.055) / 1.055, 2.4)
    }

    static let table: [Float] = (0..<256).map { i in
        referenceLinear(forByte: UInt8(i))
    }

    /// Unpack an `R<<24 | G<<16 | B<<8 | A` u32 (engine encoding per
    /// `crates/solidterm-engine/src/cells.rs:214`) into a linear-space
    /// `SIMD4<Float>`. Alpha stays straight (no transfer function).
    @inline(__always)
    static func unpackLinear(_ packed: UInt32) -> SIMD4<Float> {
        let r = UInt8((packed >> 24) & 0xff)
        let g = UInt8((packed >> 16) & 0xff)
        let b = UInt8((packed >> 8) & 0xff)
        let a = UInt8(packed & 0xff)
        return SIMD4<Float>(
            table[Int(r)],
            table[Int(g)],
            table[Int(b)],
            Float(a) / 255.0)
    }
}

// MARK: - Theme color → SwiftUI Color bridge

extension Color {
    /// Construct a SwiftUI `Color` from a linear-RGB `SIMD4<Float>`
    /// token. `Theme.Color.*Linear` constants are pre-computed in
    /// linear space (sRGB→linear) so the Metal `.bgra8Unorm_srgb`
    /// framebuffer reads them back as the token's sRGB hex after
    /// the encode-on-store. SwiftUI's `Color(.sRGBLinear, ...)`
    /// initializer takes the same linear-space values directly.
    ///
    /// M5.5-4: migrated here from the now-deleted `BlockContainerView`
    /// so `GutterView` (and any future SwiftUI consumers) can resolve
    /// `Theme.Color.*Linear` tokens without depending on the chrome
    /// surface that's been removed.
    init(linear: SIMD4<Float>) {
        self.init(
            .sRGBLinear,
            red: Double(linear.x),
            green: Double(linear.y),
            blue: Double(linear.z),
            opacity: Double(linear.w))
    }
}
