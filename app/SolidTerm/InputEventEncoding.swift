// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Swift half of the FFI input path (ADR-0006). Translates
// AppKit `NSEvent.keyDown` into the FFI `InputEvent` shared struct that
// rust-expert's `TerminalSession.send_input` (#16-rust, commit 4706213)
// dispatches on. This file is pure data marshalling — no Metal types,
// no AppKit responder wiring, no FFI calls. The NSEvent overload is a
// thin AppKit thunk over the lower-level `makeKeyInputEvent(...)` so
// XCTest can exercise the encoder without manufacturing NSEvents
// (which `NSEvent.keyEvent(with:...)` makes painful in headless XCTest).
//
// Discriminator constants (kind / action / modifier-bit positions) are
// hardcoded with cite-comments to `crates/solidterm-ffi/src/bridge.rs`'s
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
// emitting different escape sequences.
//
// FocusStackManager routing (app-action shortcuts vs PTY pass-through) is
// a Week 4+ surface; today every keyDown that reaches `TerminalSurfaceView`
// gets encoded and sent to the session. Menu-bar-bound ⌘ shortcuts
// (⌘Q, ⌘N, ⌘W, ⌘H per `AppMenu`) are intercepted by AppKit before the
// responder chain, so they never reach this encoder. Non-menu ⌘ keystrokes
// pass through to the session as raw bytes — defensible for a terminal
// (vim, etc. legitimately want them) until FocusStackManager arrives.

import AppKit

/// `InputEvent.kind` discriminator. Mirror of `solidterm_ffi::kinds::INPUT_EVENT_*`.
enum InputEventKind: UInt8 {
    case key = 0  // kinds::INPUT_EVENT_KEY
    case mouse = 1  // kinds::INPUT_EVENT_MOUSE
    case focus = 2  // kinds::INPUT_EVENT_FOCUS
}

/// `KeyEvent.action` discriminator. Mirror of `solidterm_ffi::kinds::KEY_ACTION_*`.
enum KeyAction: UInt8 {
    case press = 0  // kinds::KEY_ACTION_PRESS
    case release = 1  // kinds::KEY_ACTION_RELEASE
    case `repeat` = 2  // kinds::KEY_ACTION_REPEAT
}

