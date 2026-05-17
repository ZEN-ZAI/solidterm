//! Implements spec/m1-task-breakdown.md §1.7 — `CellView`, the
//! engine-side cell snapshot returned by
//! [`crate::TerminalEngine::viewport_cells`]. Mirrors
//! `nextterm_ffi::CellDeltaWire`'s 32-byte wire layout
//! (`spec/ffi-boundary.md` + #13) so the engine→FFI transcode is
//! mechanical when 1.8+ wires the bridge.
//!
//! Wide-char handling: alacritty stores wide characters as TWO grid
//! cells — a primary cell with `Flags::WIDE_CHAR` set carrying the
//! actual `char`, plus a continuation cell with `Flags::WIDE_CHAR_SPACER`
//! holding a placeholder space. We emit only the primary, with
//! `width = 2`. Callers walk the returned `Vec<CellView>` row-major
//! and use `width` to advance their cursor, so the col gap (e.g. 5,
//! 7 for a wide char at col 5) is unambiguous.
//!
//! `LEADING_WIDE_CHAR_SPACER` covers the case where a wide char would
//! straddle the rightmost column: alacritty places a leading-spacer
//! at column N-1 of the wrap origin and the actual wide char at
//! column 0 of the next line. We skip both spacer variants.
//!
//! Color resolution: `vte::ansi::Color` is a 3-variant enum (Spec /
//! Named / Indexed). We pre-resolve to R8G8B8A8 u32 at the engine
//! using a hardcoded fallback palette — theme-aware resolution
//! lands at M2 when the renderer's palette protocol is defined.
//! Renderers can detect the Named-Foreground sentinel `0xffffffff`
//! and Named-Background sentinel `0x000000ff` if they want to override
//! with a theme; M1 doesn't bake that contract in.
//!
//! Hyperlinks (OSC 8): alacritty's `vte::ansi` parser handles OSC 8
//! end-to-end and stamps `cursor.template.hyperlink` so subsequent
//! printed cells carry the link reference on `Cell::hyperlink()`.
//! We surface that as `CellView.link: Option<Hyperlink>` — a small
//! owned `{ id, uri }` pair cloned out of alacritty's `Arc`-shared
//! `Hyperlink`. Cells outside an OSC 8 open/close pair carry `None`.
//! The closing form `OSC 8 ; ; ST` (empty id + empty URI) clears the
//! template; later cells emit `None` again. This task only surfaces
//! the annotation in engine-side `CellView`; the FFI wire layout
//! (`CellDeltaWire`, 32 bytes) is unchanged at task 2.4 — propagating
//! hyperlinks across the bridge lands when the renderer needs to
//! display them.

use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::vte::ansi::{Color, NamedColor};

/// Engine-side hyperlink annotation cloned from alacritty's
/// `term::cell::Hyperlink` (which is `Arc<HyperlinkInner>` upstream).
/// Owned `String`s — each cell carrying a link incurs two heap clones,
/// but only when a link is actually present (the common no-link path
/// hits `None` and pays nothing).
///
/// `id` is the OSC 8 correlation id. The upstream parser
/// (`vte-0.15/src/ansi.rs:1413`) strips the `id=` prefix from the
/// `key=value:key=value` link-params slot before constructing the
/// `Hyperlink`; if no `id=` was supplied alacritty generates a
/// `<counter>_alacritty` synthetic id (`alacritty_terminal-0.26/src/term/cell.rs:90`)
/// so the field is always non-empty. Renderers should treat it as
/// opaque correlation data, not as user-presentable text.
///
/// `uri` is the resource identifier verbatim from the escape (any `;`
/// inside the URI is rebuilt by the upstream parser before reaching
/// the handler — see `vte-0.15/src/ansi.rs:1396-1403`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hyperlink {
    pub id: String,
    pub uri: String,
}

