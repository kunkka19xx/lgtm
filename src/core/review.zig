// SPDX-License-Identifier: Apache-2.0
//
// The review file: every open note as one markdown document the agent reads.
//
// This is the half of the tool that makes comments worth collecting. A reference
// sent per note would be a dozen interruptions; a file written once and named
// in a single line is one. It is also why hard rule 1 is survivable at all -
// comments may contain newlines because they are *written*, and what goes through
// `send-keys` is the sentence that says where the file is.
//
// Pure: comments in, markdown out. No filesystem here - `io/fs.zig` writes it -
// and no bridge, so what the agent is told is decided by a template the user
// can change rather than by a format literal in here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const comments = @import("comments.zig");

/// `.lgtm/review-1.md`, `review-2.md`, and so on. Numbered rather than
/// timestamped so the line sent to the agent is short and so a reader can say
/// "the second review" and be understood.
pub fn fileName(buf: []u8, n: u32) []const u8 {
    return std.fmt.bufPrint(buf, "review-{d}.md", .{n}) catch "review.md";
}

pub fn path(buf: []u8, n: u32) []const u8 {
    return std.fmt.bufPrint(buf, ".lgtm/review-{d}.md", .{n}) catch ".lgtm/review.md";
}

/// Renders the open comments, grouped by file and ordered by line within each.
///
/// Grouped because that is how the agent will act on them: everything about
/// one file at once, top to bottom, so it reads the way a human review reads.
/// The store's own order is insertion order, which is the order the *reader*
/// found things in - useful for `]c`, useless for someone about to make the
/// changes.
///
/// Open and stale comments, not sent ones. A sent note has been acted on or
/// ignored already and asking again would be asking twice - but a *stale* one
/// is still something the reader wrote and has not dismissed, so it goes in
/// with a warning rather than being dropped on its way to the agent. Hard rule
/// 7 does not stop at the screen.
pub fn render(out: *std.ArrayList(u8), gpa: Allocator, store: *const comments.Store, n: u32) Allocator.Error!u32 {
    var num: [24]u8 = undefined;
    try out.appendSlice(gpa, "# Review ");
    try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n}) catch "");
    try out.appendSlice(gpa, "\n");

    var written: u32 = 0;
    // Files in first-appearance order, without allocating a set: the comment
    // count is small enough that a scan per file is cheaper than a hash map,
    // and it keeps the output stable between runs.
    for (store.items(), 0..) |note, i| {
        if (note.state == .sent) continue;
        var already = false;
        for (store.items()[0..i]) |prev| {
            if (prev.state != .sent and std.mem.eql(u8, prev.path, note.path)) already = true;
        }
        if (already) continue;

        try out.appendSlice(gpa, "\n## ");
        try out.appendSlice(gpa, note.path);
        try out.appendSlice(gpa, "\n");

        // Sorted by line within the file, by selection rather than by sorting
        // a copy: there is no allocation to fail and the lists are tiny.
        // Ordered by (line, id), not by line alone. Two comments on one line
        // is ordinary - a reader has two things to say about the same call -
        // and ordering by line only made the second one unreachable: it was
        // never "after" the first, so the walk stopped and the review file
        // silently held half of what was written.
        var last: u32 = 0;
        var last_id: u32 = 0;
        var first = true;
        while (true) {
            var best: ?*const comments.Comment = null;
            for (store.items()) |*m| {
                if (m.state == .sent) continue;
                if (!std.mem.eql(u8, m.path, note.path)) continue;
                if (!first and (m.line < last or (m.line == last and m.id <= last_id))) continue;
                if (best) |b| {
                    if (m.line > b.line or (m.line == b.line and m.id > b.id)) continue;
                }
                best = m;
            }
            const m = best orelse break;
            last = m.line;
            last_id = m.id;
            first = false;

            try out.appendSlice(gpa, "\n- **line ");
            try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{m.line}) catch "");
            try out.appendSlice(gpa, "**");
            // A stale comment says so in the file as well as on screen. The agent
            // should know the line moved out from under the remark rather than
            // being pointed at code that may not be the code meant.
            if (m.about_removed) try out.appendSlice(gpa, " _(about code removed in this hunk)_");
            if (m.state == .stale) try out.appendSlice(gpa, " _(stale - the line this was written against has gone)_");
            try out.appendSlice(gpa, "\n\n");
            try indent(out, gpa, m.body);
            written += 1;
        }
    }

    if (written == 0) try out.appendSlice(gpa, "\nNo open comments.\n");
    return written;
}

/// The body as a markdown blockquote, so a comment containing a list or a code
/// fence does not break out of its bullet.
fn indent(out: *std.ArrayList(u8), gpa: Allocator, body: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try out.appendSlice(gpa, "  > ");
        try out.appendSlice(gpa, line);
        try out.appendSlice(gpa, "\n");
    }
}

const testing = std.testing;

test "the review groups by file and orders by line" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    // Written out of order, the way a reader actually wanders a diff.
    _ = try store.add("src/b.zig", 9, "second file");
    _ = try store.add("src/a.zig", 40, "later line");
    _ = try store.add("src/a.zig", 4, "earlier line");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const n = try render(&out, testing.allocator, &store, 3);
    try testing.expectEqual(@as(u32, 3), n);

    const text = out.items;
    try testing.expect(std.mem.startsWith(u8, text, "# Review 3\n"));
    // Files in first-appearance order, lines ascending inside each.
    const b = std.mem.indexOf(u8, text, "## src/b.zig").?;
    const a = std.mem.indexOf(u8, text, "## src/a.zig").?;
    try testing.expect(b < a);
    const early = std.mem.indexOf(u8, text, "earlier line").?;
    const late = std.mem.indexOf(u8, text, "later line").?;
    try testing.expect(early < late);
}

test "sent comments stay out, so nothing is asked for twice" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 1, "already said this");
    store.markSent();
    _ = try store.add("a.zig", 2, "this one is new");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const n = try render(&out, testing.allocator, &store, 1);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.indexOf(u8, out.items, "already said this") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "this one is new") != null);
}

test "a stale comment says so in the file, not just on screen" {
    // Hard rule 7 reaches the agent too: pointing it at a line that moved out
    // from under the remark, without saying so, is how a review misleads.
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    const id = try store.add("a.zig", 3, "this branch is dead");
    store.find(id).?.state = .stale;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try render(&out, testing.allocator, &store, 1);
    try testing.expect(std.mem.indexOf(u8, out.items, "stale") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "this branch is dead") != null);
}

test "a multi-line note stays inside its bullet" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 1, "why this?\n\n- because\n- and also");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try render(&out, testing.allocator, &store, 1);
    // Every line of the body is quoted, so a list inside a comment does not
    // become a sibling of the bullet it belongs to.
    try testing.expect(std.mem.indexOf(u8, out.items, "  > - because") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "  > - and also") != null);
}

test "an empty review says so rather than being a bare heading" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), try render(&out, testing.allocator, &store, 7));
    try testing.expect(std.mem.indexOf(u8, out.items, "No open comments") != null);
}

test "the file is numbered and lands in the state directory" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("review-4.md", fileName(&buf, 4));
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings(".lgtm/review-4.md", path(&buf2, 4));
}
