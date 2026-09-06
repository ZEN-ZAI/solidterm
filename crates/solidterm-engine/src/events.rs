//! Implements spec/m1-task-breakdown.md §1.8 — `EngineEvent`,
//! `EventProxy`, and the engine-side event bus.
//!
//! Two event sources merge into one `crossbeam_channel::Receiver`
//! exposed via [`crate::TerminalEngine::drain_events`]:
//!
//! 1. **`alacritty_terminal::Term`** fires events through the
//!    `EventListener` trait (`event.rs:103-105` upstream — single
//!    `fn send_event(&self, _event: Event)` method, all variants
//!    flow through one channel). Our [`EventProxy`] implements this
//!    trait and translates each `Event` into an `EngineEvent`.
//!
//! 2. **`alacritty_terminal::Pty`** surfaces child-process exit via
//!    `EventedPty::next_child_event` (`tty/mod.rs:96`). `Term` does
//!    NOT fire `Event::ChildExit` — that variant is vestigial in the
//!    upstream enum (defined but never sent through `send_event`).
//!    Engine polls `next_child_event` inline in `poll_output` and
//!    forwards to the same channel.
//!
//! Variant scope: M1 ships the 9 variants below. Deferred to later
//! atomics:
//! - `TextAreaSizeRequest` — XTWINOPS `CSI 14 t` (text-area pixels)
//!   carries a `WindowSize`-keyed formatter; cell pixel dims live on
//!   the Swift renderer side, not in the engine. Defer.
//! - `Exit` — alacritty's "shutdown request" CSI; different from
//!   `ChildExited`. Defer.
//!
//! `PtyWrite(String)` IS handled in M1 (#73, task 2.10): the proxy
//! queues the formatted bytes onto the same `pty_responses`
//! `Sender<String>` OSC 10/11/12 uses, and `poll_output` writes them
//! back to the PTY master FD. Today's sole producer is
//! `text_area_size_chars` (`CSI 18 t` / XTWINOPS rows-cols query)
//! which alacritty formats directly as `\x1b[8;rows;cols t`. Future
//! producers (DECRQSS, DCS responses) reuse the same path.
//!
//! `ColorRequest` (OSC 10/11/12 query) IS handled in M1 (#71, task 2.5):
//! the proxy looks up the queried index against a hardcoded Zenzai Dark
//! palette, invokes alacritty's response formatter to build the OSC
//! reply, and pushes the formatted bytes onto a separate
//! `Sender<String>` (`pty_responses`) that the engine drains in
//! [`crate::TerminalEngine::poll_output`] and writes back to the PTY
//! master FD. This is **not** an `EngineEvent` — consumers don't see
//! the reply; it goes straight back to the shell so it can use the
//! current fg/bg/cursor colors (e.g. vim's `'background'` detection).
//! The set form (`OSC 10 ; rgb:RR/GG/BB`) is handled by alacritty's
//! `set_color` which mutates Term's internal palette; we don't need
//! to do anything additional. M1 ships fg/bg/cursor only; theming
//! lands in M5 with a real `ThemeManager`.

use alacritty_terminal::event::{Event as AlacrittyEvent, EventListener};
use alacritty_terminal::term::ClipboardType;
use alacritty_terminal::vte::ansi::{NamedColor, Rgb};
use crossbeam_channel::Sender;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

/// Cap on the DECODED OSC 52 payload we retain and forward. A hostile
/// child can emit megabytes of base64 in one sequence; alacritty has
/// already decoded it by the time we see the String (that transient
/// allocation is alacritty-internal and freed immediately), so the cap
/// bounds what we LATCH in the FFI layer and push to `NSPasteboard` —
/// not the one-shot decode. 1 MiB is far above any legitimate copy.
const OSC52_MAX_DECODED_BYTES: usize = 1 << 20;

/// Upper bound on an OSC 0/2 window-title payload. A title is only ever
/// shown in tab/window chrome, so a few KiB is generous; capping stops a
/// hostile `\e]2;<tens of MB>\a` (or a `CSI 22 t` `push_title` stack) from
/// parking huge Strings in `held_events` and shipping them to the host.
/// Truncated (not dropped) at a char boundary so a legitimate long title
/// still shows a usable prefix.
const TITLE_MAX_BYTES: usize = 4096;

/// Hardcoded Zenzai Dark foreground (`#d6d6dd`, per
/// `spec/theme-appearance.md`). Used as the reply payload for OSC 10
/// queries until M5's `ThemeManager` lands. M1 keeps theming
/// deliberately out-of-scope so the engine surface doesn't grow a
/// `set_theme` API we'd have to redesign.
pub(crate) const ZENZAI_DARK_FOREGROUND: Rgb = Rgb {
    r: 0xd6,
    g: 0xd6,
    b: 0xdd,
};

