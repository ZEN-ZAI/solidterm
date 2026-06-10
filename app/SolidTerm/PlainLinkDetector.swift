// PlainLinkDetector — finds plain URLs and bare file paths in a terminal
// row string so ⌘-hover / ⌘-click works on output that didn't emit an
// OSC 8 hyperlink. OSC 8 still takes priority (the caller checks it
// first); this is the fallback.
//
// Design constraints:
//  • No Rust changes — runs on `session.row_text(row)` Swift-side.
//  • NSDataDetector for URLs; a single linear NSRegularExpression for
//    absolute / home-relative file paths.
//  • URL scheme allowlist: http, https, mailto only. `file` is
//    deliberately excluded — a malicious TUI could print
//    `file:///Users/you/.ssh/id_rsa` and turn it into a one-click
//    disclosure; local files instead go through the path regex, which
//    gates on on-disk existence and opens via the configured editor.
//    The OSC 8 hyperlink path in TerminalSurfaceView shares this same
//    allowlist via `sanctionedURL(fromTerminalContent:)`, keeping both
//    open-paths behind one policy.
//  • File paths: absolute (/…) or home-relative (~…), must exist on disk
//    before becoming clickable, capped at 512 chars to bound the stat().
//  • Opening is gated entirely on the caller's explicit ⌘-click — this
//    type never opens anything or touches the network.

import Foundation

/// A detected link and where it sits within a terminal row.
struct DetectedLink: Equatable {
    enum Kind: Equatable {
        /// http/https/mailto URL — opened via NSWorkspace on ⌘-click.
        case url(URL)
        /// Absolute or ~-relative path that exists — opened in the
        /// configured editor on ⌘-click.
        case filePath(URL)
    }
    let kind: Kind
    /// Terminal column of the first cell of the match.
    let startCol: Int
    /// Number of terminal columns the match spans (wide-char aware).
    let span: Int
}

/// Maps the i-th `Character` of a row string to the terminal column it
/// starts at. `row_text` emits one Character per primary cell (alacritty
/// skips wide-char spacer cells), so wide characters occupy two columns
/// but one Character — we advance the column counter by the display
/// width. For ASCII (every URL / path) the map is identity; the wide
/// handling only keeps the underline aligned when a row has leading CJK.
struct ColumnMap {
    /// `colForChar[i]` = terminal column where Character i begins.
    let colForChar: [Int]

    init(rowText: String, terminalCols: Int) {
        var cols: [Int] = []
        cols.reserveCapacity(rowText.count)
        var col = 0
        for ch in rowText {
            guard col < terminalCols else { break }
            cols.append(col)
            col += ch.isWideTerminalCharacter ? 2 : 1
        }
        self.colForChar = cols
    }

    /// Convert an NSRange (UTF-16 offsets into `string`) to a
    /// `(startCol, span)` pair, or nil if it falls outside the mapped
    /// columns. The span includes the last matched character's width.
    func columnSpan(for nsRange: NSRange, in string: String) -> (startCol: Int, span: Int)? {
        guard let range = Range(nsRange, in: string) else { return nil }
        let startCharIdx = string.distance(from: string.startIndex, to: range.lowerBound)
        let endCharIdx = string.distance(from: string.startIndex, to: range.upperBound)
        guard startCharIdx >= 0, startCharIdx < colForChar.count,
            endCharIdx > startCharIdx
        else { return nil }
        let lastCharIdx = endCharIdx - 1
        guard lastCharIdx < colForChar.count else { return nil }
        let lastChar = string[string.index(string.startIndex, offsetBy: lastCharIdx)]
        let lastWidth = lastChar.isWideTerminalCharacter ? 2 : 1
        let startCol = colForChar[startCharIdx]
        let span = colForChar[lastCharIdx] + lastWidth - startCol
        return span > 0 ? (startCol, span) : nil
    }
}

final class PlainLinkDetector {
    static let shared = PlainLinkDetector()

