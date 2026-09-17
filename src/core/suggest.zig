// SPDX-License-Identifier: Apache-2.0
//
// A ```suggestion block is an edit, not a paragraph about one. Drawn as its
// fence, the reader diffs it in their head against the lines above.
//
// A walker, so nothing is allocated and a long body is not capped. Drawing a
// note and measuring its height both run it, which is what keeps them agreeing
// on a height that now depends on the file as well as the remark.

const std = @import("std");
const diff = @import("diff.zig");

pub const open_fence = "```suggestion";

/// The most lines one suggestion is shown against; a span comes from a visual
/// selection. What does not fit is not drawn.
pub const max_replaced = 64;

pub const Kind = enum { prose, removed, added };

/// One row of a drawn comment. Borrowed from the body and the file, both of
/// which outlive the walk.
pub const Line = struct { text: []const u8, kind: Kind };

/// The cheap test that keeps an ordinary remark from looking up lines.
pub fn has(body: []const u8) bool {
    return std.mem.indexOf(u8, body, open_fence) != null;
}

/// The lines a suggestion on `line` covering `span` replaces, in one pass.
pub fn replaced(f: *const diff.FileDiff, line: u32, span: u32, buf: [][]const u8) []const []const u8 {
    if (line == 0 or buf.len == 0) return &.{};
    var n: usize = 0;
    var i: u32 = 0;
    while (i < f.lines.len()) : (i += 1) {
        const no = f.lines.new_no[i];
        if (no < line or no >= line + @max(span, 1)) continue;
        buf[n] = f.lines.text[i];
        n += 1;
        if (n == buf.len) break;
    }
    return buf[0..n];
}

pub fn walk(body: []const u8, old: []const []const u8) Walker {
    return .{ .body = std.mem.splitScalar(u8, body, '\n'), .old = old };
}

pub const Walker = struct {
    body: std.mem.SplitIterator(u8, .scalar),
    old: []const []const u8,
    at: usize = 0,
    /// Emitting the replaced lines, which come before what replaces them.
    leaving: bool = false,
    inside: bool = false,

    pub fn next(self: *Walker) ?Line {
        if (self.leaving) {
            if (self.at < self.old.len) {
                const t = self.old[self.at];
                self.at += 1;
                return .{ .text = t, .kind = .removed };
            }
            self.leaving = false;
        }
        while (self.body.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!self.inside) {
                if (!opens(line)) return .{ .text = line, .kind = .prose };
                self.inside = true;
                // The line has gone from the diff; the proposal still reads.
                if (self.old.len == 0) continue;
                self.leaving = true;
                return self.next();
            }
            // Unclosed, the rest of the body is the proposal.
            if (closes(line)) {
                self.inside = false;
                continue;
            }
            return .{ .text = line, .kind = .added };
        }
        return null;
    }
};

fn opens(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), open_fence);
}

fn closes(line: []const u8) bool {
    const bare = std.mem.trim(u8, line, " \t");
    if (bare.len < 3) return false;
    for (bare) |c| {
        if (c != '`') return false;
    }
    return true;
}

const testing = std.testing;

fn collect(gpa: std.mem.Allocator, body: []const u8, old: []const []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var w = walk(body, old);
    while (w.next()) |l| try out.append(gpa, l);
    return out.toOwnedSlice(gpa);
}

test "a suggestion is the lines it replaces against the lines it proposes" {
    const gpa = testing.allocator;
    const body = "this reads better:\n```suggestion\nconst b = 2;\n```";
    const old = [_][]const u8{"const a = 1;"};
    const got = try collect(gpa, body, &old);
    defer gpa.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Kind.prose, got[0].kind);
    try testing.expectEqualStrings("this reads better:", got[0].text);
    try testing.expectEqual(Kind.removed, got[1].kind);
    try testing.expectEqualStrings("const a = 1;", got[1].text);
    try testing.expectEqual(Kind.added, got[2].kind);
    try testing.expectEqualStrings("const b = 2;", got[2].text);
}

test "a body with no suggestion is prose, line for line" {
    const gpa = testing.allocator;
    const body = "one\ntwo\nthree";
    const got = try collect(gpa, body, &.{});
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    for (got) |l| try testing.expectEqual(Kind.prose, l.kind);
    try testing.expect(!has(body));
}

test "a multi-line suggestion shows every line out and every line in" {
    const gpa = testing.allocator;
    const body = "```suggestion\nx\ny\nz\n```\nand a word after.";
    const old = [_][]const u8{ "a", "b" };
    const got = try collect(gpa, body, &old);
    defer gpa.free(got);

    try testing.expectEqual(@as(usize, 6), got.len);
    try testing.expectEqual(Kind.removed, got[0].kind);
    try testing.expectEqual(Kind.removed, got[1].kind);
    try testing.expectEqual(Kind.added, got[2].kind);
    try testing.expectEqual(Kind.added, got[4].kind);
    // Prose after the block is prose again.
    try testing.expectEqual(Kind.prose, got[5].kind);
    try testing.expectEqualStrings("and a word after.", got[5].text);
}

test "a stale suggestion still reads, with nothing to show as replaced" {
    const gpa = testing.allocator;
    const body = "```suggestion\nnew\n```";
    const got = try collect(gpa, body, &.{});
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Kind.added, got[0].kind);
}

test "an unclosed fence proposes the rest of the remark" {
    const gpa = testing.allocator;
    const body = "```suggestion\nnew line\nanother";
    const old = [_][]const u8{"old"};
    const got = try collect(gpa, body, &old);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Kind.removed, got[0].kind);
    try testing.expectEqual(Kind.added, got[1].kind);
    try testing.expectEqual(Kind.added, got[2].kind);
}

test "a fence that is not a suggestion stays prose" {
    const gpa = testing.allocator;
    const body = "look:\n```zig\nconst a = 1;\n```";
    const old = [_][]const u8{"whatever"};
    const got = try collect(gpa, body, &old);
    defer gpa.free(got);
    for (got) |l| try testing.expectEqual(Kind.prose, l.kind);
}
