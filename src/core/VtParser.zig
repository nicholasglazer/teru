const std = @import("std");
const Grid = @import("Grid.zig");

/// VT100/xterm escape sequence parser.
/// State machine that takes raw bytes and drives a Grid.
///
/// Supported sequences:
///   Cursor:   ESC[A/B/C/D (movement), ESC[H/f (position), ESC[s/u (save/restore), ESC 7/8
///   Erase:    ESC[J (display), ESC[K (line)
///   SGR:      ESC[0-8m (attrs), ESC[30-37/40-47m (basic), ESC[38;5;N/48;5;Nm (256),
///             ESC[38;2;R;G;B/48;2;R;G;Bm (truecolor)
///   Scroll:   ESC[S (up), ESC[T (down)
///   Mode:     ESC[?25h/l (cursor visibility), ESC[?1049h/l (alt screen)
///   OSC:      ESC]0;...BEL (set title)
///   Control:  CR, LF, BS, TAB, BEL
const VtParser = @This();

pub const MouseMode = enum {
    none, // no mouse reporting
    normal, // 1000: press + release
    button_event, // 1002: + motion while button held
    any_event, // 1003: + all motion
};

pub const State = enum {
    ground,
    escape, // saw ESC
    csi_entry, // saw ESC[
    csi_param, // collecting params
    csi_intermediate, // saw intermediate byte (0x20-0x2F)
    osc_string, // saw ESC], collecting until BEL/ST
    dcs_passthrough, // saw ESC P, ignore until ST (ESC \)
    charset_g0, // saw ESC(, waiting for charset designator
    charset_g1, // saw ESC), waiting for charset designator
};

pub const MAX_PARAMS = 16;
pub const MAX_OSC_LEN = 256;

state: State = .ground,
grid: *Grid,
allocator: std.mem.Allocator,

/// File descriptor for sending responses back to the PTY (DA1, DSR, etc.)
/// Set to the PTY master fd by the Pane after init. -1 = no responses.
response_fd: i32 = -1,

/// Optional callback for sending responses through IPC instead of fd.
/// When set, sendResponse() calls this instead of writing to response_fd.
/// Used by remote/daemon panes that need pane_id framing.
response_fn: ?*const fn (data: []const u8, ctx: ?*anyopaque) void = null,
response_ctx: ?*anyopaque = null,

/// CSI parameter accumulation
params: [MAX_PARAMS]u16 = [_]u16{0} ** MAX_PARAMS,
param_count: u8 = 0,
/// CSI prefix byte ('?', '>', '=', '<', or 0 for none)
csi_prefix: u8 = 0,
/// Intermediate byte (e.g., ' ', '!', '"', etc.)
intermediate: u8 = 0,

/// OSC string buffer
osc_buf: [MAX_OSC_LEN]u8 = [_]u8{0} ** MAX_OSC_LEN,
osc_len: u16 = 0,

/// Parsed title from OSC 0
title: [MAX_OSC_LEN]u8 = [_]u8{0} ** MAX_OSC_LEN,
title_len: u16 = 0,
title_changed: bool = false,

/// UTF-8 decoder state
utf8_buf: [4]u8 = undefined,
utf8_len: u8 = 0,
utf8_expected: u8 = 0,

/// Cursor visibility
cursor_visible: bool = true,

/// Alt screen active
alt_screen: bool = false,

/// Last printed character (for REP / ESC[b)
last_char: u21 = ' ',

/// Bracketed paste mode (ESC[?2004h/l)
bracketed_paste: bool = false,

/// Application cursor keys mode (ESC[?1h/l — DECCKM)
app_cursor_keys: bool = false,

/// Auto-wrap mode (ESC[?7h/l — DECAWM), on by default
auto_wrap: bool = true,

/// Mouse tracking modes (ESC[?1000h..1003h, ESC[?1006h)
mouse_tracking: MouseMode = .none,
mouse_sgr: bool = false, // SGR extended format (mode 1006)

/// G0 charset: false = ASCII (B), true = DEC Special Graphics (0)
g0_line_drawing: bool = false,

/// Synchronized output (ESC[?2026h/l) — when true, defer rendering until
/// the app sends ESC[?2026l. Prevents flickering during rapid screen updates.
sync_output: bool = false,

/// Agent protocol: last OSC 9999 payload for external consumption
agent_event_buf: [512]u8 = undefined,
agent_event_len: usize = 0,
has_agent_event: bool = false,


pub fn init(allocator: std.mem.Allocator, grid: *Grid) VtParser {
    return .{ .grid = grid, .allocator = allocator };
}

/// Send a response back to the PTY (for DA1, DSR, etc.)
/// ECHO is disabled on the slave termios from the master side at PTY
/// creation, so response bytes written here are delivered to the shell's
/// stdin without being echoed back to the master as output.
fn sendResponse(self: *const VtParser, data: []const u8) void {
    if (@import("builtin").os.tag == .windows) return; // ConPTY handles DA1/DSR internally
    if (self.response_fn) |f| {
        f(data, self.response_ctx);
        return;
    }
    if (self.response_fd >= 0) {
        _ = std.c.write(self.response_fd, data.ptr, data.len);
    }
}

/// Create a VtParser with an undefined grid pointer and allocator.
/// MUST call setGrid() before feeding any data.
pub fn initEmpty() VtParser {
    return .{ .grid = undefined, .allocator = undefined };
}

pub fn setGrid(self: *VtParser, grid: *Grid) void {
    self.grid = grid;
}

pub fn setAllocator(self: *VtParser, allocator: std.mem.Allocator) void {
    self.allocator = allocator;
}

/// Feed a slice of bytes into the parser.
/// Uses SIMD fast-path to skip runs of printable ASCII when in ground state.
pub fn feed(self: *VtParser, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) {
        // Fast-path: when in ground state, scan ahead for the next byte
        // that needs special handling (ESC or any C0 control char < 0x20).
        // All bytes 0x20..0xFF are printable and can be batched into the grid.
        if (self.state == .ground) {
            const remaining = data[i..];
            const special = findNextSpecial(remaining);

            if (special > 0) {
                // Batch-write the printable run directly into the grid.
                self.writeGroundBatch(remaining[0..special]);
                i += special;
                continue;
            }
        }

        self.processByte(data[i]);
        i += 1;
    }
}

