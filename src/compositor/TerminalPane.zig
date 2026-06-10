//! Terminal pane for the miozu compositor.
//!
//! Wraps a libteru Pane (PTY + Grid + VtParser) with a SoftwareRenderer
//! and a wlr_scene_buffer. Each terminal pane is an independent scene node
//! that the compositor tiles alongside Wayland client windows.
//!
//! Rendering is zero-copy: SoftwareRenderer writes ARGB pixels directly
//! into a wlr_buffer. On each frame, if the grid is dirty, we re-render
//! and tell wlroots the buffer changed. No intermediate copies.

const std = @import("std");
const teru = @import("teru");
const Pane = teru.Pane;
const Grid = teru.Grid;
const SoftwareRenderer = teru.render.SoftwareRenderer;
const FontAtlas = teru.render.FontAtlas;
const Selection = teru.Selection;
const MouseState = teru.mouse.MouseState;
const compat = teru.compat;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const TerminalPane = @This();

/// Safety valve for DEC private mode 2026 (synchronized output). When an
/// app opens a sync batch and never closes it (buggy client, crashed
/// mid-paint), we fall through after this many milliseconds so the pane
/// isn't frozen. Matches Alacritty's published default.
const sync_output_timeout_ms: u64 = 150;

server: *Server,
pane: Pane,
renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
node_id: u64,
event_source: ?*wlr.wl_event_source = null,
read_buf: [8192]u8 = undefined,
// Smooth-scroll animation state (ServerCursor.tickScrollAnim eases the live
// scroll position toward this pixel target over frames). target_px is an
// absolute scrollback offset in pixels (scroll_offset*cell_h + scroll_pixel).
scroll_anim_active: bool = false,
scroll_anim_target_px: i64 = 0,
// Sub-pixel carry for touchpad/continuous scroll (Pane.fractionalScrollStep):
// lets slow scrolling move smoothly and near-rest sensor noise cancel out
// instead of jittering ±1px.
scroll_frac_px: f64 = 0,
// Per-pane font zoom (Alt+scroll over THIS pane). 0 = follow the server's
// base size via the shared atlas. Non-zero = this pane owns `zoom_atlas`,
// rasterized at `pane_font_size`, so zooming one pane never re-rasterizes
// the whole compositor (no bars/other-panes scaling, no per-tick lag).
pane_font_size: u16 = 0,
zoom_atlas: ?*FontAtlas = null,
// Monotonic ns when the pane first observed pane.vt.sync_output = true
// for the current DEC-2026 batch. 0 means "not currently in a batch".
// Used to timeout pathological apps that open a sync batch and never
// close it — the renderer falls through after 150 ms to avoid a
// frozen-pane look.
sync_started_ns: i128 = 0,

/// Set by poll() when VtParser.sync_flushed was true after a PTY read
/// cycle — the app closed its DEC-2026 batch (even if it re-opened it
/// in the same write). Read and cleared by renderIfDirty to skip the
/// sync-hold timeout and render immediately.
sync_flushed: bool = false,

// Mouse-driven text selection state. Populated by
// ServerCursor.processCursorButton / processCursorMotion when the
// cursor is over this pane's scene_buffer — teruwm-native panes
// aren't Wayland clients, so wlr_seat_pointer_notify_button has no
// effect on them and we have to do the selection bookkeeping here
// ourselves. renderIfDirty consults selection.active and paints a
// highlight overlay via SoftwareRenderer.renderDirtyWithSelection.
selection: Selection = .{},
mouse: MouseState = .{},

// ── Construction ───────────────────────────────────────────────

/// Common init: creates Pane + SoftwareRenderer + wlr_scene_buffer.
/// Does NOT register with workspace or node registry — callers do that.
fn init(server: *Server, rows: u16, cols: u16) ?*TerminalPane {
    return initWithSpawn(server, rows, cols, server.spawn_config);
}