/// Hardcoded Zenzai Dark background (`#0c0d10`, per
/// `spec/theme-appearance.md` — also matches the Phase 0 Metal renderer
/// clear color in `app/SolidTerm/TerminalSurfaceView.swift:29`). Used as
/// the reply payload for OSC 11 queries.
pub(crate) const ZENZAI_DARK_BACKGROUND: Rgb = Rgb {
    r: 0x0c,
    g: 0x0d,
    b: 0x10,
};

/// Hardcoded Zenzai Dark cursor (`#7aa2f7`, per
/// `spec/theme-appearance.md`). Used as the reply payload for OSC 12
/// queries.
pub(crate) const ZENZAI_DARK_CURSOR: Rgb = Rgb {
    r: 0x7a,
    g: 0xa2,
    b: 0xf7,
};

/// Map an OSC-10/11/12-derived color index to its Zenzai Dark Rgb
/// value, or `None` for indices we don't reply for.
///
/// Index numbering matches `vte::ansi::NamedColor`: 256 = Foreground
/// (OSC 10), 257 = Background (OSC 11), 258 = Cursor (OSC 12). Other
/// indices (e.g. the 16-color ANSI palette at 0..16, the 256-color
/// xterm extension at 16..256, or unknown high-index queries) return
/// `None` — we silently drop the query rather than reply with a wrong
/// color. M5's `ThemeManager` will widen this to the full palette.
///
/// Superseded for live replies by [`ThemeColors::color_for_index`] (which
/// reads the renderer-pushed theme); retained as the source of the
/// default-slot values and exercised by the color-default tests.
#[allow(dead_code)]
pub(crate) fn theme_color_for_index(index: usize) -> Option<Rgb> {
    if index == NamedColor::Foreground as usize {
        Some(ZENZAI_DARK_FOREGROUND)
    } else if index == NamedColor::Background as usize {
        Some(ZENZAI_DARK_BACKGROUND)
    } else if index == NamedColor::Cursor as usize {
        Some(ZENZAI_DARK_CURSOR)
    } else {
        None
    }
}

#[inline]
fn pack_rgb(c: Rgb) -> u32 {
    (u32::from(c.r) << 16) | (u32::from(c.g) << 8) | u32::from(c.b)
}

#[inline]
fn unpack_rgb(v: u32) -> Rgb {
    Rgb {
        r: ((v >> 16) & 0xff) as u8,
        g: ((v >> 8) & 0xff) as u8,
        b: (v & 0xff) as u8,
    }
}

/// Live fg/bg/cursor used to answer OSC 10/11/12 color queries with the
/// terminal's *actual* rendered theme rather than a hardcoded palette.
/// The Swift renderer pushes the resolved (sRGB) colors via
/// [`crate::TerminalEngine::set_theme_colors`] whenever the theme
/// changes; the [`EventProxy`] (moved into `Term`) reads them when a
/// child queries. Each color is packed sRGB `0x00RRGGBB`. Defaults to
/// the Zenzai Dark constants so a query before the host pushes a theme
/// still gets a sane (and previously-shipped) answer. `Arc`-shared so the
/// engine and the proxy see the same atomics; lock-free.
pub(crate) struct ThemeColors {
    fg: AtomicU32,
    bg: AtomicU32,
    cursor: AtomicU32,
}

impl ThemeColors {
    pub(crate) fn new_default() -> Self {
        Self {
            fg: AtomicU32::new(pack_rgb(ZENZAI_DARK_FOREGROUND)),
            bg: AtomicU32::new(pack_rgb(ZENZAI_DARK_BACKGROUND)),
            cursor: AtomicU32::new(pack_rgb(ZENZAI_DARK_CURSOR)),
        }
    }

    /// Update the live colors (sRGB `0x00RRGGBB`, alpha ignored).
    pub(crate) fn set(&self, fg: u32, bg: u32, cursor: u32) {
        self.fg.store(fg & 0x00ff_ffff, Ordering::Relaxed);
        self.bg.store(bg & 0x00ff_ffff, Ordering::Relaxed);
        self.cursor.store(cursor & 0x00ff_ffff, Ordering::Relaxed);
    }