/// `InputEvent.modifiers` bitfield. Bit positions mirror
/// `solidterm_ffi::kinds::MODIFIER_BIT_*`.
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
    static func encode(
        _ event: NSEvent, kittyFlags: UInt8 = 0, appCursor: Bool = false,
        optionAsMeta: Bool = false
    ) -> InputEvent {
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
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            kittyFlags: kittyFlags, appCursor: appCursor)
        {
            return makeKeyInputEvent(
                characters: escSeq,
                keycode: event.keyCode,
                modifiers: event.modifierFlags)
        }
        // Option-as-meta: a printable Option+key emits ESC + the base
        // (un-composed) char rather than the macOS-composed glyph. Runs
        // AFTER the special-key check so arrows / fn keys keep their ANSI
        // sequences (and `metaCharacters` also rejects the function-key
        // private-use range as defense-in-depth). The caller (keyDown)
        // must have bypassed the IME so we never see the composed glyph.
        if let meta = metaCharacters(
            base: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            optionAsMeta: optionAsMeta)
        {
            return makeKeyInputEvent(
                characters: meta,
                keycode: event.keyCode,
                modifiers: event.modifierFlags)
        }
        return makeKeyInputEvent(
            characters: chars,
            keycode: event.keyCode,
            modifiers: event.modifierFlags)
    }

    /// Option-as-meta byte decision, factored out as a pure function over
    /// `(base, modifiers, optionAsMeta)` so it's unit-testable without the
    /// headless-fragile `NSEvent` factory (see file header). `base` is
    /// `NSEvent.charactersIgnoringModifiers` — the layout char the key
    /// would type *without* Option, so Shift+Option+b → "B" → `ESC B`
    /// (readline M-B), matching what readline / emacs / zsh expect.
    ///
    /// Returns `ESC + base` only when: the preference is on, Option is
    /// held, Control/Command are NOT (those carry their own terminal
    /// semantics), and `base`'s first scalar is a printable, non-DEL
    /// character outside the `0xF700…0xF8FF` AppKit function-key
    /// private-use range (arrows, F-keys, Home/End/PageUp report codes
    /// there and must keep their CSI/SS3 sequences). `nil` otherwise —
    /// the caller falls back to the normal (composed) character.
    static func metaCharacters(
        base: String?,
        modifiers: NSEvent.ModifierFlags,
        optionAsMeta: Bool
    ) -> String? {
        guard optionAsMeta else { return nil }
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.option),
            !mods.contains(.control),
            !mods.contains(.command),
            let base,
            let scalar = base.unicodeScalars.first,
            scalar.value >= 0x20,
            scalar.value != 0x7F,
            !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return "\u{1B}" + base
    }

    /// Translate special keycodes to the ANSI escape sequence the PTY
    /// expects. Returns nil for ordinary printable keys — the caller
    /// falls back to NSEvent.characters. Internal (not `private`) so
    /// the unit test target can exercise the shift+Return branch
    /// without synthesizing NSEvents (which is fragile in headless
    /// XCTest — see encoder header comment).
    static func ansiEscapeForSpecialKey(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        kittyFlags: UInt8 = 0, appCursor: Bool = false
    ) -> String? {
        let ESC = "\u{1B}"
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift)
        // Kitty keyboard protocol (any flag set ⇒ a TUI pushed it; bit0 =
        // disambiguate-esc-codes). Under the protocol an editor like
        // Claude Code expects *modified* Enter as a CSI u sequence so it
        // can tell "submit" (bare `\r`) from "insert newline"
        // (Shift+Enter → `\e[13;2u`). Kitty exempts *plain* Enter from
        // CSI u for shell compatibility, so we only upgrade when a
        // modifier is held; the rest of the keymap stays legacy (Claude
        // Code accepts legacy sequences for the keys we don't upgrade).
        if kittyFlags != 0,
            keyCode == 0x24 || keyCode == 0x4C,  // Return / KeypadEnter
            let m = kittyModifierParam(mods)
        {
            return ESC + "[13;\(m)u"
        }
        // Escape under the Kitty protocol (DISAMBIGUATE): report as
        // `\e[27u` (or `\e[27;<mod>u` when modified) — the canonical
        // disambiguation the flag exists for, so the app tells a real
        // Esc from the lead byte of an escape sequence without a timing
        // heuristic. Non-kitty Esc stays a bare `\x1b` (falls through to
        // event.characters in the caller).
        if kittyFlags != 0, keyCode == 0x35 {  // Escape
            if let m = kittyModifierParam(mods) { return ESC + "[27;\(m)u" }
            return ESC + "[27u"
        }
        // Non-kitty fallback for Shift+Return → ESC+CR. Plain Return /
        // Enter both send `\r` (0x0D) — byte-identical with or without
        // Shift — so without the kitty protocol a TUI can't distinguish
        // "submit" from "insert newline". iTerm2 / Alacritty / WezTerm
        // all encode Shift+Enter as `ESC \r` by convention; many line
        // editors read that as "insert a literal newline".
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
        // DECCKM (application-cursor-keys, CSI ?1 h): full-screen TUIs
        // (vim, less, htop, fzf) expect the cursor keys as SS3 (`\eOA`…)
        // rather than the normal CSI (`\e[A`…). Only the six cursor keys
        // switch — Page Up/Down and Forward-Delete stay CSI. Restricted
        // to the unmodified case: a held modifier keeps the legacy CSI
        // path (xterm uses CSI-with-param for modified cursor keys, and
        // shift+arrow is intercepted upstream for selection anyway).
        let hasMod =
            mods.contains(.shift) || mods.contains(.control)
            || mods.contains(.option) || mods.contains(.command)
        if appCursor && !hasMod {
            switch keyCode {
            case 0x7E: return ESC + "OA"  // ↑
            case 0x7D: return ESC + "OB"  // ↓
            case 0x7C: return ESC + "OC"  // →
            case 0x7B: return ESC + "OD"  // ←
            case 0x73: return ESC + "OH"  // Home
            case 0x77: return ESC + "OF"  // End
            default: break
            }
        }
        // Modified cursor / Home / End → CSI 1 ; <mod> <final> (xterm
        // "PC-Style Function Keys"; identical form under kitty
        // DISAMBIGUATE). Without this the modifier was silently dropped —
        // Ctrl/Alt/Shift+Arrow and Ctrl+Home/End arrived byte-identical to
        // a plain arrow, so word-motion and shift-extend died in
        // full-screen editors (Claude Code's prompt, vim, …) on the
        // alt-screen (where shift+arrow isn't intercepted for selection).
        // `kittyModifierParam` returns `1 + bitmask`, which IS the xterm
        // modifier parameter, so one branch is correct for both modes.
        if let m = kittyModifierParam(mods) {
            let letter: String?
            switch keyCode {
            case 0x7E: letter = "A"  // ↑
            case 0x7D: letter = "B"  // ↓
            case 0x7C: letter = "C"  // →
            case 0x7B: letter = "D"  // ←
            case 0x73: letter = "H"  // Home
            case 0x77: letter = "F"  // End
            default: letter = nil
            }
            if let l = letter { return ESC + "[1;\(m)\(l)" }
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

    /// Kitty keyboard protocol modifier parameter: `1 + bitmask`, where
    /// bitmask is shift(1) | alt(2) | ctrl(4) | super(8). Returns `nil`
    /// when no modifier is held — the caller leaves an unmodified key on
    /// its legacy path (e.g. plain Enter stays a bare `\r`). Shift alone
    /// → `1 + 1 = 2`, matching the `\e[13;2u` Shift+Enter sequence.
    static func kittyModifierParam(_ mods: NSEvent.ModifierFlags) -> Int? {
        var bits = 0
        if mods.contains(.shift) { bits |= 1 }
        if mods.contains(.option) { bits |= 2 }
        if mods.contains(.control) { bits |= 4 }
        if mods.contains(.command) { bits |= 8 }
        return bits == 0 ? nil : bits + 1
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
