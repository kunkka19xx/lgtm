// SPDX-License-Identifier: Apache-2.0
//
// Pull-request mode: pointing the review at somebody else's tree, and handing
// a batch of remarks back to the forge. `core/gh.zig` does the talking.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("app.zig").App;
const notes = @import("notes.zig");
const finder_mod = @import("finder.zig");
const comments_mod = @import("../core/comments.zig");
const gh = @import("../core/gh.zig");
const wrap_mod = @import("wrap.zig");

/// A review the loop is to hand to the forge.
pub const Post = struct {
    event: gh.Event,
    /// One comment by id, or null for every unposted one.
    one: ?u32 = null,
};

pub const State = struct {
    /// The two refs the review points at. Inline rather than in an arena: the
    /// resolve allocates before it can fail, so a failed `:pr` freed refs the
    /// review was still using.
    base: [64]u8 = undefined,
    base_len: u8 = 0,
    target: [64]u8 = undefined,
    target_len: u8 = 0,
    /// Which request the comment store belongs to, zero for the working tree.
    /// One file for both re-anchored remarks onto whatever line they fell near.
    number: u32 = 0,
    /// `owner/repo`, so posting does not have to ask again.
    repo: [128]u8 = undefined,
    repo_len: u8 = 0,
    /// The sentence a posted review opens with, held across the frame between
    /// arming the post and making it.
    note_buf: [256]u8 = undefined,
    note_len: u16 = 0,
    want_post: ?Post = null,
    /// Whole rows, not numbers: a row already carries the two refs, so picking
    /// one asks GitHub nothing more.
    rows: std.ArrayList(gh.Pr) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.rows.deinit(gpa);
    }
};

/// The author column's ceiling. A login is short; a bot's is not, and one of
/// them should not push every title off an eighty-column pane.
const author_max: usize = 14;

/// What the line numbers in a review file belong to. Empty for the working
/// tree, where they belong to the files on disk.
pub fn reviewScope(app: *const App, buf: []u8) []const u8 {
    if (app.pr.number == 0) return "";
    return std.fmt.bufPrint(
        buf,
        "Pull request #{d}, {s}. Line numbers are that tree, not the working one: `gh pr checkout {d}`.",
        .{ app.pr.number, postRepo(app) orelse "", app.pr.number },
    ) catch "";
}

/// The repository a pull request review is posted to, remembered from the
/// resolve so posting costs no second question.
pub fn postRepo(app: *const App) ?[]const u8 {
    if (app.pr.number == 0 or app.pr.repo_len == 0) return null;
    return app.pr.repo[0..app.pr.repo_len];
}

/// `:post`, `:approve`, `:request-changes`. One review, one request, so a
/// partial failure cannot happen.
///
/// The argument, if any, is the covering note the review opens with. An
/// approval needs nothing to say; the other two do, or there is no reason
/// to have notified anybody.
pub fn postReview(app: *App, want: gh.Event, note: []const u8) void {
    if (postRepo(app) == null) {
        app.notice.set("not reviewing a pull request", .{});
        return;
    }
    if (unposted(app) == 0 and want != .approve and note.len == 0) {
        if (app.comments.len() == 0) {
            app.notice.set("no comments to post", .{});
        } else {
            app.notice.set("everything here is posted already", .{});
        }
        return;
    }
    app.pr.note_len = @intCast(@min(note.len, app.pr.note_buf.len));
    @memcpy(app.pr.note_buf[0..app.pr.note_len], note[0..app.pr.note_len]);
    app.pr.want_post = .{ .event = want };
    app.notice.set("posting to #{d}...", .{app.pr.number});
}

pub fn unposted(app: *const App) usize {
    var n: usize = 0;
    for (app.comments.items()) |c| {
        if (!c.posted) n += 1;
    }
    return n;
}

/// The call itself, from the loop, one frame after the notice that says it
/// is happening.
pub fn performPost(app: *App, req: Post) void {
    const repo = postRepo(app) orelse return;

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var one: comments_mod.Store = .init(app.gpa);
    defer one.deinit();
    var store = &app.comments;
    if (req.one) |id| {
        const n = app.comments.find(id) orelse return;
        _ = one.addFull(n.path, n.line, n.body, n.anchor, n.about_removed, n.span) catch return;
        one.list.items[0].state = n.state;
        store = &one;
    }

    var out: std.ArrayList(u8) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    const note = app.pr.note_buf[0..app.pr.note_len];
    gh.reviewBody(&out, arena, store, app.review.files(), req.event, note, &ids) catch {
        app.notice.set("could not build the review", .{});
        return;
    };

    gh.post(app.gpa, arena, app.io, repo, app.pr.number, out.items) catch {
        app.notice.set("could not post to #{d}", .{app.pr.number});
        return;
    };

    if (req.one) |id| {
        app.comments.markPosted(&.{id});
        app.notice.set("posted 1 to #{d}", .{app.pr.number});
    } else {
        app.comments.markPosted(ids.items);
        finder_mod.closeFiles(app);
        app.notice.set("posted {d} to #{d} as {s}", .{ ids.items.len, app.pr.number, req.event.wire() });
    }
    notes.saveComments(app);
}

