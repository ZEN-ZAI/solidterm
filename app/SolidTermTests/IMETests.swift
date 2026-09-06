// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// IME on the Swift half. Phase 1
// task 3.11 / #19 — `NSTextInputClient` skeleton on `TerminalSurfaceView`:
// protocol conformance + `insertText` routing + sentinel returns from
// the 9 stubbed methods.
//
// M1 Week 4 task 4.9 wires real composition state, screen-space
// `firstRectForCharacterRange` for IME candidate-window anchoring, and
// the lifecycle (setMarkedText / unmarkText / commit-via-insertText).
// Composition is Swift-side only — preedit bytes never cross the FFI;
// only committed text reaches `session.send_input`.
//
// Live IME (Thai dead-key, CJK candidate selection, Korean preedit,
// macOS Dictation) requires user input via Input Sources; cannot be
// synthesized in xctest. The tests here drive the NSTextInputClient
// methods directly per protocol contract; live verification is owed
// to the user as the M1 exit gate.

import AppKit
import XCTest

@testable import SolidTerm

final class IMETests: XCTestCase {

    private static let initialBounds = NSRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Protocol conformance

    func testSurfaceViewConformsToNSTextInputClient() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertTrue(
            view is NSTextInputClient,
            "TerminalSurfaceView must adopt NSTextInputClient")
    }

    // MARK: - insertText routing

    func testInsertTextWithStringDoesNotCrash() {
        // The renderer's session is nil until `windowChanged` is called
        // (the XCTest harness never attaches the view to a window).
        // `insertText` must early-return cleanly when there's no session
        // — same pattern as `applyFrameDelta` (#17). This test pins the
        // happy-path no-crash behavior; byte-level verification of the
        // insertText → send_input contract lives in rust-expert's
        // dispatch tests (5 tests, bridge.rs:955-992).
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertNoThrow(
            view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNoThrow(
            view.insertText(
                "字", replacementRange: NSRange(location: NSNotFound, length: 0)))
    }

    func testInsertTextWithAttributedStringExtractsPlainString() {
        // NSTextInputClient.insertText takes `Any` because the IME
        // stack may pass either `NSString` or `NSAttributedString`
        // (e.g., macOS Dictation can pass attributed strings with
        // alternative-suggestion markers). The encoder takes only the
        // plain-string content; attribute info is discarded for the
        // skeleton. The test verifies the decode path doesn't trap
        // on the `default: return` branch when a real attributed
        // string is passed.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        let attributed = NSAttributedString(
            string: "hello",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        XCTAssertNoThrow(
            view.insertText(
                attributed,
                replacementRange: NSRange(location: NSNotFound, length: 0)))
    }

    func testInsertTextIgnoresUnknownArgumentType() {
        // Defensive: `insertText` declares `Any` for the string param.
        // If something other than NSString / NSAttributedString comes
        // through, the early-return must not crash. Pass an NSNumber
        // — definitely not a string type.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertNoThrow(
            view.insertText(
                NSNumber(value: 42),
                replacementRange: NSRange(location: NSNotFound, length: 0)))
    }

    // MARK: - No-composition defaults (post-4.9)

    func testSelectedRangeReturnsNotFoundWhenNotComposing() {
        // 4.9: returns NSNotFound when no composition is active. Once
        // `setMarkedText` fires, this returns the IME's selection-
        // within-preedit (covered by `testSelectedRangeMatchesIMESelection`).
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        let range = view.selectedRange()
        XCTAssertEqual(range.location, NSNotFound)
        XCTAssertEqual(range.length, 0)
    }

    func testMarkedRangeReturnsNotFoundWhenNotComposing() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        let range = view.markedRange()
        XCTAssertEqual(range.location, NSNotFound)
        XCTAssertEqual(range.length, 0)
    }

    func testHasMarkedTextReturnsFalseWhenNotComposing() {
        // Load-bearing: `keyDown`'s fall-through gate reads
        // `hasMarkedText()` to decide whether to direct-send the raw
        // event. False when no composition; flips true on
        // setMarkedText so composition keystrokes don't leak to the
        // PTY (covered by `testHasMarkedTextFlipsTrueDuringComposition`).
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertFalse(view.hasMarkedText())
    }

    func testAttributedSubstringReturnsNilWhenNotComposing() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertNil(
            view.attributedSubstring(
                forProposedRange: NSRange(location: 0, length: 5),
                actualRange: nil))
    }

    func testFirstRectReturnsZeroWithoutWindow() {
        // Defensive: when the view isn't in a window (xctest harness
        // path), firstRect returns `.zero`. Production launches always
        // have a window by the time an IME engages. The presence of
        // `actualRange` writes is verified separately so callers that
        // pass non-nil pointers can still rely on the API contract
        // even on the fallback path.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        var actual = NSRange(location: 0, length: 0)
        let rect = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: &actual)
        XCTAssertEqual(rect, .zero)
        XCTAssertEqual(actual.location, 0)
        XCTAssertEqual(actual.length, 1)
    }

    func testCharacterIndexReturnsZero() {
        // 4.9 documents this as a "graceful degradation" — IMEs
        // that depend on hit-testing within the preedit text get
        // composition-start. Atomic scope; surface as polish if
        // dogfood reveals a need.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertEqual(view.characterIndex(for: NSPoint(x: 100, y: 100)), 0)
    }

    // MARK: - 4.9 composition lifecycle

    func testSetMarkedTextStartsComposition() {
        // Set marked text → hasMarkedText flips true; markedRange
        // covers the full preedit; selectedRange returns the IME's
        // caret position within it.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "こ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testHasMarkedTextFlipsTrueDuringComposition() {
        // Pin the load-bearing keyDown-gate behavior: hasMarkedText
        // MUST return true while composition is active. Without this,
        // composition keystrokes (e.g., the Japanese kana that the IME
        // is still refining) would leak to the PTY through keyDown's
        // direct-send fall-through.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertFalse(view.hasMarkedText())
        view.setMarkedText(
            "あ",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
    }

    func testSetMarkedTextEmptyClearsComposition() {
        // Some input sources call setMarkedText("") instead of
        // unmarkText() to end composition. Both must behave identically.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "ก",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
    }

    func testUnmarkTextClearsComposition() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
    }

    func testSetMarkedTextWithAttributedStringExtractsPlainText() {
        // macOS hands us NSAttributedString in some IME paths
        // (Dictation; some Asian IMEs include per-clause attributes).
        // The extractor must pick out `.string` and store it as the
        // preedit text — attribute info is currently ignored (per-
        // clause rendering is post-MVP polish).
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        let attr = NSAttributedString(
            string: "ㅎ",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        view.setMarkedText(
            attr,
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
        let sub = view.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 1),
            actualRange: nil)
        XCTAssertEqual(sub?.string, "ㅎ")
    }

    func testSetMarkedTextWithUnknownTypeClearsComposition() {
        // Defensive: unknown payload (declared `Any` in the protocol)
        // clears any active composition rather than leaving stale
        // marked text on screen.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "ก",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText(
            NSNumber(value: 42),
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
    }

    func testInsertTextDuringCompositionClearsState() {
        // Commit path: insertText fires for the IME-resolved text.
        // Composition state MUST clear so the next keystroke isn't
        // gated by stale hasMarkedText. Pinning this ensures the
        // commit lifecycle stays correct under future refactors.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.insertText(
            "日",
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
    }

    func testSelectedRangeMatchesIMESelection() {
        // The IME's selection-within-preedit is reported back through
        // `selectedRange()`. Some IMEs use this to render their
        // caret position inside the marked text. We honor what the
        // IME passed in setMarkedText.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        let imeCaret = NSRange(location: 2, length: 1)  // Korean syllable selection
        view.setMarkedText(
            "한국어",
            selectedRange: imeCaret,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.selectedRange(), imeCaret)
    }

    // MARK: - 4.9 attributedSubstring

    func testAttributedSubstringReturnsRequestedRangeOfMarkedText() {
        // Reconversion / Dictation paths request a substring of the
        // marked text. Honor the requested range, clamping to the
        // composition's bounds.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "abc",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: 0, length: 0)
        let sub = view.attributedSubstring(
            forProposedRange: NSRange(location: 1, length: 1),
            actualRange: &actual)
        XCTAssertEqual(sub?.string, "b")
        XCTAssertEqual(actual, NSRange(location: 1, length: 1))
    }

    func testAttributedSubstringClampsBeyondCompositionBounds() {
        // Defensive: a request beyond composition length must clamp
        // rather than crash. Some IMEs over-request when refreshing
        // a candidate window.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        view.setMarkedText(
            "ab",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: 0, length: 0)
        let sub = view.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 100),
            actualRange: &actual)
        XCTAssertEqual(sub?.string, "ab")
        XCTAssertEqual(actual, NSRange(location: 0, length: 2))
    }

    // MARK: - 4.9 Thai dead-key composition (synthesized lifecycle)

    func testThaiDeadKeyCompositionLifecycle() {
        // Thai input often goes through a dead-key style preedit:
        // the consonant + vowel + tone marker are composed before
        // commit. Synthesize the sequence via the NSTextInputClient
        // contract to verify the full lifecycle reaches a clean state.
        // (Live Thai keyboard verification is owed to the user.)
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        // Step 1: leading consonant marked
        view.setMarkedText(
            "ก",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
        // Step 2: vowel added (preedit grows)
        view.setMarkedText(
            "ก่",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
        // Step 3: commit
        view.insertText(
            "ก่",
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
    }

    // MARK: - 4.9 paste payload helper still works (regression guard)

    func testPasteFormatStillWorksUnderCompositionRefactor() {
        // The paste payload helper is unrelated to composition but
        // shares the file with insertText routing. Pin its contract
        // here so a future composition refactor doesn't accidentally
        // change paste behavior.
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload("hi", bracketedPasteEnabled: false),
            "hi")
        XCTAssertEqual(
            TerminalSurfaceView.formatPastePayload("hi", bracketedPasteEnabled: true),
            "\u{1B}[200~hi\u{1B}[201~")
    }

    // MARK: - validAttributesForMarkedText — load-bearing for Dictation

    func testValidAttributesIncludesUnderlineStyle() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertTrue(
            view.validAttributesForMarkedText().contains(.underlineStyle),
            "validAttributesForMarkedText must include .underlineStyle for "
                + "preedit-underline rendering")
    }

    func testValidAttributesIncludesMarkedClauseSegment() {
        // **macOS Dictation fails silently without `.markedClauseSegment`**
        // This is the
        // single most-likely-to-rot detail in the IME skeleton — easy
        // to "clean up" by future agents who see no obvious consumer
        // and remove it. This test is the regression guard.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertTrue(
            view.validAttributesForMarkedText().contains(.markedClauseSegment),
            ".markedClauseSegment is REQUIRED for macOS Dictation; do not "
                + "remove it — Dictation fails silently without it")
    }

    // MARK: - keyDown still routes (no regression vs 979f331)

    func testKeyDownDoesNotCrashWithoutSession() {
        // The renderer's session is nil before windowChanged. keyDown
        // must early-return cleanly when no session exists — same
        // precondition as #17-swift's
        // `testRendererSessionStartsNilBeforeWindowAttached`. After #19,
        // the keyDown path goes through inputContext?.handleEvent
        // first, which can fire insertText / doCommand callbacks
        // synchronously. None of those should crash on the no-session
        // path either.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: CACurrentMediaTime(),
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0)
        else {
            XCTFail("synthetic NSEvent.keyEvent returned nil — methodology blocked")
            return
        }
        XCTAssertNoThrow(view.keyDown(with: event))
    }
}
