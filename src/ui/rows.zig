// SPDX-License-Identifier: Apache-2.0
//
// The row model: what the diff body is, one screen row at a time, before any
// terminal is involved.
//
// Structure only - no text is formatted here. A row is a few bytes naming
// where its content comes from, so the list is built once per re-diff (from
// the diff arena) while the strings are built per frame for visible rows only
//. Keeping this file free of vaxis is what lets the
// layout be tested without a terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("../core/diff.zig");
const hunk = @import("../core/hunk.zig");

/// Which body the rows describe. Structure, not decoration: the two layouts
/// emit different rows for the same file, so switching is a rebuild.
///
/// `flow` is the one-column diff - the format every other tool calls unified.
pub const Layout = enum { flow, split };

/// One row of the split layout: the old file's line on the left, the new
/// file's on the right. Either side may be absent - a removal with nothing
/// opposite it, or the padding under a run that ran out.
///
/// A context line is the same index on both sides, because the diff stores it
/// once and it is the same text in both files.
pub const Pair = struct { left: ?u32 = null, right: ?u32 = null };

pub const Row = union(enum) {
    /// Index into `FileDiff.hunks`.
    hunk_header: u32,
    /// Index into `FileDiff.lines`.
    line: u32,
    /// Two lines abreast, one from each side of the change. Index into
    /// `Rows.pairs`. Only the split layout emits these; the flow one emits
    /// `.line`, and no list holds both.
    pair: u32,
    /// The inset rule drawn between two hunks of the same file.
    gap,
    /// A note, drawn under the line it was written against - the way a review
    /// comment sits under its code. Index into the frame's note list.
    ///
    /// A row of its own rather than something painted over the line, because
    /// everything that counts rows already works: it scrolls, it wraps, and
    /// the motions step past it the way they step past a hunk header.
    note: u32,
    /// The file exceeded `large_file_lines`, so its body was never parsed.
    /// Deferring is not discarding: core/diff.zig retains the bytes and `zo`
    /// materialises them (`Review.expand`), after which this row is gone and
    /// the file has hunks like any other.
    summarised,
    /// The file is not text. One row saying what it is instead of a screen of
    /// its bytes; `FileDiff.bin` holds what the row draws.
    binary,
};

