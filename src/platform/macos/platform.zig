//! macOS platform backend using Cocoa (AppKit) via Objective-C runtime.
//!
//! Pure C function calls from Zig — no Swift, no Objective-C compiler.
//! Creates an NSApplication + NSWindow, blits CPU framebuffer via
//! NSBitmapImageRep, polls events via nextEventMatchingMask.

const std = @import("std");
const builtin = @import("builtin");

// ── Objective-C runtime (hand-declared, no @cImport) ──────────────────
//
// Zig's C translator cannot handle Objective-C block syntax in
// objc/runtime.h, so we declare the minimal set of externs we need.

const SEL = *opaque {};

extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() callconv(.c) void;
// objc_msgSend_stret only exists on x86_64; arm64 returns structs via registers.
const objc_msgSend_stret_fn = if (builtin.cpu.arch == .x86_64) blk: {
    const f = struct {
        extern "c" fn objc_msgSend_stret() callconv(.c) void;
    };
    break :blk f.objc_msgSend_stret;
} else objc_msgSend;

// ── Objective-C runtime helpers ─────────────────────────────────────

const id = *anyopaque;

// objc_msgSend has variable calling convention depending on return type.
// We cast the function pointer to the signature we need at each call site.
const objc_msgSend_fn = objc_msgSend;

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

fn cls(name: [*:0]const u8) id {
    return @ptrCast(objc_getClass(name) orelse unreachable);
}

/// Typed objc_msgSend wrappers using concrete function pointer types.
/// Avoids @Type (removed in Zig 0.16) by declaring explicit signatures per arity.

fn msgSend(target: id, selector: SEL, args: anytype) id {
    return msgSendTyped(id, target, selector, args);
}

fn msgSendVoid(target: id, selector: SEL, args: anytype) void {
    _ = msgSendTyped(id, target, selector, args);
}

fn msgSendBool(target: id, selector: SEL, args: anytype) bool {
    return msgSendTyped(i8, target, selector, args) != 0;
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
inline fn msgSendTyped(comptime Ret: type, target: id, selector: SEL, args: anytype) Ret {
    const base = &objc_msgSend_fn;
    switch (args.len) {
        0 => return @as(*const fn (id, SEL) callconv(.c) Ret, @ptrCast(base))(target, selector),
        1 => return @as(*const fn (id, SEL, @TypeOf(args[0])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0]),
        2 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1]),
        3 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2]),
        4 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3]),
        5 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4]),
        6 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6]), @TypeOf(args[7])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        9 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6]), @TypeOf(args[7]), @TypeOf(args[8])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8]),
        10 => return @as(*const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6]), @TypeOf(args[7]), @TypeOf(args[8]), @TypeOf(args[9])) callconv(.c) Ret, @ptrCast(base))(target, selector, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9]),
        else => @compileError("msgSendTyped: too many arguments (max 10 extra args supported)"),
    }
}

// ── Cocoa constants ─────────────────────────────────────────────────

/// NSWindowStyleMask values
const NSWindowStyleMaskTitled: u64 = 1 << 0;
const NSWindowStyleMaskClosable: u64 = 1 << 1;
const NSWindowStyleMaskMiniaturizable: u64 = 1 << 2;
const NSWindowStyleMaskResizable: u64 = 1 << 3;

/// NSBackingStoreType
const NSBackingStoreBuffered: u64 = 2;

/// NSEventMask: NSEventMaskAny = max u64
const NSEventMaskAny: u64 = std.math.maxInt(u64);

/// NSEvent types
const NSEventTypeLeftMouseDown: u64 = 1;
const NSEventTypeLeftMouseUp: u64 = 2;
const NSEventTypeRightMouseDown: u64 = 3;
const NSEventTypeRightMouseUp: u64 = 4;
const NSEventTypeMouseMoved: u64 = 5;
const NSEventTypeLeftMouseDragged: u64 = 6;
const NSEventTypeKeyDown: u64 = 10;
const NSEventTypeKeyUp: u64 = 11;
const NSEventTypeFlagsChanged: u64 = 12;
const NSEventTypeAppKitDefined: u64 = 13;
const NSEventTypeScrollWheel: u64 = 22;

/// NSPoint (CGPoint) for locationInWindow return value
const NSPoint = extern struct { x: f64, y: f64 };

/// CGRect (x, y, width, height) as a packed struct for objc_msgSend_stret
const CGRect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

// ── Shared types (from platform/types.zig) ──────────────────────────

const types = @import("../types.zig");
pub const KeyEvent = types.KeyEvent;
pub const Event = types.Event;
pub const Size = types.Size;

// ── macOS window ────────────────────────────────────────────────────

