//! Rendering subsystem for teru.
//!
//! Two-tier rendering architecture:
//!   CPU  — SIMD software raster + X11 SHM (primary, works everywhere)
//!   TTY  — VT output to host terminal (SSH, server, container, --raw mode)

pub const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
pub const FontAtlas = @import("FontAtlas.zig");
pub const GlyphInfo = FontAtlas.GlyphInfo;

pub const tier = @import("tier.zig");
pub const RenderTier = tier.RenderTier;
pub const detectTier = tier.detectTier;

pub const BarWidget = @import("BarWidget.zig");
pub const BarRenderer = @import("BarRenderer.zig");

test {
    _ = @import("software.zig");
    _ = FontAtlas;
    _ = tier;
    _ = BarWidget;
    _ = BarRenderer;
}