pub const Rows = struct {
    /// No file, or no file yet. Spelled once so the callers that reset a
    /// generation do not each have to know the shape of an empty one.
    pub const empty: Rows = .{ .items = &.{}, .hunk_rows = &.{}, .pairs = &.{} };

    items: []Row,
    /// Row index of each hunk's header, in file order. What `]h` and `[h` step
    /// through, and what turns a cursor row into "#3 of 9".
    hunk_rows: []u32,
    /// What each `.pair` row holds. Empty under the flow layout.
    pairs: []Pair = &.{},

    pub fn deinit(self: *Rows, gpa: Allocator) void {
        gpa.free(self.items);
        gpa.free(self.hunk_rows);
        gpa.free(self.pairs);
        self.* = undefined;
    }

    pub fn len(self: Rows) u32 {
        return @intCast(self.items.len);
    }

    /// Index of the hunk containing `row`, or null above the first header.
    pub fn hunkAt(self: Rows, row: u32) ?u32 {
        if (self.hunk_rows.len == 0) return null;
        var i: usize = self.hunk_rows.len;
        while (i > 0) {
            i -= 1;
            if (self.hunk_rows[i] <= row) return @intCast(i);
        }
        return null;
    }

    /// Row of the next hunk header strictly after `row`, or null at the end.
    /// Reporting the end rather than wrapping is what lets the caller decide
    /// what the end means: `app.stepHunk` wraps and says so in the status
    /// line, which it could not do if the wrap were hidden in here.
    pub fn nextHunkRow(self: Rows, row: u32) ?u32 {
        for (self.hunk_rows) |h| {
            if (h > row) return h;
        }
        return null;
    }

    pub fn prevHunkRow(self: Rows, row: u32) ?u32 {
        var i: usize = self.hunk_rows.len;
        while (i > 0) {
            i -= 1;
            if (self.hunk_rows[i] < row) return self.hunk_rows[i];
        }
        return null;
    }

    /// Index into `FileDiff.lines` for a row, or null when the row is chrome.
    /// Search and the bridge both need "which line is the cursor on", and a
    /// header is not one.
    pub fn lineAt(self: Rows, row: u32) ?u32 {
        if (row >= self.items.len) return null;
        return switch (self.items[row]) {
            .line => |li| li,
            // The new side is the answer whenever there is one. Comments
            // anchor to new-file line numbers, so a row that changed code is a
            // row that points at the change; a removal with nothing opposite
            // it is the only case where the old side is what the reader means.
            .pair => |pi| if (pi < self.pairs.len)
                (self.pairs[pi].right orelse self.pairs[pi].left)
            else
                null,
            else => null,
        };
    }

    /// Both sides of a split row, or null when the row is chrome or the
    /// layout is flow. The renderer draws two columns from it and the cursor
    /// uses it to know which column it is standing in.
    pub fn pairAt(self: Rows, row: u32) ?Pair {
        if (row >= self.items.len) return null;
        const r = self.items[row];
        if (r != .pair or r.pair >= self.pairs.len) return null;
        return self.pairs[r.pair];
    }

    /// The reverse: which row draws line `li`. Search finds a line index by
    /// scanning `DiffLines` - which works for files whose rows were never
    /// built - and this is what turns that answer back into a cursor position.
    pub fn rowForLine(self: Rows, li: u32) ?u32 {
        for (self.items, 0..) |r, i| switch (r) {
            .line => |n| if (n == li) return @intCast(i),
            // Either side, not the one `lineAt` prefers: a search that found a
            // removed line still has a row to put the cursor on when that line
            // was drawn beside the addition that replaced it.
            .pair => |pi| if (pi < self.pairs.len) {
                const p = self.pairs[pi];
                if (p.left == li or p.right == li) return @intCast(i);
            },
            else => {},
        };
        return null;
    }

    /// First row that is a diff line, so the cursor never opens on a header or
    /// a rule - neither is something you can point an agent at.
    pub fn firstLineRow(self: Rows) u32 {
        for (self.items, 0..) |r, i| {
            if (r == .line or r == .pair) return @intCast(i);
        }
        return 0;
    }
};