/// `<C-p>` in the comment list: the one under the cursor, on its own.
/// GitHub's "add single comment" beside its "submit review", which is the
/// split every reader already knows from the web.
pub fn postOne(app: *App) void {
    const n = notes.listSelected(app) orelse return;
    if (postRepo(app) == null) {
        app.notice.set("not reviewing a pull request", .{});
        return;
    }
    if (n.posted) {
        app.notice.set("already posted", .{});
        return;
    }
    app.pr.note_len = 0;
    app.pr.want_post = .{ .event = .comment, .one = n.id };
    app.notice.set("posting {s}:{d}...", .{ n.path, n.line });
}

/// `:pr [n]`, `:pr off` for the working tree, `:pr list [all]` to choose
/// from what is open. The same resolve `--pr` runs, so the spellings
/// cannot disagree about what a request is.
pub fn openPr(app: *App, arg: []const u8) Allocator.Error!void {
    if (std.mem.eql(u8, arg, "off")) return closePr(app);
    if (std.mem.eql(u8, arg, "list")) return openPrList(app, false);
    if (std.mem.eql(u8, arg, "list all") or std.mem.eql(u8, arg, "all")) return openPrList(app, true);

    var number: ?u32 = null;
    if (arg.len > 0) {
        number = std.fmt.parseInt(u32, arg, 10) catch {
            app.notice.set("pr takes a number or list, not {s}", .{arg});
            return;
        };
    }

    // Dies with the call; what the review keeps is copied out. Nothing
    // is touched before the resolve can fail, so a failure leaves the
    // review where it was.
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const refs = gh.resolve(app.gpa, scratch.allocator(), app.io, number) catch {
        app.notice.set("could not open that pull request", .{});
        return;
    };
    enterPr(app, refs);
}

/// Point the review at a request and start reading it.
///
/// Everything it keeps is copied out of the caller's arena, so the caller
/// is free to drop it - which is what lets the picker close first.
pub fn enterPr(app: *App, refs: gh.Refs) void {
    app.review.base = keepRef(app, &app.pr.base, &app.pr.base_len, refs.base);
    app.review.target = keepRef(app, &app.pr.target, &app.pr.target_len, refs.target);
    app.review.setLabel(refs.label);
    app.pr.repo_len = @intCast(@min(refs.repo.len, app.pr.repo.len));
    @memcpy(app.pr.repo[0..app.pr.repo_len], refs.repo[0..app.pr.repo_len]);
    notes.swapComments(app, refs.number);
    const theirs = importRemarks(app, refs.repo, refs.number);
    reopen(app);
    // Not the label: the badge shows it already. What is new is that the
    // review has stopped following the working tree, and how much of the
    // review was already there before the reader arrived.
    if (theirs > 0) {
        app.notice.set("#{d}, {d} remark{s} already on it - :pr off to come back", .{
            refs.number,
            theirs,
            if (theirs == 1) "" else "s",
        });
    } else {
        app.notice.set("static review of #{d} - :pr off to come back", .{refs.number});
    }
}

/// The remarks already on the request, into the store beside the reader's
/// own. Returns how many.
///
/// Failing costs the reader nothing but those remarks: `gh` may be absent
/// or the network down, and neither is a reason to refuse to read a diff
/// that is already resolved. It says so rather than saying nothing.
///
/// Not persisted and not counted as a change, so an import cannot make the
/// comment file dirty and cannot come back twice.
pub fn importRemarks(app: *App, repo: []const u8, number: u32) usize {
    if (repo.len == 0) return 0;
    const was_dirty = app.comments.dirty;
    // Reading the request again replaces what it said last time. Without
    // this, opening the same request twice showed every remark twice.
    app.comments.dropTheirs();

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const found = gh.remarks(app.gpa, scratch.allocator(), app.io, repo, number) catch {
        app.notice.set("could not read the remarks already on #{d}", .{number});
        return 0;
    };

    var taken: usize = 0;
    for (found) |r| {
        // A remark on a file rather than on a line has nowhere to sit in
        // the gutter. Hard rule 7 is about the reader's own remarks; this
        // one is on the request, where it stays.
        if (r.line == 0) continue;
        _ = app.comments.adopt(r.path, r.line, r.span, r.body, r.author, r.outdated) catch continue;
        taken += 1;
    }
    app.comments.dirty = was_dirty;
    return taken;
}

