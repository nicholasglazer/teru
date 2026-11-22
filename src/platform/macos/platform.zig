//! macOS platform backend using Cocoa (AppKit) via the Objective-C runtime.
//!
//! Pure C function calls from Zig: no Swift, no Objective-C compiler. It
//! creates an NSApplication and an NSWindow, presents the CPU framebuffer
//! as the contents of a Core Animation layer, and polls events with
//! nextEventMatchingMask instead of running [NSApp run].
//!
//! Units: everything this backend hands to shared code (window size,
//! resize events, mouse positions, the framebuffer) is in backing pixels.
//! AppKit works in points; on a Retina display a point is two pixels.
//!
//! Never run on real hardware by the people who wrote it: see
//! docs/INSTALLING.md for what has and has not been checked.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const events = @import("events.zig");
const keyboard = @import("keyboard.zig");

// ── Objective-C runtime (hand-declared, no @cImport) ──────────────────
//
// Zig's C translator cannot handle Objective-C block syntax in
// objc/runtime.h, so we declare the minimal set of externs we need.

const SEL = *opaque {};
const id = *anyopaque;

extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() callconv(.c) void;
extern "c" fn objc_allocateClassPair(superclass: ?*anyopaque, name: [*:0]const u8, extra_bytes: usize) ?*anyopaque;
extern "c" fn objc_registerClassPair(class: *anyopaque) void;
extern "c" fn class_addMethod(class: *anyopaque, name: SEL, imp: *const anyopaque, type_encoding: [*:0]const u8) ObjcBool;
// Objects AppKit returns autoreleased (every NSEvent, every string made
// with a convenience constructor) are freed when the enclosing pool is
// popped. teru never runs [NSApp run], which is what normally provides
// one, so each poll and each frame pushes its own.
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

// objc_msgSend_stret only exists on x86_64; arm64 returns structs via registers.
const objc_msgSend_stret_fn = if (builtin.cpu.arch == .x86_64) blk: {
    const f = struct {
        extern "c" fn objc_msgSend_stret() callconv(.c) void;
    };
    break :blk f.objc_msgSend_stret;
} else objc_msgSend;

// Foundation, QuartzCore and CoreGraphics constants (NSString / CFString).
extern "c" const NSDefaultRunLoopMode: id;
extern "c" const kCAGravityTopLeft: id;
extern "c" const kCAFilterNearest: id;
extern "c" const kCGColorSpaceSRGB: *const anyopaque;

// CoreGraphics: a bitmap context is the staging buffer each frame is
// copied into; CGBitmapContextCreateImage snapshots it copy-on-write.
extern "c" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ?*anyopaque, bitmap_info: u32) ?*anyopaque;
extern "c" fn CGBitmapContextGetData(context: *anyopaque) ?[*]u8;
extern "c" fn CGBitmapContextGetBytesPerRow(context: *anyopaque) usize;
extern "c" fn CGBitmapContextCreateImage(context: *anyopaque) ?*anyopaque;
extern "c" fn CGContextRelease(context: ?*anyopaque) void;
extern "c" fn CGImageRelease(image: ?*anyopaque) void;

/// The framebuffer holds u32 0xAARRGGBB, which a little-endian CPU stores as
/// the bytes B,G,R,A. CoreGraphics reads that as "32-bit little-endian,
/// alpha first, alpha ignored": exactly xRGB.
const kCGBitmapByteOrder32Little: u32 = 2 << 12;
const kCGImageAlphaNoneSkipFirst: u32 = 6;

/// Objective-C BOOL: C `bool` on arm64, `signed char` on x86_64.
const ObjcBool = if (builtin.cpu.arch == .aarch64) bool else i8;
const YES: ObjcBool = if (ObjcBool == bool) true else 1;
const NO: ObjcBool = if (ObjcBool == bool) false else 0;
/// Type-encoding character for BOOL, used when adding methods at runtime.
const bool_enc = if (ObjcBool == bool) "B" else "c";

// ── Objective-C runtime helpers ─────────────────────────────────────

const objc_msgSend_fn = objc_msgSend;

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

fn cls(name: [*:0]const u8) id {
    return @ptrCast(objc_getClass(name) orelse unreachable);
}

fn msgSend(target: id, selector: SEL, args: anytype) id {
    return msgSendTyped(id, target, selector, args);
}

/// For methods that can return nil.
fn msgSendOpt(target: id, selector: SEL, args: anytype) ?id {
    return msgSendTyped(?id, target, selector, args);
}