/// SIMD-accelerated scan for special bytes in the input buffer.
/// Returns the index of the first byte that needs special handling:
///   - byte < 0x20 (ESC, CR, LF, BS, TAB, BEL, etc.)
///   - byte >= 0x80 (UTF-8 multi-byte sequences)
/// or input.len if the entire buffer is printable ASCII (0x20..0x7F).
fn findNextSpecial(input: []const u8) usize {
    const Vec16 = @Vector(16, u8);
    const lo: Vec16 = @splat(0x20);
    const hi: Vec16 = @splat(0x80);

    var i: usize = 0;

    // SIMD path: 16 bytes at a time
    while (i + 16 <= input.len) : (i += 16) {
        const chunk: Vec16 = input[i..][0..16].*;
        // Byte < 0x20 (control) OR byte >= 0x80 (UTF-8 lead/continuation)
        const below = chunk < lo;
        const above = chunk >= hi;
        const combined = below | above;
        const mask: u16 = @bitCast(combined);
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar fallback for remaining bytes
    while (i < input.len) : (i += 1) {
        if (input[i] < 0x20 or input[i] > 0x7F) return i;
    }

    return input.len;
}

/// Batch-write a run of printable bytes (all >= 0x20) into the grid.
/// Avoids per-byte state machine overhead for the common case of plain text.
fn writeGroundBatch(self: *VtParser, run: []const u8) void {
    const grid = self.grid;
    for (run) |byte| {
        if (grid.cursor_col >= grid.cols) {
            grid.cursor_col = 0;
            grid.cursorDown();
        }
        const cell = grid.cellAt(grid.cursor_row, grid.cursor_col);
        cell.char = @as(u21, byte);
        cell.fg = grid.pen_fg;
        cell.bg = grid.pen_bg;
        cell.attrs = grid.pen_attrs;
        cell.hyperlink_id = grid.pen_hyperlink_id;
        grid.cursor_col += 1;
    }
    if (run.len > 0) {
        self.last_char = @as(u21, run[run.len - 1]);
        grid.dirty = true;
    }
}

/// Process a single byte through the state machine.
fn processByte(self: *VtParser, byte: u8) void {
    switch (self.state) {
        .ground => self.handleGround(byte),
        .escape => self.handleEscape(byte),
        .csi_entry => self.handleCsiEntry(byte),
        .csi_param => self.handleCsiParam(byte),
        .csi_intermediate => self.handleCsiIntermediate(byte),
        .osc_string => self.handleOscString(byte),
        .dcs_passthrough => {
            // DCS: silently consume until ST (ESC \) or BEL
            if (byte == 0x1B) {
                // Could be ESC \ (ST) — peek at escape handler
                self.state = .escape;
            } else if (byte == 0x07) {
                // BEL also terminates DCS
                self.state = .ground;
            }
            // All other bytes: silently consumed (no output)
        },
        .charset_g0 => self.handleCharsetG0(byte),
        .charset_g1 => self.handleCharsetG1(byte),
    }
}

// ── Ground state ─────────────────────────────────────────────────

fn handleGround(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x1B => { // ESC
            self.state = .escape;
        },
        0x07 => { // BEL — visual bell
            self.grid.bell = true;
        },
        0x08 => { // BS (backspace)
            if (self.grid.cursor_col > 0) {
                self.grid.cursor_col -= 1;
            }
        },
        0x09 => { // TAB — advance to next tab stop
            const tw: u16 = self.grid.tab_width;
            const next = if (tw > 0) (self.grid.cursor_col / tw + 1) * tw else self.grid.cursor_col + 1;
            self.grid.cursor_col = @min(next, self.grid.cols -| 1);
        },
        0x0A, 0x0B, 0x0C => { // LF, VT, FF
            self.grid.newline();
        },
        0x0D => { // CR — return to left margin (or col 0 if no margins)
            self.grid.cursor_col = @intCast(self.grid.getLeftMargin());
        },
        0x00...0x06, 0x0E...0x1A, 0x1C...0x1F => {
            // Other C0 controls: ignore
        },
        else => {
            // Printable character or UTF-8 byte
            if (byte >= 0x80) {
                self.handleUtf8(byte);
            } else {
                var ch: u21 = @as(u21, byte);
                // DEC Special Graphics (line drawing) charset mapping
                if (self.g0_line_drawing) {
                    ch = acsMap(byte);
                }
                self.grid.write(ch);
                self.last_char = ch;
            }
        },
    }
}

// ── UTF-8 decoder ───────────────────────────────────────────────

fn handleUtf8(self: *VtParser, byte: u8) void {
    if (byte & 0xE0 == 0xC0) {
        // 2-byte sequence start (110xxxxx)
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = 2;
    } else if (byte & 0xF0 == 0xE0) {
        // 3-byte sequence start (1110xxxx)
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = 3;
    } else if (byte & 0xF8 == 0xF0) {
        // 4-byte sequence start (11110xxx)
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = 4;
    } else if (byte & 0xC0 == 0x80 and self.utf8_len > 0) {
        // Continuation byte (10xxxxxx)
        self.utf8_buf[self.utf8_len] = byte;
        self.utf8_len += 1;

        if (self.utf8_len == self.utf8_expected) {
            // Decode complete sequence
            const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
            self.utf8_len = 0;
            self.utf8_expected = 0;
            self.grid.write(cp);
            self.last_char = cp;
        }
    } else {
        // Invalid byte — reset decoder, emit replacement character
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.grid.write(0xFFFD);
    }
}

