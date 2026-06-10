//! Test barrel for the teruwm compositor.
//!
//! `zig build test -Dcompositor` reaches `test { ... }` blocks in every
//! file listed here. Only compositor modules with non-trivial pure-math
//! coverage land in the barrel — display-bound paths are exercised by
//! the headless end-to-end harness instead (`tests/teruwm_e2e.py`,
//! which launches teruwm on the wlroots headless backend and asserts
//! spawn / tiling / shell-exit / no-spin / clean-shutdown over MCP).
//!
//! Adding a file: `_ = @import("MyFile.zig");` — the reference pulls
//! every `test {}` block in that file into the binary.

test {
    _ = @import("Node.zig");
    _ = @import("Bar.zig");
    _ = @import("WmConfig.zig");
    _ = @import("wlr.zig");
    _ = @import("WmMcpTools.zig");
}
