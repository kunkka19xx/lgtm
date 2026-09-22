// SPDX-License-Identifier: Apache-2.0
//
// Review comments as the app drives them: where one anchors, what a selection
// covers, the panel beside the list, and the file they persist to.
// `core/comments.zig` is the store and the re-anchoring.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../i18n/i18n.zig");

const app_mod = @import("app.zig");
const App = app_mod.App;
const comments_mod = @import("../core/comments.zig");
const dist = comments_mod.dist;
const event_mod = @import("../core/event.zig");
const compose_mod = @import("compose.zig");
const finder_mod = @import("finder.zig");
const fs_mod = @import("../io/fs.zig");
const render = @import("render.zig");
const review_file = @import("../core/review.zig");
const suggest = @import("../core/suggest.zig");
const template = @import("../bridge/template.zig");
const walks = @import("walks.zig");
const pr_mod = @import("pr.zig");
const thread_mod = @import("thread.zig");

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
    openBox(app, .{ .fresh = at }, .copy, "");
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

    openBox(app, .{ .fresh = at }, .copy, seed.items);
    // Inside the fence: the reader came to change that, not to write
    // around it.
    app.compose.cursor = "```suggestion\n".len;

    // A selection can shrink for a good reason - a removed line has
    // nothing to replace - but shrinking silently looks broken.
    if (at.skipped > 0) {
        app.notice.set("suggesting {d} of {d} selected rows: {d} are not lines in the new file", .{
            at.span, at.rows, at.skipped,
        });
    }
}

/// `<Space>vc`: the overlay where the line carries a conversation, which is
/// the only thing that can say *which* remark is meant. One remark alone
/// opens in the box as it always has.
pub fn commentOpen(app: *App) Allocator.Error!void {
    const n = commentHere(app) orelse return;
    if (thread_mod.worthOpening(app, n)) return thread_mod.open(app, n);
    return commentEdit(app);
}

/// The same box, seeded with what the comment already says.
pub fn commentEdit(app: *App) Allocator.Error!void {
    const n = commentHere(app) orelse return;
    // Somebody else's opens to be read. Refusing to open it at all left the
    // only full copy of it in a gutter marker.
    if (n.theirs() and !mine(app, n.*)) return commentRead(app, n);
    // The reader's own that lives on the request: saving is a call to the
    // forge, not a store write, and the box has to know which before it opens.
    const kind: app_mod.ComposeFor = if (n.theirs())
        .{ .amend = .{ .id = n.id, .remote = n.remote } }
    else
        .{ .edit = n.id };
    openBox(app, kind, .copy, n.body);
}

/// A remark from the request, in the box with no way to change it: editing a
/// copy would say something its author never wrote.
pub fn commentRead(app: *App, n: *comments_mod.Comment) void {
    openBox(app, .{ .view = n.id }, .copy, "");
    // Read only, caret at the top: nothing in this one is typed.
    app.compose.startView(n.body);
    app.mode = .note_view;
}

/// The box, pointed at one thing. Every way into it goes through here: the
/// five fields were set one by one at each of them, and two that disagreed are
/// how `<C-s>` in a reply box once saved a remark instead of sending it.
pub fn openBox(app: *App, kind: app_mod.ComposeFor, to: App.Delivery, seed: []const u8) void {
    app.compose_for = kind;
    app.compose_to = to;
    // Whatever the last send left behind. Nothing reads it until `want_send`
    // is set and every path that sets it fills the buffer first, but a box
    // opening over a stale payload is one fewer thing to have to know.
    app.outgoing.clearRetainingCapacity();
    app.compose.start(seed);
    app.preset_index = null;
    app.mode = .note_input;
}

/// The note the cursor is pointing at: the one on this line, or the one
/// whose own row the cursor is sitting on. Both are "this note" to a
/// reader looking at it, and only one of them was reachable before.
pub fn commentUnderCursor(app: *App) ?*comments_mod.Comment {
    if (app.vp.cursor < app.rows.len()) {
        if (app.rows.items[app.vp.cursor] == .note) {
            return app.comments.find(app.rows.items[app.vp.cursor].note);
        }
    }
    const at = commentLine(app) orelse return null;
    // The one the reader picked: `]c`, the list and the overlay all leave a
    // selection behind, and store order would act on somebody else's.
    if (selectedOn(app, at.path, at.line) != 0) {
        if (app.comments.find(app.comment_sel)) |n| return n;
    }
    return app.comments.at(at.path, at.line);
}