/// Width of the line-number column, from the largest number this file shows.
pub fn numWidth(f: *const diff.FileDiff) u16 {
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

/// Columns before a line's text. The two views spend a different number of
/// them, because they are short of different things.
///
/// The flow view has the pane to itself and spends four: `+` or `-`, a column
/// of its own for `]m`'s bar, the number, and two after it - the first being
/// where a note's dot goes, the second being air the code reads better for.
///
/// The split view has halved itself already and spends one: the number, and
/// the single column between it and the code. That column is the separator,
/// the note's dot and the mark's bar, whichever the line has earned. Three
/// things are gone from it and each was saying something already said louder
/// elsewhere - the sign, because the number is coloured and the row washed
/// behind it; the air, because there is none to spare; and the mark's own
/// column, because a marker beside the code reads as well as one before the
/// number and costs half as much.
///
/// The flow view keeps all four precisely because it can afford them, and
/// because it is the one view a terminal without colour can still read.
///
/// Every glyph that goes in here is one column wide in all three icon sets, so
/// this is arithmetic rather than a measurement - which is what lets
/// `ui/app.zig` know how wide a wrapped line is without a terminal to measure
/// on.
pub fn gutter(f: *const diff.FileDiff, layout: Layout) u16 {
    return numWidth(f) + switch (layout) {
        .flow => @as(u16, 4),
        .split => @as(u16, 1),
    };
}

/// The narrowest pane a split view is drawn in at all, whatever the config or
/// a keypress asked for.
///
/// Not the same number as `[diff] split_min_width`, which is where `auto`
/// stops *choosing* side by side. This is where it stops being possible. A
/// gutter of about five columns and twenty-four of code on each side, plus the
/// divider, is fifty-nine; sixty is the round number above it. Below that the
/// split is not cramped, it is broken - two columns too narrow to hold a line
/// of code, with everything in them wrapped eight rows deep.
///
/// A floor rather than a refusal: `|` is suspended while the pane is too
/// small, not forgotten, so widening it brings the split straight back.
pub const min_split_width: u16 = 60;

/// Where the split layout's two columns sit in a pane `cols` wide. One
/// answer, because `ui/body.zig` draws to it and `ui/app.zig` places the
/// cursor by it, and two implementations would disagree on an odd width.
///
/// The divider takes the middle column, so an odd pane gives it the odd one
/// and both sides stay equal - two columns of different widths read as a
/// mistake rather than as a layout.
pub const Split = struct {
    /// Columns the old file has, starting at 0.
    left: u16,
    /// Column the divider is drawn in.
    divider: u16,
    /// First column of the new file, and how many it has.
    right: u16,
    right_width: u16,

    pub fn of(cols: u16) Split {
        // The odd column goes to the new file rather than the old one. On an
        // even pane the two cannot be equal, and the side being reviewed is
        // the one to give it to.
        const left = (cols -| 1) / 2;
        return .{
            .left = left,
            .divider = left,
            .right = left +| 1,
            .right_width = cols -| (left +| 1),
        };
    }

    /// Where a line drawn on `side` starts, and how wide it is.
    pub const Column = struct { at: u16, width: u16 };

    pub fn column(self: Split, side: Side) Column {
        return switch (side) {
            .old => .{ .at = 0, .width = self.left },
            .new => .{ .at = self.right, .width = self.right_width },
        };
    }
};

/// Which file a drawn line comes from. Under the flow layout the kind of the
/// line answers this; under the split one the column does, and a context line
/// is drawn twice from two different buffers.
pub const Side = enum { old, new };

/// Builds the rows for one file: each hunk's header, then its lines, with a
/// rule between hunks but never before the first or after the last.
/// A note as the row builder needs it: which line it hangs under, and where
/// to find its text when the row is drawn.
pub const CommentAt = struct { line: u32, index: u32 };

pub fn build(gpa: Allocator, f: *const diff.FileDiff) Allocator.Error!Rows {
    return buildWith(gpa, f, &.{}, .flow);
}

pub fn buildWith(
    gpa: Allocator,
    f: *const diff.FileDiff,
    notes: []const CommentAt,
    layout: Layout,
) Allocator.Error!Rows {
    var b: Builder = .{ .gpa = gpa, .file = f, .notes = notes, .layout = layout };
    errdefer b.discard();

    if (f.summarised) {
        try b.items.append(gpa, .summarised);
        return b.finish();
    }

    // Nothing to diff and nothing worth drawing line by line. Without this the
    // file has no rows at all, and a header with a void under it does not say
    // why.
    if (f.status == .binary) {
        try b.items.append(gpa, .binary);
        return b.finish();
    }

    // A file with no hunks but with lines is one being *read* rather than
    // reviewed - `<Space>F` on something the agent has not touched. There is
    // no hunk header to draw because there is no hunk: it is the whole file,
    // and every line of it belongs.
    if (f.hunks.len == 0 and f.lines.len() > 0) {
        try b.body(0, @intCast(f.lines.len()));
        return b.finish();
    }

    for (f.hunks, 0..) |h, hi| {
        if (hi > 0) try b.items.append(gpa, .gap);
        try b.hunk_rows.append(gpa, @intCast(b.items.items.len));
        try b.items.append(gpa, .{ .hunk_header = @intCast(hi) });
        try b.body(h.lo, h.hi);
    }
    return b.finish();
}

/// The three lists a row model is, plus the one decision that changes what
/// goes in them. A struct rather than three parameters because the split
/// layout writes to two of them at once and the flow one to one.
const Builder = struct {
    gpa: Allocator,
    file: *const diff.FileDiff,
    notes: []const CommentAt,
    layout: Layout,
    items: std.ArrayList(Row) = .empty,
    hunk_rows: std.ArrayList(u32) = .empty,
    pairs: std.ArrayList(Pair) = .empty,

    fn discard(self: *Builder) void {
        self.items.deinit(self.gpa);
        self.hunk_rows.deinit(self.gpa);
        self.pairs.deinit(self.gpa);
    }

    fn finish(self: *Builder) Allocator.Error!Rows {
        const owned = try self.items.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(owned);
        const hunks = try self.hunk_rows.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(hunks);
        return .{
            .items = owned,
            .hunk_rows = hunks,
            .pairs = try self.pairs.toOwnedSlice(self.gpa),
        };
    }

    /// The lines in `[lo, hi)`, as whatever the layout makes of them.
    fn body(self: *Builder, lo: u32, hi: u32) Allocator.Error!void {
        if (self.layout == .flow) {
            var i = lo;
            while (i < hi) : (i += 1) {
                try self.items.append(self.gpa, .{ .line = i });
                try appendComments(self.gpa, &self.items, self.file, i, self.notes);
            }
            return;
        }

        const kinds = self.file.lines.kind;
        var i = lo;
        while (i < hi) {
            if (kinds[i] == .context) {
                try self.pair(.{ .left = i, .right = i }, i);
                i += 1;
                continue;
            }
            // A run of removals and the run of additions that follows it are
            // one edit, so they go abreast: the reader compares row against
            // row, which is the only thing this layout is for. The shorter
            // run pads, and git never interleaves the two within a hunk.
            const del_lo = i;
            while (i < hi and kinds[i] == .del) i += 1;
            const del_hi = i;
            const add_lo = i;
            while (i < hi and kinds[i] == .add) i += 1;
            const add_hi = i;

            var n: u32 = 0;
            const rows = @max(del_hi - del_lo, add_hi - add_lo);
            while (n < rows) : (n += 1) {
                const l: ?u32 = if (del_lo + n < del_hi) del_lo + n else null;
                const r: ?u32 = if (add_lo + n < add_hi) add_lo + n else null;
                try self.pair(.{ .left = l, .right = r }, r);
            }
        }
    }

    /// One split row, and the notes hanging under whichever line of it can
    /// carry them - which is the new one, because that is the only side a
    /// comment has a line number in.
    fn pair(self: *Builder, p: Pair, note_line: ?u32) Allocator.Error!void {
        try self.items.append(self.gpa, .{ .pair = @intCast(self.pairs.items.len) });
        try self.pairs.append(self.gpa, p);
        if (note_line) |li| try appendComments(self.gpa, &self.items, self.file, li, self.notes);
    }
};

/// Every note hanging under line `li`, in the order they were written.
fn appendComments(
    gpa: Allocator,
    items: *std.ArrayList(Row),
    f: *const diff.FileDiff,
    li: u32,
    notes: []const CommentAt,
) Allocator.Error!void {
    if (notes.len == 0 or li >= f.lines.len()) return;
    const no = f.lines.new_no[li];
    if (no == 0) return;
    for (notes) |n| {
        if (n.line == no) try items.append(gpa, .{ .note = n.index });
    }
}

const testing = std.testing;

fn fixture(gpa: Allocator) !diff.FileDiff {
    // Two hunks, three lines each.
    const n = 6;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, n),
        .old_no = try gpa.alloc(u32, n),
        .new_no = try gpa.alloc(u32, n),
        .text = try gpa.alloc([]const u8, n),
    };
    for (0..n) |i| {
        lines.kind[i] = if (i % 3 == 1) .add else .context;
        lines.old_no[i] = @intCast(i + 1);
        lines.new_no[i] = @intCast(i + 1);
        lines.text[i] = "x";
    }
    const hunks = try gpa.alloc(hunk.Hunk, 2);
    hunks[0] = .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lo = 0, .hi = 3, .id = 3 };
    hunks[1] = .{ .old_start = 9, .old_count = 3, .new_start = 9, .new_count = 3, .lo = 3, .hi = 6, .id = 4 };
    return .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .hunks = hunks,
        .lines = lines,
    };
}

