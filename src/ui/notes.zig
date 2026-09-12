// SPDX-License-Identifier: Apache-2.0
//
// Review comments as the app drives them: where one anchors, what a selection
// covers, the panel beside the list, and the file they persist to.
// `core/comments.zig` is the store and the re-anchoring.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("app.zig");
const App = app_mod.App;
const comments_mod = @import("../core/comments.zig");
const compose_mod = @import("compose.zig");
const finder_mod = @import("finder.zig");
const fs_mod = @import("../io/fs.zig");
const render = @import("render.zig");
const review_file = @import("../core/review.zig");
const template = @import("../bridge/template.zig");
const walks = @import("walks.zig");
const pr_mod = @import("pr.zig");

/// The line the cursor points at, as the note store counts them: the new
/// file's line, which is what survives a re-diff and what a reference
/// names. Null on a row that is chrome, or a line that exists only in HEAD.
pub const Spot2 = struct { path: []const u8, line: u32, deleted: bool = false, span: u32 = 1, rows: u32 = 1, skipped: u32 = 0 };

/// The new-file lines a selection covers, or null when it touches none.
/// A remark cannot span code the new file does not have.
pub const Range = struct {
    lo: u32,
    hi: u32,
    rows: u32,
    skipped: u32,

    /// Lines the remark covers, which is what the store calls its span.
    pub fn covers(self: Range) u32 {
        return self.hi - self.lo + 1;
    }
};

/// Where a comment sits in the order `]c` walks: the review's files first,
/// in review order, then everything else by path. `line` breaks the tie.
pub fn selectedRange(app: *App) ?Range {
    const sel = app.selection() orelse return null;
    // Both kinds: a comment anchors to whole lines, so the rows a
    // selection touches matter and where in them it starts does not.
    // Refusing charwise fell back to the caret's line, the last of them.
    const f = app.current() orelse return null;

    var lo: u32 = 0;
    var hi: u32 = 0;
    var rows: u32 = 0;
    var skipped: u32 = 0;
    var row = sel.lo;
    while (row <= sel.hi) : (row += 1) {
        rows += 1;
        const li = app.lineAt(row) orelse {
            skipped += 1;
            continue;
        };
        if (li >= f.lines.len()) {
            skipped += 1;
            continue;
        }
        const no = f.lines.new_no[li];
        if (no == 0) {
            skipped += 1;
            continue;
        }
        if (lo == 0 or no < lo) lo = no;
        if (no > hi) hi = no;
    }
    return if (lo == 0) null else .{ .lo = lo, .hi = hi, .rows = rows, .skipped = skipped };
}

/// The text of a new-file line, for the anchor a comment carries across a
/// restart. It has to be the line the comment *attached* to, not the one
/// the cursor was on: a deleted line's text is not in the new file, so an
/// anchor taken from it would find nothing and go stale immediately.
pub fn textOfNewLine(app: *App, line: u32) []const u8 {
    const f = app.current() orelse return "";
    var i: u32 = 0;
    while (i < f.lines.len()) : (i += 1) {
        if (f.lines.new_no[i] == line) return f.lines.text[i];
    }
    return "";
}

/// Where a comment written here would attach.
///
/// A deleted line has no line in the new file, and the store anchors to
/// new-file lines - so a remark about removed code used to be refused
/// outright. It attaches to the enclosing hunk instead, on the first line
/// of it that still exists, and is marked as being about the removal so
/// the review file and the box say which. Refusing was the honest answer
/// to the wrong question: "why did you take this out" is a thing a
/// reviewer says constantly.
pub fn commentLine(app: *App) ?Spot2 {
    const f = app.current() orelse return null;
    const li = app.lineAt(app.vp.cursor) orelse return null;
    if (li >= f.lines.len()) return null;
    const no = f.lines.new_no[li];
    if (no != 0) {
        // Anchored at the selection's *first* new-file line: the caret
        // is at its bottom, and measuring from there covers one line.
        if (selectedRange(app)) |r| return .{
            .path = f.path(),
            .line = r.lo,
            .span = r.covers(),
            .rows = r.rows,
            .skipped = r.skipped,
        };
        return .{ .path = f.path(), .line = no };
    }

    // On a deletion: the first surviving line of the hunk it sits in.
    const hi = app.rows.hunkAt(app.vp.cursor) orelse return null;
    if (hi >= f.hunks.len) return null;
    const h = f.hunks[hi];
    var i = h.lo;
    while (i < h.hi) : (i += 1) {
        if (i < f.lines.len() and f.lines.new_no[i] != 0) {
            return .{ .path = f.path(), .line = f.lines.new_no[i], .deleted = true };
        }
    }
    // A hunk that is nothing but deletions has no surviving line at all.
    // `new_start` is where the removed code used to begin, which is the
    // only place left to point at.
    if (h.new_start == 0) return null;
    return .{ .path = f.path(), .line = h.new_start, .deleted = true };
}

