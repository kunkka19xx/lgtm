// SPDX-License-Identifier: Apache-2.0
//
// The `F` overlay: every changed file in the review, narrowed as you type,
// `Enter` to jump to one (SPEC.md 6.4, FEATURES.md 4.7).
//
// The same shape as `help.zig`, deliberately: a filter, a selection, and the
// grid the last frame drew. Two overlays that behave differently would be two
// things to learn, and there is nothing about a list of files that wants
// different rules from a list of keys.
//
// It is *not* the three-scope fuzzy finder on `f` - that one reaches the whole
// repository and the `look` index, and needs a SQLite reader to do it. This is
// the changed-files scope of it, which needs nothing the review does not
// already have.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("../core/diff.zig");
const event = @import("../core/event.zig");
const frame = @import("frame.zig");
const fuzzy = @import("fuzzy.zig");
const keytext = @import("keytext.zig");
const keymap = @import("keymap.zig");
const prompt_mod = @import("prompt.zig");

/// What a key did to the overlay, for the caller that owns `Mode`.
pub const Fed = enum { stay, close, open };

pub const Files = struct {
    filter: prompt_mod.Prompt = .{},
    /// An index into the *filtered* list, reset by every narrowing for the
    /// same reason the help popup resets it: index 3 of a shorter list is a
    /// different row than the one the reader was looking at.
    index: usize = 0,
    layout: frame.HelpLayout = .{},

    /// Opens on the file the review is already showing, so the list answers
    /// "where am I" before it answers "where else could I be".
    pub fn open(self: *Files, at: usize) void {
        self.filter.start(.help_filter);
        self.index = at;
    }

    pub fn close(self: *Files) void {
        self.filter.close();
    }

    pub fn feed(self: *Files, key: event.Key) Fed {
        return switch (self.filter.feed(key)) {
            .typing => blk: {
                self.index = 0;
                break :blk .stay;
            },
            .submit => .open,
            .cancel => .close,
        };
    }

    /// One row, counted against the list as filtered, so the
    /// selection can never sit past the end of what is on screen.
    pub fn move(self: *Files, files: []const diff.FileDiff, delta: i32) void {
        const n = count(files, self.filter.text());
        if (n == 0) {
            self.index = 0;
            return;
        }
        // Wraps at both ends. A list you step through with Tab should come
        // back round rather than stop dead, and the review's own `]h`/`[h`
        // already read that way.
        const len: i64 = @intCast(n);
        // `@mod`, not `%`: the result must be non-negative so a step up from
        // the first row lands on the last.
        self.index = @intCast(@mod(@as(i64, @intCast(self.index)) + delta, len));
    }

    /// The same step, stopping at the ends. What a page wants: wrapping a
    /// screenful lands nowhere the eye was looking.
    fn moveClamped(self: *Files, files: []const diff.FileDiff, delta: i32) void {
        const n = count(files, self.filter.text());
        if (n == 0) {
            self.index = 0;
            return;
        }
        const i = @as(i64, @intCast(self.index)) + delta;
        self.index = if (i < 0) 0 else if (i >= @as(i64, @intCast(n))) n - 1 else @intCast(i);
    }

    /// One screenful sideways is one column, and the file list has exactly
    /// one - so this is a page, which is the useful reading of `H`/`L` in a
    /// single-column list rather than a key that does nothing.
    pub fn movePage(self: *Files, files: []const diff.FileDiff, delta: i32) void {
        const per: i32 = @intCast(@min(@max(self.layout.per, 1), 1000));
        self.moveClamped(files, delta * per);
    }

    /// Which file the selection points at, as an index into the review's own
    /// file list - which is what the caller needs, since the overlay's indexes
    /// are into a filtered view of it.
    pub fn selected(self: *const Files, files: []const diff.FileDiff) ?u32 {
        var shown: usize = 0;
        for (files, 0..) |f, i| {
            if (fuzzy.match(f.path(), self.filter.text()) == null) continue;
            if (shown == self.index) return @intCast(i);
            shown += 1;
        }
        return null;
    }

    pub fn view(
        self: *Files,
        mode: event.Mode,
        files: []const diff.FileDiff,
        current: u32,
        bindings: []const keymap.Binding,
        arena: Allocator,
    ) Allocator.Error!?frame.FilesView {
        if (mode != .finder) return null;
        const filter = self.filter.text();
        return .{
            .entries = try entries(files, current, filter, arena),
            .query = filter,
            .index = self.index,
            .keys = try keytext.helpEntries(bindings, .finder, "", arena),
            .layout = &self.layout,
        };
    }
};

