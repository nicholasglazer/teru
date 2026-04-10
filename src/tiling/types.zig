//! Shared type definitions for the tiling layout system.

const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.width == other.width and self.height == other.height;
    }

    pub const zero = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

pub const Layout = enum(u8) {
    master_stack = 0,
    grid = 1,
    monocle = 2,
    dishes = 3,
    spiral = 4,
    three_col = 5,
    columns = 6,
    accordion = 7,

    /// Parse a layout name string (e.g. "master-stack", "grid") into a Layout.
    /// Accepts both hyphen and underscore variants for multi-word names.
    pub fn parse(s: []const u8) ?Layout {
        if (std.mem.eql(u8, s, "master-stack") or std.mem.eql(u8, s, "master_stack")) return .master_stack;
        if (std.mem.eql(u8, s, "grid")) return .grid;
        if (std.mem.eql(u8, s, "monocle")) return .monocle;
        if (std.mem.eql(u8, s, "dishes")) return .dishes;
        if (std.mem.eql(u8, s, "accordion")) return .accordion;
        if (std.mem.eql(u8, s, "spiral")) return .spiral;
        if (std.mem.eql(u8, s, "three-col") or std.mem.eql(u8, s, "three_col")) return .three_col;
        if (std.mem.eql(u8, s, "columns")) return .columns;
        return null;
    }

    /// Return the canonical display name for a layout (hyphenated form).
    pub fn name(self: Layout) []const u8 {
        return switch (self) {
            .master_stack => "master-stack",
            .grid => "grid",
            .monocle => "monocle",
            .dishes => "dishes",
            .spiral => "spiral",
            .three_col => "three-col",
            .columns => "columns",
            .accordion => "accordion",
        };
    }
};

pub const SplitDirection = enum { horizontal, vertical };

pub const SplitNode = union(enum) {
    leaf: u64,
    split: Split,

    pub const Split = struct {
        dir: SplitDirection,
        ratio: f32,
        first: u16,
        second: u16,
    };
};

pub const max_layouts = 8;

// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "Layout.parse — all valid names" {
    try t.expectEqual(@as(?Layout, .master_stack), Layout.parse("master-stack"));
    try t.expectEqual(@as(?Layout, .master_stack), Layout.parse("master_stack"));
    try t.expectEqual(@as(?Layout, .grid), Layout.parse("grid"));
    try t.expectEqual(@as(?Layout, .monocle), Layout.parse("monocle"));
    try t.expectEqual(@as(?Layout, .dishes), Layout.parse("dishes"));
    try t.expectEqual(@as(?Layout, .accordion), Layout.parse("accordion"));
    try t.expectEqual(@as(?Layout, .spiral), Layout.parse("spiral"));
    try t.expectEqual(@as(?Layout, .three_col), Layout.parse("three-col"));
    try t.expectEqual(@as(?Layout, .three_col), Layout.parse("three_col"));
    try t.expectEqual(@as(?Layout, .columns), Layout.parse("columns"));
}

test "Layout.parse — unknown returns null" {
    try t.expectEqual(@as(?Layout, null), Layout.parse("floating"));
    try t.expectEqual(@as(?Layout, null), Layout.parse("unknown"));
    try t.expectEqual(@as(?Layout, null), Layout.parse(""));
}

test "Layout.name — canonical names" {
    try t.expectEqualStrings("master-stack", Layout.master_stack.name());
    try t.expectEqualStrings("grid", Layout.grid.name());
    try t.expectEqualStrings("monocle", Layout.monocle.name());
    try t.expectEqualStrings("dishes", Layout.dishes.name());
    try t.expectEqualStrings("spiral", Layout.spiral.name());
    try t.expectEqualStrings("three-col", Layout.three_col.name());
    try t.expectEqualStrings("columns", Layout.columns.name());
    try t.expectEqualStrings("accordion", Layout.accordion.name());
}

test "Layout.parse and Layout.name roundtrip" {
    const all = [_]Layout{
        .master_stack, .grid, .monocle, .dishes,
        .spiral, .three_col, .columns, .accordion,
    };
    for (all) |layout| {
        const str = layout.name();
        const roundtrip = Layout.parse(str);
        try t.expectEqual(@as(?Layout, layout), roundtrip);
    }
}
