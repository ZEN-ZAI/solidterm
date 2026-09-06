# Changelog

All notable changes to SolidTerm are documented here. The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- Closing a window while its shell was flooding output deadlocked the whole app. Root cause: dropping the session on the main thread ran alacritty's `Pty::Drop` inline — SIGHUP plus a blocking `child.wait()` — while the child was parked in `write(2)` on a full kernel PTY buffer, the reader thread was parked sending into the full flood-cap channel, and the only drainer of that channel (`poll_output`, on the main-thread tick) was the thread now sitting in `wait4`. Teardown now runs through `shutdown_detached`: SIGHUP immediately, then a detached thread that drains the reader channel for a 500 ms grace, escalates to SIGKILL, and only then drops — so Swift's last release returns in microseconds and a wedged session can stall only its own teardown thread.
- Everything running in a pane could freeze for as long as the display stayed asleep (a 7.6 h stall of a long-running CLI overnight), then resume the instant the screen came back. Root cause: `poll_output` — the only drain of the bounded PTY reader channel — was reached solely from `draw(update:)`, and macOS stops the `CAMetalDisplayLink` when the display sleeps or the window is fully occluded. The channel filled, the reader thread parked in `send`, the PTY master buffer backed up, and the child blocked in `write()`. A watchdog now drains the engine whenever the link stops ticking, and repaints from a full-frame delta once it resumes.
- A selection drifted off the text it was made on whenever the grid scrolled. Three causes: `update_selection` rebuilt the range from a cached absolute anchor point that output-driven grid rotation invalidated (alacritty rotates its own `Term::selection`, the shadow copy got no such treatment); drag auto-scroll took the moving column from the *bottom* endpoint, which on an upward drag is the anchor; and the painted mirror cached viewport-relative rows and re-synced only on input, so output-driven scrolling left the tint glued to stale screen rows. The anchor is now re-derived from the live selection, auto-scroll follows the pointer, and the mirror re-projects once per encoded frame.
- ⌥/⌘-drag — the documented escape hatch for selecting text over a TUI that has enabled DEC 1000/1002/1003 — started a selection but couldn't extend it, and the release auto-copied a one-cell anchor. `mouseDown` and `mouseUp` honoured the held modifier; `mouseDragged` tested only whether mouse reporting was active. The gesture owner is now decided once at `mouseDown` and held through drag and release, which also stops a modifier pressed or released mid-drag from handing the rest of the gesture to the other side.
- A window title set once by a program reverted to the cwd basename after 500 ms of quiet, so anything that titles itself and then gets on with the job (`\e]2;building\a` before a long build, a shell hook titling at exec time, any TUI that isn't a spinner) silently lost its title mid-run. The recency window existed because the "I'm done with the title" signal never arrived: a child hands the title back with an empty OSC 0/2 payload, which vte parses as `set_title(Some(""))` rather than `Event::ResetTitle`, indistinguishable at the Swift boundary from "no title event this tick". That reset is now latched in the bridge, and the title stays until either it or the child leaving the alternate screen hands it back.

## [0.4.12] — 2026-08-17

The first tagged release since 0.1.0, reconstructed from the 58 commits between them; `dist/SolidTerm-0.4.12.dmg` was built 18 s after the last of them.

### Added
- Window and tab restoration on relaunch, delegated to Apple's `NSWindowRestoration` (layout and working directory only — not live processes, not scrollback), with a Settings ▸ Appearance toggle, default on.
- A durable per-window cwd and command journal alongside restoration: a 5 s sampler reads cwd and foreground command back from the shell pid (`proc_pidinfo`, `KERN_PROCARGS2`) and writes plain JSON to Application Support, off the main thread, so it survives a `kill -9` that the coalesced saved-state blob does not. The recorded command is typed back onto the prompt *without* a trailing newline, so it never re-executes on its own; every C0/C1 control character is rejected both at record time and again before the bytes reach the PTY.
- ⌘⇧O terminal switcher: a fuzzy-filtered overlay across every open window and native tab, matching on title and working directory, with wrap-around ↑/↓ navigation and Return to focus.
- Mouse reporting (DEC 1000/1002/1003 with SGR-1006 and legacy X10 encoding), so click, drag and wheel reach vim, htop and lazygit.
- Paste-jail guard: an embedded `\e[200~` / `\e[201~` is removed from the clipboard before the text is wrapped for a bracketed paste, so pasted content cannot close the paste envelope early and have its tail read as typed input (iTerm2 and Ghostty parity).
- Kitty keyboard protocol support in the encoder: Shift+Enter is sent as `\e[13;2u` when a kitty mode is active, so an editor can tell "submit" from "insert newline"; plain Enter stays a bare `\r`.
- DECCKM (SS3 cursor keys) and focus-event reporting (DECSET 1004), read off the engine's mode bits and acted on by the input path.
- Clickable plain URLs and file paths under ⌘-hover / ⌘-click, not just OSC 8 hyperlinks; `file://` is excluded from the URL allowlist and local paths go through an existence-gated branch that opens the configured editor.
- Option-as-Meta: an opt-in Settings ▸ Keyboard toggle that sends ESC + the base character for readline/emacs/zsh instead of composing an accent.
- SGR underline (`\e[4m`), bold and italic rendering: underline as a coalesced run of overlay quads, bold/italic as per-variant `CTFont`s sharing the existing atlas cache, degrading to plain text on fonts CoreText can't synthesize.
- Scrollbar overlay with fade, hover-grow, and hidden-when-no-history; bell visual flash; cursor blink with sine ease and pause-on-typing.
- Sticky tab titles: an OSC 0/2 title holds the tab for as long as titles keep arriving (a 0.5 s recency window), so a TUI exiting snaps the tab back to the cwd basename; the window subtitle shows the working directory.
- Colour emoji at their proper presentation: scalars with `Emoji_Presentation=Yes` now resolve to Apple Color Emoji even when the monospace face covers them monochrome, and every rasterization path uniformly shrinks a glyph whose ink exceeds its cell box instead of clipping it.
- Grapheme coalescing extended to skin-tone modifiers and generic Unicode marks (Devanagari matras, Arabic/Hebrew diacritics, Vietnamese stacks) on top of Thai / regional-indicator / ZWJ / variation-selector clusters, with the per-cell wire grapheme field grown 16 → 32 bytes so subdivision-flag tags and deep ZWJ families cross the FFI whole.
- Honest capability advertisement: DA1 now answers `\x1b[?62;22c` (VT220 conformance + ANSI colour) instead of alacritty's bare VT102-no-colour reply, and `CSI > q` (XTVERSION) answers with the product name and version.
- Settings: native Form/Section layout, live font preview, theme colour swatches, keybindings grouped by category with a search field, configurable scrollback (0–1 M, default 100 K), a "Reset All Settings" button, and an About panel.
- Right-click context menu (Copy / Paste / Select All / Look Up / Services / Clear Buffer), auto-copy on selection mouseUp, drag-select auto-scroll with tiered cadence, and a theme hot-reload toast.
- App icon: a flat-shaded isometric cube, rendered from `scripts/gen-icon.swift` and downsized to every macOS app-icon size by `scripts/gen-icon.sh`.

### Changed
- Internal identifiers unified under the SolidTerm name. User-visible consequence, accepted as pre-1.0 breakage: preference keys, the shell-integration directory (`~/.config/solidterm/`) and the keybindings path (`~/.solidterm/keybindings.json`) moved, so settings and installed shell integration from an earlier build are orphaned and need re-applying. The shaping kill-switch is `SOLIDTERM_SHAPING`.
- The Command Palette was removed. Its ⌘K binding had been hidden since 2026-05-11 and was never re-enabled; `CommandPaletteAction` became `KeybindingAction` and the Settings ▸ Keybindings tab is the surface that remains.
- The unreachable CLAUDE.md cascade resolver (627 lines, exported but referenced only by its own tests) and its seven dependencies were removed, along with a workspace-wide sweep of declared-but-unused crates and a dead test-util feature.
- The glyph atlas grew 512² → 2048² (4 MiB, far under the 64 MiB ceiling). Each distinct coalesced cluster takes its own two-cell slot, and Thai makes almost every syllable a unique cluster — 512² held about 80 of them, less than one screenful.
- `panic = abort` in the release and dev profiles, so an engine panic is a deterministic abort rather than an unwind across the `extern "C"` boundary; `TerminalSession` records its owner thread at construction and debug-asserts it at every mutating entry point.
- The render-path latency measurement is gated behind `SOLIDTERM_RUN_PERF=1`. Its p99 gate measures GPU/WindowServer scheduling, not correctness, so it flaked whenever the suite ran under load.
- Idle frames no longer encode: a quiescent terminal commits zero command buffers per second while the display link keeps ticking at 120 Hz for keystroke latency.

### Fixed
- Ctrl-C (and the whole Ctrl-A..Z / Ctrl-[ \ ] ^ _ / Ctrl-Space control family) could suddenly stop reaching the foreground program — most visibly, Ctrl-C no longer interrupting a full-screen TUI like Claude. Root cause: an IME composition left orphaned when a ⌘C/⌘V fired mid-preedit kept `hasMarkedText()` permanently true, wedging the keyboard direct-send gate. Control-mapped keys now bypass the IME gate (they're never composition input) and any active composition is cancelled by Copy/Paste/Paste-Plain/Select-All.
- Selecting text in a full-screen TUI and pressing ⌘C typed a literal `c` into the app. `validateMenuItem(copy:)` consulted the engine's selection span, which a constantly-repainting TUI clears on any grid write, so the menu item disabled itself, the key equivalent never fired, and the keystroke fell through to `keyDown`. Copy validation now reads the same Swift mirror `copy(_:)` does, and ⌘-modified keys are never forwarded to the PTY.
- After the find bar or switcher had been opened a few times, AppKit/SwiftUI silently removed the File and Edit submenus from the main menu and every shortcut in them went dead while plain typing still worked. No app code mutates the menu and its identity is unchanged, so the app now re-installs it the instant the File submenu goes missing — within one event cycle, before the next keypress.
- Dismissing the find bar or the switcher could leave the app with no key window at all, killing every keyboard path until another window was clicked. Both non-activating panels now re-key their anchor window on dismiss, guarded so an app-switch dismissal doesn't yank focus back.
- The block cursor was drawn as an opaque overlay quad, hiding the character underneath it. It is now reverse-videoed in the grid pass — the cell fills with the cursor colour and the glyph is redrawn in the cell's background colour — fading back to normal as the blink alpha falls.
- SGR underline never rendered on real terminal content. The `FrameDelta` apply path wrote only GPU textures, so the CPU-side shadow the underline encoder walks stayed blank; the resolved cells are now mirrored into it.
- Dense scripts rendered blank or garbled. A frame resolved every cell's atlas entry before uploading, so placing a later glyph could evict one an earlier-resolved slot still pointed at — the wrong glyph mid-screen, plus a full-frame repaint re-armed every frame. Same-batch entries are now pinned against eviction, and an over-capacity working set renders blank rather than aliasing.
- Colour emoji rendered washed-out. Apple Color Emoji bitmaps are rasterized sRGB-encoded, but the colour atlas was `.rgba8Unorm`, so the shader composited them into a linear background undecoded and the sRGB drawable encoded them a second time. The atlas is now `.rgba8Unorm_srgb`.
- Intermittent tearing and garbled cells under sustained output: the four `.shared` grid cell textures were mutated on the main thread with no frame-in-flight synchronization, so the CPU could overwrite cells the GPU was still sampling. A one-frame-in-flight semaphore now fences every live-texture mutation.
- Text stayed roughly 2× oversized and blurry after a window moved between displays of different backing scale, until a manual resize; the atlas and grid are now rebuilt when the scale actually changes.
- A re-entrant input-source-change notification (re-posted by `discardMarkedText()` through TSM/IMK re-activation) re-scheduled its own observer endlessly and pegged the main thread at 100% CPU — a ~38 h hang was observed. The handler now bails when the input-source ID is unchanged.
- Thai backspace: an over-eager removal made backspace go codepoint-by-codepoint; the handler that takes the trailing tone mark off in one press is back, with the shell-dependent double-type caveat documented inline.
- A reverse (right-to-left or upward) drag dropped both the anchor cell and the cell under the cursor. alacritty trims the boundary cell whose side faces away from the selection body, and swapping the ordered endpoints inverted both sides; the sides are now chosen from the drag direction.
- A wheel scroll left the selection highlight pinned to the old screen rows, and a selection entirely below the viewport painted a stray one-row tint instead of nothing.
- Search returned wrong columns and dropped matches: plain mode searched a separately-lowercased haystack, which shifts byte offsets for characters like K (U+212A) and İ (U+0130). It now searches the text via an escaped case-insensitive regex, skips both wide-char spacer variants, and counts a trailing double-width glyph as two cells.
- Six protocol and input defects found by an adversarial hunt: modified cursor keys dropped their modifier entirely (killing word-motion and shift-extend in an alt-screen editor) and now emit `CSI 1;<mod><final>`; Escape under the kitty protocol reports `\e[27u` instead of a bare `\x1b` that forces timing heuristics; the bracketed-paste marker scrub was single-pass and could be bypassed by re-splicing an end marker across the removal boundary, so it now loops until stable; capability-query replies were flushed only inside the render-pipeline guard, so a TUI blocking on its startup DA round-trip hung behind a blank window; reply write-back went through a bare `write_all` instead of the EAGAIN backoff and could drop an already-dequeued reply; and a decoded OSC 52 clipboard write was dropped at the FFI instead of reaching the pasteboard.
- OSC 10/11/12 colour queries answered with hardcoded constants regardless of the active theme, so a child probing the background to pick light/dark contrast got the wrong answer. The renderer now pushes its resolved fg/bg/cursor across the FFI, applying the exact IEC 61966-2-1 linear→sRGB encode.
- OSC 7 working directories were mishandled three ways: percent-encoded paths (spaces, Thai, emoji) weren't decoded; a path containing a literal `;` was truncated because vte over-splits on it; and percent-encoded control bytes decoded back into raw ESC/CR that bypassed C0 stripping. Decoding now happens before UTF-8 validation, params are rejoined, and control characters are rejected.
- ⌘-hovering a hyperlink while scrolled into scrollback resolved the live tail's row rather than the displayed one.
- OSC 8 hyperlink opens went to `NSWorkspace.open` with no scheme check, while plain-text links already enforced http/https/mailto — a benign-looking link could target `file://`, `ssh://`, or any registered handler. Both paths now share one allowlist gate, and a denied scheme falls through to the detector that sees only the visible row text.
- A `write(2)` to the non-blocking PTY master dropped its unwritten tail on EAGAIN despite an all-or-error contract; it now retries from the write offset. The paste path no longer flips `O_NONBLOCK` on the dup-shared master FD (a latent cross-thread flag race with the reader), and a `kill -STOP`ped child with a full input buffer no longer hangs the UI thread per keystroke — consecutive EAGAIN retries are budgeted at ~250 ms.
- The reader thread pushed into an unbounded channel, so a flooding child grew RSS without bound; it is bounded at 512 chunks (~2 MiB) and the kernel PTY buffer provides standard TTY flow control. Teardown disconnects the receiver *before* joining the thread, since a sender parked on a full channel can't be woken by master EOF. `poll_output` also takes a 1 MiB per-call byte budget so a flood can't wedge the tick thread or pile unbounded events.
- OSC 52 clipboard writes are capped at 1 MiB and OSC 0/2 titles truncated at 4096 bytes on a char boundary, so a hostile child can't push megabytes through the FFI to the pasteboard or the title bar.
- `TerminalSession::new` and the PTY reader spawn are fallible: openpty failure, FD or thread exhaustion, or bad geometry now degrade to an inert surface (nil to Swift) instead of aborting the app.
- Two use-after-frees at the FFI boundary: ARC could release a Rust-owned `RustVec` after its last syntactic use while an `UnsafeBufferPointer` was still reading it, in both frame-delta and search-match decoding. Both reads are now wrapped in `withExtendedLifetime`.
- Malformed or overlong CSI sequences were still acted on — vte's `ignore` flag is now honoured, so they no longer answer XTVERSION or mutate `modifyOtherKeys`.
- Engine-only edits silently never reached the built app: the "Build Rust core" prebuild phase declared inputs from one crate only, so Xcode skipped it and the app linked a stale static library. The phase now always runs and relies on cargo's own incremental tracking.
- The fish shell-integration guard used `exit`, which in a sourced file terminates the interactive shell — re-sourcing after editing `config.fish` killed the session. It uses `return` now, and the legacy-era state variable names were renamed to `_SOLIDTERM_*` with the old names still honoured so a pre-rename install can't double-register hooks mid-session.
- Closing a window with the find bar open orphaned the floating panel on screen and leaked its global event monitor; the switcher could be left with no window to return focus to; and a stale dismiss task could hide a toast a newer one had just presented.
- Long pastes froze the UI (non-blocking PTY write plus a chunker that re-queues on EAGAIN), ⌘N/⌘T didn't inherit the cwd when OSC 7 wasn't wired (`proc_pidinfo` fallback), a second ⌘F raced its own dismissal, and the right-click menu silently did nothing.
- The glyph atlas 64 MiB ceiling was checked against grey bytes only on one of the two placement paths, and an eviction left cells showing stale UVs until the next scroll — evictions now force a full-frame repaint.

## [0.1.0] — 2026-05-17 — initial release

First SolidTerm build: a native macOS terminal on alacritty_terminal + Metal.

### What works
- PTY + VT parsing via alacritty
- Metal renderer (Stack A) with cross-cell shaping for Thai, flag pairs, ZWJ overflow, variation selectors
- Color emoji (Apple Color Emoji) at 2-cell width — fixed emoji UV 2× scaling
- IME (Thai + CJK), keyboard input, mouse, drag-drop file paths
- Themes (TOML), font config, theme hot-reload
- Search (regex scrollback)
- Shell integration: OSC 7, OSC 133 (zsh/bash/fish)
- Command palette, look-up popover

### Stats
- 3 Rust crates, 195 + 13 unit tests pass
- 63 Swift sources, 320 XCTest tests pass
- Bundle: `com.zenzai.SolidTerm`, product `SolidTerm`

[Unreleased]: https://github.com/ZEN-ZAI/solidterm/compare/v0.4.12...HEAD
[0.4.12]: https://github.com/ZEN-ZAI/solidterm/compare/v0.1.0...v0.4.12
[0.1.0]: https://github.com/ZEN-ZAI/solidterm/releases/tag/v0.1.0
