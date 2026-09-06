// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Theme TOML loader + hot-reload watcher. Salvaged pattern from
// zenzai-v2's Dango theme system per the 2026-04-22 postmortem:
// "19 tokens, 3 built-in themes (matcha, tokyo-night, gruvbox),
// hot-reload via config watcher."
//
// File layout: `~/.config/solidterm/themes/<name>.toml`. Schema matches
// the user's existing zenzai theme files (`~/.config/zenzai/themes/`)
// so they can be copied across:
//
//   name = "zenzai"
//   background = "#0F0F12"
//   foreground = "#E4E2DE"
//   cursor = "#7B9E7B"
//   selection = "#3A2A30"
//
//   [ansi]
//   black = "#2A2A30"
//   red = "#C47171"
//   ... (16 entries)
//
// Bundled defaults under `Resources/Themes/` are copied to the user's
// config dir on first launch so the picker has something to show.
//
// Hot-reload: a `DispatchSource.makeFileSystemObjectSource` on the
// themes directory fires `.write | .delete | .extend` events. The
// store re-scans + re-publishes; SwiftUI consumers (`Appearance`
// picker) and the renderer (`MetalRenderer.refreshClearColor`) pick
// up the new palette via the `themeFileDidChange` notification on
// the same path the explicit-mode picker uses.

import Combine
import Foundation
import simd

/// One parsed theme file. Only carries the tokens SolidTerm renders
/// against today; the `[ui]` section in the user's zenzai files is
/// ignored for now (SolidTerm has its own design-system layer).
public struct ThemeFile: Equatable {
    public let name: String
    public let background: SIMD4<Float>
    public let foreground: SIMD4<Float>
    public let cursor: SIMD4<Float>
    public let selection: SIMD4<Float>
    public let ansi: [SIMD4<Float>]  // 16 entries: 0..7 normal, 8..15 bright

    /// Resolve to a `Theme.Palette` for the cell sentinel-resolution
    /// path. The engine's `NamedColor::Foreground` / `Background`
    /// sentinels map to the file's `foreground` / `background`.
    var palette: Theme.Palette {
        Theme.Palette(
            defaultFgLinear: foreground,
            defaultBgLinear: background)
    }
}

/// Parse errors for `ThemeTOMLParser`.
public enum ThemeTOMLError: Error, Equatable {
    case missingKey(String)
    case malformedHex(String)
    case ansiTableIncomplete(missing: [String])
}

/// Hand-rolled subset TOML parser. Handles only `key = "#hex"` rows
/// and `[header]` section markers — enough for the zenzai theme
/// schema. Swift doesn't ship a TOML parser; adding a dependency for
/// 16 fields of `key = value` is overkill.
public enum ThemeTOMLParser {
    public static func parse(_ text: String) throws -> ThemeFile {
        var top: [String: String] = [:]
        var sections: [String: [String: String]] = [:]
        var currentSection: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                sections[currentSection!] = [:]
                continue
            }
            // key = "value" or key = value
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            var value = parts[1]
            // Strip surrounding quotes (single or double).
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            if let section = currentSection {
                sections[section, default: [:]][key] = value
            } else {
                top[key] = value
            }
        }

        let name = top["name"] ?? "untitled"
        let bg = try parseHex(top["background"] ?? "", key: "background")
        let fg = try parseHex(top["foreground"] ?? "", key: "foreground")
        let cursor = try parseHex(top["cursor"] ?? "", key: "cursor")
        let selection = try parseHex(top["selection"] ?? "", key: "selection")

        let ansiTable = sections["ansi"] ?? [:]
        let ansiKeys = [
            "black", "red", "green", "yellow",
            "blue", "magenta", "cyan", "white",
            "bright_black", "bright_red", "bright_green", "bright_yellow",
            "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
        ]
        let missing = ansiKeys.filter { ansiTable[$0] == nil }
        if !missing.isEmpty {
            throw ThemeTOMLError.ansiTableIncomplete(missing: missing)
        }
        let ansi = try ansiKeys.map { try parseHex(ansiTable[$0]!, key: "ansi.\($0)") }

        return ThemeFile(
            name: name, background: bg, foreground: fg,
            cursor: cursor, selection: selection, ansi: ansi)
    }

    /// Parse `#RRGGBB` into a linear-space `SIMD4<Float>`. Throws on
    /// malformed input; alpha is always 1.
    private static func parseHex(_ raw: String, key: String) throws -> SIMD4<Float> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#"), trimmed.count == 7 else {
            throw ThemeTOMLError.malformedHex("\(key): \(raw)")
        }
        let hex = String(trimmed.dropFirst())
        guard let value = UInt32(hex, radix: 16) else {
            throw ThemeTOMLError.malformedHex("\(key): \(raw)")
        }
        let rgba = (value << 8) | 0xff
        return SRGBLinearLUT.unpackLinear(rgba)
    }
}

