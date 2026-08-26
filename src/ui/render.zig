// SPDX-License-Identifier: Apache-2.0
//
// Draws one frame of the unified diff view (mockup 2a): one status row, the
// diff body, one mode row. No persistent file list - files are reached with
// `]f`, which is what buys the body 22 of 26 rows instead of 17.
//
// Every string drawn here is allocated from the frame arena, because vaxis
// cells reference the text rather than copying it and `render()` reads it
// later. The arena is reset after render and flush, never before
// (ARCHITECTURE.md 5c). A slice that dies early renders as plausible garbage
// on one row rather than crashing, so this rule is a review item, not
// something the compiler catches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const diff = @import("../core/diff.zig");
const hunk = @import("../core/hunk.zig");
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const rows_mod = @import("rows.zig");
const theme_mod = @import("theme.zig");

pub const Theme = theme_mod.Theme;
pub const Glyphs = theme_mod.Glyphs;

/// Rows of chrome: status, rule, rule, mode.
pub const chrome_rows = 4;

pub fn bodyHeight(win_rows: u16) u16 {
    return if (win_rows > chrome_rows) win_rows - chrome_rows else 0;
}

/// Everything one frame needs. Assembled by the app; nothing here reaches back
/// into the diff pipeline or the terminal.
pub const View = struct {
    file: *const diff.FileDiff,
    rows: rows_mod.Rows,
    file_index: u32,
    file_count: u32,
    /// Row index of the cursor, and of the first visible row.
    cursor: u32,
    scroll: u32,
    mode: []const u8 = "NORMAL",
    hints: []const u8 = "",
    /// Enclosing function name per hunk, empty where unknown.
    fn_names: []const []const u8 = &.{},
    /// Whole-file token runs and the buffers they index. Empty when the file
    /// could not be attached - a torn read, or a language with no lexer - in
    /// which case the body renders correct but unstyled.
    work: ?buffer.Buffer = null,
    head: ?buffer.Buffer = null,
    work_runs: []const lexer.Run = &.{},
    head_runs: []const lexer.Run = &.{},
    /// Hunks across the whole review, and the 1-based position of the one the
    /// cursor is in. Position rather than the id, because ids keep climbing
    /// across re-diffs as changes come and go - "#16 of 15" is a true
    /// statement that reads like a bug.
    total_hunks: u32 = 0,
    hunk_ordinal: u32 = 0,
    /// Set when the last re-diff hit a file changing underneath it. Shown
    /// rather than swallowed: a stale frame the user knows about beats a
    /// blended one they do not (SPEC.md 9).
    torn: bool = false,
};

pub const Frame = struct {
    win: vaxis.Window,
    arena: Allocator,
    theme: Theme,
    glyphs: Glyphs,

    fn width(self: Frame) u16 {
        return self.win.width;
    }

    /// A rule spanning `cols` columns, built from a possibly multi-byte glyph.
    fn rule(self: Frame, glyph: []const u8, cols: u16) Allocator.Error![]const u8 {
        const out = try self.arena.alloc(u8, @as(usize, cols) * glyph.len);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            @memcpy(out[i * glyph.len ..][0..glyph.len], glyph);
        }
        return out;
    }

    fn put(self: Frame, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
        _ = self.win.printSegment(
            .{ .text = text, .style = style },
            .{ .row_offset = row, .col_offset = col, .wrap = .none },
        );
    }

    /// Right-aligns using display width, never byte length: the status fields
    /// are full of multi-byte glyphs and `─` is three bytes wide and one
    /// column.
    fn putRight(self: Frame, row: u16, text: []const u8, style: vaxis.Style) void {
        const w = self.win.gwidth(text);
        if (w >= self.width()) return self.put(row, 0, text, style);
        self.put(row, self.width() - w, text, style);
    }
};

