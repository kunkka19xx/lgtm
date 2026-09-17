// SPDX-License-Identifier: Apache-2.0
//
// `lgtm risk`: what the change did to the tests.
//
// The one question in this tool that git cannot answer at all. `git diff`
// shows a deleted test and an added skip exactly the way it shows a renamed
// variable - as lines - and a reader skims them, which is the whole reason
// weakening a test is the cheapest way to turn a red build green.
//
// `core/testrisk.zig` has counted this on every re-diff since it was written.
// What was missing is a way to read the answer without sitting in the pane, and
// an exit code, so the question can be asked by something that is not a person.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("../core/diff.zig");
const git = @import("../core/git.zig");
const testrisk = @import("../core/testrisk.zig");
const highlight = @import("../syntax/highlight.zig");
const i18n = @import("../i18n/i18n.zig");
const path_mod = @import("path.zig");
const preview = @import("preview.zig");
const theme_mod = @import("theme.zig");
const wrap = @import("wrap.zig");

const Glyphs = theme_mod.Glyphs;
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

const margin = 1;
const gap = 2;

/// Lines shown per file before the rest are counted instead. A file that
/// deleted forty tests has made its point by the eighth.
const max_places = 8;

const metrics: wrap.Metrics = .{ .method = .unicode };

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// A line that is itself the finding: a test declaration that went, a skip
/// that arrived.
pub const Place = struct {
    /// In the old file for a removal, the new one for an addition - the same
    /// number the reader would scroll to.
    line: u32,
    added: bool,
    text: []const u8,
};

/// One file that checks less than it did.
pub const Finding = struct {
    path: []const u8,
    risk: testrisk.Risk,
    /// Empty when the only signal is a count: a fallen assertion total is a
    /// property of the file, and pointing at one arbitrary removed line would
    /// be pointing at evidence rather than at the thing.
    places: []const Place = &.{},
    /// Places past `max_places`, which are counted rather than printed.
    more: u32 = 0,
};

pub const Options = struct {
    theme: Theme,
    glyphs: Glyphs,
    colour: bool,
    cols: ?u16 = null,
    base: []const u8 = "HEAD",
    target: ?[]const u8 = null,
    ignore: []const []const u8 = &.{},
    /// Fail on a fallen assertion count as well. Off by default, because a
    /// refactor that merges two checks into one looks the same from here and a
    /// build that fails on it is a build people learn to re-run.
    strict: bool = false,
};

/// Diffs, scans, prints, and answers with the code the shell should get.
pub fn run(gpa: Allocator, io: std.Io, w: *std.Io.Writer, opts: Options) Error!u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = (if (opts.target) |t|
        git.diffAt(arena, io, null, opts.ignore, opts.base, t)
    else
        git.diffPathsIn(arena, io, null, &.{}, opts.ignore, opts.base)) catch |err| switch (err) {
        error.NotARepository => {
            try w.print("lgtm: {s}\n", .{i18n.t("not a git repository")});
            return 1;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try w.print("lgtm: {s}\n", .{i18n.t("could not read the diff")});
            return 1;
        },
    };

    const found = try collect(arena, parsed.diff.files);
    try draw(arena, w, found, opts);
    return verdict(found, opts.strict);
}

/// Zero when nothing was weakened, one when something was.
///
/// The two certain signals fail a build; a fallen assertion count only does
/// under `--strict`. A check that cries wolf is a check somebody switches off,
/// and then it is worse than never having been written.
pub fn verdict(found: []const Finding, strict: bool) u8 {
    for (found) |f| {
        if (f.risk.certain()) return 1;
        if (strict and f.risk.any()) return 1;
    }
    return 0;
}