/// The same, saying so when there is none. Every key that acts on "the
/// comment here" asks through this, so they cannot disagree about what to say
/// when there is nothing under the cursor.
pub fn commentHere(app: *App) ?*comments_mod.Comment {
    return commentUnderCursor(app) orelse {
        app.notice.set("no comment here", .{});
        return null;
    };
}

/// `<Space>vc`: the nearest note, opened to read and edit - or to read
/// only, when it is a remark that came from the request.
///
/// Nearest rather than "the one under the cursor", because the reader
/// asking to see a note is usually near it rather than on it - the marker
/// caught their eye a few lines away. The one under the cursor still wins
/// when there is one.
pub fn commentView(app: *App, body: u16) !void {
    if (commentUnderCursor(app) != null) return commentOpen(app);

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
    try commentOpen(app);
}

/// The comment the overlay is highlighting, or null when it is not the
/// comment overlay that is open.
pub fn listSelected(app: *App) ?*comments_mod.Comment {
    if (app.files_purpose != .comments) return null;
    const i = app.file_list.selected(app.pick_list.items) orelse return null;
    if (i >= app.pick_list.items.len) return null;
    // By id: a row may stand for a conversation, so its position is not the
    // store's.
    return app.comments.find(app.pick_list.items[i].id);
}

/// Send the highlighted comment straight from the list, without a detour
/// through the box: the list is where a reader decides what still needs
/// saying, so it is where saying it should be possible.
pub fn listSendOne(app: *App) !void {
    const n = listSelected(app) orelse return;
    finder_mod.closeFiles(app);
    try sendOne(app, n);
    app.rebuildRows(.line) catch {};
}

/// One remark handed over: its line queued for the agent, and marked sent.
///
/// Handed over, so it is sent: it drops out of the next `review-N.md` rather
/// than asking twice, and editing it reopens it the way editing any sent
/// comment does.
pub fn sendOne(app: *App, n: *comments_mod.Comment) !void {
    var buf: [compose_mod.max_bytes]u8 = undefined;
    var flat: [compose_mod.max_bytes]u8 = undefined;
    const line = oneLine(app, &buf, &flat, n.*);
    n.state = .sent;
    app.comments.dirty = true;
    saveComments(app);

    app.outgoing.clearRetainingCapacity();
    try app.outgoing.appendSlice(app.gpa, line);
    app.want_send = .send;
}

pub fn listDrop(app: *App) void {
    const n = listSelected(app) orelse return;
    if (n.theirs()) return dropTheirs(app, n);
    drop(app, n.id);
    finder_mod.buildPickList(app);
    if (app.comments.len() == 0) {
        finder_mod.closeFiles(app);
        app.notice.set("comment deleted - none left", .{});
        return;
    }
    app.notice.set("comment deleted", .{});
}

/// One of this checkout's own, gone: off the store, onto disk, out of the
/// rows. What lives on the request goes through `dropTheirs` instead, which
/// has to ask the forge.
fn drop(app: *App, id: u32) void {
    app.comments.remove(id);
    saveComments(app);
    app.rebuildRows(.line) catch {};
}

/// `<Space>sc`: this one comment, into the compose box, ready to send.
///
/// `<C-s>` is the other direction - every open comment as one file, which
/// is the batch the tool is built around. This is for the remark that
/// cannot wait for the batch: one line, the reference and the text, into
/// the box where it can be edited before it goes.
pub fn commentSend(app: *App) !void {
    const n = commentHere(app) orelse return;
    var buf: [compose_mod.max_bytes]u8 = undefined;
    var flat: [compose_mod.max_bytes]u8 = undefined;
    openBox(app, .agent, .send, oneLine(app, &buf, &flat, n.*));
}