/// `<Space>lp`: the open requests, one per row, and Enter reviews one.
///
/// Nothing is asked of GitHub twice. The rows carry the same fields a
/// single view returns, so choosing one is a merge-base and a re-diff.
pub fn openPrList(app: *App, all: bool) Allocator.Error!void {
    if (app.mode == .finder) return finder_mod.closeFiles(app);

    app.pick_list.clearRetainingCapacity();
    app.pr.rows.clearRetainingCapacity();
    _ = app.pick_arena.reset(.retain_capacity);
    const arena = app.pick_arena.allocator();

    const rows = gh.list(app.gpa, arena, app.io, all) catch {
        app.notice.set("could not list pull requests - is gh set up?", .{});
        return;
    };
    if (rows.len == 0) {
        app.notice.set("no {s}pull requests", .{if (all) "" else "open "});
        return;
    }
    try showPrs(app, arena, rows, all);
}

/// The rows as a list to choose from. Separate from fetching them so the
/// columns can be tested without a network.
pub fn showPrs(app: *App, arena: Allocator, rows: []const gh.Pr, all: bool) Allocator.Error!void {
    app.files_purpose = .prs;

    // A column earns its width or it is not drawn. Every row open, or
    // every row the same person's, and the word repeats down the list
    // saying nothing - and it is still in the panel beside it.
    var mixed_state = false;
    var mixed_author = false;
    var w_num: usize = 0;
    var w_state: usize = 0;
    var w_author: usize = 0;
    const whos = try arena.alloc([]const u8, rows.len);
    for (rows, whos) |r, *who| {
        mixed_state = mixed_state or !std.mem.eql(u8, r.status(), rows[0].status());
        mixed_author = mixed_author or !std.mem.eql(u8, r.author, rows[0].author);
        who.* = try shortAuthor(arena, r.author, app.glyphs.ellipsis);
        w_num = @max(w_num, digits(r.number));
        w_state = @max(w_state, r.status().len);
        w_author = @max(w_author, wrap_mod.columns(who.*, .{ .method = .unicode }));
    }

    for (rows, whos) |r, who| {
        var label: std.ArrayList(u8) = .empty;
        try label.print(arena, "#{d}{s}", .{ r.number, finder_mod.pad(arena, w_num -| digits(r.number)) });
        if (mixed_state) {
            try label.print(arena, "  {s}{s}", .{ r.status(), finder_mod.pad(arena, w_state -| r.status().len) });
        }
        if (mixed_author) {
            const w = wrap_mod.columns(who, .{ .method = .unicode });
            try label.print(arena, "  {s}{s}", .{ who, finder_mod.pad(arena, w_author -| w) });
        }
        try label.print(arena, "  {s}", .{r.title});

        try app.pr.rows.append(app.gpa, r);
        try app.pick_list.append(app.gpa, .{
            .path = label.items,
            // How big the read is. The one thing the row cannot say in
            // words, and the list already knows how to draw it.
            .added = r.added,
            .removed = r.removed,
            .plain = true,
            // A digits-only filter means the request's number, not the
            // `2` in a title.
            .key = r.number,
        });
    }

    finder_mod.show(app, .{
        .title = if (all) " pull requests " else " open pull requests ",
        .gutter = false,
    });
}

/// ASCII from the forge, so bytes are columns.
pub fn shortAuthor(arena: Allocator, name: []const u8, ell: []const u8) Allocator.Error![]const u8 {
    if (name.len <= author_max) return name;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ name[0 .. author_max - 1], ell });
}

pub fn digits(n: u32) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// `<CR>` in the request picker: review that one.
///
/// The row is read before the picker closes: once the list is a file list
/// again the next rebuild empties the arena the rows live in. The refs
/// come back in a scratch arena, so entering the review can wait.
pub fn pickPr(app: *App, at: ?u32) void {
    const i = at orelse return finder_mod.closeFiles(app);
    if (i >= app.pr.rows.items.len) return finder_mod.closeFiles(app);

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const refs = gh.refsOf(app.gpa, scratch.allocator(), app.io, app.pr.rows.items[i]) catch {
        finder_mod.closeFiles(app);
        app.notice.set("could not open that pull request", .{});
        return;
    };
    finder_mod.closeFiles(app);
    enterPr(app, refs);
}

