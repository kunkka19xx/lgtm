// SPDX-License-Identifier: Apache-2.0
//
// The diff body: the rows between the two rules. One screen row at a time,
// and only the visible ones - the row model is built per diff, the strings
// per frame (PERFORMANCE.md 7.5).
//
// Everything here draws through `Frame` and reads through `View`; neither the
// diff pipeline nor the terminal is reachable from this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const diff = @import("../core/diff.zig");
const hunk = @import("../core/hunk.zig");
const buffer = @import("../text/buffer.zig");
const lexer = @import("../syntax/lexer.zig");
const search = @import("search.zig");
const rows_mod = @import("rows.zig");

const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const View = frame_mod.View;
const Theme = frame_mod.Theme;
const withBg = frame_mod.withBg;

pub fn draw(f: Frame, v: View, top: u16, height: u16) Allocator.Error!void {
    var screen_row: u16 = 0;
    while (screen_row < height) : (screen_row += 1) {
        const idx = v.scroll + screen_row;
        if (idx >= v.rows.len()) break;
        const mark: Mark = .{
            .cursor = idx == v.cursor,
            .selected = if (v.selection) |sel| sel.contains(idx) else false,
        };
        try drawRow(f, v, top + screen_row, v.rows.items[idx], mark);
    }
}

/// How a body row is standing out, if it is. Two independent bits rather than
/// one enum: the cursor is *inside* a selection for all but the first row of
/// it, and both have to be visible at once or the reader loses the cursor.
const Mark = struct {
    cursor: bool = false,
    selected: bool = false,

    fn background(self: Mark, t: Theme) ?vaxis.Color {
        if (self.cursor) return t.cursor_line.bg;
        if (self.selected) return t.selection.bg;
        return null;
    }
};

fn drawRow(f: Frame, v: View, row: u16, r: rows_mod.Row, mark: Mark) Allocator.Error!void {
    switch (r) {
        .gap => {
            const cols = if (f.width() > 6) f.width() - 6 else f.width();
            f.put(row, 3, try f.rule(f.glyphs.gap, cols), f.theme.rule);
        },
        .summarised => _ = try f.print(
            row,
            0,
            f.theme.dim,
            "  {d} lines changed - too large to render inline, not discarded",
            .{v.file.added + v.file.removed},
        ),
        .hunk_header => |hi| try drawHunkHeader(f, v, row, hi),
        .line => |li| try drawLine(f, v, row, li, mark),
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

fn drawLine(f: Frame, v: View, row: u16, li: u32, mark: Mark) Allocator.Error!void {
    const lines = v.file.lines;
    if (li >= lines.len()) return;
    const kind = lines.kind[li];
    const t = f.theme;
    const g = f.glyphs;

    const bg: ?vaxis.Color = mark.background(t);

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

    // A highlighted row is filled first so it spans the full width, not just
    // the columns that happen to carry text.
    if (bg) |b| {
        var c: u16 = 0;
        while (c < f.width()) : (c += 1) {
            f.win.writeCell(c, row, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = b } });
        }
    }

    f.put(row, 0, prefix, sign_style);
    const col = f.win.gwidth(prefix);
    try drawCode(f, v, row, col, li, kind, bg);
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

    var segs: std.ArrayList(vaxis.Segment) = .empty;

    build: {
        const buf = src orelse break :build;
        if (runs.len == 0 or no == 0 or no > buf.lineCount()) break :build;
        const lo = buf.starts[no - 1];
        const hi = lo + @as(u32, @intCast(text.len));

        for (runsIn(runs, lo, hi)) |r| {
            const s = @max(r.start, lo);
            const e = @min(r.end(), hi);
            if (e <= s) continue;
            try segs.append(f.arena, .{
                .text = buf.bytes[s..e],
                .style = withBg(f.theme.forKind(r.kind), bg),
            });
        }
    }
    // Unstyled is the fallback for every reason the lexer had nothing to say -
    // an unattached file, an unknown language, a line past the buffer.
    if (segs.items.len == 0) try segs.append(f.arena, .{ .text = text, .style = plain });

    if (v.query.len > 0) {
        segs = try markMatches(f.arena, segs, v.query, f.theme.search_match);
    }
    _ = f.win.print(segs.items, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

/// Splits segments so every occurrence of `query` gets `style`.
///
/// Done on the segments rather than by overwriting cells afterwards, because a
/// byte offset is not a column: a tab or a wide glyph earlier in the line
/// would put the highlight somewhere else entirely. A match straddling two
/// lexer runs comes out as two highlighted pieces, which reads the same.
fn markMatches(
    arena: Allocator,
    segs: std.ArrayList(vaxis.Segment),
    query: []const u8,
    style: vaxis.Style,
) Allocator.Error!std.ArrayList(vaxis.Segment) {
    const sensitive = search.caseSensitive(query);
    var out: std.ArrayList(vaxis.Segment) = .empty;

    for (segs.items) |seg| {
        var rest = seg.text;
        while (indexOfMatch(rest, query, sensitive)) |at| {
            if (at > 0) try out.append(arena, .{ .text = rest[0..at], .style = seg.style });
            try out.append(arena, .{ .text = rest[at..][0..query.len], .style = style });
            rest = rest[at + query.len ..];
        }
        if (rest.len > 0) try out.append(arena, .{ .text = rest, .style = seg.style });
    }
    return out;
}

fn indexOfMatch(haystack: []const u8, needle: []const u8, sensitive: bool) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (sensitive) return std.mem.indexOf(u8, haystack, needle);

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return i;
    }
    return null;
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

test "match highlighting splits segments without losing or duplicating bytes" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const plain: vaxis.Style = .{};
    const hit: vaxis.Style = .{ .bold = true };

    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = "let token = ", .style = plain });
    try segs.append(arena, .{ .text = "tokenise();", .style = plain });

    const out = try markMatches(arena, segs, "token", hit);

    // Every byte survives, in order: a highlight that eats text is worse than
    // no highlight at all.
    var joined: std.ArrayList(u8) = .empty;
    var marked: usize = 0;
    for (out.items) |seg| {
        try joined.appendSlice(arena, seg.text);
        if (seg.style.bold) marked += 1;
    }
    try testing.expectEqualStrings("let token = tokenise();", joined.items);
    try testing.expectEqual(@as(usize, 2), marked);
}

test "match highlighting follows smart case and leaves a clean line alone" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try segs.append(arena, .{ .text = "TokenStore", .style = .{} });

    // Lowercase query: matches either case.
    const loose = try markMatches(arena, segs, "token", .{ .bold = true });
    try testing.expect(loose.items[0].style.bold);

    // A capital pins it, so this one does not match at all - and an unmatched
    // line comes back as the single segment it went in as.
    const strict = try markMatches(arena, segs, "TOKEN", .{ .bold = true });
    try testing.expectEqual(@as(usize, 1), strict.items.len);
    try testing.expect(!strict.items[0].style.bold);
    try testing.expectEqualStrings("TokenStore", strict.items[0].text);
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
