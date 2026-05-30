// Implements spec/metal-renderer.md §Frame Pacing and the Stage 1
// full-screen cell pass. Per-frame work: clear the drawable to the
// theme color, encode the entire grid through `GridPipeline` in a
// single 4-vertex draw call, present. Frame times are logged on a
// rolling 240-sample window so the kill-criterion gate at #8 can
// baseline against measured GPU costs.
//
// On first attach the grid is initialized blank (every cell `glyph =
// nil`, theme bg + fg). Real content is driven from the engine via
// `applyFrameDelta` (4.1) — and the keystroke-driven cell mutation in
// `recordKeystroke` continues to drive a single cell from
// `randomGlyphs` so the latency harness has a guaranteed visible
// state-change per keystroke (memory: feedback_meaningful_latency_measurement).

import AppKit
import CoreText
import Darwin
import Metal
import QuartzCore

final class MetalRenderer {
    /// Default grid dimensions for first attach. The values mirror
    /// the historical 80×24 spike so `TerminalWindowController`'s
    /// initial frame still snaps cleanly to a familiar shell layout;
    /// `resizeGrid(cols:rows:)` (4.8) replaces them as the window
    /// resizes from there. Kept private — the live values live on
    /// `gridCols` / `gridRows` instance properties below, and external
    /// readers go through `viewportCols` / `viewportRows`.
    private static let defaultGridCols = 80
    private static let defaultGridRows = 24
    /// Live grid dimensions, owned by the renderer post-attach.
    /// Mutated by `resizeGrid(cols:rows:)` (4.8) on host-side window
    /// resize. Read by selection clamping (`encodeSelection`),
    /// cursor clamping (`encodeCursorOverlay`), the blank-grid initial
    /// fill (`makeBlankGrid`), and `viewportCols` / `viewportRows`.
    private(set) var gridCols: Int = MetalRenderer.defaultGridCols
    private(set) var gridRows: Int = MetalRenderer.defaultGridRows

    /// Pixel format the attached layer + downstream pipelines were
    /// built with. Captured on `attach(layer:)` so `resizeGrid` can
    /// rebuild `GridPipeline` without a separate format-source.
    /// Defaults to `.bgra8Unorm_srgb` — what `TerminalSurfaceView`
    /// pins on its `CAMetalLayer` (`makeBackingLayer`).
    private var attachedPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    /// Counter for `resizeGrid` invocations that actually rebuilt the
    /// pipeline (skipped early-returns don't tick). Test-only seam so
    /// `WindowChromeTests` can verify idempotency without poking
    /// pipeline internals.
    var resizeRebuildCount: Int = 0

    /// Glyph alphabet used by `recordKeystroke` to drive a visible
    /// state-change per keystroke (latency-harness rule 8 — memory
    /// `feedback_meaningful_latency_measurement`). Pre-rasterized into
    /// the atlas during `windowChanged` so the keystroke path is
    /// allocation-free.
    private static let randomGlyphs: [Unicode.Scalar] = {
        let upper = (0..<26).compactMap { Unicode.Scalar(0x41 + $0) }
        let digits = (0..<10).compactMap { Unicode.Scalar(0x30 + $0) }
        return upper + digits
    }()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// Reserved for the Stage-0 single-cell overlay path (cursor, IME
    /// underline, selection accents) at task 4.7 / 4.9. Not used by the
    /// current grid renderer; kept so adding the overlay pass doesn't
    /// require re-introducing the pipeline state.
    private let cellPipeline: CellPipeline
    private var gridPipeline: GridPipeline?
    /// Stage-2 overlay pipeline for cursor (4.7), selection (4.5), and
    /// IME marked-text underline (4.9). Constructed lazily once the
    /// device + pixel format are known; the pipeline shape is
    /// kind-discriminated per spec/metal-renderer.md §Stage 2.
    private var overlayPipeline: OverlayPipeline?

    private weak var attachedLayer: CAMetalLayer?
    private var displayLink: CAMetalDisplayLink?
    private var atlas: GlyphAtlas?

    /// M7-3: NotificationCenter observer for `FontSettings.didChange`.
    /// Owned so the observer can be removed in `windowChanged` when
    /// re-installing for a new window. Strong-ref because the
    /// notification token holds the closure; the renderer outlives
    /// the observer lifetime by tying to `windowChanged` teardown.
    private var fontObserver: NSObjectProtocol?

    /// M7-3: set whenever the atlas needs a fresh build because the
    /// font family or size changed. Read by `draw(update:)`'s prologue
    /// (consumed and cleared) so the rebuild lands on a frame boundary
    /// rather than mid-encode. Test seam: tests assert this transitions
    /// to `true` on `FontSettings.didChange`.
    private(set) var atlasDirty: Bool = false

    /// Per-window font-size override. `nil` means "follow the global
    /// `FontSettings.shared.size`" — that's the default for new windows.
    /// Set via `bumpFontSize()` / `dropFontSize()` / `resetFontSize()`
    /// when the user runs ⌘+/⌘-/⌘0 inside this window. Once set, the
    /// global Settings → Appearance picker no longer affects this
    /// window's size (family changes still apply). Reset by
    /// `resetFontSize()` (returns the window to global default).
    private var fontSizeOverride: CGFloat?

    /// Resolved font size for this renderer — the override if set,
    /// otherwise the global default. Read by `makeEffectiveFont()`
    /// and `reloadFont()` instead of going straight to
    /// `FontSettings.shared.size`.
    @MainActor
    private var effectiveFontSize: CGFloat {
        fontSizeOverride ?? FontSettings.shared.size
    }

    /// Build the `CTFont` this renderer should rasterize against —
    /// global family + per-window-resolved size. Replaces direct
    /// `FontSettings.shared.makeCTFont()` calls so the override can
    /// take effect.
    @MainActor
    private func makeEffectiveFont() -> CTFont {
        FontSettings.makeCTFont(
            family: FontSettings.shared.family,
            size: effectiveFontSize)
    }

    /// Last-seen cursor state from the engine. Updated each frame
    /// inside `applyFrameDelta` so `draw(update:)` can encode the
    /// overlay quad after the grid pass without re-reading the
    /// `FrameDelta`. `nil` while the session hasn't produced a frame
    /// yet (Phase 1 stub returns a default `CursorState` regardless,
    /// but this guards future producers that gate cursor visibility).
    private var lastCursor: CursorState?

    /// 4.9: weak handle to the host `TerminalSurfaceView` so the
    /// composition pass can read `activeComposition` each frame. Weak
    /// — the controller owns both objects; avoiding the retain cycle
    /// is cheap insurance. Set via `attachHostView(_:)` from the view's
    /// `init` after `attach(layer:)`.
    private weak var hostView: TerminalSurfaceView?

    /// 4.9: cells we painted as preedit on the most recent frame.
    /// When composition clears (commit / unmark), the underlying real
    /// cells need to repaint — but the engine doesn't mark them dirty
    /// (we never sent input through the FFI). We track per-cell
    /// indices here and force a `setRegion` repaint of those cells
    /// from the cached `cells` shadow array on the first post-clear
    /// frame. Empty when no composition is active.
    private var preeditPaintedCells: [(row: Int, col: Int)] = []
    /// 4.9: set when `invalidateCompositionRender` fires. Read by the
    /// next `draw(update:)` to ensure preedit cells get repainted from
    /// the underlying state.
    private var compositionInvalidated: Bool = false

    /// 4.5: read-only view of the last-seen cursor for the keyboard
    /// selection extender. Returns a default-zero `CursorState`
    /// (row 0, col 0) before the first frame so shift+arrow in the
    /// no-frame-yet window starts a selection at the grid origin
    /// rather than crashing. This matches the pre-frame rendered
    /// state — the spike's random-fill grid sits behind a (0, 0)
    /// cursor.
    var lastSeenCursor: CursorState {
        lastCursor
            ?? CursorState(
                row: 0, col: 0,
                shape: 0, blink: false, hidden: false)
    }

    /// Cursor blink phase reference. Populated lazily on first draw so
    /// the blink starts from "visible" the moment a window appears,
    /// not from app-launch time. V2 raised the period to 900 ms and
    /// switched to a sine-eased curve (`easedBlinkAlpha`) with steady
    /// dwell phases — calm pulse instead of a strobe.
    private var blinkOriginTime: CFTimeInterval?
    private static let blinkPeriodSec: CFTimeInterval = 0.9

    /// V2 pause-on-type: timestamp of the most recent keystroke. While
    /// `now - lastKeystrokeTime < blinkPauseAfterKeystrokeSec` the
    /// cursor holds solid at alpha=1.0 (no fade) so the user sees a
    /// stable insertion point during active typing.
    private var lastKeystrokeTime: CFTimeInterval = 0
    private static let blinkPauseAfterKeystrokeSec: CFTimeInterval = 0.5
    /// UX6: tracks the previous frame's `typingActive` so the cursor
    /// encode can detect the typing → idle transition and re-anchor
    /// `blinkOriginTime` once at the boundary instead of every frame
    /// during typing.
    private var wasTypingLastFrame: Bool = false

    /// V1 scrollbar fade: timestamp of the last `scroll_top` /
    /// `scroll_total` change observed in `applyFrameDelta`. The thumb
    /// is fully opaque for the first `scrollbarHoldSec`, then fades to
    /// the resting alpha over the next `scrollbarFadeSec`.
    private var lastScrollActivityTime: CFTimeInterval = 0
    private static let scrollbarHoldSec: CFTimeInterval = 0.8
    private static let scrollbarFadeSec: CFTimeInterval = 0.8
    private static let scrollbarRestingAlpha: Float = 0.25
    // UX4: bump 6→8pt resting and 9→12pt hover so the visual target
    // matches the 16pt hit zone. Matches macOS-style "overlay
    // scroller" proportions (Safari/Finder use 9pt → 15pt; we sit
    // between that and the original Alacritty-style hairline).
    private static let scrollbarHoverWidthPx: Float = 12.0
    private static let scrollbarRestingWidthPx: Float = 8.0
    private static let scrollbarHoverHitWidthPt: Float = 16.0

    /// V1 scrollbar hover: latest mouse-in-view location in surface
    /// points, set by `TerminalSurfaceView.mouseMoved`. Nil when the
    /// pointer is outside the view. Used to detect right-edge hover
    /// for the "grow + solid" affordance.
    var hoverPointInView: CGPoint? {
        didSet { pendingRedraw = true }
    }

    /// P1 idle-frame skip: when true, the next `draw(update:)` is
    /// guaranteed to encode + present. Set by `markNeedsRedraw()` from
    /// the host view on any user-driven state change that the engine
    /// doesn't surface through `take_frame_delta` (selection drags,
    /// scroll-to-bottom, theme switch, link-hover, search-match list
    /// changes, …). Reset to false at the bottom of `draw(update:)`
    /// after a successful encode.
    private var pendingRedraw: Bool = true

    /// P1: true once we've committed at least one drawable. Pre-first-
    /// frame ticks must always encode — even when nothing's "dirty" —
    /// so the compositor gets the cleared background instead of a
    /// black surface.
    private var hasPresented: Bool = false

    /// P1: snapshot of `lastCursor` at the time of the last successful
    /// encode. Used by `draw(update:)` to detect cursor field changes
    /// (move/shape/blink/hidden) that warrant a redraw even when no
    /// grid cells changed.
    private var lastEncodedCursor: CursorState?

    /// I1 bell flash: timestamp of the most recent `EngineEvent::Bell`
    /// drained from the engine. Nil when no flash is in-flight; a
    /// CACurrentMediaTime() when one is fading. The encode path fades
    /// from 0.25 alpha to 0 over `bellFlashDurationSec` and clears the
    /// timestamp once `elapsed > duration`.
    private var bellFlashStartTime: CFTimeInterval?
    private static let bellFlashDurationSec: CFTimeInterval = 0.15

    /// Owning handle to the Rust-side `TerminalSession`. Constructed in
    /// `windowChanged` once a window is available; reset to nil when the
    /// view leaves its window. `TerminalSurfaceView.keyDown` reads this
    /// to dispatch encoded `InputEvent`s through `send_input`. Production
    /// session lifecycle (PTY spawn, real `pixel_w`/`pixel_h` derivation,
    /// environment inheritance, `$SHELL` resolution) lands at #17 + Week 1
    /// PTY work; today this is a default-configured session whose only
    /// observable side effect is buffering `event.key.text` bytes for
    /// the future PTY consumer.
    private(set) var session: TerminalSession?

    /// The host `NSWindow` the renderer is currently presenting into.
    /// Captured in `windowChanged(window:)` so the per-frame title
    /// poll (`drain_latest_title`) can update `window.title` without
    /// re-walking the responder chain. `weak` — the window outlives
    /// the renderer in practice (the controller owns both), but
    /// avoiding a retain cycle is cheap insurance.
    private weak var hostWindow: NSWindow?

    /// Cell height in points (logical pixels divided by backing scale).
    /// Read by `TerminalSurfaceView.scrollWheel(with:)` so the trackpad
    /// pixel-delta accumulator can flush at line boundaries. Returns
    /// nil before the atlas is constructed in `windowChanged`.
    /// Task 4.4.
    var cellHeightPt: CGFloat? {
        guard let atlas else { return nil }
        return atlas.cellSizePt.height
    }

    /// Cell width in points. Used by the 4.5 mouse handler to
    /// translate window-space click coordinates into terminal cell
    /// `(row, col)` indices. Returns nil before the atlas is built.
    var cellWidthPt: CGFloat? {
        guard let atlas else { return nil }
        return atlas.cellSizePt.width
    }

    /// Visible viewport height in rows. PgUp / PgDn page by this amount
    /// so a single press covers exactly one screenful — the iTerm2 /
    /// Terminal.app convention. Tracks the live `gridRows` so
    /// post-resize page-by-screenful scrolling matches the visible
    /// height. Task 4.4 + 4.8.
    var viewportRows: Int { gridRows }

    /// Visible viewport width in columns. Mirrors `viewportRows` for
    /// the 4.5 mouse-handler's cell clamping. Dynamic per
    /// `gridCols` — updated by `resizeGrid(cols:rows:)` at 4.8.
    var viewportCols: Int { gridCols }

    /// M6-2 ⌘+hover state: the cell range under the mouse cursor when
    /// the user is holding ⌘ and hovering over a detected file path.
    /// Encoded as a bottom-of-cell underline (reusing the `imeUnderline`
    /// kind=3 shader path with a link-tint color). `nil` clears the
    /// underline. Set by `TerminalSurfaceView.mouseMoved` /
    /// `flagsChanged` based on `FilePathDetector` output.
    ///
    /// Post-P1: writes go through a `didSet` that marks the next frame
    /// dirty so the idle-skip path doesn't strand a stale (or missing)
    /// underline on screen when the hover state changes between ticks.
    var linkHover: LinkHover? {
        didSet {
            if linkHover != oldValue { pendingRedraw = true }
        }
    }