    /// Resolve an OSC-10/11/12 index (256=fg, 257=bg, 258=cursor) to the
    /// live `Rgb`, or `None` for indices we don't reply for.
    fn color_for_index(&self, index: usize) -> Option<Rgb> {
        if index == NamedColor::Foreground as usize {
            Some(unpack_rgb(self.fg.load(Ordering::Relaxed)))
        } else if index == NamedColor::Background as usize {
            Some(unpack_rgb(self.bg.load(Ordering::Relaxed)))
        } else if index == NamedColor::Cursor as usize {
            Some(unpack_rgb(self.cursor.load(Ordering::Relaxed)))
        } else {
            None
        }
    }
}

/// Engine-side event surfaced from `alacritty_terminal::Term` (via
/// the [`EventListener`] trait) or from PTY child lifecycle (via
/// `EventedPty::next_child_event` polling in `poll_output`).
///
/// Drained as a batch via [`crate::TerminalEngine::drain_events`]
/// once per consumer tick (e.g. one drain per `CAMetalDisplayLink`
/// frame at the FFI integration atomic).
///
/// Field-shape mirrors the alacritty surface as closely as practical
/// while dropping `Arc<dyn Fn>` callback variants and `ExitStatus`
/// (replaced with a serialisable `Option<i32>`) so this enum is
/// `Clone + PartialEq + Eq` and ready for future FFI transcode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineEvent {
    /// Terminal bell — `\x07` (BEL byte) or CSI sequence.
    Bell,
    /// Window title change (OSC 0 / OSC 2). Carries the new title
    /// string verbatim from the escape sequence.
    TitleChanged(String),
    /// Reset to the default window title (OSC 110 / 111 / 112).
    TitleReset,
    /// Child process exited. `status` is the exit code if the
    /// process terminated normally, or `None` if it was killed by
    /// signal or alacritty couldn't determine the status.
    ChildExited { status: Option<i32> },
    /// OSC 52 clipboard write. The renderer is responsible for the
    /// platform clipboard call (Stack A — Rust never touches
    /// `NSPasteboard`).
    ClipboardStore { kind: ClipboardKind, text: String },
    /// OSC 52 clipboard read request. The escape-sequence response
    /// formatting is dropped at this boundary — the consumer
    /// constructs its own response if needed (callback-response
    /// pattern is deferred per the module-level note).
    ClipboardLoad { kind: ClipboardKind },
    /// Grid changes that may require a mouse-cursor shape change
    /// (e.g. cursor entered/left a hyperlink).
    MouseCursorDirty,
    /// New terminal content available — alacritty's `Wakeup` signal.
    /// Used as a generic "something changed" notification.
    WakeUp,
    /// Cursor blinking state changed (e.g. DEC modes 12 / 25).
    CursorBlinkingChange,
    /// OSC 133 ; A — shell prompt is about to be drawn.
    /// Source: `FinalTerm` semantic-prompts proposal, adopted by VS Code,
    /// iTerm2, kitty, etc. Surfaced by the `OscPerform` sibling parser
    /// (the OSC sideband alacritty's `vte::ansi::Handler` doesn't
    /// expose). Consumers (the Swift renderer's prompt-marker accent —
    /// "Show command markers") use this as the boundary between
    /// completed-output and new-prompt.
    PromptStart,
    /// OSC 133 ; B — user input begins (right after the prompt is
    /// drawn). Marks the boundary between prompt cells and user-typed
    /// command cells in the same row.
    CommandStart,
    /// OSC 133 ; C — command is about to execute (user pressed Enter).
    /// Marks the boundary between user-typed input and command output.
    PreExec,
    /// OSC 133 ; D [; <code>] — command finished. `code` is the optional
    /// decimal exit status; `None` when the shell omitted it or sent a
    /// non-numeric value.
    ///
    /// Named `CommandExit` (not plain `Exit`) to disambiguate from
    /// shell/process termination — `ChildExited` already covers PTY
    /// child death; this variant means "the command-the-user-typed has
    /// finished" while the shell process keeps running.
    CommandExit { code: Option<i32> },
    /// OSC 7 — current working directory reported by the shell.
    /// Format: `OSC 7 ; file://<host>/<path> ST` (or BEL terminator).
    /// The host portion is informational only; we extract the path.
    /// `String` (not `PathBuf`) to (1) match the `TitleChanged(String)`
    /// pattern, (2) keep the FFI surface clean for M3+ Swift consumers,
    /// (3) avoid platform-encoding concerns for the typical UTF-8 case.
    ///
    /// Path bytes are not URL-decoded at this stage — most shell-emitted
    /// paths don't contain `%XX` sequences, and a robust decoder is
    /// out-of-scope for M1 task 2.3. Non-`file://` schemes are silently
    /// dropped (no event); invalid UTF-8 paths are silently dropped
    /// with a `tracing::debug!` breadcrumb.
    CwdChanged(String),
}

