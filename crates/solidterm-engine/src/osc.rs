//! OSC routing — recognises shell-integration escape sequences and emits
//! semantic events for the rest of the system.
//!
//! Implements spec/m1-task-breakdown.md §2.1: the [`OscPerform`] sibling
//! `vte::Perform` impl runs alongside alacritty's `vte::ansi::Processor`
//! in [`crate::TerminalEngine::poll_output`]. Each output chunk is parsed
//! twice — once by the alacritty pipeline (grid mutation, the load-bearing
//! producer) and once by our pre-scanner (OSC interception only). The
//! double-parse is ~50 ns/byte (vte FSM cost), well under any frame
//! budget at typical PTY rates.
//!
//! Why a sibling parser instead of a Term wrapper: `Term<L>` implements
//! `vte::ansi::Handler`, which surfaces semantic methods (`set_title`,
//! `clipboard_store`, etc.) but **does not** surface a generic
//! `osc_dispatch`. OSCs that the upstream Performer doesn't recognise —
//! 133, 7, 2026 (alacritty handles 2026 internally but not via Handler)
//! — are silently logged as `[unhandled osc_dispatch]` at
//! `vte/ansi.rs:1341` and never bubble up. The lower-level `vte::Perform`
//! trait IS where `osc_dispatch(&mut self, params: &[&[u8]],
//! bell_terminated: bool)` lives. Driving a sibling `vte::Parser` with
//! our own `Perform` impl is the cleanest way to observe every OSC
//! without forking alacritty's Processor or reimplementing its OSC
//! parsing.
//!
//! Tasks 2.2 (OSC 133) and 2.3 (OSC 7) plug their parsing into
//! [`OscPerform::osc_dispatch`]'s `match` arm.
//!
//! Task 2.9 also overrides [`vte::Perform::csi_dispatch`] for `XTerm`'s
//! `modifyOtherKeys` (`CSI > 4 ; level m` set / `CSI ? 4 m` query). Why
//! here rather than via alacritty's `Term::set_modify_other_keys` /
//! `Term::report_modify_other_keys`: alacritty 0.26 does not implement
//! either trait method (vte's defaults — both no-op — apply), so the
//! state would be unobservable. The sibling parser sees the raw bytes
//! anyway; intercepting `csi_dispatch` for the two relevant forms is
//! cheaper than wrapping `Term`. Kitty keyboard protocol (`CSI > N u` /
//! `CSI < N u` / `CSI = N u` / `CSI ? u`) **is** fully implemented by
//! alacritty when `Config::kitty_keyboard` is true (see `engine::new`),
//! so it lives on `Term` — only the accessor on `TerminalEngine` is
//! needed for that side.

use alacritty_terminal::vte;
use crossbeam_channel::Sender;

use crate::events::EngineEvent;

/// `vte::Perform` impl that runs alongside alacritty's `Processor` to
/// observe every OSC the shell emits. See module-level docs for why
/// this is a sibling parser rather than a `Handler` wrapper.
///
/// Holds a [`Sender<EngineEvent>`] cloned from the engine's merged event
/// channel (#55). When tasks 2.2+ flesh out specific OSC handlers, they
/// use `self.sender.send(EngineEvent::...)` to surface semantic events
/// to consumers via [`crate::TerminalEngine::drain_events`].
///
/// All non-OSC `vte::Perform` methods are no-ops: alacritty's
/// `vte::ansi::Processor` is the authoritative grid-mutation consumer,
/// and we don't want to duplicate any of its work. Only [`Self::
/// osc_dispatch`] carries logic.
///
/// `pub(crate)` — engine-internal. External consumers receive the
/// resulting [`EngineEvent`]s through `drain_events`.
pub(crate) struct OscPerform {
    /// Cloned `crossbeam_channel::Sender` shared with [`crate::events::
    /// EventProxy`] and the engine's own `events_tx`. All three produce
    /// into the same receiver; `drain_events` is the single consumer.
    ///
    sender: Sender<EngineEvent>,

    /// Cloned `crossbeam_channel::Sender` for queueing PTY-write replies
    /// (#71 / #73 / task 2.9). Drained in `TerminalEngine::poll_output`
    /// outside the `parser.advance` borrow chain. Used today for the
    /// `CSI ? 4 m` modifyOtherKeys query reply (`CSI > 4 ; level m`).
    pty_responses: Sender<String>,

    /// `XTerm` `modifyOtherKeys` level. `0` = disabled (the default and
    /// the `Reset` form `CSI > 4 ; 0 m`), `1` = `EnableExceptWellDefined`
    /// (`CSI > 4 ; 1 m`), `2` = `EnableAll` (`CSI > 4 ; 2 m`). Read by
    /// [`crate::TerminalEngine::modify_other_keys_level`]. Mode tracking
    /// is engine-side because alacritty 0.26 does not implement
    /// `Handler::set_modify_other_keys` (defaults to no-op) — see the
    /// module docs for the rationale.
    ///
    /// Stored on `OscPerform` rather than on `TerminalEngine` directly
    /// because the `vte::Perform` impl is the natural place to mutate it
    /// (we already see every CSI here for the OSC sibling-parser run).
    /// The engine reads it via `osc_perform.modify_other_keys_level()`.
    modify_other_keys_level: u8,
}