/// Same as init() but with an explicit SpawnConfig — used by session
/// restore to spawn each pane in its saved cwd running its saved cmd.
fn initWithSpawn(server: *Server, rows: u16, cols: u16, spawn_config: Pane.SpawnConfig) ?*TerminalPane {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    // Buffer = grid + 2*padding so the renderer can inset the text by the
    // configured margin (filled with scheme.bg) exactly like windowed teru.
    const pad = server.terminal_padding;
    const pixel_w: u32 = @as(u32, cols) * cell_w + pad * 2;
    const pixel_h: u32 = @as(u32, rows) * cell_h + pad * 2;

    // Resources acquired in order: pixel_buffer → scene_buffer → pane →
    // renderer → tp. Anything that fails after must roll back everything
    // before it. A plain `orelse return null` leaks; use labelled blocks
    // so each fallible step frees its predecessors explicitly.
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;

    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var pane = Pane.init(allocator, rows, cols, server.next_node_id, spawn_config) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var renderer = SoftwareRenderer.initWithScheme(allocator, pixel_w, pixel_h, cell_w, cell_h, server.color_scheme) catch {
        pane.deinit(allocator);
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    renderer.padding = pad; // content margin, same key/meaning as windowed teru

    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, pixel_w) * @as(usize, pixel_h);
        if (needed > 0) {
            // Adopt the wlr buffer's memory as the framebuffer; free the one
            // initWithScheme just allocated, else it's orphaned for the pane's
            // whole life (~1 MB/pane leak — the renderer's deinit is never
            // called once it points at borrowed wlr memory).
            allocator.free(renderer.framebuffer);
            renderer.framebuffer = data[0..needed];
        }
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }
    // Bold/italic variants (fall back to the regular atlas when unset).
    if (server.font_variant_bold) |v| renderer.glyph_atlas_bold = v.data;
    if (server.font_variant_italic) |v| renderer.glyph_atlas_italic = v.data;
    if (server.font_variant_bold_italic) |v| renderer.glyph_atlas_bold_italic = v.data;

    const tp = allocator.create(TerminalPane) catch {
        pane.deinit(allocator);
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    const node_id = server.next_node_id;
    server.next_node_id += 1;

    tp.* = .{
        .server = server,
        .pane = pane,
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .node_id = node_id,
    };

    tp.pane.linkVt(allocator);

    // Register PTY fd with wlroots event loop
    if (tp.getPtyFd()) |fd| {
        if (wlr.wl_display_get_event_loop(server.display)) |event_loop| {
            tp.event_source = wlr.wl_event_loop_add_fd(event_loop, fd, wlr.WL_EVENT_READABLE, ptyReadable, @ptrCast(tp));
        }
    }

    // Pane index — centralised here so every creation path
    // (createWithSpawn, createFloating, createRestored) gets it for
    // free. Server.terminalPaneById(nid) returns this pointer; missing
    // registration silently no-ops scratchpad hide/show (v0.6.4 bug).
    server.pane_index.put(server.zig_allocator, tp.node_id, tp) catch {};

    return tp;
}

/// Create a tiled terminal pane on the given workspace.
/// NOTE: caller MUST add the returned pane to server.terminal_panes[]
/// BEFORE calling arrangeworkspace(), otherwise the pane can't be
/// found for resize/positioning.
pub fn create(server: *Server, ws: u8, rows: u16, cols: u16) ?*TerminalPane {
    return createWithSpawn(server, ws, rows, cols, server.spawn_config);
}

/// Create a tiled pane with an explicit SpawnConfig (shell, cwd). Used
/// by session restore so each pane re-spawns in its saved cwd.
pub fn createWithSpawn(server: *Server, ws: u8, rows: u16, cols: u16, spawn_config: Pane.SpawnConfig) ?*TerminalPane {
    const tp = initWithSpawn(server, rows, cols, spawn_config) orelse return null;

    const slot = server.nodes.addTerminal(server.zig_allocator, tp.node_id, ws);
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, tp.node_id) catch return null;

    // Auto-name: "term-{ws}-{id}"
    if (slot) |s| {
        var name_buf: [32]u8 = undefined;
        const auto_name = std.fmt.bufPrint(&name_buf, "term-{d}-{d}", .{ ws, tp.node_id }) catch "term";
        server.nodes.setName(s, auto_name);
    }

    std.log.scoped(.pty).info("terminal pane node={d} ws={d} ({d}x{d})", .{ tp.node_id, ws, cols, rows });

    tp.render();
    return tp;
}

