// Implements spec/ffi-boundary.md §Input path round-trip on the Swift
// half. Exercises `InputEventEncoder.makeKeyInputEvent(...)` — the
// AppKit-free overload that the `NSEvent`-taking entry point delegates
// to. Tests target the lower-level overload so the synthetic-NSEvent
// factory's headless-XCTest fragility never enters this file.
//
// The Rust side has 5 dispatch tests covering what `send_input` does
// with the InputEvent once Swift hands it across the FFI; this file
// covers the Swift half: that the encoder produces the right shape for
// ASCII / multibyte / modifier combinations, that the discriminator
// constants line up with `solidterm_ffi::kinds::*`, and that the
// modifier bitfield is derived correctly from `NSEvent.modifierFlags`.
//
// `KeyEvent.text` is `RustString` post-#16-perf (was `RustVec<UInt8>`).
// Tests assert via `text.toString()` rather than per-byte inspection.

import AppKit
import XCTest

@testable import SolidTerm

final class InputEventEncodingTests: XCTestCase {

    // MARK: - Discriminator constants align with bridge.rs::kinds

    func testInputEventKindRawValuesMatchKinds() {
        // bridge.rs:75-79 : INPUT_EVENT_KEY=0, _MOUSE=1, _FOCUS=2.
        XCTAssertEqual(InputEventKind.key.rawValue, 0)
        XCTAssertEqual(InputEventKind.mouse.rawValue, 1)
        XCTAssertEqual(InputEventKind.focus.rawValue, 2)
    }

    func testKeyActionRawValuesMatchKinds() {
        // bridge.rs:82-84 : KEY_ACTION_PRESS=0, _RELEASE=1, _REPEAT=2.
        XCTAssertEqual(KeyAction.press.rawValue, 0)
        XCTAssertEqual(KeyAction.release.rawValue, 1)
        XCTAssertEqual(KeyAction.repeat.rawValue, 2)
    }

    func testModifierMaskBitPositionsMatchKinds() {
        // bridge.rs:107-110 : MODIFIER_BIT_SHIFT=0, _CTRL=1, _ALT=2, _SUPER=3.
        XCTAssertEqual(ModifierMask.shift.rawValue, 0b0000_0001)
        XCTAssertEqual(ModifierMask.ctrl.rawValue, 0b0000_0010)
        XCTAssertEqual(ModifierMask.alt.rawValue, 0b0000_0100)
        XCTAssertEqual(ModifierMask.super.rawValue, 0b0000_1000)
    }

    // MARK: - Modifier translation

    func testModifierMaskFromEmptyFlagsIsEmpty() {
        let mask = ModifierMask.from([])
        XCTAssertTrue(mask.isEmpty)
    }

    func testModifierMaskFromShiftFlag() {
        let mask = ModifierMask.from(.shift)
        XCTAssertTrue(mask.contains(.shift))
        XCTAssertFalse(mask.contains(.ctrl))
        XCTAssertFalse(mask.contains(.alt))
        XCTAssertFalse(mask.contains(.super))
    }

    func testModifierMaskFromCommandMapsToSuper() {
        // AppKit calls it `command`; the FFI calls it `super` (Linux/Wayland
        // convention). The mapping is a documentation concern; the test
        // ensures the bridge stays correct.
        let mask = ModifierMask.from(.command)
        XCTAssertTrue(mask.contains(.super))
        XCTAssertFalse(mask.contains(.shift))
    }

    func testModifierMaskFromComboFlags() {
        let mask = ModifierMask.from([.shift, .control, .option, .command])
        XCTAssertTrue(mask.contains(.shift))
        XCTAssertTrue(mask.contains(.ctrl))
        XCTAssertTrue(mask.contains(.alt))
        XCTAssertTrue(mask.contains(.super))
        XCTAssertEqual(mask.rawValue, 0b0000_1111)
    }

    // MARK: - Encoder shape (lower-level overload)

    func testEncodeAsciiLetter() {
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "a", keycode: 0, modifiers: [], action: .press)

