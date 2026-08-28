// SPDX-License-Identifier: Apache-2.0
//
// The row model: what the diff body is, one screen row at a time, before any
// terminal is involved.
//
// Structure only - no text is formatted here. A row is a few bytes naming
// where its content comes from, so the list is built once per re-diff (from
// the diff arena) while the strings are built per frame for visible rows only
// (PERFORMANCE.md 7.5). Keeping this file free of vaxis is what lets the
// layout be tested without a terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("../core/diff.zig");
const hunk = @import("../core/hunk.zig");

pub const Row = union(enum) {
    /// Index into `FileDiff.hunks`.
    hunk_header: u32,
    /// Index into `FileDiff.lines`.
    line: u32,
    /// The inset rule drawn between two hunks of the same file.
    gap,
    /// The file exceeded `large_file_lines`, so its body was never parsed.
    /// Deferring is not discarding: core/diff.zig retains the bytes and can
    /// materialise them on demand.
    summarised,
};

pub const Rows = struct {
    /// No file, or no file yet. Spelled once so the callers that reset a
    /// generation do not each have to know the shape of an empty one.
    pub const empty: Rows = .{ .items = &.{}, .hunk_rows = &.{} };

    items: []Row,
    /// Row index of each hunk's header, in file order. What `]h` and `[h` step
    /// through, and what turns a cursor row into "#3 of 9".
    hunk_rows: []u32,

    pub fn deinit(self: *Rows, gpa: Allocator) void {
        gpa.free(self.items);
        gpa.free(self.hunk_rows);
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
            else => null,
        };
    }

    /// The reverse: which row draws line `li`. Search finds a line index by
    /// scanning `DiffLines` - which works for files whose rows were never
    /// built - and this is what turns that answer back into a cursor position.
    pub fn rowForLine(self: Rows, li: u32) ?u32 {
        for (self.items, 0..) |r, i| {
            if (r == .line and r.line == li) return @intCast(i);
        }
        return null;
    }

    /// First row that is a diff line, so the cursor never opens on a header or
    /// a rule - neither is something you can point an agent at.
    pub fn firstLineRow(self: Rows) u32 {
        for (self.items, 0..) |r, i| {
            if (r == .line) return @intCast(i);
        }
        return 0;
    }
};

/// Builds the rows for one file: each hunk's header, then its lines, with a
/// rule between hunks but never before the first or after the last.
pub fn build(gpa: Allocator, f: *const diff.FileDiff) Allocator.Error!Rows {
    var items: std.ArrayList(Row) = .empty;
    errdefer items.deinit(gpa);
    var hunk_rows: std.ArrayList(u32) = .empty;
    errdefer hunk_rows.deinit(gpa);

    if (f.summarised) {
        try items.append(gpa, .summarised);
        return .{
            .items = try items.toOwnedSlice(gpa),
            .hunk_rows = try hunk_rows.toOwnedSlice(gpa),
        };
    }

    for (f.hunks, 0..) |h, hi| {
        if (hi > 0) try items.append(gpa, .gap);
        try hunk_rows.append(gpa, @intCast(items.items.len));
        try items.append(gpa, .{ .hunk_header = @intCast(hi) });
        var i = h.lo;
        while (i < h.hi) : (i += 1) try items.append(gpa, .{ .line = i });
    }

    const owned_items = try items.toOwnedSlice(gpa);
    errdefer gpa.free(owned_items);
    return .{
        .items = owned_items,
        .hunk_rows = try hunk_rows.toOwnedSlice(gpa),
    };
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

test "a file with no hunks produces no rows and no crash" {
    const gpa = testing.allocator;
    var f: diff.FileDiff = .{ .old_path = "e", .new_path = "e", .status = .modified };
    var rows = try build(gpa, &f);
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), rows.len());
    try testing.expect(rows.nextHunkRow(0) == null);
    try testing.expectEqual(@as(u32, 0), rows.firstLineRow());
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