/// Create a terminal pane from a restored Pane (compositor restart).
/// The Pane already has an attached PTY fd with a running shell.
pub fn createRestored(server: *Server, ws: u8, pane: *Pane) ?*TerminalPane {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const pad = server.terminal_padding;
    const pixel_w: u32 = @as(u32, pane.grid.cols) * cell_w + pad * 2;
    const pixel_h: u32 = @as(u32, pane.grid.rows) * cell_h + pad * 2;

    // Same unwind order as initWithSpawn. Pane is caller-owned, not
    // freed on failure here — the caller passes us a pre-attached Pane
    // during hot-restart.
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;

    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var renderer = SoftwareRenderer.initWithScheme(allocator, pixel_w, pixel_h, cell_w, cell_h, server.color_scheme) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    renderer.padding = pad; // content margin, same key/meaning as windowed teru
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, pixel_w) * @as(usize, pixel_h);
        if (needed > 0) {
            // Adopt the wlr buffer's memory as the framebuffer; free the one
            // initWithScheme just allocated, else it's orphaned for the pane's
            // whole life (~1 MB/pane leak — the renderer's deinit is never
            // called once it points at borrowed wlr memory).
            allocator.free(renderer.framebuffer);
            renderer.framebuffer = data[0..needed];
        }
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }
    if (server.font_variant_bold) |v| renderer.glyph_atlas_bold = v.data;
    if (server.font_variant_italic) |v| renderer.glyph_atlas_italic = v.data;
    if (server.font_variant_bold_italic) |v| renderer.glyph_atlas_bold_italic = v.data;

    const tp = allocator.create(TerminalPane) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    tp.* = .{
        .server = server,
        .pane = pane.*,
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .node_id = pane.id,
    };

    tp.pane.linkVt(allocator);

    // Register PTY fd with wlroots event loop
    if (tp.getPtyFd()) |fd| {
        if (wlr.wl_display_get_event_loop(server.display)) |event_loop| {
            tp.event_source = wlr.wl_event_loop_add_fd(event_loop, fd, wlr.WL_EVENT_READABLE, ptyReadable, @ptrCast(tp));
        }
    }

    // Register with node registry and workspace
    const slot = server.nodes.addTerminal(server.zig_allocator, tp.node_id, ws);
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, tp.node_id) catch {};

    // Auto-name restored pane
    if (slot) |s| {
        var name_buf: [32]u8 = undefined;
        const auto_name = std.fmt.bufPrint(&name_buf, "term-{d}-{d}", .{ ws, tp.node_id }) catch "term";
        server.nodes.setName(s, auto_name);
    }

    // Add to terminal_panes array.
    for (server.terminal_panes, 0..) |maybe, i| {
        if (maybe == null) {
            server.terminal_panes[i] = tp;
            server.terminal_count += 1;
            break;
        }
    }

    // pane_index registration: this path does NOT go through initWithSpawn
    // (it builds tp inline above), so unlike create*/createFloating it must
    // register here. Without it, terminalPaneById() returns null for every
    // hot-restart-restored pane, silently breaking visibility recompute,
    // cursor drag/resize and scratchpad toggle (the v0.6.4 bug class).
    server.pane_index.put(server.zig_allocator, tp.node_id, tp) catch {};

    tp.render();
    return tp;
}

/// Create a floating terminal pane (scratchpads — not part of workspace tiling).
/// `initWithSpawn` registers the pane in server.pane_index so
/// Server.terminalPaneById resolves its node_id — this was broken in
/// v0.6.4 when registration only lived in the tiled path, causing
/// scratchpad hide/show to silently no-op. Pass `.{}` for the default
/// shell-spawn, or a populated SpawnConfig to run `htop`, `$EDITOR`,
/// etc. (threaded through from `[scratchpad.NAME] cmd = …`).
pub fn createFloating(server: *Server, rows: u16, cols: u16, spawn_config: Pane.SpawnConfig) ?*TerminalPane {
    const tp = initWithSpawn(server, rows, cols, spawn_config) orelse return null;
    tp.render();
    return tp;
}

// ── I/O ────────────────────────────────────────────────────────

/// Read PTY output. Does NOT render — rendering happens in the frame callback
/// to coalesce multiple PTY reads into a single render per vsync.
/// Read PTY data with throttling. Processes up to max_reads_per_tick chunks
/// to prevent heavy output (e.g., Claude AI streaming) from starving mouse/keyboard.
pub fn poll(self: *TerminalPane) bool {
    const max_reads_per_tick = 4; // 4 * 8KB = 32KB max per event loop tick
    var any = false;
    for (0..max_reads_per_tick) |_| {
        const n = self.pane.readAndProcess(&self.read_buf) catch return any;
        if (n == 0) break;
        // Capture sync flush signal from VtParser before the next read
        // overwrites it. The app may have closed the DEC-2026 batch
        // (ESC[?2026l) and immediately re-opened it (ESC[?2026h) in the
        // same PTY write — the final state is "open" but the flush
        // intent is on every close. Picking this up lets renderIfDirty
        // skip the 150 ms hold for keystroke-granular updates.
        if (self.pane.vt.sync_flushed) {
            self.sync_flushed = true;
            self.pane.vt.sync_flushed = false;
        }
        self.server.perf.recordPtyRead(n);
        any = true;
    }
    return any;
}