pub const MacosWindow = struct {
    ns_app: id,
    ns_window: id,
    ns_view: id,
    width: u32,
    height: u32,
    is_open: bool,
    was_key_window: bool,

    pub fn init(width: u32, height: u32, title: []const u8) !MacosWindow {
        // 1. [NSApplication sharedApplication]
        const NSApplication = cls("NSApplication");
        const app = msgSend(NSApplication, sel("sharedApplication"), .{});

        // 2. Set activation policy to regular (foreground app)
        //    [app setActivationPolicy:NSApplicationActivationPolicyRegular]
        msgSendVoid(app, sel("setActivationPolicy:"), .{@as(i64, 0)});

        // 3. Create NSWindow
        const NSWindow = cls("NSWindow");
        const alloc_window = msgSend(NSWindow, sel("alloc"), .{});

        const rect = CGRect{
            .x = 100.0,
            .y = 100.0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        const style_mask = NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable;

        // initWithContentRect:styleMask:backing:defer:
        const window = msgSend(alloc_window, sel("initWithContentRect:styleMask:backing:defer:"), .{
            rect,
            style_mask,
            NSBackingStoreBuffered,
            @as(i8, 0), // defer: NO
        });

        // 4. Set title
        const NSString = cls("NSString");
        const title_str = msgSend(NSString, sel("stringWithUTF8String:"), .{
            @as([*:0]const u8, @ptrCast(title.ptr)),
        });
        msgSendVoid(window, sel("setTitle:"), .{title_str});

        // 5. Get content view (default NSView)
        const view = msgSend(window, sel("contentView"), .{});

        // 6. Make window visible
        msgSendVoid(window, sel("makeKeyAndOrderFront:"), .{@as(?id, null)});

        // 7. Activate the app
        msgSendVoid(app, sel("activateIgnoringOtherApps:"), .{@as(i8, 1)});

        // 8. Finish launching
        msgSendVoid(app, sel("finishLaunching"), .{});

        return MacosWindow{
            .ns_app = app,
            .ns_window = window,
            .ns_view = view,
            .width = width,
            .height = height,
            .is_open = true,
            .was_key_window = true, // window starts as key after makeKeyAndOrderFront
        };
    }

    pub fn setOpacity(self: *MacosWindow, opacity: f32) void {
        if (opacity >= 1.0) return;
        const alpha: f64 = @max(0.0, @min(1.0, @as(f64, opacity)));
        _ = msgSendF64(self.ns_window, sel("setAlphaValue:"), .{alpha});
    }

    pub fn setTitle(self: *MacosWindow, title: []const u8) void {
        const NSString = cls("NSString");
        const title_str = msgSend(NSString, sel("stringWithUTF8String:"), .{
            @as([*:0]const u8, @ptrCast(title.ptr)),
        });
        msgSendVoid(self.ns_window, sel("setTitle:"), .{title_str});
    }

    pub fn deinit(self: *MacosWindow) void {
        msgSendVoid(self.ns_window, sel("close"), .{});
        self.is_open = false;
    }

    pub fn pollEvents(self: *MacosWindow) ?Event {
        // [NSApp nextEventMatchingMask:untilDate:inMode:dequeue:]
        const NSDefaultRunLoopMode = msgSend(cls("NSString"), sel("stringWithUTF8String:"), .{
            @as([*:0]const u8, "kCFRunLoopDefaultMode"),
        });

        const event = msgSend(self.ns_app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{
            NSEventMaskAny,
            @as(?id, null), // untilDate: nil (don't block)
            NSDefaultRunLoopMode,
            @as(i8, 1), // dequeue: YES
        });

        // Check if event is nil (objc nil = null pointer)
        const event_ptr: ?*anyopaque = event;
        if (event_ptr == null) {
            // No event — still check for focus changes
            return self.checkFocusChange();
        }

        // Get event type: [event type]
        const event_type = msgSendU64(event, sel("type"), .{});

        // Check for window resize by querying current frame
        const view_frame = self.getViewFrame();
        const new_w: u32 = @intFromFloat(view_frame.width);
        const new_h: u32 = @intFromFloat(view_frame.height);
        if (new_w != self.width or new_h != self.height) {
            self.width = new_w;
            self.height = new_h;
            // Still forward the event to the app so Cocoa handles it
            msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
            return .{ .resize = .{ .width = new_w, .height = new_h } };
        }

        switch (event_type) {
            NSEventTypeKeyDown => {
                const keycode = msgSendU16(event, sel("keyCode"), .{});
                const modflags = msgSendU64(event, sel("modifierFlags"), .{});
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return .{ .key_press = .{
                    .keycode = @intCast(keycode),
                    .modifiers = @truncate(modflags),
                } };
            },
            NSEventTypeKeyUp => {
                const keycode = msgSendU16(event, sel("keyCode"), .{});
                const modflags = msgSendU64(event, sel("modifierFlags"), .{});
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return .{ .key_release = .{
                    .keycode = @intCast(keycode),
                    .modifiers = @truncate(modflags),
                } };
            },

            // ── Mouse press events ─────────────────────────────────
            NSEventTypeLeftMouseDown => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return self.mouseEvent(event, .left, true);
            },
            NSEventTypeRightMouseDown => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return self.mouseEvent(event, .right, true);
            },

            // ── Mouse release events ──────────────────────────────
            NSEventTypeLeftMouseUp => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return self.mouseEvent(event, .left, false);
            },
            NSEventTypeRightMouseUp => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                return self.mouseEvent(event, .right, false);
            },

            // ── Mouse motion (move + drag) ────────────────────────
            NSEventTypeMouseMoved, NSEventTypeLeftMouseDragged => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                const loc = self.getEventLocation(event);
                if (loc) |pt| {
                    const modflags = msgSendU64(event, sel("modifierFlags"), .{});
                    return .{ .mouse_motion = .{
                        .x = pt.x,
                        .y = pt.y,
                        .modifiers = @truncate(modflags),
                    } };
                }
                return .none;
            },

            // ── Scroll wheel ──────────────────────────────────────
            NSEventTypeScrollWheel => {
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});
                const delta_y = msgSendF64(event, sel("scrollingDeltaY"), .{});
                if (delta_y == 0.0) return .none;
                const loc = self.getEventLocation(event);
                if (loc) |pt| {
                    const modflags = msgSendU64(event, sel("modifierFlags"), .{});
                    const button: types.MouseButton = if (delta_y > 0.0) .scroll_up else .scroll_down;
                    return .{ .mouse_press = .{
                        .x = pt.x,
                        .y = pt.y,
                        .button = button,
                        .modifiers = @truncate(modflags),
                    } };
                }
                return .none;
            },

            else => {
                // Forward unhandled events to the application
                msgSendVoid(self.ns_app, sel("sendEvent:"), .{event});

                // Check if window was closed
                if (!msgSendBool(self.ns_window, sel("isVisible"), .{})) {
                    self.is_open = false;
                    return .close;
                }

                // Check for focus changes after forwarding
                if (self.checkFocusChange()) |focus_event| return focus_event;

                return .none;
            },
        }
    }

    pub fn putFramebuffer(self: *MacosWindow, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.width);
        const blit_h = @min(fb_height, self.height);
        if (blit_w == 0 or blit_h == 0) return;

        // Create NSBitmapImageRep with the pixel data.
        // Pixels are ARGB (u32 = 0xAARRGGBB), 8 bits per component, 32 bits per pixel.
        const NSBitmapImageRep = cls("NSBitmapImageRep");
        const alloc_rep = msgSend(NSBitmapImageRep, sel("alloc"), .{});

        // initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:
        //   samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:
        //   bytesPerRow:bitsPerPixel:
        const NSDeviceRGBColorSpace = msgSend(cls("NSString"), sel("stringWithUTF8String:"), .{
            @as([*:0]const u8, "NSDeviceRGBColorSpace"),
        });
        const data_ptr: [*]const u8 = @ptrCast(pixels.ptr);
        var planes: [1][*]const u8 = .{data_ptr};

        const bitmap = msgSend(alloc_rep, sel("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:"), .{
            @as([*][*]const u8, &planes), // planes
            @as(i64, @intCast(blit_w)), // pixelsWide
            @as(i64, @intCast(blit_h)), // pixelsHigh
            @as(i64, 8), // bitsPerSample
            @as(i64, 4), // samplesPerPixel (RGBA)
            @as(i8, 1), // hasAlpha: YES
            @as(i8, 0), // isPlanar: NO
            NSDeviceRGBColorSpace,
            @as(i64, @intCast(fb_width * 4)), // bytesPerRow
            @as(i64, 32), // bitsPerPixel
        });

        // Create NSImage and add the rep
        const NSImage = cls("NSImage");
        const alloc_image = msgSend(NSImage, sel("alloc"), .{});
        const size = CGRect{ .x = 0, .y = 0, .width = @floatFromInt(blit_w), .height = @floatFromInt(blit_h) };
        _ = size;

        // Use initWithSize: then addRepresentation:
        const img_size_sel = sel("initWithSize:");
        const NSSize = extern struct { width: f64, height: f64 };
        const img_size = NSSize{ .width = @floatFromInt(blit_w), .height = @floatFromInt(blit_h) };

        const FnInitSize = *const fn (id, SEL, NSSize) callconv(.c) id;
        const init_size_fn: FnInitSize = @ptrCast(&objc_msgSend_fn);
        const image = init_size_fn(alloc_image, img_size_sel, img_size);

        msgSendVoid(image, sel("addRepresentation:"), .{bitmap});

        // Draw to the view: lock focus, composite, unlock
        msgSendVoid(self.ns_view, sel("lockFocus"), .{});

        // [image drawAtPoint:NSZeroPoint fromRect:NSZeroRect
        //         operation:NSCompositingOperationCopy fraction:1.0]
        const zero_point = NSPoint{ .x = 0.0, .y = 0.0 };
        const zero_rect = CGRect{ .x = 0.0, .y = 0.0, .width = 0.0, .height = 0.0 };

        const FnDraw = *const fn (id, SEL, NSPoint, CGRect, u64, f64) callconv(.c) void;
        const draw_fn: FnDraw = @ptrCast(&objc_msgSend_fn);
        draw_fn(image, sel("drawAtPoint:fromRect:operation:fraction:"), zero_point, zero_rect, 1, // NSCompositingOperationCopy
            1.0);

        msgSendVoid(self.ns_view, sel("unlockFocus"), .{});

        // Flush the window
        msgSendVoid(self.ns_window, sel("flushWindow"), .{});

        // Release
        msgSendVoid(bitmap, sel("release"), .{});
        msgSendVoid(image, sel("release"), .{});
    }

    pub fn setSize(self: *MacosWindow, width: u32, height: u32) void {
        const frame = self.getViewFrame();
        const new_rect = CGRect{
            .x = frame.x,
            .y = frame.y,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        const FnSetFrame = *const fn (id, SEL, CGRect, i8) callconv(.c) void;
        const set_fn: FnSetFrame = @ptrCast(&objc_msgSend_fn);
        set_fn(self.ns_window, sel("setFrame:display:"), new_rect, 1);
        self.width = width;
        self.height = height;
    }

    pub fn getSize(self: *const MacosWindow) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn hideCursor(_: *MacosWindow) void {
        msgSendVoid(cls("NSCursor"), sel("hide"), .{});
    }

    pub fn showCursor(_: *MacosWindow) void {
        msgSendVoid(cls("NSCursor"), sel("unhide"), .{});
    }

    // ── Internal helpers ────────────────────────────────────────────

    /// Convert an NSEvent with a button into a mouse_press or mouse_release Event.
    fn mouseEvent(self: *MacosWindow, event: id, button: types.MouseButton, is_press: bool) Event {
        const loc = self.getEventLocation(event);
        if (loc) |pt| {
            const modflags = msgSendU64(event, sel("modifierFlags"), .{});
            const me = types.MouseEvent{
                .x = pt.x,
                .y = pt.y,
                .button = button,
                .modifiers = @truncate(modflags),
            };
            return if (is_press) .{ .mouse_press = me } else .{ .mouse_release = me };
        }
        return .none;
    }

    /// Get event location converted from Cocoa bottom-left origin to top-left origin.
    /// Returns null if coordinates are outside the window bounds.
    fn getEventLocation(self: *MacosWindow, event: id) ?struct { x: u32, y: u32 } {
        // [event locationInWindow] returns NSPoint (two f64s).
        // On arm64 (Apple Silicon), small structs are returned in registers via objc_msgSend.
        // On x86_64, NSPoint (16 bytes) is returned in registers (not stret).
        const FnLoc = *const fn (id, SEL) callconv(.c) NSPoint;
        const loc_fn: FnLoc = @ptrCast(&objc_msgSend_fn);
        const loc = loc_fn(event, sel("locationInWindow"));

        // Convert from Cocoa coordinates (origin bottom-left) to top-left origin
        const screen_y = @as(f64, @floatFromInt(self.height)) - loc.y;

        // Clamp to window bounds — events outside the view (e.g. title bar) are ignored
        if (loc.x < 0.0 or screen_y < 0.0) return null;
        const px: u32 = @intFromFloat(loc.x);
        const py: u32 = @intFromFloat(screen_y);
        if (px >= self.width or py >= self.height) return null;

        return .{ .x = px, .y = py };
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

    fn getViewFrame(self: *MacosWindow) CGRect {
        // [self.ns_view frame] returns CGRect — a large struct, needs stret on x86_64.
        // On arm64 (Apple Silicon), stret is not used.
        const FnFrame = *const fn (id, SEL) callconv(.c) CGRect;
        const frame_fn: FnFrame = @ptrCast(&objc_msgSend_stret_fn);
        return frame_fn(self.ns_view, sel("frame"));
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
            .macos => |*w| .{ .width = w.width, .height = w.height },
        };
    }

    pub fn getX11Info(_: *const Platform) ?types.X11Info {
        return null;
    }
};