fn msgSendVoid(target: id, selector: SEL, args: anytype) void {
    msgSendTyped(void, target, selector, args);
}

fn msgSendBool(target: id, selector: SEL, args: anytype) bool {
    const r = msgSendTyped(ObjcBool, target, selector, args);
    return if (ObjcBool == bool) r else r != 0;
}

fn msgSendU64(target: id, selector: SEL, args: anytype) u64 {
    return msgSendTyped(u64, target, selector, args);
}

fn msgSendI64(target: id, selector: SEL, args: anytype) i64 {
    return msgSendTyped(i64, target, selector, args);
}

fn msgSendU16(target: id, selector: SEL, args: anytype) u16 {
    return msgSendTyped(u16, target, selector, args);
}

fn msgSendF64(target: id, selector: SEL, args: anytype) f64 {
    return msgSendTyped(f64, target, selector, args);
}

/// Call objc_msgSend with concrete function pointer types per arity.
/// Avoids @Type (removed in Zig 0.16) by declaring explicit signatures.
inline fn msgSendTyped(comptime Ret: type, target: id, selector: SEL, args: anytype) Ret {
    const base = &objc_msgSend_fn;
    switch (args.len) {
        0 => return @as(*const fn (id, SEL) callconv(.c) Ret, @ptrCast(base))(target, selector),
        1 => return @as(*const fn (id, SEL, @TypeOf(args[0])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0]),
        2 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1]),
        3 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2]),
        4 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3]),
        else => @compileError("msgSendTyped: too many arguments (max 4 extra args supported)"),
    }
}

/// An NSString for a string literal, autoreleased.
fn nsString(lit: [*:0]const u8) id {
    return msgSend(cls("NSString"), sel("stringWithUTF8String:"), .{lit});
}

// ── Cocoa constants ─────────────────────────────────────────────────

const NSWindowStyleMaskTitled: u64 = 1 << 0;
const NSWindowStyleMaskClosable: u64 = 1 << 1;
const NSWindowStyleMaskMiniaturizable: u64 = 1 << 2;
const NSWindowStyleMaskResizable: u64 = 1 << 3;

const NSBackingStoreBuffered: u64 = 2;
const NSApplicationActivationPolicyRegular: i64 = 0;
/// applicationShouldTerminate: reply that keeps AppKit from calling exit().
const NSTerminateCancel: u64 = 0;

const NSEventMaskAny: u64 = std.math.maxInt(u64);

const NSEventTypeLeftMouseDown: u64 = 1;
const NSEventTypeLeftMouseUp: u64 = 2;
const NSEventTypeRightMouseDown: u64 = 3;
const NSEventTypeRightMouseUp: u64 = 4;
const NSEventTypeMouseMoved: u64 = 5;
const NSEventTypeLeftMouseDragged: u64 = 6;
const NSEventTypeRightMouseDragged: u64 = 7;
const NSEventTypeKeyDown: u64 = 10;
const NSEventTypeKeyUp: u64 = 11;
const NSEventTypeFlagsChanged: u64 = 12;
const NSEventTypeScrollWheel: u64 = 22;
const NSEventTypeOtherMouseDown: u64 = 25;
const NSEventTypeOtherMouseUp: u64 = 26;
const NSEventTypeOtherMouseDragged: u64 = 27;

const NSEventModifierFlagCommand: u64 = 1 << 20;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventPhaseBegan: u64 = 1 << 0;

/// NSUTF8StringEncoding / NSISOLatin1StringEncoding
const NSUTF8StringEncoding: u64 = 4;
const NSISOLatin1StringEncoding: u64 = 5;

/// CALayer autoresizing: kCALayerWidthSizable | kCALayerHeightSizable.
const kCALayerSizable: u32 = (1 << 1) | (1 << 4);

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { x: f64, y: f64, width: f64, height: f64 };

// ── Shared types (from platform/types.zig) ──────────────────────────

const types = @import("../types.zig");
pub const KeyEvent = types.KeyEvent;
pub const Event = types.Event;
pub const Size = types.Size;

// ── Delegates ────────────────────────────────────────────────────────
//
// Two small classes built at runtime with objc_allocateClassPair:
//  - the window delegate answers windowShouldClose: with NO and records
//    the request, so the red button ends teru through its normal shutdown
//    (session save, PTY hangup) instead of AppKit closing the window;
//  - the application delegate answers applicationShouldTerminate: with
//    NSTerminateCancel for the same reason. Cmd+Q, Quit in the Dock menu,
//    logout and shutdown all call -[NSApp terminate:], which otherwise
//    ends in exit() without returning here.
// AppKit calls them on the main thread from inside nextEventMatchingMask
// or sendEvent:, so a plain global is enough.

