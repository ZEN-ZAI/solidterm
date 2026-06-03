// ⌘⇧O fuzzy terminal switcher — SwiftUI body, model, and entry type.
//
// A floating overlay (sibling to the ⌘F search panel; see
// SearchPanelView) listing every open terminal across all windows and
// native tabs, fuzzy-filtered by title + working directory. ↑/↓ move the
// selection (wrap-around), Return focuses that terminal, Esc dismisses.
// Visual contract matches the search panel: overlay bg, 12pt radius,
// 30%-opacity border.

import AppKit
import SwiftUI

/// One row in the switcher: a single terminal (window or native tab).
struct TerminalSwitcherEntry: Identifiable {
    let id: Int
    /// The terminal's NSWindow. Held strongly only for the brief life of
    /// the overlay — the model clears its entries on dismiss, so no
    /// window is retained past the switcher's visible lifetime.
    let window: NSWindow
    let title: String
    /// Absolute working directory (may be empty before the first OSC 7).
    let cwd: String

    /// Haystack for fuzzy matching — title and full path together so a
    /// query can hit the program/title OR any path segment.
    var searchText: String { "\(title) \(cwd)" }

    /// Home-abbreviated cwd for display ("~/Projects/solidterm").
    var displayCwd: String {
        if cwd.isEmpty { return "" }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }
}

@MainActor
final class TerminalSwitcherModel: ObservableObject {
    @Published var entries: [TerminalSwitcherEntry] = []
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0

    var onActivate: (TerminalSwitcherEntry) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    /// Entries matching the current query, ranked best-first. An empty
    /// query returns every entry in enumeration order. Ties break by id
    /// so the order is stable.
    var filtered: [TerminalSwitcherEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return entries }
        return entries
            .compactMap { e in FuzzyMatch.score(q, e.searchText).map { (e, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .map(\.0)
    }

    /// Move the highlighted row by `delta`, wrapping around the filtered
    /// list. No-op on an empty list.
    func moveSelection(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { selectedIndex = 0; return }
        selectedIndex = ((selectedIndex + delta) % n + n) % n
    }

    /// Reset the highlight to the top — called whenever the query changes
    /// (the ranked list reorders under it).
    func resetSelection() { selectedIndex = 0 }

    func activateSelected() {
        let f = filtered
        guard f.indices.contains(selectedIndex) else { return }
        onActivate(f[selectedIndex])
    }
}

struct TerminalSwitcherView: View {
    @ObservedObject var model: TerminalSwitcherModel
    @FocusState private var fieldFocused: Bool

    static let panelWidth: CGFloat = 560
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.one) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(Color(linear: Theme.Color.textTertiaryLinear))
                    .accessibilityHidden(true)
                SwitcherSearchField(
                    query: $model.query,
                    onMove: { model.moveSelection($0) },
                    onActivate: { model.activateSelected() },
                    onDismiss: { model.onDismiss() },
                    onChange: { model.resetSelection() }
                )
                .focused($fieldFocused)
                .accessibilityIdentifier("switcher.searchField")
            }
            .padding(.horizontal, Theme.Spacing.two)
            .frame(height: Self.headerHeight)

            Rectangle()
                .fill(Color(linear: Theme.Color.textTertiaryLinear).opacity(0.25))
                .frame(height: 1)

            list
        }
        .frame(width: Self.panelWidth)
        .background(Color(linear: Theme.Color.bgOverlayLinear))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(
                    Color(linear: Theme.Color.textTertiaryLinear).opacity(0.3),
                    lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch terminal")
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var list: some View {
        let items = model.filtered
        if items.isEmpty {
            Text(model.entries.isEmpty ? "No open terminals" : "No match")
                .font(.system(size: 12))
                .foregroundColor(Color(linear: Theme.Color.textTertiaryLinear))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("switcher.empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                            TerminalSwitcherRow(
                                entry: entry, isSelected: idx == model.selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = idx
                                    model.activateSelected()
                                }
                        }
                    }
                }
                .onChange(of: model.selectedIndex) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct TerminalSwitcherRow: View {
    let entry: TerminalSwitcherEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.one) {
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundColor(Color(linear: Theme.Color.textSecondaryLinear))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? "Terminal" : entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(linear: Theme.Color.textPrimaryLinear))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !entry.displayCwd.isEmpty {
                    Text(entry.displayCwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(linear: Theme.Color.textTertiaryLinear))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.two)
        .frame(height: TerminalSwitcherView.rowHeight)
        .background(
            isSelected
                ? Color(linear: Theme.Color.bgTintActiveLinear)
                : Color.clear)
    }
}

// MARK: - NSTextField wrapper (mirrors SearchPanelSearchField)

/// AppKit-backed query field — same first-responder workaround as the
/// search field. Forwards Return / Esc / ↑ / ↓ through typed callbacks so
/// the controller drives activation / dismiss / navigation.
struct SwitcherSearchField: NSViewRepresentable {
    @Binding var query: String
    var onMove: (_ delta: Int) -> Void
    var onActivate: () -> Void
    var onDismiss: () -> Void
    var onChange: () -> Void

    func makeNSView(context: Context) -> SwitcherTextField {
        let f = SwitcherTextField()
        f.placeholderString = "Switch to terminal…"
        f.font = NSFont.systemFont(ofSize: 14)
        f.textColor = NSColor(Color(linear: Theme.Color.textPrimaryLinear))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ nsView: SwitcherTextField, context: Context) {
        if nsView.stringValue != query { nsView.stringValue = query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SwitcherSearchField
        init(parent: SwitcherSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.query = f.stringValue
            parent.onChange()
        }

        func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onActivate()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onDismiss()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            default:
                return false
            }
        }
    }
}

final class SwitcherTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}