fn decodeUtf8(bytes: []const u8) u21 {
    return switch (bytes.len) {
        2 => (@as(u21, bytes[0] & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F),
        3 => (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | @as(u21, bytes[2] & 0x3F),
        4 => (@as(u21, bytes[0] & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | @as(u21, bytes[3] & 0x3F),
        else => 0xFFFD, // replacement character
    };
}

// ── Escape state (saw ESC) ───────────────────────────────────────

/// DEC Special Graphics (ACS) character mapping.
/// Maps ASCII 0x60-0x7E to Unicode box-drawing/symbol codepoints.
fn acsMap(byte: u8) u21 {
    return switch (byte) {
        '`' => 0x25C6, // ◆ diamond
        'a' => 0x2592, // ▒ checkerboard
        'j' => 0x2518, // ┘ lower-right corner
        'k' => 0x2510, // ┐ upper-right corner
        'l' => 0x250C, // ┌ upper-left corner
        'm' => 0x2514, // └ lower-left corner
        'n' => 0x253C, // ┼ crossing
        'q' => 0x2500, // ─ horizontal line
        't' => 0x251C, // ├ left tee
        'u' => 0x2524, // ┤ right tee
        'v' => 0x2534, // ┴ bottom tee
        'w' => 0x252C, // ┬ top tee
        'x' => 0x2502, // │ vertical line
        else => byte, // pass through unchanged
    };
}

fn handleEscape(self: *VtParser, byte: u8) void {
    switch (byte) {
        '[' => {
            self.resetCsiState();
            self.state = .csi_entry;
        },
        ']' => {
            self.osc_len = 0;
            self.state = .osc_string;
        },
        '7' => { // DECSC: save cursor
            self.grid.saveCursor();
            self.state = .ground;
        },
        '8' => { // DECRC: restore cursor
            self.grid.restoreCursor();
            self.state = .ground;
        },
        'D' => { // IND: index (move cursor down, scroll if needed)
            if (self.grid.cursor_row >= self.grid.scroll_bottom) {
                self.grid.scrollUp();
            } else {
                self.grid.cursor_row += 1;
            }
            self.state = .ground;
        },
        'M' => { // RI: reverse index (move cursor up, scroll if needed)
            if (self.grid.cursor_row <= self.grid.scroll_top) {
                self.grid.scrollDown();
            } else {
                self.grid.cursor_row -= 1;
            }
            self.state = .ground;
        },
        'E' => { // NEL: next line
            self.grid.newline();
            self.state = .ground;
        },
        'c' => { // RIS: full reset
            self.grid.clearScreen(2);
            self.grid.cursor_row = 0;
            self.grid.cursor_col = 0;
            self.grid.resetPen();
            self.grid.scroll_top = 0;
            self.grid.scroll_bottom = self.grid.rows -| 1;
            self.cursor_visible = true;
            self.g0_line_drawing = false;
            self.state = .ground;
        },
        'P' => {
            // DCS — Device Control String (XTGETTCAP, DECRQSS, etc.)
            // Silently consume until ST (ESC \) or BEL
            self.state = .dcs_passthrough;
        },
        '(' => {
            // ESC( — Designate G0 character set. Next byte selects charset.
            self.state = .charset_g0;
        },
        ')' => {
            // ESC) — Designate G1 character set (ignored for now)
            self.state = .charset_g1;
        },
        else => {
            // Unknown escape sequence: drop back to ground
            self.state = .ground;
        },
    }
}

// ── Charset designation (ESC( / ESC)) ───────────────────────────

fn handleCharsetG0(self: *VtParser, byte: u8) void {
    switch (byte) {
        '0' => self.g0_line_drawing = true, // DEC Special Graphics
        'B' => self.g0_line_drawing = false, // ASCII
        else => {},
    }
    self.state = .ground;
}

fn handleCharsetG1(self: *VtParser, byte: u8) void {
    // G1 charset designation — consume and ignore
    _ = byte;
    self.state = .ground;
}

// ── CSI entry (saw ESC[) ─────────────────────────────────────────

fn handleCsiEntry(self: *VtParser, byte: u8) void {
    switch (byte) {
        '?', '>', '=', '<' => {
            // CSI prefix: ? (DEC private), > (DA2), = (DA3), < (KKP pop)
            self.csi_prefix = byte;
            self.state = .csi_param;
        },
        '0'...'9' => {
            self.params[0] = byte - '0';
            self.param_count = 1;
            self.state = .csi_param;
        },
        ';' => {
            // Empty first param (defaults to 0)
            self.param_count = 2;
            self.state = .csi_param;
        },
        0x20...0x2F => {
            self.intermediate = byte;
            self.state = .csi_intermediate;
        },
        0x40...0x7E => {
            // Final byte with no params
            self.param_count = 0;
            self.dispatchCsi(byte);
            self.state = .ground;
        },
        else => {
            self.state = .ground;
        },
    }
}

// ── CSI param collection ─────────────────────────────────────────

fn handleCsiParam(self: *VtParser, byte: u8) void {
    switch (byte) {
        '0'...'9' => {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            if (idx < MAX_PARAMS) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
        },
        ';' => {
            if (self.param_count < MAX_PARAMS) {
                self.param_count += 1;
                if (self.param_count <= MAX_PARAMS) {
                    self.params[self.param_count - 1] = 0;
                }
            }
        },
        0x20...0x2F => {
            self.intermediate = byte;
            self.state = .csi_intermediate;
        },
        0x40...0x7E => {
            // Final byte
            self.dispatchCsi(byte);
            self.state = .ground;
        },
        else => {
            self.state = .ground;
        },
    }
}

// ── CSI intermediate ─────────────────────────────────────────────

fn handleCsiIntermediate(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x20...0x2F => {
            // Another intermediate byte (rare, ignore)
        },
        0x40...0x7E => {
            // Final byte with intermediate
            if (self.intermediate == ' ' and byte == 'q') {
                // DECSCUSR — set cursor shape
                const n = self.getParam(0, 1);
                self.grid.cursor_shape = switch (n) {
                    0, 1, 2 => .block,
                    3, 4 => .underline,
                    5, 6 => .bar,
                    else => .block,
                };
            }
            self.state = .ground;
        },
        else => {
            self.state = .ground;
        },
    }
}

// ── OSC string (saw ESC]) ────────────────────────────────────────

fn handleOscString(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x07 => { // BEL terminates OSC
            self.finishOsc();
            self.state = .ground;
        },
        0x1B => {
            // ESC inside OSC — could be ST (ESC \) or a new escape sequence.
            // Finish the OSC and transition to escape state so the next byte
            // (e.g., '\') is handled as part of the escape, not printed literally.
            self.finishOsc();
            self.state = .escape;
        },
        else => {
            if (self.osc_len < MAX_OSC_LEN) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        },
    }
}

fn finishOsc(self: *VtParser) void {
    if (self.osc_len == 0) return;

    const data = self.osc_buf[0..self.osc_len];

    // Parse the OSC number (digits before the first ';')
    var num_end: usize = 0;
    while (num_end < data.len and data[num_end] >= '0' and data[num_end] <= '9') {
        num_end += 1;
    }

    if (num_end > 0 and num_end < data.len and data[num_end] == ';') {
        const osc_num = std.fmt.parseInt(u16, data[0..num_end], 10) catch 0;
        const payload = data[num_end + 1 ..];

        switch (osc_num) {
            0, 2 => {
                // Window title
                const copy_len = @min(payload.len, MAX_OSC_LEN);
                @memcpy(self.title[0..copy_len], payload[0..copy_len]);
                self.title_len = @intCast(copy_len);
                self.title_changed = true;
            },
            10 => {
                // Query/set foreground color. "?" = query.
                if (payload.len == 1 and payload[0] == '?') {
                    // Respond with default foreground (white)
                    self.sendResponse("\x1b]10;rgb:ff/ff/ff\x1b\\");
                }
                // Setting foreground color: silently accepted (no visual effect yet)
            },
            11 => {
                // Query/set background color. "?" = query.
                if (payload.len == 1 and payload[0] == '?') {
                    // Respond with default background (black)
                    self.sendResponse("\x1b]11;rgb:00/00/00\x1b\\");
                }
            },
            8 => {
                // Hyperlink (OSC 8). Format: "params;uri" to start, ";;" to end.
                // params are key=value pairs (id=...) — we skip them for now.
                if (std.mem.indexOf(u8, payload, ";")) |sep| {
                    const uri = payload[sep + 1 ..];
                    if (uri.len == 0) {
                        // End hyperlink
                        self.grid.pen_hyperlink_id = 0;
                    } else {
                        // Start hyperlink — allocate a slot
                        const id = self.grid.hyperlink_next_id;
                        var entry = &self.grid.hyperlinks[id];
                        const copy_len = @min(uri.len, entry.uri.len);
                        @memcpy(entry.uri[0..copy_len], uri[0..copy_len]);
                        entry.uri_len = @intCast(copy_len);
                        entry.active = true;
                        self.grid.pen_hyperlink_id = id;
                        self.grid.hyperlink_next_id +%= 1;
                        if (self.grid.hyperlink_next_id == 0) self.grid.hyperlink_next_id = 1;
                    }
                }
            },
            52 => {
                // Clipboard (OSC 52). Format: "c;BASE64" or "c;?" for query.
                // Silently accepted — clipboard integration requires platform support.
            },
            133 => {
                // Shell integration: semantic prompt marks (A/B/C/D)
                self.handleOsc133(payload);
            },
            9999 => {
                // Agent protocol — store payload for external consumption
                if (payload.len <= self.agent_event_buf.len) {
                    @memcpy(self.agent_event_buf[0..payload.len], payload);
                    self.agent_event_len = payload.len;
                    self.has_agent_event = true;
                }
            },
            else => {},
        }
    }
}

/// Handle OSC 133 shell integration (semantic prompt marks).
/// Payload format: "A", "B", "C", "D", or "D;exit_code".
fn handleOsc133(self: *VtParser, payload: []const u8) void {
    if (payload.len == 0) return;

    const grid = self.grid;
    const row = grid.cursor_row;
    if (row >= grid.row_meta.len) return;

    switch (payload[0]) {
        'A' => {
            grid.row_meta[row].prompt_mark = .prompt_start;
        },
        'B' => {
            grid.row_meta[row].prompt_mark = .input_start;
        },
        'C' => {
            grid.row_meta[row].prompt_mark = .output_start;
        },
        'D' => {
            grid.row_meta[row].prompt_mark = .output_end;
            // Parse exit code: "D;0" or "D;1" etc.
            if (payload.len >= 3 and payload[1] == ';') {
                // Find end of number (could have ";aid=PID" suffix)
                var end: usize = 2;
                while (end < payload.len and payload[end] >= '0' and payload[end] <= '9') : (end += 1) {}
                grid.row_meta[row].exit_code = std.fmt.parseInt(u8, payload[2..end], 10) catch null;
            } else {
                grid.row_meta[row].exit_code = null;
            }
        },
        else => {},
    }
}

/// Consume the last agent protocol event (OSC 9999 payload).
/// Returns the payload slice, or null if no event is pending.
/// Clears the event flag so the same event isn't consumed twice.
pub fn consumeAgentEvent(self: *VtParser) ?[]const u8 {
    if (self.has_agent_event) {
        self.has_agent_event = false;
        return self.agent_event_buf[0..self.agent_event_len];
    }
    return null;
}

// ── CSI dispatch ─────────────────────────────────────────────────

fn resetCsiState(self: *VtParser) void {
    self.params = [_]u16{0} ** MAX_PARAMS;
    self.param_count = 0;
    self.csi_prefix = 0;
    self.intermediate = 0;
}

/// Get CSI param with default value.
fn getParam(self: *const VtParser, idx: u8, default: u16) u16 {
    if (idx >= self.param_count) return default;
    const v = self.params[idx];
    return if (v == 0) default else v;
}

fn dispatchCsi(self: *VtParser, final: u8) void {
    if (self.csi_prefix != 0) {
        self.dispatchCsiPrivate(final);
        return;
    }

    switch (final) {
        'A' => { // CUU — cursor up
            const n = self.getParam(0, 1);
            self.grid.cursor_row -|= n;
            if (self.grid.cursor_row < self.grid.scroll_top) {
                self.grid.cursor_row = self.grid.scroll_top;
            }
        },
        'B' => { // CUD — cursor down
            const n = self.getParam(0, 1);
            self.grid.cursor_row = @min(self.grid.cursor_row +| n, self.grid.scroll_bottom);
        },
        'C' => { // CUF — cursor forward
            const n = self.getParam(0, 1);
            self.grid.cursor_col = @min(self.grid.cursor_col +| n, self.grid.cols -| 1);
        },
        'D' => { // CUB — cursor back
            const n = self.getParam(0, 1);
            self.grid.cursor_col -|= n;
        },
        'E' => { // CNL — cursor next line
            const n = self.getParam(0, 1);
            self.grid.cursor_row = @min(self.grid.cursor_row +| n, self.grid.scroll_bottom);
            self.grid.cursor_col = 0;
        },
        'F' => { // CPL — cursor previous line
            const n = self.getParam(0, 1);
            self.grid.cursor_row -|= n;
            if (self.grid.cursor_row < self.grid.scroll_top) {
                self.grid.cursor_row = self.grid.scroll_top;
            }
            self.grid.cursor_col = 0;
        },
        'G' => { // CHA — cursor horizontal absolute (1-based)
            const col = self.getParam(0, 1);
            self.grid.cursor_col = if (col == 0) 0 else @min(col - 1, self.grid.cols -| 1);
        },
        'H', 'f' => { // CUP / HVP — cursor position (1-based)
            const row = self.getParam(0, 1);
            const col = self.getParam(1, 1);
            self.grid.setCursorPos(row, col);
        },
        'J' => { // ED — erase display
            const mode: u8 = @intCast(self.getParam(0, 0));
            self.grid.clearScreen(mode);
        },
        'K' => { // EL — erase line
            const mode: u8 = @intCast(self.getParam(0, 0));
            self.grid.clearLine(self.grid.cursor_row, mode);
        },
        'L' => { // IL — insert lines
            const n = self.getParam(0, 1);
            self.grid.insertLines(n);
        },
        'M' => { // DL — delete lines
            const n = self.getParam(0, 1);
            self.grid.deleteLines(n);
        },
        'P' => { // DCH — delete characters
            const n = self.getParam(0, 1);
            self.grid.deleteChars(n);
        },
        'S' => { // SU — scroll up
            const n = self.getParam(0, 1);
            self.grid.scrollUpN(n);
        },
        'T' => { // SD — scroll down
            const n = self.getParam(0, 1);
            self.grid.scrollDownN(n);
        },
        'X' => { // ECH — erase characters (overwrite with blanks, no shift)
            const n = self.getParam(0, 1);
            self.grid.eraseChars(n);
        },
        '@' => { // ICH — insert blank characters
            const n = self.getParam(0, 1);
            self.grid.insertBlanks(n);
        },
        '`' => { // HPA — horizontal position absolute (1-based, same as CHA)
            const col = self.getParam(0, 1);
            self.grid.cursor_col = if (col == 0) 0 else @min(col - 1, self.grid.cols -| 1);
        },
        'b' => { // REP — repeat last character
            const n = self.getParam(0, 1);
            var i: u16 = 0;
            while (i < n) : (i += 1) {
                self.grid.write(self.last_char);
            }
        },
        'd' => { // VPA — vertical position absolute (1-based)
            const row = self.getParam(0, 1);
            self.grid.cursor_row = if (row == 0) 0 else @min(row - 1, self.grid.rows -| 1);
        },
        'm' => { // SGR — select graphic rendition
            self.dispatchSgr();
        },
        'r' => { // DECSTBM — set scroll region
            const top = self.getParam(0, 1);
            const bottom = self.getParam(1, self.grid.rows);
            self.grid.scroll_top = if (top == 0) 0 else @min(top - 1, self.grid.rows -| 1);
            self.grid.scroll_bottom = if (bottom == 0) 0 else @min(bottom - 1, self.grid.rows -| 1);
            // Ensure top < bottom
            if (self.grid.scroll_top >= self.grid.scroll_bottom) {
                self.grid.scroll_top = 0;
                self.grid.scroll_bottom = self.grid.rows -| 1;
            }
            // Move cursor to home
            self.grid.cursor_row = 0;
            self.grid.cursor_col = 0;
        },
        'n' => { // DSR — device status report (non-private form)
            const p = self.getParam(0, 0);
            if (p == 5) {
                self.sendResponse("\x1b[0n");
            } else if (p == 6) {
                var buf: [32]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.grid.cursor_row + 1,
                    self.grid.cursor_col + 1,
                }) catch return;
                self.sendResponse(msg);
            }
        },
        's' => {
            if (self.grid.margins_enabled) {
                // DECSLRM — set left/right margins (when DECLRMM active)
                const left: u16 = if (self.params[0] > 0) self.params[0] - 1 else 0;
                const right: u16 = if (self.param_count > 1 and self.params[1] > 0) self.params[1] else self.grid.cols;
                self.grid.setMargins(
                    @intCast(@min(left, self.grid.cols)),
                    @intCast(@min(right, self.grid.cols)),
                );
                // Per VT510: cursor moves to home after DECSLRM
                self.grid.cursor_row = self.grid.scroll_top;
                self.grid.cursor_col = @intCast(self.grid.getLeftMargin());
            } else {
                // SCP — save cursor position
                self.grid.saveCursor();
            }
        },
        'u' => { // RCP — restore cursor position
            self.grid.restoreCursor();
        },
        'c' => { // DA1 — primary device attributes (non-private form: ESC[c)
            self.sendResponse("\x1b[?62;22c");
        },
        else => {
            // Unknown CSI final byte: ignore
        },
    }
}