/// One remark as the single line the agent is handed: where it is, then what
/// it says, flattened to obey hard rule 1. The three keys that send one
/// remark all read from here, so the reference cannot come out three ways.
///
/// The request's number leads when there is one, for the same reason the
/// review file names it: `path:line` on somebody else's tree is a different
/// line here. `buf` and `flat` are the caller's because the result points into
/// them.
pub fn oneLine(app: *const App, buf: []u8, flat: []u8, n: comments_mod.Comment) []const u8 {
    const body = compose_mod.flatten(flat, n.body);
    var where: [64]u8 = undefined;
    const at = if (n.span > 1)
        std.fmt.bufPrint(&where, "{s}:{d}-{d}", .{ n.path, n.line, n.end() }) catch n.path
    else
        std.fmt.bufPrint(&where, "{s}:{d}", .{ n.path, n.line }) catch n.path;
    return if (app.pr.number == 0)
        std.fmt.bufPrint(buf, "{s} - {s}", .{ at, body }) catch body
    else
        std.fmt.bufPrint(buf, "PR #{d} {s} - {s}", .{ app.pr.number, at, body }) catch body;
}

pub fn commentDelete(app: *App) void {
    const n = commentHere(app) orelse return;
    if (n.theirs()) return dropTheirs(app, n);
    drop(app, n.id);
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

/// Why somebody else's remark does not open to be changed, and what does work
/// on it. One sentence, said from the overlay and the diff alike.
pub fn sayTheirs(app: *App, n: comments_mod.Comment, mode: event_mod.Mode) void {
    var key: [32]u8 = undefined;
    app.notice.set("{s} wrote that one - {s} answers it", .{
        n.author, app.keyFor(.thread_reply, mode, &key),
    });
}

/// Deleting a remark that lives on the request: the reader's own goes off the
/// request itself, and somebody else's goes nowhere. Removing only the copy
/// here would leave it on the request and bring it back on the next read.
fn dropTheirs(app: *App, n: *comments_mod.Comment) void {
    if (!mine(app, n.*)) return sayTheirs(app, n.*, app.mode);
    pr_mod.dropAsk(app, n);
}

/// A remark nothing here may delete, and why. Either way it lives on the
/// request, and that is where it changes.
pub fn notYours(app: *App, n: comments_mod.Comment) bool {
    if (!n.theirs()) return false;
    if (mine(app, n)) {
        var key: [32]u8 = undefined;
        app.notice.set("that one is on the request - {s} edits it there", .{
            app.keyFor(.comment_view, .normal, &key),
        });
    } else {
        sayTheirs(app, n, .normal);
    }
    return true;
}

pub fn spotOf(app: *App, n: comments_mod.Comment) App.Spot {
    for (app.review.files(), 0..) |f, i| {
        if (std.mem.eql(u8, f.path(), n.path)) {
            return .{ .bucket = 0, .fi = @intCast(i), .path = n.path, .line = n.line, .id = n.id };
        }
    }
    return .{ .bucket = 1, .fi = 0, .path = n.path, .line = n.line, .id = n.id };
}

/// Where the cursor is, in the same order, so "next" means next from here.
pub fn spotHere(app: *App) App.Spot {
    const f = app.current() orelse return .{ .bucket = 0, .fi = 0, .path = "", .line = 0 };
    const line = if (commentLine(app)) |at| at.line else 0;
    const id = selectedOn(app, f.path(), line);
    if (app.preview != null) return .{ .bucket = 1, .fi = 0, .path = f.path(), .line = line, .id = id };
    return .{ .bucket = 0, .fi = app.file_index, .path = f.path(), .line = line, .id = id };
}

/// Which remark on this line the reader has settled on, and zero unless it is
/// still the line they are on. Without it `]c` walks back onto the first
/// remark of the line, because "here" would be the line rather than a remark.
pub fn selectedOn(app: *App, path: []const u8, line: u32) u32 {
    if (app.comment_sel == 0) return 0;
    const n = app.comments.find(app.comment_sel) orelse return 0;
    if (n.line != line or !std.mem.eql(u8, n.path, path)) return 0;
    return n.id;
}

pub fn lessSpot(a: App.Spot, b: App.Spot) bool {
    if (a.bucket != b.bucket) return a.bucket < b.bucket;
    if (a.bucket == 0 and a.fi != b.fi) return a.fi < b.fi;
    if (a.bucket == 1) {
        const c = std.mem.order(u8, a.path, b.path);
        if (c != .eq) return c == .lt;
    }
    if (a.line != b.line) return a.line < b.line;
    // Ordered by line alone, the second remark on a line is never "after"
    // the first, so `]c` stopped dead there.
    return a.id < b.id;
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
    if (app.persist) fs_mod.writeStateFile(app.io, rel, out.items) catch {
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
    var mine_buf: [16]u8 = undefined;
    var theirs_buf: [16]u8 = undefined;
    const total = written.total();
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{total}) catch "?";
    app.outgoing.clearRetainingCapacity();
    // Two sentences: a single total would say the reviewers' asks are all
    // the reader's own.
    if (written.theirs > 0) {
        try template.render(app.gpa, &app.outgoing, app.templates.submit_review_mixed, &.{
            .{ .name = "path", .value = rel },
            .{ .name = "mine", .value = std.fmt.bufPrint(&mine_buf, "{d}", .{written.mine}) catch "?" },
            .{ .name = "theirs", .value = std.fmt.bufPrint(&theirs_buf, "{d}", .{written.theirs}) catch "?" },
            .{ .name = "count", .value = count },
        });
    } else {
        try template.render(app.gpa, &app.outgoing, app.templates.submit_review, &.{
            .{ .name = "path", .value = rel },
            .{ .name = "count", .value = count },
            .{ .name = "s", .value = if (total == 1) "" else "s" },
        });
    }
    app.want_send = .send;
}

/// A comment's panel: the remark as written, then the hunk it sits in.
pub fn commentPanel(app: *const App, arena: Allocator, n: comments_mod.Comment) []const u8 {
    var code = commentCode(app, arena, n.path, n.line);
    // Stale means our diff no longer holds the line, which is when seeing
    // the code matters most - and the forge kept the version it was about.
    if (code.len == 0) code = n.hunk;
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
    if (!app.comments.dirty or !app.persist) return;
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

/// Phone comments as someone else's, marked sent: shown, never written back, never in the TUI's review.
pub fn loadPhone(app: *App) void {
    const n = if (!phoneFresh(app.io)) 0 else if (fs_mod.readFile(app.io, app.gpa, ".lgtm/phone", 256)) |bytes| blk: {
        defer app.gpa.free(bytes);
        const name = std.mem.trim(u8, bytes, " \t\r\n");
        const k = @min(name.len, app.phone_buf.len);
        @memcpy(app.phone_buf[0..k], name[0..k]);
        break :blk k;
    } else |_| 0;
    app.phone_len = n;

    const dirty = app.comments.dirty;
    defer app.comments.dirty = dirty;
    var i = app.comments.items().len;
    while (i > 0) {
        i -= 1;
        const c = app.comments.items()[i];
        if (std.mem.eql(u8, c.author, phone_author)) app.comments.remove(c.id);
    }
    const text = fs_mod.readFile(app.io, app.gpa, ".lgtm/phone.jsonl", 4 << 20) catch return;
    defer app.gpa.free(text);
    var phone: comments_mod.Store = .init(app.gpa);
    defer phone.deinit();
    comments_mod.read(&phone, text) catch return;
    for (phone.items()) |c| {
        const id = app.comments.adopt(.{ .path = c.path, .line = c.line, .span = c.span, .body = c.body, .author = phone_author }) catch continue;
        app.comments.find(id).?.state = .sent;
    }
}

const phone_author = "phone";

/// `lgtm serve` rewrites `.lgtm/phone` every five seconds while attached; older, its daemon is gone.
const phone_stale_ns: i128 = 15 * std.time.ns_per_s;

pub fn phoneFresh(io: std.Io) bool {
    const meta = fs_mod.statFile(io, ".lgtm/phone") orelse return false;
    return meta.size > 0 and std.Io.Timestamp.now(io, .real).nanoseconds - meta.mtime_ns < phone_stale_ns;
}

pub fn loadComments(app: *App) void {
    if (!app.persist) return;
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
        // Every remark, not only the ones a row points at: the gutter dot
        // reads this list, and a folded reply would take its state with it.
        const head = app.comments.threadHead(n);
        out.append(arena, .{
            .line = n.line,
            .id = n.id,
            .body = markBody(arena, n),
            .state = if (head != null and head.? > 0) worstOn(app, n) else markState(n),
            .replies = head orelse 0,
            .span = n.span,
        }) catch return out.items;
    }
    return out.items;
}

/// The worst state in the conversation `n` leads. The gutter dot's ranking,
/// and deliberately the same function on it, so a line and the row under it
/// cannot disagree.
fn worstOn(app: *App, n: comments_mod.Comment) render.CommentMark.State {
    var buf: [thread_mod.max_messages]*comments_mod.Comment = undefined;
    var worst = markState(n);
    for (app.comments.threadAt(n, &buf)) |c| {
        const st = markState(c.*);
        if (st.worseThan(worst)) worst = st;
    }
    return worst;
}

/// What a note row says. Whose it is goes in the remark rather than beside
/// it: a reader scrolling past needs to know without opening a list, and the
/// wrap has to measure the name along with the words. Shared, because the row
/// that draws a note and the pass that measures it must agree to the byte.
pub fn markBody(arena: Allocator, n: comments_mod.Comment) []const u8 {
    if (!n.theirs()) return n.body;
    // A remark opening with a suggestion has no first line of prose for the
    // name to join, so the name takes a row of its own.
    const lead = std.mem.trimStart(u8, n.body, " \t");
    const sep: []const u8 = if (std.mem.startsWith(u8, lead, suggest.open_fence)) "\n" else "  ";
    return std.fmt.allocPrint(arena, "@{s}{s}{s}", .{ n.author, sep, n.body }) catch n.body;
}

pub fn markState(n: comments_mod.Comment) render.CommentMark.State {
    return switch (n.state) {
        .open => .open,
        .sent => .sent,
        .stale => .stale,
    };
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

const testing = std.testing;

test "a note row names its remark rather than counting to it" {
    // An ordinal is only right while the rows are rebuilt the instant the
    // store changes. Every path does that today, so this deliberately does
    // not: the point is that the row no longer depends on it.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const f = fx.app.current().?;
    const line = f.lines.new_no[0];

    const first = try fx.app.comments.add(f.path(), line, "first");
    _ = try fx.app.comments.add(f.path(), line, "second");
    try fx.app.rebuildRows(.line);

    var rows: [2]u32 = undefined;
    var found: usize = 0;
    for (fx.app.rows.items, 0..) |r, i| {
        if (r != .note) continue;
        rows[found] = @intCast(i);
        found += 1;
        if (found == rows.len) break;
    }
    try testing.expectEqual(rows.len, found);

    fx.app.vp.cursor = rows[1];
    try testing.expectEqualStrings("second", commentUnderCursor(&fx.app).?.body);

    // The store moves and the rows do not.
    fx.app.comments.remove(first);
    fx.app.vp.cursor = rows[1];
    try testing.expectEqualStrings("second", commentUnderCursor(&fx.app).?.body);
    // And a row whose remark is gone names nothing, not whatever slid in.
    fx.app.vp.cursor = rows[0];
    try testing.expect(commentUnderCursor(&fx.app) == null);
}

test "the walk reaches every remark on a line, not only the first" {
    // Ordered by line alone, the second remark on a line is never "after"
    // the first, so the walk stops dead there.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const f = fx.app.current().?;

    const first = try fx.app.comments.adopt(.{ .path = f.path(), .line = 1, .span = 1, .body = "that's nice", .author = "someone", .outdated = false, .remote = 4242 });
    const second = try fx.app.comments.add(f.path(), 1, "fixed in the follow-up");

    const a: App.Spot = spotOf(&fx.app, fx.app.comments.find(first).?.*);
    const b: App.Spot = spotOf(&fx.app, fx.app.comments.find(second).?.*);
    try testing.expect(lessSpot(a, b));
    try testing.expect(!lessSpot(b, a));

    // From the line with nothing chosen, both are still ahead.
    const here: App.Spot = .{ .bucket = a.bucket, .fi = a.fi, .path = a.path, .line = 1, .id = 0 };
    try testing.expect(lessSpot(here, a));
    try testing.expect(lessSpot(here, b));

    // Once the first is the selection, only the second is.
    fx.app.comment_sel = first;
    const from = spotHere(&fx.app);
    try testing.expectEqual(first, from.id);
    try testing.expect(!lessSpot(from, a));
    try testing.expect(lessSpot(from, b));
}

test "a selection that is not on this line claims nothing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const f = fx.app.current().?;

    const id = try fx.app.comments.add(f.path(), 2, "mine");
    fx.app.comment_sel = id;
    try testing.expectEqual(id, selectedOn(&fx.app, f.path(), 2));
    // Another line, another file, and a remark that has since been deleted.
    try testing.expectEqual(@as(u32, 0), selectedOn(&fx.app, f.path(), 3));
    try testing.expectEqual(@as(u32, 0), selectedOn(&fx.app, "other.zig", 2));
    fx.app.comments.remove(id);
    try testing.expectEqual(@as(u32, 0), selectedOn(&fx.app, f.path(), 2));
}

test "the remark the reader picked is the one that opens" {
    // The store's first match is whichever the forge listed first, which is
    // the wrong one half the time.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const f = fx.app.current().?;

    _ = try fx.app.comments.adopt(.{ .path = f.path(), .line = 1, .span = 1, .body = "theirs", .author = "someone", .outdated = false, .remote = 4242 });
    const mine_id = try fx.app.comments.add(f.path(), 1, "mine");

    try testing.expectEqualStrings("theirs", commentUnderCursor(&fx.app).?.body);
    fx.app.comment_sel = mine_id;
    try testing.expectEqualStrings("mine", commentUnderCursor(&fx.app).?.body);
}

test "a remark nobody here wrote, and with no thread, opens to be read" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // No remote: one that came from a phone rather than from the request.
    // Anything with a thread opens in the overlay, where answering lives.
    const body = "this retry never backs off";
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = body, .author = "someone", .outdated = false, .remote = 0 });
    try commentView(&fx.app, 20);

    // It used to refuse to open at all.
    try testing.expect(fx.app.mode == .note_view);
    try testing.expect(fx.app.compose_for == .view);
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

