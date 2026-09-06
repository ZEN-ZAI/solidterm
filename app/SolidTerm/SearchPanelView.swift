// M7-2 ⌘F find-in-scrollback — SwiftUI body for the search panel.
//
// Layout: 480pt × 56pt, single-row search field + .* regex toggle +
// "n of m" indicator + ↑ / ↓ chevrons. Visual contract mirrors
// CommandPaletteView's chrome (overlay bg, 12pt radius, 30%-opacity
// border) so the two floating panels feel like the same family.
//
// Behavior:
// - typing → model.query updates → controller re-runs search
// - regex checkbox → model.useRegex flips → re-search
// - Return / ↓: next; Shift-Return / ↑: previous; Esc: dismiss

import AppKit
import SwiftUI

@MainActor
final class SearchPanelModel: ObservableObject {
    @Published var query: String = ""
    @Published var useRegex: Bool = false
    @Published var matches: [SearchMatchSwift] = []
    @Published var activeIndex: Int?
    /// Non-nil when the user typed an invalid regex; rendered as an
    /// inline syntax-error chip.
    @Published var parseError: String?

    enum JumpDirection { case next, previous }

    var onCommit: (JumpDirection) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onSearch: () -> Void = {}

    /// "n of m" indicator. Returns "0/0" when no query has been typed.
    var counterText: String {
        if matches.isEmpty {
            return query.isEmpty ? "" : "0/0"
        }
        let cur = (activeIndex ?? 0) + 1
        return "\(cur)/\(matches.count)"
    }
}

struct SearchPanelView: View {
    @ObservedObject var model: SearchPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.one) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(
                    Color(linear: Theme.Color.textTertiaryLinear)
                )
                .accessibilityHidden(true)

            SearchPanelSearchField(
                query: $model.query,
                onCommit: { shift in
                    model.onCommit(shift ? .previous : .next)
                },
                onDismiss: { model.onDismiss() },
                onChange: { model.onSearch() }
            )
            .focused($searchFocused)
            .accessibilityIdentifier("searchPanel.searchField")

            // Regex toggle. Tapping flips `useRegex` and re-runs the
            // search so the highlight set updates immediately.
            Button(action: {
                model.useRegex.toggle()
                model.onSearch()
            }) {
                Text(".*")
                    .font(
                        .system(
                            size: 12, weight: .medium, design: .monospaced)
                    )
                    .padding(.horizontal, Theme.Spacing.one)
                    .padding(.vertical, 2)
                    .background(
                        model.useRegex
                            ? Color(linear: Theme.Color.accentRunningLinear)
                                .opacity(0.25)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle regex")
            .accessibilityIdentifier("searchPanel.regexToggle")

            // n of m indicator
            Text(model.parseError != nil ? "regex error" : model.counterText)
                .font(.system(size: 11))
                .foregroundColor(
                    Color(linear: Theme.Color.textTertiaryLinear)
                )
                .frame(minWidth: 56, alignment: .trailing)
                .accessibilityIdentifier("searchPanel.counter")

            Button(action: { model.onCommit(.previous) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("searchPanel.prev")

            Button(action: { model.onCommit(.next) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("searchPanel.next")

            Button(action: { model.onDismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("searchPanel.close")
        }
        .padding(.horizontal, Theme.Spacing.two)
        .frame(width: 480, height: 56)
        .background(Color(linear: Theme.Color.bgOverlayLinear))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(
                    Color(linear: Theme.Color.textTertiaryLinear).opacity(0.3),
                    lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in scrollback")
        .onAppear { searchFocused = true }
    }
}

// MARK: - NSTextField wrapper

/// AppKit-backed search field — same SwiftUI focus-state workaround as
/// `CommandPaletteSearchField`. Forwards Return / Esc / arrow events
/// through the typed callbacks so the controller can drive jump /
/// dismiss behavior.
struct SearchPanelSearchField: NSViewRepresentable {
    @Binding var query: String
    /// `shift` is true when Shift was held during Return.
    var onCommit: (_ shift: Bool) -> Void
    var onDismiss: () -> Void
    var onChange: () -> Void

    func makeNSView(context: Context) -> SearchPanelTextField {
        let f = SearchPanelTextField()
        f.placeholderString = "Find in terminal…"
        f.font = NSFont.systemFont(ofSize: 14)
        f.textColor = NSColor(Color(linear: Theme.Color.textPrimaryLinear))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ nsView: SearchPanelTextField, context: Context) {
        if nsView.stringValue != query {
            nsView.stringValue = query
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchPanelSearchField
        init(parent: SearchPanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.query = f.stringValue
            parent.onChange()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSEvent.modifierFlags.contains(.shift)
                parent.onCommit(shift)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onDismiss()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onCommit(false)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onCommit(true)
                return true
            default:
                return false
            }
        }
    }
}

final class SearchPanelTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}