/// Copies a ref somewhere the review can hold it. Truncates rather than
/// refuses: a ref that does not resolve is git's error to report.
pub fn keepRef(_: *App, buf: []u8, len: *u8, ref: []const u8) []const u8 {
    len.* = @intCast(@min(ref.len, buf.len));
    @memcpy(buf[0..len.*], ref[0..len.*]);
    return buf[0..len.*];
}

/// A reader who can get into a pull request without restarting should be
/// able to get out the same way.
pub fn closePr(app: *App) void {
    if (app.review.label().len == 0) {
        app.notice.set("not reviewing a pull request", .{});
        return;
    }
    app.review.base = "HEAD";
    app.review.target = null;
    app.review.setLabel("");
    app.pr.base_len = 0;
    app.pr.target_len = 0;
    app.pr.repo_len = 0;
    notes.swapComments(app, 0);
    reopen(app);
    app.notice.set("back to the working tree", .{});
}

/// Re-diff against whatever the review now points at, and start again at
/// the top: the cursor's line number means nothing in a different diff.
pub fn reopen(app: *App) void {
    app.file_index = 0;
    app.vp.cursor = 0;
    app.rediff() catch {};
}

const testing = std.testing;
const app_mod = @import("app.zig");
const event = @import("../core/event.zig");

test "a pull request is opened by number and left by name" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Nothing to leave yet, and saying so beats silently re-diffing.
    closePr(&fx.app);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "not reviewing") != null);

    // A word is not a number, and this is caught before `gh` is spawned.
    try openPr(&fx.app, "main");
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "takes a number") != null);
    try testing.expectEqualStrings("", fx.app.review.label());

    // The label is what the status row shows instead of two shas, and it
    // is what `:pr off` tests to know there is something to leave.
    fx.app.review.setLabel("#13 feat: syntax highlight for json");
    try testing.expectEqualStrings("#13 feat: syntax highlight for json", fx.app.review.label());
    fx.app.review.target = "c7143ba";
    closePr(&fx.app);
    try testing.expectEqualStrings("", fx.app.review.label());
    try testing.expect(fx.app.review.target == null);
    try testing.expectEqualStrings("HEAD", fx.app.review.base);
}

test "remarks on a pull request do not follow you to the working tree" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // One file per scope, so nothing has to filter and a working-tree
    // review never re-anchors somebody else's branch onto the tree here.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(".lgtm/comments.jsonl", notes.commentsPath(&fx.app, &buf));
    fx.app.pr.number = 13;
    try testing.expectEqualStrings(".lgtm/pr-13.jsonl", notes.commentsPath(&fx.app, &buf));
}

test "swapping scope empties the store and reloads the new one" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    _ = try fx.app.comments.add("a.zig", 1, "about the working tree");
    try testing.expectEqual(@as(usize, 1), fx.app.comments.len());
    // Nothing here may write to the repository the tests run in.
    fx.app.comments.dirty = false;

    // A scope with no file: the store comes back empty rather than
    // carrying the previous one's remarks across, and rather than picking
    // up `notes.jsonl`, which belongs to the working tree alone.
    notes.swapComments(&fx.app, 999_999);
    try testing.expectEqual(@as(usize, 0), fx.app.comments.len());
    try testing.expectEqual(@as(u32, 999_999), fx.app.pr.number);

    // Asking for the scope already open is not a reload: it would drop
    // unsaved remarks on the way out and back.
    _ = try fx.app.comments.add("b.zig", 2, "about the request");
    fx.app.comments.dirty = false;
    notes.swapComments(&fx.app, 999_999);
    try testing.expectEqual(@as(usize, 1), fx.app.comments.len());
}

test "a failed pull request leaves the review pointing where it was" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Standing in one pull request, as if a resolve had succeeded.
    fx.app.review.base = keepRef(&fx.app, &fx.app.pr.base, &fx.app.pr.base_len, "be94b77de24e3c40f85f80bbcfc11b871335d065");
    fx.app.review.target = keepRef(&fx.app, &fx.app.pr.target, &fx.app.pr.target_len, "c7143ba8237180b84b378d651f0b020652160868");
    fx.app.review.setLabel("#13 feat: syntax highlight for json");

    // A resolve that cannot even start. The refs held an arena that was
    // reset before the resolve ran, so a failure freed what the review was
    // still pointing at and left it to diff against whatever landed there.
    try openPr(&fx.app, "not-a-number");
    try testing.expectEqualStrings("be94b77de24e3c40f85f80bbcfc11b871335d065", fx.app.review.base);
    try testing.expectEqualStrings("c7143ba8237180b84b378d651f0b020652160868", fx.app.review.target.?);
    try testing.expectEqualStrings("#13 feat: syntax highlight for json", fx.app.review.label());

    // And leaving puts back refs that are not owned by anything at all.
    closePr(&fx.app);
    try testing.expectEqualStrings("HEAD", fx.app.review.base);
    try testing.expect(fx.app.review.target == null);
    try testing.expectEqual(@as(u8, 0), fx.app.pr.base_len);
}