fn dispatchCsiPrivate(self: *VtParser, final: u8) void {
    const mode = self.getParam(0, 0);
    switch (final) {
        'h' => { // DECSET
            switch (mode) {
                1 => self.app_cursor_keys = true, // DECCKM
                7 => self.auto_wrap = true, // DECAWM
                12 => {}, // Cursor blink — accepted, no visual effect yet
                25 => self.cursor_visible = true, // show cursor
                47, 1047, 1049 => { // Alt screen on
                    if (!self.alt_screen) {
                        self.alt_screen = true;
                        self.grid.switchToAltScreen(self.allocator) catch {};
                    }
                },
                1000 => self.mouse_tracking = .normal,
                1002 => self.mouse_tracking = .button_event,
                1003 => self.mouse_tracking = .any_event,
                1006 => self.mouse_sgr = true,
                2004 => self.bracketed_paste = true,
                2026 => self.sync_output = true,
                69 => self.grid.margins_enabled = true, // DECLRMM — enable left/right margins
                else => {},
            }
        },
        'l' => { // DECRST
            switch (mode) {
                1 => self.app_cursor_keys = false, // DECCKM
                7 => self.auto_wrap = false, // DECAWM
                12 => {}, // Cursor blink off — accepted
                25 => self.cursor_visible = false, // hide cursor
                47, 1047, 1049 => { // Alt screen off
                    if (self.alt_screen) {
                        self.alt_screen = false;
                        self.grid.switchToMainScreen();
                    }
                },
                1000, 1002, 1003 => self.mouse_tracking = .none,
                1006 => self.mouse_sgr = false,
                2004 => self.bracketed_paste = false,
                69 => { // DECLRMM — disable left/right margins
                    self.grid.margins_enabled = false;
                    self.grid.left_margin = 0;
                    self.grid.right_margin = 0;
                },
                2026 => {
                    self.sync_output = false;
                    self.grid.dirty = true;
                },
                else => {},
            }
        },
        'c' => {
            if (self.csi_prefix == '>') {
                // DA2 (ESC[>c) — Secondary Device Attributes
                // Respond: ESC[>Pp;Pv;Pc c (VT100-class, version, 0)
                self.sendResponse("\x1b[>0;0;0c");
            } else {
                // DA1 (ESC[?c or ESC[c) — Primary Device Attributes
                // Respond: VT220 with ANSI color support
                self.sendResponse("\x1b[?62;22c");
            }
        },
        'u' => {
            if (self.csi_prefix == '?') {
                // Kitty keyboard protocol query (CSI ? u)
                // Respond with current flags (0 = supported but inactive)
                self.sendResponse("\x1b[?0u");
            }
            // CSI > flags u = KKP push (TODO: implement flag tracking)
            // CSI < u = KKP pop (TODO: implement flag tracking)
        },
        'p' => {
            if (self.intermediate == '$' and self.csi_prefix == '?') {
                // DECRQM — request mode (CSI ? Pn $ p)
                // Respond: CSI ? Pn ; Ps $ y
                var buf: [32]u8 = undefined;
                const ps: u8 = switch (mode) {
                    2026 => if (self.sync_output) 1 else 2, // sync output
                    2004 => if (self.bracketed_paste) 1 else 2, // bracketed paste
                    1049 => if (self.alt_screen) 1 else 2, // alt screen
                    25 => if (self.cursor_visible) 1 else 2, // cursor visible
                    1 => if (self.app_cursor_keys) 1 else 2, // app cursor
                    1000, 1002, 1003 => if (self.mouse_tracking != .none) 1 else 2,
                    else => 0, // not recognized
                };
                const msg = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, ps }) catch return;
                self.sendResponse(msg);
            }
        },
        'n' => {
            // DSR — Device Status Report
            const p = self.getParam(0, 0);
            if (p == 5) {
                // Status report: "I'm OK"
                self.sendResponse("\x1b[0n");
            } else if (p == 6) {
                // Cursor position report: ESC[row;colR
                var buf: [32]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.grid.cursor_row + 1,
                    self.grid.cursor_col + 1,
                }) catch return;
                self.sendResponse(msg);
            }
        },
        else => {},
    }
}