/// Simplified clipboard target. Mirrors
/// `alacritty_terminal::term::ClipboardType` (`term/mod.rs:2314`)
/// but in our crate so consumers don't pull alacritty types
/// directly.
///
/// `Clipboard` corresponds to OSC 52 'c' (standard clipboard);
/// `Selection` covers OSC 52 'p' / 's' (X11 PRIMARY / select-text).
/// macOS has no PRIMARY equivalent, but we keep the distinction so
/// the renderer can decide how to handle it (typically: ignore
/// `Selection`, only act on `Clipboard`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardKind {
    Clipboard,
    Selection,
}

impl From<ClipboardType> for ClipboardKind {
    fn from(value: ClipboardType) -> Self {
        match value {
            ClipboardType::Clipboard => ClipboardKind::Clipboard,
            ClipboardType::Selection => ClipboardKind::Selection,
        }
    }
}

/// `EventListener` impl that translates alacritty `Event`s into
/// `EngineEvent`s pushed onto a `crossbeam_channel` sender.
///
/// `&self` (not `&mut`) — the trait sig demands it; channel sender
/// is `Send + Sync` so the `&self` constraint is satisfied without
/// interior mutability. Send failures (channel disconnected, e.g.
/// engine being torn down mid-call) are logged via `tracing::warn!`
/// and the event is silently dropped — cleanup-safe.
///
/// Two senders, two consumers:
/// - `events` carries `EngineEvent` for external drain via
///   [`crate::TerminalEngine::drain_events`].
/// - `pty_responses` carries OSC 10/11/12 reply strings the engine
///   writes back to the PTY in `poll_output`. This is intentionally
///   **not** an `EngineEvent` variant — replies are an internal
///   write-back, not consumer-facing telemetry. Decoupling the two
///   channels also avoids a mid-parse re-entrant PTY write (the
///   `EventProxy` runs inside `parser.advance(&mut term, &chunk)` in
///   `poll_output`, where `pty.writer()` would be a borrow conflict).
///
/// `pub(crate)` — engine-internal trait impl. External consumers
/// receive events through [`crate::TerminalEngine::drain_events`].
pub(crate) struct EventProxy {
    sender: Sender<EngineEvent>,
    pty_responses: Sender<String>,
    theme_colors: Arc<ThemeColors>,
}

impl EventProxy {
    /// Default constructor — seeds a private default theme slot. Used by
    /// tests that don't drive theming; OSC color replies fall back to the
    /// Zenzai Dark constants.
    #[cfg(test)]
    pub(crate) fn new(sender: Sender<EngineEvent>, pty_responses: Sender<String>) -> Self {
        Self::with_theme_colors(sender, pty_responses, Arc::new(ThemeColors::new_default()))
    }

    /// Engine constructor — shares the engine's [`ThemeColors`] so the
    /// renderer's `set_theme_colors` updates are visible in OSC replies.
    pub(crate) fn with_theme_colors(
        sender: Sender<EngineEvent>,
        pty_responses: Sender<String>,
        theme_colors: Arc<ThemeColors>,
    ) -> Self {
        Self {
            sender,
            pty_responses,
            theme_colors,
        }
    }
}