fn freeFixture(gpa: Allocator, f: *diff.FileDiff) void {
    gpa.free(f.hunks);
    f.lines.deinit(gpa);
}

test "rows interleave headers, lines and one rule between hunks" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);

    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    // header + 3 lines, rule, header + 3 lines.
    try testing.expectEqual(@as(u32, 9), rows.len());
    try testing.expect(rows.items[0] == .hunk_header);
    try testing.expect(rows.items[1] == .line);
    try testing.expect(rows.items[4] == .gap);
    try testing.expect(rows.items[5] == .hunk_header);
    // No rule before the first hunk or after the last.
    try testing.expect(rows.items[rows.items.len - 1] == .line);
}

test "hunk lookup maps a cursor row to its hunk" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), rows.hunkAt(0).?);
    try testing.expectEqual(@as(u32, 0), rows.hunkAt(3).?);
    // The rule belongs to the hunk above it, which is what keeps the status
    // line from blanking as the cursor crosses it.
    try testing.expectEqual(@as(u32, 0), rows.hunkAt(4).?);
    try testing.expectEqual(@as(u32, 1), rows.hunkAt(5).?);
    try testing.expectEqual(@as(u32, 1), rows.hunkAt(8).?);
}

test "hunk stepping stops at the ends rather than wrapping" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(u32, 5), rows.nextHunkRow(0).?);
    try testing.expect(rows.nextHunkRow(5) == null);
    try testing.expectEqual(@as(u32, 0), rows.prevHunkRow(5).?);
    try testing.expect(rows.prevHunkRow(0) == null);
}

