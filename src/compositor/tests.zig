//! Test barrel for the teruwm compositor.
//!
//! `zig build test -Dcompositor` reaches `test { ... }` blocks in every
//! file listed here. Only compositor modules with non-trivial pure-math
//! coverage land in the barrel — display-bound paths stay untested
//! until session_lock_v1 or a proper headless harness arrives.
//!
//! Adding a file: `_ = @import("MyFile.zig");` — the reference pulls
//! every `test {}` block in that file into the binary.

test {
    _ = @import("Node.zig");
    _ = @import("Bar.zig");
    _ = @import("WmConfig.zig");
}