/// Every file the scanner has something to say about.
///
/// A language nobody has described yields nothing rather than a guess, and a
/// file too large to have been parsed has no lines to compare - both of which
/// mean silence far more often than not, which is the point.
fn collect(arena: Allocator, files: []const diff.FileDiff) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (files) |*f| {
        const lang = highlight.forPath(f.path()) orelse continue;
        const found = try testrisk.scanRows(arena, f, lang);
        const risk = found.risk;
        if (!risk.any()) continue;

        var places: std.ArrayList(Place) = .empty;
        var more: u32 = 0;
        for (found.rows, 0..) |hit, i| {
            if (!hit) continue;
            if (places.items.len == max_places) {
                more += 1;
                continue;
            }
            const added = f.lines.kind[i] == .add;
            try places.append(arena, .{
                .line = if (added) f.lines.new_no[i] else f.lines.old_no[i],
                .added = added,
                .text = std.mem.trim(u8, f.lines.text[i], " \t"),
            });
        }
        try out.append(arena, .{
            .path = f.path(),
            .risk = risk,
            .places = places.items,
            .more = more,
        });
    }
    return out.items;
}

/// The findings, then one line that adds them up.
pub fn draw(arena: Allocator, w: *std.Io.Writer, found: []const Finding, opts: Options) Error!void {
    const t = opts.theme;
    try w.writeByte('\n');

    if (found.len == 0) {
        try w.splatByteAll(' ', margin);
        try paint(w, opts, t.dim, i18n.t("nothing weakened: the tests check as much as they did"));
        try w.writeAll("\n\n");
        return;
    }

    // One width for every line number in the report, not one per file: the
    // numbers are a column, and a column that restarts is a list.
    var no_w: u16 = 0;
    for (found) |f| for (f.places) |p| {
        var buf: [16]u8 = undefined;
        no_w = @max(no_w, wrap.columns(std.fmt.bufPrint(&buf, "{d}", .{p.line}) catch "", metrics));
    };

    var total: testrisk.Risk = .{};
    for (found) |f| {
        total.add(f.risk);

        try w.splatByteAll(' ', margin);
        try paint(w, opts, t.path, f.path);
        try w.splatByteAll(' ', gap);
        try paint(w, opts, t.removed_count, try summary(arena, f.risk));
        try w.writeByte('\n');

        for (f.places) |p| {
            var buf: [16]u8 = undefined;
            const no = std.fmt.bufPrint(&buf, "{d}", .{p.line}) catch "";
            try w.splatByteAll(' ', margin + gap + no_w - wrap.columns(no, metrics));
            try paint(w, opts, t.line_no, no);
            try w.splatByteAll(' ', gap);
            try paint(
                w,
                opts,
                if (p.added) t.add_sign else t.del_sign,
                if (p.added) opts.glyphs.add else opts.glyphs.del,
            );
            try w.writeByte(' ');
            // The head of the line, not its middle: a test declaration says
            // what it is in its first few words.
            try paint(w, opts, t.text, try path_mod.clip(
                arena,
                p.text,
                (opts.cols orelse std.math.maxInt(u16)) -| (margin + gap + no_w + gap + 2),
                opts.glyphs.ellipsis,
                metrics,
            ));
            try w.writeByte('\n');
        }
        if (f.more > 0) {
            try w.splatByteAll(' ', margin + gap + no_w + gap + 2);
            try paint(w, opts, t.dim, try i18n.allocPrint(arena, "{d} more like these", .{f.more}));
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    try w.splatByteAll(' ', margin);
    // Two sentences rather than one with a suffix: the verb and the pronoun
    // both change with the count, and "1 file check less than they did" is
    // what a suffix gets you.
    try paint(w, opts, t.text, if (found.len == 1)
        i18n.t("1 file checks less than it did")
    else
        try i18n.allocPrint(arena, "{d} files check less than they did", .{found.len}));
    try paint(w, opts, t.dim, ": ");
    try paint(w, opts, t.removed_count, try summary(arena, total));
    try w.writeAll("\n\n");
}

/// What one risk says, in words. The same three phrases the pane uses, in the
/// same order and from the same strings, so a reader who has seen one has read
/// the other.
fn summary(arena: Allocator, r: testrisk.Risk) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [64]u8 = undefined;
    if (r.removed > 0) {
        try out.appendSlice(arena, i18n.bufPrint(&buf, "{d} test{s} removed", .{
            r.removed, if (r.removed == 1) "" else "s",
        }) catch "");
    }
    if (r.skipped > 0) {
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, i18n.bufPrint(&buf, "{d} skip{s} added", .{
            r.skipped, if (r.skipped == 1) "" else "s",
        }) catch "");
    }
    if (r.fewer_asserts > 0) {
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, i18n.bufPrint(&buf, "{d} fewer assertion{s}", .{
            r.fewer_asserts, if (r.fewer_asserts == 1) "" else "s",
        }) catch "");
    }
    // A deleted file that held tests, with nothing else to say about it.
    if (out.items.len == 0 and r.file_deleted) {
        try out.appendSlice(arena, i18n.t("the file it tested is gone"));
    }
    return out.items;
}