    /// One-row, N-cell underline span for ⌘+hover-detected file paths.
    struct LinkHover: Equatable {
        let row: Int
        let startCol: Int
        let span: Int
    }

    /// M7-2 ⌘F find — match list for the active search session. Each
    /// span carries the alacritty-absolute `line` (negative =
    /// scrollback); the encode path translates to viewport row using
    /// `lastScrollTop` every frame, so highlights track content as the
    /// user scrolls without the controller re-publishing.
    ///
    /// `activeIndex` is the index of the currently focused match
    /// (Return / Down jumped to it). The active match renders with a
    /// stronger accent; the rest get a dimmed tint.
    struct SearchHighlights: Equatable {
        struct Span: Equatable {
            /// Alacritty-absolute line. Negative = scrollback row.
            let line: Int
            let startCol: Int
            let span: Int
        }
        let spans: [Span]
        let activeIndex: Int?
    }
    var searchHighlights: SearchHighlights? {
        didSet { pendingRedraw = true }
    }

    /// M7-2: latest `scroll_top` from the engine (rows scrolled up into
    /// history). Cached during `applyFrameDelta` so the search-highlight
    /// encode path can compute `viewportRow = line + scrollTop` without
    /// re-pulling the FFI frame delta (which would double-drain).
    private var lastScrollTop: Int = 0

    /// Latest `scroll_total` from the engine (rows in scrollback). Cached
    /// alongside `lastScrollTop` so the scrollbar overlay encode can
    /// compute the thumb position without re-pulling the frame delta.
    private var lastScrollTotal: Int = 0

    /// Mutable per-cell state. The renderer keeps the array so the
    /// keystroke handler can read the previous slot before producing
    /// a new one (and so a future "redraw whole grid" path can call
    /// `setGrid` without rebuilding). Per-keystroke mutations
    /// enqueue (index, slot) pairs onto `pendingCellWrites`; the next
    /// frame applies them via `GridPipeline.setCell` for one-cell
    /// texture updates instead of full-grid rewrites.
    private var cells: [CellSlot] = []
    private var pendingCellWrites: [(index: Int, slot: CellSlot)] = []
    private var keystrokeIndex: Int = 0
    /// Pending input timestamps (`NSEvent.timestamp`, mach-time-derived)
    /// awaiting their first frame's `presentedTime`. Drained inside the
    /// `addCompletedHandler` so latency is computed on the same clock.
    private var pendingKeystrokeTimes: [CFTimeInterval] = []

    /// Per-keystroke render-path latency samples. Populated by
    /// `didMeasureKeystrokeLatency`; the meter logs a percentile
    /// summary once `targetSampleCount` (default 1000) is reached.
    let latencyMeter = LatencyMeter(targetSampleCount: 1000)

    var clearColor: MTLClearColor = TerminalSurfaceView.defaultClearColor

    /// Linear-space white text on the dark theme background. Pure linear
    /// (1, 1, 1) → sRGB (255, 255, 255) after the framebuffer's encode-on-
    /// store. ThemeManager (M5) replaces this with the active palette's
    /// foreground color.
    var fgColorLinear: SIMD4<Float> = SIMD4(1.0, 1.0, 1.0, 1.0)

    /// Frame-time samples (CPU encode wallclock, milliseconds) over the
    /// last `frameTimeWindow` frames. Logged every `frameTimeWindow`
    /// frames so the kill-criterion early-warning at #8 has measured
    /// data to compare against.
    private var frameTimes: [Double] = []
    private var frameCount: UInt64 = 0
    private static let frameTimeWindow = 240  // 2 seconds at 120 Hz

    /// ADR-19 / spec/cross-cell-shaping.md feature gate. When ON, the
    /// FrameDelta path routes `[CellDeltaSwift]` through
    /// `GraphemeClusterCoalescer.coalesce` before slot resolution so
    /// cross-cell grapheme clusters (Thai SARA AM, regional indicator
    /// flag pairs, ZWJ family spillovers) render as one wide glyph.
    /// Default ON since v0.1.7 (ADR-19 / atomic 5 — manual verification
    /// of `ทำ`, `ห้`, `ก่อ`, `กืน` 2026-05-16). Setting
    /// `NEXTTERM_SHAPING=0` disables the coalescer and restores the
    /// v0.1.6 single-cell path for diagnosis.
    private let useShaping: Bool =
        ProcessInfo.processInfo.environment["NEXTTERM_SHAPING"] != "0"