test "a ref longer than the buffer is truncated rather than overrunning it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const long = "a" ** 200;
    const kept = keepRef(&fx.app, &fx.app.pr.base, &fx.app.pr.base_len, long);
    try testing.expectEqual(fx.app.pr.base.len, kept.len);
    try testing.expect(std.mem.startsWith(u8, long, kept));
}

fn prRow(number: u32, state: []const u8, author: []const u8, title: []const u8) gh.Pr {
    return .{
        .number = number,
        .state = state,
        .base_ref = "main",
        .base_oid = "be94b77",
        .head_oid = "c7143ba",
        .url = "https://github.com/o/r/pull/1",
        .author = author,
        .title = title,
    };
}

fn showPrRows(fx: *app_mod.Fixture, rows: []const gh.Pr, all: bool) !void {
    fx.app.pick_list.clearRetainingCapacity();
    fx.app.pr.rows.clearRetainingCapacity();
    _ = fx.app.pick_arena.reset(.retain_capacity);
    try showPrs(&fx.app, fx.app.pick_arena.allocator(), rows, all);
}

test "a column of one repeated word is not drawn" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // One person's open requests: saying `open` and their name on every
    // row spends the width the titles need at eighty columns.
    const same = [_]gh.Pr{
        prRow(19, "OPEN", "kunkka19xx", "feat: posting comments to a PR"),
        prRow(7, "OPEN", "kunkka19xx", "fix: the anchor table"),
    };
    try showPrRows(fx, &same, false);
    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    // Or `<CR>` reads the row as a file path and jumps nowhere.
    try testing.expectEqual(@TypeOf(fx.app.files_purpose).prs, fx.app.files_purpose);
    // The number is padded so the titles line up, and nothing else is
    // between them.
    try testing.expectEqualStrings("#19  feat: posting comments to a PR", fx.app.pick_list.items[0].path);
    try testing.expectEqualStrings("#7   fix: the anchor table", fx.app.pick_list.items[1].path);
    // A digits-only filter means the request, not a `7` in a title.
    try testing.expectEqual(@as(?u32, 19), fx.app.pick_list.items[0].key);

    // Mixed, and both columns are worth their width.
    var mixed = [_]gh.Pr{
        prRow(19, "OPEN", "kunkka19xx", "feat: posting"),
        prRow(16, "MERGED", "someone", "chore: config"),
    };
    mixed[0].draft = true;
    try showPrRows(fx, &mixed, true);
    try testing.expectEqualStrings("#19  draft   kunkka19xx  feat: posting", fx.app.pick_list.items[0].path);
    try testing.expectEqualStrings("#16  merged  someone     chore: config", fx.app.pick_list.items[1].path);
}

test "picking a request that is not there closes the list and does nothing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const rows = [_]gh.Pr{prRow(19, "OPEN", "me", "feat: posting")};
    try showPrRows(fx, &rows, false);

    // No network in a test, so only the refusing half is exercised here:
    // an index past the rows must not read one.
    pickPr(&fx.app, 5);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expectEqual(@as(u32, 0), fx.app.pr.number);
}

test "posting is armed, not done, so the frame saying so is drawn first" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Outside a pull request there is nothing to arm and the answer is
    // immediate: a `posting...` that resolved to an error would flash.
    postReview(&fx.app, .comment, "");
    try testing.expect(fx.app.pr.want_post == null);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "not reviewing") != null);

    fx.app.pr.number = 16;
    fx.app.pr.repo_len = @intCast("o/r".len);
    @memcpy(fx.app.pr.repo[0..3], "o/r");

    // Nothing to say is also answered on the spot.
    postReview(&fx.app, .comment, "");
    try testing.expect(fx.app.pr.want_post == null);

    // With something to post the call is left for the loop, which draws
    // before it performs.
    _ = try fx.app.comments.add("a.zig", 1, "a remark");
    postReview(&fx.app, .request_changes, "have a look");
    const req = fx.app.pr.want_post.?;
    try testing.expectEqual(gh.Event.request_changes, req.event);
    try testing.expect(req.one == null);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "posting") != null);
    // The note outlives the prompt buffer it was typed into.
    try testing.expectEqualStrings("have a look", fx.app.pr.note_buf[0..fx.app.pr.note_len]);
}