/// Engine-internal viewport cell snapshot. Field order matches
/// `nextterm_ffi::CellDeltaWire` for mechanical transcode.
///
/// `grapheme` is UTF-8, null-padded, truncated at 16 bytes. The 16-byte
/// buffer covers Thai 3-component clusters (consonant + upper vowel +
/// tone, 9 bytes — `เพื่อน` pattern), Devanagari conjuncts up to 4
/// codepoints, and short emoji ZWJ sequences. Deep ZWJ clusters (e.g.
/// 👨‍👩‍👧‍👦 at 25 bytes) still truncate; a variable-length cluster
/// side-channel is the future-proof fix tracked in tech-debt. The
/// truncation matches `CellDeltaWire::new`'s `len.min(16)`, so picking
/// `[u8; 16]` here doesn't lose information the FFI boundary wouldn't
/// discard anyway.
///
/// `fg` / `bg` are R8G8B8A8-packed u32 (high byte = R, low byte = A);
/// resolution uses a hardcoded fallback palette at M1. M2 introduces
/// theme-aware resolution.
///
/// `attrs` is alacritty's `cell::Flags` u16 verbatim — `BOLD`,
/// `ITALIC`, `UNDERLINE`, `INVERSE`, `STRIKEOUT`, `DIM`, `HIDDEN`,
/// underline variants, etc. (`term/cell.rs:15` upstream).
///
/// `width` is 1 for single-width cells and 2 for the primary cell of
/// a wide character. Continuation cells (`WIDE_CHAR_SPACER` /
/// `LEADING_WIDE_CHAR_SPACER`) are skipped from the output Vec, so
/// `width = 0` does not appear in `CellView` instances returned from
/// `viewport_cells`.
///
/// `link` carries the OSC 8 hyperlink annotation set by the shell
/// (`Some(Hyperlink { id, uri })` for cells printed between an open
/// and close OSC 8 pair, `None` otherwise). The upstream alacritty
/// `Term::set_hyperlink` writes the link onto `cursor.template`; every
/// printed cell inherits that template, so this field tracks the
/// active link state on a per-cell basis.
///
/// Note: `CellView` is no longer `Copy + Eq` because `link: Option<Hyperlink>`
/// owns heap strings. Existing callers either inspect individual fields
/// (`row`, `col`, `grapheme`, `attrs`, …) or iterate by reference, so
/// dropping the auto-`Copy` bound is non-breaking inside the engine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellView {
    pub row: u16,
    pub col: u16,
    pub grapheme: [u8; 16],
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub width: u8,
    pub link: Option<Hyperlink>,
}

impl CellView {
    /// Build a `CellView` from an alacritty `Cell` at viewport
    /// position `(row, col)`. Returns `None` if the cell is a
    /// wide-char continuation (`WIDE_CHAR_SPACER` or
    /// `LEADING_WIDE_CHAR_SPACER`); callers iterate column indices
    /// and skip `None` results.
    pub(crate) fn from_alacritty_cell(row: u16, col: u16, cell: &Cell) -> Option<Self> {
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            return None;
        }

        let width = if cell.flags.contains(Flags::WIDE_CHAR) {
            2
        } else {
            1
        };

        let grapheme = encode_grapheme(cell);
        let fg = encode_color(cell.fg, ColorRole::Foreground);
        let bg = encode_color(cell.bg, ColorRole::Background);
        let attrs = cell.flags.bits();
        // `Cell::hyperlink()` clones the upstream `Arc<HyperlinkInner>`
        // (cheap atomic refcount bump). We immediately dismantle it
        // into our owned `Hyperlink { id, uri }` form so callers don't
        // need to depend on alacritty's typed wrapper.
        let link = cell.hyperlink().map(|h| Hyperlink {
            id: h.id().to_owned(),
            uri: h.uri().to_owned(),
        });

        Some(Self {
            row,
            col,
            grapheme,
            fg,
            bg,
            attrs,
            width,
            link,
        })
    }
}