// ── SGR dispatch ─────────────────────────────────────────────────

fn dispatchSgr(self: *VtParser) void {
    if (self.param_count == 0) {
        // ESC[m with no params = reset
        self.grid.resetPen();
        return;
    }

    var i: u8 = 0;
    while (i < self.param_count) {
        const p = self.params[i];
        switch (p) {
            0 => self.grid.resetPen(),
            1 => self.grid.pen_attrs.bold = true,
            2 => self.grid.pen_attrs.dim = true,
            3 => self.grid.pen_attrs.italic = true,
            4 => self.grid.pen_attrs.underline = true,
            5 => self.grid.pen_attrs.blink = true,
            7 => self.grid.pen_attrs.inverse = true,
            8 => self.grid.pen_attrs.hidden = true,
            9 => self.grid.pen_attrs.strikethrough = true,
            22 => {
                self.grid.pen_attrs.bold = false;
                self.grid.pen_attrs.dim = false;
            },
            23 => self.grid.pen_attrs.italic = false,
            24 => self.grid.pen_attrs.underline = false,
            25 => self.grid.pen_attrs.blink = false,
            27 => self.grid.pen_attrs.inverse = false,
            28 => self.grid.pen_attrs.hidden = false,
            29 => self.grid.pen_attrs.strikethrough = false,
            // Standard foreground colors (30-37)
            30...37 => self.grid.pen_fg = .{ .indexed = @intCast(p - 30) },
            // Standard background colors (40-47)
            40...47 => self.grid.pen_bg = .{ .indexed = @intCast(p - 40) },
            39 => self.grid.pen_fg = .default, // default fg
            49 => self.grid.pen_bg = .default, // default bg
            // Bright foreground (90-97)
            90...97 => self.grid.pen_fg = .{ .indexed = @intCast(p - 90 + 8) },
            // Bright background (100-107)
            100...107 => self.grid.pen_bg = .{ .indexed = @intCast(p - 100 + 8) },
            // Extended color: 38;5;N or 38;2;R;G;B
            38 => {
                i = self.parseExtendedColor(i, true);
                continue;
            },
            48 => {
                i = self.parseExtendedColor(i, false);
                continue;
            },
            else => {}, // Unknown SGR param: ignore
        }
        i += 1;
    }
}

/// Parse extended color (256-color or truecolor).
/// Returns the new index to continue from.
fn parseExtendedColor(self: *VtParser, start: u8, is_fg: bool) u8 {
    var i = start + 1;
    if (i >= self.param_count) return i;

    const sub = self.params[i];
    switch (sub) {
        5 => { // 256-color: 38;5;N
            i += 1;
            if (i >= self.param_count) return i;
            const color_idx: u8 = @intCast(@min(self.params[i], 255));
            if (is_fg) {
                self.grid.pen_fg = .{ .indexed = color_idx };
            } else {
                self.grid.pen_bg = .{ .indexed = color_idx };
            }
            return i + 1;
        },
        2 => { // Truecolor: 38;2;R;G;B
            i += 1;
            if (i + 2 >= self.param_count) return i;
            const r: u8 = @intCast(@min(self.params[i], 255));
            const g: u8 = @intCast(@min(self.params[i + 1], 255));
            const b_val: u8 = @intCast(@min(self.params[i + 2], 255));
            if (is_fg) {
                self.grid.pen_fg = .{ .rgb = .{ .r = r, .g = g, .b = b_val } };
            } else {
                self.grid.pen_bg = .{ .rgb = .{ .r = r, .g = g, .b = b_val } };
            }
            return i + 3;
        },
        else => return i + 1,
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "plain text" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("Hello");

    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 5), grid.cursor_col);
}