pub fn draw(f: Frame, v: View) Allocator.Error!void {
    f.win.clear();
    const h = f.win.height;
    if (h < chrome_rows + 1 or f.width() < 20) return drawTooSmall(f);

    try drawStatus(f, v, 0);
    f.put(1, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try drawBody(f, v, 2, bodyHeight(h));
    f.put(h - 2, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try drawMode(f, v, h - 1);
}

/// Below this there is no honest layout, so say so instead of drawing a
/// corrupted one.
fn drawTooSmall(f: Frame) void {
    f.put(0, 0, "lgtm: window too small", f.theme.dim);
}

fn drawStatus(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;
    const g = f.glyphs;

    var col: u16 = 1;
    const path = v.file.path();
    f.put(row, col, path, t.path);
    col += f.win.gwidth(path);

    const counts = try std.fmt.allocPrint(f.arena, " {s} {d}/{d} {s} ", .{
        g.sep, v.file_index + 1, v.file_count, g.sep,
    });
    f.put(row, col, counts, t.dim);
    col += f.win.gwidth(counts);

    const plus = try std.fmt.allocPrint(f.arena, "+{d}", .{v.file.added});
    f.put(row, col, plus, t.added_count);
    col += f.win.gwidth(plus) + 1;

    const minus = try std.fmt.allocPrint(f.arena, "{s}{d}", .{ g.del, v.file.removed });
    f.put(row, col, minus, t.removed_count);

    // Right side: which hunk the cursor is in, out of how many in this file.
    if (v.rows.hunkAt(v.cursor)) |hi| {
        if (hi < v.file.hunks.len) {
            const right = try std.fmt.allocPrint(f.arena, "#{d} {s} {d}/{d} ", .{
                v.file.hunks[hi].id, g.sep, v.hunk_ordinal, v.total_hunks,
            });
            f.putRight(row, right, t.hunk_id);
        }
    }
}

fn drawMode(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;

    const badge = try std.fmt.allocPrint(f.arena, " {s} ", .{v.mode});
    f.put(row, 1, badge, t.mode_badge);
    var col: u16 = 1 + f.win.gwidth(badge) + 2;

    if (v.torn) {
        const warn = "file changed while reading, re-diffing";
        f.put(row, col, warn, t.removed_count);
        col += f.win.gwidth(warn) + 2;
    } else {
        const info = try std.fmt.allocPrint(f.arena, "{d} rows", .{v.rows.len()});
        f.put(row, col, info, t.dim);
        col += f.win.gwidth(info) + 2;
    }

    if (v.hints.len > 0 and f.win.gwidth(v.hints) + col + 1 <= f.width()) {
        f.putRight(row, v.hints, t.hint);
    }
}

fn drawBody(f: Frame, v: View, top: u16, height: u16) Allocator.Error!void {
    var screen_row: u16 = 0;
    while (screen_row < height) : (screen_row += 1) {
        const idx = v.scroll + screen_row;
        if (idx >= v.rows.len()) break;
        const on_cursor = idx == v.cursor;
        try drawRow(f, v, top + screen_row, v.rows.items[idx], on_cursor);
    }
}

fn drawRow(f: Frame, v: View, row: u16, r: rows_mod.Row, on_cursor: bool) Allocator.Error!void {
    switch (r) {
        .gap => {
            const cols = if (f.width() > 6) f.width() - 6 else f.width();
            f.put(row, 3, try f.rule(f.glyphs.gap, cols), f.theme.rule);
        },
        .summarised => {
            const msg = try std.fmt.allocPrint(
                f.arena,
                "  {d} lines changed - too large to render inline, not discarded",
                .{v.file.added + v.file.removed},
            );
            f.put(row, 0, msg, f.theme.dim);
        },
        .hunk_header => |hi| try drawHunkHeader(f, v, row, hi),
        .line => |li| try drawLine(f, v, row, li, on_cursor),
    }
}

fn drawHunkHeader(f: Frame, v: View, row: u16, hi: u32) Allocator.Error!void {
    if (hi >= v.file.hunks.len) return;
    const h = v.file.hunks[hi];
    const t = f.theme;
    const g = f.glyphs;

    const name = if (hi < v.fn_names.len) v.fn_names[hi] else "";
    const left = if (name.len > 0)
        try std.fmt.allocPrint(f.arena, " {s} #{d} {s} {s}", .{ g.at, h.id, g.sep, name })
    else
        try std.fmt.allocPrint(f.arena, " {s} #{d}", .{ g.at, h.id });
    f.put(row, 0, left, t.hunk_id);

    // A wholly deleted file has no new-file lines, so its new range is 0-0.
    // Show where the code used to be instead of printing a line number that
    // does not exist.
    const right = if (h.new_count == 0)
        try std.fmt.allocPrint(f.arena, "{s}{d}-{d} {s} ", .{
            g.del, h.old_start, h.old_start + @max(h.old_count, 1) - 1, g.at,
        })
    else if (h.new_count == 1)
        try std.fmt.allocPrint(f.arena, "{d} {s} ", .{ h.new_start, g.at })
    else
        try std.fmt.allocPrint(f.arena, "{d}-{d} {s} ", .{
            h.new_start, h.new_start + h.new_count - 1, g.at,
        });

    // Only when it does not collide with the name: a truncated function name
    // is worse than an absent line range.
    if (f.win.gwidth(left) + f.win.gwidth(right) + 2 <= f.width()) {
        f.putRight(row, right, t.dim);
    }
}

/// Width of the line-number column, from the largest number this file shows.
fn numWidth(f: *const diff.FileDiff) u16 {
    var max: u32 = 1;
    for (f.hunks) |h| {
        const end = h.new_start + h.new_count;
        if (end > max) max = end;
        const old_end = h.old_start + h.old_count;
        if (old_end > max) max = old_end;
    }
    var w: u16 = 1;
    var n = max;
    while (n >= 10) : (n /= 10) w += 1;
    return @max(w, 2);
}

fn drawLine(f: Frame, v: View, row: u16, li: u32, on_cursor: bool) Allocator.Error!void {
    const lines = v.file.lines;
    if (li >= lines.len()) return;
    const kind = lines.kind[li];
    const t = f.theme;
    const g = f.glyphs;

    const bg: ?vaxis.Color = if (on_cursor) t.cursor_line.bg else null;

    const sign: []const u8 = switch (kind) {
        .add => g.add,
        .del => g.del,
        .context => g.context,
    };
    const sign_style = withBg(switch (kind) {
        .add => t.add_sign,
        .del => t.del_sign,
        .context => t.dim,
    }, bg);

    const no = switch (kind) {
        .del => lines.old_no[li],
        else => lines.new_no[li],
    };
    const nw = numWidth(v.file);
    const prefix = try std.fmt.allocPrint(f.arena, "{s} {d: >[2]}  ", .{ sign, no, nw });

    // The cursor row is filled first so the highlight spans the full width,
    // not just the columns that happen to carry text.
    if (on_cursor) {
        var c: u16 = 0;
        while (c < f.width()) : (c += 1) {
            f.win.writeCell(c, row, .{ .char = .{ .grapheme = " " }, .style = t.cursor_line });
        }
    }

    f.put(row, 0, prefix, sign_style);
    const col = f.win.gwidth(prefix);
    try drawCode(f, v, row, col, li, kind, bg);
}

fn withBg(style: vaxis.Style, bg: ?vaxis.Color) vaxis.Style {
    var out = style;
    if (bg) |b| out.bg = b;
    return out;
}

/// Draws one line's text, split into styled segments by the lexer's runs.
///
/// The runs cover the whole buffer, so the line's byte range is found from its
/// line number rather than by pointer arithmetic on the diff's text slice -
/// which would be wrong for a file that failed to attach.
fn drawCode(
    f: Frame,
    v: View,
    row: u16,
    col: u16,
    li: u32,
    kind: hunk.LineKind,
    bg: ?vaxis.Color,
) Allocator.Error!void {
    const lines = v.file.lines;
    const text = lines.text[li];
    const plain = withBg(f.theme.text, bg);

    const src: ?buffer.Buffer = switch (kind) {
        .del => v.head,
        else => v.work,
    };
    const runs: []const lexer.Run = switch (kind) {
        .del => v.head_runs,
        else => v.work_runs,
    };
    const no = switch (kind) {
        .del => lines.old_no[li],
        else => lines.new_no[li],
    };

    const buf = src orelse return f.put(row, col, text, plain);
    if (runs.len == 0 or no == 0 or no > buf.lineCount()) {
        return f.put(row, col, text, plain);
    }
    const lo = buf.starts[no - 1];
    const hi = lo + @as(u32, @intCast(text.len));

    const slice = runsIn(runs, lo, hi);
    if (slice.len == 0) return f.put(row, col, text, plain);

    var segs: std.ArrayList(vaxis.Segment) = .empty;
    for (slice) |r| {
        const s = @max(r.start, lo);
        const e = @min(r.end(), hi);
        if (e <= s) continue;
        try segs.append(f.arena, .{
            .text = buf.bytes[s..e],
            .style = withBg(f.theme.forKind(r.kind), bg),
        });
    }
    if (segs.items.len == 0) return f.put(row, col, text, plain);
    _ = f.win.print(segs.items, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

/// Runs overlapping `[lo, hi)`. Binary search for the first, then a walk:
/// runs are sorted and non-overlapping, so this is O(log n + k) per row rather
/// than a scan of the file's runs for every visible line.
pub fn runsIn(runs: []const lexer.Run, lo: u32, hi: u32) []const lexer.Run {
    var low: usize = 0;
    var high: usize = runs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (runs[mid].end() <= lo) low = mid + 1 else high = mid;
    }
    const start = low;
    var end = start;
    while (end < runs.len and runs[end].start < hi) end += 1;
    return runs[start..end];
}

const testing = std.testing;

test "body height leaves exactly the chrome rows" {
    try testing.expectEqual(@as(u16, 22), bodyHeight(26));
    try testing.expectEqual(@as(u16, 0), bodyHeight(4));
    try testing.expectEqual(@as(u16, 0), bodyHeight(1));
}

test "run lookup finds only the runs overlapping a line" {
    const runs = [_]lexer.Run{
        .{ .start = 0, .len = 5, .kind = .keyword },
        .{ .start = 5, .len = 5, .kind = .text },
        .{ .start = 10, .len = 5, .kind = .string },
        .{ .start = 15, .len = 5, .kind = .comment },
    };
    const got = runsIn(&runs, 5, 15);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(lexer.Kind.text, got[0].kind);
    try testing.expectEqual(lexer.Kind.string, got[1].kind);

    // A range inside one run still finds it.
    try testing.expectEqual(@as(usize, 1), runsIn(&runs, 11, 13).len);
    // A range past the end finds nothing rather than trapping.
    try testing.expectEqual(@as(usize, 0), runsIn(&runs, 100, 200).len);
    // The first run is found without walking off the front.
    try testing.expectEqual(@as(usize, 1), runsIn(&runs, 0, 3).len);
}

test "line number column widens with the file" {
    var small: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified };
    var hs = [_]hunk.Hunk{.{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lo = 0, .hi = 3 }};
    small.hunks = &hs;
    try testing.expectEqual(@as(u16, 2), numWidth(&small));

    var big: diff.FileDiff = .{ .old_path = "a", .new_path = "a", .status = .modified };
    var hb = [_]hunk.Hunk{.{ .old_start = 1, .old_count = 1, .new_start = 12000, .new_count = 40, .lo = 0, .hi = 1 }};
    big.hunks = &hb;
    try testing.expectEqual(@as(u16, 5), numWidth(&big));
}
