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
/// bounds what we LATCH in the FFI layer and push to NSPasteboard —
/// not the one-shot decode. 1 MiB is far above any legitimate copy.
const OSC52_MAX_DECODED_BYTES: usize = 1 << 20;

/// Upper bound on an OSC 0/2 window-title payload. A title is only ever
/// shown in tab/window chrome, so a few KiB is generous; capping stops a
/// hostile `\e]2;<tens of MB>\a` (or a `CSI 22 t` push_title stack) from
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
mod tests {
    use super::{
        theme_color_for_index, ClipboardKind, EngineEvent, EventProxy, ThemeColors,
        ZENZAI_DARK_BACKGROUND, ZENZAI_DARK_CURSOR, ZENZAI_DARK_FOREGROUND,
    };
    use alacritty_terminal::event::{Event as AlacrittyEvent, EventListener};
    use alacritty_terminal::term::ClipboardType;
    use alacritty_terminal::vte::ansi::NamedColor;
    use crossbeam_channel::{unbounded, Receiver};
    use std::sync::Arc;

    /// Build an `EventProxy` whose PTY-response channel is a throwaway
    /// `Receiver` we drop on the floor. Used by every test that doesn't
    /// care about OSC 10/11/12 replies. `_pty_rx` is held in a tuple
    /// return so it stays alive for the lifetime of the proxy (sender
    /// would error on a disconnected receiver).
    fn proxy_for_event_tests() -> (EventProxy, Receiver<EngineEvent>, Receiver<String>) {
        let (events_tx, events_rx) = unbounded::<EngineEvent>();
        let (pty_tx, pty_rx) = unbounded::<String>();
        (EventProxy::new(events_tx, pty_tx), events_rx, pty_rx)
    }

    #[test]
    fn clipboard_kind_from_alacritty_type() {
        assert_eq!(
            ClipboardKind::from(ClipboardType::Clipboard),
            ClipboardKind::Clipboard
        );
        assert_eq!(
            ClipboardKind::from(ClipboardType::Selection),
            ClipboardKind::Selection
        );
    }

    #[test]
    fn proxy_forwards_bell() {
        let (proxy, rx, _pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::Bell);
        assert_eq!(rx.try_recv().ok(), Some(EngineEvent::Bell));
    }

    #[test]
    fn proxy_forwards_title_changed() {
        let (proxy, rx, _pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::Title("solidterm".to_string()));
        assert_eq!(
            rx.try_recv().ok(),
            Some(EngineEvent::TitleChanged("solidterm".to_string()))
        );
    }

    #[test]
    fn proxy_forwards_title_reset() {
        let (proxy, rx, _pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::ResetTitle);
        assert_eq!(rx.try_recv().ok(), Some(EngineEvent::TitleReset));
    }