impl EventListener for EventProxy {
    fn send_event(&self, event: AlacrittyEvent) {
        let translated = match event {
            AlacrittyEvent::Bell => Some(EngineEvent::Bell),
            AlacrittyEvent::Title(mut t) => {
                if t.len() > TITLE_MAX_BYTES {
                    let mut end = TITLE_MAX_BYTES;
                    while end > 0 && !t.is_char_boundary(end) {
                        end -= 1;
                    }
                    t.truncate(end);
                }
                Some(EngineEvent::TitleChanged(t))
            }
            AlacrittyEvent::ResetTitle => Some(EngineEvent::TitleReset),
            AlacrittyEvent::ClipboardStore(ty, text) => {
                if text.len() > OSC52_MAX_DECODED_BYTES {
                    tracing::warn!(
                        len = text.len(),
                        "OSC 52 clipboard write exceeds cap; dropping"
                    );
                    None
                } else {
                    Some(EngineEvent::ClipboardStore {
                        kind: ty.into(),
                        text,
                    })
                }
            }
            AlacrittyEvent::ClipboardLoad(ty, _formatter) => {
                // The formatter `Arc<dyn Fn(&str) -> String>` is
                // dropped here per the module-level note. Consumers
                // that need to respond construct their own escape
                // sequence; the callback-response pattern is
                // deferred to a later atomic.
                Some(EngineEvent::ClipboardLoad { kind: ty.into() })
            }
            AlacrittyEvent::MouseCursorDirty => Some(EngineEvent::MouseCursorDirty),
            AlacrittyEvent::Wakeup => Some(EngineEvent::WakeUp),
            AlacrittyEvent::CursorBlinkingChange => Some(EngineEvent::CursorBlinkingChange),
            // OSC 10/11/12 query (#71, task 2.5). alacritty's
            // `dynamic_color_sequence` builds an `Arc<dyn Fn(Rgb) ->
            // String>` formatter that already encodes the OSC
            // prefix, the rgb:RRRR/GGGG/BBBB body, and the matching
            // terminator (BEL or ST). We supply the Rgb from the
            // hardcoded Zenzai Dark palette and queue the formatted
            // bytes for `poll_output` to write back to the PTY.
            //
            // Indices we don't have palette entries for (anything
            // outside Foreground=256 / Background=257 / Cursor=258 at
            // M1) are silently dropped — replying with a wrong color
            // is worse than not replying. M5's `ThemeManager` will
            // widen the lookup to the full 256-color + named palette.
            AlacrittyEvent::ColorRequest(index, formatter) => {
                if let Some(color) = self.theme_colors.color_for_index(index) {
                    let reply = formatter(color);
                    if self.pty_responses.send(reply).is_err() {
                        tracing::warn!(
                            "EventProxy: pty_responses channel closed; dropping OSC color reply"
                        );
                    }
                } else {
                    tracing::debug!(
                        index,
                        "EventProxy: OSC color query for un-themed index; dropping"
                    );
                }
                None
            }
            // PtyWrite — alacritty asks the engine to write a
            // formatted reply back to the PTY (#73, task 2.10).
            // Today's only producer is `text_area_size_chars` (CSI
            // 18 t / XTWINOPS rows-cols query), which formats
            // `\x1b[8;rows;cols t` directly without a callback. We
            // route the bytes through the same `pty_responses`
            // queue OSC 10/11/12 uses — the engine's `poll_output`
            // drains it after `parser.advance` returns and writes
            // each reply to the PTY master FD.
            //
            // Same re-entrance guard as the `ColorRequest` arm:
            // `EventProxy::send_event` runs inside
            // `parser.advance(&mut term, &chunk)` where a direct
            // `pty.writer()` call would conflict with the existing
            // borrow. Decoupling via the channel lets the writer
            // claim the borrow exclusively in `poll_output`.
            AlacrittyEvent::PtyWrite(reply) => {
                // alacritty's `Term` answers primary DA (`CSI c`) with the
                // bare VT102 attributes `\x1b[?6c`, which advertises NO
                // color. Capability-probing apps can downgrade a terminal
                // that identifies as a featureless VT102. Rewrite it to
                // `\x1b[?62;22c` — VT220 conformance (62) + ANSI color (22)
                // — which honestly describes SolidTerm: it IS a 24-bit
                // color terminal. Every other PtyWrite (e.g. the XTWINOPS
                // `\x1b[8;rows;cols t` size reply) passes through verbatim.
                let reply = if reply == "\x1b[?6c" {
                    String::from("\x1b[?62;22c")
                } else {
                    reply
                };
                if self.pty_responses.send(reply).is_err() {
                    tracing::warn!(
                        "EventProxy: pty_responses channel closed; dropping PtyWrite reply"
                    );
                }
                None
            }
            // Deferred variants: log + drop. TextAreaSizeRequest
            // (CSI 14 t) carries an `Arc<dyn Fn(WindowSize) ->
            // String>` formatter that needs cell pixel dims (cell_
            // width/cell_height) — those live on the Swift renderer
            // side, not the engine. Exit is alacritty's CSI-driven
            // shutdown signal, separate from ChildExited. ChildExit
            // is vestigial in the upstream enum — `Term` never
            // sends it; engine emits `ChildExited` from poll_output
            // via `Pty::next_child_event` instead.
            AlacrittyEvent::TextAreaSizeRequest(_)
            | AlacrittyEvent::Exit
            | AlacrittyEvent::ChildExit(_) => {
                tracing::trace!(?event, "EventProxy: dropping deferred-scope event");
                None
            }
        };

        if let Some(translated) = translated {
            if self.sender.send(translated).is_err() {
                // Receiver dropped (engine teardown). Cleanup-safe.
                tracing::warn!("EventProxy: channel closed; dropping event");
            }
        }
    }
}

#[cfg(test)]
mod tests;