var close_requested: bool = false;

fn windowShouldClose(_: id, _: SEL, _: ?id) callconv(.c) ObjcBool {
    close_requested = true;
    return NO;
}

fn applicationShouldTerminate(_: id, _: SEL, _: ?id) callconv(.c) u64 {
    close_requested = true;
    return NSTerminateCancel;
}

const MethodDef = struct { name: [*:0]const u8, imp: *const anyopaque, encoding: [*:0]const u8 };

/// Find or register an NSObject subclass with the given methods.
fn delegateClass(name: [*:0]const u8, methods: []const MethodDef) ?id {
    if (objc_getClass(name)) |existing| return existing;
    const class = objc_allocateClassPair(objc_getClass("NSObject"), name, 0) orelse return null;
    for (methods) |m| _ = class_addMethod(class, sel(m.name), m.imp, m.encoding);
    objc_registerClassPair(class);
    return class;
}

fn newDelegate(name: [*:0]const u8, methods: []const MethodDef) ?id {
    const class = delegateClass(name, methods) orelse return null;
    return msgSend(msgSend(class, sel("alloc"), .{}), sel("init"), .{});
}

/// The menu bar: an application menu with Hide and Quit, and a Window menu
/// with Minimize. Their key equivalents (Cmd+H, Cmd+Q, Cmd+M) are matched
/// by AppKit against the selected keyboard layout. Must be set before
/// finishLaunching.
fn buildMainMenu(app: id) void {
    const NSMenu = cls("NSMenu");
    const NSMenuItem = cls("NSMenuItem");
    const add = sel("addItemWithTitle:action:keyEquivalent:");

    const bar = msgSend(msgSend(NSMenu, sel("alloc"), .{}), sel("init"), .{});

    const app_item = msgSend(msgSend(NSMenuItem, sel("alloc"), .{}), sel("init"), .{});
    msgSendVoid(bar, sel("addItem:"), .{app_item});
    const app_menu = msgSend(msgSend(NSMenu, sel("alloc"), .{}), sel("initWithTitle:"), .{nsString("teru")});
    _ = msgSend(app_menu, add, .{ nsString("Hide teru"), sel("hide:"), nsString("h") });
    const others = msgSend(app_menu, add, .{ nsString("Hide Others"), sel("hideOtherApplications:"), nsString("h") });
    msgSendVoid(others, sel("setKeyEquivalentModifierMask:"), .{NSEventModifierFlagOption | NSEventModifierFlagCommand});
    _ = msgSend(app_menu, add, .{ nsString("Show All"), sel("unhideAllApplications:"), nsString("") });
    msgSendVoid(app_menu, sel("addItem:"), .{msgSend(NSMenuItem, sel("separatorItem"), .{})});
    _ = msgSend(app_menu, add, .{ nsString("Quit teru"), sel("terminate:"), nsString("q") });
    msgSendVoid(app_item, sel("setSubmenu:"), .{app_menu});

    const win_item = msgSend(msgSend(NSMenuItem, sel("alloc"), .{}), sel("init"), .{});
    msgSendVoid(bar, sel("addItem:"), .{win_item});
    const win_menu = msgSend(msgSend(NSMenu, sel("alloc"), .{}), sel("initWithTitle:"), .{nsString("Window")});
    _ = msgSend(win_menu, add, .{ nsString("Minimize"), sel("performMiniaturize:"), nsString("m") });
    _ = msgSend(win_menu, add, .{ nsString("Zoom"), sel("performZoom:"), nsString("") });
    msgSendVoid(win_item, sel("setSubmenu:"), .{win_menu});

    msgSendVoid(app, sel("setMainMenu:"), .{bar});
    msgSendVoid(app, sel("setWindowsMenu:"), .{win_menu});

    // The menus retain what was added to them.
    msgSendVoid(app_menu, sel("release"), .{});
    msgSendVoid(win_menu, sel("release"), .{});
    msgSendVoid(app_item, sel("release"), .{});
    msgSendVoid(win_item, sel("release"), .{});
    msgSendVoid(bar, sel("release"), .{});
}

