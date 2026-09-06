// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M6-5 Keybindings settings tab — UI for the 8 M6 actions.
//
// Settings → Keyboard is one of the three discoverability surfaces
// for app-action keybindings, alongside the menu bar and the command
// palette (ADR-0005).
//
// Responsibilities:
// - List each `KeybindingAction` with its title + current key
// - Capture a new key combo via `KeyCaptureField`
// - Reset-per-row + global "Reset all to defaults"
// - Show conflict warnings + reserved-range warnings as chips
// - Block save in capture if user picks a reserved-range key
//   (defense-in-depth alongside JSON-load reserved-range skip)

import AppKit
import SwiftUI

@MainActor
struct KeybindingsTab: View {
    @ObservedObject var store: KeybindingStore = .shared
    /// Capture state — when user clicks a row's "Change…" button,
    /// the corresponding action ID lands here and the row swaps to
    /// `KeyCaptureField` for that one action.
    @State private var capturingAction: KeybindingAction?
    /// Last reserved-key rejection for the capture toast.
    @State private var rejectedKey: String?
    /// S4: search-query filter. Empty → show every action. Otherwise
    /// match (case-insensitively) against title, raw value, current
    /// shortcut, and the action's category label.
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleCategories, id: \.self) { category in
                        categorySection(category)
                    }
                }
            }
            footer
        }
        .accessibilityIdentifier("settings.keybindings")
    }

    /// S4: categories that have at least one action matching the
    /// current search query. Preserves the enum's declaration order
    /// so the grouping stays stable.
    private var visibleCategories: [KeybindingAction.Category] {
        KeybindingAction.Category.allCases.filter { c in
            actionsMatching(query).contains { $0.category == c }
        }
    }

    private func actionsMatching(_ q: String) -> [KeybindingAction] {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            return KeybindingAction.allCases
        }
        let needle = q.lowercased()
        return KeybindingAction.allCases.filter { action in
            let key = (store.lookup(action) ?? "").lowercased()
            return action.title.lowercased().contains(needle)
                || action.rawValue.lowercased().contains(needle)
                || action.category.rawValue.lowercased().contains(needle)
                || key.contains(needle)
        }
    }

    @ViewBuilder
    private func categorySection(_ category: KeybindingAction.Category) -> some View {
        let actions = actionsMatching(query).filter { $0.category == category }
        if !actions.isEmpty {
            Text(category.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    Color(linear: Theme.Color.textSecondaryLinear)
                )
                .textCase(.uppercase)
                .padding(.horizontal, Theme.Spacing.three)
                .padding(.top, Theme.Spacing.two)
                .padding(.bottom, 4)
            ForEach(actions, id: \.self) { action in
                row(for: action)
                    .padding(.horizontal, Theme.Spacing.three)
                    .padding(.vertical, Theme.Spacing.one)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.one) {
            Text("Keybindings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(
                    Color(linear: Theme.Color.textPrimaryLinear))
            Text(
                "Customize keyboard shortcuts. Stored in "
                    + "~/.solidterm/keybindings.json."
            )
            .font(.system(size: 12))
            .foregroundColor(
                Color(linear: Theme.Color.textSecondaryLinear))
            // S4: search across title / raw / shortcut / category.
            HStack(spacing: Theme.Spacing.half) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(
                        Color(linear: Theme.Color.textTertiaryLinear))
                TextField("Filter actions or shortcuts…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.keybindings.search")
            }
            .padding(.top, 2)
            if !store.diagnostics.isEmpty {
                ForEach(0..<store.diagnostics.count, id: \.self) { i in
                    diagnosticChip(store.diagnostics[i])
                }
            }
            if let rk = rejectedKey {
                Text("Reserved: \(rk) is reserved for a future binding.")
                    .font(.system(size: 11))
                    .foregroundColor(
                        Color(linear: Theme.Color.accentWarningLinear)
                    )
                    .accessibilityIdentifier("settings.keybindings.reservedToast")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.three)
    }

    @ViewBuilder
    private func diagnosticChip(_ d: KeybindingDiagnostic) -> some View {
        HStack(spacing: Theme.Spacing.half) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(
                    Color(linear: Theme.Color.accentWarningLinear))
            Text(message(for: d))
                .font(.system(size: 11))
                .foregroundColor(
                    Color(linear: Theme.Color.textSecondaryLinear))
        }
    }

    private func message(for d: KeybindingDiagnostic) -> String {
        switch d {
        case .unknownAction(let a, let k):
            return "Unknown action \"\(a)\" at \(k) — skipped."
        case .reservedKey(let k, let a):
            return "Reserved key \"\(k)\" for \(a) — skipped."
        case .chordUnsupported(let k, let a):
            return "Chord \"\(k)\" for \(a) — runtime support pending."
        case .duplicateKey(let k, let kept, let dropped):
            return "Duplicate \"\(k)\" — kept \(kept), dropped \(dropped)."
        case .malformedFile(let r):
            return "Malformed file — using defaults. \(r)"
        }
    }

    @ViewBuilder
    private func row(for action: KeybindingAction) -> some View {
        HStack(spacing: Theme.Spacing.two) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        Color(linear: Theme.Color.textPrimaryLinear))
                Text(action.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(
                        Color(linear: Theme.Color.textTertiaryLinear))
            }
            Spacer(minLength: 0)
            if capturingAction == action {
                KeyCaptureField(
                    onCapture: { key in handleCapture(action: action, key: key) },
                    onCancel: { capturingAction = nil })
            } else {
                Text(displayKey(for: action))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(
                        Color(linear: Theme.Color.textSecondaryLinear)
                    )
                    .frame(minWidth: 100, alignment: .trailing)
                Button("Change…") { capturingAction = action }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Reset") {
                    try? store.resetActionToDefault(action)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isAtDefault(action))
            }
        }
        .accessibilityIdentifier("settings.keybindings.row.\(action.rawValue)")
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            Button("Reset all to defaults") {
                try? store.resetAllToDefaults()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings.keybindings.resetAll")
        }
        .padding(Theme.Spacing.three)
    }

    private func displayKey(for action: KeybindingAction) -> String {
        store.lookup(action) ?? "(unbound)"
    }

    private func isAtDefault(_ action: KeybindingAction) -> Bool {
        store.lookup(action) == KeybindingStore.defaults[action]
    }

    private func handleCapture(
        action: KeybindingAction, key: String
    ) {
        let normalized = KeybindingStore.normalizeKey(key)
        // Reserved-range gate — block save, show toast.
        if KeybindingStore.isReserved(normalized) {
            rejectedKey = normalized
            // Capture stays open so user can pick again.
            return
        }
        rejectedKey = nil
        capturingAction = nil
        // Build a new bindings array: existing user-bindings minus
        // anything pointing to `action` or to `normalized`, plus the
        // new entry. Disabled list survives.
        var current: KeybindingsFile = .init()
        if let data = try? Data(contentsOf: KeybindingStore.defaultFileURL()),
            let parsed = try? JSONDecoder().decode(
                KeybindingsFile.self, from: data)
        {
            current = parsed
        }
        current.bindings.removeAll {
            $0.action == action.rawValue
                || KeybindingStore.normalizeKey($0.key) == normalized
        }
        current.bindings.append(
            .init(
                key: normalized, action: action.rawValue))
        try? store.save(
            bindings: current.bindings, disabled: current.disabled)
    }
}