    #[test]
    fn proxy_forwards_clipboard_store() {
        let (proxy, rx, _pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::ClipboardStore(
            ClipboardType::Clipboard,
            "hello".to_string(),
        ));
        assert_eq!(
            rx.try_recv().ok(),
            Some(EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: "hello".to_string(),
            })
        );
    }

    #[test]
    fn proxy_pty_write_queues_on_pty_responses() {
        // #73: PtyWrite is the alacritty-side hook for `CSI 18 t`
        // (text_area_size_chars) — it routes the formatted reply
        // string through `pty_responses`, NOT the consumer-facing
        // events channel. Pin both halves of that contract.
        let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[8;24;80t".to_string()));
        assert!(
            events_rx.try_recv().is_err(),
            "PtyWrite must not surface as EngineEvent — replies are internal write-back"
        );
        assert_eq!(
            pty_rx.try_recv().ok(),
            Some("\x1b[8;24;80t".to_string()),
            "PtyWrite payload must land on pty_responses verbatim",
        );
    }

    #[test]
    fn proxy_rewrites_bare_da1_to_advertise_color() {
        // alacritty answers DA1 with the bare VT102 `\x1b[?6c` (no color).
        // EventProxy rewrites it to `\x1b[?62;22c` (VT220 + ANSI color) so
        // probing apps don't treat SolidTerm as a featureless mono terminal.
        let (proxy, _events_rx, pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[?6c".to_string()));
        assert_eq!(pty_rx.try_recv().ok(), Some("\x1b[?62;22c".to_string()));
    }

    #[test]
    fn proxy_passes_through_non_da1_pty_writes_unchanged() {
        // Only the exact bare-DA1 string is rewritten; every other reply
        // (e.g. the XTWINOPS size report) is forwarded verbatim.
        let (proxy, _events_rx, pty_rx) = proxy_for_event_tests();
        proxy.send_event(AlacrittyEvent::PtyWrite("\x1b[8;24;80t".to_string()));
        assert_eq!(pty_rx.try_recv().ok(), Some("\x1b[8;24;80t".to_string()));
    }

    #[test]
    fn proxy_drops_child_exit_vestigial_variant() {
        // alacritty's Event::ChildExit is defined but never fired
        // from Term::send_event; if it did somehow arrive (via a
        // future upstream change) we'd drop it because ChildExited
        // comes through the Pty::next_child_event path with a more
        // accurate exit status. Use `sh -c true` to construct an
        // ExitStatus portably (avoids hardcoding /bin/true vs
        // /usr/bin/true differences across hosts).
        let (proxy, rx, _pty_rx) = proxy_for_event_tests();
        let exit_status = std::process::Command::new("sh")
            .args(["-c", "true"])
            .status()
            .expect("sh -c true should run");
        proxy.send_event(AlacrittyEvent::ChildExit(exit_status));
        assert!(
            rx.try_recv().is_err(),
            "Event::ChildExit is vestigial upstream; Pty::next_child_event is the canonical source"
        );
    }

    #[test]
    fn proxy_send_after_receiver_dropped_is_silent_warn() {
        let (events_tx, events_rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let proxy = EventProxy::new(events_tx, pty_tx);
        drop(events_rx);
        // Should not panic; just logs a warn and drops.
        proxy.send_event(AlacrittyEvent::Bell);
    }

    // -----------------------------------------------------------------
    // task 2.5 — OSC 10/11/12 (fg/bg/cursor color queries)
    //
    // The query path runs entirely inside alacritty's stack:
    //
    //   vte::Parser → vte::ansi::Processor → Term::dynamic_color_sequence
    //     → Event::ColorRequest(index, formatter)
    //     → EventProxy::send_event → pty_responses queue
    //     → poll_output drains and writes to PTY master FD
    //
    // alacritty's `dynamic_color_sequence` (term/mod.rs:1675-1688) builds
    // an `Arc<dyn Fn(Rgb) -> String>` formatter that already encodes the
    // OSC prefix and matching terminator (BEL or ST), so EventProxy only
    // needs to supply the Rgb. The formatter shape is:
    //
    //   |color| format!("\x1b]{};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}{terminator}",
    //                   prefix, color.r, color.g, color.b)
    //
    // For OSC 10 query against fg=#d6d6dd, the reply is
    // `\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\` (the doubled hex bytes are the
    // standard XParseColor format — a 16-bit channel synthesised by
    // duplicating the 8-bit channel byte).
    // -----------------------------------------------------------------

    /// Direct-call (bypass parser) — `ColorRequest` for index 256
    /// (Foreground) builds the formatted reply against
    /// `ZENZAI_DARK_FOREGROUND` and pushes it onto the `pty_responses`
    /// queue (no `EngineEvent` emitted on the events channel). Pins the
    /// Rgb-lookup behaviour without depending on the full Term + parser
    /// stack (those are exercised by the `osc_10_*_via_term` tests
    /// below).
    #[test]
    fn proxy_color_request_foreground_pushes_pty_reply() {
        let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
        // Synthesise the formatter alacritty would build for OSC 10 ; ?
        // with an ST terminator. Exact format from `term/mod.rs:1681`.
        let formatter = std::sync::Arc::new(|color: alacritty_terminal::vte::ansi::Rgb| {
            format!(
                "\x1b]10;rgb:{0:02x}{0:02x}/{1:02x}{1:02x}/{2:02x}{2:02x}\x1b\\",
                color.r, color.g, color.b
            )
        });
        proxy.send_event(AlacrittyEvent::ColorRequest(
            NamedColor::Foreground as usize,
            formatter,
        ));
        // No EngineEvent surfaced — replies are internal write-back.
        assert!(
            events_rx.try_recv().is_err(),
            "ColorRequest must not surface as EngineEvent — replies go to pty_responses",
        );
        // PTY response queue carries the formatted reply with the
        // hardcoded foreground (#d6d6dd → rgb:d6d6/d6d6/dddd).
        assert_eq!(
            pty_rx.try_recv().ok(),
            Some("\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string()),
        );
    }

    /// `set_theme_colors` makes the OSC reply reflect the live theme, not
    /// the hardcoded Zenzai Dark default. Set bg=#445566 and confirm the
    /// OSC 11 reply carries it (`rgb:4444/5555/6666`).
    #[test]
    fn proxy_color_request_reflects_set_theme_colors() {
        let (events_tx, _events_rx) = unbounded::<EngineEvent>();
        let (pty_tx, pty_rx) = unbounded::<String>();
        let theme = Arc::new(ThemeColors::new_default());
        theme.set(0x11_22_33, 0x44_55_66, 0x77_88_99); // fg, bg, cursor (sRGB)
        let proxy = EventProxy::with_theme_colors(events_tx, pty_tx, Arc::clone(&theme));
        let formatter = Arc::new(|color: alacritty_terminal::vte::ansi::Rgb| {
            format!(
                "\x1b]11;rgb:{0:02x}{0:02x}/{1:02x}{1:02x}/{2:02x}{2:02x}\x1b\\",
                color.r, color.g, color.b
            )
        });
        proxy.send_event(AlacrittyEvent::ColorRequest(
            NamedColor::Background as usize,
            formatter,
        ));
        assert_eq!(
            pty_rx.try_recv().ok(),
            Some("\x1b]11;rgb:4444/5555/6666\x1b\\".to_string()),
            "OSC 11 reply must reflect the set background (#445566)",
        );
    }

    /// Index outside the M1 palette (256/257/258) — silently dropped.
    /// Indices for the 16-color ANSI palette (0..16) and 256-color
    /// extension (16..256) aren't themed at M1, so no reply is queued.
    /// Future themability widens this; pin the current behaviour.
    #[test]
    fn proxy_color_request_unsupported_index_drops_silently() {
        let (proxy, events_rx, pty_rx) = proxy_for_event_tests();
        let formatter = std::sync::Arc::new(|_: alacritty_terminal::vte::ansi::Rgb| String::new());
        proxy.send_event(AlacrittyEvent::ColorRequest(0, formatter)); // ANSI black
        assert!(events_rx.try_recv().is_err());
        assert!(
            pty_rx.try_recv().is_err(),
            "OSC 4 query for ANSI palette must not produce a reply at M1",
        );
    }

    /// `theme_color_for_index` returns the right Rgb for each of the
    /// three named indices. Belt-and-suspenders against an off-by-one
    /// in the `NamedColor` discriminant constants.
    #[test]
    fn theme_color_lookup_matches_named_indices() {
        assert_eq!(
            theme_color_for_index(NamedColor::Foreground as usize),
            Some(ZENZAI_DARK_FOREGROUND),
        );
        assert_eq!(
            theme_color_for_index(NamedColor::Background as usize),
            Some(ZENZAI_DARK_BACKGROUND),
        );
        assert_eq!(
            theme_color_for_index(NamedColor::Cursor as usize),
            Some(ZENZAI_DARK_CURSOR),
        );
        // Bright/Dim variants and ANSI palette indices are intentionally
        // unhandled at M1 — defer to ThemeManager.
        assert!(theme_color_for_index(0).is_none());
        assert!(theme_color_for_index(255).is_none());
        assert!(theme_color_for_index(NamedColor::DimForeground as usize).is_none());
    }

    // -----------------------------------------------------------------
    // task 2.6 — OSC 52 (clipboard write) end-to-end
    //
    // The OSC 52 path runs entirely inside alacritty's stack:
    //
    //   vte::Parser → vte::ansi::Processor → Term::clipboard_store
    //     → EventProxy::send_event → EngineEvent::ClipboardStore
    //
    // alacritty already (a) parses `OSC 52 ; <selection> ; <data> ST`,
    // (b) base64-decodes + UTF-8-validates `data`, (c) gates on the
    // `Osc52` config (default `OnlyCopy` allows store, denies load), and
    // (d) routes through `Event::ClipboardStore(ClipboardType, String)`.
    // Our `EventProxy::send_event` impl above translates that to
    // `EngineEvent::ClipboardStore { kind, text }`.
    //
    // Sources (alacritty_terminal 0.26.0 / vte 0.15.0):
    //   - vte/ansi.rs:1483-1492 — OSC 52 dispatch (b"52" arm).
    //   - alacritty_terminal/term/mod.rs:1705-1722 — clipboard_store
    //     (selection match, base64 decode, UTF-8 validate, send_event).
    //   - alacritty_terminal/term/mod.rs:1726-1747 — clipboard_load
    //     (gated to Osc52::OnlyPaste|CopyPaste; denied under our default).
    //
    // These tests therefore serve two purposes:
    //   1. Pin the upstream behaviour our renderer relies on (so a
    //      future alacritty bump that breaks OSC 52 fails CI here).
    //   2. Document the proxy translation for reviewers — `text` is
    //      the **decoded** UTF-8 string, not raw base64.
    //
    // Tests run a real `Term<EventProxy>` + `ansi::Processor` (no PTY
    // spawn — fast + deterministic) per the alacritty-internal pattern.
    // -----------------------------------------------------------------

    use alacritty_terminal::grid::Dimensions;
    use alacritty_terminal::term::{Config as AlacrittyTermConfig, Term};
    use alacritty_terminal::vte::ansi;

    /// Minimal `Dimensions` for a non-PTY `Term` constructed inside
    /// these tests. Mirrors the `EngineDimensions` in `engine.rs`; kept
    /// local to the test module so we don't widen the engine's surface.
    struct TestDimensions {
        rows: usize,
        cols: usize,
    }

    impl Dimensions for TestDimensions {
        fn total_lines(&self) -> usize {
            self.rows
        }
        fn screen_lines(&self) -> usize {
            self.rows
        }
        fn columns(&self) -> usize {
            self.cols
        }
    }

    /// Drive `bytes` through `vte::ansi::Processor` against a fresh
    /// `Term<EventProxy>` and return the events drained from the proxy
    /// channel. This is the same code path `TerminalEngine::poll_output`
    /// runs (`engine.rs:373`), minus the PTY reader thread.
    fn drive_through_term(bytes: &[u8]) -> Vec<EngineEvent> {
        let (events, _replies) = drive_through_term_full(bytes);
        events
    }

    /// Same as [`drive_through_term`] but also returns the queue of
    /// PTY-write-back replies (OSC 10/11/12 query answers). Used by
    /// task 2.5's tests to verify the reply payload without mocking
    /// a PTY.
    fn drive_through_term_full(bytes: &[u8]) -> (Vec<EngineEvent>, Vec<String>) {
        let (events_tx, events_rx) = unbounded::<EngineEvent>();
        let (pty_tx, pty_rx) = unbounded::<String>();
        let proxy = EventProxy::new(events_tx, pty_tx);
        let dims = TestDimensions { rows: 24, cols: 80 };
        let mut term = Term::new(AlacrittyTermConfig::default(), &dims, proxy);
        // Explicit type annotation — `Processor`'s `Timeout` type
        // parameter has a default (`StdSyncHandler`) that the inference
        // engine doesn't pick automatically across crate boundaries.
        // `engine.rs:134` uses the same shape (typed field).
        let mut parser: ansi::Processor = ansi::Processor::new();
        parser.advance(&mut term, bytes);
        let mut events = Vec::new();
        while let Ok(event) = events_rx.try_recv() {
            events.push(event);
        }
        let mut replies = Vec::new();
        while let Ok(reply) = pty_rx.try_recv() {
            replies.push(reply);
        }
        (events, replies)
    }

    /// OSC 52 ; c ; <base64> — the canonical clipboard-write form.
    /// Base64 of "Hello" is `SGVsbG8=`. Expect `ClipboardStore` with
    /// `kind: Clipboard` and the **decoded** text.
    #[test]
    fn osc_52_c_with_base64_emits_clipboard_store() {
        let events = drive_through_term(b"\x1b]52;c;SGVsbG8=\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: "Hello".to_string(),
            }],
        );
    }

    /// BEL terminator (`\x07`) is interchangeable with ST (`\x1b\\`)
    /// for OSC sequences. `vte::Parser` collapses both into the same
    /// `osc_dispatch`; pin that down for OSC 52 too.
    #[test]
    fn osc_52_c_bel_terminated_also_works() {
        let events = drive_through_term(b"\x1b]52;c;d29ybGQ=\x07");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: "world".to_string(),
            }],
        );
    }

    /// OSC 52 ; p ; <base64> — X11 PRIMARY selection. macOS has no
    /// PRIMARY equivalent; alacritty still surfaces it as
    /// `ClipboardType::Selection` and the renderer is responsible for
    /// ignoring it. Pin the kind translation here.
    #[test]
    fn osc_52_p_emits_selection_kind() {
        let events = drive_through_term(b"\x1b]52;p;Zm9v\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Selection,
                text: "foo".to_string(),
            }],
        );
    }

    /// OSC 52 ; s ; <base64> — `s` (alias for select-text) also maps
    /// to `Selection` per `term/mod.rs:1713`.
    #[test]
    fn osc_52_s_emits_selection_kind() {
        let events = drive_through_term(b"\x1b]52;s;YmFy\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Selection,
                text: "bar".to_string(),
            }],
        );
    }

    /// OSC 52 ; c ; ? — clipboard *read* request. Under our default
    /// `Osc52::OnlyCopy` config (set in `engine.rs:220`, inheriting
    /// alacritty's Default), reads are denied and no event fires.
    /// Read-path support is deferred to M2+ for security reasons
    /// (terminal apps reading clipboard = exfiltration vector; needs
    /// explicit user-consent UX).
    #[test]
    fn osc_52_query_form_does_not_emit_under_default_config() {
        let events = drive_through_term(b"\x1b]52;c;?\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 52 ; c ; ? must not emit under default Osc52::OnlyCopy",
        );
    }

    /// OSC 52 ; c ; <invalid-base64> — alacritty's base64 decoder
    /// returns `Err`; `clipboard_store` early-returns without firing
    /// an event (`term/mod.rs:1717`). Exfil-resistant: malformed input
    /// is silently dropped rather than panicking or emitting a
    /// half-decoded payload.
    #[test]
    fn osc_52_invalid_base64_does_not_emit() {
        // `not-base64!!!` decodes-fails (! is outside the base64
        // alphabet). The arm must drop, no panic, no event.
        let events = drive_through_term(b"\x1b]52;c;not-base64!!!\x1b\\");
        assert!(events.is_empty(), "invalid base64 must be silently dropped",);
    }

    /// OSC 52 ; c ; <base64-of-invalid-utf8> — base64 decodes to bytes
    /// that aren't valid UTF-8; alacritty's `String::from_utf8` returns
    /// `Err` and the event is dropped (`term/mod.rs:1718`). Pins the
    /// "no malformed text emit" guarantee.
    #[test]
    fn osc_52_invalid_utf8_payload_does_not_emit() {
        // Lone continuation byte 0x80 is not valid UTF-8. Base64-encoded
        // `[0x80]` is `gA==`.
        let events = drive_through_term(b"\x1b]52;c;gA==\x1b\\");
        assert!(
            events.is_empty(),
            "non-UTF-8 decoded payload must not emit (silent drop)",
        );
    }

    /// OSC 52 with an unrecognised selection byte (e.g. `q`, `0`-`7`,
    /// or any letter outside `c`/`p`/`s`) — alacritty's match arm
    /// early-returns (`term/mod.rs:1714`). No event fires. Multi-char
    /// selection like `cs` collapses to its first byte (`c`) per vte's
    /// `params[1].first().unwrap_or(&b'c')` (`vte/ansi.rs:1488`); the
    /// "unrecognised" case here picks a byte that's neither.
    #[test]
    fn osc_52_unrecognised_selection_does_not_emit() {
        let events = drive_through_term(b"\x1b]52;q;SGVsbG8=\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 52 with unrecognised selection byte must not emit",
        );
    }

    /// OSC 52 with empty selection (`OSC 52 ; ; <base64>`) — vte's
    /// dispatch defaults to `b'c'` when `params[1].first()` is `None`
    /// (`vte/ansi.rs:1488`). So this is treated as an OSC 52 ; c ; ...
    /// write. Pins that fallback so a future vte change doesn't
    /// silently break "missing-selection" shells.
    #[test]
    fn osc_52_empty_selection_defaults_to_clipboard() {
        let events = drive_through_term(b"\x1b]52;;SGVsbG8=\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: "Hello".to_string(),
            }],
        );
    }

    /// OSC 52 with too few parameters (`OSC 52` alone, or just
    /// `OSC 52 ; c`) — vte's `params.len() < 3` guard returns via
    /// `unhandled` (`vte/ansi.rs:1484`). No event, no panic.
    #[test]
    fn osc_52_truncated_params_does_not_emit() {
        // No selection, no data.
        let events = drive_through_term(b"\x1b]52\x1b\\");
        assert!(events.is_empty(), "OSC 52 with no params must not emit");

        // Selection but no data.
        let events = drive_through_term(b"\x1b]52;c\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 52 with selection but no data must not emit",
        );
    }

    /// OSC 52 ; c ; <empty-base64> — empty base64 is valid and decodes
    /// to an empty byte string, which is valid UTF-8 (the empty
    /// string). alacritty fires `ClipboardStore` with `text: ""`. Pins
    /// this edge case so a renderer-side "non-empty payload" assertion
    /// can be added later without surprise.
    #[test]
    fn osc_52_empty_base64_emits_empty_text() {
        let events = drive_through_term(b"\x1b]52;c;\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: String::new(),
            }],
        );
    }

    /// OSC 52 with a decoded payload that exceeds `OSC52_MAX_DECODED_BYTES`
    /// is dropped at the EventProxy cap check. "QUFB" is base64 for "AAA"
    /// (3 bytes); repeating it `(cap / 3) + 1` times decodes to more than
    /// cap bytes. The engine must not emit a `ClipboardStore` event.
    #[test]
    fn osc_52_write_over_cap_is_dropped() {
        use super::OSC52_MAX_DECODED_BYTES;
        // (cap / 3) + 1 repetitions decodes to cap + 1 bytes — just over the limit.
        let payload = "QUFB".repeat((OSC52_MAX_DECODED_BYTES / 3) + 1);
        let seq = format!("\x1b]52;c;{payload}\x1b\\");
        let events = drive_through_term(seq.as_bytes());
        assert!(
            events.is_empty(),
            "OSC 52 payload exceeding OSC52_MAX_DECODED_BYTES must be dropped; got {events:?}",
        );
    }

    /// OSC 52 with a decoded payload well under the cap passes through
    /// unchanged. "QUFB" decodes to "AAA" (3 bytes).
    #[test]
    fn osc_52_write_under_cap_passes() {
        let events = drive_through_term(b"\x1b]52;c;QUFB\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::ClipboardStore {
                kind: ClipboardKind::Clipboard,
                text: "AAA".to_string(),
            }],
            "OSC 52 payload under cap must emit exactly one ClipboardStore event",
        );
    }

    // -----------------------------------------------------------------
    // task 2.5 — OSC 10/11/12 end-to-end through Term + Processor
    //
    // Drive each query through the full alacritty stack and assert the
    // formatted reply lands on `pty_responses`. The reply uses the
    // XParseColor `rgb:RRRR/GGGG/BBBB` format alacritty's formatter at
    // term/mod.rs:1681 builds (16-bit channels synthesised by repeating
    // each 8-bit byte — see vte/ansi.rs comments for why).
    // -----------------------------------------------------------------

    /// OSC 10 ; ? ST — query the foreground color. Reply carries
    /// `rgb:d6d6/d6d6/dddd` for `#d6d6dd` and the same ST terminator
    /// the shell sent.
    #[test]
    fn osc_10_query_replies_with_foreground() {
        let (events, replies) = drive_through_term_full(b"\x1b]10;?\x1b\\");
        assert!(events.is_empty(), "OSC 10 query must not surface as event");
        assert_eq!(
            replies,
            vec!["\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string()]
        );
    }

    /// OSC 11 ; ? ST — query the background color. Reply carries
    /// `rgb:0c0c/0d0d/1010` for `#0c0d10`.
    #[test]
    fn osc_11_query_replies_with_background() {
        let (events, replies) = drive_through_term_full(b"\x1b]11;?\x1b\\");
        assert!(events.is_empty());
        assert_eq!(
            replies,
            vec!["\x1b]11;rgb:0c0c/0d0d/1010\x1b\\".to_string()]
        );
    }

    /// OSC 12 ; ? ST — query the cursor color. Reply carries
    /// `rgb:7a7a/a2a2/f7f7` for `#7aa2f7`.
    #[test]
    fn osc_12_query_replies_with_cursor() {
        let (events, replies) = drive_through_term_full(b"\x1b]12;?\x1b\\");
        assert!(events.is_empty());
        assert_eq!(
            replies,
            vec!["\x1b]12;rgb:7a7a/a2a2/f7f7\x1b\\".to_string()]
        );
    }

    /// BEL terminator (`\x07`) — alacritty's formatter takes the
    /// terminator the shell used and echoes it back; vte's parser
    /// surfaces both `\x1b\\` and `\x07` as the same OSC dispatch. Pin
    /// the BEL-roundtrip path for OSC 10 (the others share the formatter
    /// shape).
    #[test]
    fn osc_10_query_bel_terminated_reply_uses_bel() {
        let (_events, replies) = drive_through_term_full(b"\x1b]10;?\x07");
        assert_eq!(replies, vec!["\x1b]10;rgb:d6d6/d6d6/dddd\x07".to_string()]);
    }

    /// OSC 10 set form (`OSC 10 ; rgb:RR/GG/BB ST`) — alacritty parses
    /// the rgb body and calls `Handler::set_color` on Term, which
    /// updates Term's internal palette (no event, no PTY reply). M1
    /// doesn't react to set requests beyond letting alacritty mutate
    /// its palette; the renderer keeps painting against its own
    /// hardcoded ThemeManager-replacement constants. The test pins
    /// "no panic, no surprise event, no PTY reply" — the contract is
    /// "set form is silently absorbed by alacritty".
    #[test]
    fn osc_10_set_form_does_not_emit_or_reply() {
        let (events, replies) = drive_through_term_full(b"\x1b]10;rgb:00/00/00\x1b\\");
        assert!(events.is_empty(), "OSC 10 set must not surface as event");
        assert!(
            replies.is_empty(),
            "OSC 10 set must not produce a PTY reply"
        );
    }

    /// OSC 11 set form, same contract as OSC 10 set.
    #[test]
    fn osc_11_set_form_does_not_emit_or_reply() {
        let (events, replies) = drive_through_term_full(b"\x1b]11;rgb:ff/ff/ff\x1b\\");
        assert!(events.is_empty());
        assert!(replies.is_empty());
    }

    /// OSC 12 set form, same contract.
    #[test]
    fn osc_12_set_form_does_not_emit_or_reply() {
        let (events, replies) = drive_through_term_full(b"\x1b]12;#7aa2f7\x1b\\");
        assert!(events.is_empty());
        assert!(replies.is_empty());
    }

    /// Multiple queries chained in one chunk (`OSC 10 ; ? ; ?`) —
    /// alacritty's `OSC 10|11|12` arm at vte/ansi.rs:1422 iterates
    /// `params[1..]` and **increments** the dynamic color code on each
    /// iteration (vte/ansi.rs:1447). So `OSC 10 ; ? ; ? ; ?` is a
    /// chained query for fg → bg → cursor in one OSC. Each iteration
    /// invokes `dynamic_color_sequence` separately, so `EventProxy`
    /// queues one reply per `?`. Pin the per-index advancement to
    /// catch upstream behaviour changes.
    #[test]
    fn osc_10_chained_query_advances_index_per_question_mark() {
        let (_events, replies) = drive_through_term_full(b"\x1b]10;?;?;?\x1b\\");
        assert_eq!(
            replies,
            vec![
                "\x1b]10;rgb:d6d6/d6d6/dddd\x1b\\".to_string(),
                "\x1b]11;rgb:0c0c/0d0d/1010\x1b\\".to_string(),
                "\x1b]12;rgb:7a7a/a2a2/f7f7\x1b\\".to_string(),
            ],
            "chained `;?` parameters should advance fg → bg → cursor per upstream loop",
        );
    }

    // -----------------------------------------------------------------
    // task 2.10 — XTWINOPS title operations & rows-cols query (#73)
    //
    // Of the four CSI t variants vte/alacritty handles
    // (vte-0.15.0/src/ansi.rs:1739-1745):
    //   - 14 t (text_area_size_pixels) — needs cell pixel dims; deferred
    //     (the renderer side owns those values).
    //   - 18 t (text_area_size_chars) — formats `\x1b[8;rows;cols t`
    //     directly via `Event::PtyWrite`, exercised below.
    //   - 22 t (push_title) — alacritty stores `term.title.clone()` on
    //     an internal stack capped at TITLE_STACK_MAX_DEPTH = 4096
    //     (alacritty_terminal-0.26.0/src/term/mod.rs:42). No event is
    //     fired; verified indirectly by the pop-restores-prior-title
    //     test below.
    //   - 23 t (pop_title) — alacritty calls `set_title(popped)` which
    //     fires `Event::Title` (or `Event::ResetTitle` if the popped
    //     value was None). That's what surfaces as `EngineEvent::Title
    //     Changed` / `TitleReset` to consumers — we just verify the
    //     existing translation still holds across a push/pop cycle.
    //
    // CSI 0 t and 2 t (title queries) are intentionally NOT supported
    // by vte (the `_ => unhandled!()` arm at vte/ansi.rs:1744). xterm-
    // hardened terminal emulators omit title query support — replying
    // with arbitrary user-controlled title text is a CVE class
    // (e.g. CVE-2003-0063). We inherit that posture by not adding our
    // own dispatch; if a future spec requires it, we'd have to handle
    // it outside the alacritty stack.
    // -----------------------------------------------------------------

    /// `CSI 18 t` produces `\x1b[8;<rows>;<cols> t` on the PTY-response
    /// queue via the `PtyWrite` arm. `TestDimensions` is 24×80, so the
    /// expected reply is `\x1b[8;24;80t`. Pins both:
    ///   1. alacritty/vte still dispatches `('t', []) => 18 =>
    ///      text_area_size_chars` (catches an upstream regression).
    ///   2. Our `PtyWrite` translation routes the bytes verbatim through
    ///      `pty_responses` (catches a regression in `EventProxy`).
    #[test]
    fn xtwinops_18t_emits_rows_cols_reply() {
        let (events, replies) = drive_through_term_full(b"\x1b[18t");
        assert!(
            events.is_empty(),
            "CSI 18 t must not surface a consumer-facing event; got {events:?}",
        );
        assert_eq!(
            replies,
            vec!["\x1b[8;24;80t".to_string()],
            "CSI 18 t reply payload (rows;cols) must match the test dimensions",
        );
    }

    /// `CSI 14 t` (`text_area_size_pixels`) is the deferred sibling —
    /// alacritty fires `Event::TextAreaSizeRequest(formatter)` which
    /// the proxy currently drops with a tracing breadcrumb. Pin the
    /// drop so an accidental "wire it up" change has to surface here
    /// (it would need cell pixel dims that don't live on the engine).
    #[test]
    fn xtwinops_14t_pixel_query_drops_until_renderer_wired() {
        let (events, replies) = drive_through_term_full(b"\x1b[14t");
        assert!(
            events.is_empty(),
            "CSI 14 t must not surface a consumer-facing event today",
        );
        assert!(
            replies.is_empty(),
            "CSI 14 t reply path is deferred (needs cell pixel dims from renderer)",
        );
    }

    /// `CSI 22 t` (`push_title`) does not fire any alacritty event —
    /// title state is mutated only on `set_title` / `pop_title` /
    /// `reset_title`. Pin the silent-stack-push contract: feeding
    /// `OSC 0 ; A ST` then `CSI 22 t` produces exactly one
    /// `TitleChanged("A")`, with no extra event for the push.
    #[test]
    fn xtwinops_22t_push_title_emits_no_event() {
        let (events, replies) = drive_through_term_full(b"\x1b]0;A\x1b\\\x1b[22t");
        assert_eq!(
            events,
            vec![EngineEvent::TitleChanged("A".to_string())],
            "push_title must be silent — only the prior set_title fires an event",
        );
        assert!(
            replies.is_empty(),
            "push_title is purely state-mutating; no PTY reply",
        );
    }

    /// `CSI 23 t` (`pop_title`) restores the most recent pushed title
    /// via `set_title(popped)`, which fires `Event::Title(prev)` or
    /// `Event::ResetTitle` if the popped value was `None`. Round-trip:
    ///
    /// 1. `OSC 0 ; A ST` -> `TitleChanged("A")`
    /// 2. `CSI 22 t` -> silent push of "A"
    /// 3. `OSC 0 ; B ST` -> `TitleChanged("B")`
    /// 4. `CSI 23 t` -> `set_title(Some("A"))` -> `TitleChanged("A")`
    ///
    /// Confirms the title stack semantics our consumers (block
    /// tracking, window-chrome label) rely on.
    #[test]
    fn xtwinops_23t_pop_title_restores_prior_title() {
        let (events, replies) =
            drive_through_term_full(b"\x1b]0;A\x1b\\\x1b[22t\x1b]0;B\x1b\\\x1b[23t");
        assert_eq!(
            events,
            vec![
                EngineEvent::TitleChanged("A".to_string()),
                EngineEvent::TitleChanged("B".to_string()),
                EngineEvent::TitleChanged("A".to_string()),
            ],
            "expected push/pop cycle to restore the pushed title via set_title",
        );
        assert!(replies.is_empty());
    }

    /// `CSI 23 t` against an empty title stack is a no-op —
    /// `pop_title` early-returns when `title_stack.pop()` yields `None`
    /// (`alacritty_terminal-0.26.0/src/term/mod.rs:2252`). No event, no
    /// reply, no panic. Defensive against a host that emits `23 t`
    /// without a matching prior `22 t`.
    #[test]
    fn xtwinops_23t_pop_on_empty_stack_is_noop() {
        let (events, replies) = drive_through_term_full(b"\x1b[23t");
        assert!(
            events.is_empty(),
            "pop_title on empty stack must not fire any event; got {events:?}",
        );
        assert!(replies.is_empty());
    }
}
