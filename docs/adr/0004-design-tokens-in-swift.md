# ADR-0004 — Design tokens are linear-space Swift constants

Status: accepted

## Context

Every colour, gap, corner radius and animation duration the app draws has to
come from somewhere. Left to itself that "somewhere" becomes a hex literal at
the call site, and a palette then exists only as the union of the places it was
typed — which is how two views end up one channel apart and nobody notices.

Two properties of this renderer make the problem sharper than usual. First, the
`CAMetalLayer` is `.bgra8Unorm_srgb`, so Metal applies the sRGB encode on
store: a shader that wants a given sRGB hex on screen must be handed the
*linear* value, and converting at each call site is both repeated work and a
place to get the gamma wrong. Second, the same token has to resolve differently
in light and dark mode without the call site branching on mode.

## Decision

`app/SolidTerm/Theme.swift` is the single source of truth for token values.
Renderer and chrome code reads tokens; no raw hex or pixel literal appears at a
call site.

- **Colour tokens** are `SIMD4<Float>` in linear space, built by
  `SRGBLinearLUT.unpackLinear(0xRRGGBBAA)` from the authored sRGB hex. Names
  follow the token vocabulary — `bg-base`, `bg-elevated`, `bg-overlay`,
  `bg-tint-subtle`, `bg-tint-active`, `text-primary`, `text-secondary`,
  `text-tertiary`, the `accent-*` family, `selection-bg`, `cursor-default`,
  `ime-underline`, `link-underline`, the `team-*` family.
- **Derived tokens are computed, never re-authored.** `text-tertiary` is
  `text-secondary` scaled to 60 % on the linear RGB channels with alpha
  preserved; `bg-tint-subtle` and `bg-tint-active` are `bg-base` lifted by
  roughly 4 % and 8 % lightness, so hover and keyboard-focus stay one and two
  steps off the floor. Aliases are declared as aliases: `ime-underline` is
  `text-primary`, `link-underline` is `accent-running`, and three of the
  `team-*` colours are the corresponding accents.
- **Mode resolution is an overload, not a branch at the call site.** The
  `Theme.Color.*Linear(for: Theme.Mode.Resolved)` functions are the public
  surface. Dark resolves to the top-level constants; light resolves to
  `Theme.LightTokens`, which is implementation and is not called directly.
  Dark is the zenzai/matcha cascade; light anchors on Catppuccin Latte with six
  tokens darkened from raw Latte so they clear WCAG AA on `bg-base #eff1f5`.
  A file-backed theme from `~/.config/solidterm/themes/*.toml` wins over both
  when one is active.
- **The non-colour scales are tokens too.** Spacing is an 8-point grid with a
  4-point half-step (0 / 4 / 8 / 16 / 24 / 32 / 48 / 64). Radius is
  0 / 2 / 4 / 6 / 12 pt, with 6 pt the container value. Motion is
  0 / 100 / 150 / 300 ms with 150 ms the baseline, plus easing curves as
  cubic-bezier control points.

## Consequences

- The on-screen pixel matches the authored hex by construction, because the
  gamma conversion happens once, in the token, and the framebuffer format does
  the inverse.
- Values are pinned by tests, not by convention: `ThemeTokenTests` asserts each
  token's hex, the derived relationships and the aliases; `ThemeModeTests`
  asserts WCAG contrast for both modes, including each of the six darkened
  light tokens. Changing a colour therefore means changing a test, which is the
  point — the change becomes visible in review instead of arriving as a diff to
  one constant.
- Adding a token means adding it here first. A view that needs a value the
  token set does not have is a signal to extend the set, not to type a hex.