fn paint(w: *std.Io.Writer, opts: Options, style: Style, text: []const u8) std.Io.Writer.Error!void {
    if (!opts.colour or text.len == 0) return w.writeAll(text);
    return preview.styled(w, style, text);
}

const testing = std.testing;

const test_opts: Options = .{
    .theme = theme_mod.default,
    .glyphs = Glyphs.ascii,
    .colour = false,
};

const test_found: []const Finding = &.{
    .{
        .path = "src/core/auth.zig",
        .risk = .{ .removed = 2 },
        .places = &.{
            .{ .line = 47, .added = false, .text = "test \"rejects an expired token\" {" },
            .{ .line = 51, .added = false, .text = "test \"rejects another issuer\" {" },
        },
    },
    .{
        .path = "src/ui/app.zig",
        .risk = .{ .skipped = 1, .fewer_asserts = 3 },
        .places = &.{
            .{ .line = 112, .added = true, .text = "return error.SkipZigTest;" },
        },
    },
};

fn drawn(arena: Allocator, buf: []u8, found: []const Finding, opts: Options) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try draw(arena, &w, found, opts);
    return w.buffered();
}

test "a weakened file is named, counted, and pointed at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_found, test_opts);

    try testing.expect(std.mem.indexOf(u8, out, "src/core/auth.zig  2 tests removed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "47  - test \"rejects an expired token\" {") != null);
    // A skip arrived rather than left, so it reads as an addition.
    try testing.expect(std.mem.indexOf(u8, out, "112  + return error.SkipZigTest;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 skip added, 3 fewer assertions") != null);
}

test "the last line adds up every file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_found, test_opts);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "2 files check less than they did: 2 tests removed, 1 skip added, 3 fewer assertions",
    ) != null);
}

test "one file is a file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_found[0..1], test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "1 file checks less than it did") != null);
}

test "a clean change says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, &.{}, test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "nothing weakened") != null);
}

test "the line numbers are one column across every file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_found, test_opts);

    // 47 is padded to the width of 112, or the signs do not line up.
    try testing.expect(std.mem.indexOf(u8, out, "    47  -") != null);
    try testing.expect(std.mem.indexOf(u8, out, "   112  +") != null);
}

test "a removed test fails the build; a fallen assertion count only does when asked" {
    const removed: []const Finding = &.{.{ .path = "a.zig", .risk = .{ .removed = 1 } }};
    const skipped: []const Finding = &.{.{ .path = "a.zig", .risk = .{ .skipped = 1 } }};
    const softer: []const Finding = &.{.{ .path = "a.zig", .risk = .{ .fewer_asserts = 4 } }};

    try testing.expectEqual(@as(u8, 1), verdict(removed, false));
    try testing.expectEqual(@as(u8, 1), verdict(skipped, false));
    try testing.expectEqual(@as(u8, 0), verdict(softer, false));
    try testing.expectEqual(@as(u8, 1), verdict(softer, true));
    try testing.expectEqual(@as(u8, 0), verdict(&.{}, true));
}