/// Incremental render if the grid has pending changes. Called from the frame callback.
/// Only re-renders dirty rows + cursor rows, not the entire grid.
pub fn renderIfDirty(self: *TerminalPane) bool {
    if (!self.pane.grid.dirty) return false;

    // DEC private mode 2026 — synchronized output batch. When the
    // application has opened a batch (ESC[?2026h) and hasn't closed it
    // yet (ESC[?2026l), hold the render. Claude Code + Ink apps +
    // fzf + ratatui rely on this: they paint the next screen state in
    // multiple writes and expect terminals to commit atomically.
    // Without this skip, every intermediate paint lands on screen and
    // the user sees a rapid scroll from top to bottom as the app's UI
    // rebuilds row-by-row. windowed.zig honours this already; the
    // compositor path had regressed since the module split.
    //
    // If the app closed the sync batch (ESC[?2026l) at any point since
    // our last render — even if it immediately re-opened it with
    // ESC[?2026h in the same PTY write — poll() caught the flush signal
    // and set sync_flushed. Render immediately; the app intended this
    // data to be visible. Without this, every keystroke in an app that
    // keeps a perpetual batch (like many TUIs) lands with a 150 ms delay
    // because the final sync_output state after the read is "open".
    //
    // Safety valve: if an app enters the sync batch and never exits,
    // fall through after `sync_output_timeout_ms` so the pane isn't
    // frozen forever. See the constant's docstring.
    if (self.pane.vt.sync_output and !self.sync_flushed) {
        const now = compat.monotonicNow();
        if (self.sync_started_ns == 0) self.sync_started_ns = now;
        if (now - self.sync_started_ns < sync_output_timeout_ms * std.time.ns_per_ms) return false;
        // Timed out — let the frame render below and reset tracker.
        self.sync_started_ns = 0;
    } else {
        self.sync_started_ns = 0;
    }
    self.sync_flushed = false;

    // Capture dirty range BEFORE renderDirty resets it. Convert
    // grid rows → pixel Y via cell_height. If the range is empty
    // (min > max sentinel, see Grid.clearDirty) fall back to full
    // damage — the renderer treats that as "paint everything".
    const grid = &self.pane.grid;
    // When scrolled into the scrollback, the overlay shifts the whole frame —
    // a partial (dirty-row) repaint would tear it. Force a full repaint so the
    // overlay always lands on a complete frame (full damage via inverted range).
    if (self.pane.scroll_offset > 0) grid.markAllDirty();
    // Full-buffer damage (dirty_y0 < 0). Per-row partial damage (the perf opt in
    // commit 738d0d4) HALF-RENDERS native panes on the GLES/nvidia path: wlroots'
    // partial texture re-upload of our reused data-ptr buffer only covers roughly
    // the top of each dirty row, leaving the bottom of the glyphs stale. Verified:
    // pixman renders the partial band fine, gles2 truncates it to ~half — so it
    // never reproduced in the headless pixman tests, only on the real GPU.
    // renderDirtyWithSelection below still re-paints ONLY the dirty rows, so CPU
    // stays cheap; we just always present full damage so the GPU re-uploads the
    // whole pane. (Revisit with buffer double-buffering if upload cost ever bites.)
    const dirty_y0: c_int = -1;
    const dirty_y1: c_int = -1;

    // Render the dirty range with selection overlay applied per-cell.
    // `terminalMouseMotion` / `terminalMousePress` in ServerCursor now
    // mark only the rows whose selection-bg state actually changed
    // (prev-end, new-end, and start — one to three rows per motion
    // tick for a typical drag). The earlier `markAllDirty` here was a
    // sledgehammer that re-painted the full grid every frame a
    // selection was active — sustained drag hit 4.46 % teruwm CPU.
    const sel_ptr: ?*const Selection = if (self.selection.active) &self.selection else null;
    const so: u32 = self.pane.scroll_offset;
    const sbl: u32 = if (grid.scrollback) |sb| @intCast(sb.lineCount()) else 0;
    // Honour DECTCEM (ESC[?25l) and focus: the focused pane draws a SOLID cursor,
    // unfocused panes a HOLLOW outline — so two visible panes don't both look
    // active. (repaintBorderOnly re-applies cursor_focused + repaints the cursor
    // cell on focus flips, which the old border-only paint skipped.)
    // Hide the live cursor while scrolled back — it belongs to the bottom
    // (live) row, not the historical viewport the user is looking at.
    self.renderer.cursor_visible = self.pane.vt.cursor_visible and self.pane.scroll_offset == 0;
    self.renderer.cursor_focused = (self.server.focused_terminal == self);
    self.renderer.renderDirtyWithSelection(grid, sel_ptr, so, sbl);
    self.applyScrollOverlay();

    const border: c_int = if (self.shouldDrawBorder()) blk: {
        const border_color = self.borderColor();
        self.drawBorder(border_color);
        break :blk 2; // drawBorder paints a 2-px perimeter.
    } else 0;

    wlr.miozu_scene_buffer_commit_dirty(
        self.scene_buffer,
        self.pixel_buffer,
        @intCast(self.renderer.width),
        @intCast(self.renderer.height),
        dirty_y0,
        dirty_y1,
        border,
    );
    return true;
}