/// Pack `cell.c` plus any `cell.zerowidth()` characters into the
/// 8-byte UTF-8 buffer, null-padded and truncated.
fn encode_grapheme(cell: &Cell) -> [u8; 16] {
    let mut out = [0u8; 16];
    let mut written = 0usize;

    let mut buf = [0u8; 4];
    let primary = cell.c.encode_utf8(&mut buf);
    let n = primary.len().min(16 - written);
    out[written..written + n].copy_from_slice(&primary.as_bytes()[..n]);
    written += n;

    if let Some(zerowidth) = cell.zerowidth() {
        for zw in zerowidth {
            if written >= 16 {
                break;
            }
            let mut zw_buf = [0u8; 4];
            let zw_str = zw.encode_utf8(&mut zw_buf);
            let n = zw_str.len().min(16 - written);
            out[written..written + n].copy_from_slice(&zw_str.as_bytes()[..n]);
            written += n;
        }
    }

    out
}

/// Whether a color slot is the foreground or background. Used to pick
/// the right `NamedColor::Foreground` / `Background` sentinel when
/// resolving Named colors against the fallback palette.
#[derive(Clone, Copy)]
enum ColorRole {
    Foreground,
    Background,
}

/// Resolve `Color` to R8G8B8A8 packed u32 using the M1 fallback
/// palette. Spec is trivial; Indexed uses the xterm-256color table;
/// Named maps to the standard xterm defaults plus
/// Foreground/Background sentinels (`0xffffffff` / `0x000000ff`) the
/// renderer can override at M2.
fn encode_color(color: Color, role: ColorRole) -> u32 {
    match color {
        Color::Spec(rgb) => pack_rgba(rgb.r, rgb.g, rgb.b),
        Color::Indexed(idx) => {
            let rgb = XTERM_256_PALETTE[idx as usize];
            pack_rgba(rgb.0, rgb.1, rgb.2)
        }
        Color::Named(named) => encode_named(named, role),
    }
}

const fn pack_rgba(r: u8, g: u8, b: u8) -> u32 {
    ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | 0xff
}

/// Encode `NamedColor` against the standard xterm fallback palette.
/// Foreground/Background use sentinel values renderers can override
/// at M2; the 8 ANSI colors + their Bright variants use xterm
/// defaults.
fn encode_named(named: NamedColor, role: ColorRole) -> u32 {
    match named {
        NamedColor::Foreground => 0xffff_ffff, // white opaque sentinel
        NamedColor::Background => 0x0000_00ff, // black opaque sentinel
        // matcha palette (zenzai-v2 themes/matcha.toml — green-tinted dark).
        NamedColor::Black | NamedColor::DimBlack => pack_rgba(0x2a, 0x34, 0x24),
        NamedColor::Red => pack_rgba(0xd4, 0x70, 0x70),
        NamedColor::Green => pack_rgba(0xa8, 0xcc, 0x8c),
        NamedColor::Yellow => pack_rgba(0xd4, 0xc0, 0x78),
        NamedColor::Blue => pack_rgba(0x68, 0x98, 0xb0),
        NamedColor::Magenta => pack_rgba(0xb8, 0x90, 0xa8),
        NamedColor::Cyan => pack_rgba(0x70, 0xb8, 0xa0),
        NamedColor::White => pack_rgba(0xc8, 0xd0, 0xb8),
        NamedColor::BrightBlack => pack_rgba(0x3a, 0x4a, 0x34),
        NamedColor::BrightRed => pack_rgba(0xe8, 0x88, 0x88),
        NamedColor::BrightGreen => pack_rgba(0xb8, 0xdc, 0xa0),
        NamedColor::BrightYellow => pack_rgba(0xe8, 0xd8, 0x90),
        NamedColor::BrightBlue => pack_rgba(0x80, 0xb0, 0xc8),
        NamedColor::BrightMagenta => pack_rgba(0xd0, 0xa8, 0xc0),
        NamedColor::BrightCyan => pack_rgba(0x88, 0xd0, 0xb8),
        NamedColor::BrightWhite => pack_rgba(0xd8, 0xe0, 0xcc),
        // Dim variants derived at ~50% lightness from the matcha hues.
        NamedColor::DimRed => pack_rgba(0x6a, 0x38, 0x38),
        NamedColor::DimGreen => pack_rgba(0x54, 0x66, 0x46),
        NamedColor::DimYellow => pack_rgba(0x6a, 0x60, 0x3c),
        NamedColor::DimBlue => pack_rgba(0x34, 0x4c, 0x58),
        NamedColor::DimMagenta => pack_rgba(0x5c, 0x48, 0x54),
        NamedColor::DimCyan => pack_rgba(0x38, 0x5c, 0x50),
        NamedColor::DimWhite | NamedColor::Cursor => pack_rgba(0x64, 0x68, 0x5c),
        NamedColor::BrightForeground | NamedColor::DimForeground => match role {
            ColorRole::Foreground => 0xffff_ffff,
            ColorRole::Background => 0x0000_00ff,
        },
    }
}