/// The rows, in review order, narrowed by `query`. Order is the review's, not
/// a ranking: a reader who knows the change knows roughly where a file sits in
/// it, and re-sorting on every keystroke takes that away. The tiers still
/// matter for *which* rows survive, not for where they land.
pub fn entries(
    files: []const diff.FileDiff,
    current: u32,
    query: []const u8,
    arena: Allocator,
) Allocator.Error![]const frame.FileEntry {
    var out: std.ArrayList(frame.FileEntry) = .empty;
    for (files, 0..) |f, i| {
        if (fuzzy.match(f.path(), query) == null) continue;
        try out.append(arena, .{
            .path = f.path(),
            .added = f.added,
            .removed = f.removed,
            .status = f.status,
            .current = i == current,
        });
    }
    return out.toOwnedSlice(arena);
}

/// How many rows survive `query`. Lets the selection be clamped without
/// building the list first.
pub fn count(files: []const diff.FileDiff, query: []const u8) usize {
    var n: usize = 0;
    for (files) |f| {
        if (fuzzy.match(f.path(), query) != null) n += 1;
    }
    return n;
}

/// Where the current file sits in the unfiltered list, which is where the
/// overlay opens.
pub fn rowOf(files: []const diff.FileDiff, current: u32) usize {
    return if (current < files.len) current else 0;
}

const testing = std.testing;

/// Paths and counts are all these tests need; the rest of a `FileDiff` is
/// what the body draws, not what the list does.
fn fixture() [4]diff.FileDiff {
    return .{
        .{ .old_path = "src/ui/app.zig", .new_path = "src/ui/app.zig", .status = .modified, .added = 12, .removed = 4 },
        .{ .old_path = "src/core/diff.zig", .new_path = "src/core/diff.zig", .status = .modified, .added = 1, .removed = 0 },
        .{ .old_path = "README.md", .new_path = "README.md", .status = .modified, .added = 30, .removed = 2 },
        .{ .old_path = "src/ui/app_old.zig", .new_path = "src/ui/app_old.zig", .status = .deleted, .added = 0, .removed = 99 },
    };
}

test "the list is every changed file, in the review's own order" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const files = fixture();

    const rows = try entries(&files, 1, "", a.allocator());
    try testing.expectEqual(@as(usize, 4), rows.len);
    // Review order, not alphabetical and not by size: a reader who knows the
    // change knows roughly where a file sits in it.
    try testing.expectEqualStrings("src/ui/app.zig", rows[0].path);
    try testing.expectEqualStrings("README.md", rows[2].path);
    try testing.expectEqual(@as(u32, 30), rows[2].added);

    // Exactly one row is marked as the one the review is on.
    var marked: usize = 0;
    for (rows) |r| {
        if (r.current) marked += 1;
    }
    try testing.expectEqual(@as(usize, 1), marked);
    try testing.expect(rows[1].current);

    // Status rides along, because a deleted file looks like every other row
    // without it - `+0 −99` is a hint, not a statement.
    try testing.expectEqual(diff.Status.deleted, rows[3].status);
    try testing.expectEqual(diff.Status.modified, rows[0].status);
}