impl OscPerform {
    /// Construct an `OscPerform` with the engine's event sender and
    /// the shared PTY-response sender. Cheap; `Sender` is `Clone` and
    /// the underlying `crossbeam_channel` is lock-free for unbounded
    /// channels.
    pub(crate) fn new(sender: Sender<EngineEvent>, pty_responses: Sender<String>) -> Self {
        Self {
            sender,
            pty_responses,
            modify_other_keys_level: 0,
        }
    }

    /// Current `XTerm` `modifyOtherKeys` level: `0` (disabled / Reset),
    /// `1` (`EnableExceptWellDefined`), or `2` (`EnableAll`). Read by
    /// [`crate::TerminalEngine::modify_other_keys_level`].
    pub(crate) fn modify_other_keys_level(&self) -> u8 {
        self.modify_other_keys_level
    }

    /// Test/diagnostic accessor — confirms the sender plumbing is live.
    /// Used by tests that assert send-from-`osc_dispatch` lands on the
    /// receiver. Not part of the stable engine surface.
    #[cfg(test)]
    pub(crate) fn sender(&self) -> &Sender<EngineEvent> {
        &self.sender
    }

    /// Send an event, logging + dropping silently if the receiver has
    /// disconnected (engine teardown). Mirrors the cleanup-safe
    /// behaviour of [`crate::events::EventProxy::send_event`].
    fn emit(&self, event: EngineEvent) {
        if self.sender.send(event).is_err() {
            tracing::warn!("OscPerform: events channel closed; dropping OSC event");
        }
    }

    /// OSC 133 — `FinalTerm` semantic-prompts. Marker letter is in
    /// `params[1]`; `D` may carry an optional decimal exit code in
    /// `params[2]`. Extra trailing parameters (e.g. `aid=1234`,
    /// `cl=line`, `freshline`) are ignored by design — detection is
    /// driven solely by the marker letter so vendor extensions
    /// (iTerm2 / VS Code / kitty) don't break round-tripping.
    ///
    /// Defensive on every parse failure: malformed forms are silently
    /// dropped (with a tracing breadcrumb at debug level) rather than
    /// panicking. The shell is the source of truth; if it sends garbage
    /// we shouldn't take down the renderer.
    fn handle_osc_133(&self, params: &[&[u8]]) {
        // Need at least the OSC number + the marker letter.
        let Some(marker) = params.get(1) else {
            tracing::debug!("OSC 133 missing marker letter; dropping");
            return;
        };

        match *marker {
            b"A" => self.emit(EngineEvent::PromptStart),
            b"B" => self.emit(EngineEvent::CommandStart),
            b"C" => self.emit(EngineEvent::PreExec),
            b"D" => {
                // Optional exit code in params[2]. Decimal i32; on
                // missing or non-numeric input fall back to None
                // rather than dropping the whole event — `D` itself
                // is the load-bearing "command finished" signal.
                let code = params
                    .get(2)
                    .and_then(|raw| std::str::from_utf8(raw).ok())
                    .and_then(|s| s.parse::<i32>().ok());
                self.emit(EngineEvent::CommandExit { code });
            }
            other => {
                tracing::debug!(
                    marker = ?String::from_utf8_lossy(other),
                    "OSC 133 unknown marker; dropping",
                );
            }
        }
    }

