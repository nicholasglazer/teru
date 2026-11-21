//! Windows platform backend using Win32 API.
//!
//! Hand-declared Win32 types and extern functions (avoids windows.h
//! dependency for cross-compilation sanity). Creates a window via
//! RegisterClassExW + CreateWindowExW, blits CPU framebuffer via
//! StretchDIBits, polls events via PeekMessageW.

const std = @import("std");

// ── Win32 type declarations ─────────────────────────────────────────
// Manually declared so this file compiles (as type definitions) on any
// host. The externs only resolve when actually linking against Windows.

const BOOL = i32;
const BYTE = u8;
const WORD = u16;
const DWORD = u32;
const UINT = u32;
const INT = i32;
const LONG = i32;
const LONG_PTR = isize;
const UINT_PTR = usize;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const ATOM = u16;
const HBRUSH = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HDC = ?*anyopaque;
const HICON = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const HMODULE = ?*anyopaque;
const HWND = ?*anyopaque;
const LPVOID = ?*anyopaque;
const LPCWSTR = ?[*:0]const u16;
const LPWSTR = ?[*:0]u16;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,
};

const POINT = extern struct {
    x: LONG = 0,
    y: LONG = 0,
};

const MSG = extern struct {
    hwnd: HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: INT = 0,
    cbWndExtra: INT = 0,
    hInstance: HINSTANCE = null,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: LPCWSTR = null,
    lpszClassName: LPCWSTR = null,
    hIconSm: HICON = null,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]BYTE = @splat(0),
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG = 0,
    biHeight: LONG = 0,
    biPlanes: WORD = 1,
    biBitCount: WORD = 0,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

const RGBQUAD = extern struct {
    rgbBlue: BYTE = 0,
    rgbGreen: BYTE = 0,
    rgbRed: BYTE = 0,
    rgbReserved: BYTE = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]RGBQUAD = .{.{}},
};

// ── Win32 constants ─────────────────────────────────────────────────

const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const CS_OWNDC: UINT = 0x0020;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_EX_LAYERED: DWORD = 0x00080000;

const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_SETFOCUS: UINT = 0x0007;
const WM_KILLFOCUS: UINT = 0x0008;
const WM_PAINT: UINT = 0x000F;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_INPUTLANGCHANGE: UINT = 0x0051;
const WM_ERASEBKGND: UINT = 0x0014;

// WM_SIZE wParam
const SIZE_MINIMIZED: WPARAM = 1;

const VK_F4: WPARAM = 0x73;
const VK_SHIFT: INT = 0x10;
const VK_CONTROL: INT = 0x11;
const VK_MENU: INT = 0x12; // Alt
const VK_LCONTROL: INT = 0xA2;
const VK_RMENU: INT = 0xA5; // right Alt
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;

const PM_REMOVE: UINT = 0x0001;

const DIB_RGB_COLORS: UINT = 0;
const SRCCOPY: DWORD = 0x00CC0020;

const BI_RGB: DWORD = 0;

const SW_SHOW: INT = 5;

// SetLayeredWindowAttributes flags
const LWA_ALPHA: DWORD = 0x00000002;
const SWP_NOMOVE: UINT = 0x0002;
const SWP_NOZORDER: UINT = 0x0004;

// WHEEL_DELTA for WM_MOUSEWHEEL
const WHEEL_DELTA: i16 = 120;

// ── Win32 extern functions ──────────────────────────────────────────

