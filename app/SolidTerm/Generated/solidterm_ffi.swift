public func ffi_greet<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$ffi_greet(nameAsRustStr))
    })
}
public func echo_session_config(_ c: SessionConfig) -> SessionConfig {
    __swift_bridge__$echo_session_config(c.intoFfiRepr()).intoSwiftRepr()
}
public func echo_input_event(_ e: InputEvent) -> InputEvent {
    __swift_bridge__$echo_input_event(e.intoFfiRepr()).intoSwiftRepr()
}
public func echo_frame_delta(_ f: FrameDelta) -> FrameDelta {
    __swift_bridge__$echo_frame_delta(f.intoFfiRepr()).intoSwiftRepr()
}
public func echo_cell_delta(_ c: CellDelta) -> CellDelta {
    __swift_bridge__$echo_cell_delta(c.intoFfiRepr()).intoSwiftRepr()
}
public struct KeyEvent {
    public var codepoint: UInt32
    public var keycode: UInt32
    public var text: RustString
    public var action: UInt8

    public init(codepoint: UInt32,keycode: UInt32,text: RustString,action: UInt8) {
        self.codepoint = codepoint
        self.keycode = keycode
        self.text = text
        self.action = action
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$KeyEvent {
        { let val = self; return __swift_bridge__$KeyEvent(codepoint: val.codepoint, keycode: val.keycode, text: { let rustString = val.text.intoRustString(); rustString.isOwned = false; return rustString.ptr }(), action: val.action); }()
    }
}
extension __swift_bridge__$KeyEvent {
    @inline(__always)
    func intoSwiftRepr() -> KeyEvent {
        { let val = self; return KeyEvent(codepoint: val.codepoint, keycode: val.keycode, text: RustString(ptr: val.text), action: val.action); }()
    }
}
extension __swift_bridge__$Option$KeyEvent {
    @inline(__always)
    func intoSwiftRepr() -> Optional<KeyEvent> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<KeyEvent>) -> __swift_bridge__$Option$KeyEvent {
        if let v = val {
            return __swift_bridge__$Option$KeyEvent(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$KeyEvent(is_some: false, val: __swift_bridge__$KeyEvent())
        }
    }
}
public struct MouseEvent {
    public var col: UInt16
    public var row: UInt16
    public var button: UInt8
    public var action: UInt8

    public init(col: UInt16,row: UInt16,button: UInt8,action: UInt8) {
        self.col = col
        self.row = row
        self.button = button
        self.action = action
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$MouseEvent {
        { let val = self; return __swift_bridge__$MouseEvent(col: val.col, row: val.row, button: val.button, action: val.action); }()
    }
}
extension __swift_bridge__$MouseEvent {
    @inline(__always)
    func intoSwiftRepr() -> MouseEvent {
        { let val = self; return MouseEvent(col: val.col, row: val.row, button: val.button, action: val.action); }()
    }
}
extension __swift_bridge__$Option$MouseEvent {
    @inline(__always)
    func intoSwiftRepr() -> Optional<MouseEvent> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<MouseEvent>) -> __swift_bridge__$Option$MouseEvent {
        if let v = val {
            return __swift_bridge__$Option$MouseEvent(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$MouseEvent(is_some: false, val: __swift_bridge__$MouseEvent())
        }
    }
}
public struct CursorState {
    public var row: UInt16
    public var col: UInt16
    public var shape: UInt8
    public var blink: Bool
    public var hidden: Bool

    public init(row: UInt16,col: UInt16,shape: UInt8,blink: Bool,hidden: Bool) {
        self.row = row
        self.col = col
        self.shape = shape
        self.blink = blink
        self.hidden = hidden
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$CursorState {
        { let val = self; return __swift_bridge__$CursorState(row: val.row, col: val.col, shape: val.shape, blink: val.blink, hidden: val.hidden); }()
    }
}
extension __swift_bridge__$CursorState {
    @inline(__always)
    func intoSwiftRepr() -> CursorState {
        { let val = self; return CursorState(row: val.row, col: val.col, shape: val.shape, blink: val.blink, hidden: val.hidden); }()
    }
}
extension __swift_bridge__$Option$CursorState {
    @inline(__always)
    func intoSwiftRepr() -> Optional<CursorState> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<CursorState>) -> __swift_bridge__$Option$CursorState {
        if let v = val {
            return __swift_bridge__$Option$CursorState(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$CursorState(is_some: false, val: __swift_bridge__$CursorState())
        }
    }
}
public struct CellDelta {
    public var row: UInt16
    public var col: UInt16
    public var grapheme: RustVec<UInt8>
    public var fg: UInt32
    public var bg: UInt32
    public var attrs: UInt16
    public var width: UInt8

