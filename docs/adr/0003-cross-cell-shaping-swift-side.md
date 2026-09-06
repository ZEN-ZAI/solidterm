# ADR-0003 — Cross-cell grapheme shaping lives on the Swift side

Status: accepted

## Context

A terminal grid assigns each cell one display slot, and the engine fills those
cells from the byte stream. Several scripts break that assumption: Thai SARA AM
(`ทำ`) is a base consonant plus a vowel sign that Unicode segments as two
clusters but readers see as one glyph; a flag is two regional indicators; a ZWJ
emoji family can exceed the 32-byte grapheme buffer a single cell carries and
spill into the next one; a variation selector or a skin-tone modifier can land
in the following cell for the same reason.

Rendering those cells independently produces the visible bug: a dotted circle
where a Thai vowel should sit, two letters instead of a flag, a broken family
emoji. Something has to notice that adjacent cells belong to one drawn unit.

That "something" needs a cluster authority. The only one available that agrees
with what macOS itself draws is CoreText — specifically Swift's UAX #29
`byComposedCharacterSequences` segmentation and the CoreText shaping that
follows. Reimplementing UAX #29 in Rust would mean maintaining a second
segmentation implementation that must agree with CoreText's, forever, or
accept that the renderer disagrees with the platform on exactly the inputs that
motivated the work.

Stack A already draws this line: Swift owns all rendering, Rust is data-only,
and no CoreText or Metal type crosses the FFI. Shaping is a rendering concern.

## Decision

Cross-cell grapheme shaping is a Swift-side pass that runs *after* the FFI, in
`GraphemeClusterCoalescer`. It sweeps the decoded cell records row-major, and
where adjacent cells belong to one cluster it merges them into a
`CoalescedCell` carrying an owned `grapheme` string and a `cellSpan` — the
number of source columns the entry covers, the primary cell's display width
included. The renderer sizes its atlas quad from `cellSpan` alone;
`GridPipeline`'s span texture was widened to
`r16Uint` to carry it, and the shader extends the quad accordingly.

The coalescer is two-stage on purpose. `candidate()` is a cheap scalar-range
screen that exits on the first byte compare for ASCII, so the common path costs
nothing. `shouldMerge()` is the authority: it asks Swift's UAX #29 whether the
joined string is one composed character sequence, with one deliberate override
— a Thai consonant followed only by Thai marks or SARA AM is treated as one
cluster even though UAX #29 splits it, because SARA AM is categorised `Lo`, not
a combining mark, and readers still see one unit.

The Rust engine is unchanged by this: it keeps emitting per-cell records and
knows nothing about clusters.

Shaping is on by default. `SOLIDTERM_SHAPING=0` disables the coalescer and
restores the single-cell path, for diagnosing whether a rendering artefact
comes from shaping or from somewhere else.

## Consequences

- The renderer agrees with CoreText by construction, including on future
  Unicode revisions, because it delegates rather than reimplements.
- The cost is one extra pass over the decoded cells per frame. The fast-path
  screen keeps ASCII rows at effectively the cost of the range compare.
- Correctness is pinned by tests, not by inspection:
  `GraphemeClusterCoalescerTests` covers the Thai stacks, flag pairs, ZWJ
  spillover, variation selectors and the over-merge guards — a skin-tone
  modifier must not swallow the emoji after it, and where the cheap screen
  fires the commit decision must still agree with Swift's own segmentation —
  and `GlyphAtlasTests` pins the `cellSpan` quad sizing.
- The escape hatch is a diagnostic, not a supported configuration. Anything
  that only works with `SOLIDTERM_SHAPING=0` is a bug in the coalescer.
- Because the merge happens after the FFI, the engine's cell records stay a
  faithful description of the grid. Anything that needs grid truth rather than
  drawing truth — selection extents, search offsets — reads the pre-coalesced
  cells.
