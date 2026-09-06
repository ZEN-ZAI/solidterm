# 13 — Split TerminalSurfaceView.swift along its MARKs

Status: ready-for-agent
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