    /// OSC 7 — shell-reported current working directory.
    ///
    /// Canonical form: `OSC 7 ; file://<host>/<path> ST`. The host
    /// portion is informational; we extract `<path>` and emit
    /// [`EngineEvent::CwdChanged`].
    ///
    /// Parsing rules:
    /// - URL bytes live in `params[1]` (the single tail argument).
    /// - The scheme prefix `file://` is matched case-sensitively —
    ///   shells (zsh, bash, fish) emit lowercase. If a counterexample
    ///   appears in the wild, relax the match here.
    /// - Host can be empty (`file:///path`), `localhost`, or a remote
    ///   hostname; in every case we skip everything between `file://`
    ///   and the next `/`, then take the remainder as the path.
    /// - URL-decoding (`%XX` → bytes) is intentionally skipped at M1.
    ///   Most shell-emitted paths are plain ASCII; non-ASCII or
    ///   special-character paths get a TODO for M2+.
    /// - Invalid UTF-8 path bytes: silently dropped with a debug
    ///   breadcrumb (no event, no panic).
    /// - Non-`file://` schemes (e.g. `http://`): silently dropped with
    ///   a debug breadcrumb (no event).
    /// - Missing path / empty params / other malformed input: silently
    ///   dropped (no panic).
    ///
    /// Defensive on every branch — the shell is the source of truth
    /// and we shouldn't take down the renderer for malformed bytes.
    fn handle_osc_7(&self, params: &[&[u8]]) {
        // Canonical scheme is `file://` (case-sensitive — shells emit
        // lowercase). Other schemes are out-of-scope for cwd reporting.
        const SCHEME: &[u8] = b"file://";

        // OSC 7 carries the URL as the tail argument. vte splits OSC
        // params on ';', but ';' is a legal byte inside a path, so a URL
        // with literal semicolons arrives split across params[1..]. Rejoin
        // rather than silently truncating the cwd at the first ';'. (Shells
        // usually percent-encode ';' as %3b, keeping it in params[1], so
        // this is a no-op in the common case.)
        let joined_url: Vec<u8>;
        let url_bytes: &[u8] = match params.get(1) {
            None => {
                tracing::debug!("OSC 7 missing URL argument; dropping");
                return;
            }
            Some(first) if params.len() <= 2 => first,
            Some(_) => {
                joined_url = params[1..].join(&b';');
                &joined_url
            }
        };

        let Some(after_scheme) = url_bytes.strip_prefix(SCHEME) else {
            tracing::debug!(
                url = ?String::from_utf8_lossy(url_bytes),
                "OSC 7 non-file:// scheme; dropping",
            );
            return;
        };

        // Skip the host portion: everything up to (but not including)
        // the next `/`. For `file:///path` the host is empty and the
        // first byte after `file://` is already `/` — the find()
        // returns 0 and we slice from 0 onward (path is `/path`).
        let Some(slash_idx) = after_scheme.iter().position(|&b| b == b'/') else {
            // No `/` means no path component — `file://localhost`
            // alone is malformed for cwd reporting.
            tracing::debug!(
                url = ?String::from_utf8_lossy(url_bytes),
                "OSC 7 missing path component after host; dropping",
            );
            return;
        };
        let path_bytes = &after_scheme[slash_idx..];

        // Decode `%XX` sequences before UTF-8 validation so encoded
        // non-ASCII paths (Thai, emoji, spaces) come through correctly.
        // Shells often percent-encode whatever bytes the OS gave them,
        // not just unsafe URL chars — so we decode unconditionally.
        let Some(decoded) = percent_decode(path_bytes) else {
            tracing::debug!(
                path = ?String::from_utf8_lossy(path_bytes),
                "OSC 7 malformed %XX escape; dropping",
            );
            return;
        };
        let Ok(path) = std::str::from_utf8(&decoded) else {
            tracing::debug!(
                path = ?String::from_utf8_lossy(&decoded),
                "OSC 7 path is not valid UTF-8; dropping",
            );
            return;
        };

        // Percent-decoding runs after vte has stripped C0 controls, so
        // encoded controls (`%1b`, `%0d`, `%0a`, `%07`) would decode back
        // to raw control/ESC bytes that are valid UTF-8 and thus survive,
        // re-introducing bytes vte deliberately removed. A legitimate cwd
        // never contains C0/C1 controls — reject the event rather than
        // emit a path carrying reinjected control bytes.
        if path.chars().any(char::is_control) {
            tracing::debug!(
                path = ?path,
                "OSC 7 decoded path contains control characters; dropping",
            );
            return;
        }

        self.emit(EngineEvent::CwdChanged(path.to_string()));
    }

    /// `CSI > 4 ; level m` — `XTerm` `modifyOtherKeys` set. Per
    /// `vte/ansi.rs:1626-1634`, level `0` resets, `1` enables except for
    /// well-defined keys, `2` enables for all keys; any other value is
    /// silently ignored ("`unhandled`" in vte's terminology). When the
    /// shell omits the level (e.g. `CSI > 4 m`), vte's `next_param_or(0)`
    /// gives `0`, matching xterm's reset semantic.
    ///
    /// We accept the same three values and stash the level on
    /// `OscPerform`. Out-of-range values are dropped with a tracing
    /// breadcrumb so a misbehaving shell can't corrupt the level.
    fn handle_modify_other_keys_set(&mut self, level: u16) {
        match level {
            0..=2 => {
                // u16 → u8 truncation is safe inside the matched range
                // (0/1/2 fits in u8 trivially). Use `try_into` over `as`
                // to keep clippy happy and lock the invariant in code.
                if let Ok(level_u8) = u8::try_from(level) {
                    self.modify_other_keys_level = level_u8;
                    tracing::trace!(level, "modifyOtherKeys level set");
                }
            }
            other => {
                tracing::debug!(
                    level = other,
                    "modifyOtherKeys: out-of-range level; ignoring"
                );
            }
        }
    }

    /// `CSI ? 4 m` — `XTerm` `modifyOtherKeys` query. Reply is
    /// `CSI > 4 ; level m` per the canonical `XTerm` form (vte's
    /// `report_modify_other_keys` doc-comment, `vte/ansi.rs:679`).
    /// We queue the formatted reply on `pty_responses`; the engine's
    /// `poll_output` drains and writes it to the PTY master FD, the
    /// same path OSC 10/11/12 replies use (#71). Drop quietly if the
    /// receiver has disconnected — the engine is tearing down.
    fn handle_modify_other_keys_query(&self) {
        let reply = format!("\x1b[>4;{}m", self.modify_other_keys_level);
        if self.pty_responses.send(reply).is_err() {
            tracing::warn!(
                "OscPerform: pty_responses channel closed; dropping modifyOtherKeys reply"
            );
        }
    }

    /// `CSI > Ps q` — XTVERSION terminal-identification request. Reply is
    /// the DCS form `DCS > | <name> <version> ST` (`\x1bP>|…\x1b\\`).
    /// alacritty 0.26 does not implement XTVERSION (no `Handler` method;
    /// vte's default is a no-op), so the sibling parser answers it — modern
    /// terminals (Ghostty, kitty, WezTerm, xterm) all reply, and TUIs use
    /// the reply to identify the terminal and unlock capabilities (notably
    /// Claude Code, which withholds its truecolor input gradient from
    /// terminals that don't answer this probe — env `TERM_PROGRAM` /
    /// `COLORTERM` alone don't satisfy it).
    ///
    /// Reports `SolidTerm <version>`. The Ps parameter (0) is ignored; we
    /// always answer.
    fn handle_xtversion_query(&self) {
        let reply = format!("\x1bP>|SolidTerm {}\x1b\\", env!("CARGO_PKG_VERSION"));
        if self.pty_responses.send(reply).is_err() {
            tracing::warn!("OscPerform: pty_responses channel closed; dropping XTVERSION reply");
        }
    }
}