/// Repaint the border only (no grid rerender) and commit.
/// Called on focus state flip — the previous + new focused pane's
/// border colour changes but the cells haven't; a full `render()`
/// here was re-SIMD-blitting thousands of cells for nothing.
pub fn repaintBorderOnly(self: *TerminalPane) void {
    // Focus changed: re-apply the cursor's focus style (solid↔hollow) and repaint
    // its row, plus the border. This used to be border-only, which left an
    // unfocused pane still showing a SOLID 'active' cursor (the deferred follow-up
    // noted in renderIfDirty). The cursor row is one cell tall — far cheaper than
    // a full re-blit, so the original perf intent holds.
    self.renderer.cursor_focused = (self.server.focused_terminal == self);
    const grid = &self.pane.grid;
    grid.markRowDirty(grid.cursor_row);
    self.renderer.renderDirty(grid); // repaints the cursor row + cursor in the new style

    const has_border = self.shouldDrawBorder();
    if (has_border) self.drawBorder(self.borderColor());
    // Full-buffer damage: a partial (cursor-row) band half-renders on the GLES
    // path (same root cause as renderIfDirty). Only the cursor row was
    // re-rendered, so CPU stays cheap; full damage just re-uploads the pane.
    wlr.miozu_scene_buffer_commit_dirty(
        self.scene_buffer,
        self.pixel_buffer,
        @intCast(self.renderer.width),
        @intCast(self.renderer.height),
        -1,
        -1,
        0,
    );
}

/// Write input to the terminal's PTY.
/// Jump the scrollback view back to the live bottom. Called when the user
/// types or pastes (scroll_to_bottom_on_input) — the same reflex every
/// terminal has: you're interacting, so show the prompt. No-op if already at
/// the bottom. Does NOT run for scroll keybinds (those never write to the PTY).
pub fn snapToBottom(self: *TerminalPane) void {
    if (self.pane.scroll_offset == 0 and self.pane.scroll_pixel == 0) return;
    self.pane.scroll_offset = 0;
    self.pane.scroll_pixel = 0;
    self.scroll_frac_px = 0;
    self.scroll_anim_active = false;
    self.pane.grid.markAllDirty();
}

pub fn writeInput(self: *TerminalPane, data: []const u8) void {
    if (self.server.wm_config.scroll_to_bottom_on_input) self.snapToBottom();
    _ = self.pane.ptyWrite(data) catch {};
    // Reset the per-vsync edge-trigger fallback counter so the next few
    // frames poll every PTY for the imminent shell echo. After ~4 frames
    // of silence the fallback drops to one poll per 16 frames (safety net).
    self.server.frames_since_pty_input = 0;
    // Ensure a frame fires so the frame callback polls for the echo
    // and renders the updated grid. The PTY fd event (edge-triggered
    // epoll) can miss data races; the vsync poll is the fallback.
    self.server.scheduleRender();
}

/// Get the PTY master fd for polling.
pub fn getPtyFd(self: *TerminalPane) ?i32 {
    return switch (self.pane.backend) {
        .local => |p| p.master,
        .remote => null,
    };
}

// ── Rendering ──────────────────────────────────────────────────

