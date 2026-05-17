// M7-3 — Font settings store. Single source of truth for the
// terminal-cell font (family, point size, ligatures), backed by
// `UserDefaults` so the choice round-trips across launches.
//
// Why centralized: prior to M7-3 three call-sites hardcoded
// "Menlo-Regular" 14pt (TerminalSurfaceView.gridContentSize,
// MetalRenderer.windowChanged, TerminalSurfaceView.fontDescriptor).
// Routing through this store keeps them in lockstep when the user
// runs ⌘+/⌘-/⌘0 or edits the picker in Settings → Appearance.
//
// Atlas regen: `MetalRenderer` subscribes to `Self.didChange` and
// rebuilds its `GlyphAtlas` + `GridPipeline` when the family or size
// changes (the atlas is keyed by `(fontHash, glyphId, pxSize)` so a
// size change invalidates every entry — cheaper to rebuild than to
// evict glyph-by-glyph).

import AppKit
import CoreText
import Foundation

@MainActor
public final class FontSettings: ObservableObject {
    /// Process-wide singleton; the few call-sites that resolve the
    /// active font read through this. Tests use `init(defaults:)` to
    /// stand up an isolated store against a temp `UserDefaults` suite.
    public static let shared = FontSettings(defaults: .standard)

    /// `UserDefaults` keys. Public so tests can poke / inspect.
    public enum Keys {
        public static let family = "solidterm.font.family"
        public static let size = "solidterm.font.size"
        public static let ligatures = "solidterm.font.ligatures"
    }

    /// Default font family. JetBrainsMono ships in the user's
    /// `~/Library/Fonts` and is the family their zenzai config
    /// selected (`~/.config/zenzai/config.toml`). `makeCTFont` falls
    /// back to Menlo automatically when the platform can't resolve
    /// the PostScript name (fresh install on a machine without
    /// JetBrains Mono).
    public static let defaultFamily = "JetBrainsMono-Regular"

    /// Default point size. 14pt was the spike/M1 hardcoded value;
    /// staying with it keeps the existing atlas cell metrics + the
    /// `gridContentSize(80, 24)` window-snap result identical for
    /// pre-M7-3 users.
    public static let defaultSize: CGFloat = 14

    /// Inclusive size clamp. iTerm2 / Terminal.app use roughly the
    /// same range; values outside this band are clamped at the API
    /// surface (setSize / increase / decrease) so callers can pass
    /// any value without pre-validating.
    public static let minSize: CGFloat = 8
    public static let maxSize: CGFloat = 32

    /// Notification name posted when any font setting changes.
    /// `MetalRenderer` observes this to trigger atlas regeneration.
    /// Posted on the main run loop; observer block runs on main.
    public static let didChange = Notification.Name("solidterm.font.didChange")

    @Published public private(set) var family: String
    @Published public private(set) var size: CGFloat
    @Published public private(set) var ligatures: Bool

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.family =
            defaults.string(forKey: Keys.family) ?? Self.defaultFamily
        let storedSize = defaults.object(forKey: Keys.size) as? Double
        self.size = Self.clamp(
            storedSize.map { CGFloat($0) } ?? Self.defaultSize)
        // Default ligatures off — Menlo doesn't ship a ligature
        // table, so until a font that does (Fira Code etc.) lands
        // this is a no-op visually but the bit still round-trips.
        self.ligatures =
            (defaults.object(forKey: Keys.ligatures) as? Bool) ?? false
    }

    // MARK: - Mutators

    /// Set the active family. Empty / whitespace-only strings are
    /// rejected (silently — the picker doesn't allow empty input).
    public func setFamily(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != family else { return }
        family = trimmed
        defaults.set(trimmed, forKey: Keys.family)
        notifyChange()
    }

    /// Set the point size. Clamped to `[minSize, maxSize]`.
    public func setSize(_ raw: CGFloat) {
        let clamped = Self.clamp(raw)
        guard clamped != size else { return }
        size = clamped
        defaults.set(Double(clamped), forKey: Keys.size)
        notifyChange()
    }

    /// ⌘+ — bump size by 1pt, clamped.
    public func increaseSize() { setSize(size + 1) }
    /// ⌘- — drop size by 1pt, clamped.
    public func decreaseSize() { setSize(size - 1) }
    /// ⌘0 — restore the built-in default size (not the last saved
    /// value, per spec/m7 brief).
    public func resetSize() { setSize(Self.defaultSize) }

    public func setLigatures(_ on: Bool) {
        guard on != ligatures else { return }
        ligatures = on
        defaults.set(on, forKey: Keys.ligatures)
        notifyChange()
    }

    // MARK: - Resolved CTFont

    /// Build a `CTFont` from the current family + size. Falls back
    /// to Menlo if the family resolves nil (NSFontManager returned
    /// a font the platform doesn't actually have a descriptor for).
    public func makeCTFont() -> CTFont {
        Self.makeCTFont(family: family, size: size)
    }

    /// Stateless variant used by tests + `gridContentSize` so
    /// callers without a `FontSettings` instance can resolve the
    /// same fallback chain.
    public static func makeCTFont(family: String, size: CGFloat) -> CTFont {
        let primary = CTFontCreateWithName(family as CFString, size, nil)
        // CTFontCreateWithName always returns a CTFont, but if the
        // family doesn't exist it silently falls back to the system
        // font — which is variable-width and would visibly break the
        // grid. Detect that case by checking the resolved PostScript
        // name + falling back through a monospace cascade.
        let resolvedName = CTFontCopyName(primary, kCTFontPostScriptNameKey)
            as String? ?? ""
        if resolvedName == family
            || resolvedName.lowercased().contains("menlo")
            || resolvedName.lowercased().contains("jetbrainsmono")
        {
            return primary
        }
        // Cascade: requested family → JetBrains Mono → Menlo.
        // System default (Helvetica) breaks the grid — guard against it.
        for fallback in ["JetBrainsMono-Regular", "Menlo-Regular"] {
            let font = CTFontCreateWithName(fallback as CFString, size, nil)
            let name = CTFontCopyName(font, kCTFontPostScriptNameKey) as String? ?? ""
            if name == fallback {
                return font
            }
        }
        // True last resort — even Menlo unresolvable. Return primary
        // (system default) and let the user see the broken grid as a
        // visible signal something is wrong.
        return primary
    }

    // MARK: - Helpers

    public static func clamp(_ raw: CGFloat) -> CGFloat {
        min(max(raw, minSize), maxSize)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
