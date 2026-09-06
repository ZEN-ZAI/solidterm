# 10 — Drag-and-drop tests (shellQuote + performDragOperation)

Status: done — 2026-09-06
Blocked by: 02
Spec: ../spec.md (D10)

## Steps

1. `app/SolidTermTests/DragDropTests.swift`:
   - `TerminalSurfaceView.shellQuote` (1715): plain path unchanged; spaces, `'`, `$`, backtick, unicode (Thai) quoted so `sh -c "printf %s $quoted"` round-trips — assert against a table of expected strings.
   - `draggingEntered`/`draggingUpdated` (1672/1677) return `.copy` for a pasteboard with file URLs and `[]` otherwise.
   - `performDragOperation` (1682): stub `NSDraggingInfo` (it is a protocol; implement `draggingPasteboard` with `NSPasteboard(name: .init("solidterm-test"))` holding two file URLs, one with a space) → assert the bytes handed to the session (`paste_chunk`) are `'/a/b c' /d/e` + trailing space, via a view attached to a real `TerminalSession` and reading back with `row_text` after the shell echoes, or via a seam that records the outgoing payload (prefer the seam: `internal var dropPayloadSink: ((String) -> Void)?` used only when non-nil).
2. Keep everything `internal`; no behaviour change.

## Verify

`xcodebuild test -only-testing:SolidTermTests/DragDropTests` then the full suite.

## Comments

### 2026-09-06 — landed

One commit: `test(app): pin the Finder drop path before ticket 13 moves it`
(this commit). `app/SolidTermTests/DragDropTests.swift` (7 tests), one test
seam on `TerminalSurfaceView`, and the xcodegen regen that puts the file in
the target. Rust 273 passed / 0 failed; Swift `Executed 479 tests, with 2
tests skipped and 0 failures`.

The seam is step 1's preferred option, `dropPayloadSink`, but declared at
`TerminalSurfaceView.swift:337` beside `rendererForTesting` — not beside the
drop handler where it reads most naturally. Ticket 13 moves lines 1664-1942
wholesale into `TerminalSurfaceView+DragDrop.swift` as a pure move, and an
extension cannot carry a stored property; putting it in that band would have
handed 13 the one line it could not move. It fires *alongside* `feedChunked`
rather than replacing it, so the drop still reaches the PTY and production —
where the sink is nil — is byte-for-byte unchanged.

Where the ticket and the tree disagree, the tree won:

- Step 1 says a plain path is "unchanged". `shellQuote` wraps
  unconditionally: `/tmp/plain` comes back as `'/tmp/plain'`. The table
  asserts that, and `testShellQuoteRoundTripsThroughRealShell` hands every
  quoted form to `/bin/sh` and compares what `printf %s` prints — an
  independent oracle rather than a restatement of the one-line
  implementation.
- Step 1 expects the drop payload `'/a/b c' /d/e` plus a trailing space.
  `performDragOperation` quotes *every* item and joins with a single
  separator, so the payload is `'/a/b c' '/d/e'` with no trailing space.
- Step 1 names `paste_chunk` as the observation point; the drop actually
  calls `feedChunked`, which is the wrapper over `paste_chunk`. The sink sits
  on the payload both would carry.
- The line numbers in step 1 are pre-`swift-format` (ticket 02); the four
  members now sit at 1674/1679/1684/1718 minus the seam's relocation.

The code review found one divergence worth pinning rather than fixing:
`draggingEntered` / `draggingUpdated` test the pasteboard with
`canReadObject(forClasses: [NSURL.self], options: nil)`, which any URL
satisfies, while `performDragOperation` reads with `urlReadingFileURLsOnly`.
A web URL dragged from a browser is therefore promised a copy badge and then
silently declined. `testWebURLIsPromisedACopyThenDeclinedByTheDrop` asserts
the behaviour as it is: it is a cursor-badge cosmetic, no wrong byte reaches
the PTY, and this branch makes no behaviour changes. If it is ever fixed,
that test is the one to update.

Not done here: `isImageFile` (line 1706) is defined in this section and
called by nothing, so it has no test. Removing dead code is not this
ticket's job and no ticket in the map claims it; ticket 13 will move it with
the rest of the section.
