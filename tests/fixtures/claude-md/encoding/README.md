# Encoding fixtures

CLAUDE.md files in different encodings — loader normalizes to UTF-8 + LF.

| File | Encoding |
|---|---|
| `utf8-no-bom.md` | UTF-8, LF (canonical) |
| `utf8-bom.md` | UTF-8 with BOM (U+FEFF prefix) — loader strips |
| `crlf.md` | UTF-8, CRLF — loader normalises to LF |
| `utf16-le.md` | UTF-16 LE with BOM — loader transcodes (or rejects with clear error) |

Generate the binary variants with `scripts/regen-encoding-fixtures.sh` (uses `iconv` + `printf`). They're not committed as plain text because editors will mangle them; produced on demand.
