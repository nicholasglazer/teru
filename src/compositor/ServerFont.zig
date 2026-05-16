//! Font-size zoom for teruwm.
//!
//! teruwm shares a single `FontAtlas` across every terminal pane and both
//! status bars. A font zoom re-rasterizes that atlas, then propagates the
//! new cell metrics everywhere: each pane re-grids (rows/cols change while
//! its pixel rect stays put), the bars resize (`cell_h + 4`), and every
//! workspace is re-arranged so tiled panes reflow around the new bar
//! height.
//!
//! The pure size arithmetic lives in `FontAtlas.zoomedFontSize` — shared
//! with standalone-terminal windowed mode (`modes/windowed.zig`) so the
//! two zoom paths can never drift.

const Server = @import("Server.zig");
const teru = @import("teru");
const FontAtlas = teru.render.FontAtlas;

/// Apply one font-size zoom step to the whole compositor. Re-rasterizes the
/// shared atlas, re-fonts every terminal pane and the bars, then re-arranges
/// all workspaces. Returns true if the font size actually changed (caller
/// repaints); false if already at the target size or re-rasterization failed.
pub fn applyFontZoom(server: *Server, target: FontAtlas.ZoomTarget) bool {
    const fa = server.font_atlas orelse return false;

    const new_size = FontAtlas.zoomedFontSize(target, server.font_size, server.font_size_base);
    if (new_size == server.font_size) return false;

    // Re-rasterize the shared atlas in place. rasterizeAtSize copies the
    // font_data, so deinit-ing the old atlas afterwards can't dangle the new
    // one. The heap cell holding the FontAtlas struct is reused.
    const new_atlas = fa.rasterizeAtSize(new_size) catch return false;
    fa.deinit();
    fa.* = new_atlas;
    server.font_size = new_size;

    // Re-point every terminal pane (tiled, floating, scratchpad) at the new
    // atlas and re-grid it to its current framebuffer.
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| tp.refont();
    }

    // Resize the bars to the new cell-derived height before arranging —
    // arrangeworkspace reads bar.bar_height to inset the tiling area.
    if (server.bar) |bar| bar.refont(server);

    // Reflow every workspace: the bar-height delta shifts tiled pane rects.
    var ws: u8 = 0;
    while (ws < 10) : (ws += 1) server.arrangeworkspace(ws);

    // Final repaint — arrangeworkspace only repaints panes whose rect moved.
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| tp.render();
    }
    if (server.bar) |bar| _ = bar.render(server);

    return true;
}