/// An NSString for `bytes`, owned by the caller (+1). Invalid UTF-8 is read
/// as Latin-1, which accepts any bytes, so this returns null only when
/// allocation fails. Never builds one from an unterminated slice cast to a
/// C string, which read past the end of the pane title.
fn newNSString(bytes: []const u8) ?id {
    const NSString = cls("NSString");
    const sel_init = sel("initWithBytes:length:encoding:");
    const utf8 = msgSendOpt(msgSend(NSString, sel("alloc"), .{}), sel_init, .{ bytes.ptr, @as(u64, bytes.len), NSUTF8StringEncoding });
    if (utf8) |s| return s;
    return msgSendOpt(msgSend(NSString, sel("alloc"), .{}), sel_init, .{ bytes.ptr, @as(u64, bytes.len), NSISOLatin1StringEncoding });
}

// ── macOS window ────────────────────────────────────────────────────

pub const MacosWindow = struct {
    ns_app: id,
    ns_window: id,
    ns_view: id,
    ns_layer: id,
    window_delegate: ?id,
    /// Content size in backing pixels.
    width: u32,
    height: u32,
    /// View bounds in points.
    pt_width: f64,
    pt_height: f64,
    /// backingScaleFactor: 1, or 2 on Retina.
    scale: u32,
    is_open: bool,
    was_key_window: bool,
    /// The size or scale changed since the last `.resize` was handed out.
    size_dirty: bool = false,
    queue: events.EventQueue = .{},
    scroll: events.ScrollAccumulator = .{},
    /// sRGB, created once.
    color_space: ?*anyopaque,
    /// CGBitmapContext each frame is copied into; rebuilt when the size changes.
    staging: ?*anyopaque = null,
    staging_w: u32 = 0,
    staging_h: u32 = 0,

    /// `width` x `height` is the content size in points: the same physical
    /// size a 1x Linux window of that many pixels has.
    pub fn init(width: u32, height: u32, title: []const u8) !MacosWindow {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Order matters (glfw does the same): activation policy, then the
        // menu bar, then finishLaunching, then the window, then activate.
        const app = msgSend(cls("NSApplication"), sel("sharedApplication"), .{});
        // An unbundled executable gets no Dock icon or keyboard focus
        // without the Regular policy.
        _ = msgSendBool(app, sel("setActivationPolicy:"), .{NSApplicationActivationPolicyRegular});
        buildMainMenu(app);
        const app_delegate = newDelegate("TeruAppDelegate", &.{
            .{ .name = "applicationShouldTerminate:", .imp = @ptrCast(&applicationShouldTerminate), .encoding = "Q@:@" },
        });
        // NSApp does not retain its delegate; this one lives for the process.
        if (app_delegate) |d| msgSendVoid(app, sel("setDelegate:"), .{d});
        msgSendVoid(app, sel("finishLaunching"), .{});

        const rect = CGRect{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(@max(width, 1)),
            .height = @floatFromInt(@max(height, 1)),
        };
        const style_mask = NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable;
        const window = msgSendOpt(msgSend(cls("NSWindow"), sel("alloc"), .{}), sel("initWithContentRect:styleMask:backing:defer:"), .{
            rect,
            style_mask,
            NSBackingStoreBuffered,
            NO,
        }) orelse return error.CreateWindowFailed;

        // A window made in code is released by AppKit when it closes, after
        // which every message to it (the close in deinit) is a use after
        // free. teru owns it instead and releases it in deinit.
        msgSendVoid(window, sel("setReleasedWhenClosed:"), .{NO});
        // Without this, AppKit sends no mouse-moved events (hover, URL
        // highlighting).
        msgSendVoid(window, sel("setAcceptsMouseMovedEvents:"), .{YES});
        msgSendVoid(window, sel("setBackgroundColor:"), .{msgSend(cls("NSColor"), sel("blackColor"), .{})});

        const window_delegate = newDelegate("TeruWindowDelegate", &.{
            .{ .name = "windowShouldClose:", .imp = @ptrCast(&windowShouldClose), .encoding = bool_enc ++ "@:@" },
        });
        if (window_delegate) |d| msgSendVoid(window, sel("setDelegate:"), .{d});

        const view = msgSend(window, sel("contentView"), .{});

        // A layer-hosting view: set the layer first, then wantsLayer. AppKit
        // then never draws over the layer's contents, which is where each
        // frame goes (putFramebuffer). Drawing with lockFocus outside
        // drawRect: shows nothing on a layer-backed view, and every view is
        // layer-backed since macOS 10.14.
        const layer = msgSend(cls("CALayer"), sel("layer"), .{});
        msgSendVoid(layer, sel("setContentsGravity:"), .{kCAGravityTopLeft});
        msgSendVoid(layer, sel("setMagnificationFilter:"), .{kCAFilterNearest});
        msgSendVoid(layer, sel("setMinificationFilter:"), .{kCAFilterNearest});
        msgSendVoid(layer, sel("setOpaque:"), .{YES});
        msgSendVoid(layer, sel("setAutoresizingMask:"), .{kCALayerSizable});
        msgSendVoid(view, sel("setLayer:"), .{layer});
        msgSendVoid(view, sel("setWantsLayer:"), .{YES});

        var self = MacosWindow{
            .ns_app = app,
            .ns_window = window,
            .ns_view = view,
            .ns_layer = layer,
            .window_delegate = window_delegate,
            // What the caller asked for and sized its first frame to. If the
            // real pixel size differs (always, on Retina), the first event
            // is a resize to it.
            .width = width,
            .height = height,
            .pt_width = rect.width,
            .pt_height = rect.height,
            .scale = 1,
            .is_open = true,
            .was_key_window = true,
            .color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB),
        };
        self.setTitle(title);
        self.refreshGeometry();

        msgSendVoid(window, sel("center"), .{});
        msgSendVoid(window, sel("makeKeyAndOrderFront:"), .{@as(?id, null)});
        // macOS 14 replaced activateIgnoringOtherApps: with -activate, which
        // only asks (cooperative activation). Ask both ways: the old call is
        // deprecated but still honoured, and the new one may be refused.
        if (msgSendBool(app, sel("respondsToSelector:"), .{sel("activate")})) {
            msgSendVoid(app, sel("activate"), .{});
        }
        msgSendVoid(app, sel("activateIgnoringOtherApps:"), .{YES});

        return self;
    }

    pub fn setOpacity(self: *MacosWindow, opacity: f32) void {
        if (opacity >= 1.0) return;
        const alpha: f64 = @max(0.0, @min(1.0, @as(f64, opacity)));
        msgSendVoid(self.ns_window, sel("setAlphaValue:"), .{alpha});
    }

    pub fn setTitle(self: *MacosWindow, title: []const u8) void {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        // setTitle: with nil raises an exception, which aborts.
        const s = newNSString(title) orelse return;
        msgSendVoid(self.ns_window, sel("setTitle:"), .{s});
        msgSendVoid(s, sel("release"), .{});
    }

    pub fn deinit(self: *MacosWindow) void {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        msgSendVoid(self.ns_window, sel("setDelegate:"), .{@as(?id, null)});
        msgSendVoid(self.ns_window, sel("close"), .{});
        msgSendVoid(self.ns_window, sel("release"), .{});
        if (self.window_delegate) |d| msgSendVoid(d, sel("release"), .{});
        CGContextRelease(self.staging);
        self.staging = null;
        CGColorSpaceRelease(self.color_space);
        self.color_space = null;
        self.is_open = false;
    }

    pub fn pollEvents(self: *MacosWindow) ?Event {
        if (self.takeEvent()) |e| return e;

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Bounded, so a stream of mouse moves cannot keep teru from drawing.
        var budget: u32 = 64;
        while (true) {
            // Read the size before dequeuing, so the event that comes with
            // a resize is queued behind it instead of replaced by it.
            self.refreshGeometry();
            if (self.takeEvent()) |e| return e;
            if (close_requested) {
                self.is_open = false;
                return .close;
            }
            if (budget == 0) break;
            budget -= 1;

            const event = msgSendOpt(self.ns_app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{
                NSEventMaskAny,
                @as(?id, null), // untilDate: nil = don't block
                NSDefaultRunLoopMode,
                YES,
            }) orelse break;
            self.handleEvent(event);
        }
        return self.checkFocusChange();
    }

    /// Present one frame. `pixels` is `fb_width` x `fb_height` 0xAARRGGBB in
    /// backing pixels.
    pub fn putFramebuffer(self: *MacosWindow, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.width);
        const blit_h = @min(fb_height, self.height);
        if (blit_w == 0 or blit_h == 0) return;
        if (pixels.len < @as(usize, fb_width) * fb_height) return;

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // The renderer reuses (and on resize frees) its buffer, while Core
        // Animation may still read the image after commit. So each frame is
        // copied into a bitmap context, which is allocated only when the
        // size changes; the image snapshot taken from it is copy-on-write.
        if (self.staging == null or self.staging_w != blit_w or self.staging_h != blit_h) {
            CGContextRelease(self.staging);
            self.staging = CGBitmapContextCreate(null, blit_w, blit_h, 8, 0, self.color_space, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
            self.staging_w = blit_w;
            self.staging_h = blit_h;
            if (self.staging == null) {
                std.log.err("macos: CGBitmapContextCreate {d}x{d} failed", .{ blit_w, blit_h });
                self.staging_w = 0;
                self.staging_h = 0;
                return;
            }
        }
        const ctx = self.staging.?;
        const dst = CGBitmapContextGetData(ctx) orelse return;
        const bpr = CGBitmapContextGetBytesPerRow(ctx);
        if (bpr < @as(usize, blit_w) * 4) return;
        for (0..blit_h) |y| {
            const src = std.mem.sliceAsBytes(pixels[y * fb_width ..][0..blit_w]);
            @memcpy(dst[y * bpr ..][0..src.len], src);
        }
        const image = CGBitmapContextCreateImage(ctx) orelse return;
        defer CGImageRelease(image);

        const CATransaction = cls("CATransaction");
        msgSendVoid(CATransaction, sel("begin"), .{});
        // Without this every new frame cross-fades in over 0.25 s.
        msgSendVoid(CATransaction, sel("setDisableActions:"), .{YES});
        // One framebuffer pixel per backing pixel: Core Animation does not
        // set this for a layer it does not manage.
        msgSendVoid(self.ns_layer, sel("setContentsScale:"), .{@as(f64, @floatFromInt(self.scale))});
        msgSendVoid(self.ns_layer, sel("setContents:"), .{@as(id, image)});
        msgSendVoid(CATransaction, sel("commit"), .{});
        // teru's loop does not return to a run loop that commits implicit
        // transactions on its own schedule; push this one out now.
        msgSendVoid(CATransaction, sel("flush"), .{});
    }

    /// Resize the content area to `width` x `height` backing pixels.
    pub fn setSize(self: *MacosWindow, width: u32, height: u32) void {
        const size = NSSize{
            .width = geometry.pointSize(width, self.scale),
            .height = geometry.pointSize(height, self.scale),
        };
        msgSendVoid(self.ns_window, sel("setContentSize:"), .{size});
        self.refreshGeometry();
    }

    pub fn getSize(self: *const MacosWindow) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Hide the pointer until it next moves, as Terminal.app does. NSCursor
    /// hide/unhide are counted and app-wide, so an unbalanced pair would
    /// leave it hidden everywhere.
    pub fn hideCursor(_: *MacosWindow) void {
        msgSendVoid(cls("NSCursor"), sel("setHiddenUntilMouseMoves:"), .{YES});
    }

    /// The pointer comes back by itself when it moves.
    pub fn showCursor(_: *MacosWindow) void {}

    // ── Internal helpers ────────────────────────────────────────────

    fn takeEvent(self: *MacosWindow) ?Event {
        if (self.size_dirty) {
            self.size_dirty = false;
            return .{ .resize = .{ .width = self.width, .height = self.height } };
        }
        return self.queue.take();
    }

    /// Read the view size and backing scale; flag a resize if either moved.
    /// Polling the scale also catches the window being dragged between a
    /// Retina and a 1x display.
    fn refreshGeometry(self: *MacosWindow) void {
        const FnRect = *const fn (id, SEL) callconv(.c) CGRect;
        const bounds = @as(FnRect, @ptrCast(&objc_msgSend_stret_fn))(self.ns_view, sel("bounds"));
        const scale = geometry.scaleFromBacking(msgSendF64(self.ns_window, sel("backingScaleFactor"), .{}));
        const px_w = geometry.pixelSize(bounds.width, scale);
        const px_h = geometry.pixelSize(bounds.height, scale);
        self.pt_width = bounds.width;
        self.pt_height = bounds.height;
        if (px_w == 0 or px_h == 0) return;
        if (px_w != self.width or px_h != self.height or scale != self.scale) {
            self.width = px_w;
            self.height = px_h;
            self.scale = scale;
            self.size_dirty = true;
        }
    }

    fn handleEvent(self: *MacosWindow, event: id) void {
        const event_type = msgSendU64(event, sel("type"), .{});
        switch (event_type) {
            // Keys are translated here and not passed to sendEvent:. The
            // content view does not handle keyDown:, so AppKit would end in
            // noResponderFor:, which beeps on every keystroke.
            NSEventTypeKeyDown => self.onKey(event, true),
            NSEventTypeKeyUp => self.onKey(event, false),
            NSEventTypeFlagsChanged => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                self.onFlagsChanged(event);
            },
            NSEventTypeLeftMouseDown,
            NSEventTypeLeftMouseUp,
            NSEventTypeRightMouseDown,
            NSEventTypeRightMouseUp,
            NSEventTypeMouseMoved,
            NSEventTypeLeftMouseDragged,
            NSEventTypeRightMouseDragged,
            NSEventTypeOtherMouseDown,
            NSEventTypeOtherMouseUp,
            NSEventTypeOtherMouseDragged,
            => {
                // AppKit needs these for the title bar, the window buttons and
                // edge resizing; the content view ignores them.
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                self.onMouse(event, event_type);
            },
            NSEventTypeScrollWheel => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                self.onScroll(event);
            },
            else => msgSendVoid(self.ns_app, sel("sendEvent:"), .{event}),
        }
    }

    fn modifierFlags(event: id) u32 {
        return @truncate(msgSendU64(event, sel("modifierFlags"), .{}));
    }

    fn onKey(self: *MacosWindow, event: id, down: bool) void {
        const raw = modifierFlags(event);
        if (down and raw & NSEventModifierFlagCommand != 0) {
            // Cmd+Q, Cmd+H, Cmd+M: the menu bar's key equivalents, which
            // AppKit matches against the selected layout. Anything the menu
            // does not take is a teru binding (super+... in teru.conf).
            if (msgSendOpt(self.ns_app, sel("mainMenu"), .{})) |menu| {
                if (msgSendBool(menu, sel("performKeyEquivalent:"), .{event})) return;
            }
        }
        const keycode: u32 = msgSendU16(event, sel("keyCode"), .{});
        // The keyboard module reads modifier state from this, not from key
        // events, so it cannot drift from what AppKit reports.
        self.queue.push(.{ .wl_modifiers = .{ .depressed = raw, .latched = 0, .locked = 0, .group = 0 } });
        const key = KeyEvent{ .keycode = keycode, .modifiers = keyboard.x11Modifiers(raw) };
        self.queue.push(if (down) .{ .key_press = key } else .{ .key_release = key });
    }

    /// Modifier keys produce flagsChanged, never keyDown or keyUp.
    fn onFlagsChanged(self: *MacosWindow, event: id) void {
        const raw = modifierFlags(event);
        const keycode: u32 = msgSendU16(event, sel("keyCode"), .{});
        self.queue.push(.{ .wl_modifiers = .{ .depressed = raw, .latched = 0, .locked = 0, .group = 0 } });
        // Caps Lock reports its toggle state in the flags; no press/release,
        // which the keyboard would read as a toggle of its own.
        const pressed = keyboard.modifierTransition(keycode, raw) orelse return;
        const key = KeyEvent{ .keycode = keycode, .modifiers = keyboard.x11Modifiers(raw) };
        self.queue.push(if (pressed) .{ .key_press = key } else .{ .key_release = key });
    }

    fn onMouse(self: *MacosWindow, event: id, event_type: u64) void {
        const Kind = enum { press, release, motion };
        const kind: Kind = switch (event_type) {
            NSEventTypeLeftMouseDown, NSEventTypeRightMouseDown, NSEventTypeOtherMouseDown => .press,
            NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp, NSEventTypeOtherMouseUp => .release,
            else => .motion,
        };
        const button: ?types.MouseButton = switch (event_type) {
            NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp, NSEventTypeLeftMouseDragged => .left,
            NSEventTypeRightMouseDown, NSEventTypeRightMouseUp, NSEventTypeRightMouseDragged => .right,
            NSEventTypeOtherMouseDown, NSEventTypeOtherMouseUp, NSEventTypeOtherMouseDragged => if (msgSendI64(event, sel("buttonNumber"), .{}) == 2) .middle else null,
            else => null, // plain move
        };
        if (kind != .motion and button == null) return; // back/forward buttons

        // A press must land in the view (not the title bar). A release or a
        // drag that left the window is clamped to its edge, so a selection
        // follows the pointer out and still ends when the button comes up.
        const dragging = event_type != NSEventTypeMouseMoved;
        const clamp = kind == .release or (kind == .motion and dragging);
        const px = self.eventPixel(event, clamp) orelse return;
        const mods = keyboard.x11Modifiers(modifierFlags(event));
        switch (kind) {
            .motion => self.queue.push(.{ .mouse_motion = .{ .x = px.x, .y = px.y, .modifiers = mods } }),
            .press, .release => {
                const me = types.MouseEvent{ .x = px.x, .y = px.y, .button = button.?, .modifiers = mods };
                self.queue.push(if (kind == .press) .{ .mouse_press = me } else .{ .mouse_release = me });
            },
        }
    }

    fn onScroll(self: *MacosWindow, event: id) void {
        const dy = msgSendF64(event, sel("scrollingDeltaY"), .{});
        const steps: i32 = if (msgSendBool(event, sel("hasPreciseScrollingDeltas"), .{})) blk: {
            // Trackpad or Magic Mouse: deltas in points, dozens per swipe.
            if (msgSendU64(event, sel("phase"), .{}) & NSEventPhaseBegan != 0) self.scroll.reset();
            break :blk self.scroll.feed(dy);
        } else if (dy > 0) 1 else if (dy < 0) -1 else 0; // a wheel notch
        if (steps == 0) return;
        const px = self.eventPixel(event, false) orelse return;
        const mods = keyboard.x11Modifiers(modifierFlags(event));
        const button: types.MouseButton = if (steps > 0) .scroll_up else .scroll_down;
        for (0..@abs(steps)) |_| {
            self.queue.push(.{ .mouse_press = .{ .x = px.x, .y = px.y, .button = button, .modifiers = mods } });
        }
    }

    /// The event's position as a framebuffer pixel (origin top left).
    fn eventPixel(self: *MacosWindow, event: id, clamp: bool) ?geometry.Pixel {
        const FnLoc = *const fn (id, SEL) callconv(.c) NSPoint;
        const in_window = @as(FnLoc, @ptrCast(&objc_msgSend_fn))(event, sel("locationInWindow"));
        const FnConv = *const fn (id, SEL, NSPoint, ?id) callconv(.c) NSPoint;
        const p = @as(FnConv, @ptrCast(&objc_msgSend_fn))(self.ns_view, sel("convertPoint:fromView:"), in_window, null);
        return geometry.viewPointToPixel(p.x, p.y, self.pt_height, self.scale, self.width, self.height, clamp);
    }

    /// Detect focus changes by comparing [window isKeyWindow] with cached state.
    fn checkFocusChange(self: *MacosWindow) ?Event {
        const is_key = msgSendBool(self.ns_window, sel("isKeyWindow"), .{});
        if (is_key != self.was_key_window) {
            self.was_key_window = is_key;
            return if (is_key) .focus_in else .focus_out;
        }
        return null;
    }
};

