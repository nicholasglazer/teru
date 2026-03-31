---
name: vt-compliance
description: VT compliance testing -- run escape sequence tests against teru's VtParser, validate CSI/SGR/OSC/DCS handling, report supported vs unsupported sequences
model: sonnet
context: fork
---

# VT Compliance Testing

Test teru's VtParser against terminal escape sequence standards.

## Usage

Run this skill to audit VtParser compliance. It will:
1. Read the VtParser state machine to catalog handled sequences
2. Run inline tests to verify correctness
3. Compare against the full VT100/xterm/DEC spec
4. Report supported, partially supported, and unsupported sequences

## Step 1: Read VtParser state machine

Read the complete `src/core/VtParser.zig` to understand current coverage.
Read `src/core/Grid.zig` to understand what the parser can drive.

## Step 2: Run existing tests

```bash
cd /home/ng/prod/teru && zig build test 2>&1
```

Count passing tests. Note any failures.

## Step 3: Catalog sequence support

Check VtParser for handling of each sequence category. For each, grep the source for the relevant dispatch bytes and report status.

### CSI Sequences (ESC[ ... final_byte)

| Sequence | Name | Final | Check |
|----------|------|-------|-------|
| CSI n A | Cursor Up | A | grep for `'A'` in CSI dispatch |
| CSI n B | Cursor Down | B | grep for `'B'` |
| CSI n C | Cursor Forward | C | grep for `'C'` |
| CSI n D | Cursor Backward | D | grep for `'D'` |
| CSI n E | Cursor Next Line | E | grep for `'E'` |
| CSI n F | Cursor Previous Line | F | grep for `'F'` |
| CSI n G | Cursor Horizontal Abs | G | grep for `'G'` |
| CSI n;m H | Cursor Position | H | grep for `'H'` |
| CSI n J | Erase in Display | J | grep for `'J'` |
| CSI n K | Erase in Line | K | grep for `'K'` |
| CSI n L | Insert Lines | L | grep for `'L'` |
| CSI n M | Delete Lines | M | grep for `'M'` |
| CSI n P | Delete Characters | P | grep for `'P'` |
| CSI n S | Scroll Up | S | grep for `'S'` |
| CSI n T | Scroll Down | T | grep for `'T'` |
| CSI n X | Erase Characters | X | grep for `'X'` |
| CSI n @ | Insert Characters | @ | grep for `'@'` |
| CSI n d | Vertical Position Abs | d | grep for `'d'` |
| CSI n;m f | Horizontal+Vertical | f | grep for `'f'` |
| CSI n;m r | Set Scroll Region | r | grep for `'r'` |
| CSI s | Save Cursor | s | grep for `'s'` |
| CSI u | Restore Cursor | u | grep for `'u'` |
| CSI n m | SGR (attrs/colors) | m | grep for `'m'` |
| CSI n n | Device Status Report | n | grep for `'n'` |
| CSI n t | Window manipulation | t | grep for `'t'` |
| CSI n c | Device Attributes | c | grep for `'c'` |

### SGR Parameters (within CSI m)

| Param | Effect | Check |
|-------|--------|-------|
| 0 | Reset | grep for param 0 handling |
| 1 | Bold | grep for bold |
| 2 | Dim/Faint | grep for dim |
| 3 | Italic | grep for italic |
| 4 | Underline | grep for underline |
| 5 | Blink | grep for blink |
| 7 | Inverse/Reverse | grep for inverse |
| 8 | Hidden | grep for hidden |
| 9 | Strikethrough | grep for strikethrough |
| 22 | Normal intensity | grep for 22 |
| 23 | Not italic | grep for 23 |
| 24 | Not underlined | grep for 24 |
| 25 | Not blinking | grep for 25 |
| 27 | Not reversed | grep for 27 |
| 28 | Not hidden | grep for 28 |
| 29 | Not strikethrough | grep for 29 |
| 30-37 | FG basic colors | grep for color handling |
| 38;5;N | FG 256-color | grep for 38 |
| 38;2;R;G;B | FG truecolor | grep for truecolor/rgb |
| 39 | FG default | grep for 39 |
| 40-47 | BG basic colors | grep for BG |
| 48;5;N | BG 256-color | grep for 48 |
| 48;2;R;G;B | BG truecolor | grep for BG truecolor |
| 49 | BG default | grep for 49 |
| 90-97 | FG bright colors | grep for bright/90 |
| 100-107 | BG bright colors | grep for 100 |

