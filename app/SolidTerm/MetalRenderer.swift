// Frame pacing and the Stage 1 full-screen cell pass.
// Per-frame work: clear the drawable to the
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
//
// The renderer is split by method cluster across sibling files: the font
// and theme-colour plumbing in MetalRenderer+Font.swift, the title / cwd
// drains in +TitleCwd.swift, the frame-delta application and the cell-slot
// builders in +FrameDelta.swift, the eight overlay encoders and the
// composition painting in +Overlays.swift. What stays here: the class
// declaration, every property, init / deinit, attach, `windowChanged`,
// `resizeGrid`, the display link + idle pump, `draw`, the latency
// bookkeeping and the session / blank-grid factories.

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
    var attachedPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

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
    static let randomGlyphs: [Unicode.Scalar] = {
        let upper = (0..<26).compactMap { Unicode.Scalar(0x41 + $0) }
        let digits = (0..<10).compactMap { Unicode.Scalar(0x30 + $0) }
        return upper + digits
    }()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Reserved for the Stage-0 single-cell overlay path (cursor, IME
    /// underline, selection accents) at task 4.7 / 4.9. Not used by the
    /// current grid renderer; kept so adding the overlay pass doesn't
    /// require re-introducing the pipeline state.
    private let cellPipeline: CellPipeline
    var gridPipeline: GridPipeline?
    /// Stage-2 overlay pipeline for cursor (4.7), selection (4.5), and
    /// IME marked-text underline (4.9). Constructed lazily once the
    /// device + pixel format are known; the pipeline shape is
    /// kind-discriminated — one shader whose `kind` uniform selects
    /// the overlay geometry.
    private var overlayPipeline: OverlayPipeline?

    weak var attachedLayer: CAMetalLayer?
    private var displayLink: CAMetalDisplayLink?

    /// The renderer's clock. Every timestamp the renderer stamps into
    /// its own state and every elapsed-time comparison it makes against
    /// one reads this, so the durations that drive the idle-pump
    /// watchdog, the bell flash, the scrollbar fade and the blink phase
    /// are all on one substitutable source. Production leaves it at
    /// `CACurrentMediaTime`; only tests reassign it, which is how
    /// `IdlePumpTests` reaches a stalled link without a display sleep.
    /// The two diagnostic `NSLog` timestamps that sit next to
    /// `NSEvent.timestamp` / `MTLDrawable.presentedTime` deliberately
    /// stay on `CACurrentMediaTime()` — they are only comparable to
    /// those values on the same mach clock.
    var now: () -> CFTimeInterval = CACurrentMediaTime

    /// `now()` of the last `draw(update:)` tick. Read by
    /// `pumpIfDisplayLinkStalled()` to tell a stopped display link
    /// (display asleep, window fully occluded) from a healthy one.
    var lastDisplayLinkTick: CFTimeInterval = 0
    /// Watchdog that keeps the engine draining while the display link
    /// is stopped. See `startIdlePump()`.
    private var idlePumpTimer: DispatchSourceTimer?
    /// App Nap opt-out, held for as long as the watchdog is armed so
    /// the OS can't throttle the pump's timer while the window is
    /// occluded — the exact condition the pump exists to survive.
    private var idlePumpActivity: NSObjectProtocol?
    /// Set when the idle pump discarded a frame delta; consumed by
    /// `draw(update:)`, which then repaints from a full-frame delta so
    /// the discarded cells reappear.
    private(set) var pendingFullRepaint = false

    var atlas: GlyphAtlas?

    /// M7-3: NotificationCenter observer for `FontSettings.didChange`.
    /// Owned so the observer can be removed in `windowChanged` when
    /// re-installing for a new window. Strong-ref because the
    /// notification token holds the closure; the renderer outlives
    /// the observer lifetime by tying to `windowChanged` teardown.
    var fontObserver: NSObjectProtocol?

    /// M7-3: set whenever the atlas needs a fresh build because the
    /// font family or size changed. Read by `draw(update:)`'s prologue
    /// (consumed and cleared) so the rebuild lands on a frame boundary
    /// rather than mid-encode. Test seam: tests assert this transitions
    /// to `true` on `FontSettings.didChange`.
    var atlasDirty: Bool = false

    /// Per-window font-size override. `nil` means "follow the global
    /// `FontSettings.shared.size`" — that's the default for new windows.
    /// Set via `bumpFontSize()` / `dropFontSize()` / `resetFontSize()`
    /// when the user runs ⌘+/⌘-/⌘0 inside this window. Once set, the
    /// global Settings → Appearance picker no longer affects this
    /// window's size (family changes still apply). Reset by
    /// `resetFontSize()` (returns the window to global default).
    var fontSizeOverride: CGFloat?

    /// Resolved font size for this renderer — the override if set,
    /// otherwise the global default. Read by `makeEffectiveFont()`
    /// and `reloadFont()` instead of going straight to
    /// `FontSettings.shared.size`.
    @MainActor
    var effectiveFontSize: CGFloat {
        fontSizeOverride ?? FontSettings.shared.size
    }

    /// Last-seen cursor state from the engine. Updated each frame
    /// inside `applyFrameDelta` so `draw(update:)` can encode the
    /// overlay quad after the grid pass without re-reading the
    /// `FrameDelta`. `nil` while the session hasn't produced a frame
    /// yet (Phase 1 stub returns a default `CursorState` regardless,
    /// but this guards future producers that gate cursor visibility).
    var lastCursor: CursorState?

    /// 4.9: weak handle to the host `TerminalSurfaceView` so the
    /// composition pass can read `activeComposition` each frame. Weak
    /// — the controller owns both objects; avoiding the retain cycle
    /// is cheap insurance. Set via `attachHostView(_:)` from the view's
    /// `init` after `attach(layer:)`.
    weak var hostView: TerminalSurfaceView?

    /// 4.9: cells we painted as preedit on the most recent frame.
    /// When composition clears (commit / unmark), the underlying real
    /// cells need to repaint — but the engine doesn't mark them dirty
    /// (we never sent input through the FFI). We track per-cell
    /// indices here and force a `setRegion` repaint of those cells
    /// from the cached `cells` shadow array on the first post-clear
    /// frame. Empty when no composition is active.
    var preeditPaintedCells: [(row: Int, col: Int)] = []
    /// 4.9: set when `invalidateCompositionRender` fires. Read by the
    /// next `draw(update:)` to ensure preedit cells get repainted from
    /// the underlying state.
    var compositionInvalidated: Bool = false

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
    var blinkOriginTime: CFTimeInterval?
    static let blinkPeriodSec: CFTimeInterval = 0.9

    /// V2 pause-on-type: timestamp of the most recent keystroke. While
    /// `now - lastKeystrokeTime < blinkPauseAfterKeystrokeSec` the
    /// cursor holds solid at alpha=1.0 (no fade) so the user sees a
    /// stable insertion point during active typing.
    var lastKeystrokeTime: CFTimeInterval = 0
    static let blinkPauseAfterKeystrokeSec: CFTimeInterval = 0.5
    /// UX6: tracks the previous frame's `typingActive` so the cursor
    /// encode can detect the typing → idle transition and re-anchor
    /// `blinkOriginTime` once at the boundary instead of every frame
    /// during typing.
    var wasTypingLastFrame: Bool = false

    /// V1 scrollbar fade: timestamp of the last `scroll_top` /
    /// `scroll_total` change observed in `applyFrameDelta`. The thumb
    /// is fully opaque for the first `scrollbarHoldSec`, then fades to
    /// the resting alpha over the next `scrollbarFadeSec`.
    var lastScrollActivityTime: CFTimeInterval = 0
    static let scrollbarHoldSec: CFTimeInterval = 0.8
    static let scrollbarFadeSec: CFTimeInterval = 0.8
    static let scrollbarRestingAlpha: Float = 0.25
    // UX4: bump 6→8pt resting and 9→12pt hover so the visual target
    // matches the 16pt hit zone. Matches macOS-style "overlay
    // scroller" proportions (Safari/Finder use 9pt → 15pt; we sit
    // between that and the original Alacritty-style hairline).
    static let scrollbarHoverWidthPx: Float = 12.0
    static let scrollbarRestingWidthPx: Float = 8.0
    static let scrollbarHoverHitWidthPt: Float = 16.0

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
    var pendingRedraw: Bool = true

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
    /// `now()` when one is fading. The encode path fades
    /// from 0.25 alpha to 0 over `bellFlashDurationSec` and clears the
    /// timestamp once `elapsed > duration`.
    var bellFlashStartTime: CFTimeInterval?
    static let bellFlashDurationSec: CFTimeInterval = 0.15

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

    /// Test seam — production only ever assigns `session` from
    /// `windowChanged(window:)`, which needs a live `CAMetalLayer`.
    /// `IdlePumpTests` drives `pumpIfDisplayLinkStalled()` on a
    /// renderer-without-window and needs that guard to both pass and
    /// fail, so hand it the one assignment it needs instead of opening
    /// the setter to every caller in the module.
    func attachSessionForTesting(_ session: TerminalSession) {
        self.session = session
    }

    /// The host `NSWindow` the renderer is currently presenting into.
    /// Captured in `windowChanged(window:)` so the per-frame title
    /// poll (`drain_latest_title`) can update `window.title` without
    /// re-walking the responder chain. `weak` — the window outlives
    /// the renderer in practice (the controller owns both), but
    /// avoiding a retain cycle is cheap insurance.
    /// Posted (object = host `NSWindow`) when this renderer's pane cwd
    /// changes, so `TerminalWindowController` can `invalidateRestorableState`
    /// and re-capture the working directory for window restoration.
    static let cwdDidChange = Notification.Name("com.zenzai.SolidTerm.cwdDidChange")

    weak var hostWindow: NSWindow?

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
    var lastScrollTop: Int = 0

    /// Latest `scroll_total` from the engine (rows in scrollback). Cached
    /// alongside `lastScrollTop` so the scrollbar overlay encode can
    /// compute the thumb position without re-pulling the frame delta.
    var lastScrollTotal: Int = 0

    /// Mutable per-cell state. The renderer keeps the array so the
    /// keystroke handler can read the previous slot before producing
    /// a new one (and so a future "redraw whole grid" path can call
    /// `setGrid` without rebuilding). Per-keystroke mutations
    /// enqueue (index, slot) pairs onto `pendingCellWrites`; the next
    /// frame applies them via `GridPipeline.setCell` for one-cell
    /// texture updates instead of full-grid rewrites.
    var cells: [CellSlot] = []
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

    /// One-frame-in-flight fence for the grid cell textures (`.shared`
    /// storage, mutated by CPU `replace(region:)`). Hold the slot whenever
    /// mutating the LIVE pipeline's textures or while a committed frame's
    /// GPU reads are outstanding; every committed command buffer signals
    /// from its completion handler. Fresh-pipeline `setGrid` paths
    /// (reloadFont/windowChanged/resizeGrid) need no slot — their textures
    /// have never been submitted, and in-flight buffers retain the old set.
    let frameSlot = DispatchSemaphore(value: 1)

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

    /// ADR-0003 feature gate. When ON, the
    /// FrameDelta path routes `[CellDeltaSwift]` through
    /// `GraphemeClusterCoalescer.coalesce` before slot resolution so
    /// cross-cell grapheme clusters (Thai SARA AM, regional indicator
    /// flag pairs, ZWJ family spillovers) render as one wide glyph.
    /// Default ON since v0.1.7 (ADR-0003 — manual verification
    /// of `ทำ`, `ห้`, `ก่อ`, `กืน` 2026-05-16). Setting
    /// `SOLIDTERM_SHAPING=0` disables the coalescer and restores the
    /// v0.1.6 single-cell path for diagnosis.
    let useShaping: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["SOLIDTERM_SHAPING"] != "0"
    }()

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
        // see same dark pixels until M6-4b lands the light tokens;
        // the wiring lands now so the activation diff is
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
        stopIdlePump()
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

    /// Test seam — read-only view of the per-window override.
    var fontSizeOverrideForTesting: CGFloat? { fontSizeOverride }

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
        stopIdlePump()
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
            // No frameSlot needed: fresh pipeline — textures are new and unsubmitted; in-flight buffers retain the old set.
            try pipeline.setGrid(
                self.cells, atlasSize: GlyphAtlas.atlasSize,
                colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
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
        startIdlePump()

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
            // No frameSlot needed: fresh pipeline — textures have never been submitted; in-flight buffers continue sampling the old pipeline's set.
            try newPipeline.setGrid(
                cells, atlasSize: GlyphAtlas.atlasSize,
                colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
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

    /// M6-2: latest OSC-7 cwd, polled once per frame off
    /// `drain_latest_cwd`. Read by `TerminalSurfaceView` for relative-
    /// path resolution in the file-path detector. Empty when the shell
    /// hasn't emitted OSC 7 yet (e.g. a fresh login shell with no
    /// chpwd hook configured).
    var lastCwd: String = ""

    var lastCwdProcPollTime: CFTimeInterval = 0

    /// V3: the OSC title currently owning the title bar, or nil when
    /// the cwd-basename fallback has it. Set by any non-empty OSC 0/2,
    /// cleared by a title reset or by the child leaving the alternate
    /// screen — see `applyLatestTitleIfAny` for why it is sticky rather
    /// than time-limited.
    var stickyOscTitle: String?

    /// Alt-screen state as of the last title tick, so the *transition*
    /// out (TUI quit) can hand the title back. Alt-screen entry is not
    /// a signal: plenty of TUIs title themselves after switching.
    var lastAltScreenForTitle = false

    // The delegate is held strongly by the renderer; the link only retains
    // it weakly so we keep a strong ref here.
    private lazy var displayLinkDelegate = MetalDisplayLinkProxy { [weak self] update in
        self?.draw(update: update)
    }

    /// A live `CAMetalDisplayLink` ticks at >= 30 Hz (the `minimum` of
    /// the `preferredFrameRateRange` set in `windowChanged`), so a gap
    /// this wide means the link stopped rather than merely ran slow.
    static let displayLinkStallThresholdSec: CFTimeInterval = 0.5

    /// Watchdog poll interval. Cheap: one main-queue wakeup that
    /// returns immediately while the link is healthy.
    private static let idlePumpIntervalMs = 250

    /// True when `now` is far enough past the last display-link tick
    /// that the link must be treated as stopped. `lastTick == 0` (no
    /// tick yet) counts as stalled, so the pump also covers the window
    /// between session spawn and the first frame.
    static func displayLinkStalled(
        now: CFTimeInterval, lastTick: CFTimeInterval
    ) -> Bool {
        now - lastTick > displayLinkStallThresholdSec
    }

    /// Keep the engine draining while the display link is stopped.
    ///
    /// macOS stops `CAMetalDisplayLink` whenever the display sleeps or
    /// the window is fully occluded. `poll_output` — the sole drain of
    /// the PTY reader channel — is reached only through
    /// `take_frame_delta`, which only `draw(update:)` calls, so a
    /// stopped link means nothing drains: the bounded reader channel
    /// (`pty.rs: PTY_CHANNEL_CAP = 512` chunks) fills, the reader
    /// thread parks in `send`, the PTY master buffer backs up, and the
    /// child blocks in `write()`. Everything running in the pane
    /// freezes until the display returns — observed as a 7.6 h stall
    /// of a long-running CLI across an overnight display sleep.
    @MainActor
    private func startIdlePump() {
        stopIdlePump()
        // App Nap throttles the timers of occluded apps, which would
        // blunt this watchdog exactly when it is needed.
        // `userInitiated` opts out of that; the
        // `AllowingIdleSystemSleep` variant deliberately leaves the
        // *system* free to sleep, since keeping the Mac awake is the
        // user's call (caffeinate / Energy Saver), not the terminal's.
        idlePumpActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "drain PTY output while the display link is stopped")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = .milliseconds(
            Self.idlePumpIntervalMs)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            // The source is bound to the main queue, so the handler is
            // already main-isolated; `assumeIsolated` documents that
            // without bubbling @MainActor into DispatchSource.
            MainActor.assumeIsolated {
                self?.pumpIfDisplayLinkStalled()
            }
        }
        timer.resume()
        idlePumpTimer = timer
    }

    /// Disarm the watchdog and release its App Nap opt-out. Callable
    /// from the non-isolated `deinit`: both calls are thread-safe.
    private func stopIdlePump() {
        idlePumpTimer?.cancel()
        idlePumpTimer = nil
        if let activity = idlePumpActivity {
            ProcessInfo.processInfo.endActivity(activity)
            idlePumpActivity = nil
        }
    }

    @MainActor
    func pumpIfDisplayLinkStalled() {
        guard let session,
            Self.displayLinkStalled(
                now: now(), lastTick: lastDisplayLinkTick)
        else { return }
        // Called for the side effect only: `take_frame_delta` runs
        // `poll_output`, which drains the reader channel and writes
        // capability-query replies back to the child. The delta is
        // discarded — there is no drawable to paint while the link is
        // down — so flag a full repaint for the next live tick. Same
        // shape as the no-pipeline pump inside `draw(update:)`.
        _ = session.take_frame_delta()
        pendingFullRepaint = true
    }

    private func draw(update: CAMetalDisplayLink.Update) {
        lastDisplayLinkTick = now()
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
        // Window restoration: a cwd change (OSC 7 or the proc fallback,
        // including the first one after spawn) invalidates the window's
        // saved state so a relaunch respawns the shell in the new dir.
        if cwdChanged, let window = hostWindow {
            NotificationCenter.default.post(name: Self.cwdDidChange, object: window)
        }

        // I1 bell flash: poll the engine for any bell events that
        // landed since the last tick. Latched in the FFI's
        // `drain_bell` (which collapses rapid-fire bells to one flash
        // — matches iTerm2). Setting the start time here ensures the
        // dirty-frame gate below treats the flash as a redraw reason.
        if let session, session.drain_bell() {
            bellFlashStartTime = now()
        }

        // OSC 52 clipboard write: when the child (e.g. Claude Code copying
        // an in-TUI selection) requests `\e]52;c;<base64>`, the engine
        // decodes it and latches the text here; push it to the system
        // pasteboard. Write direction only — alacritty denies OSC 52
        // read-back by default, so this can't exfiltrate the clipboard.
        if let session {
            let osc52 = session.drain_clipboard_store().toString()
            if !osc52.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(osc52, forType: .string)
            }
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
        let compositionActive =
            (hostView?.activeComposition != nil)
            || !preeditPaintedCells.isEmpty

        // Apply engine-driven cell writes + keystroke-spike + composition
        // to the pipeline textures. These call `MTLTexture.replace`
        // which is synchronous CPU→GPU upload and doesn't need an
        // encoder, so it's safe to run before the encode-skip decision.

        // Acquire the frame slot before the first cell-texture mutation.
        // This must precede the mutation block (the encode-skip decision
        // is COMPUTED from it, so it can't move later), and it blocks only
        // until the previous frame's GPU reads complete — sub-ms for a
        // terminal grid. Every exit path below either falls into the
        // defer (no GPU work submitted) or hands the slot to the command
        // buffer's completion handler (`slotTransferredToGPU`).
        frameSlot.wait()
        var slotTransferredToGPU = false
        defer { if !slotTransferredToGPU { frameSlot.signal() } }

        var frameHadCells = false
        if let atlas, let pipeline = gridPipeline {
            // Atlas-eviction repaint: if any LRU eviction or full reset
            // happened since the last frame, every cell's cached UV may
            // now point at a different glyph. Pull a full-frame delta
            // (re-emits every viewport row through the engine) so each
            // cell re-runs `makeSlot` and re-pins its glyph at the
            // post-eviction UV. Without this, the user sees garbled
            // text (typically Thai/CJK) until scroll forces a redraw.
            // Both flags are consumed every frame — folding them into
            // one `||` condition would short-circuit the second
            // consumer and strand its flag. `pendingFullRepaint` is
            // set by the idle pump, whose deltas were discarded while
            // the display link was stopped; the same full-frame
            // re-emit that fixes eviction restores those cells.
            let atlasEvicted = atlas.consumePendingEviction()
            let resumedFromIdlePump = pendingFullRepaint
            pendingFullRepaint = false
            if atlasEvicted || resumedFromIdlePump,
                let session = session
            {
                let frame = session.take_full_frame_delta()
                self.lastCursor = frame.cursor
                if let decoded = try? FrameDeltaDecoding.decodeCells(frame.cells) {
                    if useShaping {
                        let coalesced = GraphemeClusterCoalescer.coalesce(decoded)
                        Self.applyCoalescedCellsAsRegions(
                            coalesced, pipeline: pipeline, atlas: atlas,
                            shadow: &self.cells, gridCols: gridCols,
                            makeSlot: { [weak self] cell in
                                self?.makeSlot(from: cell, atlas: atlas)
                            })
                    } else {
                        Self.applyCellsAsRegions(
                            decoded, pipeline: pipeline, atlas: atlas,
                            shadow: &self.cells, gridCols: gridCols,
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
                    at: index, slot: slot, atlasSize: GlyphAtlas.atlasSize,
                    colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
            }
            pendingCellWrites.removeAll(keepingCapacity: true)
            applyCompositionStateIfNeeded(pipeline: pipeline, atlas: atlas)
        } else if let session {
            // No render pipeline (grid init failed in windowChanged, or
            // not yet built): still pump the engine each tick so PTY
            // output is parsed and capability-query replies (DA1/DA2,
            // DSR cursor position, kitty CSI?u) get written back to the
            // child. poll_output — the sole drain of the reply queue —
            // is otherwise reached ONLY through the pipeline-gated frame
            // path above, so without this a TUI that blocks on its
            // startup DA round-trip (Claude Code does) would hang forever
            // behind a blank window. The frame delta is discarded; there
            // is nothing to draw, but take_frame_delta runs poll_output.
            _ = session.take_frame_delta()
        }

        let cursorChanged = !Self.cursorEqual(lastCursor, lastEncodedCursor)
        // A blinking, visible cursor is animation work — we must encode
        // every tick during blink (the eased curve from V2 will smooth
        // this, but the simple binary fallback already requires it).
        let blinkAnimating =
            (lastCursor?.blink ?? false)
            && !(lastCursor?.hidden ?? true)

        let pendingKeystrokeFrame = !pendingKeystrokeTimes.isEmpty

        // V1 scrollbar fade: redraw is needed while the fade is in
        // progress (between hold-end and resting). Past the fade end,
        // the thumb sits at resting alpha and doesn't change again
        // until the next scroll.
        let scrollbarFadeActive: Bool = {
            guard lastScrollActivityTime > 0 else { return false }
            let elapsed = self.now() - lastScrollActivityTime
            return elapsed
                < Self.scrollbarHoldSec + Self.scrollbarFadeSec
        }()

        let bellFlashing: Bool = {
            guard let started = bellFlashStartTime else { return false }
            let elapsed = self.now() - started
            if elapsed >= Self.bellFlashDurationSec {
                bellFlashStartTime = nil
                // One last frame to clear the flash overlay.
                return true
            }
            return true
        }()

        let needsEncode =
            !hasPresented
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

        let cpuStart = now()

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
            let gutterPx = Float(Theme.Gutter.widthPt) * Float(layer.contentsScale)
            let gridOriginPx = SIMD2<Float>(gutterPx, 0)

            // Cursor visibility fix: resolve the block-cursor reverse-video
            // state ONCE here, before the grid encode, because the helper
            // advances per-frame blink bookkeeping (`blinkOriginTime`,
            // `wasTypingLastFrame`) and must run exactly once per tick. The
            // grid pass consumes it to reverse-video the cursor cell (so the
            // glyph stays readable); `encodeCursorOverlay` reuses the same
            // alpha for the beam / underline shapes, which still draw as
            // overlay quads. A nil result means "no block cursor this frame"
            // (hidden, scrolled into history, off-screen, blink-off, or a
            // beam / underline shape).
            let cursorBlock = computeCursorBlockState()

            var uniforms = GridUniforms(
                screenSizePx: drawableSizePx,
                cellSizePx: cellPx,
                atlasSizePx: SIMD2(
                    Float(GlyphAtlas.atlasSize.x), Float(GlyphAtlas.atlasSize.y)),
                gridSizeCells: SIMD2(UInt32(gridCols), UInt32(gridRows)),
                gridOriginPx: gridOriginPx,
                colorAtlasSizePx: SIMD2(
                    Float(atlas.colorAtlasSize.x),
                    Float(atlas.colorAtlasSize.y)))
            if let block = cursorBlock, block.kind == .cursorBlock {
                // Only the BLOCK shape reverse-videos in the grid pass.
                uniforms.cursorCell = SIMD2(UInt32(block.col), UInt32(block.row))
                uniforms.cursorColorLinear = block.color
                uniforms.cursorBlockAlpha = block.alpha
                uniforms.cursorBlockActive = 1
            }
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
                    state: cursorBlock,
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
        // Return the frame slot when the GPU finishes this frame —
        // including `.error` completions (GPU fault/device loss), so a
        // committed frame can never strand the slot. Registered FIRST so
        // it runs before the latency handler (FIFO), and capturing the
        // semaphore itself (never `self`) so the signal survives renderer
        // deinit with a frame still in flight.
        commandBuffer.addCompletedHandler { [frameSlot] _ in frameSlot.signal() }
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
        slotTransferredToGPU = true
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

        let cpuEnd = now()
        recordFrameTime((cpuEnd - cpuStart) * 1_000.0)  // ms
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
    /// Cached resolved palette — refreshed on `themeDidChange` and on
    /// renderer init. Read on the same thread that drives drawing,
    /// avoiding the MainActor hop in the per-cell hot loop. The
    /// `themeDidChange` observer below mutates this on the main runloop.
    var resolvedPalette: Theme.Palette = Theme.Color.defaultPalette

    /// Active cursor color (file-backed theme wins over the static
    /// `Theme.Color.cursorDefaultLinear`). Refreshed by
    /// `refreshClearColor`.
    var resolvedCursor: SIMD4<Float> = Theme.Color.cursorDefaultLinear

    /// Active selection-bg color. File-backed theme wins.
    var resolvedSelection: SIMD4<Float> = Theme.Color.selectionBgLinear

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
    var ansiOverride: [UInt32: SIMD4<Float>] = [:]

    /// Per-scalar de-duplication for atlas-miss logs. Bounded so an
    /// adversarial stream can't grow this unboundedly; once we hit the
    /// cap we stop adding (further misses for new scalars go silently).
    /// 4.2 (atlas LRU) and 4.3 (font fallback) retire most of this.
    var loggedMissingScalars: Set<UInt32> = []
    static let loggedMissingCap = 256

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
        let scrollbackLines =
            scrollback > 0
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
    /// never touches stay blank — the grid extends visually to all
    /// four window edges over the `bg-base` background.
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
    static func makeBlankGrid(
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
    // The typing-to-pixel measurement (M1 task 3.10) requires a visible
    // state change per keystroke. The smallest viable change: cycle
    // cell (0, 0)'s glyph through the atlas's pre-rasterized A-Z + 0-9
    // set. The keystroke timestamp (`NSEvent.timestamp`,
    // mach-time-derived) is queued for the next frame's completion
    // handler, where `drawable.presentedTime` (also mach-time-derived)
    // closes the latency loop.

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
        lastKeystrokeTime = now()

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