/// Standard xterm 6×6×6 RGB cube step values for palette indices
/// 16-231. Hoisted to module scope to satisfy clippy's
/// `items_after_statements` lint inside the const-fn build.
const XTERM_CUBE_STEPS: [u8; 6] = [0, 95, 135, 175, 215, 255];

/// Standard xterm 256-color palette, encoded as `(r, g, b)` triples.
/// Indexes 0-15 mirror the 8 ANSI + 8 bright colors (overlap with
/// `NamedColor` mappings); 16-231 form the 6×6×6 RGB cube; 232-255
/// are the grayscale ramp.
const XTERM_256_PALETTE: [(u8, u8, u8); 256] = {
    let mut palette = [(0u8, 0u8, 0u8); 256];

    // 0-15: matcha palette (matches `encode_named` above).
    palette[0] = (0x2a, 0x34, 0x24);
    palette[1] = (0xd4, 0x70, 0x70);
    palette[2] = (0xa8, 0xcc, 0x8c);
    palette[3] = (0xd4, 0xc0, 0x78);
    palette[4] = (0x68, 0x98, 0xb0);
    palette[5] = (0xb8, 0x90, 0xa8);
    palette[6] = (0x70, 0xb8, 0xa0);
    palette[7] = (0xc8, 0xd0, 0xb8);
    palette[8] = (0x3a, 0x4a, 0x34);
    palette[9] = (0xe8, 0x88, 0x88);
    palette[10] = (0xb8, 0xdc, 0xa0);
    palette[11] = (0xe8, 0xd8, 0x90);
    palette[12] = (0x80, 0xb0, 0xc8);
    palette[13] = (0xd0, 0xa8, 0xc0);
    palette[14] = (0x88, 0xd0, 0xb8);
    palette[15] = (0xd8, 0xe0, 0xcc);

    // 16-231: 6×6×6 RGB cube using XTERM_CUBE_STEPS.
    let mut idx = 16;
    let mut r = 0;
    while r < 6 {
        let mut g = 0;
        while g < 6 {
            let mut b = 0;
            while b < 6 {
                palette[idx] = (
                    XTERM_CUBE_STEPS[r],
                    XTERM_CUBE_STEPS[g],
                    XTERM_CUBE_STEPS[b],
                );
                idx += 1;
                b += 1;
            }
            g += 1;
        }
        r += 1;
    }

    // 232-255: 24-step grayscale ramp. `g` is bounded < 24 so the
    // `g as u8` cast is unreachable as a truncation in practice;
    // const-fn doesn't permit `try_from` so we accept the lint with
    // an explicit allow + rationale.
    let mut g: u8 = 0;
    while g < 24 {
        let level = 8 + g * 10;
        palette[232 + g as usize] = (level, level, level);
        g += 1;
    }

    palette
};