    public init(row: UInt16,col: UInt16,grapheme: RustVec<UInt8>,fg: UInt32,bg: UInt32,attrs: UInt16,width: UInt8) {
        self.row = row
        self.col = col
        self.grapheme = grapheme
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.width = width
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$CellDelta {
        { let val = self; return __swift_bridge__$CellDelta(row: val.row, col: val.col, grapheme: { let val = val.grapheme; val.isOwned = false; return val.ptr }(), fg: val.fg, bg: val.bg, attrs: val.attrs, width: val.width); }()
    }
}
extension __swift_bridge__$CellDelta {
    @inline(__always)
    func intoSwiftRepr() -> CellDelta {
        { let val = self; return CellDelta(row: val.row, col: val.col, grapheme: RustVec(ptr: val.grapheme), fg: val.fg, bg: val.bg, attrs: val.attrs, width: val.width); }()
    }
}
extension __swift_bridge__$Option$CellDelta {
    @inline(__always)
    func intoSwiftRepr() -> Optional<CellDelta> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<CellDelta>) -> __swift_bridge__$Option$CellDelta {
        if let v = val {
            return __swift_bridge__$Option$CellDelta(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$CellDelta(is_some: false, val: __swift_bridge__$CellDelta())
        }
    }
}
public struct HyperlinkHit {
    public var uri: RustString
    public var start_col: UInt16
    public var span: UInt16

    public init(uri: RustString,start_col: UInt16,span: UInt16) {
        self.uri = uri
        self.start_col = start_col
        self.span = span
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$HyperlinkHit {
        { let val = self; return __swift_bridge__$HyperlinkHit(uri: { let rustString = val.uri.intoRustString(); rustString.isOwned = false; return rustString.ptr }(), start_col: val.start_col, span: val.span); }()
    }
}
extension __swift_bridge__$HyperlinkHit {
    @inline(__always)
    func intoSwiftRepr() -> HyperlinkHit {
        { let val = self; return HyperlinkHit(uri: RustString(ptr: val.uri), start_col: val.start_col, span: val.span); }()
    }
}
extension __swift_bridge__$Option$HyperlinkHit {
    @inline(__always)
    func intoSwiftRepr() -> Optional<HyperlinkHit> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<HyperlinkHit>) -> __swift_bridge__$Option$HyperlinkHit {
        if let v = val {
            return __swift_bridge__$Option$HyperlinkHit(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$HyperlinkHit(is_some: false, val: __swift_bridge__$HyperlinkHit())
        }
    }
}
public struct SessionConfig {
    public var rows: UInt16
    public var cols: UInt16
    public var pixel_w: UInt16
    public var pixel_h: UInt16
    public var command: RustString
    public var cwd: RustString
    public var env: RustVec<UInt8>
    public var scrollback_lines: UInt32

    public init(rows: UInt16,cols: UInt16,pixel_w: UInt16,pixel_h: UInt16,command: RustString,cwd: RustString,env: RustVec<UInt8>,scrollback_lines: UInt32) {
        self.rows = rows
        self.cols = cols
        self.pixel_w = pixel_w
        self.pixel_h = pixel_h
        self.command = command
        self.cwd = cwd
        self.env = env
        self.scrollback_lines = scrollback_lines
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$SessionConfig {
        { let val = self; return __swift_bridge__$SessionConfig(rows: val.rows, cols: val.cols, pixel_w: val.pixel_w, pixel_h: val.pixel_h, command: { let rustString = val.command.intoRustString(); rustString.isOwned = false; return rustString.ptr }(), cwd: { let rustString = val.cwd.intoRustString(); rustString.isOwned = false; return rustString.ptr }(), env: { let val = val.env; val.isOwned = false; return val.ptr }(), scrollback_lines: val.scrollback_lines); }()
    }
}
extension __swift_bridge__$SessionConfig {
    @inline(__always)
    func intoSwiftRepr() -> SessionConfig {
        { let val = self; return SessionConfig(rows: val.rows, cols: val.cols, pixel_w: val.pixel_w, pixel_h: val.pixel_h, command: RustString(ptr: val.command), cwd: RustString(ptr: val.cwd), env: RustVec(ptr: val.env), scrollback_lines: val.scrollback_lines); }()
    }
}
extension __swift_bridge__$Option$SessionConfig {
    @inline(__always)
    func intoSwiftRepr() -> Optional<SessionConfig> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<SessionConfig>) -> __swift_bridge__$Option$SessionConfig {
        if let v = val {
            return __swift_bridge__$Option$SessionConfig(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$SessionConfig(is_some: false, val: __swift_bridge__$SessionConfig())
        }
    }
}
public struct InputEvent {
    public var kind: UInt8
    public var key: KeyEvent
    public var mouse: MouseEvent
    public var modifiers: UInt8