impl vte::Perform for OscPerform {
    /// Operating-system command dispatch. The 2.1 wrapper exposes the
    /// `match params[0]` extension point and a `tracing::trace!`
    /// breadcrumb; specific OSC numbers (133, 7, 8, 52, 2026, ...) land
    /// in tasks 2.2 through 2.7.
    ///
    /// `params[0]` is the OSC number as ASCII bytes (e.g. `b"133"`,
    /// `b"7"`); subsequent slices are `;`-separated tail arguments per
    /// the OSC spec. `bell_terminated` distinguishes BEL (`\x07`) from
    /// ST (`\x1b\\`) terminators — relevant for OSCs that echo a reply
    /// back to the PTY (10/11/12 in task 2.5; 52 in 2.6) since the
    /// reply must use the same terminator the shell sent.
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if params.is_empty() || params[0].is_empty() {
            return;
        }

        // Extension point for tasks 2.3 (OSC 7), 2.4 (OSC 8),
        // 2.5 (OSC 10/11/12), 2.6 (OSC 52), 2.7 (OSC 2026). Each arm
        // lands as a one-line diff alongside its handler method.
        match params[0] {
            // task 2.2: OSC 133 — `FinalTerm` semantic-prompts.
            b"133" => self.handle_osc_133(params),
            // task 2.3: OSC 7 — shell-reported current working directory.
            b"7" => self.handle_osc_7(params),
            // task 2.4: b"8"   => { ... }
            // task 2.5: b"10" | b"11" | b"12" => { ... }
            // task 2.6: b"52"  => { ... }
            // task 2.7: handled inline by the sibling Processor for now;
            //          synchronized-update damage-hold lands in 2.7.
            _ => {
                tracing::trace!(
                    osc = ?String::from_utf8_lossy(params[0]),
                    bell_terminated,
                    param_count = params.len(),
                    "OscPerform: unmatched OSC (extension point for tasks 2.3+)",
                );
            }
        }
    }

    /// CSI dispatch — observe-only, narrowly scoped to `XTerm`'s
    /// `modifyOtherKeys` (set + query). Alacritty's `Processor`
    /// (running against `Term` on every chunk in `poll_output`) is the
    /// authoritative consumer for every other CSI sequence including
    /// the Kitty keyboard protocol (`'u'` final, handled by `Term`'s
    /// `set_keyboard_mode` / `push_keyboard_mode` / `pop_keyboard_modes`
    /// / `report_keyboard_mode` impls when `Config::kitty_keyboard` is
    /// true). We must NOT duplicate any of that — only the two arms
    /// alacritty leaves as defaults are claimed here.
    ///
    /// Match shape mirrors `vte::ansi`'s parser
    /// (`vte-0.13.1/src/ansi.rs:1626-1641`) so our state stays in lock-
    /// step with what the spec expects vte's `Handler` to receive.
    fn csi_dispatch(
        &mut self,
        params: &vte::Params,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        // vte sets `ignore` when the CSI overflowed its intermediate /
        // parameter limits or was otherwise malformed; a spec-conformant
        // terminal drops it rather than replying or mutating state.
        if ignore {
            return;
        }

        // `CSI > Ps q` — XTVERSION terminal-identification request.
        // alacritty 0.26 leaves it unhandled (no XTVERSION support), so we
        // answer it in the sibling parser, same rationale as
        // modifyOtherKeys below.
        if action == 'q' && intermediates == b">" {
            self.handle_xtversion_query();
            return;
        }

        // Two relevant forms only:
        //   `CSI > 4 ; level m`  → set    (intermediates = b">")
        //   `CSI ? 4 m`           → query  (intermediates = b"?")
        // Any other CSI is alacritty's concern.
        if action != 'm' {
            return;
        }

        match intermediates {
            b">" => {
                // First param must be `4` to be modifyOtherKeys; xterm's
                // CSI `> Pm m` family also covers other modes (e.g.
                // `> 0 m` resets all). Filter by leading param == 4
                // before reading the level.
                let mut iter = params.iter();
                let first = iter.next().and_then(|p| p.first().copied());
                if first != Some(4) {
                    return;
                }
                // vte's `next_param_or(0)` semantics: missing second
                // param → level 0 (reset). Matches `vte/ansi.rs:1627`.
                let level = iter.next().and_then(|p| p.first().copied()).unwrap_or(0);
                self.handle_modify_other_keys_set(level);
            }
            b"?" => {
                // vte requires exactly `4` as the param for the query
                // form (`vte/ansi.rs:1635-1640`). We do the same to
                // avoid replying to unrelated `CSI ? Pm m` variants.
                let mut iter = params.iter();
                let first = iter.next().and_then(|p| p.first().copied());
                if first != Some(4) {
                    return;
                }
                self.handle_modify_other_keys_query();
            }
            _ => {}
        }
    }

    // All remaining `vte::Perform` methods are no-ops. The alacritty
    // `Processor` (driven against `Term` in the same `poll_output`
    // chunk loop) is the authoritative consumer for print / execute /
    // ESC / DCS state machines. We sit purely on the OSC + the
    // narrowly-scoped `modifyOtherKeys` CSI sideband.
}

