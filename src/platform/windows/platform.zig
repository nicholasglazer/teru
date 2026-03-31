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
    rgbReserved: [32]BYTE = [_]BYTE{0} ** 32,
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

const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_PAINT: UINT = 0x000F;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_SETFOCUS: UINT = 0x0007;
const WM_KILLFOCUS: UINT = 0x0008;

const PM_REMOVE: UINT = 0x0001;

const COLOR_WINDOW: INT = 5;

const DIB_RGB_COLORS: UINT = 0;
const SRCCOPY: DWORD = 0x00CC0020;

const BI_RGB: DWORD = 0;

const SW_SHOW: INT = 5;

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
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.c) void;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) BOOL;
extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) HCURSOR;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: LONG_PTR) callconv(.c) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(.c) LONG_PTR;

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
extern "gdi32" fn GetDC(hWnd: HWND) callconv(.c) HDC;
extern "gdi32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.c) INT;

// GWLP_USERDATA
const GWLP_USERDATA: INT = -21;

// IDC_ARROW = MAKEINTRESOURCE(32512)
fn IDC_ARROW() LPCWSTR {
    return @ptrFromInt(32512);
}

// ── Shared types (from platform/types.zig) ──────────────────────────

const types = @import("../types.zig");
pub const KeyEvent = types.KeyEvent;
pub const Event = types.Event;
pub const Size = types.Size;

// ── Win32 window ────────────────────────────────────────────────────

/// Per-window state accessible from the WndProc callback via GWLP_USERDATA.
const WindowState = struct {
    width: u32,
    height: u32,
    is_open: bool,
    pending_event: ?Event,
};

pub const Win32Window = struct {
    hwnd: HWND,
    hinstance: HINSTANCE,
    state: *WindowState,

    // Static allocator for WindowState (one per window, freed on deinit)
    var state_storage: ?*WindowState = null;

    pub fn init(width: u32, height: u32, title: []const u8) !Win32Window {
        const hinstance = GetModuleHandleW(null);

        // Convert title to wide string (UTF-16)
        var wide_title: [256:0]u16 = [_:0]u16{0} ** 256;
        const len = @min(title.len, 255);
        for (0..len) |i| {
            wide_title[i] = title[i]; // ASCII subset
        }
        wide_title[len] = 0;

        const class_name: [*:0]const u16 = &[_:0]u16{ 't', 'e', 'r', 'u', '_', 'w', 'n', 'd' };

        // Register window class
        var wc = WNDCLASSEXW{};
        wc.cbSize = @sizeOf(WNDCLASSEXW);
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinstance;
        wc.hCursor = LoadCursorW(null, IDC_ARROW());
        wc.hbrBackground = @ptrFromInt(@as(usize, @intCast(COLOR_WINDOW + 1)));
        wc.lpszClassName = class_name;

        _ = RegisterClassExW(&wc);

        // Allocate persistent state for the WndProc callback
        const state = std.heap.page_allocator.create(WindowState) catch return error.OutOfMemory;
        state.* = .{
            .width = width,
            .height = height,
            .is_open = true,
            .pending_event = null,
        };
        state_storage = state;

        // Create window
        const hwnd = CreateWindowExW(
            0, // dwExStyle
            class_name,
            @ptrCast(&wide_title),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(width),
            @intCast(height),
            null, // parent
            null, // menu
            hinstance,
            null, // lpParam
        );

        if (hwnd == null) return error.CreateWindowFailed;

        // Store state pointer in window's GWLP_USERDATA
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(state)));

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        return Win32Window{
            .hwnd = hwnd,
            .hinstance = hinstance,
            .state = state,
        };
    }

    pub fn deinit(self: *Win32Window) void {
        _ = DestroyWindow(self.hwnd);
        self.state.is_open = false;
        std.heap.page_allocator.destroy(self.state);
        state_storage = null;
    }

    pub fn pollEvents(self: *Win32Window) ?Event {
        // Check for pending event from WndProc
        if (self.state.pending_event) |evt| {
            self.state.pending_event = null;
            return evt;
        }

        var msg: MSG = .{};
        if (PeekMessageW(&msg, self.hwnd, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) {
                self.state.is_open = false;
                return .close;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);

            // Check if WndProc produced a pending event
            if (self.state.pending_event) |evt| {
                self.state.pending_event = null;
                return evt;
            }
            return .none;
        }
        return null;
    }

    pub fn putFramebuffer(self: *Win32Window, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.state.width);
        const blit_h = @min(fb_height, self.state.height);
        if (blit_w == 0 or blit_h == 0) return;

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

    pub fn getSize(self: *const Win32Window) Size {
        return .{ .width = self.state.width, .height = self.state.height };
    }

    // ── WndProc callback ────────────────────────────────────────────

    fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
        const state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (state_ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);

        const state: *WindowState = @ptrFromInt(@as(usize, @intCast(state_ptr)));

        switch (msg) {
            WM_CLOSE => {
                state.is_open = false;
                state.pending_event = .close;
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            WM_SIZE => {
                const new_w: u32 = @truncate(@as(usize, @bitCast(lparam)));
                const new_h: u32 = @truncate(@as(usize, @bitCast(lparam)) >> 16);
                if (new_w != state.width or new_h != state.height) {
                    state.width = new_w;
                    state.height = new_h;
                    state.pending_event = .{ .resize = .{ .width = new_w, .height = new_h } };
                }
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN => {
                const modifiers = getKeyModifiers();
                state.pending_event = .{ .key_press = .{
                    .keycode = @truncate(wparam),
                    .modifiers = modifiers,
                } };
                return 0;
            },
            WM_KEYUP, WM_SYSKEYUP => {
                const modifiers = getKeyModifiers();
                state.pending_event = .{ .key_release = .{
                    .keycode = @truncate(wparam),
                    .modifiers = modifiers,
                } };
                return 0;
            },
            WM_SETFOCUS => {
                state.pending_event = .focus_in;
                return 0;
            },
            WM_KILLFOCUS => {
                state.pending_event = .focus_out;
                return 0;
            },
            WM_PAINT => {
                var ps: PAINTSTRUCT = .{};
                _ = BeginPaint(hwnd, &ps);
                _ = EndPaint(hwnd, &ps);
                state.pending_event = .expose;
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// Read current modifier key state via GetKeyState (virtual key codes).
    fn getKeyModifiers() u32 {
        // GetKeyState returns high bit set if key is down
        var mods: u32 = 0;
        if (getKeyStateDown(0x10)) mods |= 0x01; // VK_SHIFT
        if (getKeyStateDown(0x11)) mods |= 0x02; // VK_CONTROL
        if (getKeyStateDown(0x12)) mods |= 0x04; // VK_MENU (Alt)
        if (getKeyStateDown(0x5B) or getKeyStateDown(0x5C)) mods |= 0x08; // VK_LWIN / VK_RWIN
        return mods;
    }

    fn getKeyStateDown(vk: INT) bool {
        const state = GetKeyState(vk);
        return (state & @as(i16, -0x7FFF - 1)) != 0; // high bit test
    }
};

extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.c) i16;

// ── Platform wrapper (single-backend, matches linux Platform shape) ─

pub const Platform = union(enum) {
    win32: Win32Window,

    pub fn init(width: u32, height: u32, title: []const u8) !Platform {
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

    pub fn getSize(self: *const Platform) Size {
        return switch (self.*) {
            .win32 => |*w| .{ .width = w.state.width, .height = w.state.height },
        };
    }
};