    init(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create MTLCommandQueue on \(device.name)")
        }
        queue.label = "com.zenzai.SolidTerm.MetalRenderer"
        self.commandQueue = queue
        do {
            self.cellPipeline = try CellPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        } catch {
            fatalError("CellPipeline construction failed: \(error)")
        }
        do {
            self.overlayPipeline = try OverlayPipeline(
                device: device, pixelFormat: .bgra8Unorm_srgb)
        } catch {
            // Non-fatal: degrades to grid-only rendering (no cursor /
            // selection / IME overlay). The grid pass still runs.
            NSLog(
                "MetalRenderer: OverlayPipeline construction failed (cursor / "
                    + "selection / IME overlays disabled): %@",
                String(describing: error))
            self.overlayPipeline = nil
        }
        // M6-4a: refresh clear color on theme change. Light-mode users
        // see same dark pixels until M6-4b lands the spec-keeper's
        // light tokens; the wiring lands now so the activation diff is
        // a token-only swap.
        themeChangeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshClearColor()
            }
        }
        // File-backed TOML theme changes ride a sibling notification
        // so a single observer on `themeDidChange` covers both surfaces.
        // ThemeFileStore also posts its own `didChange` — we cover that
        // via a second observer so the user's edit fires the renderer
        // immediately without waiting for the mode-picker path.
        themeFileObserver = NotificationCenter.default.addObserver(
            forName: ThemeFileStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshClearColor()
            }
        }
        // Pull the persisted theme into the renderer at construction
        // time. ThemeFileStore.init reads `solidterm.theme.fileBacked`
        // out of UserDefaults via reload(notify: false) — the silent
        // reload is required because shared-singleton observers haven't
        // wired up yet — so the saved theme is sitting on
        // `ThemeFileStore.shared.current` but nothing has woken the
        // renderer up. Without this call, the first launch after a
        // theme pick reverts to the built-in default until the user
        // opens Settings and re-picks, then sees "oh, it didn't save"
        // (it did; the renderer just never refreshed). The renderer
        // is always constructed on the main thread (window setup);
        // `assumeIsolated` documents the contract without needing to
        // bubble @MainActor up to every caller.
        MainActor.assumeIsolated {
            refreshClearColor()
        }
    }

    deinit {
        displayLink?.invalidate()
        if let observer = themeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = themeFileObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// M6-4a: theme-change observer token. Stored so `deinit` can
    /// remove it cleanly. Light-mode flips post `themeDidChange`; this
    /// callback re-resolves `clearColor` against the current
    /// `ThemeManager.shared.resolved` mode.
    private var themeChangeObserver: NSObjectProtocol?
    private var themeFileObserver: NSObjectProtocol?

    /// M6-4a: re-resolve `clearColor` against the current theme mode.
    /// Called from the `themeDidChange` observer + on demand by tests.
    /// The `CAMetalDisplayLink` re-renders every vsync so the next
    /// frame picks up the new clear color without any additional
    /// invalidation hook.
    @MainActor
    func refreshClearColor() {
        // File-backed TOML theme (~/.config/solidterm/themes/<name>.toml)
        // wins over the built-in Theme.Mode cascade — same code path
        // the theme picker drives. The renderer honors the file's
        // bg/fg, cursor, selection, AND ANSI palette (mapped via the
        // engine's compile-time hex values).
        if let file = ThemeFileStore.shared.current {
            resolvedPalette = file.palette
            resolvedCursor = file.cursor
            resolvedSelection = file.selection
            ansiOverride = Self.buildAnsiOverride(file: file)
            clearColor = MTLClearColor(
                red: Double(file.background.x),
                green: Double(file.background.y),
                blue: Double(file.background.z),
                alpha: Double(file.background.w))
        } else {
            let mode = ThemeManager.shared.resolved
            clearColor = Theme.defaultClearMTL(for: mode)
            resolvedPalette = Theme.Color.defaultPalette(for: mode)
            resolvedCursor = Theme.Color.cursorDefaultLinear(for: mode)
            resolvedSelection = Theme.Color.selectionBgLinear(for: mode)
            ansiOverride = [:]
        }
        // Refresh the per-cell palette so existing visible cells re-
        // resolve against the live theme. Earlier versions blanked
        // `self.cells` and waited for the engine to re-emit damage on
        // the next PTY write — but an idle Claude Code session never
        // ticks PTY output, so text stayed invisible mid-theme-switch
        // until the user typed. `take_full_frame_delta` re-emits
        // every viewport row through the FFI without consuming
        // alacritty's damage state, so the renderer's resolver picks
        // up the new palette + `ansiOverride` map in the next frame.
        // No session yet (renderer still initialising) → fall back to
        // the blank-grid path so the new background color paints
        // immediately.
        if let session, let pipeline = gridPipeline, let atlas {
            let frame = session.take_full_frame_delta()
            self.lastCursor = frame.cursor
            if let decoded = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                if useShaping {
                    let coalesced = GraphemeClusterCoalescer.coalesce(decoded)
                    Self.applyCoalescedCellsAsRegions(
                        coalesced, pipeline: pipeline, atlas: atlas,
                        makeSlot: { [weak self] cell in
                            self?.makeSlot(from: cell, atlas: atlas)
                        })
                } else {
                    Self.applyCellsAsRegions(
                        decoded, pipeline: pipeline, atlas: atlas,
                        makeSlot: { [weak self] cell in
                            self?.makeSlot(from: cell, atlas: atlas)
                        })
                }
            }
        } else {
            self.cells = Self.makeBlankGrid(
                cols: gridCols, rows: gridRows, palette: resolvedPalette)
            try? gridPipeline?.setGrid(
                self.cells, atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
        }
        pendingRedraw = true
    }

    func attach(layer: CAMetalLayer) {
        attachedLayer = layer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = false
        layer.isOpaque = true
        attachedPixelFormat = layer.pixelFormat
    }

    /// 4.9: capture a weak handle to the host view so the composition
    /// pass can poll `activeComposition` each frame. The view's `init`
    /// calls this immediately after `attach(layer:)`; subsequent
    /// re-attaches (window changes) leave the host pointer alone since
    /// the view itself isn't recreated.
    func attachHostView(_ view: TerminalSurfaceView) {
        self.hostView = view
    }

    /// 4.9: signal that composition state changed. The renderer flips
    /// `compositionInvalidated` so the next frame either repaints
    /// preedit cells (if a composition is now active) or restores the
    /// underlying real cells (if a composition just ended). Called
    /// from `setMarkedText`, `unmarkText`, and the `insertText` commit
    /// path.
    func invalidateCompositionRender() {
        compositionInvalidated = true
        pendingRedraw = true
    }

    /// P1 idle-frame skip: called by the host view on any user-driven
    /// state change that the engine doesn't surface through a
    /// `FrameDelta` — selection drags, link-hover changes, search-list
    /// updates, mouse / scroll events. The next display-link tick is
    /// guaranteed to run a full encode + present.
    func markNeedsRedraw() {
        pendingRedraw = true
    }

    /// P1: equality on the fields that drive the cursor overlay encode.
    /// `lastCursor` always reflects the latest engine snapshot; the
    /// "encoded" mirror only updates on a successful draw. Any field
    /// change between the two ticks must force a redraw — but updates
    /// that no-op visually (e.g. same position with a flipped reserved
    /// bit, should we add one) shouldn't.
    private static func cursorEqual(_ a: CursorState?, _ b: CursorState?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?):
            return l.row == r.row && l.col == r.col
                && l.shape == r.shape && l.blink == r.blink
                && l.hidden == r.hidden
        default: return false
        }
    }

    /// M7-3: subscribe to `FontSettings.didChange` exactly once per
    /// renderer-lifetime so font family / size edits trigger an
    /// atlas regen on the next draw. Idempotent — re-installs only
    /// when the prior observer was torn down (e.g. the renderer is
    /// rehosted on a different window). Posts run on the main run
    /// loop, matching the rendering thread.
    /// Test seam — `MetalRendererFontTests` calls this after
    /// constructing a renderer-without-window so the `atlasDirty`
    /// flag wiring can be exercised without standing up a real
    /// `CAMetalLayer`. Production callers go through `windowChanged`.
    @MainActor
    func installFontObserverForTesting() {
        installFontObserverIfNeeded()
    }

    @MainActor
    private func installFontObserverIfNeeded() {
        if fontObserver != nil { return }
        fontObserver = NotificationCenter.default.addObserver(
            forName: FontSettings.didChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.atlasDirty = true
        }
    }

    /// Per-window ⌘+ / ⌘- / ⌘0. Updates this renderer's font-size
    /// override and triggers an atlas regen on the next frame. Other
    /// windows are unaffected. Clamped via `FontSettings.clamp` so
    /// out-of-band hotkey presses are silently saturated.
    @MainActor
    func bumpFontSize() {
        let next = FontSettings.clamp(effectiveFontSize + 1)
        guard next != effectiveFontSize else { return }
        fontSizeOverride = next
        atlasDirty = true
        reloadFont()
    }

    @MainActor
    func dropFontSize() {
        let next = FontSettings.clamp(effectiveFontSize - 1)
        guard next != effectiveFontSize else { return }
        fontSizeOverride = next
        atlasDirty = true
        reloadFont()
    }

    /// ⌘0 — clears the per-window override so the window snaps back
    /// to the global Settings → Appearance default. Not "shrink to
    /// 14" — match the M7-3 spec where ⌘0 means "default size".
    @MainActor
    func resetFontSize() {
        guard fontSizeOverride != nil else { return }
        fontSizeOverride = nil
        atlasDirty = true
        reloadFont()
    }

    /// Test seam — read-only view of the per-window override.
    var fontSizeOverrideForTesting: CGFloat? { fontSizeOverride }

    /// M7-3: rebuild the glyph atlas + grid pipeline against the
    /// current `FontSettings`. Also recomputes the host window's
    /// content-size so the cell grid matches the new metrics
    /// (without this, a font-size bump leaves the visible grid the
    /// same pixel size but with fewer / clipped cells until the next
    /// manual resize). Safe to call repeatedly; no-op when the
    /// renderer hasn't yet attached a window.
    @MainActor
    @discardableResult
    func reloadFont() -> Bool {
        guard let window = hostWindow else {
            atlasDirty = false
            return false
        }
        let scale = window.backingScaleFactor
        let font = makeEffectiveFont()
        do {
            let newAtlas = try GlyphAtlas(
                device: device, font: font, contentsScale: scale)
            for scalar in Self.randomGlyphs {
                _ = try newAtlas.entry(
                    for: scalar, commandQueue: commandQueue)
            }
            let newPipeline = try GridPipeline(
                device: device,
                pixelFormat: attachedPixelFormat,
                cols: gridCols,
                rows: gridRows)
            try newPipeline.setGrid(
                self.cells, atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            self.atlas = newAtlas
            self.gridPipeline = newPipeline
            // Keep the window size fixed; reflow the cell grid against
            // the new cell metrics instead. Bigger font ⇒ fewer cells
            // visible; smaller font ⇒ more cells. Matches iTerm2 /
            // Ghostty: ⌘+/⌘- changes typography only, not chrome.
            // We derive cols/rows from the unchanged content rect and
            // forward to `resizeGrid`, which propagates through to
            // alacritty via the FFI.
            let viewSize = window.contentRect(
                forFrameRect: window.frame).size
            let cellW = newAtlas.cellSizePt.width
            let cellH = newAtlas.cellSizePt.height
            if cellW > 0, cellH > 0 {
                let gridWidth = max(0, viewSize.width - Theme.Gutter.widthPt)
                let cols = max(1, Int((gridWidth / cellW).rounded(.down)))
                let rows = max(1, Int((viewSize.height / cellH).rounded(.down)))
                resizeGrid(cols: cols, rows: rows)
            }
        } catch {
            NSLog(
                "MetalRenderer.reloadFont: rebuild failed: %@",
                String(describing: error))
            atlasDirty = false
            return false
        }
        atlasDirty = false
        return true
    }

    @MainActor
    func windowChanged(window: NSWindow?) {
        // Seed the resolved palette from the persisted theme mode so
        // the first frame after a Light-mode launch doesn't flash dark.
        // `windowChanged` is MainActor-isolated so reading
        // ThemeManager.shared.resolved is safe here (the renderer init
        // path runs in a nonisolated context where it isn't).
        resolvedPalette = Theme.Color.defaultPalette(
            for: ThemeManager.shared.resolved)
        // Tear down any previous link — moves between windows / displays
        // are rare but possible (Spaces drag, multi-monitor).
        displayLink?.invalidate()
        displayLink = nil
        // M7-3: drop the prior font observer so the next install
        // (below, after the new window is established) doesn't
        // stack a second handler on the same notification.
        if let token = fontObserver {
            NotificationCenter.default.removeObserver(token)
            fontObserver = nil
        }
        atlasDirty = false
        // Reset the atlas + grid pipeline; a new window may have a
        // different backing-scale factor and the cell-size derivation
        // depends on it.
        atlas = nil
        gridPipeline = nil
        // Drop the Rust-side session handle alongside the rest of the
        // window-scoped state. ARC release on the swift-bridge wrapper
        // calls `__swift_bridge__$TerminalSession$_free`, which drops
        // the boxed engine session on the Rust side.
        session = nil

        // Capture the host window for per-frame title updates (4.8).
        // Reset to nil first so a leaving-window transition doesn't
        // leave a stale reference behind.
        hostWindow = window

        guard let layer = attachedLayer, let window else { return }

        let scale = window.backingScaleFactor
        let font = makeEffectiveFont()
        // M7-3: subscribe to font-setting changes so ⌘+/⌘-/⌘0 and
        // the Settings picker can re-rasterize the atlas on the fly.
        // Re-installs every windowChanged so a window-move doesn't
        // leak the prior observation.
        installFontObserverIfNeeded()
        do {
            let atlas = try GlyphAtlas(device: device, font: font, contentsScale: scale)
            // Pre-rasterize the keystroke-mutation alphabet so
            // `recordKeystroke` (latency-harness state-change path)
            // is allocation-free.
            for scalar in Self.randomGlyphs {
                _ = try atlas.entry(for: scalar, commandQueue: commandQueue)
            }
            let pipeline = try GridPipeline(
                device: device,
                pixelFormat: attachedPixelFormat,
                cols: gridCols,
                rows: gridRows)
            self.cells = Self.makeBlankGrid(
                cols: gridCols, rows: gridRows, palette: resolvedPalette)
            try pipeline.setGrid(self.cells, atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            self.atlas = atlas
            self.gridPipeline = pipeline
        } catch {
            // The spike target is a single-glyph render; failure here is
            // catastrophic enough that we want a console signal but not a
            // hard crash (visual rendering will degrade to clear-only).
            NSLog("MetalRenderer: grid init failed: %@", String(describing: error))
        }

        // Construct the Rust-side terminal session. Independent of the
        // grid-init success path: even if rendering degrades to
        // clear-only, the input plumbing should still buffer bytes for
        // the future PTY consumer. `pixel_w` / `pixel_h` are zero
        // placeholders this PR — Week 1 PTY spawn computes the real
        // values from atlas cell-size × grid dimensions.
        // Consume any new-window/new-tab cwd override the controller
        // injected before windowChanged fired. Cleared after use so
        // subsequent session rebuilds (Cmd+R, etc.) fall back to home.
        let initialCwd = pendingInitialCwd
        pendingInitialCwd = nil
        self.session = Self.makeDefaultSession(
            rows: gridRows, cols: gridCols, cwd: initialCwd)

        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 120, preferred: 120)
        link.delegate = displayLinkDelegate
        link.add(to: .main, forMode: .common)
        displayLink = link

        // The mode-default seed at the top of this method (line 692)
        // overrode the file-theme palette that `init`'s
        // `refreshClearColor()` already established. Re-resolve now
        // that the pipeline + atlas exist so the just-blanked cells
        // get re-uploaded against the file theme + ansiOverride. This
        // is what makes ⌘N / ⌘T windows honor the active theme
        // instead of falling back to the built-in dark palette.
        refreshClearColor()
    }

    /// Resize the live grid to `cols × rows`. Triggered by
    /// `TerminalSurfaceView.setFrameSize(_:)` on host-side window
    /// resize (4.8). Three concerns:
    ///
    ///   1. Update the renderer's `gridCols` / `gridRows` so the
    ///      grid pass uniforms (`gridSizeCells`), selection /
    ///      cursor clamps, and `viewport*` accessors all see the new
    ///      dimensions.
    ///   2. Rebuild the `GridPipeline` — its three textures
    ///      (cellFG, cellBG, cellAtlasUV) are sized at construction
    ///      to `cols × rows × format`. The atlas itself stays — it's
    ///      glyph-keyed, not grid-keyed.
    ///   3. Forward to the engine via `session.resize(rows, cols)` so
    ///      `Term::resize` rewrites the alacritty grid and
    ///      `Pty::on_resize` issues `TIOCSWINSZ` (delivers `SIGWINCH`
    ///      to children).
    ///
    /// Idempotent — a no-change resize early-returns before the
    /// pipeline rebuild. Zero / negative dimensions early-return
    /// without mutation (defensive against transient layout passes
    /// that compute a 0-px frame; `setFrameSize` clamps to ≥ 1 cell
    /// before calling but a future caller might not).
    ///
    /// On pipeline-rebuild failure the renderer logs and keeps the
    /// previous pipeline (degraded but live). That path also early-
    /// returns before forwarding to the engine — keeping the
    /// renderer-side and engine-side dimensions in lockstep.
    func resizeGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if cols == gridCols, rows == gridRows { return }

        let newPipeline: GridPipeline
        do {
            newPipeline = try GridPipeline(
                device: device,
                pixelFormat: attachedPixelFormat,
                cols: cols, rows: rows)
        } catch {
            NSLog(
                "MetalRenderer.resizeGrid: pipeline rebuild failed (%dx%d): %@",
                cols, rows, String(describing: error))
            return
        }

        gridCols = cols
        gridRows = rows
        gridPipeline = newPipeline
        // Re-populate the shadow array at the new dimensions. The next
        // `applyFrameDelta` will overwrite cells the shell painted;
        // until then `cells` carries blank slots (theme bg + fg) so:
        //   1. `recordKeystroke` (latency harness) can read a valid
        //      cell-0 entry and append its mutated slot — without this,
        //      a `cells.isEmpty` early-return starves the harness's
        //      completion-handler queue (the n=0 corruption symptom).
        //   2. `restoredSlot` (IME preedit-clear path) reads valid
        //      bg/fg when erasing preedit underlines on commit / unmark.
        cells = Self.makeBlankGrid(cols: cols, rows: rows, palette: resolvedPalette)
        pendingCellWrites.removeAll(keepingCapacity: true)
        // Push the blank state into the new pipeline's textures.
        // Without this, the rebuilt cellFG/cellBG/cellAtlasUV stay
        // zero-initialized; cells that the engine's post-resize damage
        // doesn't immediately repaint render with bg=(0,0,0,0) instead
        // of bg-base. Visible as a light-gray rectangle covering the
        // un-touched area of the viewport.
        do {
            try newPipeline.setGrid(cells, atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
        } catch {
            NSLog(
                "MetalRenderer.resizeGrid: setGrid after rebuild failed: %@",
                String(describing: error))
        }

        // Forward to the engine. Failure here is "alacritty wouldn't
        // resize" — we log and continue; the renderer-side grid still
        // has the new dimensions so the visual is correct, but child
        // processes won't see a SIGWINCH until the next successful
        // resize.
        if let session, !session.resize(UInt16(rows), UInt16(cols)) {
            NSLog(
                "MetalRenderer.resizeGrid: engine resize rejected (%dx%d)",
                cols, rows)
        }

        resizeRebuildCount &+= 1
        pendingRedraw = true
    }

    /// 4.8: drain the engine's pending title-changed events and
    /// forward the latest to the host window. Called once per frame
    /// from `draw(update:)`. Empty-string sentinel = no event this
    /// tick → skip; otherwise set `window.title`. The display-link
    /// callback already runs on the main thread (per
    /// `CAMetalDisplayLink.add(to: .main, ...)`) so the AppKit
    /// `setTitle` call is safe without a dispatch hop.
    @discardableResult
    private func applyLatestTitleIfAny() -> Bool {
        guard let session else { return false }
        let oscTitle = session.drain_latest_title().toString()
        // V3 fallback rule: OSC 2 is "recently sticky". Once the
        // shell (or any running TUI — Claude Code's spinner, vim's
        // status, etc.) has emitted *any* OSC 2 title within the
        // last `oscTitleRecencyWindow` seconds, we surrender the
        // title bar to the engine and don't overwrite it with our
        // cwd-basename fallback. After silence longer than the
        // window we let the fallback re-engage so the title doesn't
        // stay stuck on vim's last status line after the user quits.
        let now = CACurrentMediaTime()
        if !oscTitle.isEmpty {
            lastOscTitleTime = now
        }
        let oscRecent = (now - lastOscTitleTime) < Self.oscTitleRecencyWindow
            && lastOscTitleTime > 0
        let effective: String
        let subtitle: String
        if !oscTitle.isEmpty {
            effective = oscTitle
            subtitle = lastCwd.isEmpty ? "" : Self.displayCwd(lastCwd)
        } else if oscRecent {
            // OSC 2 active but quiet this tick: leave the title alone
            // and only refresh the subtitle if the cwd changed.
            // Returning `false` here is intentional — no encode
            // dirty-bit, no AppKit title-bar redraw.
            if let window = hostWindow,
                window.styleMask.contains(.titled),
                window.isVisible,
                window.standardWindowButton(.closeButton) != nil
            {
                let desired = lastCwd.isEmpty ? "" : Self.displayCwd(lastCwd)
                if window.subtitle != desired {
                    window.subtitle = desired
                    return true
                }
            }
            return false
        } else if !lastCwd.isEmpty {
            effective = (lastCwd as NSString).lastPathComponent.isEmpty
                ? lastCwd
                : (lastCwd as NSString).lastPathComponent
            subtitle = Self.displayCwd(lastCwd)
        } else {
            return false
        }
        var changed = false
        if hostWindow?.title != effective {
            hostWindow?.title = effective
            changed = true
        }
        // V3 subtitle gate: assigning `NSWindow.subtitle` on a window
        // without a fully-initialised titlebar (e.g. xctest-spun
        // windows that haven't been ordered front yet) raises
        // `NSInternalInconsistencyException: titlebarAccessoryViewControllers
        // not supported for this window style` because subtitle is
        // implemented under the hood as a titlebar accessory. Gate on
        // the window having a real close-button — a reliable signal
        // that AppKit has built the proper titlebar chrome.
        if let window = hostWindow,
            window.styleMask.contains(.titled),
            window.standardWindowButton(.closeButton) != nil,
            window.subtitle != subtitle
        {
            window.subtitle = subtitle
            changed = true
        }
        return changed
    }

    /// V3: render a cwd absolute path with `$HOME` collapsed to `~`
    /// for a tidier subtitle. Common case is `/Users/<me>/foo` →
    /// `~/foo`; everything outside `$HOME` stays absolute.
    private static func displayCwd(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// M6-2: latest OSC-7 cwd, polled once per frame off
    /// `drain_latest_cwd`. Read by `TerminalSurfaceView` for relative-
    /// path resolution in the file-path detector. Empty when the shell
    /// hasn't emitted OSC 7 yet (e.g. a fresh login shell with no
    /// chpwd hook configured).
    private(set) var lastCwd: String = ""

    @discardableResult
    private func applyLatestCwdIfAny() -> Bool {
        guard let session else { return false }
        let cwd = session.drain_latest_cwd().toString()
        if !cwd.isEmpty, cwd != lastCwd {
            lastCwd = cwd
            return true
        }
        // V3 fallback: when the shell hasn't wired OSC 7, periodically
        // refresh `lastCwd` from `proc_pidinfo(child_pid)`. 500 ms is
        // slow enough to keep the FFI/proc call rare and fast enough
        // that the user sees the title flip within a frame or two
        // after `cd`. Skip while OSC 7 has been observed at least
        // once (the engine pushes events; we trust them).
        if cwd.isEmpty {
            let now = CACurrentMediaTime()
            if now - lastCwdProcPollTime > 0.5 {
                lastCwdProcPollTime = now
                let pid = pid_t(session.child_pid())
                if pid > 0, let refreshed = Self.cwdForPid(pid),
                    refreshed != lastCwd
                {
                    lastCwd = refreshed
                    return true
                }
            }
        }
        return false
    }

    private var lastCwdProcPollTime: CFTimeInterval = 0

    /// V3: timestamp of the most recent OSC 2 title we observed.
    /// The cwd-basename fallback is dormant while OSC 2 has fired
    /// within `oscTitleRecencyWindow` — this kills the Claude-spinner
    /// blink — but re-engages after silence (e.g. user quits vim /
    /// claude, returns to the shell), so the title doesn't stay
    /// stuck at the last TUI value forever.
    private var lastOscTitleTime: CFTimeInterval = 0
    // 500ms catches Claude's ~16ms spinner ticks and vim's mode-line
    // updates while keeping the post-exit revert snappy. The earlier
    // 1.5s value lagged visibly when the user quit a TUI — title
    // stayed stuck on the TUI's last value before the cwd basename
    // re-engaged (regression report 2026-05-20 UX pass).
    private static let oscTitleRecencyWindow: CFTimeInterval = 0.5

    /// Best-effort working directory for ⌘N / ⌘T inheritance.
    /// Prefers OSC 7 (`lastCwd`) when the shell has emitted it; falls
    /// back to `proc_pidinfo` on the child PID so a vanilla zsh with no
    /// shell integration still inherits cwd — matches Terminal.app's
    /// behaviour. Returns nil if neither source has a value.
    func currentCwd() -> String? {
        if !lastCwd.isEmpty { return lastCwd }
        guard let session else { return nil }
        let pid = pid_t(session.child_pid())
        guard pid > 0 else { return nil }
        return Self.cwdForPid(pid)
    }

    /// macOS `proc_pidinfo(PROC_PIDVNODEPATHINFO)` wrapper. The struct
    /// is laid out as two `vnode_info_path` blocks (proc + cwd); we
    /// only want the cwd path. Returns nil on any libproc failure.
    private static func cwdForPid(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let n = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard n == Int32(size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(validatingUTF8: $0)
            }
        }
    }

    // The delegate is held strongly by the renderer; the link only retains
    // it weakly so we keep a strong ref here.
    private lazy var displayLinkDelegate = MetalDisplayLinkProxy { [weak self] update in
        self?.draw(update: update)
    }

    private func draw(update: CAMetalDisplayLink.Update) {
        // 4.8: poll the engine for the latest title-changed event and
        // forward to the host window. Empty string is the
        // no-event-this-tick sentinel; we skip the assignment to avoid
        // wiping a previously-set title with a TitleReset (which the
        // FFI currently drops). `drain_latest_title` also drains other
        // event variants — a deliberate "renderer is the canonical
        // event consumer" choice. The call cost is negligible (an
        // empty Vec on no events; the FFI overhead is one method
        // dispatch + a String allocation).
        let titleChanged = applyLatestTitleIfAny()
        let cwdChanged = applyLatestCwdIfAny()

        // I1 bell flash: poll the engine for any bell events that
        // landed since the last tick. Latched in the FFI's
        // `drain_bell` (which collapses rapid-fire bells to one flash
        // — matches iTerm2). Setting the start time here ensures the
        // dirty-frame gate below treats the flash as a redraw reason.
        if let session, session.drain_bell() {
            bellFlashStartTime = CACurrentMediaTime()
        }

        // Unconditional cursor refresh — matches alacritty's "cursor
        // read on every render tick" approach. `applyFrameDelta` also
        // refreshes `lastCursor`, but only along the
        // `atlas && gridPipeline && attachedLayer` happy path; this
        // call covers the pre-pipeline window AND guarantees that a
        // pure-scroll path (`session.scroll_lines` from PgUp /
        // trackpad / find-bar / block-jump) lands the engine's
        // `display_offset == 0 && SHOW_CURSOR` visibility decision
        // into `lastCursor` before `encodeCursorOverlay` reads it.
        // The accessor is side-effect-free (no `poll_output`, no
        // damage drain) — see `bridge.rs::cursor_snapshot`.
        if let session {
            self.lastCursor = session.cursor_snapshot()
        }

        // M7-3: pick up a pending font-size / family change before we
        // touch the encoder so the atlas + pipeline rebuild lands on
        // a clean frame boundary. `reloadFont()` is a no-op when
        // `atlasDirty == false`, so this is allocation-free in the
        // steady state. Display-link delegate already pumps on the
        // main runloop (per `link.add(to: .main, ...)` in attach), so
        // assumeIsolated is safe here.
        var fontReloaded = false
        if atlasDirty {
            MainActor.assumeIsolated { _ = reloadFont() }
            fontReloaded = true
        }

        // P1 idle-frame skip: do all engine-consuming work (frame
        // delta drain, pending cell writes, composition apply) BEFORE
        // deciding whether to encode. Each step reports back whether
        // it produced visible changes; the encode path is short-
        // circuited when nothing wants the GPU. We still tick at
        // 120Hz to keep keystroke→pixel latency tight, but a quiescent
        // terminal commits zero command buffers per frame.

        // Pre-decode composition / pending-cells state. Both run inside
        // the pipeline-ready guard, but their dirty signals must be
        // observable here so we can decide whether to encode.
        let hadPendingCells = !pendingCellWrites.isEmpty
        let compositionWasInvalidated = compositionInvalidated
        let compositionActive = (hostView?.activeComposition != nil)
            || !preeditPaintedCells.isEmpty

        // Apply engine-driven cell writes + keystroke-spike + composition
        // to the pipeline textures. These call `MTLTexture.replace`
        // which is synchronous CPU→GPU upload and doesn't need an
        // encoder, so it's safe to run before the encode-skip decision.
        var frameHadCells = false
        if let atlas, let pipeline = gridPipeline {
            // Atlas-eviction repaint: if any LRU eviction or full reset
            // happened since the last frame, every cell's cached UV may
            // now point at a different glyph. Pull a full-frame delta
            // (re-emits every viewport row through the engine) so each
            // cell re-runs `makeSlot` and re-pins its glyph at the
            // post-eviction UV. Without this, the user sees garbled
            // text (typically Thai/CJK) until scroll forces a redraw.
            if atlas.consumePendingEviction(),
                let session = session
            {
                let frame = session.take_full_frame_delta()
                self.lastCursor = frame.cursor
                if let decoded = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                    if useShaping {
                        let coalesced = GraphemeClusterCoalescer.coalesce(decoded)
                        Self.applyCoalescedCellsAsRegions(
                            coalesced, pipeline: pipeline, atlas: atlas,
                            makeSlot: { [weak self] cell in
                                self?.makeSlot(from: cell, atlas: atlas)
                            })
                    } else {
                        Self.applyCellsAsRegions(
                            decoded, pipeline: pipeline, atlas: atlas,
                            makeSlot: { [weak self] cell in
                                self?.makeSlot(from: cell, atlas: atlas)
                            })
                    }
                }
                frameHadCells = true
            } else {
                frameHadCells = applyFrameDelta(pipeline: pipeline, atlas: atlas)
            }
            for (index, slot) in pendingCellWrites {
                try? pipeline.setCell(
                    at: index, slot: slot, atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            }
            pendingCellWrites.removeAll(keepingCapacity: true)
            applyCompositionStateIfNeeded(pipeline: pipeline, atlas: atlas)
        }

        let cursorChanged = !Self.cursorEqual(lastCursor, lastEncodedCursor)
        // A blinking, visible cursor is animation work — we must encode
        // every tick during blink (the eased curve from V2 will smooth
        // this, but the simple binary fallback already requires it).
        let blinkAnimating = (lastCursor?.blink ?? false)
            && !(lastCursor?.hidden ?? true)

        let pendingKeystrokeFrame = !pendingKeystrokeTimes.isEmpty

        // V1 scrollbar fade: redraw is needed while the fade is in
        // progress (between hold-end and resting). Past the fade end,
        // the thumb sits at resting alpha and doesn't change again
        // until the next scroll.
        let scrollbarFadeActive: Bool = {
            guard lastScrollActivityTime > 0 else { return false }
            let elapsed = CACurrentMediaTime() - lastScrollActivityTime
            return elapsed
                < Self.scrollbarHoldSec + Self.scrollbarFadeSec
        }()

        let bellFlashing: Bool = {
            guard let started = bellFlashStartTime else { return false }
            let elapsed = CACurrentMediaTime() - started
            if elapsed >= Self.bellFlashDurationSec {
                bellFlashStartTime = nil
                // One last frame to clear the flash overlay.
                return true
            }
            return true
        }()

        let needsEncode = !hasPresented
            || pendingRedraw
            || frameHadCells
            || hadPendingCells
            || cursorChanged
            || compositionWasInvalidated
            || compositionActive
            || blinkAnimating
            || pendingKeystrokeFrame
            || fontReloaded
            || titleChanged
            || cwdChanged
            || bellFlashing
            || scrollbarFadeActive

        guard needsEncode else { return }

        let drawable = update.drawable
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        encoder.label = "Grid pass (Stage 1)"

        let cpuStart = CACurrentMediaTime()

        // Drain pending keystroke timestamps now (before encoding) so the
        // completion handler closes over a stable list rather than a
        // racing array on the renderer.
        let frameKeystrokes = pendingKeystrokeTimes
        pendingKeystrokeTimes.removeAll(keepingCapacity: true)

        if let atlas, let pipeline = gridPipeline, let layer = attachedLayer {
            let cellPx = SIMD2<Float>(
                Float(atlas.cellSizePx.x), Float(atlas.cellSizePx.y))
            let drawableSizePx = SIMD2<Float>(
                Float(layer.drawableSize.width), Float(layer.drawableSize.height))
            // M5.5-3: cell grid is shifted right by the 24pt gutter.
            // `gridOriginPx` is in pixels (drawable space), so multiply
            // by the layer's contentsScale (Retina 2× or 1× external).
            let gutterPx = Float(Theme.Gutter.widthPt) *
                Float(layer.contentsScale)
            let gridOriginPx = SIMD2<Float>(gutterPx, 0)
            let uniforms = GridUniforms(
                screenSizePx: drawableSizePx,
                cellSizePx: cellPx,
                atlasSizePx: SIMD2(
                    Float(GlyphAtlas.atlasSize.x), Float(GlyphAtlas.atlasSize.y)),
                gridSizeCells: SIMD2(UInt32(gridCols), UInt32(gridRows)),
                gridOriginPx: gridOriginPx,
                colorAtlasSizePx: SIMD2(
                    Float(atlas.colorAtlasSize.x),
                    Float(atlas.colorAtlasSize.y)))
            pipeline.encode(uniforms: uniforms, atlas: atlas, encoder: encoder)

            // Stage-2 overlay pass: selection (4.5) + cursor (4.7),
            // drawn on top of the grid pass into the same render
            // encoder. `loadAction` already ran (clear), the grid
            // encode just stored its result; the overlay pipeline's
            // source-over blend composes overlays on top without
            // disturbing surrounding pixels.
            //
            // Order matters: selection tint goes BEFORE the cursor so
            // the cursor sits visually on top of any selection that
            // covers its cell. Both compose against the same stored
            // grid pass via straight-alpha source-over.
            if let overlay = overlayPipeline {
                encodeSelectionOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // SGR underline (\e[4m). Drawn after selection so it
                // sits visually on top of the selection tint (matches
                // how most terminals render — the underline survives
                // into selected text).
                encodeTextUnderlineOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                encodeCursorOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // 4.9 IME underline pass: one quad per preedit cell at
                // the cursor row's bottom 15%. Drawn after the cursor
                // overlay so the underline sits visually on top of any
                // cursor block / underline that intersects the same
                // cell — preedit takes precedence visually because the
                // user is actively composing.
                encodeImeUnderlineOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // M6-2: ⌘+hover link underline. Drawn last so it sits
                // visually above selection / cursor when those overlap
                // a hovered path's row.
                encodeLinkUnderlineOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // M7-2 ⌘F: search-match highlights. Rendered after
                // selection so they overlay the user's existing
                // selection rather than getting covered by it.
                encodeSearchHighlightOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // Scrollbar thumb. Drawn last so it sits visually on
                // top of any selection or highlight that brushes the
                // right edge.
                encodeScrollbarOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    cellSizePx: cellPx,
                    gridOriginPx: gridOriginPx,
                    overlay: overlay)
                // I1 bell flash: full-viewport tint quad that fades
                // from 0.25 alpha to 0 over 150 ms. Drawn last so it
                // tints every other overlay (cursor, scrollbar, …)
                // uniformly — matches Terminal.app's whole-window
                // flash semantics.
                encodeBellFlashOverlay(
                    encoder: encoder,
                    drawableSizePx: drawableSizePx,
                    overlay: overlay)
            }
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        if !frameKeystrokes.isEmpty {
            // `drawable.presentedTime` is the actual host time the GPU
            // finished presenting the surface to the compositor, on the
            // same `mach_absolute_time` clock as `NSEvent.timestamp`.
            // Each pending keystroke gets one render-path latency
            // sample fed to `latencyMeter`.
            //
            // Task #36 diagnostic instrumentation: when
            // `latencyMeter.diagnosticsEnabled` is true, log every
            // completion-handler invocation with timestamps. The
            // harness corruption observed mid-#16-perf manifested as
            // "1000 keystrokes fire, 0 samples land" which is
            // consistent with this handler never firing (compositor
            // present-skip starves the addCompletedHandler callback).
            // Capturing `diagEnabled` outside the closure is
            // intentional — we don't want the closure to retain the
            // meter just to read its flag.
            let diagEnabled = latencyMeter.diagnosticsEnabled
            commandBuffer.addCompletedHandler { [weak self] cb in
                let now = CACurrentMediaTime()
                // `drawable.presentedTime` is 0 if the drawable was
                // never composited to a real display (e.g., a hidden
                // test window that didn't reach the WindowServer's
                // present queue). In that case fall back to
                // `cb.gpuEndTime`, which is set whenever the GPU
                // finishes the work — same mach-time clock, but
                // captures "render done" rather than "shown on
                // screen." Test harness uses this path; production
                // launches with a visible window get the full
                // presented-time measurement.
                let presentedTime = drawable.presentedTime
                let endTime = presentedTime > 0 ? presentedTime : cb.gpuEndTime

                if diagEnabled {
                    NSLog(
                        "MetalRenderer.completedHandler t=%.6f keystrokes=%d "
                            + "presentedTime=%.6f gpuEndTime=%.6f endTime=%.6f",
                        now, frameKeystrokes.count, presentedTime,
                        cb.gpuEndTime, endTime)
                }

                guard endTime > 0 else { return }
                for ts in frameKeystrokes {
                    let latencyMs = (endTime - ts) * 1_000.0
                    self?.didMeasureKeystrokeLatency(ms: latencyMs)
                }
            }
        }
        commandBuffer.commit()

        // P1: bookkeeping for the next idle-skip decision. The encoded
        // cursor snapshot is what the just-presented frame painted; the
        // next tick compares against it. `pendingRedraw` is cleared
        // here, not at function entry, so concurrent `markNeedsRedraw`
        // calls during this frame's encode don't get lost — they pile
        // up into the next tick.
        lastEncodedCursor = lastCursor
        pendingRedraw = false
        hasPresented = true

        let cpuEnd = CACurrentMediaTime()
        recordFrameTime((cpuEnd - cpuStart) * 1_000.0)  // ms
    }

    /// Pull the latest `FrameDelta` from the Rust session, decode the
    /// `cells: Vec<u8>` payload via the zero-copy reader, and apply
    /// engine-driven cells through `pipeline.setRegion`. Called once
    /// per `CAMetalDisplayLink` tick from `draw(update:)`, per
    /// spec/ffi-boundary.md:240 ("Swift calls take_frame_delta()
    /// synchronously from that callback").
    ///
    /// swift-bridge transfers ownership of the `Vec<u8>` allocation per
    /// call: the returned `FrameDelta` carries a Swift-owned `RustVec`
    /// that frees on `deinit`. The Rust-side buffer's lifetime is the
    /// `FrameDelta` value's lifetime — scoped to this function body.
    /// Decoding and application both happen before `frame` drops at
    /// function exit, so the zero-copy `RustVec.as_ptr()` reads are
    /// safe.
    ///
    /// **Region grouping (#57):** decoded cells are sorted by
    /// (row, col) and split into row-contiguous runs. Each run is
    /// pushed through `pipeline.setRegion` as a 1×N rect, collapsing
    /// 3·N `replace(region:)` calls into 3 calls per run. For typical
    /// PTY traffic (a handful of full lines + cursor moves) this is
    /// the dominant per-frame Metal driver cost on the FrameDelta
    /// path; the keystroke spike path (`pendingCellWrites`) keeps
    /// `setCell` since it always carries exactly one cell.
    ///
    /// `makeSlot(from:)` returns `nil` today (Phase 1 stub); the
    /// producer also returns 0 cells, so the inner loop runs zero
    /// times in practice. Both light up at M1 Week 1 task 1.6 (#56).
    @discardableResult
    private func applyFrameDelta(pipeline: GridPipeline, atlas: GlyphAtlas) -> Bool {
        guard let session else { return false }
        let frame = session.take_frame_delta()
        // Cursor state is consumed by the Stage-2 overlay encode in
        // `draw(update:)`. Snapshot it BEFORE the decode + apply so a
        // malformed-cells early-return (`decodeCells throws`) can't
        // leave `lastCursor` pinned to a stale visibility state. The
        // engine's `display_offset == 0 && SHOW_CURSOR` gate (see
        // `engine.rs::cursor()`) flips this on every scroll-into-
        // history; without an unconditional refresh the cursor stays
        // drawn at the last live-grid row while the user pages
        // through scrollback.
        self.lastCursor = frame.cursor
        let decoded: [CellDeltaSwift]
        do {
            decoded = try FrameDeltaDecoding.decodeCells(frame.cells)
        } catch {
            NSLog(
                "MetalRenderer: frame delta decode failed: %@",
                String(describing: error))
            return false
        }
        if useShaping {
            let coalesced = GraphemeClusterCoalescer.coalesce(decoded)
            Self.applyCoalescedCellsAsRegions(
                coalesced, pipeline: pipeline, atlas: atlas,
                makeSlot: { [weak self] cell in
                    self?.makeSlot(from: cell, atlas: atlas)
                })
        } else {
            Self.applyCellsAsRegions(
                decoded, pipeline: pipeline, atlas: atlas,
                makeSlot: { [weak self] cell in
                    self?.makeSlot(from: cell, atlas: atlas)
                })
        }
        // M7-2: cache scroll_top so the search-highlight overlay can
        // translate alacritty-absolute match lines into viewport rows
        // every frame (so highlights track content as the user scrolls
        // without re-running search).
        let scrollChanged = self.lastScrollTop != Int(frame.scroll_top)
            || self.lastScrollTotal != Int(frame.scroll_total)
        self.lastScrollTop = Int(frame.scroll_top)
        self.lastScrollTotal = Int(frame.scroll_total)
        if scrollChanged {
            // V1 scrollbar fade: bump activity so the thumb pops back
            // to full opacity. Also any new cell delta counts as
            // "user is scrolled into history and live tail moved"
            // implicitly via the engine's scroll-on-output snap,
            // but only the top/total changes are real scroll events.
            lastScrollActivityTime = CACurrentMediaTime()
        }
        return !decoded.isEmpty || scrollChanged
    }

    /// Apply a decoded cell stream as row-contiguous region writes.
    /// Static + parameterized on `makeSlot` so unit tests can exercise
    /// the grouping logic without instantiating a full renderer.
    ///
    /// Algorithm:
    ///   1. Resolve each `CellDeltaSwift` to a `CellSlot` via `makeSlot`;
    ///      cells that resolve to `nil` (out-of-cascade glyph, malformed
    ///      grapheme) are dropped.
    ///   2. Sort the resolved (row, col, slot) triples by (row, col).
    ///      The Rust producer at #56 writes in row-major scan order, so
    ///      this is typically already-sorted; the sort is a safety net,
    ///      not the hot path.
    ///   3. Walk the sorted list emitting one `setRegion` per maximal
    ///      run of (same row, contiguous col).
    static func applyCellsAsRegions(
        _ decoded: [CellDeltaSwift],
        pipeline: GridPipeline,
        atlas: GlyphAtlas,
        makeSlot: (CellDeltaSwift) -> CellSlot?
    ) {
        guard !decoded.isEmpty else { return }
        var resolved: [(row: Int, col: Int, slot: CellSlot)] = []
        resolved.reserveCapacity(decoded.count)
        for cell in decoded {
            guard let slot = makeSlot(cell) else { continue }
            resolved.append((row: Int(cell.row), col: Int(cell.col), slot: slot))
        }
        guard !resolved.isEmpty else { return }
        resolved.sort { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }

        // Coalesce maximal (row == prev.row && col == prev.col + 1) runs.
        // `runStart` indexes the first element of the current run,
        // `runEnd` is one-past-the-last (half-open).
        var runStart = 0
        while runStart < resolved.count {
            let start = resolved[runStart]
            var runEnd = runStart + 1
            while runEnd < resolved.count {
                let prev = resolved[runEnd - 1]
                let curr = resolved[runEnd]
                if curr.row == prev.row && curr.col == prev.col + 1 {
                    runEnd += 1
                } else {
                    break
                }
            }
            let width = runEnd - runStart
            var slots: [CellSlot] = []
            slots.reserveCapacity(width)
            for k in runStart..<runEnd {
                slots.append(resolved[k].slot)
            }
            let rect = GridPipeline.GridRect(
                col: start.col, row: start.row, width: width, height: 1)
            do {
                try pipeline.setRegion(
                    rect: rect, slots: slots,
                    atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            } catch {
                // Bounds errors from a misbehaving Rust producer are
                // logged but non-fatal — drop the run and continue;
                // the next frame's setRegion calls re-establish state.
                NSLog(
                    "MetalRenderer.applyCellsAsRegions: setRegion failed for "
                        + "rect=(%d,%d %dx%d): %@",
                    rect.col, rect.row, rect.width, rect.height,
                    String(describing: error))
            }
            runStart = runEnd
        }
    }

    /// ADR-19 atomic 4 — coalesced-cell variant of
    /// `applyCellsAsRegions`. Each `CoalescedCell` expands to one
    /// primary slot at `(row, col)` carrying the cluster glyph (whose
    /// `AtlasEntry.cellSpan == cellSpan`, so GridPipeline packs the
    /// high byte of `cellAtlasSelector` accordingly) plus `cellSpan-1`
    /// continuation slots at `(row, col+1)..(row, col+cellSpan-1)`
    /// with `glyph = nil` — those pack as selector=0/cellSpan=0, which
    /// the fragment shader treats as continuation-of-primary-to-left.
    ///
    /// Run grouping logic is identical to the `CellDeltaSwift` variant
    /// above (sort by (row, col); emit maximal contiguous runs through
    /// `setRegion`). Primary + continuation cells of a single cluster
    /// land in the same run.
    static func applyCoalescedCellsAsRegions(
        _ coalesced: [CoalescedCell],
        pipeline: GridPipeline,
        atlas: GlyphAtlas,
        makeSlot: (CoalescedCell) -> CellSlot?
    ) {
        guard !coalesced.isEmpty else { return }
        var resolved: [(row: Int, col: Int, slot: CellSlot)] = []
        resolved.reserveCapacity(coalesced.count)
        for cell in coalesced {
            guard let primary = makeSlot(cell) else { continue }
            resolved.append((
                row: Int(cell.row), col: Int(cell.col), slot: primary))
            // Emit cellSpan-1 continuation cells. Each carries the
            // primary's bg so the cluster row paints a contiguous
            // background; foreground is irrelevant (no glyph). The
            // shader's leftward primary-walk reads the glyph from the
            // primary's selector byte, not from continuations.
            let span = max(UInt8(1), cell.cellSpan)
            if span >= 2 {
                let continuation = CellSlot(
                    glyph: nil,
                    fgColorLinear: primary.fgColorLinear,
                    bgColorLinear: primary.bgColorLinear,
                    attrs: primary.attrs)
                for k in 1..<Int(span) {
                    resolved.append((
                        row: Int(cell.row),
                        col: Int(cell.col) + k,
                        slot: continuation))
                }
            }
        }
        guard !resolved.isEmpty else { return }
        resolved.sort { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }

        var runStart = 0
        while runStart < resolved.count {
            let start = resolved[runStart]
            var runEnd = runStart + 1
            while runEnd < resolved.count {
                let prev = resolved[runEnd - 1]
                let curr = resolved[runEnd]
                if curr.row == prev.row && curr.col == prev.col + 1 {
                    runEnd += 1
                } else {
                    break
                }
            }
            let width = runEnd - runStart
            var slots: [CellSlot] = []
            slots.reserveCapacity(width)
            for k in runStart..<runEnd {
                slots.append(resolved[k].slot)
            }
            let rect = GridPipeline.GridRect(
                col: start.col, row: start.row, width: width, height: 1)
            do {
                try pipeline.setRegion(
                    rect: rect, slots: slots,
                    atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            } catch {
                NSLog(
                    "MetalRenderer.applyCoalescedCellsAsRegions: setRegion "
                        + "failed for rect=(%d,%d %dx%d): %@",
                    rect.col, rect.row, rect.width, rect.height,
                    String(describing: error))
            }
            runStart = runEnd
        }
    }

    /// Translate an engine-produced `CellDeltaSwift` into a renderable
    /// `CellSlot`. Implements task 4.1 (SGR colors) end-to-end:
    ///
    /// 1. Resolve `fg` / `bg` u32 (engine `pack_rgba` encoding —
    ///    `R<<24 | G<<16 | B<<8 | 0xff`, with sentinels `0xffff_ffff`
    ///    for `NamedColor::Foreground` and `0x0000_00ff` for
    ///    `NamedColor::Background`) to linear-space `SIMD4<Float>` via
    ///    `SRGBLinearLUT` and `Theme.Color.defaultPalette`. The framebuffer is
    ///    `.bgra8Unorm_srgb` so the grid shader's mix runs in linear
    ///    space and Metal sRGB-encodes on store.
    ///
    /// 2. Decode `cell.grapheme` (UTF-8, null-padded to 8 bytes) to its
    ///    first `Unicode.Scalar`. A blank cell (space or all-zero
    ///    grapheme) returns a `CellSlot(glyph: nil, …)` so the
    ///    background still paints — **never** `nil`, since
    ///    `applyCellsAsRegions` drops nil slots and stale texture
    ///    contents would persist.
    ///
    /// 3. Look up the scalar in `atlas`. BMP-only path may throw
    ///    `glyphMissing` for astrals + grapheme clusters; we catch and
    ///    return a blank slot. Font fallback (task 4.3) and atlas LRU
    ///    (4.2) light up later. Each missing scalar is logged once via
    ///    `loggedMissingScalars` to surface coverage gaps without
    ///    spamming the console under traffic.
    ///
    /// `cell.width == 2` (wide-char primary) is rendered into its
    /// single grid slot for now; spanning two cells is task 4.3 work.
    /// The continuation cell is filtered upstream by
    /// `CellView::from_alacritty_cell` (`cells.rs:121`) so we never see
    /// it here.
    // TODO(post-4.1): honor cell.attrs (BOLD/ITALIC need font-weight
    // selection — overlaps 4.3; UNDERLINE needs an overlay pass).
    /// Cached resolved palette — refreshed on `themeDidChange` and on
    /// renderer init. Read on the same thread that drives drawing,
    /// avoiding the MainActor hop in the per-cell hot loop. The
    /// `themeDidChange` observer below mutates this on the main runloop.
    private var resolvedPalette: Theme.Palette = Theme.Color.defaultPalette

    /// Active cursor color (file-backed theme wins over the static
    /// `Theme.Color.cursorDefaultLinear`). Refreshed by
    /// `refreshClearColor`.
    private var resolvedCursor: SIMD4<Float> = Theme.Color.cursorDefaultLinear

    /// Active selection-bg color. File-backed theme wins.
    private var resolvedSelection: SIMD4<Float> = Theme.Color.selectionBgLinear

    /// Engine-baked-ANSI-hex → theme-file-ANSI-override map. Built
    /// from `ThemeFile.ansi` on theme change so per-cell color
    /// resolution can apply the override in O(1) without changing
    /// the FFI surface. Empty = no override active (engine values
    /// pass through unchanged).
    ///
    /// The engine bakes 16 zenzai-v2 ANSI values into encode_named
    /// at compile time (`cells.rs`); user-selected file themes ride
    /// on top via this map. Keys are the engine's packed `u32`
    /// (`R<<24 | G<<16 | B<<8 | A`).
    private var ansiOverride: [UInt32: SIMD4<Float>] = [:]

    /// Engine's 16 compile-time ANSI hex values (matcha palette).
    /// Mirrors `cells.rs::encode_named` order:
    ///   0..7   = normal black/red/green/yellow/blue/magenta/cyan/white
    ///   8..15  = bright variants
    /// Hex stored in packed `R<<24 | G<<16 | B<<8 | 0xff` form so the
    /// override map can key directly on the u32 the renderer reads
    /// off `cell.fg` / `cell.bg`.
    private static let engineAnsiHex: [UInt32] = [
        0x2a34_24ff, 0xd470_70ff, 0xa8cc_8cff, 0xd4c0_78ff,
        0x6898_b0ff, 0xb890_a8ff, 0x70b8_a0ff, 0xc8d0_b8ff,
        0x3a4a_34ff, 0xe888_88ff, 0xb8dc_a0ff, 0xe8d8_90ff,
        0x80b0_c8ff, 0xd0a8_c0ff, 0x88d0_b8ff, 0xd8e0_ccff,
    ]

    private static func buildAnsiOverride(
        file: ThemeFile
    ) -> [UInt32: SIMD4<Float>] {
        guard file.ansi.count == 16 else { return [:] }
        var out: [UInt32: SIMD4<Float>] = [:]
        out.reserveCapacity(16)
        for (i, hex) in engineAnsiHex.enumerated() {
            out[hex] = file.ansi[i]
        }
        return out
    }

    private func makeSlot(from cell: CellDeltaSwift, atlas: GlyphAtlas) -> CellSlot? {
        Self.makeSlot(
            from: cell,
            atlas: atlas,
            commandQueue: commandQueue,
            palette: resolvedPalette,
            ansiOverride: ansiOverride,
            onAtlasMiss: { [weak self] scalar, error in
                self?.logMissingGlyphOnce(scalar: scalar, error: error)
            })
    }

    /// Pick the styled atlas entry for a (scalar, attrs) pair.
    /// Branches on alacritty `Flags::BOLD` (0x0002) / `Flags::ITALIC`
    /// (0x0004); plain text takes the unstyled fast path so the
    /// per-cell cost stays the same as pre-styled-text.
    static func lookupGlyph(
        scalar: Unicode.Scalar,
        attrs: UInt16,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        let bold = (attrs & 0x0002) != 0
        let italic = (attrs & 0x0004) != 0
        if !bold && !italic {
            return try atlas.entry(for: scalar, commandQueue: commandQueue)
        }
        let font = atlas.styledFont(bold: bold, italic: italic)
        return try atlas.entry(
            for: scalar, font: font, commandQueue: commandQueue)
    }

    /// Test-friendly static variant. Pure logic — no `self` capture, so
    /// `MetalRendererSGRColorTests` can drive it without standing up a
    /// renderer (which requires a window + display link). The instance
    /// method above is the production caller.
    ///
    /// Returns `Optional<CellSlot>` to fit the existing
    /// `applyCellsAsRegions` makeSlot closure signature, but the body
    /// here NEVER returns nil — even atlas-miss paths return a blank
    /// slot. Once 4.3 lands the closure signature can drop the optional.
    static func makeSlot(
        from cell: CellDeltaSwift,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue,
        palette: Theme.Palette,
        ansiOverride: [UInt32: SIMD4<Float>] = [:],
        onAtlasMiss: ((Unicode.Scalar, Error) -> Void)? = nil
    ) -> CellSlot? {
        var fg = resolveColor(
            packed: cell.fg, sentinel: 0xffff_ffff,
            fallback: palette.defaultFgLinear,
            override: ansiOverride)
        var bg = resolveColor(
            packed: cell.bg, sentinel: 0x0000_00ff,
            fallback: palette.defaultBgLinear,
            override: ansiOverride)

        // INVERSE (alacritty `Flags::INVERSE` = bit 0, value 0x0001)
        // swaps fg/bg. TUIs (Claude Code, vim selection, less status
        // line) draw their cursors and selections via `\e[7m` — without
        // this swap those reads as plain unstyled text.
        if (cell.attrs & 0x0001) != 0 {
            swap(&fg, &bg)
        }

        guard let clusterString = decodeGraphemeString(cell.grapheme),
            let scalar = clusterString.unicodeScalars.first
        else {
            // All-zero grapheme — engine emits this for blank cells
            // populated by the default empty-cell template. Paint bg
            // only; no glyph lookup.
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        // Fast path: ASCII space renders pure background. Skips the
        // atlas lookup entirely (it would resolve to a blank glyph
        // anyway, but no point burning the CoreText path on it).
        if clusterString.unicodeScalars.count == 1, scalar.value == 0x20 {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        // Multi-codepoint grapheme cluster (Thai base + tone mark,
        // Devanagari + matra, Hangul jamo, emoji ZWJ sequences):
        // route through CTLine so CoreText applies shaping + mark
        // positioning. Single-scalar grapheme stays on the fast path.
        if clusterString.unicodeScalars.count > 1 {
            do {
                let entry = try atlas.entry(
                    forCluster: clusterString, commandQueue: commandQueue)
                return CellSlot(
                    glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            } catch {
                onAtlasMiss?(scalar, error)
                return CellSlot(
                    glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            }
        }

        do {
            let entry = try lookupGlyph(
                scalar: scalar, attrs: cell.attrs, atlas: atlas,
                commandQueue: commandQueue)
            return CellSlot(glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        } catch {
            onAtlasMiss?(scalar, error)
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
    }

    /// ADR-19 atomic 4 — resolve a `CoalescedCell` (coalescer output)
    /// to a `CellSlot` for the primary cell. Continuation cells are
    /// emitted separately as `slot.glyph = nil` so they pack as
    /// selector=0 / cellSpan=0 (continuation sentinel per atomic 3).
    ///
    /// Routing:
    ///   - `cellSpan >= 2`  → cluster atlas slot rasterized at
    ///     `cellSpan * cellW` wide via `entry(forCluster:cellSpan:)`.
    ///   - `cellSpan == 1` multi-scalar → existing cluster path (span=1).
    ///   - `cellSpan == 1` single-scalar → fast scalar atlas path.
    private func makeSlot(
        from cell: CoalescedCell, atlas: GlyphAtlas
    ) -> CellSlot? {
        Self.makeSlot(
            from: cell,
            atlas: atlas,
            commandQueue: commandQueue,
            palette: resolvedPalette,
            ansiOverride: ansiOverride,
            onAtlasMiss: { [weak self] scalar, error in
                self?.logMissingGlyphOnce(scalar: scalar, error: error)
            })
    }

    /// Test-friendly static variant for the coalesced-cell slot. Mirrors
    /// the `CellDeltaSwift` static above; pure logic so unit tests can
    /// drive it without a live renderer.
    static func makeSlot(
        from cell: CoalescedCell,
        atlas: GlyphAtlas,
        commandQueue: MTLCommandQueue,
        palette: Theme.Palette,
        ansiOverride: [UInt32: SIMD4<Float>] = [:],
        onAtlasMiss: ((Unicode.Scalar, Error) -> Void)? = nil
    ) -> CellSlot? {
        var fg = resolveColor(
            packed: cell.fg, sentinel: 0xffff_ffff,
            fallback: palette.defaultFgLinear,
            override: ansiOverride)
        var bg = resolveColor(
            packed: cell.bg, sentinel: 0x0000_00ff,
            fallback: palette.defaultBgLinear,
            override: ansiOverride)
        if (cell.attrs & 0x0001) != 0 {
            swap(&fg, &bg)
        }

        let clusterString = cell.grapheme
        guard let scalar = clusterString.unicodeScalars.first else {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
        if clusterString.unicodeScalars.count == 1,
           scalar.value == 0x20, cell.cellSpan <= 1 {
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }

        let span = max(UInt8(1), cell.cellSpan)
        // Multi-cell cluster or multi-scalar grapheme → cluster atlas.
        if span >= 2 || clusterString.unicodeScalars.count > 1 {
            do {
                let entry = try atlas.entry(
                    forCluster: clusterString,
                    cellSpan: span,
                    commandQueue: commandQueue)
                return CellSlot(
                    glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            } catch {
                onAtlasMiss?(scalar, error)
                return CellSlot(
                    glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
            }
        }

        // Single-scalar, single-cell: fast scalar atlas path.
        do {
            let entry = try lookupGlyph(
                scalar: scalar, attrs: cell.attrs, atlas: atlas,
                commandQueue: commandQueue)
            return CellSlot(glyph: entry, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        } catch {
            onAtlasMiss?(scalar, error)
            return CellSlot(glyph: nil, fgColorLinear: fg, bgColorLinear: bg, attrs: cell.attrs)
        }
    }

    /// Decode the full UTF-8 grapheme buffer to a Swift String, trimming
    /// trailing nulls. Returns `nil` on all-zero/malformed input.
    /// Used by both the single-scalar and the cluster atlas paths.
    static func decodeGraphemeString(_ grapheme: [UInt8]) -> String? {
        var end = grapheme.count
        for (i, byte) in grapheme.enumerated() where byte == 0 {
            end = i
            break
        }
        guard end > 0 else { return nil }
        return String(bytes: grapheme.prefix(end), encoding: .utf8)
    }

    /// Resolve a packed RGBA8 color (engine `pack_rgba` layout) to a
    /// linear-space `SIMD4<Float>`. Sentinels (`0xffff_ffff` foreground,
    /// `0x0000_00ff` background — see `cells.rs:224-225`) bypass the
    /// LUT and use the active palette's default. Any other value goes
    /// through `SRGBLinearLUT.unpackLinear` for the sRGB→linear
    /// conversion.
    @inline(__always)
    static func resolveColor(
        packed: UInt32, sentinel: UInt32, fallback: SIMD4<Float>,
        override: [UInt32: SIMD4<Float>] = [:]
    ) -> SIMD4<Float> {
        if packed == sentinel { return fallback }
        // Theme-file ANSI override: cells the engine baked with its
        // compile-time encode_named values get redirected to the
        // user's theme-file palette. Truecolor SGR (`38;2;r;g;b`)
        // values almost never collide with the 16 named hexes so
        // this is safe in practice.
        if let mapped = override[packed] {
            return mapped
        }
        return SRGBLinearLUT.unpackLinear(packed)
    }

    /// 4.5 selection overlay tint. Per spec/metal-renderer.md §Stage 2,
    /// selection is rendered at 0.35 alpha over the grid pass; the
    /// shader stays kind-agnostic and we modulate alpha CPU-side via
    /// `colorLinear.a`. Color comes from `Theme.Color.selectionBgLinear`
    /// (`#3d4254` per spec/design-tokens.md).
    ///
    /// **Span shape (4.5 scope cut):** stream selections only.
    /// `is_block == true` is plumbed through the FFI but rendered as
    /// stream — block-mode rendering is paired with block-mode input
    /// (alt-drag), and the brief defers the input plumb. The renderer
    /// is shape-ready (the `is_block` flag is read; only the encode
    /// strategy is shared) so when block-mode lands it's a single
    /// branch in this method.
    ///
    /// Stream geometry, given a span `(start_row, start_col, end_row,
    /// end_col)`:
    ///   - Single row (`start_row == end_row`): one quad spanning
    ///     `[start_col, end_col]` × that row.
    ///   - Multi-row: first row covers `[start_col, viewportCols)`;
    ///     middle rows cover `[0, viewportCols)`; last row covers
    ///     `[0, end_col]`. One overlay quad per row.
    ///
    /// Spans are passed through `OverlayUniforms.cellSpanCols`; the
    /// vertex shader stretches the quad's x-extent so each row is one
    /// draw call regardless of width. Y-axis stays single-cell.
    // PG4 selection contrast: 0.35 was the original "soft tint" that
    // kept underlying glyphs visible but produced low contrast on
    // dark themes (matcha selection #2a3424 over bg-base #0e0d10 at
    // 35% looked like a barely-there green shadow). 0.55 reads as a
    // confident selection while still letting the glyph show
    // through. True reverse-video (swap fg/bg per cell) is shader
    // work — tracked separately. This is the 80% win.
    static let selectionAlpha: Float = 0.55
    private func encodeSelectionOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let session else { return }
        // Wire format: empty → no selection; 5 u32s otherwise per
        // bridge.rs::TerminalSession::selection_span.
        //
        // **Source of truth**: prefer the Swift-side `swiftSelectionSpan`
        // mirror over the engine's span when set. alacritty clears its
        // own `Term::selection` on grid writes that intersect the
        // selection's row range (term/mod.rs:1657,1773,1786,1803,1811);
        // TUIs that redraw rows on every render tick would otherwise
        // see the selection-tint vanish under their feet. The Swift
        // mirror is the authoritative UI-layer record of "what cells
        // does the user have selected" — see
        // `TerminalSurfaceView.pendingSelection` docs.
        let startRow: Int
        let startCol: Int
        let endRow: Int
        let endCol: Int
        let isBlock: Bool
        if let mirror = hostView?.swiftSelectionSpan, mirror.count == 5 {
            startRow = Int(mirror[0])
            startCol = Int(mirror[1])
            endRow = Int(mirror[2])
            endCol = Int(mirror[3])
            isBlock = mirror[4] != 0
        } else {
            let span = session.selection_span()
            guard span.len() == 5 else { return }
            startRow = Int(span.get(index: 0).map { $0 } ?? 0)
            startCol = Int(span.get(index: 1).map { $0 } ?? 0)
            endRow = Int(span.get(index: 2).map { $0 } ?? 0)
            endCol = Int(span.get(index: 3).map { $0 } ?? 0)
            isBlock = (span.get(index: 4).map { $0 } ?? 0) != 0
        }

        // Defensive bounds: clamp to viewport so a misbehaving
        // producer can't drive an off-screen quad. Real out-of-range
        // inputs are clamped engine-side; this is belt-and-braces.
        let maxCol = max(0, gridCols - 1)
        let maxRow = max(0, gridRows - 1)
        let sR = min(max(startRow, 0), maxRow)
        let eR = min(max(endRow, 0), maxRow)
        let sC = min(max(startCol, 0), maxCol)
        let eC = min(max(endCol, 0), maxCol)

        // Per-row encode helper.
        func encodeRow(row: Int, fromCol: Int, toCol: Int) {
            guard fromCol <= toCol else { return }
            let spanCells = toCol - fromCol + 1
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(fromCol) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            var color = resolvedSelection
            color.w = Self.selectionAlpha
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.selection.rawValue,
                alpha: 1.0,
                cellSpanCols: UInt32(spanCells))
            overlay.encode(uniforms: uniforms, encoder: encoder)
        }

        if isBlock {
            // Block-mode: each row covers [sC, eC]. Documented as
            // shape-ready scope-cut — the input side stays deferred.
            for r in sR...eR {
                encodeRow(row: r, fromCol: sC, toCol: eC)
            }
        } else if sR == eR {
            encodeRow(row: sR, fromCol: sC, toCol: eC)
        } else {
            // First row: [sC, lastCol]
            encodeRow(row: sR, fromCol: sC, toCol: maxCol)
            // Middle rows: full width
            if eR > sR + 1 {
                for r in (sR + 1)...(eR - 1) {
                    encodeRow(row: r, fromCol: 0, toCol: maxCol)
                }
            }
            // Last row: [0, eC]
            encodeRow(row: eR, fromCol: 0, toCol: eC)
        }
    }

    /// Encode the Stage-2 cursor overlay quad against the open render
    /// encoder. Skips encode when the cursor is hidden (DECTCEM `?25l`),
    /// when the cursor cell is outside the current grid, or when the
    /// blink phase is in its off half.
    ///
    /// Shape mapping pins `bridge.rs::kinds::CURSOR_SHAPE_*`
    /// (`bridge.rs:101-104`):
    ///   0 (`CURSOR_SHAPE_BLOCK`)     → `.cursorBlock`
    ///   1 (`CURSOR_SHAPE_BEAM`)      → `.cursorBeam`
    ///   2 (`CURSOR_SHAPE_UNDERLINE`) → `.cursorUnderline`
    ///   _                            → `.cursorBlock` (safe default)
    private func encodeCursorOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let cursor = lastCursor, !cursor.hidden else { return }
        // UX3: don't draw the cursor while the user is scrolled into
        // history (display_offset > 0). It's misleading there — the
        // I-beam-style overlay on old output reads as "this line is
        // editable" when it isn't. Snap-to-bottom restores the cursor
        // automatically on the next input frame, so we just gate the
        // encode here. Matches Terminal.app / iTerm2 behaviour.
        if lastScrollTop > 0 { return }
        // Defensive: a misbehaving producer could place the cursor
        // outside the grid; we drop rather than encode an off-screen
        // quad (which is harmless but wastes a draw call).
        guard Int(cursor.row) < gridRows,
            Int(cursor.col) < gridCols
        else { return }

        let kind = Self.cursorKind(forShape: cursor.shape)

        // Lazily anchor the blink phase so blink starts from "visible"
        // the moment the renderer has work to do, not the moment the
        // process launched (which can be seconds before the first
        // frame on a cold start).
        let now = CACurrentMediaTime()
        if blinkOriginTime == nil { blinkOriginTime = now }
        let elapsed = now - (blinkOriginTime ?? now)

        // V2 pause-on-type: hold solid while the user is actively
        // typing. The blink resumes ~500 ms after the last keystroke.
        // Re-anchor `blinkOriginTime` on resume so the cursor enters
        // at the visible-steady phase rather than mid-fade.
        let timeSinceKey = now - lastKeystrokeTime
        let typingActive = lastKeystrokeTime > 0
            && timeSinceKey < Self.blinkPauseAfterKeystrokeSec
        // UX6: re-anchor `blinkOriginTime` only on the typing → idle
        // transition. Continuously anchoring during typing (the
        // previous behaviour) made `elapsed` jump to the pause
        // duration the instant typing stopped — landing the first
        // post-pause frame in the hidden-steady phase, so the cursor
        // disappeared for ~150 ms right when the user finished typing
        // and expected to see it. Anchoring only at the boundary
        // guarantees the first idle frame enters the visible-steady
        // phase (elapsed = 0).
        if !typingActive && wasTypingLastFrame {
            blinkOriginTime = now
        }
        wasTypingLastFrame = typingActive

        let alpha: Float
        if !cursor.blink || typingActive {
            alpha = 1.0
        } else {
            // Recompute elapsed in case we re-anchored above.
            let elapsedNow = now - (blinkOriginTime ?? now)
            alpha = easedBlinkAlpha(
                elapsed: elapsedNow, period: Self.blinkPeriodSec)
        }

        // Blink-off phase: no encode, no waste.
        guard alpha > 0 else { return }

        let originPx = SIMD2<Float>(
            gridOriginPx.x + Float(cursor.col) * cellSizePx.x,
            gridOriginPx.y + Float(cursor.row) * cellSizePx.y)

        var color = resolvedCursor
        // Modulate the uniform's alpha through the color's alpha so the
        // shader's `colorLinear.a * alpha` term is the source of truth.
        // Color stays straight-RGBA; the source-over blend factor is
        // configured on the pipeline.
        color.w = 1.0

        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: cellSizePx,
            colorLinear: color,
            kind: kind.rawValue,
            alpha: alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// 4.9: paint preedit cells over the grid texture, or restore the
    /// underlying real cells when composition just cleared.
    ///
    /// Strategy: composition state lives Swift-side only. We poll the
    /// host view's `activeComposition` each frame; when it's non-nil
    /// AND `compositionInvalidated` is set (avoids redundant uploads
    /// on stable composition frames), we upload preedit cells via
    /// `setRegion` at the cursor row. When composition just ended
    /// (`compositionInvalidated && composition == nil`), we restore
    /// the cells we'd been painting from the cached `cells` shadow
    /// array — the engine doesn't mark them dirty (we never sent
    /// preedit through the FFI), so without this restore the preedit
    /// glyphs would linger on screen until the next real PTY write
    /// touches those cells.
    ///
    /// The `cells` shadow may be empty post-resize (cleared by
    /// `resizeGrid`) — in that case we fall back to a blank-cell
    /// repaint with the theme's default background. Acceptable
    /// because resize triggers a full repaint from alacritty anyway
    /// on the next FrameDelta.
    private func applyCompositionStateIfNeeded(
        pipeline: GridPipeline, atlas: GlyphAtlas
    ) {
        let composition = hostView?.activeComposition
        // Fast path: no composition AND nothing to clean up. Most
        // frames take this exit.
        if composition == nil && !compositionInvalidated
            && preeditPaintedCells.isEmpty
        {
            return
        }

        // Restore previously-painted preedit cells from the cached
        // grid state. Done unconditionally when there ARE painted
        // cells — covers two cases:
        //   - composition just ended: no new preedit overwrite, so
        //     restore puts real cells back.
        //   - composition refined to a SHORTER preedit: tail cells
        //     that the new preedit doesn't cover need their real
        //     content back.
        // For composition that grew or stayed same length, the
        // upcoming preedit upload overwrites the restored cells, so
        // the restore is wasted work. Acceptable cost — composition
        // typically refines once per word, well under any latency
        // budget concern.
        if !preeditPaintedCells.isEmpty {
            for (row, col) in preeditPaintedCells {
                let restoredSlot = restoredSlot(row: row, col: col)
                let rect = GridPipeline.GridRect(
                    col: col, row: row, width: 1, height: 1)
                try? pipeline.setRegion(
                    rect: rect, slots: [restoredSlot],
                    atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            }
            preeditPaintedCells.removeAll(keepingCapacity: true)
        }

        // Paint new preedit cells (if any).
        if let comp = composition, !comp.text.isEmpty {
            paintPreeditCells(
                text: comp.text, pipeline: pipeline, atlas: atlas)
        }

        compositionInvalidated = false
    }

    /// 4.9: resolve the underlying real cell at (row, col) from the
    /// renderer's cached shadow. Falls back to a blank cell with
    /// theme defaults when:
    ///   - the shadow is empty (post-resize, before next FrameDelta), or
    ///   - the index is out of range (defensive — preedit cells should
    ///     always sit inside the grid since we clamp at paint time).
    private func restoredSlot(row: Int, col: Int) -> CellSlot {
        let idx = row * gridCols + col
        if idx >= 0, idx < cells.count {
            return cells[idx]
        }
        return CellSlot(
            glyph: nil,
            fgColorLinear: Theme.Color.textPrimaryLinear,
            bgColorLinear: Theme.Color.bgBaseLinear)
    }

    /// 4.9: paint preedit `text` starting at the cursor cell. Each
    /// scalar maps to one cell. Truncated at the viewport's right
    /// edge — wrapping preedit to the next row would mismatch the
    /// IME's candidate-window anchor (which is fixed at the cursor
    /// cell). Records the painted cells in `preeditPaintedCells` so
    /// the next composition-state-change frame can restore them.
    private func paintPreeditCells(
        text: String, pipeline: GridPipeline, atlas: GlyphAtlas
    ) {
        guard let cursor = lastCursor else { return }
        let row = Int(cursor.row)
        let startCol = Int(cursor.col)
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols
        else { return }

        var slots: [CellSlot] = []
        var col = startCol
        for scalar in text.unicodeScalars {
            guard col < gridCols else { break }
            let glyph = try? atlas.entry(
                for: scalar, commandQueue: commandQueue)
            slots.append(
                CellSlot(
                    glyph: glyph,
                    fgColorLinear: Theme.Color.textPrimaryLinear,
                    bgColorLinear: Theme.Color.bgBaseLinear))
            col += 1
        }
        guard !slots.isEmpty else { return }

        let rect = GridPipeline.GridRect(
            col: startCol, row: row,
            width: slots.count, height: 1)
        do {
            try pipeline.setRegion(
                rect: rect, slots: slots,
                atlasSize: GlyphAtlas.atlasSize, colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            for i in 0..<slots.count {
                preeditPaintedCells.append((row: row, col: startCol + i))
            }
        } catch {
            NSLog(
                "MetalRenderer.paintPreeditCells: setRegion failed for "
                    + "rect=(%d,%d %dx%d): %@",
                rect.col, rect.row, rect.width, rect.height,
                String(describing: error))
        }
    }

    /// 4.9: encode one IME-underline quad per preedit cell at the
    /// cursor row. The shader's kind=3 case lights the bottom ~15%
    /// of each cell with `colorLinear` (`Theme.Color.imeUnderlineLinear`).
    /// Skipped when no composition is active.
    private func encodeImeUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let comp = hostView?.activeComposition,
            !comp.text.isEmpty,
            let cursor = lastCursor
        else { return }
        let row = Int(cursor.row)
        let startCol = Int(cursor.col)
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols
        else { return }

        var color = Theme.Color.imeUnderlineLinear
        color.w = 1.0  // straight alpha; the shader gates by cellUV.y

        var col = startCol
        for _ in comp.text.unicodeScalars {
            guard col < gridCols else { break }
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(col) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.imeUnderline.rawValue,
                alpha: 1.0,
                cellSpanCols: 1)
            overlay.encode(uniforms: uniforms, encoder: encoder)
            col += 1
        }
    }

    /// M6-2: encode a single-row, N-cell underline at `linkHover` so a
    /// ⌘+hovered file path looks clickable. Reuses the kind=3 shader
    /// path (`imeUnderline`, bottom ~15% of cell) with a link-tint color
    /// so no shader change is needed. Skipped when `linkHover` is nil
    /// (not hovering, ⌘ not down, or detection disabled).
    private func encodeLinkUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let hover = linkHover else { return }
        let row = hover.row
        let startCol = hover.startCol
        guard row >= 0, row < gridRows, startCol >= 0, startCol < gridCols,
            hover.span > 0
        else { return }
        let span = min(hover.span, gridCols - startCol)
        var color = Theme.Color.linkUnderlineLinear
        color.w = 1.0
        let originPx = SIMD2<Float>(
            gridOriginPx.x + Float(startCol) * cellSizePx.x,
            gridOriginPx.y + Float(row) * cellSizePx.y)
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: cellSizePx,
            colorLinear: color,
            kind: OverlayKind.imeUnderline.rawValue,
            alpha: 1.0,
            cellSpanCols: UInt32(span))
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// SGR underline (`\e[4m`). Walks the cached `cells` array, coalescing
    /// adjacent cells in the same row that carry the UNDERLINE attr bit
    /// (alacritty `Flags::UNDERLINE` = 0x0008) into runs. One overlay
    /// quad per run, tinted with the run's fg color.
    private func encodeTextUnderlineOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        let underlineBit: UInt16 = 0x0008
        guard gridCols > 0, gridRows > 0, cells.count == gridCols * gridRows
        else { return }
        for row in 0..<gridRows {
            var col = 0
            while col < gridCols {
                let idx = row * gridCols + col
                guard (cells[idx].attrs & underlineBit) != 0 else {
                    col += 1
                    continue
                }
                let runStart = col
                let runFg = cells[idx].fgColorLinear
                while col < gridCols
                    && (cells[row * gridCols + col].attrs & underlineBit) != 0
                {
                    col += 1
                }
                let span = col - runStart
                let originPx = SIMD2<Float>(
                    gridOriginPx.x + Float(runStart) * cellSizePx.x,
                    gridOriginPx.y + Float(row) * cellSizePx.y)
                let uniforms = OverlayUniforms(
                    screenSizePx: drawableSizePx,
                    cellOriginPx: originPx,
                    cellSizePx: cellSizePx,
                    colorLinear: runFg,
                    kind: OverlayKind.textUnderline.rawValue,
                    alpha: 1.0,
                    cellSpanCols: UInt32(span))
                overlay.encode(uniforms: uniforms, encoder: encoder)
            }
        }
    }

    /// Scrollbar thumb. Hidden when scrollback is empty (live tail with
    /// no history). Right-edge strip with a thumb whose height is
    /// proportional to (viewport / total) and whose y is proportional
    /// to (scroll_top / scroll_total). scroll_top == 0 means we're at
    /// the live tail, so the thumb sits at the bottom; scroll_top ==
    /// scroll_total means oldest history, thumb at the top.
    private func encodeScrollbarOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        let total = lastScrollTotal
        guard total > 0, gridRows > 0 else { return }
        // V1: don't show the thumb at all until the buffer holds
        // meaningful history — a shell that hasn't yet exceeded one
        // viewport's worth of output doesn't need scrollback chrome.
        guard total >= gridRows else { return }

        let viewportPx = Float(gridRows) * cellSizePx.y
        let viewportRows = Float(gridRows)
        let totalRowsF = Float(total)
        let trackHeightPx = viewportPx
        // Thumb height: proportional to viewport / (viewport + history).
        // Min 24px so the thumb stays grabbable at very deep scrollback.
        let rawThumbH = trackHeightPx * (viewportRows / (viewportRows + totalRowsF))
        let thumbHPx = max(24, rawThumbH)
        // scroll_top is "rows scrolled up into history" — 0 at live
        // tail. Tail-anchored: fraction 1.0 puts the thumb at the
        // bottom of the track; fraction 0.0 at the top.
        let fractionFromTop = 1.0 - Float(lastScrollTop) / totalRowsF
        let thumbYPx = gridOriginPx.y + (trackHeightPx - thumbHPx) * fractionFromTop

        // V1 hover-grow: when the pointer sits within
        // `scrollbarHoverHitWidthPt` of the right edge AND vertically
        // overlaps the thumb, snap to the hover width and full opacity.
        // `hoverPointInView` is in view-points (not pixels); convert
        // by dividing drawableSize.x by `layer.contentsScale` to
        // compare. We approximate via the drawable-points conversion
        // here — for Retina (2×) the math is `drawableSizePx.x / 2`.
        let scale = Float((attachedLayer?.contentsScale) ?? 2.0)
        let viewWidthPt = drawableSizePx.x / scale
        let viewHeightPt = drawableSizePx.y / scale
        var hovering = false
        if let p = hoverPointInView {
            let xFromRight = viewWidthPt - Float(p.x)
            // AppKit y origin is bottom-left; convert to top-down so it
            // lines up with the drawable's pixel coords.
            let yFromTop = viewHeightPt - Float(p.y)
            let thumbYPt = thumbYPx / scale
            let thumbHPt = thumbHPx / scale
            if xFromRight >= 0
                && xFromRight <= Self.scrollbarHoverHitWidthPt
                && yFromTop >= thumbYPt - 4
                && yFromTop <= thumbYPt + thumbHPt + 4
            {
                hovering = true
            }
        }

        let widthPx: Float = hovering
            ? Self.scrollbarHoverWidthPx
            : Self.scrollbarRestingWidthPx

        // V1 fade: solid for `scrollbarHoldSec` post-activity, then
        // linear fade to `scrollbarRestingAlpha` over the next
        // `scrollbarFadeSec`. Hover overrides to full opacity.
        let elapsed = CACurrentMediaTime() - lastScrollActivityTime
        let alpha: Float
        if hovering {
            alpha = 1.0
        } else if elapsed < Self.scrollbarHoldSec {
            alpha = 1.0
        } else {
            let fadeProgress = min(
                1.0,
                Float((elapsed - Self.scrollbarHoldSec) / Self.scrollbarFadeSec))
            alpha = 1.0 - (1.0 - Self.scrollbarRestingAlpha) * fadeProgress
        }

        let originPx = SIMD2<Float>(
            drawableSizePx.x - widthPx,
            thumbYPx)
        let sizePx = SIMD2<Float>(widthPx, thumbHPx)
        var color = Theme.Color.scrollbarThumbLinear
        color.w = 1.0
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: originPx,
            cellSizePx: sizePx,
            colorLinear: color,
            kind: OverlayKind.cursorBlock.rawValue,  // kind=0: solid rect
            alpha: alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    /// I1 bell flash: full-viewport tint quad. Linear fade from
    /// `bellFlashPeakAlpha` to 0 over `bellFlashDurationSec`. No encode
    /// when no flash is in-flight — common path is a no-op.
    private func encodeBellFlashOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let started = bellFlashStartTime else { return }
        let elapsed = CACurrentMediaTime() - started
        guard elapsed < Self.bellFlashDurationSec else { return }
        let progress = Float(elapsed / Self.bellFlashDurationSec)
        let alpha = Self.bellFlashPeakAlpha * (1.0 - progress)
        // Use the theme's primary text color as the flash tint —
        // contrasts with the background on both light and dark themes
        // without needing a dedicated theme token.
        var color = resolvedPalette.defaultFgLinear
        color.w = 1.0
        let uniforms = OverlayUniforms(
            screenSizePx: drawableSizePx,
            cellOriginPx: SIMD2<Float>(0, 0),
            cellSizePx: drawableSizePx,
            colorLinear: color,
            kind: OverlayKind.cursorBlock.rawValue,  // kind=0: solid rect
            alpha: alpha,
            cellSpanCols: 1)
        overlay.encode(uniforms: uniforms, encoder: encoder)
    }

    private static let bellFlashPeakAlpha: Float = 0.25

    /// M7-2 ⌘F: encode one selection-style overlay quad per visible
    /// search match. Active match uses the accent-running color at full
    /// opacity; others use the same color at reduced alpha so the user
    /// can scan all matches without losing the active anchor.
    private func encodeSearchHighlightOverlay(
        encoder: MTLRenderCommandEncoder,
        drawableSizePx: SIMD2<Float>,
        cellSizePx: SIMD2<Float>,
        gridOriginPx: SIMD2<Float>,
        overlay: OverlayPipeline
    ) {
        guard let highlights = searchHighlights else { return }
        for (idx, h) in highlights.spans.enumerated() {
            // Translate alacritty-absolute line → viewport row.
            // viewport spans `[-scrollTop, screen_lines - scrollTop)`.
            let row = h.line + lastScrollTop
            guard row >= 0, row < gridRows,
                h.startCol >= 0, h.startCol < gridCols,
                h.span > 0
            else { continue }
            let span = min(h.span, gridCols - h.startCol)
            let isActive = (idx == highlights.activeIndex)
            var color = Theme.Color.accentRunningLinear
            color.w = isActive ? 0.55 : 0.25
            let originPx = SIMD2<Float>(
                gridOriginPx.x + Float(h.startCol) * cellSizePx.x,
                gridOriginPx.y + Float(row) * cellSizePx.y)
            let uniforms = OverlayUniforms(
                screenSizePx: drawableSizePx,
                cellOriginPx: originPx,
                cellSizePx: cellSizePx,
                colorLinear: color,
                kind: OverlayKind.selection.rawValue,
                alpha: 1.0,
                cellSpanCols: UInt32(span))
            overlay.encode(uniforms: uniforms, encoder: encoder)
        }
    }

    /// Pin the `CURSOR_SHAPE_*` u8 → `OverlayKind` mapping. Static so
    /// `OverlayPipelineTests` can drive it without instantiating a
    /// renderer.
    static func cursorKind(forShape shape: UInt8) -> OverlayKind {
        switch shape {
        case 0: return .cursorBlock  // CURSOR_SHAPE_BLOCK
        case 1: return .cursorBeam  // CURSOR_SHAPE_BEAM
        case 2: return .cursorUnderline  // CURSOR_SHAPE_UNDERLINE
        default: return .cursorBlock  // unknown shape → safe default
        }
    }

    /// Decode the first `Unicode.Scalar` from a UTF-8 grapheme buffer.
    /// `cell.grapheme` is fixed-size 8 bytes, null-padded; we trim
    /// trailing zeros and run String's UTF-8 decoder. Returns nil on
    /// all-zero or malformed input — caller renders bg-only.
    static func firstScalar(in grapheme: [UInt8]) -> Unicode.Scalar? {
        // Find the first null terminator; everything after is padding.
        var end = grapheme.count
        for (i, byte) in grapheme.enumerated() where byte == 0 {
            end = i
            break
        }
        guard end > 0 else { return nil }
        // Decode the prefix as UTF-8. Single multi-byte scalars (BMP +
        // astrals) decode here in one step; clusters return their first
        // scalar and the atlas handles the BMP-only path.
        let bytes = grapheme.prefix(end)
        if let s = String(bytes: bytes, encoding: .utf8), let first = s.unicodeScalars.first {
            return first
        }
        return nil
    }

    /// Per-scalar de-duplication for atlas-miss logs. Bounded so an
    /// adversarial stream can't grow this unboundedly; once we hit the
    /// cap we stop adding (further misses for new scalars go silently).
    /// 4.2 (atlas LRU) and 4.3 (font fallback) retire most of this.
    private var loggedMissingScalars: Set<UInt32> = []
    private static let loggedMissingCap = 256

    private func logMissingGlyphOnce(scalar: Unicode.Scalar, error: Error) {
        guard loggedMissingScalars.count < Self.loggedMissingCap else { return }
        if loggedMissingScalars.insert(scalar.value).inserted {
            NSLog(
                "MetalRenderer.makeSlot: atlas miss for U+%04X (%@) — %@",
                scalar.value, String(scalar), String(describing: error))
        }
    }

    /// Single per-keystroke latency sample. Routes through
    /// `LatencyMeter`, which logs the percentile summary once
    /// `targetSampleCount` (default 1000) is reached.
    private func didMeasureKeystrokeLatency(ms: Double) {
        latencyMeter.record(ms)
    }

    private func recordFrameTime(_ ms: Double) {
        frameTimes.append(ms)
        frameCount &+= 1
        if frameTimes.count >= Self.frameTimeWindow {
            let sorted = frameTimes.sorted()
            let p50 = sorted[sorted.count / 2]
            let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            // NSLog so the message routes through `os_log` and shows up
            // in `log stream --predicate process == SolidTerm`. Plain
            // `print` goes to stdout which `open -a` doesn't capture.
            NSLog(
                "MetalRenderer cpu encode/frame (n=%d): avg=%.3f ms, p50=%.3f ms, p99=%.3f ms",
                sorted.count, avg, p50, p99)
            frameTimes.removeAll(keepingCapacity: true)
        }
    }

    /// Default `TerminalSession` for Phase 0. Hardcoded shell + minimal
    /// env; `pixel_w` / `pixel_h` are zero placeholders. The Week 1 PTY
    /// spawn task will compute pixel dimensions from atlas cell size ×
    /// grid, plumb `$SHELL`, and inherit the launching environment.
    /// Optional cwd override for the next session spawned by
    /// `makeDefaultSession`. Set by the new-window / new-tab entry
    /// points so a fresh window inherits the active pane's working
    /// directory. Consumed once on session construction and cleared.
    var pendingInitialCwd: String?

    /// Returns `nil` if the Rust engine fails to spawn the PTY (openpty
    /// / FD exhaustion / bad geometry). The Rust side logs the cause; the
    /// caller stores the result in the optional `session`, which every
    /// consumer already guards, so a failed spawn degrades to an inert
    /// surface instead of crashing the app.
    private static func makeDefaultSession(
        rows: Int, cols: Int, cwd: String? = nil
    ) -> TerminalSession? {
        // COLORTERM=truecolor advertises 24-bit SGR support to apps that
        // check the terminfo cap (Claude Code, vim, tmux). Without it,
        // many TUIs fall back to 256-color quantization — Claude Code's
        // salmon logo gets snapped to xterm Red (#cd0000) instead of the
        // intended ~#e69191. Engine already decodes Color::Spec at
        // 24-bit per `cells.rs:204`; this just tells consumers that's
        // safe to emit.
        let envPayload =
            "TERM=xterm-256color\nCOLORTERM=truecolor\nLANG=en_US.UTF-8\n"
        let envVec = RustVec<UInt8>()
        for byte in envPayload.utf8 { envVec.push(value: byte) }

        // Q2 configurable scrollback. UserDefaults key `solidterm.scrollback`
        // overrides the engine default; 0 (default) defers to
        // `DEFAULT_SCROLLBACK_LINES`. Range gating happens engine-side
        // (`MAX_SCROLLBACK_LINES`), so any user-injected garbage gets
        // rejected at session construction rather than silently
        // accepted.
        let scrollback = UserDefaults.standard.integer(
            forKey: ScrollbackSettings.userDefaultsKey)
        let scrollbackLines = scrollback > 0
            ? UInt32(clamping: scrollback)
            : 0
        let config = SessionConfig(
            rows: UInt16(rows),
            cols: UInt16(cols),
            pixel_w: 0,
            pixel_h: 0,
            command: "/bin/zsh".intoRustString(),
            cwd: (cwd ?? NSHomeDirectory()).intoRustString(),
            env: envVec,
            scrollback_lines: scrollbackLines
        )
        return TerminalSession.new(config)
    }

    /// Initial empty `cols`×`rows` grid. Every slot is a glyph-less
    /// `CellSlot` with the theme background and primary-foreground
    /// linear-space colors (`Theme.Color.bgBaseLinear` /
    /// `textPrimaryLinear`). The engine's first `FrameDelta` after PTY
    /// spawn overwrites the cells the shell painted; cells the shell
    /// never touches stay blank — matching the visual contract from
    /// `spec/ui-chrome-visual.md` §Window ("grid extends to all four
    /// edges visually" with `bg-base` background).
    ///
    /// Replaces the Phase 0 `makeRandomGrid` spike fill that painted
    /// every cell with a random A-Z / 0-9 glyph in white. The
    /// keystroke-driven cell-(0,0) mutation in `recordKeystroke` is
    /// preserved (it's the latency harness's load-bearing visible
    /// state-change per keystroke).
    ///
    /// Keeps `cells` populated with sensible slots so the IME
    /// composition restore path (`restoredSlot`) reads valid bg/fg
    /// when erasing preedit underlines on commit / unmark.
    private static func makeBlankGrid(
        cols: Int, rows: Int,
        palette: Theme.Palette = Theme.Color.defaultPalette
    ) -> [CellSlot] {
        // Resolve fg/bg through the supplied palette so a theme-switch
        // re-blank lands the user on the active theme's colors, not the
        // compile-time dark constants. The default arg keeps existing
        // call sites (init, resize) on the dark palette — those run
        // before the theme observer fires.
        let blank = CellSlot(
            glyph: nil,
            fgColorLinear: palette.defaultFgLinear,
            bgColorLinear: palette.defaultBgLinear)
        return Array(repeating: blank, count: cols * rows)
    }

    // MARK: - Keystroke → state mutation
    //
    // Per spec/m1-task-breakdown §3.10, the typing-to-pixel measurement
    // requires a visible state change per keystroke (rule 8). The
    // smallest viable change: cycle cell (0, 0)'s glyph through the
    // atlas's pre-rasterized A-Z + 0-9 set. The keystroke timestamp
    // (`NSEvent.timestamp`, mach-time-derived) is queued for the next
    // frame's completion handler, where `drawable.presentedTime` (also
    // mach-time-derived) closes the latency loop.

    /// Called from `TerminalSurfaceView.keyDown`. The renderer doesn't
    /// care which key was pressed — every keystroke mutates the same
    /// cell, advancing through the atlas. The `eventTimestamp` is
    /// `NSEvent.timestamp` and is consumed by the next frame.
    func recordKeystroke(eventTimestamp: CFTimeInterval) {
        // P1: every keystroke is a redraw — the shell echo will land
        // on a later frame, but the user's expectation is "next frame
        // moves". Even without a visible cell change, a keystroke
        // produces a latency-meter sample that closes over the
        // command-buffer completion handler, and idle-skip would
        // otherwise drop that handler entirely.
        pendingRedraw = true
        // V2 pause-on-type: stamp the most recent keystroke so the
        // cursor encode path holds solid for the next ~500 ms.
        lastKeystrokeTime = CACurrentMediaTime()

        // Task #36 diagnostic: log the entry condition + the early-
        // return path. The atlas-nil / cells-empty silent skip is one
        // candidate for the harness corruption symptom (1000 keystrokes
        // fire, 0 samples land) — if windowChanged hasn't completed
        // its atlas init, every keystroke is a no-op. Diagnostics let
        // a future repro distinguish "renderer state not ready" from
        // "completion handler never fires."
        if latencyMeter.diagnosticsEnabled {
            NSLog(
                "MetalRenderer.recordKeystroke t=%.6f eventTs=%.6f "
                    + "atlas=%@ cells=%d pendingTimes=%d",
                CACurrentMediaTime(), eventTimestamp,
                atlas == nil ? "nil" : "ok",
                cells.count, pendingKeystrokeTimes.count)
        }

        // Production: this is a no-op. The cell-(0,0) glyph cycle was
        // Phase 0 spike instrumentation for the latency harness's
        // "guaranteed visible state change per keystroke" invariant
        // (per `feedback_meaningful_latency_measurement`). With the
        // M1 PTY path live, the shell's own echo provides the visible
        // state change; mutating cell (0,0) here pollutes the user's
        // top-left corner on every keystroke.
        //
        // Gate behind `latencyMeter.harnessActive` so
        // `LatencyMeasurementTests` (which flips the flag in setUp)
        // still gets the harness behavior, but interactive use stays
        // clean.
        guard latencyMeter.harnessActive else { return }
        guard let atlas, !cells.isEmpty else { return }
        keystrokeIndex &+= 1
        let pick = keystrokeIndex % Self.randomGlyphs.count
        if let entry = try? atlas.entry(
            for: Self.randomGlyphs[pick], commandQueue: commandQueue)
        {
            let slot = CellSlot(
                glyph: entry,
                fgColorLinear: cells[0].fgColorLinear,
                bgColorLinear: cells[0].bgColorLinear)
            cells[0] = slot
            pendingCellWrites.append((index: 0, slot: slot))
            pendingKeystrokeTimes.append(eventTimestamp)
        }
    }
}

/// Bridges `CAMetalDisplayLinkDelegate` (Obj-C protocol, must be a class)
/// into a Swift closure. Keeps the renderer free to be a `final class`
/// without inheriting from NSObject.
private final class MetalDisplayLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    private let onUpdate: (CAMetalDisplayLink.Update) -> Void

    init(onUpdate: @escaping (CAMetalDisplayLink.Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update)
    {
        onUpdate(update)
    }
}