/// `c`: the compose box, pointed at a line instead of at the agent.
pub fn commentAdd(app: *App) Allocator.Error!void {
    const at = commentLine(app) orelse {
        app.notice.set("nothing here to comment on", .{});
        return;
    };
    app.compose_is_comment = true;
    app.compose_comment = null;
    app.compose_spot = at;
    app.compose_to = .copy;
    app.outgoing.clearRetainingCapacity();
    app.compose.start("");
    app.preset_index = null;
    app.mode = .note_input;
}

/// `<Space>gc`: a comment box holding the selected lines in a
/// ```suggestion fence, so the remark is the edit rather than a
/// description of one. The block replaces the lines it is attached to.
pub fn commentSuggest(app: *App) Allocator.Error!void {
    if (app.readOnly()) return;
    const at = commentLine(app) orelse {
        app.notice.set("nothing here to suggest a change to", .{});
        return;
    };

    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(app.gpa);
    try seed.appendSlice(app.gpa, "```suggestion\n");
    var no = at.line;
    while (no < at.line + @max(at.span, 1)) : (no += 1) {
        try seed.appendSlice(app.gpa, textOfNewLine(app, no));
        try seed.append(app.gpa, '\n');
    }
    try seed.appendSlice(app.gpa, "```");

    app.compose_is_comment = true;
    app.compose_comment = null;
    app.compose_spot = at;
    app.compose_to = .copy;
    app.outgoing.clearRetainingCapacity();
    app.compose.start(seed.items);
    // Inside the fence: the reader came to change that, not to write
    // around it.
    app.compose.cursor = "```suggestion\n".len;
    app.preset_index = null;
    app.mode = .note_input;

    // A selection can shrink for a good reason - a removed line has
    // nothing to replace - but shrinking silently looks broken.
    if (at.skipped > 0) {
        app.notice.set("suggesting {d} of {d} selected rows: {d} are not lines in the new file", .{
            at.span, at.rows, at.skipped,
        });
    }
}

/// The same box, seeded with what the comment already says.
pub fn commentEdit(app: *App) Allocator.Error!void {
    const n = commentUnderCursor(app) orelse {
        app.notice.set("no comment here", .{});
        return;
    };
    // Somebody else's opens to be read. Refusing to open it at all left the
    // only full copy of it in a gutter marker.
    if (n.theirs() and !mine(app, n.*)) return commentRead(app, n);
    if (n.theirs()) app.compose_remote = n.remote;
    app.compose_is_comment = true;
    app.compose_comment = n.id;
    app.compose_to = .copy;
    app.compose.start(n.body);
    app.preset_index = null;
    app.mode = .note_input;
}

/// A remark from the request, in the box with no way to change it: editing a
/// copy would say something its author never wrote.
pub fn commentRead(app: *App, n: *comments_mod.Comment) void {
    app.compose_is_comment = false;
    app.compose_remote = 0;
    app.compose_comment = n.id;
    app.compose_spot = null;
    app.compose_to = .copy;
    app.compose.startView(n.body);
    app.preset_index = null;
    app.mode = .note_input;
}