#[cfg(test)]
mod tests {
    use super::{encode_color, pack_rgba, CellView, ColorRole, Hyperlink, XTERM_256_PALETTE};
    use alacritty_terminal::term::cell::{Cell, Flags, Hyperlink as AlacrittyHyperlink};
    use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};

    fn blank_cell() -> Cell {
        Cell::default()
    }

    #[test]
    fn from_alacritty_cell_blank() {
        let cell = blank_cell();
        let view = CellView::from_alacritty_cell(0, 0, &cell).expect("blank cell is not a spacer");
        assert_eq!(view.row, 0);
        assert_eq!(view.col, 0);
        assert_eq!(view.grapheme, *b" \0\0\0\0\0\0\0\0\0\0\0\0\0\0\0");
        assert_eq!(view.width, 1);
        assert_eq!(view.attrs, 0);
        // Default cell uses NamedColor::Foreground / Background.
        assert_eq!(view.fg, 0xffff_ffff);
        assert_eq!(view.bg, 0x0000_00ff);
        assert_eq!(
            view.link, None,
            "default cell carries no OSC 8 hyperlink annotation"
        );
    }

    #[test]
    fn from_alacritty_cell_ascii() {
        let mut cell = blank_cell();
        cell.c = 'X';
        let view = CellView::from_alacritty_cell(2, 5, &cell).expect("ASCII cell is not a spacer");
        assert_eq!(view.row, 2);
        assert_eq!(view.col, 5);
        assert_eq!(&view.grapheme[..1], b"X");
        // Bytes 1..16 must be null-padded.
        assert_eq!(&view.grapheme[1..], &[0u8; 15]);
        assert_eq!(view.width, 1);
    }

    #[test]
    fn from_alacritty_cell_wide_char_primary() {
        let mut cell = blank_cell();
        cell.c = '字';
        cell.flags.insert(Flags::WIDE_CHAR);
        let view =
            CellView::from_alacritty_cell(0, 0, &cell).expect("wide-char primary is emitted");
        assert_eq!(view.width, 2);
        // 字 is U+5B57; UTF-8 = E5 AD 97.
        assert_eq!(&view.grapheme[..3], &[0xe5, 0xad, 0x97]);
        assert_eq!(&view.grapheme[3..], &[0u8; 13]);
    }

    #[test]
    fn from_alacritty_cell_wide_char_spacer_returns_none() {
        let mut cell = blank_cell();
        cell.flags.insert(Flags::WIDE_CHAR_SPACER);
        let view = CellView::from_alacritty_cell(0, 1, &cell);
        assert!(
            view.is_none(),
            "WIDE_CHAR_SPACER continuation cells must be skipped"
        );

        let mut cell = blank_cell();
        cell.flags.insert(Flags::LEADING_WIDE_CHAR_SPACER);
        let view = CellView::from_alacritty_cell(0, 79, &cell);
        assert!(
            view.is_none(),
            "LEADING_WIDE_CHAR_SPACER cells must be skipped"
        );
    }

    #[test]
    fn from_alacritty_cell_attrs_round_trip() {
        let mut cell = blank_cell();
        cell.c = 'B';
        cell.flags.insert(Flags::BOLD | Flags::ITALIC);
        let view = CellView::from_alacritty_cell(0, 0, &cell).expect("ASCII cell is not a spacer");
        assert_eq!(
            view.attrs,
            (Flags::BOLD | Flags::ITALIC).bits(),
            "attrs must mirror cell.flags.bits() verbatim"
        );
    }

    #[test]
    fn encode_color_spec_packs_rgba() {
        let color = Color::Spec(Rgb {
            r: 0x12,
            g: 0x34,
            b: 0x56,
        });
        let packed = encode_color(color, ColorRole::Foreground);
        assert_eq!(packed, 0x12_34_56_ff);
    }

    #[test]
    fn encode_color_indexed_uses_palette() {
        // Index 9 is BrightRed; matcha `#e88888`.
        let packed = encode_color(Color::Indexed(9), ColorRole::Foreground);
        let expected = pack_rgba(0xe8, 0x88, 0x88);
        assert_eq!(packed, expected);
        // Sanity: the constant table itself is correctly populated.
        assert_eq!(XTERM_256_PALETTE[9], (0xe8, 0x88, 0x88));
        // Index 16 starts the 6×6×6 cube at (0, 0, 0).
        assert_eq!(XTERM_256_PALETTE[16], (0, 0, 0));
        // Index 21 is (0, 0, 255) — the bottom-corner blue.
        assert_eq!(XTERM_256_PALETTE[21], (0, 0, 255));
        // Index 232 is the first grayscale step (8, 8, 8).
        assert_eq!(XTERM_256_PALETTE[232], (8, 8, 8));
    }

    #[test]
    fn encode_color_named_uses_sentinels_for_default_slots() {
        assert_eq!(
            encode_color(Color::Named(NamedColor::Foreground), ColorRole::Foreground),
            0xffff_ffff
        );
        assert_eq!(
            encode_color(Color::Named(NamedColor::Background), ColorRole::Background),
            0x0000_00ff
        );
    }

    /// A cell stamped with an alacritty `Hyperlink` (the same shape
    /// `Term::set_hyperlink` writes onto `cursor.template` after an
    /// OSC 8 open) round-trips through `CellView` as a populated
    /// `link` field. Both `id` and `uri` survive the conversion to
    /// our owned `Hyperlink` struct.
    #[test]
    fn from_alacritty_cell_with_hyperlink_populates_link() {
        let mut cell = blank_cell();
        cell.c = 'L';
        cell.set_hyperlink(Some(AlacrittyHyperlink::new(
            Some("anchor-1"),
            "https://example.com/path".to_string(),
        )));

        let view = CellView::from_alacritty_cell(0, 0, &cell)
            .expect("cell with hyperlink is not a spacer");
        assert_eq!(
            view.link,
            Some(Hyperlink {
                id: "anchor-1".to_string(),
                uri: "https://example.com/path".to_string(),
            })
        );
    }

    /// A hyperlink without an explicit `id=` correlates via alacritty's
    /// synthetic `<counter>_alacritty` id (`term/cell.rs:90`); the URI
    /// is what matters end-to-end. The id is non-empty but otherwise
    /// opaque, so we assert on the URI exactly and on the `_alacritty`
    /// suffix loosely.
    #[test]
    fn from_alacritty_cell_hyperlink_without_explicit_id() {
        let mut cell = blank_cell();
        cell.c = 'A';
        cell.set_hyperlink(Some(AlacrittyHyperlink::new(
            None::<&str>,
            "file:///tmp/readme.md".to_string(),
        )));

        let view = CellView::from_alacritty_cell(0, 0, &cell)
            .expect("cell with hyperlink is not a spacer");
        let link = view.link.expect("link must be populated");
        assert_eq!(link.uri, "file:///tmp/readme.md");
        assert!(
            link.id.ends_with("_alacritty"),
            "synthetic id must follow the upstream `<counter>_alacritty` form, got {:?}",
            link.id,
        );
    }

    /// `set_hyperlink(None)` clears the annotation; the resulting cell
    /// has no extra storage and `CellView.link == None`.
    #[test]
    fn from_alacritty_cell_hyperlink_cleared_yields_none() {
        let mut cell = blank_cell();
        cell.c = 'X';
        cell.set_hyperlink(Some(AlacrittyHyperlink::new(
            Some("id-1"),
            "https://example.com".to_string(),
        )));
        cell.set_hyperlink(None);

        let view = CellView::from_alacritty_cell(0, 0, &cell)
            .expect("cleared-hyperlink cell is not a spacer");
        assert_eq!(view.link, None);
    }
}