    /// ftp/ssh/etc. are excluded — they would launch an external handler
    /// the user may not expect. `file` is excluded for the disclosure
    /// reason in the file header.
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Single policy gate for ANY terminal-content URL the app may open:
    /// the plain-text detection below AND the OSC 8 hyperlink hover path
    /// in TerminalSurfaceView. Returns nil unless the scheme is in
    /// `allowedSchemes` — a remote program controls OSC 8 URIs byte-for-
    /// byte, so an unfiltered open is an arbitrary-scheme launch vector.
    static func sanctionedURL(fromTerminalContent raw: String) -> URL? {
        guard let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// Guard against pathological rows; row_text is one row so this is
    /// generous (a normal row is bounded by the column count).
    private static let maxRowChars = 4096
    /// Cap path candidates before the existence stat().
    private static let maxPathChars = 512

    // NSDataDetector compiles a private engine once; reused across hovers.
    private let urlDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    // Absolute (/…) or home-relative (~/… or bare ~) path. Linear-time:
    // a single negated character class, no nested quantifiers, so it
    // can't ReDoS on adversarial output. Stops at whitespace and shell /
    // punctuation delimiters.
    private let pathRegex = try! NSRegularExpression(
        pattern: #"(?:/|~/|~(?!/))[^\s"',;><()\[\]]*"#)

    private init() {}

    /// Detect a URL or existing file path spanning `hoveredCol` in
    /// `rowText`. Returns nil when nothing matches the hovered cell, a
    /// URL's scheme is outside the allowlist, a path doesn't exist on
    /// disk, or the row is empty / oversized.
    func detect(in rowText: String, hoveredCol: Int, terminalCols: Int) -> DetectedLink? {
        guard !rowText.isEmpty, rowText.count <= Self.maxRowChars else { return nil }
        let map = ColumnMap(rowText: rowText, terminalCols: terminalCols)
        let nsText = rowText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // 1. URLs (http/https/mailto) via NSDataDetector.
        for m in urlDetector.matches(in: rowText, options: [], range: fullRange) {
            guard let url = m.url,
                let scheme = url.scheme?.lowercased(),
                Self.allowedSchemes.contains(scheme),
                let (startCol, span) = map.columnSpan(for: m.range, in: rowText)
            else { continue }
            let clamped = min(span, max(0, terminalCols - startCol))
            guard startCol <= hoveredCol, hoveredCol < startCol + clamped else { continue }
            return DetectedLink(kind: .url(url), startCol: startCol, span: clamped)
        }

        // 2. Absolute / home-relative file paths that exist on disk.
        for m in pathRegex.matches(in: rowText, options: [], range: fullRange) {
            let raw = nsText.substring(with: m.range)
            guard raw.count <= Self.maxPathChars else { continue }
            let expanded = raw.hasPrefix("~") ? (raw as NSString).expandingTildeInPath : raw
            guard FileManager.default.fileExists(atPath: expanded),
                let (startCol, span) = map.columnSpan(for: m.range, in: rowText)
            else { continue }
            let clamped = min(span, max(0, terminalCols - startCol))
            guard startCol <= hoveredCol, hoveredCol < startCol + clamped else { continue }
            return DetectedLink(
                kind: .filePath(URL(fileURLWithPath: expanded)),
                startCol: startCol, span: clamped)
        }

        return nil
    }
}

private extension Character {
    /// Approximates alacritty's display-width oracle: true for the East
    /// Asian Wide / Fullwidth ranges and most emoji (two terminal cells).
    /// A miss only shifts the hover underline by a cell — URL/path hit
    /// detection is unaffected since those are ASCII.
    var isWideTerminalCharacter: Bool {
        for s in unicodeScalars {
            let v = s.value
            switch v {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
                0x3400...0x4DBF,  // CJK Ext A
                0x4E00...0x9FFF,  // CJK Unified Ideographs
                0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF01...0xFF60,
                0xFFE0...0xFFE6:
                return true
            default:
                if v >= 0x1F300 { return true }
            }
        }
        return false
    }
}