extern "kernel32" fn GetModuleHandleW(lpModuleName: LPCWSTR) callconv(.c) HMODULE;

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.c) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: HINSTANCE,
    lpParam: LPVOID,
) callconv(.c) HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(.c) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
extern "imm32" fn ImmDisableIME(idThread: DWORD) callconv(.c) BOOL;
extern "imm32" fn ImmAssociateContextEx(hwnd: HWND, himc: ?*anyopaque, dwFlags: DWORD) callconv(.c) BOOL;
const IACE_IGNORENOCONTEXT: DWORD = 0x0020;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.c) void;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.c) BOOL;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.c) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) HCURSOR;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: LONG_PTR) callconv(.c) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(.c) LONG_PTR;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.c) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hWnd: HWND, crKey: DWORD, bAlpha: BYTE, dwFlags: DWORD) callconv(.c) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: UINT) callconv(.c) BOOL;
extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.c) HCURSOR;
extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.c) i16;
extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: INT, dwNewLong: LONG) callconv(.c) LONG;
extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: INT) callconv(.c) LONG;

extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: INT,
    yDest: INT,
    DestWidth: INT,
    DestHeight: INT,
    xSrc: INT,
    ySrc: INT,
    SrcWidth: INT,
    SrcHeight: INT,
    lpBits: ?*const anyopaque,
    lpbmi: *const BITMAPINFO,
    iUsage: UINT,
    rop: DWORD,
) callconv(.c) INT;
extern "user32" fn GetDC(hWnd: HWND) callconv(.c) HDC;
extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.c) INT;

// ── Win32 helper constants ──────────────────────────────────────────

// GWLP_USERDATA
const GWLP_USERDATA: INT = -21;

// GWL_EXSTYLE
const GWL_EXSTYLE: INT = -20;

// IDC_ARROW = MAKEINTRESOURCE(32512)
fn IDC_ARROW() LPCWSTR {
    return @ptrFromInt(32512);
}

/// Extract signed x-coordinate from lParam (low word, sign-extended).
fn GET_X_LPARAM(lp: LPARAM) i32 {
    return @as(i16, @truncate(@as(i64, @intCast(lp))));
}

/// Extract signed y-coordinate from lParam (high word, sign-extended).
fn GET_Y_LPARAM(lp: LPARAM) i32 {
    return @as(i16, @truncate(@as(i64, @intCast(lp)) >> 16));
}

/// Extract wheel delta from wParam high word (WM_MOUSEWHEEL).
fn GET_WHEEL_DELTA_WPARAM(wp: WPARAM) i16 {
    return @bitCast(@as(u16, @truncate(wp >> 16)));
}

// ── Shared types (from platform/types.zig) ──────────────────────────

const types = @import("../types.zig");
const compat = @import("../../compat.zig");
const keyboard = @import("keyboard.zig");
pub const KeyEvent = types.KeyEvent;
pub const MouseButton = types.MouseButton;
pub const MouseEvent = types.MouseEvent;
pub const Event = types.Event;
pub const Size = types.Size;
pub const X11Info = types.X11Info;

// ── Win32 window ────────────────────────────────────────────────────

/// Per-window state accessible from the WndProc callback via GWLP_USERDATA.
///
/// One `PeekMessageW` call can run the WndProc several times: it delivers
/// messages sent by other threads and by the system (a snap or maximize
/// sends WM_SIZE directly) before it returns the next posted one. So events
/// are queued, not kept in a single slot that a later message overwrites.
const WindowState = struct {
    /// Client-area size in pixels: the size of the surface we draw on.
    width: u32,
    height: u32,
    is_open: bool,
    /// The client size changed since the last `.resize` was handed out. A
    /// flag instead of a queued event, so a drag that produces a hundred
    /// WM_SIZE messages yields one resize to the final size, and a resize
    /// can never be lost to a full queue.
    size_dirty: bool = false,
    events: [queue_len]Event = undefined,
    head: usize = 0,
    count: usize = 0,

    const queue_len = 64;

    fn push(self: *WindowState, event: Event) void {
        if (self.count > 0) {
            const last = &self.events[(self.head + self.count - 1) % queue_len];
            // Collapse runs of pointer motion and of repaint requests: only
            // the latest matters.
            const same_kind = switch (event) {
                .mouse_motion => last.* == .mouse_motion,
                .expose => last.* == .expose,
                else => false,
            };
            if (same_kind) {
                last.* = event;
                return;
            }
        }
        if (self.count == queue_len) {
            // The main loop is not draining (a modal move/size loop). Drop
            // the oldest event; key releases and stale motion go first.
            self.head = (self.head + 1) % queue_len;
            self.count -= 1;
        }
        self.events[(self.head + self.count) % queue_len] = event;
        self.count += 1;
    }

    /// Next event for the main loop. A pending resize goes first so the
    /// framebuffer matches the window before anything is drawn.
    fn take(self: *WindowState) ?Event {
        if (self.size_dirty) {
            self.size_dirty = false;
            return .{ .resize = .{ .width = self.width, .height = self.height } };
        }
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % queue_len;
        self.count -= 1;
        return event;
    }
};