/// Resize the terminal pane to fit the given pixel rect.
pub fn resize(self: *TerminalPane, pixel_w: u32, pixel_h: u32) void {
    const cell_w = self.renderer.cell_width;
    const cell_h = self.renderer.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    // Grid cells must be integer counts, but the framebuffer itself should
    // fill the FULL allocated pixel rect — otherwise the leftover pixels
    // (< one cell) contribute to gap-asymmetry between panes. The grid is
    // inset by `padding` on all sides (content margin), so subtract 2*pad
    // before dividing into cells; the renderer fills the margin with scheme.bg.
    const pad = self.renderer.padding;
    const new_cols: u16 = @intCast(@max(1, (pixel_w -| pad * 2) / cell_w));
    const new_rows: u16 = @intCast(@max(1, (pixel_h -| pad * 2) / cell_h));
    const fb_w = pixel_w;
    const fb_h = pixel_h;

    // Skip resize if dimensions haven't changed
    if (fb_w == self.renderer.width and fb_h == self.renderer.height) return;

    // Skip unreasonable sizes
    if (fb_w == 0 or fb_h == 0 or fb_w > 8192 or fb_h > 8192) return;

    // Detach old buffer from scene before resizing (prevents stale references)
    wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, null);

    if (!wlr.miozu_pixel_buffer_resize(self.pixel_buffer, @intCast(fb_w), @intCast(fb_h))) return;

    const data = wlr.miozu_pixel_buffer_data(self.pixel_buffer) orelse return;
    const needed = @as(usize, fb_w) * @as(usize, fb_h);
    if (needed == 0) return;

    // Update renderer ATOMICALLY — all three must be consistent
    self.renderer.framebuffer = data[0..needed];
    self.renderer.width = fb_w;
    self.renderer.height = fb_h;

    self.pane.resize(self.server.zig_allocator, new_rows, new_cols) catch return;
    wlr.wlr_scene_buffer_set_dest_size(self.scene_buffer, @intCast(fb_w), @intCast(fb_h));
    self.render();
}

/// Re-adopt the server's shared font atlas after a font-size zoom.
/// Updates the renderer's cell metrics + glyph atlas, then re-grids to the
/// current framebuffer with the new cell size. The pixel rect is unchanged
/// here — `arrangeWorkspace` reflows pane positions/sizes afterwards (and
/// re-grids again only if the bar-height change shifted this pane's rect).
pub fn refont(self: *TerminalPane) void {
    const fa = self.activeAtlas() orelse return;
    if (fa.cell_width == 0 or fa.cell_height == 0) return;

    self.renderer.cell_width = fa.cell_width;
    self.renderer.cell_height = fa.cell_height;
    self.renderer.glyph_atlas = fa.atlas_data;
    self.renderer.atlas_width = fa.atlas_width;
    self.renderer.atlas_height = fa.atlas_height;

    const pad = self.renderer.padding;
    const new_cols: u16 = @intCast(@max(1, (self.renderer.width -| pad * 2) / fa.cell_width));
    const new_rows: u16 = @intCast(@max(1, (self.renderer.height -| pad * 2) / fa.cell_height));
    self.pane.resize(self.server.zig_allocator, new_rows, new_cols) catch return;
    self.pane.grid.markAllDirty();
    self.render();
}

/// The atlas this pane renders from: its private zoom atlas if it has been
/// zoomed, otherwise the server's shared base atlas.
fn activeAtlas(self: *TerminalPane) ?*FontAtlas {
    return self.zoom_atlas orelse self.server.font_atlas;
}

/// Zoom THIS pane's font in / out / reset (Alt+scroll over the pane). Per
/// pane: rasterizes a private atlas at the new size and re-grids only this
/// pane — bars and other panes are untouched, which is both the intended
/// behaviour and why there is no whole-compositor re-raster lag. Returns true
/// if the size actually changed.
pub fn zoomFont(self: *TerminalPane, target: FontAtlas.ZoomTarget) bool {
    const base = self.server.font_atlas orelse return false;
    const cur: u16 = if (self.pane_font_size != 0) self.pane_font_size else self.server.font_size_base;

    var new_size = FontAtlas.zoomedFontSize(target, cur, self.server.font_size_base);
    // Clamp to configurable bounds (non-restrictive defaults). Min is floored
    // at FontAtlas.min_font_size for legibility; max of 0 means "no maximum".
    const lo = @max(FontAtlas.min_font_size, self.server.wm_config.font_zoom_min);
    const hi = self.server.wm_config.font_zoom_max;
    if (new_size < lo) new_size = lo;
    if (hi != 0 and new_size > hi) new_size = hi;
    if (new_size == cur) return false;

    if (new_size == self.server.font_size_base) {
        // Back to the base size → drop the private atlas and share again.
        self.freeZoomAtlas();
        self.pane_font_size = 0;
    } else {
        const fresh = base.rasterizeAtSize(new_size) catch return false;
        const slot = self.server.zig_allocator.create(FontAtlas) catch {
            var tmp = fresh;
            tmp.deinit();
            return false;
        };
        slot.* = fresh;
        self.freeZoomAtlas();
        self.zoom_atlas = slot;
        self.pane_font_size = new_size;
    }

    self.refont();
    self.server.scheduleRender();
    return true;
}