        XCTAssertEqual(event.kind, InputEventKind.key.rawValue)
        XCTAssertEqual(event.key.codepoint, UInt32(Unicode.Scalar("a").value))
        XCTAssertEqual(event.key.keycode, 0)
        XCTAssertEqual(event.key.text.toString(), "a")
        XCTAssertEqual(event.key.action, KeyAction.press.rawValue)
        XCTAssertEqual(event.modifiers, 0)
    }

    func testEncodeAsciiDigit() {
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "0", keycode: 29, modifiers: [], action: .press)
        XCTAssertEqual(event.key.codepoint, UInt32(Unicode.Scalar("0").value))
        XCTAssertEqual(event.key.keycode, 29)
        XCTAssertEqual(event.key.text.toString(), "0")
    }

    func testEncodeUppercaseViaShiftModifier() {
        // NSEvent.characters is modifier-resolved: when the user holds
        // shift+'a', AppKit reports characters: "A". The encoder takes
        // that resolved string verbatim and additionally records the
        // modifier bitfield so the eventual Kitty/CSI encoder (Week 2
        // task 2.10) has both signals.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "A", keycode: 0, modifiers: .shift, action: .press)

        XCTAssertEqual(event.key.codepoint, UInt32(Unicode.Scalar("A").value))
        XCTAssertEqual(event.key.text.toString(), "A")
        XCTAssertEqual(event.modifiers & ModifierMask.shift.rawValue, ModifierMask.shift.rawValue)
        XCTAssertEqual(event.modifiers & ModifierMask.super.rawValue, 0)
    }

    func testEncodeMultibyteGrapheme() {
        // "字" is 3 bytes in UTF-8 (0xE5 0xAD 0x97). Engine receives the
        // bytes verbatim — Rust `bridge.rs::send_input` calls
        // `event.key.text.as_bytes()` and forwards to the engine's
        // `handle_key_text(&[u8])`.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "字", keycode: 0, modifiers: [], action: .press)

        XCTAssertEqual(event.key.codepoint, 0x5B57)  // "字" Unicode scalar
        XCTAssertEqual(event.key.text.toString(), "字")
    }

    func testEncodeEmptyCharactersIsZeroLengthText() {
        // Modifier-only keystrokes (e.g. holding ⌘ alone) report
        // characters as empty/nil — NSEvent.characters returns nil and
        // the encoder substitutes "". The engine no-ops empty bytes
        // today; the InputEvent is still emitted so #19 / Week 2 work
        // can see modifier-only events when needed.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "", keycode: 55, modifiers: .command, action: .press)

        XCTAssertEqual(event.key.codepoint, 0)
        XCTAssertEqual(event.key.text.toString(), "")
        XCTAssertEqual(event.key.keycode, 55)
        XCTAssertEqual(event.modifiers & ModifierMask.super.rawValue, ModifierMask.super.rawValue)
    }

    func testEncodeCtrlLetter() {
        // ⌃a — NSEvent.characters reports the resolved control byte
        // (0x01) on macOS for letter keys. The encoder records that
        // verbatim along with the ctrl bit; the Week 2 Kitty/legacy CSI
        // encoder owns the policy of whether to keep, rewrite, or
        // strip it.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "\u{01}", keycode: 0, modifiers: .control, action: .press)

        XCTAssertEqual(event.key.codepoint, 0x01)
        XCTAssertEqual(event.key.text.toString(), "\u{01}")
        XCTAssertEqual(event.modifiers & ModifierMask.ctrl.rawValue, ModifierMask.ctrl.rawValue)
    }

    func testEncodeOptionLetterIncludesAltBit() {
        // ⌥a — NSEvent.characters reports the option-resolved character
        // ("å" on US layout). The encoder records the resolved string and
        // sets the alt bit so Week 2's Kitty/CSI encoder has both signals.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "å", keycode: 0, modifiers: .option, action: .press)

        XCTAssertEqual(event.key.codepoint, 0xE5)  // "å"
        XCTAssertEqual(event.modifiers & ModifierMask.alt.rawValue, ModifierMask.alt.rawValue)
        XCTAssertEqual(event.modifiers & ModifierMask.shift.rawValue, 0)
        XCTAssertEqual(event.modifiers & ModifierMask.ctrl.rawValue, 0)
        XCTAssertEqual(event.modifiers & ModifierMask.super.rawValue, 0)
    }

    func testEncodeUsesPressActionByDefault() {
        // The lower-level overload defaults `action: KeyAction = .press`
        // so the NSEvent thunk and call sites that don't care about
        // keyUp/repeat can omit it. Week 2 task 2.10 (Kitty/CSI) is
        // where keyUp/repeat get distinct encoding.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "a", keycode: 0, modifiers: [])

        XCTAssertEqual(event.key.action, KeyAction.press.rawValue)
    }

    func testEncodeMouseFieldsAreZeroForKeyEvent() {
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "x", keycode: 7, modifiers: [], action: .press)
        XCTAssertEqual(event.mouse.col, 0)
        XCTAssertEqual(event.mouse.row, 0)
        XCTAssertEqual(event.mouse.button, 0)
        XCTAssertEqual(event.mouse.action, 0)
    }

    func testEncodeKeycodePassthrough() {
        // The encoder passes NSEvent.keyCode through verbatim. The Kitty
        // encoder at Week 2 will use it for non-character keys (arrows,
        // function keys, etc.). Today it's recorded but not used.
        let event = InputEventEncoder.makeKeyInputEvent(
            characters: "", keycode: 126, modifiers: [], action: .press)
        XCTAssertEqual(event.key.keycode, 126)  // up arrow on US layout
    }

    // MARK: - Shift+Return escape (iTerm2/Alacritty convention)

    func testShiftReturnEmitsEscCR() {
        // Plain Return falls through to NSEvent.characters ("\r"); the
        // special-key path returns nil. Shift+Return emits ESC+CR so a
        // TUI can distinguish "submit" from "insert newline".
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x24, modifiers: .shift)
        XCTAssertEqual(seq, "\u{1B}\r")
    }

    func testShiftKeypadEnterEmitsEscCR() {
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x4C, modifiers: .shift)
        XCTAssertEqual(seq, "\u{1B}\r")
    }

    func testPlainReturnFallsThroughToCharacters() {
        // Without shift, Return takes the NSEvent.characters path so
        // the standard `\r` byte reaches the PTY unchanged.
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x24, modifiers: []))
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x4C, modifiers: []))
    }

    // MARK: - Kitty keyboard protocol: modified Enter → CSI u

    func testShiftEnterUnderKittyEmitsCSIu() {
        // With kitty disambiguate active (flag bit0), Shift+Enter must
        // be `\e[13;2u` so Claude Code reads it as "insert newline",
        // distinct from the bare `\r` "submit". Modifier param = 1 +
        // shift(1) = 2.
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x24, modifiers: .shift, kittyFlags: 0x01)
        XCTAssertEqual(seq, "\u{1B}[13;2u")
    }

    func testShiftKeypadEnterUnderKittyEmitsCSIu() {
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x4C, modifiers: .shift, kittyFlags: 0x01)
        XCTAssertEqual(seq, "\u{1B}[13;2u")
    }

    func testCtrlEnterUnderKittyEmitsCSIu() {
        // Ctrl modifier → kitty param 1 + ctrl(4) = 5.
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x24, modifiers: .control, kittyFlags: 0x01)
        XCTAssertEqual(seq, "\u{1B}[13;5u")
    }

    func testPlainEnterUnderKittyStaysBareCR() {
        // Kitty exempts *unmodified* Enter from CSI u — it must fall
        // through to NSEvent.characters (`\r`), never `\e[13;1u`.
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x24, modifiers: [], kittyFlags: 0x01))
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x4C, modifiers: [], kittyFlags: 0x01))
    }

    func testShiftEnterWithoutKittyKeepsEscCR() {
        // No kitty flags active → the legacy ESC+CR convention stands,
        // so non-kitty TUIs and the existing contract are unaffected.
        let seq = InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x24, modifiers: .shift, kittyFlags: 0)
        XCTAssertEqual(seq, "\u{1B}\r")
    }

    // MARK: - DECCKM: application-cursor-keys → SS3

    func testCursorKeysEmitSS3UnderAppCursor() {
        // DECCKM on: the six cursor keys switch from CSI to SS3.
        let cases: [(UInt16, String)] = [
            (0x7E, "\u{1B}OA"),  // ↑
            (0x7D, "\u{1B}OB"),  // ↓
            (0x7C, "\u{1B}OC"),  // →
            (0x7B, "\u{1B}OD"),  // ←
            (0x73, "\u{1B}OH"),  // Home
            (0x77, "\u{1B}OF"),  // End
        ]
        for (key, want) in cases {
            XCTAssertEqual(
                InputEventEncoder.ansiEscapeForSpecialKey(
                    keyCode: key, modifiers: [], appCursor: true),
                want, "keyCode \(key) under app-cursor")
        }
    }

    func testCursorKeysStayCSIWithoutAppCursor() {
        // DECCKM off (default) → the normal CSI form is unchanged.
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7E, modifiers: [], appCursor: false),
            "\u{1B}[A")
    }

    func testModifiedCursorKeysEmitCSI1ModParam() {
        // Modified cursor / Home / End carry the modifier in CSI 1;<mod>
        // form (xterm "PC-Style Function Keys"; same under kitty). The
        // modifier param is 1 + (shift1|alt2|ctrl4): Ctrl=5, Shift=2,
        // Alt=3. App-cursor must NOT collapse a modified key to SS3.
        XCTAssertEqual(  // Ctrl+Up
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7E, modifiers: .control, appCursor: true),
            "\u{1B}[1;5A")
        XCTAssertEqual(  // Shift+Left
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7B, modifiers: .shift),
            "\u{1B}[1;2D")
        XCTAssertEqual(  // Alt(Option)+Right
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x7C, modifiers: .option),
            "\u{1B}[1;3C")
        XCTAssertEqual(  // Ctrl+End
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x77, modifiers: .control),
            "\u{1B}[1;5F")
    }

    // MARK: - Escape under the Kitty protocol

    func testEscapeEmitsCSI27uUnderKitty() {
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x35, modifiers: [], kittyFlags: 0x01),
            "\u{1B}[27u")
        XCTAssertEqual(  // Shift+Esc → param 2
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x35, modifiers: .shift, kittyFlags: 0x01),
            "\u{1B}[27;2u")
    }

    func testEscapeStaysBareWithoutKitty() {
        // No kitty → nil here; caller falls back to event.characters (\x1b).
        XCTAssertNil(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x35, modifiers: [], kittyFlags: 0))
    }

    func testPageKeysStayCSIUnderAppCursor() {
        // Page Up/Down and Forward-Delete aren't cursor keys — DECCKM
        // leaves them on CSI.
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x74, modifiers: [], appCursor: true),
            "\u{1B}[5~")
        XCTAssertEqual(
            InputEventEncoder.ansiEscapeForSpecialKey(
                keyCode: 0x79, modifiers: [], appCursor: true),
            "\u{1B}[6~")
    }

    // MARK: - Option-as-Meta (ESC-prefix)

    func testMetaCharactersEscPrefixesBaseChar() {
        // Option+b with the pref on → ESC b (readline M-b).
        XCTAssertEqual(
            InputEventEncoder.metaCharacters(
                base: "b", modifiers: .option, optionAsMeta: true),
            "\u{1B}b")
    }

    func testMetaCharactersUsesShiftedBase() {
        // charactersIgnoringModifiers already resolves Shift → "B";
        // M-B (backward-word) is valid, so Shift+Option+b → ESC B.
        XCTAssertEqual(
            InputEventEncoder.metaCharacters(
                base: "B", modifiers: [.option, .shift], optionAsMeta: true),
            "\u{1B}B")
    }

    func testMetaCharactersNilWhenPrefOff() {
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: "b", modifiers: .option, optionAsMeta: false))
    }

    func testMetaCharactersNilWithoutOption() {
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: "b", modifiers: [], optionAsMeta: true))
    }

    func testMetaCharactersNilWhenControlOrCommandHeld() {
        // Control+Option / Command+Option carry their own semantics —
        // not meta.
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: "b", modifiers: [.option, .control], optionAsMeta: true))
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: "b", modifiers: [.option, .command], optionAsMeta: true))
    }

    func testMetaCharactersNilForFunctionKeyPrivateUse() {
        // Arrows / fn keys report NSEvent private-use codepoints
        // (0xF700+); they must keep CSI/SS3, never become ESC+<pua char>.
        let up = String(UnicodeScalar(0xF700)!)  // NSUpArrowFunctionKey
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: up, modifiers: .option, optionAsMeta: true))
    }

    func testMetaCharactersNilForDeleteAndControlChars() {
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: String(UnicodeScalar(0x7F)!),  // DEL
                modifiers: .option, optionAsMeta: true))
        XCTAssertNil(
            InputEventEncoder.metaCharacters(
                base: String(UnicodeScalar(0x01)!),  // Ctrl-A control char
                modifiers: .option, optionAsMeta: true))
    }
}
