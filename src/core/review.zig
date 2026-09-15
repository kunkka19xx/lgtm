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

/// What a review turned out to contain. Two numbers, because the file holds
/// the reviewers' asks as well as the reader's own.
pub const Written = struct {
    mine: u32 = 0,
    theirs: u32 = 0,

    pub fn total(self: Written) u32 {
        return self.mine + self.theirs;
    }
};

/// The most messages one conversation contributes, so a group fits a stack
/// buffer.
const max_thread = 64;

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
/// `scope` says what the line numbers below belong to, and is empty for the
/// working tree. A pull request is somebody else's tree: without it the agent
/// resolves `src/config.zig:8` against the checkout it stands in.
pub fn render(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    store: *const comments.Store,
    n: u32,
    scope: []const u8,
) Allocator.Error!Written {
    var num: [24]u8 = undefined;
    try out.appendSlice(gpa, "# Review ");
    try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n}) catch "");
    try out.appendSlice(gpa, "\n");
    if (scope.len > 0) {
        try out.appendSlice(gpa, "\n> ");
        try out.appendSlice(gpa, scope);
        try out.appendSlice(gpa, "\n");
    }

    var written: Written = .{};
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
            // Already written under its conversation's first message: a
            // reply and what it answers are one bullet, not two.
            if (!leadsThread(store, m)) continue;

            var members: [max_thread]*const comments.Comment = undefined;
            const group = threadOf(store, m, &members);

            try out.appendSlice(gpa, "\n- **line ");
            if (m.span > 1) {
                try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}-{d}", .{ m.line, m.end() }) catch "");
            } else {
                try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{m.line}) catch "");
            }
            try out.appendSlice(gpa, "**");
            // Who wrote it, when that is not the reader: their own stay
            // unattributed so the attributed ones read as somebody else's.
            if (group.len == 1 and m.theirs()) {
                try out.appendSlice(gpa, " _(@");
                try out.appendSlice(gpa, m.author);
                try out.appendSlice(gpa, ")_");
            }
            // A stale comment says so in the file as well as on screen. The agent
            // should know the line moved out from under the remark rather than
            // being pointed at code that may not be the code meant.
            if (m.about_removed) try out.appendSlice(gpa, " _(about code removed in this hunk)_");
            if (m.state == .stale) try out.appendSlice(gpa, " _(stale - the line this was written against has gone)_");
            try out.appendSlice(gpa, "\n");

            for (group) |msg| {
                // Inside a conversation every message is labelled: a bare
                // block between two attributed ones reads as a continuation.
                if (group.len > 1) {
                    try out.appendSlice(gpa, "\n  **");
                    if (msg.theirs()) {
                        try out.appendSlice(gpa, "@");
                        try out.appendSlice(gpa, msg.author);
                    } else {
                        try out.appendSlice(gpa, "you");
                    }
                    try out.appendSlice(gpa, ":**\n");
                }
                try out.appendSlice(gpa, "\n");
                try indent(out, gpa, msg.body);
                if (msg.theirs()) written.theirs += 1 else written.mine += 1;
            }
        }
    }

    if (written.total() == 0) try out.appendSlice(gpa, "\nNo open comments.\n");
    return written;
}

/// Whether a comment leads its conversation, in the order the file is
/// written: by line, then by id. A remark written in this pane belongs to no
/// thread, so it always leads.
fn leadsThread(store: *const comments.Store, m: *const comments.Comment) bool {
    const t = m.thread();
    if (t == 0) return true;
    for (store.items()) |*o| {
        if (o == m or o.state == .sent) continue;
        if (o.thread() != t or !std.mem.eql(u8, o.path, m.path)) continue;
        if (o.line < m.line or (o.line == m.line and o.id < m.id)) return false;
    }
    return true;
}

/// Every message of one conversation, in store order - which the import has
/// already made the order they were written in.
fn threadOf(
    store: *const comments.Store,
    m: *const comments.Comment,
    buf: []*const comments.Comment,
) []*const comments.Comment {
    const t = m.thread();
    if (t == 0) {
        buf[0] = m;
        return buf[0..1];
    }
    var n: usize = 0;
    for (store.items()) |*o| {
        if (n == buf.len) break;
        if (o.state == .sent) continue;
        if (o.thread() != t or !std.mem.eql(u8, o.path, m.path)) continue;
        buf[n] = o;
        n += 1;
    }
    return buf[0..n];
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

test "a remark on several lines says so" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.addFull("a.zig", 44, "these three belong together", "", false, 3);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try render(&out, testing.allocator, &store, 1, "");
    // The first line alone is a third of the problem.
    try testing.expect(std.mem.indexOf(u8, out.items, "**line 44-46**") != null);
}

