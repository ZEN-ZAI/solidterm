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
        XCTAssertNil(InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x24, modifiers: []))
        XCTAssertNil(InputEventEncoder.ansiEscapeForSpecialKey(
            keyCode: 0x4C, modifiers: []))
    }
}
