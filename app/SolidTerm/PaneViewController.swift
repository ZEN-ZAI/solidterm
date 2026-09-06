// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Each pane in a `PaneSplitter` is a `PaneViewController`.
// M4-2 scope ships the minimal shell — pane id +
// view + metadata stub — needed for `PaneSplitter` to position and own
// child views. The teammate spawn flow (M4-4) and per-pane chrome
// (M4-5/6/7) extend `PaneMetadata` and bind `kind = .teammate(...)`.
//
// `PaneMetadata`'s field shape comes from the design archive.
// Today only `userShell` is actually exercised; the other variants are
// declared so M4-4 can land without touching this file.

import AppKit

public final class PaneViewController: NSViewController {
    public enum PaneKind: Equatable {
        case userShell
        case teamLead(teamName: String)
        case teammate(teamName: String, role: String, color: AgentColor)
    }

    public struct PaneMetadata: Equatable {
        public var kind: PaneKind
        public var sessionId: String?
        public var title: String
        public var isNativeMode: Bool

        public init(
            kind: PaneKind = .userShell,
            sessionId: String? = nil,
            title: String = "zsh",
            isNativeMode: Bool = false
        ) {
            self.kind = kind
            self.sessionId = sessionId
            self.title = title
            self.isNativeMode = isNativeMode
        }
    }

    /// Pane id, unique within the window that owns this pane.
    public let paneId: UInt64
    public var metadata: PaneMetadata

    public init(paneId: UInt64, view: NSView, metadata: PaneMetadata = PaneMetadata()) {
        self.paneId = paneId
        self.metadata = metadata
        super.init(nibName: nil, bundle: nil)
        self.view = view
    }

    public required init?(coder: NSCoder) {
        fatalError("PaneViewController does not support storyboard instantiation")
    }
}

/// Teammate accent color identifier — concrete swatches resolved by the
/// chrome layer. Empty case set today; M4-4 wires the real palette.
public enum AgentColor: Equatable {
    case blue
    case green
    case orange
    case purple
    case red
    case teal
}