fn freeZoomAtlas(self: *TerminalPane) void {
    if (self.zoom_atlas) |za| {
        za.deinit();
        self.server.zig_allocator.destroy(za);
        self.zoom_atlas = null;
    }
}

/// Render the terminal grid into the pixel buffer + draw border.
/// After the live grid has been painted into the framebuffer, overlay the
/// scrollback viewport when the pane is scrolled up. teruwm's per-pane
/// `SoftwareRenderer` only ever rasterises the live grid (scroll_offset is
/// used solely for selection coordinate mapping), so without this call
/// scrolling up showed the *same* live screen — history never appeared.
/// Reuses the exact non-destructive overlay that standalone teru's windowed
/// renderer uses (`Ui.renderScrollOverlay`), so the two stay in lockstep.
fn applyScrollOverlay(self: *TerminalPane) void {
    const so: u32 = self.pane.scroll_offset;
    const sp: i32 = self.pane.scroll_pixel;
    if (so == 0 and sp == 0) return;
    const sb = self.pane.grid.scrollback orelse return;
    const pad: u16 = @intCast(self.renderer.padding);
    const cw: u32 = self.renderer.cell_width;
    const ch: u32 = self.renderer.cell_height;
    const sel_ptr: ?*const Selection = if (self.selection.active) &self.selection else null;
    teru.render.Ui.renderScrollOverlay(&self.renderer, sb, so, cw, ch, .{
        .x = pad,
        .y = pad,
        .width = @intCast(@as(u32, self.pane.grid.cols) * cw),
        .height = @intCast(@as(u32, self.pane.grid.rows) * ch),
    }, sp, sel_ptr);
}

pub fn render(self: *TerminalPane) void {
    const sel_ptr: ?*const Selection = if (self.selection.active) &self.selection else null;
    const so: u32 = self.pane.scroll_offset;
    const sbl: u32 = if (self.pane.grid.scrollback) |sb| @intCast(sb.lineCount()) else 0;
    self.renderer.renderWithSelection(&self.pane.grid, sel_ptr, so, sbl);
    self.applyScrollOverlay();

    if (self.shouldDrawBorder()) {
        const border_color = self.borderColor();
        self.drawBorder(border_color);
    }

    // Signal wlroots that buffer content changed (full damage, NULL region)
    wlr.wlr_scene_buffer_set_buffer_with_damage(self.scene_buffer, self.pixel_buffer, null);
}

/// Smart borders: suppress the focus border when this pane is the only
/// window on its workspace. Follows xmonad's smartBorders — a border
/// around the sole visible window carries no information. Scratchpads
/// (not in NodeRegistry) always keep their border so focus between a
/// scratchpad and a lone tiled pane stays visible.
fn shouldDrawBorder(self: *TerminalPane) bool {
    const slot = self.server.nodes.findById(self.node_id) orelse return true;
    const ws = self.server.nodes.workspace[slot];
    return self.server.nodes.countInWorkspace(ws) > 1;
}

fn drawBorder(self: *TerminalPane, color: u32) void {
    const w: usize = self.renderer.width;
    const h: usize = self.renderer.height;
    if (w < 5 or h < 5) return;
    const fb = self.renderer.framebuffer;
    if (fb.len < w * h) return; // safety: buffer must match dimensions

    // Top 2 rows
    compat.memsetU32(fb[0..@min(w * 2, fb.len)], color);
    // Bottom 2 rows
    if (h >= 2) {
        const bot = (h - 2) * w;
        if (bot + w * 2 <= fb.len) compat.memsetU32(fb[bot .. bot + w * 2], color);
    }
    // Left 2 cols + right 2 cols (skip top/bottom 2 rows already filled)
    var y: usize = 2;
    while (y < h -| 2) : (y += 1) {
        const row = y * w;
        fb[row] = color;
        fb[row + 1] = color;
        fb[row + w - 1] = color;
        fb[row + w - 2] = color;
    }
}

