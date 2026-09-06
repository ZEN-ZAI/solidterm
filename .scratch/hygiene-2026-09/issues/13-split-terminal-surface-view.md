# 13 — Split TerminalSurfaceView.swift along its MARKs

Status: done — 2026-09-06
Blocked by: 02, 10
Spec: ../spec.md (D8, D9)

## Target layout (current line ranges)

| New file | Contents | Lines today |
|---|---|---|
| `TerminalSurfaceView.swift` | class decl, stored properties, init/layout, restored-command pre-fill (337), keyDown routing (403), scroll wiring (458) | 1–477 |
| `TerminalSurfaceView+Selection.swift` | keyboard arrow virtual keycodes (478) + mouse/keyboard selection handlers (781) | 478–1403 |
| `TerminalSurfaceView+Pasteboard.swift` | copy / paste (1404) | 1404–1663 |
| `TerminalSurfaceView+DragDrop.swift` | `NSDraggingDestination` (1664) incl. `shellQuote` | 1664–1942 |
| `TerminalSurfaceView+TextInputClient.swift` | `NSTextInputClient` load-bearing (1943) + composition state (2015) | 1943–2380 |
| `TerminalSurfaceView+Links.swift` | ⌘-hover / ⌘-click file path + OSC 8 (2381) | 2381–end |

## Rules

- Pure move: no renames, no reordering inside a section, no comment rewrites beyond the file header.
- Stored properties stay in the main file (extensions cannot add them). `private` members used across the new files become `internal`; count them in the commit message (58 privates today).
- Protocol conformances declared on the class stay on the class; extensions only carry methods.
- Update `app/project.yml`? Not needed — sources are globbed; run `scripts/regen-xcodeproj.sh` and commit the regenerated `.xcodeproj` in the same commit.

## Verify

`xcodebuild test` — all 446+ tests, especially `IMETests`, `CopyPasteTests`, `SelectionInputTests`, `DragDropTests`, `Osc8HoverPolicyTests`.

## Comments

### 2026-09-06 — landed

One commit: `refactor(app): split TerminalSurfaceView along its MARKs` (this
commit). `TerminalSurfaceView.swift` went from 2,555 lines to 620; the five new
files are +Selection 852, +TextInputClient 439, +DragDrop 290, +Pasteboard 268,
+Links 150.

The Target-layout table's line numbers are stale by a constant ~10-15 lines —
earlier hygiene tickets grew the file (2,555 today, 2,540 when the spec's Facts
were gathered). The MARKs themselves still match one-for-one, so the boundaries
were taken from the MARK lines (488, 1415, 1676, 1958, 2395) rather than the
table's numbers, and every section landed in the file the table names.

Pure move, verified mechanically: the multiset of non-blank lines in the six
files equals the original's, except the 31 access-level widenings. Nothing was
reworded, renamed or reordered within a section.

31 access widenings (the Rules ask for the count): 30 of the 58 `private` class
members lost the keyword because they are now read across a file boundary
(28 stay private), plus `compositionState`, whose `private(set)` had to become
settable because `insertText` / `setMarkedText` / `unmarkText` write it from
+TextInputClient.swift. Each one was justified by a real cross-file caller —
references that appear only in comments (`extendSelectionByArrow`,
`autoScrollTick`) were left private.

21 stored instance properties were hoisted back into the main file under a new
`// MARK: stored properties for the split-out extension files`, grouped by the
file each came from and keeping their original order and doc comments. Two
nested types came with them, because their doc comment documents the hoisted
property rather than the type: `PendingSelection` (with `pendingSelection`) and
`MouseGestureOwner` (with `mouseGestureOwner`, and it had to become internal so
the internal property's type is nameable).

Tallies: `cargo test --workspace` 273 passed, 0 failed (207 + 3 + 1 + 1 + 3 + 44
+ 14 across 8 suites); `xcodebuild test` Executed 482 tests, 3 skipped, 0
failures. `osc_10_query_drains_pty_response_queue_without_erroring` flaked once
on the first Rust run (PTY echo, "got 0 bytes from printf") and passed alone and
on the full rerun. Also green: `cargo fmt --all -- --check`, the CI
`swift-format lint --strict` over every non-generated Swift source,
`check-ffi-drift.sh` ("FFI shims in sync" — no bridge change, `Generated/`
untouched), `check-no-analytics.sh`, and the two stub lint scripts.
`scripts/regen-xcodeproj.sh` is idempotent: a second run reproduces the
committed `.xcodeproj` byte-for-byte.

Judgement calls:

- **The split follows the MARKs, not topic.** `scrollWheel` and
  `validateMenuItem` sit between the drag-drop MARK and the NSTextInputClient
  MARK, so they are in +DragDrop.swift; `keyDown` sits after the selection MARK,
  so it is in +Selection.swift; the backing-layer / live-resize overrides follow
  the composition-state MARK, so they are in +TextInputClient.swift. Regrouping
  them by topic would be a refactor, which the Rules forbid.
- **Only the file header was rewritten.** The main file's header gained a
  paragraph saying where each section went; its `spec/…` citations were left for
  ticket 19. The `// MARK: - Input — keyDown routing` block comment still
  describes `keyDown` and `doCommand(by:)`, which now live elsewhere — review
  flagged it, but "no comment rewrites beyond the file header" rules it out
  here, and ticket 19 is the comment-only pass.
- **Nothing was cleaned up on the way past.** `rendererForTesting` and
  `setPendingSelectionForTesting` are now redundant (`renderer` and
  `pendingSelection` are internal), and `compositionState` lost its
  write-protection. Removing either accessor would touch the tests; a pure move
  stays pure.
