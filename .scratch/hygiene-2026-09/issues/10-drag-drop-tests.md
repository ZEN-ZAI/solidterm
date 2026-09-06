# 10 — Drag-and-drop tests (shellQuote + performDragOperation)

Status: ready-for-agent
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
