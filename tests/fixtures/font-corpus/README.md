# Font corpus

Pre-rendered + post-rendered grapheme test cases. Each `<name>.txt` is the input; `<name>.json` (when shipped) is the expected per-cell grid state after CoreText shaping.

`expected.json` files are added once the renderer exists (Phase 0 Day 3-4 onward). Until then `.txt` files alone exercise the parser + width-detection layer.

## Files

| File | What it covers |
|---|---|
| `latin-ascii.txt` | printable ASCII baseline |
| `latin-extended.txt` | accented Latin + IPA |
| `thai-basic.txt` | common Thai with tone marks + vowel stacking |
| `thai-wordbreak.txt` | Thai paragraph without spaces |
| `cjk-ideograph.txt` | Han / Kana / Hangul mix |
| `cjk-han-unified.txt` | Han unification corner cases |
| `emoji-basic.txt` | single-codepoint emoji |
| `emoji-zwj.txt` | family / profession / flag (ZWJ + regional indicators) |
| `emoji-keycap.txt` | keycap sequences |
| `combining-marks.txt` | NFC vs NFD; Vietnamese; Sanskrit |
| `box-drawing.txt` | unicode line-draw chars |
| `rtl.txt` | Arabic + Hebrew (we don't support RTL — must not crash) |
| `ambiguous-width.txt` | UAX #11 ambiguous (default narrow) |
| `zero-width.txt` | ZWNJ, ZWJ, ZWSP, BOM |
| `control-chars.txt` | C0 + C1 + DEL — must not render |

## Expected.json schema (when added)

```json
{
  "lines": [
    [
      {"grapheme": "a", "width": 1, "fg": "default", "bg": "default", "flags": 0}
    ]
  ]
}
```

## Refresh

Manual edits only. After deliberate renderer changes:
1. `scripts/regen-font-corpus.sh` regenerates `expected.json` from current renderer
2. Review the diff line-by-line
3. `cargo insta accept` once verified
4. Commit fixture + code change in same PR
