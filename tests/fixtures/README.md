# Test fixtures + corpora

Inputs for SolidTerm's tests at every tier.

## Layout

```
font-corpus/     ← script + grapheme edge cases (.txt + .json expected)
vttest/          ← VT100/220/420 corpus (mirrored from xterm upstream)
osc-sequences/   ← real captures of OSC-emitting shells (.bin)
```

## Refresh policy

**Never refresh automatically.** Fixtures are inputs — if expected output changes, that's a decision, not a drift.

| Corpus | How to refresh |
|---|---|
| `font-corpus/` | `scripts/regen-font-corpus.sh` after intentional renderer change. Tests fail until `cargo insta accept` reviews the diff. |
| `vttest/` | Re-fetch from upstream (Thomas Dickey vttest); commit the diff with provenance note in this README. |
| `osc-sequences/` | `scripts/capture-osc.sh <program>` — produces `.bin` + `.meta.json`. Re-run when shell or program updates. |

## Capture provenance discipline

Anything captured (vs. hand-crafted) carries a `<file>.meta.json`:

```json
{
  "captured_at": "2026-04-25T15:00:00+07:00",
  "macos_version": "14.7.1",
  "shell": "zsh 5.9 (arm64-apple-darwin23.6.0)",
  "redacted": true,
  "source_repo": null
}
```

## Storage budget

Estimated sizes after M1: ~30 MB. Plan: ~100 MB by 1.0. Stays under GitHub soft limit.

If a single corpus passes 5 MB we'll move it to Git LFS; recorded in this README on the entry.