test "a review of somebody else's tree says whose" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("src/config.zig", 8, "this list should be sorted");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const scope = "Pull request #16, kunkka19xx/lgtm. Line numbers are that tree: `gh pr checkout 16`.";
    _ = try render(&out, testing.allocator, &store, 1, scope);

    // Without it the agent reads `src/config.zig:8` and looks at line 8 of the
    // checkout it is standing in, which is different code.
    try testing.expect(std.mem.indexOf(u8, out.items, scope) != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "gh pr checkout 16") != null);

    // A working-tree review says nothing extra: the lines are the files.
    // (`>` alone would not tell us, since every body is a blockquote.)
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(testing.allocator);
    _ = try render(&plain, testing.allocator, &store, 1, "");
    try testing.expect(std.mem.indexOf(u8, plain.items, "Pull request") == null);
    try testing.expect(std.mem.startsWith(u8, plain.items, "# Review 1\n\n## "));
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
    const n = try render(&out, testing.allocator, &store, 3, "");
    try testing.expectEqual(@as(u32, 3), n.total());
    // Every one of them the reader's own, which is the working-tree case.
    try testing.expectEqual(@as(u32, 0), n.theirs);

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
    const n = try render(&out, testing.allocator, &store, 1, "");
    try testing.expectEqual(@as(u32, 1), n.total());
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
    _ = try render(&out, testing.allocator, &store, 1, "");
    try testing.expect(std.mem.indexOf(u8, out.items, "stale") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "this branch is dead") != null);
}

test "a remark from the request says who wrote it" {
    // Or the agent acts on the reviewers' asks as if the reader had made them.
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 1, "mine");
    _ = try store.adopt(.{ .path = "a.zig", .line = 2, .body = "theirs", .author = "someone", .remote = 10 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const n = try render(&out, testing.allocator, &store, 1, "");
    try testing.expectEqual(@as(u32, 1), n.mine);
    try testing.expectEqual(@as(u32, 1), n.theirs);

    try testing.expect(std.mem.indexOf(u8, out.items, "**line 2** _(@someone)_") != null);
    // The reader's own stays unattributed, which is what makes the attributed
    // one read as somebody else's rather than as a list of names.
    try testing.expect(std.mem.indexOf(u8, out.items, "**line 1**\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "**line 1** _") == null);
}

test "a thread is one conversation, not unrelated bullets sharing a line" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.adopt(.{ .path = "docs/CONFIG.md", .line = 26, .body = "that's nice", .author = "someone", .remote = 10 });
    _ = try store.adopt(.{ .path = "docs/CONFIG.md", .line = 26, .body = "fixed in the follow-up", .author = "kunkka19xx", .remote = 11, .reply_to = 10 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const n = try render(&out, testing.allocator, &store, 1, "");
    // Both messages are written, under one bullet.
    try testing.expectEqual(@as(u32, 2), n.total());
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "- **line 26**"));

    const root = std.mem.indexOf(u8, out.items, "**@someone:**").?;
    const reply = std.mem.indexOf(u8, out.items, "**@kunkka19xx:**").?;
    try testing.expect(root < reply);
    try testing.expect(std.mem.indexOf(u8, out.items, "  > that's nice") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "  > fixed in the follow-up") != null);

    // The attribution is on the messages rather than on the bullet: a thread
    // has no single author to name up there.
    try testing.expect(std.mem.indexOf(u8, out.items, "**line 26** _(@") == null);
}

test "the reader's own reply inside a thread is labelled, alone it is not" {
    // A bare block between two attributed ones reads as a continuation of
    // whichever came first, so inside a conversation everything is labelled.
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.adopt(.{ .path = "a.zig", .line = 4, .body = "why this way?", .author = "someone", .remote = 10 });
    // Written in this pane, on the line the thread sits on: not part of the
    // conversation, because it belongs to no thread on the forge.
    _ = try store.add("a.zig", 4, "a thought of my own");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try render(&out, testing.allocator, &store, 1, "");

    // Two bullets on one line, not one conversation of two.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "- **line 4**"));
    try testing.expect(std.mem.indexOf(u8, out.items, "**you:**") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "  > a thought of my own") != null);
}

test "a thread whose reply landed on another line is still written once" {
    // Hard rule 7: a message folded under a bullet must not be a message
    // dropped. The reply is on line 31 and its root on line 26.
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.adopt(.{ .path = "a.zig", .line = 26, .body = "root", .author = "someone", .remote = 10 });
    _ = try store.adopt(.{ .path = "a.zig", .line = 31, .body = "moved reply", .author = "other", .remote = 11, .reply_to = 10 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const n = try render(&out, testing.allocator, &store, 1, "");
    try testing.expectEqual(@as(u32, 2), n.theirs);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "moved reply"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "- **line "));
}

test "a multi-line note stays inside its bullet" {
    var store: comments.Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 1, "why this?\n\n- because\n- and also");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try render(&out, testing.allocator, &store, 1, "");
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
    try testing.expectEqual(@as(u32, 0), (try render(&out, testing.allocator, &store, 7, "")).total());
    try testing.expect(std.mem.indexOf(u8, out.items, "No open comments") != null);
}

test "the file is numbered and lands in the state directory" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("review-4.md", fileName(&buf, 4));
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings(".lgtm/review-4.md", path(&buf2, 4));
}
