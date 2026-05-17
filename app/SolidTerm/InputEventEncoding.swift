// Implements the Swift half of spec/ffi-boundary.md §Input path. Translates
// AppKit `NSEvent.keyDown` into the FFI `InputEvent` shared struct that
// rust-expert's `TerminalSession.send_input` (#16-rust, commit 4706213)
// dispatches on. This file is pure data marshalling — no Metal types,
// no AppKit responder wiring, no FFI calls. The NSEvent overload is a
// thin AppKit thunk over the lower-level `makeKeyInputEvent(...)` so
// XCTest can exercise the encoder without manufacturing NSEvents
// (which `NSEvent.keyEvent(with:...)` makes painful in headless XCTest).
//
// Discriminator constants (kind / action / modifier-bit positions) are
// hardcoded with cite-comments to `crates/nextterm-ffi/src/bridge.rs`'s
// `pub mod kinds`. swift-bridge 0.1.59 cannot expose Rust `pub const` to
// Swift, so the cross-language contract is "matching numeric literals
// with comment-cite." Keep the enum raw values and `ModifierMask`
// rawValues in lockstep with `bridge.rs::kinds::*`.
//
// `KeyEvent.text: RustString` (#16-perf, was `Vec<u8>`): one
// swift-bridge call (`__swift_bridge__$RustString$new_with_str`) carries
// the typed UTF-8 across the boundary in a single sized allocation. The
// previous `Vec<u8>` shape required `RustVec<UInt8>()` + per-byte
// `push`, costing 2+N FFI calls per keystroke and adding a Vec
// reallocation on the Rust side. The latency harness regression
// surfaced after #16-swift wired this path; bisect quoted in the
// #16-perf commit body. Future Kitty CSI u / modifyOtherKeys at Week 2
// task 2.10 will continue to consume `KeyEvent.text` as the typed
// string the user emitted (modifier-resolved per `NSEvent.characters`
// semantics).
//
// keyDown only this PR: KEY_ACTION_PRESS = 0 is the only action emitted.
// keyUp / repeat get their own dispatch path at Week 2 task 2.10
// (Kitty CSI u + modifyOtherKeys), where action discriminators start
// emitting different escape sequences. See vault/spec/keyboard-system.md.
//
// FocusStackManager routing (app-action shortcuts vs PTY pass-through) is
// a Week 4+ surface; today every keyDown that reaches `TerminalSurfaceView`
// gets encoded and sent to the session. Menu-bar-bound ⌘ shortcuts
// (⌘Q, ⌘N, ⌘W, ⌘H per `AppMenu`) are intercepted by AppKit before the
// responder chain, so they never reach this encoder. Non-menu ⌘ keystrokes
// pass through to the session as raw bytes — defensible for a terminal
// (vim, etc. legitimately want them) until FocusStackManager arrives.

import AppKit

/// `InputEvent.kind` discriminator. Mirror of `nextterm_ffi::kinds::INPUT_EVENT_*`.
enum InputEventKind: UInt8 {
    case key = 0  // kinds::INPUT_EVENT_KEY
    case mouse = 1  // kinds::INPUT_EVENT_MOUSE
    case focus = 2  // kinds::INPUT_EVENT_FOCUS
}

/// `KeyEvent.action` discriminator. Mirror of `nextterm_ffi::kinds::KEY_ACTION_*`.
enum KeyAction: UInt8 {
    case press = 0  // kinds::KEY_ACTION_PRESS
    case release = 1  // kinds::KEY_ACTION_RELEASE
    case `repeat` = 2  // kinds::KEY_ACTION_REPEAT
}

/// `InputEvent.modifiers` bitfield. Bit positions mirror
/// `nextterm_ffi::kinds::MODIFIER_BIT_*`.
struct ModifierMask: OptionSet {
    let rawValue: UInt8

    static let shift = ModifierMask(rawValue: 1 << 0)  // kinds::MODIFIER_BIT_SHIFT
    static let ctrl = ModifierMask(rawValue: 1 << 1)  // kinds::MODIFIER_BIT_CTRL
    static let alt = ModifierMask(rawValue: 1 << 2)  // kinds::MODIFIER_BIT_ALT
    static let `super` = ModifierMask(rawValue: 1 << 3)  // kinds::MODIFIER_BIT_SUPER

    /// Translate `NSEvent.modifierFlags` (the device-independent subset) to
    /// the FFI bitfield. NSEvent's `.command` maps to "super" because the
    /// FFI labels follow Linux/Wayland convention; the AppKit-Linux name
    /// difference is a documentation concern only.
    static func from(_ flags: NSEvent.ModifierFlags) -> ModifierMask {
        var mask: ModifierMask = []
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.control) { mask.insert(.ctrl) }
        if flags.contains(.option) { mask.insert(.alt) }
        if flags.contains(.command) { mask.insert(.super) }
        return mask
    }
}

/// NSEvent → InputEvent translator. Pure-function namespace; no state.
enum InputEventEncoder {

