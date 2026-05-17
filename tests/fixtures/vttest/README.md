# vttest corpus

VT100 / VT220 / VT420 test sequences. Source: [Thomas Dickey's vttest](https://invisible-island.net/vttest/) — freely redistributable.

**Not committed yet** — fetch + transform pending.

## How to seed

```bash
# 1. Fetch upstream
curl -L https://invisible-island.net/datafiles/release/vttest.tar.gz | tar xz
cd vttest-*/

# 2. Build (produces `vttest` binary that emits sequences interactively)
./configure && make

# 3. Capture each menu section's input + expected
./scripts/capture-vttest.sh \
  --section "1: Test of cursor movements" \
  --output ../tests/fixtures/vttest/cursor-movement/

# (capture-vttest.sh records the byte stream vttest sends to the terminal
#  AND captures what xterm renders to compare against)

# 4. Diff our renderer vs xterm — investigate failures
```

## Layout (planned)

```
vttest/
├── cursor-movement/      ← CSI A/B/C/D, CUP, SCP
├── editing/              ← IL, DL, ICH, DCH
├── screen/               ← ED, EL, DECOM, DECSC/DECRC
├── charset/              ← SCS, NRCS
├── cmp/                  ← compatibility sweep
├── keyboard/             ← CSI u + modifyOtherKeys replies
└── README.md             ← this file
```

Each subdirectory: `input.bin` (sequences fed to engine) + `expected.txt` (ASCII rendering of expected grid) + `expected.json` (cursor + mode state).

## Pass target (M1 exit gate)

≥ 90 % of in-scope cases (cursor + editing + screen + charset). `keyboard/` tested via round-trip: we emit, capture our bytes, compare.

## License note

vttest is "freely redistributable" per Dickey's terms. Add `LICENSE.vttest` to this directory when committing transformed corpus files. Source attribution in this README.

## Refresh

When upstream vttest releases:
1. Re-fetch + re-build
2. Re-capture (xterm output may have changed)
3. Diff against our committed expected.* and update intentionally

Pinned: vttest-`<version>`-`<sha>` in this README.
