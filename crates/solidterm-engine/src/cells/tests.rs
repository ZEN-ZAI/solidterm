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
    assert_eq!(view.grapheme[0], b' ');
    assert_eq!(&view.grapheme[1..], &[0u8; 31]);
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
    // Bytes 1..32 must be null-padded.
    assert_eq!(&view.grapheme[1..], &[0u8; 31]);
    assert_eq!(view.width, 1);
}

#[test]
fn from_alacritty_cell_wide_char_primary() {
    let mut cell = blank_cell();
    cell.c = '字';
    cell.flags.insert(Flags::WIDE_CHAR);
    let view = CellView::from_alacritty_cell(0, 0, &cell).expect("wide-char primary is emitted");
    assert_eq!(view.width, 2);
    // 字 is U+5B57; UTF-8 = E5 AD 97.
    assert_eq!(&view.grapheme[..3], &[0xe5, 0xad, 0x97]);
    assert_eq!(&view.grapheme[3..], &[0u8; 29]);
}

/// Stacking many combining marks past the 32-byte buffer must never
/// emit a partial UTF-8 sequence: a mark that would straddle the
/// 32-byte boundary is dropped WHOLE. Asserts the invariant (valid
/// UTF-8, bounded, base-then-marks) rather than an exact fit count,
/// so it stays correct regardless of how many zerowidth marks
/// alacritty itself retains. Guards the downstream FFI (bridge.rs
/// `row_text` / `cell_before_cursor`) against a lone lead byte.
#[test]
fn from_alacritty_cell_zerowidth_overflow_stays_valid_utf8() {
    let mut cell = blank_cell();
    cell.c = '\u{0E19}'; // NO NU, 3 bytes
    for _ in 0..20 {
        cell.push_zerowidth('\u{0E4A}'); // MAI TRI tone mark, 3 bytes
    }

    let view =
        CellView::from_alacritty_cell(0, 0, &cell).expect("Thai cluster cell is not a spacer");

    // The buffer up to the first null must be valid UTF-8 — no
    // truncated codepoint at the 32-byte boundary.
    let end = view.grapheme.iter().position(|&b| b == 0).unwrap_or(32);
    assert!(end <= 32, "grapheme must never exceed the 32-byte buffer");
    let s = std::str::from_utf8(&view.grapheme[..end])
        .expect("overflowing zerowidth marks must never leave a partial UTF-8 sequence");
    // Whatever fit is the base consonant followed by whole tone marks.
    let mut chars = s.chars();
    assert_eq!(chars.next(), Some('\u{0E19}'));
    assert!(chars.all(|c| c == '\u{0E4A}'));
    // Only whole 3-byte codepoints are written (no partial at the
    // boundary), and the 32-byte buffer holds strictly more than the
    // old 16-byte one would have — proving the enlargement took hold.
    assert_eq!(end % 3, 0, "only whole 3-byte codepoints may be written");
    assert!(
        end > 16,
        "32-byte buffer must hold more than the old 16-byte limit"
    );
}

/// A subdivision tag flag (🏴 + tag letters + CANCEL TAG) is 28 UTF-8
/// bytes — it overflowed the old 16-byte buffer and rendered as a
/// bare black flag. The 32-byte buffer must carry the whole sequence
/// so the renderer's covering-font path can shape the full flag.
#[test]
fn from_alacritty_cell_subdivision_tag_flag_survives_whole() {
    let mut cell = blank_cell();
    cell.c = '\u{1F3F4}'; // 🏴 WAVING BLACK FLAG, 4 bytes
                          // Scotland: tag letters g,b,s,c,t + CANCEL TAG, each 4 bytes.
    for tag in [
        '\u{E0067}',
        '\u{E0062}',
        '\u{E0073}',
        '\u{E0063}',
        '\u{E0074}',
        '\u{E007F}',
    ] {
        cell.push_zerowidth(tag);
    }
    let view = CellView::from_alacritty_cell(0, 0, &cell).expect("tag-flag cell is not a spacer");
    let end = view.grapheme.iter().position(|&b| b == 0).unwrap_or(32);
    let s = std::str::from_utf8(&view.grapheme[..end]).expect("valid UTF-8");
    assert_eq!(
        s, "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        "the full subdivision tag flag must survive — not truncate to a bare 🏴"
    );
    assert_eq!(
        end, 28,
        "🏴 (4) + 5 tag letters (20) + CANCEL (4) = 28 bytes"
    );
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

    let view =
        CellView::from_alacritty_cell(0, 0, &cell).expect("cell with hyperlink is not a spacer");
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

    let view =
        CellView::from_alacritty_cell(0, 0, &cell).expect("cell with hyperlink is not a spacer");
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

    let view =
        CellView::from_alacritty_cell(0, 0, &cell).expect("cleared-hyperlink cell is not a spacer");
    assert_eq!(view.link, None);
}
