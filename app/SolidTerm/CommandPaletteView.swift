// M6-1 Command Palette — SwiftUI body.
//
// Visual contract per spec/ui-chrome-visual.md §Command palette:
// - 560pt fixed width, max 480pt height
// - 56pt search input (text-base 15pt, text-primary, placeholder text-tertiary)
// - 40pt result rows (text-sm 13pt font-weight-medium)
// - bg-overlay container; radius-lg (12pt); 1px text-tertiary @ 30% border
// - hover = bg-tint-subtle; active (kbd) = bg-tint-active + 2pt accent-running left rule
// - empty state: "No matches" (text-base) + "Try a different search" (text-sm), centered
//
// Behavior contract per spec/swift-app-modules.md §Command Palette (M6 MVP slice):
// - fuzzy-filter actions as user types (CommandPaletteFuzzy)
// - arrow-keys navigate; Return executes; Escape dismisses
//
// Slide+fade entry/exit animations are driven by the controller's NSPanel
// (frame animation + alphaValue), not SwiftUI — see CommandPaletteController.

import AppKit
import SwiftUI

/// Observable model for the palette — owns query string, selection
/// index, and the action list. Filtered list is computed each redraw
/// (cheap; ≤10 entries).
@MainActor
final class CommandPaletteModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectionIndex: Int = 0

    let actions: [CommandPaletteAction]
    var onCommit: (CommandPaletteAction) -> Void
    var onDismiss: () -> Void

    init(
        actions: [CommandPaletteAction] = CommandPaletteAction.allCases,
        onCommit: @escaping (CommandPaletteAction) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.actions = actions
        self.onCommit = onCommit
        self.onDismiss = onDismiss
    }

    /// Recompute filtered list from `query`. O(n) over a fixed small set.
    var filtered: [CommandPaletteAction] {
        CommandPaletteFuzzy.filter(actions, query: query)
    }

    func moveSelection(by delta: Int) {
        let count = filtered.count
        guard count > 0 else {
            selectionIndex = 0
            return
        }
        let next = (selectionIndex + delta) % count
        selectionIndex = next < 0 ? next + count : next
    }

    /// Reset to clean post-open state.
    func reset() {
        query = ""
        selectionIndex = 0
    }

    func commitSelected() {
        let list = filtered
        guard !list.isEmpty,
            list.indices.contains(selectionIndex) else { return }
        onCommit(list[selectionIndex])
    }
}

/// SwiftUI palette content. Hosted by `CommandPaletteController` inside
/// an `NSPanel`.
struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel

    /// Bound to the search field's first-responder state so the
    /// controller can re-focus on every show. SwiftUI's `@FocusState`
    /// resets when the view re-mounts, which matches our show/hide
    /// pattern (panel orderOut wipes the hosting view's focus).
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchInput
            divider
            resultsBody
        }
        .frame(width: 560)
        .frame(maxHeight: 480, alignment: .top)
        .background(Color(linear: Theme.Color.bgOverlayLinear))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(
                    Color(linear: Theme.Color.textTertiaryLinear).opacity(0.3),
                    lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
        .onAppear {
            searchFocused = true
        }
    }

    // MARK: Search input

    @ViewBuilder
    private var searchInput: some View {
        HStack(spacing: Theme.Spacing.one) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(
                    Color(linear: Theme.Color.textTertiaryLinear))
                .accessibilityHidden(true)
            CommandPaletteSearchField(
                query: $model.query,
                onCommit: { model.commitSelected() },
                onDismiss: { model.onDismiss() },
                onMove: { delta in model.moveSelection(by: delta) }
            )
            .focused($searchFocused)
            .accessibilityIdentifier("commandPalette.searchField")
        }
        .padding(.horizontal, Theme.Spacing.three)
        .frame(height: 56)
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(
                Color(linear: Theme.Color.textTertiaryLinear).opacity(0.3))
            .frame(height: 1)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsBody: some View {
        let items = model.filtered
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) {
                        idx, action in
                        row(action: action,
                            isActive: idx == model.selectionIndex)
                    }
                }
                .padding(.vertical, Theme.Spacing.half)
            }
        }
    }

    @ViewBuilder
    private func row(action: CommandPaletteAction, isActive: Bool) -> some View {
        HStack(spacing: Theme.Spacing.two) {
            // 2pt accent-running left rule on the active row.
            Rectangle()
                .fill(isActive
                    ? Color(linear: Theme.Color.accentRunningLinear)
                    : Color.clear)
                .frame(width: 2)
                .accessibilityHidden(true)
            Text(action.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(
                    Color(linear: Theme.Color.textPrimaryLinear))
                .accessibilityIdentifier(action.accessibilityId)
            Spacer(minLength: 0)
            if !action.shortcut.isEmpty {
                Text(action.shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(
                        Color(linear: Theme.Color.textTertiaryLinear))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Theme.Spacing.two - 2)  // 16 - 2pt rule
        .padding(.trailing, Theme.Spacing.two)
        .padding(.vertical, Theme.Spacing.half)
        .frame(height: 40)
        .background(
            isActive
                ? Color(linear: Theme.Color.bgTintActiveLinear)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onCommit(action) }
        .onHover { hovering in
            if hovering,
                let i = model.filtered.firstIndex(of: action) {
                model.selectionIndex = i
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.one) {
            Text("No matches")
                .font(.system(size: 15))
                .foregroundColor(
                    Color(linear: Theme.Color.textTertiaryLinear))
            Text("Try a different search")
                .font(.system(size: 13))
                .foregroundColor(
                    Color(linear: Theme.Color.textTertiaryLinear))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.six)
        .accessibilityIdentifier("commandPalette.emptyState")
    }
}

// MARK: - NSTextField wrapper (focus + key-handling on the input itself)

/// AppKit-backed search field. SwiftUI's `TextField` doesn't surface
/// arrow-key/Return/Escape events without scaffolding; an NSTextField
/// subclass keeps the wiring small and gives us control over the
/// caret + first-responder behavior the spec calls for ("cursor-default",
/// always-focused-on-show).
struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var query: String
    var onCommit: () -> Void
    var onDismiss: () -> Void
    /// `delta` is +1 for ArrowDown/Tab, -1 for ArrowUp/Shift-Tab.
    var onMove: (Int) -> Void

    func makeNSView(context: Context) -> CommandPaletteTextField {
        let f = CommandPaletteTextField()
        f.placeholderString = "Type a command..."
        f.font = NSFont.systemFont(ofSize: 15)
        f.textColor = NSColor(Color(linear: Theme.Color.textPrimaryLinear))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = context.coordinator
        f.onMove = onMove
        f.onDismiss = onDismiss
        return f
    }

    func updateNSView(_ nsView: CommandPaletteTextField, context: Context) {
        if nsView.stringValue != query {
            nsView.stringValue = query
        }
        nsView.onMove = onMove
        nsView.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteSearchField
        init(parent: CommandPaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.query = f.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onDismiss()
                return true
            case #selector(NSResponder.moveDown(_:)),
                #selector(NSResponder.insertTab(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)),
                #selector(NSResponder.insertBacktab(_:)):
                parent.onMove(-1)
                return true
            default:
                return false
            }
        }
    }
}

/// Subclass so we can override `performKeyEquivalent(_:)` for the
/// rare cases where AppKit doesn't route an arrow keystroke through
/// `doCommandBy:` (e.g. when an IME composition is active).
final class CommandPaletteTextField: NSTextField {
    var onMove: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
}
