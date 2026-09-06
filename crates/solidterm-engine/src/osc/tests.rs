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
/// form, defaulting the name to `SolidTerm`.
#[test]
fn xtversion_query_replies_with_terminal_name() {
    let (_events, replies) = drive_with_pty(b"\x1b[>0q");
    assert_eq!(replies.len(), 1, "exactly one XTVERSION reply");
    let r = &replies[0];
    assert!(
        r.starts_with("\x1bP>|SolidTerm "),
        "DCS>| <name> prefix, got {r:?}"
    );
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
    assert_eq!(events, vec![EngineEvent::CwdChanged("/home/ก".to_string())],);
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