/// The note the cursor is pointing at: the one on this line, or the one
/// whose own row the cursor is sitting on. Both are "this note" to a
/// reader looking at it, and only one of them was reachable before.
pub fn commentUnderCursor(app: *App) ?*comments_mod.Comment {
    const f = app.current() orelse return null;
    if (app.vp.cursor < app.rows.len()) {
        if (app.rows.items[app.vp.cursor] == .note) {
            const ni = app.rows.items[app.vp.cursor].note;
            var i: u32 = 0;
            for (app.comments.list.items) |*n| {
                if (!std.mem.eql(u8, n.path, f.path())) continue;
                if (i == ni) return n;
                i += 1;
            }
            return null;
        }
    }
    const at = commentLine(app) orelse return null;
    return app.comments.at(at.path, at.line);
}

/// `<Space>vc`: the nearest note, opened to read and edit - or to read
/// only, when it is a remark that came from the request.
///
/// Nearest rather than "the one under the cursor", because the reader
/// asking to see a note is usually near it rather than on it - the marker
/// caught their eye a few lines away. The one under the cursor still wins
/// when there is one.
pub fn commentView(app: *App, body: u16) !void {
    if (commentUnderCursor(app) != null) return commentEdit(app);

    const f = app.current() orelse {
        noComments(app);
        return;
    };
    const here = if (commentLine(app)) |at| at.line else 0;

    var best: ?u32 = null;
    for (app.comments.items()) |n| {
        if (!std.mem.eql(u8, n.path, f.path())) continue;
        if (best == null or dist(n.line, here) < dist(best.?, here)) best = n.line;
    }
    const line = best orelse {
        // None in this file. The review-wide walk is what reaches the
        // rest, and saying so beats silently jumping the reader elsewhere.
        if (app.comments.len() == 0)
            noComments(app)
        else
            app.notice.set("no comments in this file - `]c` finds the next one", .{});
        return;
    };
    _ = walks.gotoNewLine(app, line);
    app.clampScroll(body);
    try commentEdit(app);
}

/// The comment the overlay is highlighting, or null when it is not the
/// comment overlay that is open.
pub fn listSelected(app: *App) ?*comments_mod.Comment {
    if (app.files_purpose != .comments) return null;
    const i = app.file_list.selected(app.pick_list.items) orelse return null;
    const list = app.comments.list.items;
    return if (i < list.len) &list[i] else null;
}

/// Send the highlighted comment straight from the list, without a detour
/// through the box: the list is where a reader decides what still needs
/// saying, so it is where saying it should be possible.
pub fn listSendOne(app: *App) !void {
    const n = listSelected(app) orelse return;
    var buf: [compose_mod.max_bytes]u8 = undefined;
    var flat: [compose_mod.max_bytes]u8 = undefined;
    const one = compose_mod.flatten(&flat, n.body);
    // The pull request comes first for the same reason the review file
    // names it: `path:line` on somebody else's tree is a different line
    // here.
    const line = if (app.pr.number == 0)
        std.fmt.bufPrint(&buf, "{s}:{d} - {s}", .{ n.path, n.line, one }) catch one
    else
        std.fmt.bufPrint(&buf, "PR #{d} {s}:{d} - {s}", .{ app.pr.number, n.path, n.line, one }) catch one;
    n.state = .sent;
    app.comments.dirty = true;

    finder_mod.closeFiles(app);
    app.outgoing.clearRetainingCapacity();
    try app.outgoing.appendSlice(app.gpa, line);
    app.want_send = .send;
    saveComments(app);
    app.rebuildRows(.line) catch {};
}

pub fn listDrop(app: *App) void {
    const n = listSelected(app) orelse return;
    if (notYours(app, n.*)) return;
    app.comments.remove(n.id);
    saveComments(app);
    finder_mod.buildPickList(app);
    app.rebuildRows(.line) catch {};
    if (app.comments.len() == 0) {
        finder_mod.closeFiles(app);
        app.notice.set("comment deleted - none left", .{});
        return;
    }
    app.notice.set("comment deleted", .{});
}