test "CR and LF" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("AB\r\nCD");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(1, 1).char);
}

test "backspace" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("AB\x08C");

    // 'A' at 0, 'B' at 1, BS moves back to 1, 'C' overwrites 'B'
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(0, 1).char);
}

test "tab stops" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("A\tB");
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 8).char);
}

test "CSI cursor movement" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Move cursor to row 5, col 10 (1-based)
    parser.feed("\x1b[5;10H");
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);

    // Cursor up 2
    parser.feed("\x1b[2A");
    try std.testing.expectEqual(@as(u16, 2), grid.cursor_row);

    // Cursor down 1
    parser.feed("\x1b[B");
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_row);

    // Cursor forward 5
    parser.feed("\x1b[5C");
    try std.testing.expectEqual(@as(u16, 14), grid.cursor_col);

    // Cursor back 3
    parser.feed("\x1b[3D");
    try std.testing.expectEqual(@as(u16, 11), grid.cursor_col);
}

test "CSI cursor position home" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("Hello\x1b[H");
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
}

test "SGR basic attributes" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Bold + italic on
    parser.feed("\x1b[1;3mA");
    const cell_a = grid.cellAtConst(0, 0);
    try std.testing.expect(cell_a.attrs.bold);
    try std.testing.expect(cell_a.attrs.italic);

    // Reset
    parser.feed("\x1b[0mB");
    const cell_b = grid.cellAtConst(0, 1);
    try std.testing.expect(!cell_b.attrs.bold);
    try std.testing.expect(!cell_b.attrs.italic);
}

test "SGR standard colors" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Red foreground (31), blue background (44)
    parser.feed("\x1b[31;44mX");
    const cell = grid.cellAtConst(0, 0);
    try std.testing.expectEqual(Grid.Color{ .indexed = 1 }, cell.fg);
    try std.testing.expectEqual(Grid.Color{ .indexed = 4 }, cell.bg);
}

test "SGR 256-color" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // 256-color foreground: index 208 (orange)
    parser.feed("\x1b[38;5;208mA");
    const cell = grid.cellAtConst(0, 0);
    try std.testing.expectEqual(Grid.Color{ .indexed = 208 }, cell.fg);
}

test "SGR truecolor" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Truecolor foreground: RGB(255, 128, 0)
    parser.feed("\x1b[38;2;255;128;0mA");
    const cell = grid.cellAtConst(0, 0);
    try std.testing.expectEqual(Grid.Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }, cell.fg);
}

test "erase display" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("ABCDE\r\nFGHIJ\r\nKLMNO");

    // ESC[2J — clear entire screen
    parser.feed("\x1b[2J");
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(1, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 4).char);
}

test "erase line" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("ABCDE");
    // Move cursor to column 2
    parser.feed("\x1b[1;3H");
    // ESC[K — erase from cursor to end of line (mode 0)
    parser.feed("\x1b[K");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
}

test "scroll up and down" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';

    // ESC[S — scroll up
    parser.feed("\x1b[S");
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 0).char);

    // ESC[T — scroll down
    parser.feed("\x1b[T");
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(2, 0).char);
}

test "cursor save and restore via CSI" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b[5;10H"); // Move to (4,9)
    parser.feed("\x1b[s"); // Save
    parser.feed("\x1b[1;1H"); // Move to (0,0)
    parser.feed("\x1b[u"); // Restore

    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);
}

test "cursor save and restore via DEC" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b[5;10H"); // Move to (4,9)
    parser.feed("\x1b" ++ "7"); // ESC 7 — save
    parser.feed("\x1b[1;1H"); // Move to (0,0)
    parser.feed("\x1b" ++ "8"); // ESC 8 — restore

    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);
}

test "cursor visibility" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(parser.cursor_visible);

    parser.feed("\x1b[?25l"); // Hide
    try std.testing.expect(!parser.cursor_visible);

    parser.feed("\x1b[?25h"); // Show
    try std.testing.expect(parser.cursor_visible);
}

test "alt screen preserves and restores main content" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("Hello"); // Write some text
    parser.feed("\x1b[5;10H"); // Move cursor

    parser.feed("\x1b[?1049h"); // Alt screen on
    try std.testing.expect(parser.alt_screen);
    // Screen should be cleared (alt screen is blank)
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    // Cursor should be at (0,0) on alt screen
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);

    // Write something on the alt screen
    parser.feed("Alt!");

    parser.feed("\x1b[?1049l"); // Alt screen off
    try std.testing.expect(!parser.alt_screen);
    // Main screen content should be restored
    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    // Cursor should be restored to saved position (4, 9)
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);
}

test "OSC title" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b]0;My Terminal Title\x07");
    const expected = "My Terminal Title";
    try std.testing.expectEqualSlices(u8, expected, parser.title[0..parser.title_len]);
}

test "SGR reset with no params" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b[1mA"); // Bold
    try std.testing.expect(grid.cellAtConst(0, 0).attrs.bold);

    parser.feed("\x1b[mB"); // Reset (no params)
    try std.testing.expect(!grid.cellAtConst(0, 1).attrs.bold);
}

test "multiple CSI params" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Bold + underline + red fg + blue bg in one sequence
    parser.feed("\x1b[1;4;31;44mX");
    const cell = grid.cellAtConst(0, 0);
    try std.testing.expect(cell.attrs.bold);
    try std.testing.expect(cell.attrs.underline);
    try std.testing.expectEqual(Grid.Color{ .indexed = 1 }, cell.fg);
    try std.testing.expectEqual(Grid.Color{ .indexed = 4 }, cell.bg);
}

test "scroll region" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 4);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Set scroll region to rows 2-4 (1-based)
    parser.feed("\x1b[2;4r");
    try std.testing.expectEqual(@as(u16, 1), grid.scroll_top);
    try std.testing.expectEqual(@as(u16, 3), grid.scroll_bottom);
    // Cursor should go home
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
}

// ── SIMD fast-path tests ────────────────────────────────────────

test "SIMD findNextSpecial — ESC at various positions" {
    // ESC at position 0
    try std.testing.expectEqual(@as(usize, 0), findNextSpecial("\x1bHello"));

    // ESC after a few chars
    try std.testing.expectEqual(@as(usize, 5), findNextSpecial("Hello\x1b[31m"));

    // ESC at position 16 (past one SIMD chunk)
    const buf16 = "0123456789ABCDEF\x1b";
    try std.testing.expectEqual(@as(usize, 16), findNextSpecial(buf16));

    // ESC at position 17 (in scalar fallback after one full chunk)
    const buf17 = "0123456789ABCDEFG\x1b";
    try std.testing.expectEqual(@as(usize, 17), findNextSpecial(buf17));
}

test "SIMD findNextSpecial — no special bytes (pure printable text)" {
    // Short buffer (< 16 bytes, scalar only)
    try std.testing.expectEqual(@as(usize, 5), findNextSpecial("Hello"));

    // Exactly 16 bytes
    try std.testing.expectEqual(@as(usize, 16), findNextSpecial("0123456789ABCDEF"));

    // 32 bytes (two full SIMD chunks)
    try std.testing.expectEqual(@as(usize, 32), findNextSpecial("0123456789ABCDEF0123456789ABCDEF"));

    // 20 bytes (one SIMD chunk + 4 scalar)
    try std.testing.expectEqual(@as(usize, 20), findNextSpecial("0123456789ABCDEFGHIJ"));
}