pub const Win32Window = struct {
    hwnd: HWND,
    hinstance: HINSTANCE,
    state: *WindowState,
    cursor_visible: bool,
    blank_cursor: HCURSOR,
    arrow_cursor: HCURSOR,

    // Static allocator for WindowState (one per window, freed on deinit)
    var state_storage: ?*WindowState = null;

    pub fn init(width: u32, height: u32, title: []const u8) !Win32Window {
        const hinstance = GetModuleHandleW(null);

        var wide_title: [256:0]u16 = @splat(0);
        widenTitle(&wide_title, title);

        const class_name: [*:0]const u16 = &[_:0]u16{ 't', 'e', 'r', 'u', '_', 'w', 'n', 'd' };

        // Register window class
        var wc = WNDCLASSEXW{};
        wc.cbSize = @sizeOf(WNDCLASSEXW);
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinstance;
        wc.hCursor = LoadCursorW(null, IDC_ARROW());
        // No class brush: every pixel of the client area is ours to draw.
        // With one, Windows erases to white before each WM_PAINT, which
        // shows as a white flash for the whole of a drag-resize.
        wc.hbrBackground = null;
        wc.lpszClassName = class_name;

        _ = RegisterClassExW(&wc);

        // Allocate persistent state for the WndProc callback.
        // smp_allocator over page_allocator: page_allocator wastes a full
        // 4 KB page per WindowState struct in 0.17 (one mmap per alloc).
        // smp_allocator is the singleton GPA in Release. WndProc has no
        // process Init in scope, so this is the right fallback.
        const state = std.heap.smp_allocator.create(WindowState) catch return error.OutOfMemory;
        state.* = .{
            .width = width,
            .height = height,
            .is_open = true,
        };
        state_storage = state;

        // Disable IME BEFORE window creation — ImmDisableIME has no effect
        // after the first window receives WM_CREATE. Terminal emulators
        // handle keyboard input directly via ToUnicode, not IME.
        _ = ImmDisableIME(@bitCast(@as(i32, -1))); // -1 = all threads

        // `width` x `height` is the client area the caller wants to draw on.
        // CreateWindowExW takes the outer size, title bar and borders
        // included, so grow the rectangle by the frame first.
        const style: DWORD = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
        var outer = RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        _ = AdjustWindowRectEx(&outer, style, 0, WS_EX_LAYERED);

        // Create window with WS_EX_LAYERED so setOpacity works
        const hwnd = CreateWindowExW(
            WS_EX_LAYERED,
            class_name,
            @ptrCast(&wide_title),
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            outer.right - outer.left,
            outer.bottom - outer.top,
            null, // parent
            null, // menu
            hinstance,
            null, // lpParam
        );

        if (hwnd == null) {
            std.heap.smp_allocator.destroy(state);
            state_storage = null;
            return error.CreateWindowFailed;
        }

        // Belt-and-suspenders: also disassociate IME context from this window.
        // This handles cases where ImmDisableIME didn't take effect.
        _ = ImmAssociateContextEx(hwnd, null, IACE_IGNORENOCONTEXT);

        // Store state pointer in window's GWLP_USERDATA
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(state)));

        // The WM_SIZE sent during creation arrived before the state pointer
        // was attached, and Windows may not have granted the size asked for
        // (a small screen clamps it). Read what we actually got; if it
        // differs, the main loop's first event is a resize to it.
        var client: RECT = .{};
        if (GetClientRect(hwnd, &client) != 0) {
            const cw: u32 = @intCast(@max(0, client.right - client.left));
            const ch: u32 = @intCast(@max(0, client.bottom - client.top));
            if (cw != 0 and ch != 0 and (cw != state.width or ch != state.height)) {
                state.width = cw;
                state.height = ch;
                state.size_dirty = true;
            }
        }

        // Default to fully opaque
        _ = SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        const arrow = LoadCursorW(null, IDC_ARROW());

        return Win32Window{
            .hwnd = hwnd,
            .hinstance = hinstance,
            .state = state,
            .cursor_visible = true,
            .blank_cursor = null, // TODO: create blank cursor for hideCursor on Windows
            .arrow_cursor = arrow,
        };
    }

    pub fn deinit(self: *Win32Window) void {
        _ = DestroyWindow(self.hwnd);
        self.state.is_open = false;
        std.heap.smp_allocator.destroy(self.state);
        state_storage = null;
    }

    pub fn pollEvents(self: *Win32Window) ?Event {
        if (self.state.take()) |event| return event;

        // A null window filter also retrieves thread messages, WM_QUIT among
        // them, and messages for helper windows the system creates on this
        // thread.
        var msg: MSG = .{};
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) {
                self.state.is_open = false;
                return .close;
            }
            // Skip TranslateMessage for keyboard events — we handle them
            // directly via ToUnicode in keyboard.zig. TranslateMessage
            // routes through IME which produces CJK characters on systems
            // with East Asian input methods enabled.
            if (msg.message != WM_KEYDOWN and msg.message != WM_SYSKEYDOWN and
                msg.message != WM_KEYUP and msg.message != WM_SYSKEYUP)
            {
                _ = TranslateMessage(&msg);
            }
            _ = DispatchMessageW(&msg);

            if (self.state.take()) |event| return event;
        }
        // PeekMessageW runs the WndProc for sent messages even when it
        // returns no posted message, so look once more.
        return self.state.take();
    }

    pub fn putFramebuffer(self: *Win32Window, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.state.width);
        const blit_h = @min(fb_height, self.state.height);
        if (blit_w == 0 or blit_h == 0) return;
        // The DIB header below promises GDI fb_width x fb_height pixels.
        if (pixels.len < @as(usize, fb_width) * fb_height) return;

        const hdc = GetDC(self.hwnd);
        if (hdc == null) return;
        defer _ = ReleaseDC(self.hwnd, hdc);

        // BITMAPINFO for top-down DIB (negative height = top-down)
        var bmi = BITMAPINFO{};
        bmi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(fb_width);
        bmi.bmiHeader.biHeight = -@as(LONG, @intCast(fb_height)); // negative = top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        _ = StretchDIBits(
            hdc,
            0,
            0,
            @intCast(blit_w),
            @intCast(blit_h),
            0,
            0,
            @intCast(blit_w),
            @intCast(blit_h),
            @ptrCast(pixels.ptr),
            &bmi,
            DIB_RGB_COLORS,
            SRCCOPY,
        );
    }

    /// Resize so the client area is `width` x `height`. The new size reaches
    /// `state` through the WM_SIZE that SetWindowPos sends.
    pub fn setSize(self: *Win32Window, width: u32, height: u32) void {
        var outer = RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        _ = AdjustWindowRectEx(&outer, WS_OVERLAPPEDWINDOW, 0, WS_EX_LAYERED);
        _ = SetWindowPos(self.hwnd, null, 0, 0, outer.right - outer.left, outer.bottom - outer.top, SWP_NOMOVE | SWP_NOZORDER);
    }

    pub fn getSize(self: *const Win32Window) Size {
        return .{ .width = self.state.width, .height = self.state.height };
    }

    /// Set window opacity (0.0 = transparent, 1.0 = fully opaque).
    /// Requires WS_EX_LAYERED extended style set at window creation.
    pub fn setOpacity(self: *Win32Window, opacity: f32) void {
        const alpha: u8 = @intFromFloat(@max(0.0, @min(1.0, opacity)) * 255.0);
        _ = SetLayeredWindowAttributes(self.hwnd, 0, alpha, LWA_ALPHA);
    }

    /// Set window title from UTF-8.
    pub fn setTitle(self: *Win32Window, title: []const u8) void {
        var wide_title: [256:0]u16 = @splat(0);
        widenTitle(&wide_title, title);
        _ = SetWindowTextW(self.hwnd, @ptrCast(&wide_title));
    }

    /// Hide the mouse cursor over this window.
    pub fn hideCursor(self: *Win32Window) void {
        if (!self.cursor_visible) return;
        self.cursor_visible = false;
        // Set cursor to null (blank) -- Win32 hides cursor when null is passed
        _ = SetCursor(null);
        // TODO: create a blank (1x1 transparent) cursor resource for robust hiding
    }

    /// Show the mouse cursor over this window.
    pub fn showCursor(self: *Win32Window) void {
        if (self.cursor_visible) return;
        self.cursor_visible = true;
        _ = SetCursor(self.arrow_cursor);
    }

    /// Get X11 connection info. Always null on Windows.
    pub fn getX11Info(_: *const Win32Window) ?X11Info {
        return null;
    }

    // ── WndProc callback ────────────────────────────────────────────

    fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
        const state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (state_ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);

        const state: *WindowState = @ptrFromInt(@as(usize, @intCast(state_ptr)));

        switch (msg) {
            WM_CLOSE => {
                state.is_open = false;
                state.push(.close);
                return 0;
            },
            WM_ERASEBKGND => return 1, // nothing to erase: we repaint it all
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            WM_SIZE => {
                // A minimized window reports 0x0. Keep the last real size:
                // resizing the grids and the pseudoconsole to nothing would
                // discard their contents.
                if (wparam == SIZE_MINIMIZED) return 0;
                const size = clientSizeFromLparam(lparam);
                if (size.width == 0 or size.height == 0) return 0;
                if (size.width != state.width or size.height != state.height) {
                    state.width = size.width;
                    state.height = size.height;
                    state.size_dirty = true;
                }
                return 0;
            },

            // ── Keyboard ────────────────────────────────────────────
            WM_KEYDOWN, WM_SYSKEYDOWN => {
                // Alt+F4 closes the window only if DefWindowProc sees it.
                if (msg == WM_SYSKEYDOWN and wparam == VK_F4) {
                    return DefWindowProcW(hwnd, msg, wparam, lparam);
                }
                const ctrl = getKeyStateDown(VK_CONTROL);
                const alt = getKeyStateDown(VK_MENU);
                // Ctrl+Alt is how Windows delivers AltGr, and layouts with
                // an AltGr level accept either Ctrl and either Alt for it.
                // Ask the layout: if this key yields a character with both
                // held, it is text and carries neither modifier.
                const scan: u32 = @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFF);
                const altgr = ctrl and alt and keyboard.ctrlAltProducesText(@truncate(wparam), scan);
                state.push(.{ .key_press = .{
                    .keycode = keycodeFor(wparam, lparam, getKeyStateDown(VK_LCONTROL)),
                    .modifiers = modifierMask(getKeyStateDown(VK_SHIFT), ctrl, alt, superDown(), altgr),
                } });
                return 0;
            },
            WM_KEYUP, WM_SYSKEYUP => {
                state.push(.{ .key_release = .{
                    // No left-Ctrl test on release: the press may have been
                    // reported as right Alt, and its release must match.
                    .keycode = keycodeFor(wparam, lparam, false),
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_INPUTLANGCHANGE => {
                // Keyboard layout changed (Win+Space, etc.) — let DefWindowProc
                // update the thread's HKL so ToUnicode uses the new layout.
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            },

            // ── Mouse buttons ───────────────────────────────────────
            WM_LBUTTONDOWN => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_press = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .left,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_LBUTTONUP => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_release = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .left,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_RBUTTONDOWN => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_press = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .right,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_RBUTTONUP => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_release = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .right,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_MBUTTONDOWN => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_press = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .middle,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },
            WM_MBUTTONUP => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_release = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .button = .middle,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },

            // ── Mouse wheel ─────────────────────────────────────────
            WM_MOUSEWHEEL => {
                const delta = GET_WHEEL_DELTA_WPARAM(wparam);
                // WM_MOUSEWHEEL reports SCREEN coords; the rest of the input
                // path (like WM_MOUSEMOVE/WM_*BUTTON) uses client coords.
                // Convert so the scroll lands on the pane under the cursor.
                var pt = POINT{ .x = GET_X_LPARAM(lparam), .y = GET_Y_LPARAM(lparam) };
                _ = ScreenToClient(hwnd, &pt);
                const button: MouseButton = if (delta > 0) .scroll_up else .scroll_down;
                state.push(.{ .mouse_press = .{
                    .x = if (pt.x >= 0) @intCast(pt.x) else 0,
                    .y = if (pt.y >= 0) @intCast(pt.y) else 0,
                    .button = button,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },

            // ── Mouse motion ────────────────────────────────────────
            WM_MOUSEMOVE => {
                const mx = GET_X_LPARAM(lparam);
                const my = GET_Y_LPARAM(lparam);
                state.push(.{ .mouse_motion = .{
                    .x = if (mx >= 0) @intCast(mx) else 0,
                    .y = if (my >= 0) @intCast(my) else 0,
                    .modifiers = getKeyModifiers(),
                } });
                return 0;
            },

            // ── Focus ───────────────────────────────────────────────
            WM_SETFOCUS => {
                state.push(.focus_in);
                return 0;
            },
            WM_KILLFOCUS => {
                state.push(.focus_out);
                return 0;
            },

            // ── Paint ───────────────────────────────────────────────
            WM_PAINT => {
                var ps: PAINTSTRUCT = .{};
                _ = BeginPaint(hwnd, &ps);
                _ = EndPaint(hwnd, &ps);
                state.push(.expose);
                return 0;
            },

            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// Modifier state for the message being handled, for events that are
    /// not a key press (mouse, key release). Without a key to ask the
    /// layout about, AltGr is taken to be its physical form: left Ctrl,
    /// which Windows synthesises, plus right Alt.
    fn getKeyModifiers() u32 {
        return modifierMask(
            getKeyStateDown(VK_SHIFT),
            getKeyStateDown(VK_CONTROL),
            getKeyStateDown(VK_MENU),
            superDown(),
            getKeyStateDown(VK_LCONTROL) and getKeyStateDown(VK_RMENU),
        );
    }

    fn superDown() bool {
        return getKeyStateDown(0x5B) or getKeyStateDown(0x5C); // VK_LWIN / VK_RWIN
    }

    fn getKeyStateDown(vk: INT) bool {
        const s = GetKeyState(vk);
        return (s & @as(i16, -0x7FFF - 1)) != 0; // high bit test
    }
};

/// Client width and height packed into a WM_SIZE lParam: two unsigned 16-bit
/// words. The rest of the 64-bit lParam is not part of the size.
fn clientSizeFromLparam(lparam: LPARAM) Size {
    const bits: usize = @bitCast(lparam);
    return .{
        .width = @as(u16, @truncate(bits)),
        .height = @as(u16, @truncate(bits >> 16)),
    };
}

/// Modifier bits in the layout the shared input code expects, which is
/// X11's: Shift 0x01, Control 0x04, Alt (Mod1) 0x08, Super (Mod4) 0x40.
/// The shared code tests some of them by number.
///
/// With AltGr held, Control and Alt are left out: the pair is how Windows
/// reports the AltGr level shift, and passing it on would turn AltGr+Q
/// (`@` on a German layout) into a Ctrl+Alt shortcut or an ESC-prefixed key.
fn modifierMask(shift: bool, ctrl: bool, alt: bool, super: bool, altgr: bool) u32 {
    const k = types.windows_keycodes;
    var mods: u32 = 0;
    if (shift) mods |= k.SHIFT_MASK;
    if (ctrl and !altgr) mods |= k.CTRL_MASK;
    if (alt and !altgr) mods |= k.ALT_MASK;
    if (super) mods |= 0x40;
    return mods;
}

/// The key code to report for a key message. Both Alt keys arrive as
/// VK_MENU; the right one is told apart by the extended-key bit, and is
/// reported as VK_RMENU so the shared code can treat it as it does on
/// other systems. Not when left Ctrl is down: that is AltGr, not Alt.
fn keycodeFor(wparam: WPARAM, lparam: LPARAM, left_ctrl_down: bool) u32 {
    const extended = (@as(usize, @bitCast(lparam)) & (1 << 24)) != 0;
    if (wparam == VK_MENU and extended and !left_ctrl_down) return types.windows_keycodes.RALT;
    return @truncate(wparam);
}

/// UTF-8 to a NUL-terminated UTF-16 title, truncated to fit. Invalid UTF-8
/// becomes U+FFFD.
fn widenTitle(dest: *[256:0]u16, title: []const u8) void {
    const r = compat.utf8ToUtf16Chunk(title, dest[0..dest.len]);
    dest[r.written] = 0;
}

test "WM_SIZE lParam is two 16-bit words" {
    // 992x666, as Windows packs it.
    const lp: LPARAM = @bitCast(@as(usize, 0x029a03e0));
    const size = clientSizeFromLparam(lp);
    try std.testing.expectEqual(@as(u32, 992), size.width);
    try std.testing.expectEqual(@as(u32, 666), size.height);
    // Bits above the two words do not leak into the height.
    if (@bitSizeOf(usize) == 64) {
        const noisy: LPARAM = @bitCast(@as(usize, 0x7fff_0000_029a_03e0));
        try std.testing.expectEqual(@as(u32, 666), clientSizeFromLparam(noisy).height);
    }
}

test "modifier bits are the values the shared input code tests by number" {
    // windowed.zig checks Alt as `& 8`; mouse and key handling use X11's
    // Shift 1 and Control 4.
    try std.testing.expectEqual(@as(u32, 1), modifierMask(true, false, false, false, false));
    try std.testing.expectEqual(@as(u32, 4), modifierMask(false, true, false, false, false));
    try std.testing.expectEqual(@as(u32, 8), modifierMask(false, false, true, false, false));
    try std.testing.expectEqual(@as(u32, 0x40), modifierMask(false, false, false, true, false));
    // AltGr arrives as Ctrl+Alt and must reach the terminal as neither.
    try std.testing.expectEqual(@as(u32, 0), modifierMask(false, true, true, false, true));
    try std.testing.expectEqual(@as(u32, 1), modifierMask(true, true, true, false, true));
}

test "right Alt is told apart by the extended-key bit" {
    const ext: LPARAM = 1 << 24;
    try std.testing.expectEqual(@as(u32, 0x12), keycodeFor(0x12, 0, false)); // left Alt
    try std.testing.expectEqual(@as(u32, 0xA5), keycodeFor(0x12, ext, false)); // right Alt
    try std.testing.expectEqual(@as(u32, 0x12), keycodeFor(0x12, ext, true)); // AltGr
    try std.testing.expectEqual(@as(u32, 0x0D), keycodeFor(0x0D, ext, false)); // keypad Enter
}

test "event queue: resize first, motion collapses, overflow drops the oldest" {
    var st: WindowState = .{ .width = 10, .height = 10, .is_open = true };
    st.push(.focus_in);
    st.push(.{ .mouse_motion = .{ .x = 1, .y = 1, .modifiers = 0 } });
    st.push(.{ .mouse_motion = .{ .x = 2, .y = 2, .modifiers = 0 } });
    st.width = 20;
    st.size_dirty = true;

    try std.testing.expectEqual(@as(u32, 20), st.take().?.resize.width);
    try std.testing.expect(st.take().? == .focus_in);
    try std.testing.expectEqual(@as(u32, 2), st.take().?.mouse_motion.x);
    try std.testing.expect(st.take() == null);

    for (0..WindowState.queue_len + 3) |i| {
        st.push(.{ .key_press = .{ .keycode = @intCast(i), .modifiers = 0 } });
    }
    try std.testing.expectEqual(@as(u32, 3), st.take().?.key_press.keycode);
}

test "widenTitle handles non-ASCII and truncates" {
    var buf: [256:0]u16 = @splat(0);
    widenTitle(&buf, "한 a");
    try std.testing.expectEqual(@as(u16, 0xD55C), buf[0]);
    try std.testing.expectEqual(@as(u16, ' '), buf[1]);
    try std.testing.expectEqual(@as(u16, 'a'), buf[2]);
    try std.testing.expectEqual(@as(u16, 0), buf[3]);

    // A title cut in the middle of a character ends in U+FFFD, not in the
    // stray bytes read as Latin-1.
    widenTitle(&buf, "ab\xe2\x82");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xFFFD, 0xFFFD, 0 }, buf[0..5]);

    const long: [600]u8 = @splat('x');
    widenTitle(&buf, &long);
    var len: usize = 0;
    while (buf[len] != 0) len += 1;
    try std.testing.expect(len >= 254 and len <= 256);
    try std.testing.expectEqual(@as(u16, 'x'), buf[len - 1]);
}

// ── Platform wrapper (single-backend, matches Linux Platform shape) ─

pub const Platform = union(enum) {
    win32: Win32Window,

    pub fn init(width: u32, height: u32, title: []const u8, _: ?[]const u8) !Platform {
        return .{ .win32 = try Win32Window.init(width, height, title) };
    }

    pub fn deinit(self: *Platform) void {
        switch (self.*) {
            .win32 => |*w| w.deinit(),
        }
    }

    pub fn pollEvents(self: *Platform) ?Event {
        return switch (self.*) {
            .win32 => |*w| w.pollEvents(),
        };
    }

    pub fn putFramebuffer(self: *Platform, pixels: []const u32, width: u32, height: u32) void {
        switch (self.*) {
            .win32 => |*w| w.putFramebuffer(pixels, width, height),
        }
    }

    pub fn setSize(self: *Platform, width: u32, height: u32) void {
        switch (self.*) {
            .win32 => |*w| w.setSize(width, height),
        }
    }

    pub fn getSize(self: *const Platform) Size {
        return switch (self.*) {
            .win32 => |*w| w.getSize(),
        };
    }

    pub fn setOpacity(self: *Platform, opacity: f32) void {
        switch (self.*) {
            .win32 => |*w| w.setOpacity(opacity),
        }
    }

    pub fn setTitle(self: *Platform, title: []const u8) void {
        switch (self.*) {
            .win32 => |*w| w.setTitle(title),
        }
    }

    pub fn hideCursor(self: *Platform) void {
        switch (self.*) {
            .win32 => |*w| w.hideCursor(),
        }
    }

    pub fn showCursor(self: *Platform) void {
        switch (self.*) {
            .win32 => |*w| w.showCursor(),
        }
    }

    pub fn getX11Info(self: *const Platform) ?X11Info {
        return switch (self.*) {
            .win32 => |*w| w.getX11Info(),
        };
    }
};
