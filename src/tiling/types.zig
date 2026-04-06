//! Shared type definitions for the tiling layout system.

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