/// `<Space>sc`: this one comment, into the compose box, ready to send.
///
/// `<C-s>` is the other direction - every open comment as one file, which
/// is the batch the tool is built around. This is for the remark that
/// cannot wait for the batch: one line, the reference and the text, into
/// the box where it can be edited before it goes.
pub fn commentSend(app: *App) !void {
    const n = commentUnderCursor(app) orelse {
        app.notice.set("no comment here", .{});
        return;
    };
    var buf: [compose_mod.max_bytes]u8 = undefined;
    var flat: [compose_mod.max_bytes]u8 = undefined;
    const body = compose_mod.flatten(&flat, n.body);
    const seed = std.fmt.bufPrint(&buf, "{s}:{d} - {s}", .{ n.path, n.line, body }) catch n.body;

    app.compose_is_comment = false;
    app.compose_comment = null;
    app.compose_to = .send;
    app.compose.start(seed);
    app.preset_index = null;
    app.mode = .note_input;
}

pub fn commentDelete(app: *App) void {
    const n = commentUnderCursor(app) orelse {
        app.notice.set("no comment here", .{});
        return;
    };
    if (notYours(app, n.*)) return;
    app.comments.remove(n.id);
    saveComments(app);
    app.rebuildRows(.line) catch {};
    app.notice.set("comment deleted", .{});
}

/// Whether the reader wrote it. Without a login - `gh` could not be asked, or
/// no request is open - nothing is claimed, which errs towards read only.
pub fn mine(app: *App, n: comments_mod.Comment) bool {
    if (!n.theirs()) return true;
    if (n.remote == 0) return false;
    const who = app.pr.viewer();
    return who.len > 0 and std.ascii.eqlIgnoreCase(who, n.author);
}

/// A remark nothing here may delete, and why. Either way it lives on the
/// request, and that is where it changes.
pub fn notYours(app: *App, n: comments_mod.Comment) bool {
    if (!n.theirs()) return false;
    var key: [32]u8 = undefined;
    if (mine(app, n)) {
        app.notice.set("that one is on the request - {s} edits it there", .{
            app.keyFor(.comment_view, .normal, &key),
        });
    } else {
        app.notice.set("{s} wrote that one - reply on the request", .{n.author});
    }
    return true;
}

pub fn spotOf(app: *App, n: comments_mod.Comment) App.Spot {
    for (app.review.files(), 0..) |f, i| {
        if (std.mem.eql(u8, f.path(), n.path)) {
            return .{ .bucket = 0, .fi = @intCast(i), .path = n.path, .line = n.line };
        }
    }
    return .{ .bucket = 1, .fi = 0, .path = n.path, .line = n.line };
}

/// Where the cursor is, in the same order, so "next" means next from here.
pub fn spotHere(app: *App) App.Spot {
    const f = app.current() orelse return .{ .bucket = 0, .fi = 0, .path = "", .line = 0 };
    const line = if (commentLine(app)) |at| at.line else 0;
    if (app.preview != null) return .{ .bucket = 1, .fi = 0, .path = f.path(), .line = line };
    return .{ .bucket = 0, .fi = app.file_index, .path = f.path(), .line = line };
}

pub fn lessSpot(a: App.Spot, b: App.Spot) bool {
    if (a.bucket != b.bucket) return a.bucket < b.bucket;
    if (a.bucket == 0 and a.fi != b.fi) return a.fi < b.fi;
    if (a.bucket == 1) {
        const c = std.mem.order(u8, a.path, b.path);
        if (c != .eq) return c == .lt;
    }
    return a.line < b.line;
}

/// `Ctrl-s`: the review as one file, and one line telling the agent where
/// it is. The point of collecting notes rather than sending each: a dozen
/// remarks is a dozen interruptions, or it is one file.
pub fn submitReview(app: *App) !void {
    if (app.comments.openCount() == 0) {
        app.notice.set("no open comments to submit", .{});
        return;
    }
    app.review_n += 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    var scope_buf: [256]u8 = undefined;
    const written = try review_file.render(&out, app.gpa, &app.comments, app.review_n, pr_mod.reviewScope(app, &scope_buf));

    var buf: [64]u8 = undefined;
    const rel = review_file.path(&buf, app.review_n);
    fs_mod.writeStateFile(app.io, rel, out.items) catch {
        app.notice.set("could not write {s}", .{rel});
        app.review_n -= 1;
        return;
    };
    app.comments.markSent();
    saveComments(app);

    // Handing the review over is the one moment the reader has
    // demonstrably read all of it, so it is where the mark belongs: what
    // the agent does next is exactly what `]n` should walk. Taken after
    // the file is written, so a failed write does not mark a review that
    // was never sent - and not on `<Space>sc`, which sends one remark and
    // claims nothing about the rest.
    if (app.nav.mark_on_submit) app.review.mark() catch {};

    // One line, no newline in it: hard rule 1, and the reason the notes
    // themselves may be as long as they like.
    //
    // Through the template table like every other outgoing string. It was
    // a `bufPrint` here for a long time, which made the sentence the agent
    // receives most the only one a reader could not change.
    var count_buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{written}) catch "?";
    app.outgoing.clearRetainingCapacity();
    try template.render(app.gpa, &app.outgoing, app.templates.submit_review, &.{
        .{ .name = "path", .value = rel },
        .{ .name = "count", .value = count },
        .{ .name = "s", .value = if (written == 1) "" else "s" },
    });
    app.want_send = .send;
}