// ── Platform wrapper (single-backend, matches linux Platform shape) ─

pub const Platform = union(enum) {
    macos: MacosWindow,

    pub fn init(width: u32, height: u32, title: []const u8, _: ?[]const u8) !Platform {
        return .{ .macos = try MacosWindow.init(width, height, title) };
    }

    pub fn deinit(self: *Platform) void {
        switch (self.*) {
            .macos => |*w| w.deinit(),
        }
    }

    pub fn pollEvents(self: *Platform) ?Event {
        return switch (self.*) {
            .macos => |*w| w.pollEvents(),
        };
    }

    pub fn setOpacity(self: *Platform, opacity: f32) void {
        switch (self.*) {
            .macos => |*w| w.setOpacity(opacity),
        }
    }

    pub fn putFramebuffer(self: *Platform, pixels: []const u32, width: u32, height: u32) void {
        switch (self.*) {
            .macos => |*w| w.putFramebuffer(pixels, width, height),
        }
    }

    pub fn setTitle(self: *Platform, title: []const u8) void {
        switch (self.*) {
            .macos => |*w| w.setTitle(title),
        }
    }

    pub fn hideCursor(self: *Platform) void {
        switch (self.*) {
            .macos => |*w| w.hideCursor(),
        }
    }

    pub fn showCursor(self: *Platform) void {
        switch (self.*) {
            .macos => |*w| w.showCursor(),
        }
    }

    pub fn setSize(self: *Platform, width: u32, height: u32) void {
        switch (self.*) {
            .macos => |*w| w.setSize(width, height),
        }
    }

    pub fn getSize(self: *const Platform) Size {
        return switch (self.*) {
            .macos => |*w| w.getSize(),
        };
    }

    /// Backing pixels per point: 1, or 2 on Retina.
    pub fn contentScale(self: *const Platform) u32 {
        return switch (self.*) {
            .macos => |*w| w.scale,
        };
    }

    pub fn getX11Info(_: *const Platform) ?types.X11Info {
        return null;
    }
};
