// MSL pipelines.
//
// Two pipelines coexist:
//
// 1. Stage-0 single-cell pass (`cell_vertex` / `cell_fragment`) — one quad
//    at one cell, used by `CellPipeline.swift`. Survives for the overlay
//    use cases (cursor, IME marked-text underline, selection accents) that
//    arrive in 4.7 / 4.9; explicit single-cell encoding is cheaper than a
//    full-screen pass when only a handful of cells need touching.
//
// 2. Stage-1 grid pass (`grid_vertex` / `grid_fragment`) — one full-screen
//    quad sampling per-cell textures, drives the entire 80×24 (or larger)
//    terminal grid in a single draw call. Used by `GridPipeline.swift`
//    from task 3.9 onward. Fresh code, no third-party copy yet — Alacritty
//    PR #4373 is the architectural inspiration but every line below is
//    written from scratch against Apple's MSL docs.
//
// The framebuffer is .bgra8Unorm_srgb for both passes — `MTLClearColor`
// and the fragment shader outputs are LINEAR; the GPU performs the sRGB
// encode on store. Blending stays in linear space — it avoids muddy
// fonts on dark backgrounds.

#include <metal_stdlib>
using namespace metal;

// ─── Stage 0: single-cell pass ───────────────────────────────────────

struct CellUniforms {
    float2 screenSizePx;   // drawable size in pixels (after backing-scale)
    float2 cellSizePx;     // cell width × height in pixels
    float2 cellOriginPx;   // top-left of the target cell in pixels
    float2 atlasOriginUV;  // atlas sub-rect origin in [0,1] UV space
    float2 atlasSizeUV;    // atlas sub-rect size in [0,1] UV space
    float4 fgColorLinear;  // linear-space foreground (text)
    float4 bgColorLinear;  // linear-space background (cell behind text)
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// The four corners of a unit quad in cell-local space. (0,0) is the cell's
// top-left, (1,1) is its bottom-right. Drawn as a triangle strip so we
// only need four vertices.
constant float2 kQuadCorners[4] = {
    float2(0.0, 0.0),  // top-left
    float2(1.0, 0.0),  // top-right
    float2(0.0, 1.0),  // bottom-left
    float2(1.0, 1.0),  // bottom-right
};

vertex VertexOut cell_vertex(
    uint vid [[vertex_id]],
    constant CellUniforms& u [[buffer(0)]]
) {
    float2 corner = kQuadCorners[vid];

    // Cell-local → pixel space → normalized device coords. NDC has +y up;
    // our cell origin is top-left, so y is inverted.
    float2 px = u.cellOriginPx + corner * u.cellSizePx;
    float2 ndc;
    ndc.x = (px.x / u.screenSizePx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (px.y / u.screenSizePx.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = u.atlasOriginUV + corner * u.atlasSizeUV;
    return out;
}

fragment float4 cell_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> grayAtlas [[texture(0)]],
    constant CellUniforms& u [[buffer(0)]]
) {
    constexpr sampler atlasSampler(
        mag_filter::linear, min_filter::linear,
        mip_filter::nearest, address::clamp_to_edge);

    float alpha = grayAtlas.sample(atlasSampler, in.texCoord).r;
    // Linear-space straight-alpha blend: bg * (1-α) + fg * α.
    return mix(u.bgColorLinear, u.fgColorLinear, alpha);
}

// ─── Stage 1: full-screen grid pass ──────────────────────────────────

struct GridUniforms {
    float2 screenSizePx;       // drawable size in pixels
    float2 cellSizePx;         // uniform cell metrics across the grid
    float2 atlasSizePx;        // grayscale atlas dimensions in pixels
    uint2  gridSizeCells;      // grid columns × rows
    float2 gridOriginPx;       // top-left of the grid in pixels
    float2 colorAtlasSizePx;   // color emoji atlas dimensions in pixels
    // Block-cursor reverse-video (cursor visibility fix). A BLOCK cursor
    // must not paint an opaque quad over the glyph — that hides the
    // character under it. Instead the grid pass, which already samples the
    // glyph, reverse-videos the cursor cell: the cell fills with the cursor
    // colour and the glyph is redrawn in the cell's background colour so it
    // stays readable (standard terminal behaviour: Terminal.app / iTerm2).
    // Only the BLOCK shape uses this; beam / underline stay as overlay
    // quads because they don't cover the glyph. `cursorBlockActive == 0`
    // disables the path entirely (no cursor, beam/underline cursor, hidden,
    // scrolled into history, or blink-off phase), keeping the steady-state
    // render byte-identical to before the fix.
    uint2  cursorCell;         // (col, row) of the block cursor cell
    float4 cursorColorLinear;  // linear-space cursor colour (the fill)
    float  cursorBlockAlpha;   // blink phase 0..1 (1 = full reverse-video)
    uint   cursorBlockActive;  // 1 = reverse-video the cursorCell, 0 = off
};

struct GridVertexOut {
    float4 position [[position]];
};

vertex GridVertexOut grid_vertex(
    uint vid [[vertex_id]]
) {
    // Full-screen quad in NDC: covers [-1, 1]² as a triangle strip.
    constexpr float2 kFullscreen[4] = {
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0),  // top-right
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
    };
    GridVertexOut out;
    out.position = float4(kFullscreen[vid], 0.0, 1.0);
    return out;
}

fragment float4 grid_fragment(
    GridVertexOut in [[stage_in]],
    texture2d<float> grayAtlas         [[texture(0)]],
    texture2d<float> cellFG            [[texture(1)]],
    texture2d<float> cellBG            [[texture(2)]],
    texture2d<float> cellAtlasUV       [[texture(3)]],
    texture2d<float> colorAtlas        [[texture(4)]],
    texture2d<uint>  cellAtlasSelector [[texture(5)]],
    constant GridUniforms& u           [[buffer(0)]]
) {
    // [[position]] is in pixel space (post-viewport). Compute which cell
    // this fragment lies in, then where inside that cell it lies.
    float2 fragPx = in.position.xy - u.gridOriginPx;
    if (fragPx.x < 0.0 || fragPx.y < 0.0) {
        discard_fragment();
    }
    uint2 cell = uint2(fragPx / u.cellSizePx);
    if (cell.x >= u.gridSizeCells.x || cell.y >= u.gridSizeCells.y) {
        discard_fragment();
    }

    // cellAtlasSelector is r16Uint: low byte = atlas selector, high byte =
    // cellSpan (ADR-0003). cellSpan
    // semantics:
    //   - >= 1 : this cell is a primary; its glyph spans `cellSpan` cols
    //   - == 0 : either a blank cell, or a continuation owned by a primary
    //            to its left whose span reaches us
    //
    // To paint a multi-column cluster from a full-screen quad we resolve
    // the *primary* cell that covers this fragment, then sample its atlas
    // entry with a UV span scaled by `cellSpan`. With production data flow
    // at cellSpan=1 everywhere (atomic 3 status), the leftward search exits
    // on first iteration / never finds a covering primary and the math
    // collapses to the pre-r16 path — visual diff vs v0.1.6 is zero.
    // Atomic 4 starts emitting cellSpan >= 2; this code path then begins
    // covering continuation cells.
    uint packedSel = cellAtlasSelector.read(cell).r;
    uint selector = packedSel & 0xFFu;
    uint cellSpan = (packedSel >> 8) & 0xFFu;

    uint2 primary = cell;
    uint primarySpan = cellSpan;
    uint colOffset = 0u;
    if (cellSpan == 0u) {
        // Walk left up to 7 cells looking for a primary whose span reaches
        // this fragment. Bound matches realistic max cluster width (Thai
        // SARA AM compounds, ZWJ family overflow). Loop is effectively dead
        // while production cellSpan == 1 — keeps the cellSpan=1 render
        // byte-identical to pre-r16.
        for (uint k = 1u; k <= 7u && k <= cell.x; ++k) {
            uint2 probe = uint2(cell.x - k, cell.y);
            uint pp = cellAtlasSelector.read(probe).r;
            uint pspan = (pp >> 8) & 0xFFu;
            if (pspan > k) {
                primary = probe;
                primarySpan = pspan;
                selector = pp & 0xFFu;
                colOffset = k;
                break;
            }
            if (pspan != 0u) {
                // Hit another primary that doesn't reach us — stop.
                break;
            }
        }
    }
    if (primarySpan == 0u) {
        // No primary covers this fragment — render the cell's own bg.
        // Equivalent to the pre-r16 blank-cell path (UV=0, alpha=0 → bg).
        primarySpan = 1u;
    }

    float4 fg = cellFG.read(primary);
    float4 bg = cellBG.read(primary);
    float2 atlasOriginUV = cellAtlasUV.read(primary).rg;

    // Atlas glyphs are sized to match `primarySpan * cellW × cellH`; UV
    // span = (primarySpan * cellSize) / atlasSize. For color emoji the
    // atlas dimensions differ from the gray atlas, so the span is computed
    // against the selected atlas's size.
    //
    // The fragment's x within the cluster: (colOffset * cellW) + cellLocalPx.x.
    float2 cellLocalPx = fragPx - float2(cell) * u.cellSizePx;
    float clusterWidthPx = float(primarySpan) * u.cellSizePx.x;
    float localXInCluster = float(colOffset) * u.cellSizePx.x + cellLocalPx.x;
    float2 atlasPx = float2(clusterWidthPx, u.cellSizePx.y);
    float2 selectedAtlasPx = (selector == 0u)
        ? u.atlasSizePx : u.colorAtlasSizePx;
    float2 atlasSpanUV = atlasPx / selectedAtlasPx;
    float2 atlasUV = atlasOriginUV
        + float2(localXInCluster / clusterWidthPx,
                 cellLocalPx.y / u.cellSizePx.y) * atlasSpanUV;

    // Block-cursor reverse-video. When this fragment's *primary* cell is
    // the cursor cell and the block cursor is active, swap the fill and the
    // glyph colour: the cell background becomes the cursor colour and the
    // glyph is redrawn in what was the cell's background colour, so the
    // character under the cursor stays readable (standard reverse-video).
    // We compare against `primary` rather than `cell` so a multi-column
    // cluster whose primary is the cursor cell reverses as a whole; the
    // cursor only ever sits on a primary, so cross-cell continuations of a
    // glyph that starts elsewhere are unaffected.
    //
    // `cursorBlockAlpha` is the CPU-driven blink phase: at 1.0 the cell is
    // fully reversed, and as it falls to 0.0 the appearance fades back to
    // the cell's normal fg-on-bg so the blink animation still reads right.
    // The two `mix`es are unconditional cheap math; the only branch is the
    // cursor-cell test, which is uniform across the cursor cell's fragments.
    bool onCursorCell = (u.cursorBlockActive != 0u)
        && (primary.x == u.cursorCell.x)
        && (primary.y == u.cursorCell.y);
    if (onCursorCell) {
        float a = u.cursorBlockAlpha;
        float4 reversedBg = mix(bg, u.cursorColorLinear, a);
        float4 reversedFg = mix(fg, bg, a);
        bg = reversedBg;
        fg = reversedFg;
    }

    constexpr sampler atlasSampler(
        mag_filter::linear, min_filter::linear,
        mip_filter::nearest, address::clamp_to_edge);

    if (selector == 0u) {
        // Grayscale path — atlas alpha is coverage; tint with fg color.
        // With reverse-video applied above, `fg`/`bg` already carry the
        // cursor-cell swap, so a single `mix` paints the readable glyph.
        float alpha = grayAtlas.sample(atlasSampler, atlasUV).r;
        return mix(bg, fg, alpha);
    } else {
        // Color emoji path — sample RGBA from color atlas. Premultiplied
        // by the rasterizer, so straight-over against bg using its own
        // alpha. No fg tint; emoji carries its own palette. Reversing an
        // emoji's colours isn't meaningful, so under the block cursor we
        // keep the emoji intact and only let the cursor colour show through
        // its transparent margins via the reversed `bg` — the emoji stays
        // visible and the cursor still reads as "here".
        float4 emoji = colorAtlas.sample(atlasSampler, atlasUV);
        return float4(emoji.rgb + bg.rgb * (1.0 - emoji.a), 1.0);
    }
}

// ─── Stage 2: overlay pass (cursor / selection / IME / find) ─────────
//
// One fragment shader, kind-discriminated. 4.7 implements
// kind=0/1/4 (cursor block / beam / underline). 4.5 fills in kind=2
// (selection); 4.9 fills in kind=3 (IME underline).
//
// `kind=4=cursor_underline` extends the original enumeration —
// DECSCUSR has 4 cursor shapes; the design archive only defined
// kind 0/1 for the cursor.
//
// Encoded by `OverlayPipeline.swift` against the same color attachment
// as the Stage-1 grid pass (load=load, no clear) — the overlay sits on
// top of the rendered grid via straight-alpha source-over blending.

struct OverlayUniforms {
    float2 screenSizePx;
    float2 cellOriginPx;
    float2 cellSizePx;
    float4 colorLinear;
    uint   kind;       // 0=cursor_block, 1=cursor_beam, 2=selection,
                       //   3=ime_underline, 4=cursor_underline
    float  alpha;      // CPU-driven blink phase (0..1)
    uint   cellSpanCols;  // 4.5 selection: how many cells wide this quad
                          // is along the x-axis (1 = single-cell, default
                          // for cursor / IME). Vertex shader multiplies
                          // the quad's x-extent by this value so a single
                          // draw call paints a multi-cell row span.
                          // Y-axis stays single-cell — multi-row selections
                          // emit one quad per row.
};

struct OverlayVertexOut {
    float4 position [[position]];
    float2 cellUV;     // [0,1]² within the cell
};

vertex OverlayVertexOut overlay_vertex(
    uint vid [[vertex_id]],
    constant OverlayUniforms& u [[buffer(0)]]
) {
    // Reuse the same cell-local quad pattern as Stage 0; cell-local → NDC.
    // 4.5 selection: stretch the quad's x-extent by `cellSpanCols` so a
    // single draw call paints a multi-cell row span. Single-cell overlays
    // (cursor, IME) leave `cellSpanCols = 1` and behave identically.
    float2 corner = kQuadCorners[vid];
    float spanCols = max(1.0, float(u.cellSpanCols));
    float2 stretched = float2(corner.x * spanCols, corner.y);
    float2 px = u.cellOriginPx + stretched * u.cellSizePx;
    float2 ndc;
    ndc.x = (px.x / u.screenSizePx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (px.y / u.screenSizePx.y) * 2.0;

    OverlayVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    // Pass the unstretched corner so kind=1 (beam) stays anchored to the
    // first cell — cellUV.x ∈ [0, 1] across the cell, not across the span.
    out.cellUV = corner;
    return out;
}

fragment float4 overlay_fragment(
    OverlayVertexOut in [[stage_in]],
    constant OverlayUniforms& u [[buffer(0)]]
) {
    // Premultiplied straight-alpha output; blend state on the pipeline
    // does source-over against the grid pass's stored color.
    float4 c = float4(u.colorLinear.rgb, u.colorLinear.a * u.alpha);
    switch (u.kind) {
        case 0:  // cursor_block: solid rect over the cell.
            return c;
        case 1:  // cursor_beam: left ~12% of cell width (~2px at 16px cell).
            return in.cellUV.x < 0.12 ? c : float4(0);
        case 2:  // selection: solid tint at colorLinear * alpha. The
                  // pipeline's source-over blend composes this on top
                  // of the grid-pass pixels at 0.35 alpha. The 0.35
                  // factor is applied CPU-side via colorLinear.a so the
                  // shader stays kind-agnostic and the same uniform
                  // shape works for cursor / IME.
            return c;
        case 3:  // ime_underline: bottom ~15% of cell height, mirroring
                  // the cursor_underline geometry. Drawn under the
                  // preedit cells in OverlayPipeline so users see a
                  // "this is in-flight typing" cue while the IME holds
                  // marked text.
            return in.cellUV.y > 0.85 ? c : float4(0);
        case 4:  // cursor_underline: bottom ~15% of cell height (~3px at 20px cell).
            return in.cellUV.y > 0.85 ? c : float4(0);
        case 5:  // text_underline (SGR \e[4m): bottom ~8% of cell, thinner than
                  // the IME / cursor underline so it reads as text decoration
                  // rather than a UI cue.
            return in.cellUV.y > 0.92 ? c : float4(0);
        default:
            discard_fragment();
            return float4(0);
    }
}