test "typing narrows the list, and the count agrees with it" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const files = fixture();

    // A run of the query as typed.
    try testing.expectEqual(@as(usize, 3), count(&files, "src/"));
    // And scattered letters, which is what makes a path worth typing three
    // characters of: `uiap` finds `src/ui/app.zig`.
    try testing.expectEqual(@as(usize, 2), count(&files, "uiap"));
    try testing.expectEqual(@as(usize, 0), count(&files, "zzz"));

    // Whatever the filter, the list and the count are the same list.
    for ([_][]const u8{ "", "src/", "uiap", "zzz" }) |q| {
        const rows = try entries(&files, 0, q, a.allocator());
        try testing.expectEqual(count(&files, q), rows.len);
    }
}

test "a selection points at a file in the review, not in the filtered view" {
    // The index the overlay moves is into the *filtered* list; what the caller
    // needs is which file that is. Getting this wrong opens the wrong file
    // whenever a filter is in play, which is most of the time.
    const files = fixture();
    var fl: Files = .{};
    fl.open(0);

    try testing.expectEqual(@as(u32, 0), fl.selected(&files).?);
    fl.move(&files, 2);
    try testing.expectEqual(@as(u32, 2), fl.selected(&files).?);

    // With a filter that drops the first two, row 0 is the third file.
    fl.filter.start(.help_filter);
    for ("README") |ch| _ = fl.filter.feed(.{ .codepoint = ch, .mods = .{} });
    fl.index = 0;
    try testing.expectEqual(@as(u32, 2), fl.selected(&files).?);

    // A filter that matches nothing points at no file rather than at file 0.
    for ("zzz") |ch| _ = fl.filter.feed(.{ .codepoint = ch, .mods = .{} });
    try testing.expect(fl.selected(&files) == null);
}

test "the selection wraps, a page clamps, and a filter resets it" {
    const files = fixture();
    var fl: Files = .{};
    fl.open(0);

    // A step wraps at both ends; a page stops.
    fl.move(&files, -1);
    try testing.expectEqual(@as(usize, 3), fl.index);
    fl.move(&files, 1);
    try testing.expectEqual(@as(usize, 0), fl.index);
    fl.movePage(&files, -1);
    try testing.expectEqual(@as(usize, 0), fl.index);
    fl.movePage(&files, 1000);
    try testing.expectEqual(@as(usize, 3), fl.index);

    // Narrowing resets the selection, so it cannot survive into a shorter
    // list and point at a different row than the reader was looking at.
    _ = fl.feed(.{ .codepoint = 'R', .mods = .{} });
    try testing.expectEqual(@as(usize, 0), fl.index);
    fl.movePage(&files, 1000);
    try testing.expectEqual(count(&files, fl.filter.text()) - 1, fl.index);
}

test "the overlay opens on the file the reader is already on" {
    const files = fixture();
    var fl: Files = .{};
    fl.open(rowOf(&files, 2));
    try testing.expectEqual(@as(u32, 2), fl.selected(&files).?);

    // A file index past the end - a review that shrank under the cursor -
    // opens at the top rather than at nothing.
    fl.open(rowOf(&files, 99));
    try testing.expectEqual(@as(u32, 0), fl.selected(&files).?);
}

test "Enter opens, Escape closes, and typing does neither" {
    var fl: Files = .{};
    fl.open(0);
    try testing.expectEqual(Fed.stay, fl.feed(.{ .codepoint = 'a', .mods = .{} }));
    try testing.expectEqual(Fed.open, fl.feed(.{ .codepoint = event.code.enter, .mods = .{} }));
    try testing.expectEqual(Fed.close, fl.feed(.{ .codepoint = event.code.escape, .mods = .{} }));

    // Backspacing out of an empty filter closes it, the way it does in the
    // `?` overlay and in every prompt.
    fl.open(0);
    try testing.expectEqual(Fed.close, fl.feed(.{ .codepoint = event.code.backspace, .mods = .{} }));
}