/// A comment's panel: the remark as written, then the hunk it sits in.
pub fn commentPanel(app: *const App, arena: Allocator, n: comments_mod.Comment) []const u8 {
    const code = commentCode(app, arena, n.path, n.line);
    if (code.len == 0) return arena.dupe(u8, n.body) catch "";
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ n.body, code }) catch code;
}

/// The hunk a comment sits in, as diff text for its panel.
pub fn commentCode(app: *const App, arena: Allocator, path: []const u8, line: u32) []const u8 {
    for (app.review.files()) |f| {
        if (!std.mem.eql(u8, f.path(), path)) continue;
        return finder_mod.diffText(arena, f, line);
    }
    return "";
}

/// Where this review's remarks live. One file per scope rather than a
/// field on each comment: nothing has to filter, and "my remarks on this
/// pull request" is a file read.
pub fn commentsPath(app: *const App, buf: []u8) []const u8 {
    if (app.pr.number == 0) return ".lgtm/comments.jsonl";
    return std.fmt.bufPrint(buf, ".lgtm/pr-{d}.jsonl", .{app.pr.number}) catch
        ".lgtm/comments.jsonl";
}

pub fn saveComments(app: *App) void {
    if (!app.comments.dirty) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    comments_mod.write(&out, app.gpa, &app.comments) catch return;
    var buf: [64]u8 = undefined;
    fs_mod.writeStateFile(app.io, commentsPath(app, &buf), out.items) catch return;
    app.comments.dirty = false;
}

/// Puts the current scope's remarks away and brings the new scope's out.
pub fn swapComments(app: *App, number: u32) void {
    if (app.pr.number == number) return;
    saveComments(app);
    app.comments.deinit();
    app.comments = .init(app.gpa);
    app.pr.number = number;
    loadComments(app);
}

pub fn loadComments(app: *App) void {
    // `.lgtm/notes.jsonl` is the name this file had before the feature was
    // called comments. Read once and it is written back under the new
    // name: renaming a concept should not lose a reader's remarks.
    var buf: [64]u8 = undefined;
    const path = commentsPath(app, &buf);
    // The rename predates the scopes, so only the working tree ever wore
    // the old name. Offering it to every scope handed one file's remarks
    // to whichever pull request was opened first.
    const text = fs_mod.readFile(app.io, app.gpa, path, 1 << 20) catch
        if (app.pr.number == 0)
            fs_mod.readFile(app.io, app.gpa, ".lgtm/notes.jsonl", 1 << 20) catch return
        else
            return;
    defer app.gpa.free(text);
    comments_mod.read(&app.comments, text) catch {};
    if (app.comments.len() > 0 and !fs_mod.fileExists(app.io, path)) {
        app.comments.dirty = true;
        saveComments(app);
    }
}

/// The notes on the current file, for the gutter. Built into the frame
/// arena: the body reads them this frame and nothing keeps them.
pub fn commentMarks(app: *App) []const render.CommentMark {
    const f = app.current() orelse return &.{};
    var out: std.ArrayList(render.CommentMark) = .empty;
    const arena = app.frame_arena.allocator();
    for (app.comments.items()) |n| {
        if (!std.mem.eql(u8, n.path, f.path())) continue;
        // Whose it is, in the remark rather than beside it: a reader
        // scrolling past needs to know without opening a list, and the
        // wrap has to measure the name along with the words.
        const body = if (n.theirs())
            std.fmt.allocPrint(arena, "@{s}  {s}", .{ n.author, n.body }) catch n.body
        else
            n.body;
        out.append(arena, .{ .line = n.line, .body = body, .state = switch (n.state) {
            .open => .open,
            .sent => .sent,
            .stale => .stale,
        } }) catch return out.items;
    }
    return out.items;
}

