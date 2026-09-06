// Pins the Finder → terminal drop path on `TerminalSurfaceView`:
// `shellQuote`, the two `NSDraggingDestination` answer methods, and the
// payload `performDragOperation` hands to the session. Ticket 13 moves
// all four into an extension file, so they get a behavioural net first
// (spec D10).
//
// The escaping table is the load-bearing part. A dropped path goes onto
// a live shell command line verbatim, so a hole in the quoting is a
// command-injection hole. The table asserts the exact strings, and
// `testShellQuoteRoundTripsThroughRealShell` hands each one to `/bin/sh`
// and compares what `printf %s` prints back — an independent oracle, not
// a restatement of the implementation.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class DragDropTests: XCTestCase {

    // MARK: - shellQuote

    /// Every path shape the drop path can meet, with the exact string
    /// the shell must receive. `shellQuote` wraps unconditionally — a
    /// plain path comes back as `'/tmp/plain'`, not unchanged — and the
    /// only character it rewrites is `'`, which closes the quote, emits
    /// an escaped literal quote, and reopens (`'\''`). Inside single
    /// quotes POSIX gives every other byte its literal value, so `$`,
    /// backtick, `\`, `"`, `*` and Thai UTF-8 all pass through as-is.
    private static let quotingTable: [(path: String, quoted: String)] = [
        ("/tmp/plain", "'/tmp/plain'"),
        ("/tmp/with space/file.txt", "'/tmp/with space/file.txt'"),
        ("/tmp/it's/file", #"'/tmp/it'\''s/file'"#),
        ("'", #"''\'''"#),
        ("/tmp/$HOME", "'/tmp/$HOME'"),
        ("/tmp/`whoami`", "'/tmp/`whoami`'"),
        (#"/tmp/back\slash"#, #"'/tmp/back\slash'"#),
        ("/tmp/double\"quote", "'/tmp/double\"quote'"),
        ("/tmp/glob*[a-z]?", "'/tmp/glob*[a-z]?'"),
        ("/tmp/paren(1)&;|", "'/tmp/paren(1)&;|'"),
        ("/tmp/ไฟล์ ทดสอบ.txt", "'/tmp/ไฟล์ ทดสอบ.txt'"),
        ("/tmp/新建文件夹/😀", "'/tmp/新建文件夹/😀'"),
        ("", "''"),
    ]

    func testShellQuoteMatchesTable() {
        for row in Self.quotingTable {
            XCTAssertEqual(
                TerminalSurfaceView.shellQuote(row.path), row.quoted,
                "shellQuote(\(row.path))")
        }
    }

    /// The oracle: a real `/bin/sh` expands the quoted form and
    /// `printf %s` writes the argument it actually got. If the escaping
    /// leaks a word split, a variable expansion or a command
    /// substitution, the bytes coming back differ from the path.
    func testShellQuoteRoundTripsThroughRealShell() throws {
        for row in Self.quotingTable {
            XCTAssertEqual(
                try Self.printfThroughShell(row.quoted), row.path,
                "sh round-trip of \(row.quoted)")
        }
    }

    /// Runs `printf %s <quoted>` under `/bin/sh` and returns stdout.
    /// Reads the pipe to EOF before `waitUntilExit()` so a large payload
    /// can't deadlock on a full pipe buffer.
    private static func printfThroughShell(_ quoted: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0, "sh exited non-zero for \(quoted)")
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - draggingEntered / draggingUpdated

    /// A pasteboard carrying file URLs advertises a copy: the drop is
    /// accepted and Finder draws the `+` badge. Both answer methods run
    /// the same predicate — `draggingUpdated` exists because AppKit only
    /// reuses the `draggingEntered` answer when the view does not
    /// implement it, and this view does.
    func testDragAnswersCopyForFileURLs() {
        let surface = TerminalSurfaceView(frame: Self.surfaceFrame)
        let info = StubDraggingInfo(pasteboard: makeFileURLPasteboard())
        XCTAssertEqual(surface.draggingEntered(info), .copy)
        XCTAssertEqual(surface.draggingUpdated(info), .copy)
    }

    /// A pasteboard with no file URL on it is refused outright — an
    /// empty `NSDragOperation` is the "not a drop target" answer, so the
    /// cursor stays a no-drop cursor and `performDragOperation` is never
    /// reached.
    func testDragAnswersNoneWithoutFileURLs() {
        let surface = TerminalSurfaceView(frame: Self.surfaceFrame)
        let empty = StubDraggingInfo(pasteboard: makePasteboard())
        XCTAssertEqual(surface.draggingEntered(empty), [])
        XCTAssertEqual(surface.draggingUpdated(empty), [])

        let text = makePasteboard()
        text.setString("/not/a/url", forType: .string)
        let info = StubDraggingInfo(pasteboard: text)
        XCTAssertEqual(surface.draggingEntered(info), [])
        XCTAssertEqual(surface.draggingUpdated(info), [])
    }

    /// The two sides read the pasteboard with different options: the
    /// answer methods ask `canReadObject(forClasses: [NSURL.self],
    /// options: nil)`, which any URL satisfies, while the drop asks for
    /// `urlReadingFileURLsOnly`. So a web URL dragged out of Safari is
    /// promised a copy and then declined. Pinned as-is — it is a
    /// cosmetic cursor-badge mismatch, not a wrong byte on the PTY, and
    /// changing it would be a behaviour change this branch does not
    /// make. If it is ever fixed, this test is the one to update.
    func testWebURLIsPromisedACopyThenDeclinedByTheDrop() {
        let surface = makeAttachedSurface()
        var fed: [String] = []
        surface.dropPayloadSink = { fed.append($0) }

        let board = makePasteboard()
        board.writeObjects([NSURL(string: "https://example.com/page")!])
        let info = StubDraggingInfo(pasteboard: board)

        XCTAssertEqual(surface.draggingEntered(info), .copy)
        XCTAssertEqual(surface.draggingUpdated(info), .copy)
        XCTAssertFalse(surface.performDragOperation(info))
        XCTAssertTrue(fed.isEmpty, "non-file URL fed \(fed) to the session")
    }

    // MARK: - performDragOperation

    /// Everything a test allocates and has to hand back in `tearDown`:
    /// the private pasteboards (global objects the window server keeps
    /// alive until released) and the host windows.
    private var pasteboards: [NSPasteboard] = []
    private var windows: [NSWindow] = []

    /// The drop itself. Two paths, one of them with a space, go on the
    /// pasteboard; what reaches the session is each path shell-quoted
    /// and joined by a single space — `'/a/b c' '/d/e'`. There is no
    /// trailing space and no unquoted path: `shellQuote` wraps every
    /// item, so the shell sees exactly two words however the names are
    /// spelled.
    func testPerformDragOperationFeedsQuotedSpaceJoinedPaths() {
        let surface = makeAttachedSurface()
        var fed: [String] = []
        surface.dropPayloadSink = { fed.append($0) }

        let info = StubDraggingInfo(pasteboard: makeFileURLPasteboard())
        XCTAssertTrue(surface.performDragOperation(info))

        XCTAssertEqual(fed, [#"'/a/b c' '/d/e'"#])
    }

    /// No file URL on the pasteboard means nothing is fed and the drop
    /// is declined, so AppKit passes it on rather than letting the view
    /// swallow it. The session exists here, which is what makes this an
    /// assertion about the URL guard and not about the session guard
    /// ahead of it.
    func testPerformDragOperationDeclinesPasteboardWithoutFileURLs() {
        let surface = makeAttachedSurface()
        XCTAssertNotNil(
            surface.rendererForTesting.session,
            "attached surface must own a session, else this asserts the wrong guard")
        var fed: [String] = []
        surface.dropPayloadSink = { fed.append($0) }

        let text = makePasteboard()
        text.setString("/not/a/url", forType: .string)
        XCTAssertFalse(surface.performDragOperation(StubDraggingInfo(pasteboard: text)))

        XCTAssertTrue(fed.isEmpty, "declined drop fed \(fed) to the session")
    }

    /// A surface inside a window, because `viewDidMoveToWindow` is what
    /// drives the renderer's session bring-up and `performDragOperation`
    /// guards on `renderer.session`. `windows` holds the only strong
    /// reference, so the host outlives the assertions and is torn down
    /// in `tearDown`.
    private func makeAttachedSurface() -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(frame: Self.surfaceFrame)
        let window = NSWindow(
            contentRect: Self.surfaceFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = surface
        windows.append(window)
        return surface
    }

    // MARK: - Pasteboard helpers

    private static let surfaceFrame = NSRect(x: 0, y: 0, width: 800, height: 480)

    /// The two paths the drop tests use, in the order they are written
    /// to the pasteboard. The first carries a space so the joined
    /// payload proves the quoting survives into the shell line.
    private static let droppedPaths = ["/a/b c", "/d/e"]

    /// A private, uniquely named pasteboard per call so parallel or
    /// re-run tests can't read each other's items, and so nothing here
    /// touches `NSPasteboard.general` (the user's real clipboard).
    /// Released in `tearDown`.
    private func makePasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("solidterm-drag-drop-\(UUID().uuidString)"))
        board.clearContents()
        pasteboards.append(board)
        return board
    }

    private func makeFileURLPasteboard() -> NSPasteboard {
        let board = makePasteboard()
        board.writeObjects(
            Self.droppedPaths.map { URL(fileURLWithPath: $0) as NSURL })
        return board
    }

    override func tearDown() {
        for board in pasteboards { board.releaseGlobally() }
        pasteboards.removeAll()
        for window in windows { window.contentView = nil }
        windows.removeAll()
        super.tearDown()
    }
}

/// Minimal stand-in for the drag session AppKit would hand the view.
/// `NSDraggingInfo` is a protocol, so a test can supply one; only
/// `draggingPasteboard` is read by the three methods under test, and
/// every other requirement answers with an inert value.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {

    let draggingPasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.draggingPasteboard = pasteboard
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var numberOfValidItemsForDrop: Int = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