    /// AppKit thunk. Extracts the fields the encoder needs and delegates
    /// to `makeKeyInputEvent(...)` so the lower-level overload is the
    /// unit-testable seam. Always emits `kind = .key` and `action = .press`
    /// — keyDown only this PR.
    static func encode(_ event: NSEvent) -> InputEvent {
        // NSEvent.characters: the *text* the user typed (modifier-aware,
        // dead-key/IME-resolved on commit). For modifier-only events
        // (e.g. just ⌘) it returns nil or empty; the encoder treats
        // those as zero-length text, which the engine no-ops.
        let chars = event.characters ?? ""
        // Special-key translation: NSEvent.characters returns macOS
        // private-use codepoints (NSUpArrowFunctionKey = 0xF700, etc.)
        // for arrow / function / nav keys. Without translation those
        // 3-byte UTF-8 sequences get fed to the shell, which displays
        // them as `[?]` or other garbage instead of recalling history.
        // We substitute the standard ANSI escape sequences so zsh /
        // bash / readline see the bytes they expect.
        //
        // DECCKM (application-cursor-keys mode) is not honored here —
        // we always emit normal-mode CSI (`\e[A` etc.). vim/less in
        // app-cursor mode would prefer SS3 (`\eOA`), but those apps
        // also accept CSI; full DECCKM support waits on the engine
        // exposing `mode().contains(APP_CURSOR)` to Swift.
        if let escSeq = ansiEscapeForSpecialKey(
            keyCode: event.keyCode, modifiers: event.modifierFlags)
        {
            return makeKeyInputEvent(
                characters: escSeq,
                keycode: event.keyCode,
                modifiers: event.modifierFlags)
        }
        return makeKeyInputEvent(
            characters: chars,
            keycode: event.keyCode,
            modifiers: event.modifierFlags)
    }

    /// Translate special keycodes to the ANSI escape sequence the PTY
    /// expects. Returns nil for ordinary printable keys — the caller
    /// falls back to NSEvent.characters. Internal (not `private`) so
    /// the unit test target can exercise the shift+Return branch
    /// without synthesizing NSEvents (which is fragile in headless
    /// XCTest — see encoder header comment).
    static func ansiEscapeForSpecialKey(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let ESC = "\u{1B}"
        // Shift+Return → ESC+CR. Plain Return / Enter both send `\r`
        // (0x0D) — the byte is byte-identical with or without Shift,
        // so a TUI that wants to distinguish "submit" from "insert
        // newline" can't tell them apart without an extended keyboard
        // protocol. iTerm2 / Alacritty / WezTerm all encode Shift+Enter
        // as `ESC \r` by convention; Claude Code CLI, fish, readline
        // and other line editors interpret that sequence as "insert
        // a literal newline into the input buffer" without submitting.
        // Full kitty CSI u / modifyOtherKeys support deferred.
        let shift = modifiers.contains(.shift)
        if shift && (keyCode == 0x24 || keyCode == 0x4C) {  // Return / KeypadEnter
            return ESC + "\r"
        }
        // Shift+Tab → CSI Z ("back tab" / cursor backward tabulation).
        // Used by Claude CLI to cycle through modes (auto-accept,
        // plan, etc.) and by most readline-based TUIs to walk
        // completion candidates backwards. Plain Tab falls through to
        // NSEvent.characters (0x09); Shift+Tab needs the explicit
        // sequence because `characters` for Shift+Tab varies by
        // input source and isn't terminal-compatible.
        if shift && keyCode == 0x30 {  // Tab
            return ESC + "[Z"
        }
        switch keyCode {
        case 0x7E: return ESC + "[A"  // ↑
        case 0x7D: return ESC + "[B"  // ↓
        case 0x7C: return ESC + "[C"  // →
        case 0x7B: return ESC + "[D"  // ←
        case 0x73: return ESC + "[H"  // Home
        case 0x77: return ESC + "[F"  // End
        case 0x74: return ESC + "[5~"  // Page Up
        case 0x79: return ESC + "[6~"  // Page Down
        case 0x75: return ESC + "[3~"  // Forward Delete (fn-Delete)
        default: return nil
        }
    }

    /// Lower-level encoder. Builds an `InputEvent` from already-extracted
    /// fields. Tests use this directly to avoid the NSEvent factory's
    /// headless-XCTest fragility (windowNumber/context construction).
    /// `action` defaults to `.press` so the NSEvent thunk can omit it;
    /// keyUp / repeat get their own dispatch path at Week 2 task 2.10.
    static func makeKeyInputEvent(
        characters: String,
        keycode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        action: KeyAction = .press
    ) -> InputEvent {
        // Single swift-bridge call: `String.intoRustString()` invokes
        // `__swift_bridge__$RustString$new_with_str(rustStr)` with a
        // `RustStr { ptr, len }` view of the UTF-8 buffer. The Rust side
        // copies once into a sized `String`. Replaces the prior
        // `RustVec<UInt8>()` + per-byte `push` (2+N FFI calls) hot path.
        let textRust = characters.intoRustString()
        let codepoint: UInt32 = characters.unicodeScalars.first.map { $0.value } ?? 0

        let key = KeyEvent(
            codepoint: codepoint,
            keycode: UInt32(keycode),
            text: textRust,
            action: action.rawValue
        )

        // `mouse` is zeroed for key events. Rust dispatch in
        // bridge.rs only reads `event.key.text` for INPUT_EVENT_KEY;
        // the mouse fields are inert.
        let mouse = MouseEvent(col: 0, row: 0, button: 0, action: 0)

        return InputEvent(
            kind: InputEventKind.key.rawValue,
            key: key,
            mouse: mouse,
            modifiers: ModifierMask.from(modifiers).rawValue
        )
    }
}
