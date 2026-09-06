// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Minimal pane container — solidterm has no team-mode split panes.
// Kept as a thin shim so the rest of the app (`TerminalWindowController`,
// tests) doesn't need to special-case "is there a splitter?" everywhere.
//
// One pane only. The Rust-side `WindowPaneTree` was removed when
// solidterm stripped Claude features; this class is now just an
// NSSplitView with a single arranged subview.

import AppKit
import Combine

public final class PaneSplitter: NSSplitView {
    /// Insertion-ordered pane list. Always exactly one entry.
    private(set) public var panes: [PaneViewController] = []

    private let panesSubject = CurrentValueSubject<[PaneViewController], Never>([])
    public var panesPublisher: AnyPublisher<[PaneViewController], Never> {
        panesSubject.eraseToAnyPublisher()
    }

    public init(initial: PaneViewController) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dividerStyle = .thin
        isVertical = true
        delegate = self
        panes = [initial]
        addArrangedSubview(initial.view)
        panesSubject.send(panes)
    }

    public required init?(coder: NSCoder) {
        fatalError("PaneSplitter does not support storyboard instantiation")
    }

    public override func layout() {
        super.layout()
        if let only = panes.first {
            only.view.frame = bounds
        }
    }

    /// Test-only accessors — kept for compatibility with the test suite
    /// after the multi-pane stripdown.
    internal var enginePaneCount: UInt32 { UInt32(panes.count) }
    internal func engineContains(_ paneId: UInt64) -> Bool {
        panes.contains(where: { $0.paneId == paneId })
    }
    internal var currentSplitId: UInt64? { nil }
}

public enum SplitDirection {
    case horizontal
    case vertical
}

extension PaneSplitter: NSSplitViewDelegate {
    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