test "the cursor opens on a line, never on a header" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), rows.firstLineRow());
    try testing.expect(rows.items[rows.firstLineRow()] == .line);
}

test "a summarised file is one row, not zero" {
    const gpa = testing.allocator;
    var f: diff.FileDiff = .{
        .old_path = "big.zig",
        .new_path = "big.zig",
        .status = .modified,
        .summarised = true,
        .added = 9000,
    };
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    // Zero rows would render as an empty screen indistinguishable from a bug.
    try testing.expectEqual(@as(u32, 1), rows.len());
    try testing.expect(rows.items[0] == .summarised);
    try testing.expect(rows.hunkAt(0) == null);
}

test "a binary file is one row, not a screen of its bytes" {
    const gpa = testing.allocator;
    var f: diff.FileDiff = .{
        .old_path = "logo.png",
        .new_path = "logo.png",
        .status = .binary,
        .bin = .{ .kind = "PNG image", .width = 1200, .height = 630, .size = 8705 },
    };
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), rows.len());
    try testing.expect(rows.items[0] == .binary);
    try testing.expect(rows.hunkAt(0) == null);
}

test "a file with no hunks produces no rows and no crash" {
    const gpa = testing.allocator;
    var f: diff.FileDiff = .{ .old_path = "e", .new_path = "e", .status = .modified };
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), rows.len());
    try testing.expect(rows.nextHunkRow(0) == null);
    try testing.expectEqual(@as(u32, 0), rows.firstLineRow());
}