test "SIMD findNextSpecial — control chars other than ESC" {
    // Newline
    try std.testing.expectEqual(@as(usize, 3), findNextSpecial("ABC\n"));

    // Carriage return
    try std.testing.expectEqual(@as(usize, 0), findNextSpecial("\r"));

    // Tab
    try std.testing.expectEqual(@as(usize, 2), findNextSpecial("AB\tC"));

    // BEL
    try std.testing.expectEqual(@as(usize, 4), findNextSpecial("ABCD\x07"));
}

test "SIMD findNextSpecial — empty input" {
    try std.testing.expectEqual(@as(usize, 0), findNextSpecial(""));
}

test "SIMD fast-path — batched ground write produces same result as byte-by-byte" {
    const allocator = std.testing.allocator;

    // Reference: byte-by-byte through processByte
    var grid_ref = try Grid.init(allocator, 24, 80);
    defer grid_ref.deinit(allocator);
    var parser_ref = VtParser.init(allocator, &grid_ref);
    const text = "The quick brown fox jumps over the lazy dog!";
    for (text) |byte| {
        parser_ref.processByte(byte);
    }

    // Test: batched via feed() SIMD fast-path
    var grid_simd = try Grid.init(allocator, 24, 80);
    defer grid_simd.deinit(allocator);
    var parser_simd = VtParser.init(allocator, &grid_simd);
    parser_simd.feed(text);

    // Both grids must match
    try std.testing.expectEqual(grid_ref.cursor_row, grid_simd.cursor_row);
    try std.testing.expectEqual(grid_ref.cursor_col, grid_simd.cursor_col);
    for (0..text.len) |col| {
        const ref_cell = grid_ref.cellAtConst(0, @intCast(col));
        const simd_cell = grid_simd.cellAtConst(0, @intCast(col));
        try std.testing.expectEqual(ref_cell.char, simd_cell.char);
    }
}

test "SIMD fast-path — mixed text and escapes" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Text, then escape, then more text
    parser.feed("Hello\x1b[1mWorld");

    // "Hello" at cols 0-4
    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    try std.testing.expect(!grid.cellAtConst(0, 0).attrs.bold);

    // "World" at cols 5-9, bold
    try std.testing.expectEqual(@as(u21, 'W'), grid.cellAtConst(0, 5).char);
    try std.testing.expectEqual(@as(u21, 'd'), grid.cellAtConst(0, 9).char);
    try std.testing.expect(grid.cellAtConst(0, 5).attrs.bold);
}

// ── Agent protocol (OSC 9999) tests ─────────────────────────────

test "OSC 9999 agent event with BEL terminator" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // No agent event initially
    try std.testing.expect(parser.consumeAgentEvent() == null);

    // Feed an OSC 9999 sequence
    parser.feed("\x1b]9999;agent:start;name=backend-dev\x07");

    // Should have an agent event
    const payload = parser.consumeAgentEvent() orelse return error.ExpectedAgentEvent;
    try std.testing.expectEqualStrings("agent:start;name=backend-dev", payload);

    // Second consume returns null (already consumed)
    try std.testing.expect(parser.consumeAgentEvent() == null);
}

test "OSC 9999 agent event with ESC backslash terminator" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b]9999;agent:status;state=working;progress=0.5\x1b");

    const payload = parser.consumeAgentEvent() orelse return error.ExpectedAgentEvent;
    try std.testing.expectEqualStrings("agent:status;state=working;progress=0.5", payload);
}

test "OSC 9999 does not interfere with regular OSC title" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Regular title OSC
    parser.feed("\x1b]0;My Title\x07");
    try std.testing.expectEqualSlices(u8, "My Title", parser.title[0..parser.title_len]);
    try std.testing.expect(parser.consumeAgentEvent() == null);

    // Agent OSC — should not affect title
    parser.feed("\x1b]9999;agent:start;name=test\x07");
    try std.testing.expectEqualSlices(u8, "My Title", parser.title[0..parser.title_len]);
    try std.testing.expect(parser.consumeAgentEvent() != null);
}

test "OSC 9999 interleaved with text" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Text, then agent event, then more text
    parser.feed("Hello\x1b]9999;agent:task;task=Building\x07World");

    // Text should be written to grid
    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    try std.testing.expectEqual(@as(u21, 'W'), grid.cellAtConst(0, 5).char);

    // Agent event should be captured
    const payload = parser.consumeAgentEvent() orelse return error.ExpectedAgentEvent;
    try std.testing.expectEqualStrings("agent:task;task=Building", payload);
}

// ── UTF-8 decoding tests ────────────────────────────────────────

test "UTF-8 2-byte sequence (é = U+00E9)" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // é = 0xC3 0xA9
    parser.feed(&[_]u8{ 0xC3, 0xA9 });
    try std.testing.expectEqual(@as(u21, 0x00E9), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "UTF-8 3-byte sequence (→ = U+2192)" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // → = 0xE2 0x86 0x92
    parser.feed(&[_]u8{ 0xE2, 0x86, 0x92 });
    try std.testing.expectEqual(@as(u21, 0x2192), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "UTF-8 4-byte sequence (U+1F600 grinning face)" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // U+1F600 = 0xF0 0x9F 0x98 0x80
    parser.feed(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 });
    try std.testing.expectEqual(@as(u21, 0x1F600), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "UTF-8 mixed ASCII and multi-byte" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // "Héllo" — H (ASCII), é (2-byte), l, l, o (ASCII)
    parser.feed("H\xC3\xA9llo");
    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x00E9), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    try std.testing.expectEqual(@as(u16, 5), grid.cursor_col);
}

test "UTF-8 decodeUtf8 standalone" {
    // 2-byte: é (U+00E9)
    try std.testing.expectEqual(@as(u21, 0x00E9), decodeUtf8(&[_]u8{ 0xC3, 0xA9 }));
    // 3-byte: → (U+2192)
    try std.testing.expectEqual(@as(u21, 0x2192), decodeUtf8(&[_]u8{ 0xE2, 0x86, 0x92 }));
    // 4-byte: U+1F600
    try std.testing.expectEqual(@as(u21, 0x1F600), decodeUtf8(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 }));
    // Invalid length returns replacement char
    try std.testing.expectEqual(@as(u21, 0xFFFD), decodeUtf8(&[_]u8{0xFF}));
}

test "SIMD findNextSpecial stops at high bytes" {
    // Byte 0x80 at position 3 — SIMD must stop there
    try std.testing.expectEqual(@as(usize, 3), findNextSpecial("ABC\x80"));
    // All ASCII printable — no stop
    try std.testing.expectEqual(@as(usize, 5), findNextSpecial("Hello"));
    // 0xC3 at position 0
    try std.testing.expectEqual(@as(usize, 0), findNextSpecial("\xC3\xA9"));
    // Mixed: 5 ASCII then UTF-8 lead byte
    try std.testing.expectEqual(@as(usize, 5), findNextSpecial("Hello\xC3\xA9"));
    // 0x7F is below 0x80 — treated as printable by SIMD fast-path
    try std.testing.expectEqual(@as(usize, 3), findNextSpecial("AB\x7F"));
    // 0x80 at position 2 — should stop (UTF-8 continuation byte territory)
    try std.testing.expectEqual(@as(usize, 2), findNextSpecial("AB\x80"));
}

// ── Issue 2: Missing VT sequence tests ─────────────────────────

test "CSI L — insert lines" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 4);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Fill rows: A, B, C, D
    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';
    grid.cellAt(3, 0).char = 'D';

    // Move cursor to row 2 (1-based), insert 1 line
    parser.feed("\x1b[2;1H\x1b[L");

    // Row 1 should now be blank (inserted), B moves to row 2, C to row 3
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(3, 0).char);
}