/// Decode `%XX` sequences in a URL path. Returns `None` if a `%` is
/// followed by anything other than two ASCII hex digits (treated as
/// malformed input — the caller drops the OSC). Non-`%` bytes pass
/// through unchanged so multi-byte UTF-8 already in the path survives.
fn percent_decode(input: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        if input[i] == b'%' {
            let hi = input.get(i + 1).copied().and_then(hex_nibble)?;
            let lo = input.get(i + 2).copied().and_then(hex_nibble)?;
            out.push((hi << 4) | lo);
            i += 3;
        } else {
            out.push(input[i]);
            i += 1;
        }
    }
    Some(out)
}

const fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::OscPerform;
    use crate::events::EngineEvent;
    use alacritty_terminal::vte;
    use crossbeam_channel::unbounded;

    /// Drive `OscPerform` directly through a `vte::Parser` with an OSC
    /// number that has no handler arm yet. The dispatch falls through
    /// to the tracing breadcrumb without sending anything; structural
    /// pre-condition for any future arm landing in 2.4+.
    #[test]
    fn osc_perform_handles_dispatch_without_panic() {
        let (tx, rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();

        // OSC 8 (hyperlink) — `\x1b]8;;https://example.com\x07`. Until
        // task 2.4 lands, this falls through the `_` arm and doesn't
        // emit an event.
        let bytes = b"\x1b]8;;https://example.com\x07";
        vte::Parser::advance(&mut parser, &mut perform, bytes);

        assert!(
            rx.try_recv().is_err(),
            "unhandled OSC numbers must not emit events (specific arms land in 2.4+)",
        );
    }

    /// Helper: drive a byte slice through a fresh `vte::Parser` against
    /// a fresh `OscPerform` and return the resulting event vec. Each
    /// call uses a fresh receiver so tests don't pollute each other.
    fn drive(bytes: &[u8]) -> Vec<EngineEvent> {
        let (tx, rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, bytes);
        let mut out = Vec::new();
        while let Ok(event) = rx.try_recv() {
            out.push(event);
        }
        out
    }

    /// Helper: drive a byte slice and return both the event vec and
    /// any `pty_responses` queued. For tests that need to assert on the
    /// reply path (e.g. `CSI ? 4 m` modifyOtherKeys query reply).
    fn drive_with_pty(bytes: &[u8]) -> (Vec<EngineEvent>, Vec<String>) {
        let (tx, rx) = unbounded::<EngineEvent>();
        let (pty_tx, pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, bytes);
        let mut events = Vec::new();
        while let Ok(event) = rx.try_recv() {
            events.push(event);
        }
        let mut replies = Vec::new();
        while let Ok(reply) = pty_rx.try_recv() {
            replies.push(reply);
        }
        (events, replies)
    }

    /// Helper: drive a byte slice and return the `modify_other_keys_level`
    /// state on the `OscPerform` afterward. The level lives on the perform
    /// (not in events), so we have to keep a handle through dispatch.
    fn drive_capture_modify_level(bytes: &[u8]) -> u8 {
        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, bytes);
        perform.modify_other_keys_level()
    }

    /// `CSI > 0 q` (XTVERSION) replies with the DCS `>| <name> <ver> ST`
    /// form, defaulting the name to "SolidTerm".
    #[test]
    fn xtversion_query_replies_with_terminal_name() {
        let (_events, replies) = drive_with_pty(b"\x1b[>0q");
        assert_eq!(replies.len(), 1, "exactly one XTVERSION reply");
        let r = &replies[0];
        assert!(r.starts_with("\x1bP>|SolidTerm "), "DCS>| <name> prefix, got {r:?}");
        assert!(r.ends_with("\x1b\\"), "ST-terminated, got {r:?}");
    }

    /// `CSI > q` with the Ps parameter omitted is still XTVERSION — we
    /// answer regardless of Ps.
    #[test]
    fn xtversion_query_without_param_also_replies() {
        let (_events, replies) = drive_with_pty(b"\x1b[>q");
        assert_eq!(replies.len(), 1);
        assert!(replies[0].starts_with("\x1bP>|SolidTerm "));
    }

    /// OSC 133 ; A — emits `PromptStart`. ST-terminated form
    /// (`\x1b\\`); BEL-terminated (`\x07`) is also valid and tested
    /// separately in `osc_133_a_bel_terminated_also_works`.
    #[test]
    fn osc_133_a_emits_prompt_start() {
        let events = drive(b"\x1b]133;A\x1b\\");
        assert_eq!(events, vec![EngineEvent::PromptStart]);
    }

    /// OSC 133 ; A with BEL terminator — same outcome as the
    /// ST-terminated form. `vte::Parser` collapses both terminators into
    /// the same `osc_dispatch` invocation; this test pins that down for
    /// our handler.
    #[test]
    fn osc_133_a_bel_terminated_also_works() {
        let events = drive(b"\x1b]133;A\x07");
        assert_eq!(events, vec![EngineEvent::PromptStart]);
    }

    /// OSC 133 ; B — emits `CommandStart`.
    #[test]
    fn osc_133_b_emits_command_start() {
        let events = drive(b"\x1b]133;B\x1b\\");
        assert_eq!(events, vec![EngineEvent::CommandStart]);
    }

    /// OSC 133 ; C — emits `PreExec`.
    #[test]
    fn osc_133_c_emits_pre_exec() {
        let events = drive(b"\x1b]133;C\x1b\\");
        assert_eq!(events, vec![EngineEvent::PreExec]);
    }

    /// OSC 133 ; D (no exit code) — emits `CommandExit { code: None }`.
    #[test]
    fn osc_133_d_no_code_emits_exit_with_none() {
        let events = drive(b"\x1b]133;D\x1b\\");
        assert_eq!(events, vec![EngineEvent::CommandExit { code: None }]);
    }

    /// OSC 133 ; D ; <code> — emits `CommandExit { code: Some(n) }`
    /// for several common exit codes (0 = success, 1 = generic error,
    /// 127 = command-not-found, 255 = high-byte sentinel).
    #[test]
    fn osc_133_d_with_code_emits_exit_with_code() {
        for code in [0i32, 1, 127, 255] {
            let bytes = format!("\x1b]133;D;{code}\x1b\\");
            let events = drive(bytes.as_bytes());
            assert_eq!(
                events,
                vec![EngineEvent::CommandExit { code: Some(code) }],
                "OSC 133 ; D ; {code} should emit CommandExit {{ code: Some({code}) }}",
            );
        }
    }

    /// OSC 133 ; D ; <garbage> — exit code that doesn't parse as i32
    /// falls back to `None` rather than panicking or dropping the whole
    /// event. The `D` marker is load-bearing; the optional code is
    /// best-effort.
    #[test]
    fn osc_133_d_with_invalid_code_emits_exit_with_none() {
        let events = drive(b"\x1b]133;D;abc\x1b\\");
        assert_eq!(events, vec![EngineEvent::CommandExit { code: None }]);
    }

    /// OSC 133 ; <unknown> — silently dropped (debug-level trace).
    /// Forward-compat: future FinalTerm-spec markers (E, F, ...)
    /// shouldn't break the parser.
    #[test]
    fn osc_133_unknown_marker_does_not_emit() {
        let events = drive(b"\x1b]133;Z\x1b\\");
        assert!(events.is_empty(), "unknown OSC 133 marker must not emit");
    }

    /// OSC 133 ; A ; aid=1234 — vendor sub-parameters (iTerm2 prompt
    /// correlation IDs, kitty's `cl=line`, etc.) shouldn't block
    /// detection. `params[1]` is the marker letter; everything after
    /// is ignored by our handler.
    #[test]
    fn osc_133_with_extra_params_still_works() {
        let events = drive(b"\x1b]133;A;aid=1234\x1b\\");
        assert_eq!(events, vec![EngineEvent::PromptStart]);

        // Same shape with a `D` exit code: `;D;0;extra=x` should still
        // parse the code from params[2]. Trailing params are ignored.
        let events = drive(b"\x1b]133;D;0;extra=x\x1b\\");
        assert_eq!(events, vec![EngineEvent::CommandExit { code: Some(0) }]);
    }

    /// OSC 133 with no marker letter at all (`\x1b]133\x1b\\`) is
    /// dropped silently. Defensive parse against malformed shell
    /// integration.
    #[test]
    fn osc_133_missing_marker_does_not_emit() {
        let events = drive(b"\x1b]133\x1b\\");
        assert!(events.is_empty(), "OSC 133 with no marker must not emit");
    }

    /// Empty / malformed OSC bytes must not panic. `vte::Parser` will
    /// still call `osc_dispatch` with an empty slice in some edge
    /// cases; the early-return guard handles it.
    #[test]
    fn osc_perform_handles_empty_params_safely() {
        use vte::Perform;

        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);

        // Direct call (bypassing the parser) — exercises the
        // `params.is_empty()` and `params[0].is_empty()` guards.
        perform.osc_dispatch(&[], true);
        perform.osc_dispatch(&[b""], true);
        perform.osc_dispatch(&[b"", b"value"], false);
        // No panic = pass.
    }

    /// Sender accessor returns the same channel the constructor took.
    /// Cheap sanity check that confirms the field is actually wired
    /// (and lets 2.2+ tests assert against the receiver via the
    /// engine-level path).
    #[test]
    fn osc_perform_sender_is_clone_of_input() {
        let (tx, rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let perform = OscPerform::new(tx.clone(), pty_tx);

        // Use the test-only accessor to send something on the held
        // sender; the receiver must observe it.
        perform
            .sender()
            .send(EngineEvent::Bell)
            .expect("channel is open");
        assert_eq!(rx.try_recv().ok(), Some(EngineEvent::Bell));
    }

    // -----------------------------------------------------------------
    // task 2.3 — OSC 7 (current working directory)
    // -----------------------------------------------------------------

    /// Canonical zsh/bash/fish form: `file://localhost/<path>`. The
    /// `localhost` host is informational; we strip it and surface the
    /// path verbatim.
    #[test]
    fn osc_7_with_localhost_host_emits_cwd() {
        let events = drive(b"\x1b]7;file://localhost/Users/zen\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::CwdChanged("/Users/zen".to_string())],
        );
    }

    /// Empty-host form: `file:///path`. The third `/` is the path
    /// start; the host between `file://` and the third `/` is empty.
    #[test]
    fn osc_7_with_empty_host_emits_cwd() {
        let events = drive(b"\x1b]7;file:///Users/zen\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::CwdChanged("/Users/zen".to_string())],
        );
    }

    /// Remote host form: `file://hostname/<path>`. The host is dropped
    /// (informational only); the path is what matters for cwd
    /// detection. Less common in the wild but spec-compliant.
    #[test]
    fn osc_7_with_remote_host_emits_cwd() {
        let events = drive(b"\x1b]7;file://example.com/some/path\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::CwdChanged("/some/path".to_string())],
        );
    }

    /// BEL terminator (`\x07`) is interchangeable with ST (`\x1b\\`)
    /// for OSC sequences. `vte::Parser` collapses both into the same
    /// `osc_dispatch` invocation; this test pins that down for OSC 7.
    #[test]
    fn osc_7_bel_terminated_also_works() {
        let events = drive(b"\x1b]7;file:///tmp\x07");
        assert_eq!(events, vec![EngineEvent::CwdChanged("/tmp".to_string())],);
    }

    /// Non-`file://` schemes are silently dropped — OSC 7 is
    /// conventionally a cwd-reporting channel using the file URL
    /// scheme. Some shells/editors theoretically use OSC 7 for other
    /// URL types; we ignore those rather than emit a misleading
    /// `CwdChanged` event.
    #[test]
    fn osc_7_non_file_scheme_does_not_emit() {
        let events = drive(b"\x1b]7;http://example.com/\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 7 with non-file:// scheme must not emit CwdChanged",
        );
    }

    /// Invalid UTF-8 in the path bytes — drop silently, no panic.
    /// Defensive against shells running in mismatched-locale envs
    /// or with corrupted output.
    #[test]
    fn osc_7_invalid_utf8_does_not_panic() {
        // `file://localhost/` followed by an invalid UTF-8 sequence
        // (lone continuation byte 0x80) and ST terminator.
        let mut bytes = b"\x1b]7;file://localhost/\x80\x81".to_vec();
        bytes.extend_from_slice(b"\x1b\\");
        let events = drive(&bytes);
        assert!(
            events.is_empty(),
            "OSC 7 with invalid UTF-8 path must drop silently, not emit",
        );
    }

    /// Percent-encoded ASCII (space, common in paths with directory
    /// names that contain spaces). Shells percent-encode whatever
    /// bytes are unsafe in a URL; we must decode before surfacing.
    #[test]
    fn osc_7_percent_decodes_ascii_space() {
        let events = drive(b"\x1b]7;file:///tmp/foo%20bar\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::CwdChanged("/tmp/foo bar".to_string())],
        );
    }

    /// Percent-encoded multi-byte UTF-8 (Thai `ก` = U+0E01 = `E0 B8 81`).
    /// Each byte of the UTF-8 sequence comes through as its own `%XX`
    /// triplet; we must decode all three and reassemble into valid UTF-8.
    #[test]
    fn osc_7_percent_decodes_utf8_thai() {
        let events = drive(b"\x1b]7;file:///home/%E0%B8%81\x1b\\");
        assert_eq!(
            events,
            vec![EngineEvent::CwdChanged("/home/ก".to_string())],
        );
    }

    /// Malformed `%XX` (non-hex digits) — drop the entire OSC silently.
    /// We never partially-decode, since a partial path could mislead the
    /// host into displaying or following a wrong cwd.
    #[test]
    fn osc_7_malformed_percent_dropped() {
        let events = drive(b"\x1b]7;file:///tmp/%XY\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 7 with malformed %XX must drop silently",
        );
    }

    /// Missing path component (`file://localhost` with no trailing
    /// slash) — drop silently. The path is the load-bearing piece of
    /// OSC 7; without it the event has no useful payload.
    #[test]
    fn osc_7_missing_path_does_not_emit() {
        let events = drive(b"\x1b]7;file://localhost\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 7 with no path component must not emit",
        );
    }

    /// `OSC 7` with no parameters at all — drop silently. The
    /// `params.get(1)` guard handles this without panicking.
    #[test]
    fn osc_7_empty_params_does_not_emit() {
        let events = drive(b"\x1b]7\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 7 with no URL argument must not emit",
        );
    }

    /// Percent-encoded control bytes (`%1b` = ESC, `%0d` = CR) decode
    /// back to raw controls that are valid UTF-8 and would otherwise
    /// survive — reinjecting bytes vte deliberately stripped. The
    /// post-decode control-char guard must reject the event so no
    /// control/ESC-bearing cwd reaches consumers.
    #[test]
    fn osc_7_percent_encoded_control_bytes_do_not_emit() {
        let events = drive(b"\x1b]7;file:///tmp/%1bfoo%0dbar\x1b\\");
        assert!(
            events.is_empty(),
            "OSC 7 with percent-encoded control bytes must not emit CwdChanged",
        );
    }

    // -----------------------------------------------------------------
    // task 2.9 — modifyOtherKeys CSI dispatch (unit-level)
    //
    // These exercise `OscPerform`'s `csi_dispatch` directly through a
    // sibling `vte::Parser` — no Term, no PTY, no cat. Pin the parsing
    // contract independently of the cat-loopback engine tests, which
    // catch regressions if alacritty changes its parse path or if the
    // engine wiring (pty_responses_tx clone, csi_dispatch override)
    // drifts apart.
    // -----------------------------------------------------------------

    /// `CSI > 4 ; 1 m` sets level 1.
    #[test]
    fn csi_modify_other_keys_set_level_1() {
        let level = drive_capture_modify_level(b"\x1b[>4;1m");
        assert_eq!(level, 1);
    }

    /// `CSI > 4 ; 2 m` sets level 2.
    #[test]
    fn csi_modify_other_keys_set_level_2() {
        let level = drive_capture_modify_level(b"\x1b[>4;2m");
        assert_eq!(level, 2);
    }

    /// `CSI > 4 ; 0 m` resets to 0 (the "Reset" form).
    #[test]
    fn csi_modify_other_keys_set_level_0() {
        // First set to 2, then reset to 0 — verifies the path actually
        // mutates (a starting-zero would pass even if the parser was
        // broken).
        let (_evs, _replies) = drive_with_pty(b"\x1b[>4;2m\x1b[>4;0m");

        // For this assertion we can't reuse the helper across two
        // invocations (each builds a fresh perform), so build manually.
        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;2m");
        assert_eq!(perform.modify_other_keys_level(), 2, "precondition");
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;0m");
        assert_eq!(perform.modify_other_keys_level(), 0);
    }

    /// `CSI > 4 m` (no level param) — vte's `next_param_or(0)` gives
    /// 0, matching xterm's reset semantic.
    #[test]
    fn csi_modify_other_keys_set_no_level_resets() {
        // Set to 2 first, then send the no-level form.
        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;2m");
        assert_eq!(perform.modify_other_keys_level(), 2, "precondition");
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4m");
        assert_eq!(perform.modify_other_keys_level(), 0);
    }

    /// `CSI > 4 ; 99 m` — out-of-range level. Our handler drops it
    /// (with a tracing breadcrumb) and the previous level is preserved.
    #[test]
    fn csi_modify_other_keys_out_of_range_level_is_dropped() {
        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;1m");
        assert_eq!(perform.modify_other_keys_level(), 1, "precondition");
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;99m");
        assert_eq!(
            perform.modify_other_keys_level(),
            1,
            "out-of-range level must be ignored, preserving previous state",
        );
    }

    /// `CSI > N m` for `N != 4` — not modifyOtherKeys. Must not change
    /// the level. Ensures the leading-param filter is in place (other
    /// `CSI > Pm m` family members exist; we don't claim them).
    #[test]
    fn csi_gt_non_4_intermediate_does_not_affect_modify_other_keys() {
        let (tx, _rx) = unbounded::<EngineEvent>();
        let (pty_tx, _pty_rx) = unbounded::<String>();
        let mut perform = OscPerform::new(tx, pty_tx);
        let mut parser = vte::Parser::new();
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>4;2m");
        assert_eq!(perform.modify_other_keys_level(), 2, "precondition");
        // `CSI > 0 m` is xterm's "reset all modifier keys" — different
        // function, not modifyOtherKeys. Must not touch our level.
        vte::Parser::advance(&mut parser, &mut perform, b"\x1b[>0m");
        assert_eq!(
            perform.modify_other_keys_level(),
            2,
            "CSI > 0 m (not modifyOtherKeys) must not affect level",
        );
    }

    /// `CSI ? 4 m` query — replies `\x1b[>4;{level}m` on the
    /// `pty_responses` channel. Default level is 0.
    #[test]
    fn csi_modify_other_keys_query_replies_with_current_level() {
        let (events, replies) = drive_with_pty(b"\x1b[?4m");
        assert!(events.is_empty(), "query must not emit EngineEvent");
        assert_eq!(replies, vec!["\x1b[>4;0m".to_string()]);
    }

    /// After raising to level 1, the query reply reflects it.
    #[test]
    fn csi_modify_other_keys_query_replies_with_raised_level() {
        let (events, replies) = drive_with_pty(b"\x1b[>4;1m\x1b[?4m");
        assert!(events.is_empty(), "set+query must not emit EngineEvent");
        assert_eq!(replies, vec!["\x1b[>4;1m".to_string()]);
    }

    /// `CSI ? 5 m` — query for some other private mode (not 4). Must
    /// NOT enqueue a reply (we only claim `?4m`).
    #[test]
    fn csi_question_non_4_query_does_not_reply() {
        let (events, replies) = drive_with_pty(b"\x1b[?5m");
        assert!(events.is_empty());
        assert!(
            replies.is_empty(),
            "CSI ? 5 m is not modifyOtherKeys; we must not reply",
        );
    }

    /// Generic CSI sequences (no `>` / `?` intermediate) must NOT
    /// touch the modifyOtherKeys level — alacritty's main parser is
    /// the authoritative consumer for those, and double-handling here
    /// would corrupt state.
    #[test]
    fn csi_generic_does_not_touch_modify_other_keys() {
        // `CSI 4 m` is plain SGR (set "underline" attribute). We must
        // not treat it as modifyOtherKeys.
        let level = drive_capture_modify_level(b"\x1b[4m");
        assert_eq!(level, 0, "plain SGR `CSI 4 m` must not affect level");
    }
}