/// A hunk shaped like a real edit: context, two lines replaced by three, and
/// context again. The uneven runs are the point - one side has to pad.
fn replaceFixture(gpa: Allocator) !diff.FileDiff {
    const kinds = [_]hunk.LineKind{ .context, .del, .del, .add, .add, .add, .context };
    const n = kinds.len;
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, n),
        .old_no = try gpa.alloc(u32, n),
        .new_no = try gpa.alloc(u32, n),
        .text = try gpa.alloc([]const u8, n),
    };
    var o: u32 = 1;
    var w: u32 = 1;
    for (kinds, 0..) |k, i| {
        lines.kind[i] = k;
        lines.text[i] = "x";
        lines.old_no[i] = if (k == .add) 0 else blk: {
            defer o += 1;
            break :blk o;
        };
        lines.new_no[i] = if (k == .del) 0 else blk: {
            defer w += 1;
            break :blk w;
        };
    }
    const hunks = try gpa.alloc(hunk.Hunk, 1);
    hunks[0] = .{ .old_start = 1, .old_count = 4, .new_start = 1, .new_count = 5, .lo = 0, .hi = n, .id = 1 };
    return .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .hunks = hunks,
        .lines = lines,
    };
}

test "split puts a removal beside the addition that replaced it" {
    const gpa = testing.allocator;
    var f = try replaceFixture(gpa);
    defer freeFixture(gpa, &f);

    var rows = try buildWith(gpa, &f, &.{}, .split);
    defer rows.deinit(gpa);

    // Header, then context, three rows for the replacement, then context.
    try testing.expectEqual(@as(u32, 6), rows.len());
    try testing.expect(rows.items[0] == .hunk_header);

    // A context line is the same index on both sides.
    try testing.expectEqual(Pair{ .left = 0, .right = 0 }, rows.pairAt(1).?);
    // Two removals against three additions: the third row pads on the left.
    try testing.expectEqual(Pair{ .left = 1, .right = 3 }, rows.pairAt(2).?);
    try testing.expectEqual(Pair{ .left = 2, .right = 4 }, rows.pairAt(3).?);
    try testing.expectEqual(Pair{ .left = null, .right = 5 }, rows.pairAt(4).?);
}

test "a split row answers with the new side, and is found from either" {
    const gpa = testing.allocator;
    var f = try replaceFixture(gpa);
    defer freeFixture(gpa, &f);

    var rows = try buildWith(gpa, &f, &.{}, .split);
    defer rows.deinit(gpa);

    // The addition, not the removal beside it: a comment anchors to a
    // new-file line, so the row points at the code that is there now.
    try testing.expectEqual(@as(u32, 3), rows.lineAt(2).?);
    // Either side finds the row, so a search that landed on a removed line
    // still has somewhere to put the cursor.
    try testing.expectEqual(@as(u32, 2), rows.rowForLine(1).?);
    try testing.expectEqual(@as(u32, 2), rows.rowForLine(3).?);
    try testing.expectEqual(@as(u32, 4), rows.rowForLine(5).?);
    try testing.expect(rows.rowForLine(99) == null);

    // Chrome is still chrome, and the cursor still opens on content.
    try testing.expect(rows.lineAt(0) == null);
    try testing.expect(rows.pairAt(0) == null);
    try testing.expectEqual(@as(u32, 1), rows.firstLineRow());
}