    public init(kind: UInt8,key: KeyEvent,mouse: MouseEvent,modifiers: UInt8) {
        self.kind = kind
        self.key = key
        self.mouse = mouse
        self.modifiers = modifiers
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$InputEvent {
        { let val = self; return __swift_bridge__$InputEvent(kind: val.kind, key: val.key.intoFfiRepr(), mouse: val.mouse.intoFfiRepr(), modifiers: val.modifiers); }()
    }
}
extension __swift_bridge__$InputEvent {
    @inline(__always)
    func intoSwiftRepr() -> InputEvent {
        { let val = self; return InputEvent(kind: val.kind, key: val.key.intoSwiftRepr(), mouse: val.mouse.intoSwiftRepr(), modifiers: val.modifiers); }()
    }
}
extension __swift_bridge__$Option$InputEvent {
    @inline(__always)
    func intoSwiftRepr() -> Optional<InputEvent> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<InputEvent>) -> __swift_bridge__$Option$InputEvent {
        if let v = val {
            return __swift_bridge__$Option$InputEvent(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$InputEvent(is_some: false, val: __swift_bridge__$InputEvent())
        }
    }
}
public struct FrameDelta {
    public var cells: RustVec<UInt8>
    public var cursor: CursorState
    public var scroll_top: UInt32
    public var scroll_total: UInt32

    public init(cells: RustVec<UInt8>,cursor: CursorState,scroll_top: UInt32,scroll_total: UInt32) {
        self.cells = cells
        self.cursor = cursor
        self.scroll_top = scroll_top
        self.scroll_total = scroll_total
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FrameDelta {
        { let val = self; return __swift_bridge__$FrameDelta(cells: { let val = val.cells; val.isOwned = false; return val.ptr }(), cursor: val.cursor.intoFfiRepr(), scroll_top: val.scroll_top, scroll_total: val.scroll_total); }()
    }
}
extension __swift_bridge__$FrameDelta {
    @inline(__always)
    func intoSwiftRepr() -> FrameDelta {
        { let val = self; return FrameDelta(cells: RustVec(ptr: val.cells), cursor: val.cursor.intoSwiftRepr(), scroll_top: val.scroll_top, scroll_total: val.scroll_total); }()
    }
}
extension __swift_bridge__$Option$FrameDelta {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FrameDelta> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FrameDelta>) -> __swift_bridge__$Option$FrameDelta {
        if let v = val {
            return __swift_bridge__$Option$FrameDelta(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FrameDelta(is_some: false, val: __swift_bridge__$FrameDelta())
        }
    }
}

public class TerminalSession: TerminalSessionRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$TerminalSession$_free(ptr)
        }
    }
}
extension TerminalSession {
    class public func new(_ config: SessionConfig) -> Optional<TerminalSession> {
        { let val = __swift_bridge__$TerminalSession$new(config.intoFfiRepr()); if val != nil { return TerminalSession(ptr: val!) } else { return nil } }()
    }
}
public class TerminalSessionRefMut: TerminalSessionRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
extension TerminalSessionRefMut {
    public func send_input(_ event: InputEvent) {
        __swift_bridge__$TerminalSession$send_input(ptr, event.intoFfiRepr())
    }

    public func paste_chunk(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        __swift_bridge__$TerminalSession$paste_chunk(ptr, bytes.toFfiSlice())
    }

    public func take_frame_delta() -> FrameDelta {
        __swift_bridge__$TerminalSession$take_frame_delta(ptr).intoSwiftRepr()
    }

    public func take_full_frame_delta() -> FrameDelta {
        __swift_bridge__$TerminalSession$take_full_frame_delta(ptr).intoSwiftRepr()
    }

    public func scroll_lines(_ delta: Int32) {
        __swift_bridge__$TerminalSession$scroll_lines(ptr, delta)
    }

    public func scroll_to_bottom() {
        __swift_bridge__$TerminalSession$scroll_to_bottom(ptr)
    }

    public func scroll_to_line(_ line: Int32) {
        __swift_bridge__$TerminalSession$scroll_to_line(ptr, line)
    }