// ── Scene visibility ───────────────────────────────────────────

/// Current border ARGB pulled from the compositor config, honouring
/// the focused/unfocused distinction. Same source XdgView /
/// XwaylandView already use, so Wayland clients and native terminal
/// panes get identical chrome.
pub fn borderColor(self: *const TerminalPane) u32 {
    const is_focused = (self.server.focused_terminal == self);
    return if (is_focused)
        self.server.wm_config.border_color_focused
    else
        self.server.wm_config.border_color_unfocused;
}

pub fn setVisible(self: *TerminalPane, visible: bool) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, visible);
    }
}

/// Move the pane's scene buffer into a different scene tree. Used by
/// the scratchpad park/unpark path — reparenting always damages the
/// old and new AABBs, so unlike set_enabled(false) it reliably forces
/// the next DRM commit to flip.
pub fn reparent(self: *TerminalPane, new_parent: *wlr.wlr_scene_tree) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_reparent(node, new_parent);
    }
}

pub fn setPosition(self: *TerminalPane, x: i32, y: i32) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, x, y);
    }
}

// ── Event loop callback ────────────────────────────────────────

fn ptyReadable(_: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    const tp: *TerminalPane = @ptrCast(@alignCast(data orelse return 0));
    // Shell exited / fd error → tear the pane down. handleTerminalExit
    // removes this event source; without it the level-triggered fd
    // re-fires every dispatch and the compositor spins at 100% CPU.
    // wlroots reports HANGUP/ERROR for pipes, but a Linux PTY master
    // whose slave has closed stays EPOLLIN-readable (read() returns EIO)
    // and never raises HANGUP — the live-shell probe after poll() below
    // is what actually catches an exited shell. (The original test was
    // `mask & 0x10`, which can never be true: WL_EVENT_HANGUP is 0x04.)
    if (mask & (wlr.WL_EVENT_HANGUP | wlr.WL_EVENT_ERROR) != 0) {
        tp.server.handleTerminalExit(tp);
        return 0;
    }
    if (tp.poll()) {
        // Grid is dirty — tell wlroots we need a new frame so handleFrame
        // renders the updated content on the next vsync.
        // Multi-output: schedule on every output, since a pane on
        // workspace K is only ever visible on the output showing K.
        // N ≤ 4 in practice, trivial cost. Fall back to primary_output
        // during the init window where outputs[] hasn't populated yet.
        if (tp.server.outputs.items.len > 0) {
            for (tp.server.outputs.items) |o| {
                wlr.wlr_output_schedule_frame(o.wlr_output);
            }
        } else if (tp.server.primary_output) |output| {
            wlr.wlr_output_schedule_frame(output);
        }
    } else if (!tp.pane.isAlive()) {
        // Woke readable but the read produced nothing and the child is
        // gone — the PTY master is at EOF/EIO. Tear down here, else the
        // level-triggered fd re-fires forever and the compositor spins.
        tp.server.handleTerminalExit(tp);
        return 0;
    }
    return 0;
}

// ── Cleanup ────────────────────────────────────────────────────

pub fn deinit(self: *TerminalPane, allocator: std.mem.Allocator) void {
    if (self.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        self.event_source = null;
    }
    // Disable + detach the scene node, then hand it to the server's deferred
    // destroy queue (#11). A synchronous wlr_scene_node_destroy here crashed
    // at teardown — a buffer-internal signal fired after this pane's Zig
    // memory was freed (deinit runs mid-dispatch and the caller destroys the
    // *TerminalPane immediately after). queueSceneDestroy detaches the node
    // now and destroys it from a one-shot idle once the loop unwinds, so the
    // node no longer leaks until display-destroy. set_buffer(null) releases
    // the scene's ref to pixel_buffer; the deferred drain drops it.
    self.freeZoomAtlas();
    self.pane.deinit(allocator);
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
        wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, null);
        if (!self.server.queueSceneDestroy(node, self.pixel_buffer)) {
            // Couldn't defer (shutting down / no loop / OOM): fall back to the
            // historical safe-but-leaky behavior — leave the detached node for
            // wl_display_destroy to reap, and drop the buffer now.
            wlr.wlr_buffer_drop(self.pixel_buffer);
        }
    } else {
        // No scene node to defer; drop the buffer directly.
        wlr.wlr_buffer_drop(self.pixel_buffer);
    }
}
