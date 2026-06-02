// Tests for PlainLinkDetector — pure functions, no PTY / Metal / session.

import XCTest

@testable import SolidTerm

final class PlainLinkDetectorTests: XCTestCase {

    private let d = PlainLinkDetector.shared
    private let cols = 200

    // MARK: - URLs

    func testHttpsURLDetected() {
        let hit = d.detect(in: "Visit https://example.com for info", hoveredCol: 6, terminalCols: cols)
        guard case .url(let url)? = hit?.kind else { return XCTFail("expected .url") }
        XCTAssertEqual(url.absoluteString, "https://example.com")
        XCTAssertEqual(hit?.startCol, 6)
    }

    func testURLSpanCoversWholeURL() {
        let url = "https://foo.bar/path?q=1"
        let hit = d.detect(in: "See \(url)", hoveredCol: 4, terminalCols: cols)
        XCTAssertEqual(hit?.startCol, 4)
        XCTAssertEqual(hit?.span, url.count)
    }

    func testColumnOutsideURLReturnsNil() {
        // col 0 = 'S' of "See", not inside the URL.
        XCTAssertNil(d.detect(in: "See https://example.com here", hoveredCol: 0, terminalCols: cols))
    }

    func testFtpSchemeRejected() {
        XCTAssertNil(d.detect(in: "ftp://example.com/file", hoveredCol: 0, terminalCols: cols),
            "ftp is outside the scheme allowlist")
    }

    func testFileSchemeRejected() {
        // file:// must NOT become a one-click hyperlink (disclosure risk);
        // local files go through the existence-gated path branch instead.
        XCTAssertNil(d.detect(in: "open file:///etc/hosts now", hoveredCol: 5, terminalCols: cols),
            "file:// URLs are not promoted to clickable hyperlinks")
    }

    // MARK: - File paths

    func testAbsoluteExistingPathDetected() {
        // /tmp exists on every macOS box.
        let hit = d.detect(in: "See /tmp for scratch", hoveredCol: 4, terminalCols: cols)
        guard case .filePath(let url)? = hit?.kind else { return XCTFail("expected .filePath") }
        XCTAssertEqual(url.path, "/tmp")
    }

    func testNonExistentPathReturnsNil() {
        XCTAssertNil(d.detect(in: "/definitely/not/here/xyz123", hoveredCol: 0, terminalCols: cols),
            "non-existent paths must not be clickable")
    }

    func testRelativePathNotPromoted() {
        // No leading / or ~, so "src/foo.rs" is never anchored as a path.
        XCTAssertNil(d.detect(in: "src/foo.rs builds", hoveredCol: 0, terminalCols: cols))
    }

    // MARK: - Column mapping

    func testColumnMapAccountsForWideChars() {
        // '字' is two cells; subsequent chars shift right by one extra col.
        let map = ColumnMap(rowText: "字/tmp", terminalCols: cols)
        XCTAssertEqual(map.colForChar[0], 0)  // 字
        XCTAssertEqual(map.colForChar[1], 2)  // '/'
        XCTAssertEqual(map.colForChar[2], 3)  // 't'
    }

    // MARK: - Safety guards

    func testEmptyRowReturnsNil() {
        XCTAssertNil(d.detect(in: "", hoveredCol: 0, terminalCols: 80))
    }

    func testOversizedRowReturnsNil() {
        XCTAssertNil(d.detect(in: String(repeating: "a", count: 4097), hoveredCol: 0, terminalCols: 80))
    }
}
