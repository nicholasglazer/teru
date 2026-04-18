//! teru entry point — argv parsing + mode dispatch.
//!
//! Each subcommand lives in its own module under src/modes/. This
//! file only resolves `teru [args]` → one of:
//!   * daemon_mode.runHeadless   (--daemon NAME)
//!   * daemon_mode.runNamed      (-n NAME)
//!   * daemon_mode.runAttach     (--attach)
//!   * McpBridge.run             (--mcp-server / --mcp-bridge)
//!   * raw_mode.run              (--raw, or tier == .tty without -n)
//!   * windowed_mode.run         (default)
//!
//! Anything beyond arg parsing belongs in a mode module.

const std = @import("std");
const compat = @import("compat.zig");
const render = @import("render/render.zig");
const McpBridge = @import("agent/McpBridge.zig");
const Daemon = @import("server/daemon.zig");

const common = @import("modes/common.zig");
const raw_mode = @import("modes/raw.zig");
const windowed_mode = @import("modes/windowed.zig");
const daemon_mode = @import("modes/daemon.zig");

// Short-name locals used by the argv loop — the canonical defs
// live in common.
const out = common.out;
const outFmt = common.outFmt;
const version = common.version;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Parse command line args (initAllocator required on Windows; works everywhere)
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var mode_raw = false;
    var mode_attach = false;
    var mode_mcp_bridge = false;
    var mcp_target: McpBridge.Target = .teru;
    var daemon_session: ?[]const u8 = null;
    var session_name: ?[]const u8 = null; // -n NAME: persistent named session
    var template_name: ?[]const u8 = null; // -t NAME: apply template on start
    var list_sessions = false;
    var wm_class_override: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out(
                \\teru — AI-first terminal emulator
                \\
                \\Usage:
                \\  teru                          Fresh terminal (scratchpad)
                \\  teru -n <name>                Persistent named session
                \\  teru -n <name> -t <template>  Start session from template
                \\  teru -l                       List active sessions
                \\
                \\Options:
                \\  -n, --name <name>       Connect to (or start) named session
                \\  -t, --template <name>   Apply template (.tsess) on first start
                \\  -f, --fresh             Force fresh start (ignore saved layout)
                \\  -l, --list              List active sessions
                \\  -v, --version           Show version
                \\  -h, --help              Show this help
                \\  -e <command> [args...]  Run command instead of shell
                \\  --no-bar                Start with status bar hidden
                \\  --raw                   Raw TTY mode (no window)
                \\  --daemon <name>         Start headless daemon (server use)
                \\  --mcp-server            MCP stdio proxy (alias: --mcp-bridge, --mcp-stdio)
                \\  --target <teru|teruwm>  Target for --mcp-server (default: teru)
                \\  --class <name>          Set WM_CLASS
                \\
                \\Templates:
                \\  Searched in: ~/.config/teru/templates/, then ./examples/
                \\  Export current session: teru_session_save via MCP
                \\
                \\Keybindings:
                \\  Alt+Enter   New pane              Alt+X       Close pane
                \\  Alt+J/K     Focus next/prev       Alt+Z       Zoom pane
                \\  Alt+1-9,0   Switch workspace      Alt+Space   Cycle layout
                \\  Alt+V       Vi/copy mode          Alt+D       Detach
                \\  Alt+B       Toggle status bar     Alt+\       Reset zoom
                \\  RAlt+J/K    Swap pane              RAlt+H/L   Resize
                \\
                \\
            );
            return;
        }
        if (std.mem.eql(u8, arg, "--raw")) { mode_raw = true; continue; }
        if (std.mem.eql(u8, arg, "--no-bar")) { common.cli_no_bar = true; continue; }
        if (std.mem.eql(u8, arg, "--attach")) { mode_attach = true; continue; }
        if (std.mem.eql(u8, arg, "--mcp-server") or std.mem.eql(u8, arg, "--mcp-bridge") or std.mem.eql(u8, arg, "--mcp-stdio")) {
            mode_mcp_bridge = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            const v = args_iter.next() orelse continue;
            if (std.mem.eql(u8, v, "teru")) {
                mcp_target = .teru;
            } else if (std.mem.eql(u8, v, "teruwm")) {
                mcp_target = .teruwm;
            } else {
                var buf: [128]u8 = undefined;
                outFmt(&buf, "teru: unknown --target '{s}' (expected teru or teruwm)\n", .{v});
                std.process.exit(2);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) { list_sessions = true; continue; }
        if (std.mem.eql(u8, arg, "--daemon")) { daemon_session = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--session")) { session_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) { session_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) { template_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--class")) { wm_class_override = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) {
            // Collect remaining args as exec argv
            var n: usize = 0;
            while (args_iter.next()) |ea| {
                if (n < common.cli_exec_argv_buf.len - 1) {
                    common.cli_exec_argv_buf[n] = ea.ptr;
                    n += 1;
                }
            }
            if (n > 0) {
                common.cli_exec_argv_buf[n] = null; // sentinel
                common.cli_exec_argv = @ptrCast(&common.cli_exec_argv_buf);
            }
            break;
        }
    }
    // Nesting detection: don't open a window inside an existing teru
    // Safe commands inside teru: --version, --help, --list, --daemon, --raw
    const inside_teru = if (compat.getenv("TERM_PROGRAM")) |tp|
        std.mem.eql(u8, std.mem.sliceTo(tp, 0), "teru")
    else
        false;

    if (inside_teru and daemon_session == null and !list_sessions and !mode_raw and !mode_mcp_bridge) {
        // Allow named sessions in TTY mode (TUI over SSH)
        const tier_check = render.detectTier();
        const allow_tui = session_name != null and tier_check == .tty;

        if (!allow_tui) {
            if (session_name != null) {
                out("[teru] Already inside teru. Use Alt+1-9 to switch workspaces, Alt+C to create panes.\n");
                out("       For TUI mode over SSH: teru -n NAME (no display server needed)\n");
                return;
            }
            out("[teru] Already running inside teru.\n");
            out("       Alt+C  new pane     Alt+1-9  switch workspace\n");
            out("       teru --daemon NAME  start headless daemon\n");
            out("       teru -l             list active sessions\n");
            return;
        }
    }

    if (list_sessions) {
        var buf: [1024]u8 = undefined;
        if (Daemon.listSessions(&buf)) |sessions| {
            out("Active sessions:\n");
            out(sessions);
        } else {
            out("No active sessions\n");
        }
        return;
    }

    if (daemon_session) |name| {
        return daemon_mode.runHeadless(allocator, io, name, template_name);
    }

    // -n NAME: persistent named session (auto-start daemon + connect windowed)
    if (session_name) |name| {
        return daemon_mode.runNamed(allocator, io, name, template_name, wm_class_override);
    }

    if (mode_mcp_bridge) return McpBridge.run(io, mcp_target);
    if (mode_attach) return daemon_mode.runAttach(allocator, io, wm_class_override);

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty or mode_raw) {
        return raw_mode.run(allocator, io);
    }
    return windowed_mode.run(allocator, io, null, wm_class_override);
}