### DEC Private Modes (CSI ? n h/l)

| Mode | Name | Check |
|------|------|-------|
| ?1 | Application Cursor Keys | grep for mode 1 |
| ?7 | Autowrap | grep for mode 7 |
| ?12 | Cursor blink | grep for mode 12 |
| ?25 | Cursor visibility | grep for mode 25 |
| ?47 | Alt screen (old) | grep for mode 47 |
| ?1000 | Mouse click tracking | grep for 1000 |
| ?1002 | Mouse cell tracking | grep for 1002 |
| ?1003 | Mouse all tracking | grep for 1003 |
| ?1004 | Focus events | grep for 1004 |
| ?1006 | SGR mouse encoding | grep for 1006 |
| ?1049 | Alt screen + save cursor | grep for 1049 |
| ?2004 | Bracketed paste | grep for 2004 |
| ?2026 | Synchronized output | grep for 2026 |

### OSC Sequences (ESC] ... BEL/ST)

| OSC | Name | Check |
|-----|------|-------|
| 0 | Set title | grep for OSC 0 |
| 2 | Set title | grep for OSC 2 |
| 4 | Color palette | grep for OSC 4 |
| 7 | Current directory | grep for OSC 7 |
| 8 | Hyperlinks | grep for OSC 8 |
| 9 | Notification | grep for OSC 9 |
| 52 | Clipboard | grep for OSC 52 |
| 133 | Shell integration | grep for OSC 133 |
| 9999 | teru agent protocol | grep for OSC 9999 |

### Control Characters

| Char | Hex | Name | Check |
|------|-----|------|-------|
| BEL | 0x07 | Bell | grep for 0x07 or BEL |
| BS | 0x08 | Backspace | grep for 0x08 or backspace |
| HT | 0x09 | Tab | grep for 0x09 or tab |
| LF | 0x0A | Line Feed | grep for 0x0A or linefeed |
| VT | 0x0B | Vertical Tab | grep for 0x0B |
| FF | 0x0C | Form Feed | grep for 0x0C |
| CR | 0x0D | Carriage Return | grep for 0x0D |
| ESC | 0x1B | Escape | grep for 0x1B or escape |

## Step 4: Generate compliance report

Output a summary in this format:

```
## teru VT Compliance Report

### Summary
- CSI sequences: X/Y supported
- SGR attributes: X/Y supported
- DEC private modes: X/Y supported
- OSC sequences: X/Y supported
- Control characters: X/Y supported
- Tests passing: N/N

### Fully Supported
[list sequences with tests]

### Partially Supported (parsed but incomplete)
[list sequences that are recognized but missing features]

### Not Supported (planned)
[list sequences in the roadmap but not yet implemented]

### Not Supported (no plan)
[list sequences with no roadmap entry]

### Recommendations
[prioritized list of sequences to implement next, based on real-world usage]
```

## Step 5: Suggest test sequences

For any sequence that lacks tests, suggest inline test code:

```zig
test "VtParser: CSI <name>" {
    var grid = Grid.init(std.testing.allocator, 80, 24);
    defer grid.deinit(std.testing.allocator);
    var parser = VtParser.init(&grid);
    parser.feed("<escape sequence bytes>");
    // assert expected grid state
}
```

## Reference

Canonical xterm control sequences: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
vttest (compliance test suite): https://invisible-island.net/vttest/
ECMA-48 standard: https://www.ecma-international.org/publications/standards/Ecma-048.htm
