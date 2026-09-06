// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Tests for the ⌘⇧O fuzzy terminal switcher: the pure FuzzyMatch scorer
// and the TerminalSwitcherModel filter/navigation logic.

import AppKit
import XCTest

@testable import SolidTerm

final class FuzzyMatchTests: XCTestCase {

    func testEmptyNeedleMatchesEverythingNeutrally() {
        XCTAssertEqual(FuzzyMatch.score("", "anything"), 0)
        XCTAssertEqual(FuzzyMatch.score("", ""), 0)
    }

    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatch.score("xyz", "abc"))
        // Longer needle than haystack can never be a subsequence.
        XCTAssertNil(FuzzyMatch.score("abcd", "abc"))
        // Right letters, wrong order.
        XCTAssertNil(FuzzyMatch.score("ba", "ab"))
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score("src", "saxophone recursion"))
        XCTAssertNotNil(FuzzyMatch.score("solid", "zsh /Users/zen/solidterm"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score("ABC", "abcdef"))
        XCTAssertNotNil(FuzzyMatch.score("abc", "ABCDEF"))
    }

    func testConsecutiveOutranksScattered() {
        let consecutive = FuzzyMatch.score("src", "src")
        let scattered = FuzzyMatch.score("src", "saxophone recursion")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(consecutive!, scattered!)
    }

    func testBoundaryOutranksMidWord() {
        // "ab": in "a-b" the 'b' follows a boundary ('-'); in "axb" it
        // follows a non-boundary. The boundary alignment must score higher.
        let boundary = FuzzyMatch.score("ab", "a-b")
        let midWord = FuzzyMatch.score("ab", "axb")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary!, midWord!)
    }

    func testPathSegmentQueryRanksMatchingDirHigher() {
        // Querying a project name should rank that project's row above an
        // unrelated one that only matches by scattered letters.
        let solid = FuzzyMatch.score(
            "solidterm", "zsh /Users/zen/Projects/solidterm")
        let other = FuzzyMatch.score(
            "solidterm", "zsh /Users/zen/Projects/orchestration-tools-lib-demo")
        XCTAssertNotNil(solid)
        // `other` may or may not match; if it does, solid must win.
        if let other { XCTAssertGreaterThan(solid!, other) }
    }
}

@MainActor
final class TerminalSwitcherModelTests: XCTestCase {

    private func entry(_ id: Int, _ title: String, _ cwd: String)
        -> TerminalSwitcherEntry
    {
        TerminalSwitcherEntry(id: id, window: NSWindow(), title: title, cwd: cwd)
    }

    private func sampleModel() -> TerminalSwitcherModel {
        let m = TerminalSwitcherModel()
        m.entries = [
            entry(0, "zsh", "/Users/zen/Projects/solidterm"),
            entry(1, "vim", "/Users/zen/Projects/orchestration"),
            entry(2, "node", "/tmp"),
        ]
        return m
    }

    func testEmptyQueryReturnsAllInOrder() {
        let m = sampleModel()
        m.query = ""
        XCTAssertEqual(m.filtered.map(\.id), [0, 1, 2])
    }

    func testQueryFiltersToMatches() {
        let m = sampleModel()
        m.query = "solid"
        XCTAssertEqual(m.filtered.map(\.id), [0])
    }

    func testQueryRanksBestFirst() {
        let m = sampleModel()
        // "pro" hits "Projects" in both 0 and 1 (consecutive) — both
        // match; the result is non-empty and contains only those two.
        m.query = "pro"
        let ids = Set(m.filtered.map(\.id))
        XCTAssertTrue(ids.contains(0))
        XCTAssertTrue(ids.contains(1))
        XCTAssertFalse(ids.contains(2))
    }

    func testNoMatchYieldsEmpty() {
        let m = sampleModel()
        m.query = "zzzzzz"
        XCTAssertTrue(m.filtered.isEmpty)
    }

    func testMoveSelectionWrapsAround() {
        let m = sampleModel()
        m.query = ""
        XCTAssertEqual(m.selectedIndex, 0)
        m.moveSelection(-1)
        XCTAssertEqual(m.selectedIndex, 2, "up from the top wraps to the bottom")
        m.moveSelection(1)
        XCTAssertEqual(m.selectedIndex, 0, "down from the bottom wraps to the top")
        m.moveSelection(1)
        XCTAssertEqual(m.selectedIndex, 1)
    }

    func testMoveSelectionOnEmptyListIsNoOp() {
        let m = sampleModel()
        m.query = "zzzzzz"
        m.moveSelection(1)
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func testActivateSelectedInvokesCallbackWithHighlightedEntry() {
        let m = sampleModel()
        m.query = ""
        m.selectedIndex = 1
        var activated: TerminalSwitcherEntry?
        m.onActivate = { activated = $0 }
        m.activateSelected()
        XCTAssertEqual(activated?.id, 1)
    }

    func testResetSelectionReturnsToTop() {
        let m = sampleModel()
        m.query = ""
        m.selectedIndex = 2
        m.resetSelection()
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func testActivateWithStaleIndexIsSafe() {
        let m = sampleModel()
        m.query = ""
        m.selectedIndex = 99  // out of range
        var called = false
        m.onActivate = { _ in called = true }
        m.activateSelected()
        XCTAssertFalse(called, "out-of-range selection must not activate")
    }
}