/// Observable store + directory watcher. Singleton; `ThemeManager`
/// reads from this when a file-backed theme is active.
@MainActor
public final class ThemeFileStore: ObservableObject {
    public static let shared = ThemeFileStore()

    /// All themes currently on disk, keyed by file basename (no
    /// extension). Republished on directory change.
    @Published public private(set) var available: [String: ThemeFile] = [:]
    /// Currently-active theme. `nil` means "no file-backed theme;
    /// fall back to the built-in `Theme.Mode` cascade".
    @Published public private(set) var current: ThemeFile?

    /// `UserDefaults` key — the file basename of the active theme,
    /// or empty when the built-in mode picker drives.
    public static let activeKey = "solidterm.theme.fileBacked"
    /// Notification posted when `current` (or `available`) changes.
    /// `ThemeManager` re-broadcasts as `themeDidChange` so the
    /// renderer's existing observer wakes up.
    public static let didChange = Notification.Name("solidTermThemeFileDidChange")

    private let themesDir: URL
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1

    public init(themesDir: URL? = nil) {
        self.themesDir =
            themesDir
            ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".config/solidterm/themes", isDirectory: true)
        ensureSeeded()
        // CRITICAL: pass `notify: false` here. Posting the didChange
        // notification re-enters `ThemeFileStore.shared` via observers
        // (`MetalRenderer.themeFileObserver`), and since `shared` is
        // still being constructed at this point we'd recurse into the
        // same `dispatch_once` token — libdispatch traps with
        // "trying to lock recursively". Init-time observers haven't
        // subscribed yet, so skipping the post is safe.
        reload(notify: false)
        installWatcher()
    }

    /// User-facing API — set the active theme by file basename.
    /// Pass `nil` to revert to the built-in `Theme.Mode` cascade.
    public func setActive(_ name: String?) {
        if let name {
            UserDefaults.standard.set(name, forKey: Self.activeKey)
            current = available[name]
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
            current = nil
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Force a rescan + re-publish. Called on `init` (with notify=false
    /// to avoid recursive shared-singleton init via the observer chain)
    /// and on every directory-change event.
    public func reload(notify: Bool = true) {
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else {
            available = [:]
            return
        }
        var loaded: [String: ThemeFile] = [:]
        for url in contents where url.pathExtension == "toml" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let basename = url.deletingPathExtension().lastPathComponent
            if let file = try? ThemeTOMLParser.parse(text) {
                loaded[basename] = file
            }
        }
        available = loaded
        // Re-resolve the active theme from the freshly-loaded set.
        if let active = UserDefaults.standard.string(forKey: Self.activeKey),
            !active.isEmpty
        {
            current = loaded[active]
        }
        if notify {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Per-file copy of bundled `Resources/Themes/*.toml` into the
    /// user's config dir. Skips files that already exist so user
    /// edits survive across launches; brand-new themes added in a
    /// later SolidTerm update get installed automatically.
    private func ensureSeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: themesDir, withIntermediateDirectories: true)
        guard
            let bundled = Bundle.main.urls(
                forResourcesWithExtension: "toml", subdirectory: "Themes")
        else { return }
        for src in bundled {
            let dst = themesDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// DispatchSource watch on the themes directory. Fires on file
    /// add / delete / write + re-scans. Bounded — debouncing isn't
    /// needed at the cadence a human edits theme files.
    private func installWatcher() {
        let fd = open(themesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }
        source.resume()
        self.dirSource = source
    }

    deinit {
        dirSource?.cancel()
    }
}