    public func search<GenericToRustStr: ToRustStr>(_ query: GenericToRustStr, _ regex_flag: Bool) -> RustVec<UInt8> {
        return query.toRustStr({ queryAsRustStr in
            RustVec(ptr: __swift_bridge__$TerminalSession$search(ptr, queryAsRustStr, regex_flag))
        })
    }

    public func start_selection(_ mode: UInt8, _ row: UInt16, _ col: UInt16) {
        __swift_bridge__$TerminalSession$start_selection(ptr, mode, row, col)
    }

    public func update_selection(_ row: UInt16, _ col: UInt16) {
        __swift_bridge__$TerminalSession$update_selection(ptr, row, col)
    }

    public func clear_selection() {
        __swift_bridge__$TerminalSession$clear_selection(ptr)
    }

    public func drain_latest_title() -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$drain_latest_title(ptr))
    }

    public func drain_latest_cwd() -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$drain_latest_cwd(ptr))
    }

    public func drain_bell() -> Bool {
        __swift_bridge__$TerminalSession$drain_bell(ptr)
    }

    public func drain_clipboard_store() -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$drain_clipboard_store(ptr))
    }

    public func resize(_ rows: UInt16, _ cols: UInt16) -> Bool {
        __swift_bridge__$TerminalSession$resize(ptr, rows, cols)
    }

    public func set_theme_colors(_ fg: UInt32, _ bg: UInt32, _ cursor: UInt32) {
        __swift_bridge__$TerminalSession$set_theme_colors(ptr, fg, bg, cursor)
    }
}
public class TerminalSessionRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension TerminalSessionRef {
    public func rows() -> UInt16 {
        __swift_bridge__$TerminalSession$rows(ptr)
    }

    public func cols() -> UInt16 {
        __swift_bridge__$TerminalSession$cols(ptr)
    }

    public func cursor_snapshot() -> CursorState {
        __swift_bridge__$TerminalSession$cursor_snapshot(ptr).intoSwiftRepr()
    }

    public func last_search_error() -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$last_search_error(ptr))
    }

    public func is_alt_screen() -> Bool {
        __swift_bridge__$TerminalSession$is_alt_screen(ptr)
    }

    public func selection_span() -> RustVec<UInt32> {
        RustVec(ptr: __swift_bridge__$TerminalSession$selection_span(ptr))
    }

    public func selection_text() -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$selection_text(ptr))
    }

    public func bracketed_paste_enabled() -> Bool {
        __swift_bridge__$TerminalSession$bracketed_paste_enabled(ptr)
    }

    public func mouse_mode_bits() -> UInt8 {
        __swift_bridge__$TerminalSession$mouse_mode_bits(ptr)
    }

    public func kitty_keyboard_flags() -> UInt8 {
        __swift_bridge__$TerminalSession$kitty_keyboard_flags(ptr)
    }

    public func app_cursor_active() -> Bool {
        __swift_bridge__$TerminalSession$app_cursor_active(ptr)
    }

    public func focus_events_enabled() -> Bool {
        __swift_bridge__$TerminalSession$focus_events_enabled(ptr)
    }

    public func child_pid() -> UInt32 {
        __swift_bridge__$TerminalSession$child_pid(ptr)
    }

    public func row_text(_ row: UInt16) -> RustString {
        RustString(ptr: __swift_bridge__$TerminalSession$row_text(ptr, row))
    }

    public func cell_before_cursor() -> RustVec<UInt8> {
        RustVec(ptr: __swift_bridge__$TerminalSession$cell_before_cursor(ptr))
    }

    public func hyperlink_at(_ row: UInt16, _ col: UInt16) -> HyperlinkHit {
        __swift_bridge__$TerminalSession$hyperlink_at(ptr, row, col).intoSwiftRepr()
    }
}
extension TerminalSession: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_TerminalSession$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_TerminalSession$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: TerminalSession) {
        __swift_bridge__$Vec_TerminalSession$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_TerminalSession$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (TerminalSession(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<TerminalSessionRef> {
        let pointer = __swift_bridge__$Vec_TerminalSession$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return TerminalSessionRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<TerminalSessionRefMut> {
        let pointer = __swift_bridge__$Vec_TerminalSession$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return TerminalSessionRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<TerminalSessionRef> {
        UnsafePointer<TerminalSessionRef>(OpaquePointer(__swift_bridge__$Vec_TerminalSession$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_TerminalSession$len(vecPtr)
    }
}