test "CSI M — delete lines" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 4);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';
    grid.cellAt(3, 0).char = 'D';

    // Move cursor to row 2, delete 1 line
    parser.feed("\x1b[2;1H\x1b[M");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(3, 0).char);
}

test "CSI P — delete characters" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("ABCDE");
    // Move to col 2, delete 2 chars
    parser.feed("\x1b[1;3H\x1b[2P");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 4).char);
}

test "CSI @ — insert blank characters" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("ABCDE");
    // Move to col 2, insert 2 blanks
    parser.feed("\x1b[1;3H\x1b[2@");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(0, 4).char);
}

test "CSI X — erase characters" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("ABCDE");
    // Move to col 1, erase 3 chars
    parser.feed("\x1b[1;2H\x1b[3X");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(0, 4).char);
}

test "CSI b — repeat last character" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("X\x1b[4b");

    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 4).char);
    try std.testing.expectEqual(@as(u16, 5), grid.cursor_col);
}

test "CSI backtick — HPA (same as CHA)" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    parser.feed("\x1b[15`");
    try std.testing.expectEqual(@as(u16, 14), grid.cursor_col);
}

test "bracketed paste mode" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(!parser.bracketed_paste);
    parser.feed("\x1b[?2004h");
    try std.testing.expect(parser.bracketed_paste);
    parser.feed("\x1b[?2004l");
    try std.testing.expect(!parser.bracketed_paste);
}

test "application cursor keys mode" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(!parser.app_cursor_keys);
    parser.feed("\x1b[?1h");
    try std.testing.expect(parser.app_cursor_keys);
    parser.feed("\x1b[?1l");
    try std.testing.expect(!parser.app_cursor_keys);
}

test "auto-wrap mode" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(parser.auto_wrap); // on by default
    parser.feed("\x1b[?7l");
    try std.testing.expect(!parser.auto_wrap);
    parser.feed("\x1b[?7h");
    try std.testing.expect(parser.auto_wrap);
}

test "unknown CSI sequences are silently absorbed" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Feed some unknown CSI sequences — should not produce text
    parser.feed("\x1b[?12h"); // cursor blink (absorbed)
    parser.feed("\x1b[?1006h"); // SGR mouse (absorbed)
    parser.feed("\x1b[999Z"); // unknown final 'Z'
    parser.feed("OK");

    // Only "OK" should appear in the grid
    try std.testing.expectEqual(@as(u21, 'O'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'K'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u16, 2), grid.cursor_col);
}

test "DECSCUSR: cursor shape block" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // ESC[ 2 SP q -> steady block
    parser.feed("\x1b[2 q");
    try std.testing.expectEqual(Grid.CursorShape.block, grid.cursor_shape);
}

test "DECSCUSR: cursor shape underline" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // ESC[ 4 SP q -> steady underline
    parser.feed("\x1b[4 q");
    try std.testing.expectEqual(Grid.CursorShape.underline, grid.cursor_shape);
}

test "DECSCUSR: cursor shape bar" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // ESC[ 6 SP q -> steady bar
    parser.feed("\x1b[6 q");
    try std.testing.expectEqual(Grid.CursorShape.bar, grid.cursor_shape);
}

test "DECSCUSR: cursor shape blinking variants" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // 0 -> block (default)
    parser.feed("\x1b[0 q");
    try std.testing.expectEqual(Grid.CursorShape.block, grid.cursor_shape);

    // 3 -> blinking underline
    parser.feed("\x1b[3 q");
    try std.testing.expectEqual(Grid.CursorShape.underline, grid.cursor_shape);

    // 5 -> blinking bar
    parser.feed("\x1b[5 q");
    try std.testing.expectEqual(Grid.CursorShape.bar, grid.cursor_shape);

    // 1 -> blinking block
    parser.feed("\x1b[1 q");
    try std.testing.expectEqual(Grid.CursorShape.block, grid.cursor_shape);
}

test "BEL sets bell flag" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(!grid.bell);
    parser.feed("\x07");
    try std.testing.expect(grid.bell);

    // Clearing and re-triggering
    grid.bell = false;
    parser.feed("Hello\x07");
    try std.testing.expect(grid.bell);
}

test "OSC 0 sets title and title_changed flag" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    try std.testing.expect(!parser.title_changed);

    // OSC 0 ; title BEL
    parser.feed("\x1b]0;my window title\x07");
    try std.testing.expect(parser.title_changed);
    try std.testing.expectEqual(@as(u16, 15), parser.title_len);
    try std.testing.expectEqualSlices(u8, "my window title", parser.title[0..parser.title_len]);

    // Clear flag and send another title
    parser.title_changed = false;
    parser.feed("\x1b]0;new title\x07");
    try std.testing.expect(parser.title_changed);
    try std.testing.expectEqualSlices(u8, "new title", parser.title[0..parser.title_len]);
}

test "OSC 133 A/B/C/D parsing" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // A mark (prompt start)
    parser.feed("\x1b]133;A\x07");
    try std.testing.expectEqual(Grid.PromptMark.prompt_start, grid.row_meta[0].prompt_mark);

    // Move cursor down
    grid.cursor_row = 1;
    parser.feed("\x1b]133;B\x07");
    try std.testing.expectEqual(Grid.PromptMark.input_start, grid.row_meta[1].prompt_mark);

    grid.cursor_row = 2;
    parser.feed("\x1b]133;C\x07");
    try std.testing.expectEqual(Grid.PromptMark.output_start, grid.row_meta[2].prompt_mark);

    grid.cursor_row = 5;
    parser.feed("\x1b]133;D;0\x07");
    try std.testing.expectEqual(Grid.PromptMark.output_end, grid.row_meta[5].prompt_mark);
    try std.testing.expectEqual(@as(?u8, 0), grid.row_meta[5].exit_code);
}

test "OSC 133 D exit code extraction" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Exit code 0 (success)
    grid.cursor_row = 0;
    parser.feed("\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(?u8, 0), grid.row_meta[0].exit_code);

    // Exit code 1 (failure)
    grid.cursor_row = 1;
    parser.feed("\x1b]133;D;1\x07");
    try std.testing.expectEqual(@as(?u8, 1), grid.row_meta[1].exit_code);

    // Exit code 127
    grid.cursor_row = 2;
    parser.feed("\x1b]133;D;127\x07");
    try std.testing.expectEqual(@as(?u8, 127), grid.row_meta[2].exit_code);

    // D without exit code
    grid.cursor_row = 3;
    parser.feed("\x1b]133;D\x07");
    try std.testing.expectEqual(Grid.PromptMark.output_end, grid.row_meta[3].prompt_mark);
    try std.testing.expectEqual(@as(?u8, null), grid.row_meta[3].exit_code);

    // D with aid= suffix: "D;0;aid=12345"
    grid.cursor_row = 4;
    parser.feed("\x1b]133;D;0;aid=12345\x07");
    try std.testing.expectEqual(@as(?u8, 0), grid.row_meta[4].exit_code);
}

test "OSC 133 marks do not interfere with text" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);
    var parser = VtParser.init(allocator, &grid);

    // Interleave text with OSC 133 marks
    parser.feed("$ ");
    parser.feed("\x1b]133;A\x07");
    parser.feed("ls");

    try std.testing.expectEqual(@as(u21, '$'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 's'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(Grid.PromptMark.prompt_start, grid.row_meta[0].prompt_mark);
}