pub fn lineCount(text: []const u8) u16 {
    var n: u16 = 1;
    for (std.mem.trimEnd(u8, text, "\n")) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// One turn's row. The rail, then which turn, what it touched, when, and
/// how big - four columns and no more.
/// What a command is bound to right now, for a message that has to name a
/// key. Written into `buf` by the caller so this allocates nothing, and
/// read from the keymap so `[keys]` cannot leave a notice telling the
/// reader to press something they have remapped away.
pub fn noComments(app: *App) void {
    var key: [32]u8 = undefined;
    app.notice.set("no comments yet - {s} writes one", .{
        app.keyFor(.comment_add, .normal, &key),
    });
}

pub fn dist(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

const testing = std.testing;

test "a remark from the request opens to be read, never to be edited" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const body = "this retry never backs off";
    _ = try fx.app.comments.adopt("a.zig", 2, 1, body, "someone", false, 0);
    try commentView(&fx.app, 20);

    // It used to refuse to open at all.
    try testing.expect(fx.app.mode == .note_input);
    try testing.expect(fx.app.compose.read_only);
    try testing.expect(!fx.app.compose_is_comment);
    try testing.expectEqualStrings(body, fx.app.compose.text());

    // Nothing typed reaches the text, and `i` finds no way in.
    for ("ixddu") |c| _ = fx.app.compose.feed(.{ .codepoint = c, .mods = .{} });
    try testing.expectEqualStrings(body, fx.app.compose.text());
    try testing.expect(fx.app.compose.read_only);

    _ = fx.app.compose.feed(.{ .codepoint = 'w', .mods = .{} });
    try testing.expectEqual(@as(usize, 5), fx.app.compose.cursor);
    _ = fx.app.compose.feed(.{ .codepoint = '0', .mods = .{} });
    try testing.expectEqual(@as(usize, 0), fx.app.compose.cursor);
}

test "a remark of the reader's own on the request opens to be edited there" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.pr.number = 16;
    fx.app.pr.login_len = @intCast("kunkka19xx".len);
    @memcpy(fx.app.pr.login[0..fx.app.pr.login_len], "kunkka19xx");
    const id = try fx.app.comments.adopt("a.zig", 2, 1, "mine, posted", "Kunkka19xx", false, 777);

    try commentView(&fx.app, 20);
    // Editable, and `<CR>` knows it has to reach the forge.
    try testing.expect(!fx.app.compose.read_only);
    try testing.expect(fx.app.compose_is_comment);
    try testing.expectEqual(@as(u64, 777), fx.app.compose_remote);
    try testing.expectEqual(@as(?u32, id), fx.app.compose_comment);

    // Somebody else's on the same request is read and no more.
    fx.app.comments.remove(id);
    _ = try fx.app.comments.adopt("a.zig", 2, 1, "theirs", "someone", false, 778);
    try commentView(&fx.app, 20);
    try testing.expect(fx.app.compose.read_only);
    try testing.expectEqual(@as(u64, 0), fx.app.compose_remote);
}

test "without a login nothing is claimed, so a remark stays read only" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `gh` could not be asked. Guessing would offer an edit that 404s.
    _ = try fx.app.comments.adopt("a.zig", 2, 1, "mine, posted", "kunkka19xx", false, 777);
    try commentView(&fx.app, 20);
    try testing.expect(fx.app.compose.read_only);
}

test "the reader's own remark still opens to be edited" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    _ = try fx.app.comments.add("a.zig", 2, "mine");
    try commentView(&fx.app, 20);

    try testing.expect(!fx.app.compose.read_only);
    try testing.expect(fx.app.compose_is_comment);
    _ = fx.app.compose.feed(.{ .codepoint = '!', .mods = .{} });
    try testing.expectEqualStrings("mine!", fx.app.compose.text());
}