test "a deletion with nothing opposite it is the old side's row" {
    const gpa = testing.allocator;
    const kinds = [_]hunk.LineKind{ .context, .del, .del };
    var lines: hunk.DiffLines = .{
        .kind = try gpa.alloc(hunk.LineKind, kinds.len),
        .old_no = try gpa.alloc(u32, kinds.len),
        .new_no = try gpa.alloc(u32, kinds.len),
        .text = try gpa.alloc([]const u8, kinds.len),
    };
    for (kinds, 0..) |k, i| {
        lines.kind[i] = k;
        lines.text[i] = "x";
        lines.old_no[i] = @intCast(i + 1);
        lines.new_no[i] = if (k == .del) 0 else 1;
    }
    const hunks = try gpa.alloc(hunk.Hunk, 1);
    hunks[0] = .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 1, .lo = 0, .hi = 3, .id = 1 };
    var f: diff.FileDiff = .{
        .old_path = "a.zig",
        .new_path = "a.zig",
        .status = .modified,
        .hunks = hunks,
        .lines = lines,
    };
    defer freeFixture(gpa, &f);

    var rows = try buildWith(gpa, &f, &.{}, .split);
    defer rows.deinit(gpa);

    try testing.expectEqual(Pair{ .left = 1, .right = null }, rows.pairAt(2).?);
    // With no new line to point at, the row is the removal itself - which is
    // what makes a deleted line commentable at all.
    try testing.expectEqual(@as(u32, 1), rows.lineAt(2).?);
}

test "the split layout keeps the hunk walk it inherited" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);

    var rows = try buildWith(gpa, &f, &.{}, .split);
    defer rows.deinit(gpa);

    // Header, three rows, rule, header, three rows: the same shape as flow,
    // because this file replaces nothing and so pairs nothing.
    try testing.expectEqual(@as(u32, 9), rows.len());
    try testing.expectEqual(@as(u32, 5), rows.nextHunkRow(0).?);
    try testing.expectEqual(@as(u32, 1), rows.hunkAt(5).?);
}

test "the split columns account for every one, and the new side gets the odd" {
    // Odd pane: the divider takes the middle and the two sides are equal.
    const odd = Split.of(101);
    try testing.expectEqual(@as(u16, 50), odd.left);
    try testing.expectEqual(@as(u16, 50), odd.divider);
    try testing.expectEqual(@as(u16, 51), odd.right);
    try testing.expectEqual(odd.left, odd.right_width);

    // Even pane: they cannot be equal, and the column goes to the file being
    // reviewed rather than the one being compared against.
    const even = Split.of(130);
    try testing.expectEqual(@as(u16, 64), even.left);
    try testing.expectEqual(@as(u16, 65), even.right_width);

    // Nothing is lost or double-counted at either width.
    for ([_]u16{ 1, 2, 3, 80, 100, 101, 130, 200 }) |cols| {
        const sp = Split.of(cols);
        try testing.expectEqual(cols, sp.left + 1 + sp.right_width);
        try testing.expectEqual(sp.left, sp.divider);
        try testing.expectEqual(sp.divider + 1, sp.right);
    }
}

test "the split gutter is three columns narrower than the flow view's" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);
    const w = numWidth(&f);

    // Sign, mark bar, number, note dot, air.
    try testing.expectEqual(w + 4, gutter(&f, .flow));
    // The number and one column after it, which is separator, note dot and
    // mark bar at once: six columns of code back across the two halves of a
    // pane that had already halved itself.
    try testing.expectEqual(w + 1, gutter(&f, .split));
}

test "rows map to line indexes and back" {
    const gpa = testing.allocator;
    var f = try fixture(gpa);
    defer freeFixture(gpa, &f);
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);

    // Row 0 is a header: it carries no line, and saying so is what keeps the
    // bridge from sending a reference to a `@@` row.
    try testing.expect(rows.lineAt(0) == null);
    try testing.expectEqual(@as(u32, 0), rows.lineAt(1).?);
    try testing.expect(rows.lineAt(4) == null); // the rule
    try testing.expectEqual(@as(u32, 3), rows.lineAt(5 + 1).?);

    // Round trip, including across the rule that shifts every later row.
    try testing.expectEqual(@as(u32, 1), rows.rowForLine(0).?);
    try testing.expectEqual(@as(u32, 6), rows.rowForLine(3).?);
    try testing.expect(rows.rowForLine(99) == null);
    // Out of range is null rather than a trap: a resize can outrun the rows.
    try testing.expect(rows.lineAt(9999) == null);
}