test "a remark on the request opens the thread even as the only message in it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.pr.number = 16;
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "this retry never backs off", .author = "someone", .outdated = false, .remote = 900 });
    try commentView(&fx.app, 20);
    // A conversation of one is still a conversation: answering it is what the
    // overlay is for, and a box with no reply key was a dead end.
    try fx.expectMode(.thread);

    try fx.press("r");
    try testing.expectEqual(@as(u64, 900), fx.app.compose_for.reply);
    try testing.expectEqualStrings("", fx.app.compose.text());
    try fx.expectMode(.note_input);
}

test "a remark of the reader's own on the request opens to be edited there" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.pr.number = 16;
    fx.app.pr.login_len = @intCast("kunkka19xx".len);
    @memcpy(fx.app.pr.login[0..fx.app.pr.login_len], "kunkka19xx");
    const id = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "mine, posted", .author = "Kunkka19xx", .remote = 777 });

    // On the request, so the overlay opens over it and `<CR>` is the edit.
    try commentView(&fx.app, 20);
    try fx.expectMode(.thread);
    try fx.press("<CR>");
    try testing.expect(!fx.app.compose.read_only);
    try testing.expectEqual(id, fx.app.compose_for.amend.id);
    try testing.expectEqual(@as(u64, 777), fx.app.compose_for.amend.remote);
    try fx.press("<Esc>");
    try fx.press("<Esc>");

    // Somebody else's on the same request says why instead, and leaves the
    // conversation up.
    fx.app.comments.remove(id);
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "theirs", .author = "someone", .outdated = false, .remote = 778 });
    try commentView(&fx.app, 20);
    try fx.press("<CR>");
    try fx.expectMode(.thread);
    try testing.expect(!fx.app.compose.open);
}

test "without a login nothing is claimed, so a remark stays read only" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `gh` could not be asked. Guessing would offer an edit that 404s.
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "mine, posted", .author = "kunkka19xx", .remote = 777 });
    try commentView(&fx.app, 20);
    try fx.press("<CR>");
    try fx.expectMode(.thread);
    try testing.expect(!fx.app.compose.open);
}

test "a notice is drawn in the reader's language" {
    i18n.lang = .ja;
    defer i18n.lang = .en;
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try submitReview(&fx.app);
    try testing.expectEqualStrings("未送信のコメントはありません", fx.app.notice.text());
    noComments(&fx.app);
    try testing.expectEqualStrings("コメントはまだありません - <Space>c で書く", fx.app.notice.text());
}

test "the reader's own remark still opens to be edited" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    _ = try fx.app.comments.add("a.zig", 2, "mine");
    try commentView(&fx.app, 20);

    try testing.expect(fx.app.compose_for == .edit);
    _ = fx.app.compose.feed(.{ .codepoint = '!', .mods = .{} });
    try testing.expectEqualStrings("mine!", fx.app.compose.text());
}