// MARK: - Key capture

/// AppKit-backed capture field: focuses on appearance, intercepts
/// the next non-modifier keyDown, returns it as a normalized string.
/// Cancel via Escape.
struct KeyCaptureField: NSViewRepresentable {
    var onCapture: (String) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let v = KeyCaptureNSView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        return v
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 24) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Theme.Radius.base, yRadius: Theme.Radius.base)
        NSColor(Color(linear: Theme.Color.bgTintSubtleLinear))
            .setFill()
        path.fill()
        NSColor(Color(linear: Theme.Color.accentRunningLinear))
            .setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(
                Color(linear: Theme.Color.textSecondaryLinear)),
        ]
        let str = NSAttributedString(
            string: "Press a key combo…", attributes: attrs)
        str.draw(at: NSPoint(x: 8, y: 4))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel?()
            return
        }
        guard let chars = event.charactersIgnoringModifiers,
            !chars.isEmpty
        else { return }
        var parts: [String] = []
        let mods = event.modifierFlags
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("alt") }
        if mods.contains(.shift) { parts.append("shift") }
        let key = chars.lowercased()
        // Filter out modifier-only keystrokes (e.g. holding cmd alone).
        guard !key.isEmpty,
            !key.allSatisfy({ $0.unicodeScalars.first?.value ?? 0 < 32 })
        else { return }
        parts.append(key)
        onCapture?(parts.joined(separator: "+"))
    }
}
