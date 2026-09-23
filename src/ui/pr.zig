// SPDX-License-Identifier: Apache-2.0
//
// Pull-request mode: pointing the review at somebody else's tree, and handing
// a batch of remarks back to the forge. `core/gh.zig` does the talking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../i18n/i18n.zig");

const App = @import("app.zig").App;
const notes = @import("notes.zig");
const finder_mod = @import("finder.zig");
const comments_mod = @import("../core/comments.zig");
const gh = @import("../core/gh.zig");
const compose_mod = @import("compose.zig");
const event_mod = @import("../core/event.zig");
const thread_mod = @import("thread.zig");
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
    /// Who the reader is on the forge, asked once a session and kept. Without
    /// it their own remark on the request looks like everybody else's.
    login: [64]u8 = undefined,
    login_len: u8 = 0,
    /// A call armed this frame and made on the next, once the notice saying
    /// so is on screen. One slot: the loop drains it before the next
    /// keystroke, so two can never be waiting.
    pending: ?Pending = null,
    /// What the pending call carries - a covering note, a remark's new text,
    /// a reply. One buffer, because only one call is ever waiting.
    body_buf: [compose_mod.max_bytes]u8 = undefined,
    body_len: u16 = 0,
    /// A forge call the loop is to make off the main thread: `gh` costs the
    /// better part of a second, and a frozen pane reads as a key that missed.
    want: ?Want = null,
    /// A delete waiting on `y`. Taking a remark off the request cannot be
    /// undone from here and everybody watching the request sees it go, which
    /// is the same reason a restore asks first.
    dropping: ?Amend = null,
    /// Whole rows, not numbers: a row already carries the two refs, so picking
    /// one asks GitHub nothing more.
    rows: std.ArrayList(gh.Pr) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.rows.deinit(gpa);
    }

    /// Empty until a request has been opened.
    pub fn viewer(self: *const State) []const u8 {
        return self.login[0..self.login_len];
    }
};

/// A remark of the reader's own being changed where it lives: the store's id,
/// so the copy here can follow, and the forge's, which the call names.
pub const Amend = struct {
    id: u32,
    remote: u64,
};

/// A call the reader has asked for, held only so the notice saying it is
/// happening reaches the screen a frame before `gh` blocks.
pub const Pending = union(enum) {
    post: Post,
    amend: Amend,
    reply: Reply,
    /// A remark of the reader's own, off the request. The same two ids an
    /// amend carries: one for the copy here, one for the forge's.
    drop: Amend,

    pub fn says(self: Pending, buf: []u8, number: u32) []const u8 {
        return busyLine(buf, self, number);
    }
};

/// The spinner's sentence for a forge call, said in one place.
fn busyLine(buf: []u8, kind: std.meta.Tag(Pending), number: u32) []const u8 {
    return switch (kind) {
        .post => i18n.bufPrint(buf, "posting to #{d}", .{number}) catch i18n.t("posting"),
        .amend => i18n.bufPrint(buf, "editing on #{d}", .{number}) catch i18n.t("editing"),
        .reply => i18n.bufPrint(buf, "replying on #{d}", .{number}) catch i18n.t("replying"),
        .drop => i18n.bufPrint(buf, "deleting on #{d}", .{number}) catch i18n.t("deleting"),
    };
}

/// A message answering a thread: the forge's id for the remark that started
/// it, which is the only thing its endpoint is keyed on.
pub const Reply = struct {
    root: u64,
};

/// What the forge is being asked for. Arguments only: the call happens on the
/// loop's worker and answers with a `Got`.
pub const Want = union(enum) {
    /// `:pr [n]`, `--pr`. Null is the current branch's.
    open: Open,
    /// `<Space>lp`. True takes in merged and closed ones.
    list: bool,
    /// A row of the picker, copied out of the pick arena because that is reset
    /// the moment the list closes.
    pick: Pick,
    /// A review, already built: the body is made from the comment store, which
    /// only the main thread may read.
    post: Sending,
    /// New text for one remark already on the request.
    amend: Amending,
    /// One more message on a thread already on the request.
    reply: Replying,
    /// One remark of the reader's own, taken off the request.
    drop: Dropping,

    /// The sentence the spinner sits beside.
    pub fn says(self: Want, buf: []u8) []const u8 {
        return switch (self) {
            .open => |o| if (o.number) |x|
                i18n.bufPrint(buf, "opening #{d}", .{x}) catch i18n.t("opening")
            else
                i18n.t("opening this branch's request"),
            .list => i18n.t("listing pull requests"),
            .pick => |p| i18n.bufPrint(buf, "opening #{d}", .{p.pr.number}) catch i18n.t("opening"),
            .post => |p| busyLine(buf, .post, p.number),
            .amend => |a| busyLine(buf, .amend, a.number),
            .reply => |r| busyLine(buf, .reply, r.number),
            .drop => |d| busyLine(buf, .drop, d.number),
        };
    }
};

/// Opening a request. `login` asks who the reader is as well - one more call,
/// so it is made on the first request opened and not again.
pub const Open = struct {
    number: ?u32,
    login: bool = true,
};

/// The same for a row already in hand, which needs no resolve.
pub const Pick = struct {
    pr: Pr,
    login: bool = true,
};

/// A review on its way out, and the remarks to mark when it lands.
pub const Sending = struct {
    repo: []const u8,
    number: u32,
    payload: []const u8,
    ids: []const u32,
    one: ?u32,
    event: gh.Event,
};

/// One remark's new text on its way to the forge.
pub const Amending = struct {
    repo: []const u8,
    number: u32,
    id: u32,
    remote: u64,
    payload: []const u8,
    body: []const u8,
};

/// One message on its way onto a thread. `root` keys the endpoint; `on` is
/// the store's copy, so the reply lands on the same path and line.
pub const Replying = struct {
    repo: []const u8,
    number: u32,
    root: u64,
    payload: []const u8,
    body: []const u8,
};

/// One remark on its way off the request. `id` is the copy here, which is
/// removed only once the forge has answered.
pub const Dropping = struct {
    repo: []const u8,
    number: u32,
    id: u32,
    remote: u64,
};

/// A copy of `gh.Pr` owning its own bytes, so a row survives the arena its
/// label was built in.
pub const Pr = struct {
    number: u32,
    state: [16]u8 = undefined,
    state_len: u8 = 0,
    base_ref: [128]u8 = undefined,
    base_ref_len: u8 = 0,
    base_oid: [64]u8 = undefined,
    base_oid_len: u8 = 0,
    head_oid: [64]u8 = undefined,
    head_oid_len: u8 = 0,
    url: [256]u8 = undefined,
    url_len: u16 = 0,
    title: [256]u8 = undefined,
    title_len: u16 = 0,

    pub fn of(pr: gh.Pr) Pr {
        var out: Pr = .{ .number = pr.number };
        inline for (.{ "state", "base_ref", "base_oid", "head_oid", "url", "title" }) |f| {
            const src = @field(pr, f);
            const buf = &@field(out, f);
            const n = @min(src.len, buf.len);
            @memcpy(buf[0..n], src[0..n]);
            @field(out, f ++ "_len") = @intCast(n);
        }
        return out;
    }

    pub fn back(self: *const Pr) gh.Pr {
        return .{
            .number = self.number,
            .state = self.state[0..self.state_len],
            .base_ref = self.base_ref[0..self.base_ref_len],
            .base_oid = self.base_oid[0..self.base_oid_len],
            .head_oid = self.head_oid[0..self.head_oid_len],
            .url = self.url[0..self.url_len],
            .title = self.title[0..self.title_len],
        };
    }
};

/// A request, everything the forge knows about it, in one job: fetching the
/// remarks and the login on the main thread froze the pane with the spinner
/// already gone.
pub const Opened = struct {
    refs: gh.Refs,
    remarks: []const gh.Remark = &.{},
    /// Who the reader is on the forge, or empty when it was not asked or
    /// could not be answered. Nothing is claimed without it.
    login: []const u8 = "",
    /// The diff resolved but the remarks did not, which is said rather than
    /// shown as a request with no remarks on it.
    remarks_failed: bool = false,
};

/// Why a call came back with nothing. A deadline that fired is not a missing
/// `gh` or an absent request: pressing the key again is reasonable.
pub const Fail = enum { failed, timed_out };

/// What came back, in the job's arena.
pub const Got = union(enum) {
    opened: Opened,
    rows: []gh.Pr,
    /// The request's remarks, read again once the post landed: its answer
    /// carries no comment ids, and a remark this checkout posted can only be
    /// edited later through the forge's copy of it. Empty when that read
    /// failed, which costs the copy here nothing but its id.
    posted: []const gh.Remark,
    amended: void,
    /// The id the forge minted for the reply, or zero when its answer did not
    /// carry one. Posted either way.
    replied: u64,
    dropped: void,
    failed: Fail,
};

/// How an error from `core/gh.zig` reaches the notice.
fn failure(err: anyerror) Got {
    return .{ .failed = if (err == error.GhTimedOut) .timed_out else .failed };
}

/// Arms a call and says so. The loop draws this frame before anything blocks.
pub fn ask(app: *App, want: Want) void {
    var buf: [160]u8 = undefined;
    app.startBusy("{s}", .{want.says(&buf)});
    app.pr.want = want;
}

/// The blocking half. Arguments in, an arena and a `Got` out.
pub fn fetch(gpa: Allocator, arena: Allocator, io: std.Io, want: Want) Got {
    return switch (want) {
        .open => |o| open(gpa, arena, io, gh.resolve(gpa, arena, io, o.number) catch |e| return failure(e), o.login),
        .pick => |p| open(gpa, arena, io, gh.refsOf(gpa, arena, io, p.pr.back()) catch |e| return failure(e), p.login),
        .list => |all| .{ .rows = gh.list(gpa, arena, io, all) catch |e| return failure(e) },
        .post => |p| {
            gh.post(gpa, arena, io, p.repo, p.number, p.payload) catch |e| return failure(e);
            return .{ .posted = gh.remarks(gpa, arena, io, p.repo, p.number) catch &.{} };
        },
        .amend => |a| {
            gh.amend(gpa, arena, io, a.repo, a.remote, a.payload) catch |e| return failure(e);
            return .amended;
        },
        .reply => |r| .{
            .replied = gh.reply(gpa, arena, io, r.repo, r.number, r.root, r.payload) catch |e| return failure(e),
        },
        .drop => |d| {
            gh.drop(gpa, arena, io, d.repo, d.remote) catch |e| return failure(e);
            return .dropped;
        },
    };
}

/// The rest of what opening a request needs, on the same worker as the refs.
/// Neither is worth failing the open for: a request without them still
/// reviews.
fn open(gpa: Allocator, arena: Allocator, io: std.Io, refs: gh.Refs, want_login: bool) Got {
    var out: Opened = .{ .refs = refs };
    if (want_login) out.login = gh.viewer(gpa, arena, io) catch "";
    if (refs.repo.len > 0) {
        out.remarks = gh.remarks(gpa, arena, io, refs.repo, refs.number) catch blk: {
            out.remarks_failed = true;
            break :blk &.{};
        };
    }
    return .{ .opened = out };
}

/// What the main thread does with it, once the spinner stops.
pub fn apply(app: *App, want: Want, got: Got) Allocator.Error!void {
    app.busy = null;
    switch (got) {
        // A deadline that fired says so: a slow `gh` is not an absent
        // request, and blaming their setup sends them after the wrong thing.
        .failed => |why| switch (want) {
            .list => if (why == .timed_out)
                app.notice.set("gh did not answer in time - no pull requests listed", .{})
            else
                app.notice.set("could not list pull requests - is gh set up?", .{}),
            .post => |p| if (why == .timed_out)
                app.notice.set("gh did not answer in time - nothing was posted to #{d}", .{p.number})
            else
                app.notice.set("could not post to #{d}", .{p.number}),
            // Nothing changed here either, which is the point of waiting.
            .amend => |a| if (why == .timed_out)
                app.notice.set("gh did not answer in time - that comment is unchanged", .{})
            else
                app.notice.set("could not edit that comment on #{d} - it is unchanged", .{a.number}),
            // Nothing was written here either, so the thread on screen is
            // still the thread on the request.
            .reply => |r| if (why == .timed_out)
                app.notice.set("gh did not answer in time - nothing was posted to #{d}", .{r.number})
            else
                app.notice.set("could not reply on #{d}", .{r.number}),
            // The copy here was never removed, so the remark is still both
            // places it was.
            .drop => |d| if (why == .timed_out)
                app.notice.set("gh did not answer in time - that comment is still on #{d}", .{d.number})
            else
                app.notice.set("could not delete that comment on #{d}", .{d.number}),
            else => if (why == .timed_out)
                app.notice.set("gh did not answer in time - nothing was opened", .{})
            else
                app.notice.set("could not open that pull request", .{}),
        },
        .posted => |fresh| {
            const p = want.post;
            app.comments.markPosted(p.ids);
            // What went up comes back as the forge's own, which is the copy
            // that can be edited: adopted here, and the local one it replaces
            // dropped, or the line would carry the same remark twice.
            if (fresh.len > 0) {
                _ = adoptRemarks(app, fresh);
                _ = app.comments.dropPostedDuplicates(app.pr.viewer(), &app.comment_sel);
                app.rebuildRows(.line) catch {};
            }
            if (p.one == null) finder_mod.closeFiles(app);
            if (p.one != null) {
                app.notice.set("posted 1 to #{d}", .{p.number});
            } else {
                app.notice.set("posted {d} to #{d} as {s}", .{ p.ids.len, p.number, p.event.wire() });
            }
            notes.saveComments(app);
        },
        .amended => {
            const a = want.amend;
            // Now, and only now: this copy follows the forge's.
            app.comments.edit(a.id, a.body) catch {};
            app.rebuildRows(.line) catch {};
            app.notice.set("comment updated on #{d}", .{a.number});
        },
        .replied => |id| replied(app, want.reply, id),
        .dropped => {
            const d = want.drop;
            // Now, and only now: the forge has it, so this copy may go.
            app.comments.remove(d.id);
            notes.saveComments(app);
            app.rebuildRows(.line) catch {};
            // The overlay was reading a conversation that may have just ended.
            if (app.mode == .thread and !thread_mod.alive(app)) thread_mod.close(app);
            app.notice.set("comment deleted on #{d}", .{d.number});
        },
        .opened => |o| enterPr(app, o),
        .rows => |rows| {
            if (rows.len == 0) {
                if (want.list) app.notice.set("no pull requests", .{}) else app.notice.set("no open pull requests", .{});
                return;
            }
            // Copied into the pick arena, because the job's dies with it.
            app.pick_list.clearRetainingCapacity();
            app.pr.rows.clearRetainingCapacity();
            _ = app.pick_arena.reset(.retain_capacity);
            const into = app.pick_arena.allocator();
            const kept = try into.alloc(gh.Pr, rows.len);
            for (rows, kept) |src, *dst| dst.* = .{
                .number = src.number,
                .state = try into.dupe(u8, src.state),
                .base_ref = try into.dupe(u8, src.base_ref),
                .base_oid = try into.dupe(u8, src.base_oid),
                .head_oid = try into.dupe(u8, src.head_oid),
                .url = try into.dupe(u8, src.url),
                .draft = src.draft,
                .author = try into.dupe(u8, src.author),
                .added = src.added,
                .removed = src.removed,
                .title = try into.dupe(u8, src.title),
            };
            try showPrs(app, into, kept, want.list);
        },
    }
}

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

/// The same, saying so when there is none. Every key that needs the forge asks
/// through this, so five of them cannot drift into five sentences.
pub fn needRepo(app: *App) ?[]const u8 {
    return postRepo(app) orelse {
        app.notice.set("not reviewing a pull request", .{});
        return null;
    };
}

/// Arms a call and says so, holding the text it is to carry. The loop makes
/// it on the next pass, by which time the notice is already drawn.
fn armWith(app: *App, req: Pending, body: []const u8) void {
    app.pr.body_len = @intCast(@min(body.len, app.pr.body_buf.len));
    @memcpy(app.pr.body_buf[0..app.pr.body_len], body[0..app.pr.body_len]);
    app.pr.pending = req;
    var buf: [160]u8 = undefined;
    app.startBusy("{s}", .{req.says(&buf, app.pr.number)});
}

/// The prepare each pending call needs, so the loop asks once rather than
/// knowing which kinds there are.
pub fn prepare(app: *App, arena: Allocator, req: Pending) ?Want {
    return switch (req) {
        .post => |p| preparePost(app, arena, p),
        .amend => |a| prepareAmend(app, arena, a),
        .reply => |r| prepareReply(app, arena, r),
        .drop => |d| prepareDrop(app, arena, d),
    };
}

/// `:post`, `:approve`, `:request-changes`. One review, one request, so a
/// partial failure cannot happen.
///
/// The argument, if any, is the covering note the review opens with. An
/// approval needs nothing to say; the other two do, or there is no reason
/// to have notified anybody.
pub fn postReview(app: *App, want: gh.Event, note: []const u8) void {
    _ = needRepo(app) orelse return;
    if (unposted(app) == 0 and want != .approve and note.len == 0) {
        if (app.comments.len() == 0) {
            app.notice.set("no comments to post", .{});
        } else {
            app.notice.set("everything here is posted already", .{});
        }
        return;
    }
    armWith(app, .{ .post = .{ .event = want } }, note);
}

/// `<CR>` on a remark of the reader's own that lives on the request. The new
/// text goes to the forge first and the store waits. Armed rather than made,
/// like every other call, so the notice reaches the screen before `gh` blocks.
pub fn amend(app: *App, id: u32, remote: u64, body: []const u8) void {
    _ = needRepo(app) orelse return;
    armWith(app, .{ .amend = .{ .id = id, .remote = remote } }, body);
}

/// Deleting a remark of the reader's own where it lives.
///
/// Asked rather than done: it cannot be undone from here, and everybody
/// watching the request sees it go. `y` is the only answer that deletes,
/// which is how a restore asks too.
pub fn dropAsk(app: *App, n: *const comments_mod.Comment) void {
    if (postRepo(app) == null or n.remote == 0) {
        app.notice.set("that one is on the request, and this is not reviewing it", .{});
        return;
    }
    app.pr.dropping = .{ .id = n.id, .remote = n.remote };
    var buf: [160]u8 = undefined;
    app.notice.set("{s}", .{dropQuestion(&buf, app.pr.number)});
}

/// The question itself, in one place: the status row asks it, and a box over
/// the status row asks it in its own top border instead.
///
/// Short enough for a border. The request's number is already in the mode row
/// and the remark itself is the highlighted one, so what is left to say is
/// what the key does and what every other key does.
pub fn dropQuestion(buf: []u8, number: u32) []const u8 {
    _ = number;
    return i18n.bufPrint(buf, "delete this comment? y deletes, any other key cancels", .{}) catch i18n.t("delete this comment? y deletes");
}

/// The same, into a frame's arena, and empty when nothing is being asked.
/// What the boxes that can be covering the status row draw in their own
/// chrome.
pub fn askText(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    if (app.pr.dropping == null) return "";
    var buf: [160]u8 = undefined;
    return arena.dupe(u8, dropQuestion(&buf, app.pr.number));
}

/// The answer. Anything but `y` is no, because the safe reading of an
/// ambiguous keystroke is the one that deletes nothing.
pub fn dropAnswer(app: *App, key: event_mod.Key) void {
    const asked = app.pr.dropping.?;
    app.pr.dropping = null;
    if (key.codepoint != 'y' or key.mods.ctrl) {
        app.notice.set("nothing deleted", .{});
        return;
    }
    armWith(app, .{ .drop = asked }, "");
}

/// The half only the main thread may do: the repository, into the job's arena.
pub fn prepareDrop(app: *App, arena: Allocator, req: Amend) ?Want {
    const repo = postRepo(app) orelse return null;
    return .{ .drop = .{
        .repo = arena.dupe(u8, repo) catch return null,
        .number = app.pr.number,
        .id = req.id,
        .remote = req.remote,
    } };
}

/// `{"body": ...}`, which is the whole of what a PATCH of one remark and a
/// POST of one reply each send.
fn bodyJson(arena: Allocator, text: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, "{\"body\":") catch return null;
    comments_mod.quoteJson(&out, arena, text) catch return null;
    out.append(arena, '}') catch return null;
    return out.items;
}

/// The half only the main thread may do, into the job's arena.
pub fn prepareAmend(app: *App, arena: Allocator, req: Amend) ?Want {
    const repo = postRepo(app) orelse return null;
    const body = app.pr.body_buf[0..app.pr.body_len];
    const payload = bodyJson(arena, body) orelse return null;

    return .{ .amend = .{
        .repo = arena.dupe(u8, repo) catch return null,
        .number = app.pr.number,
        .id = req.id,
        .remote = req.remote,
        .payload = payload,
        .body = arena.dupe(u8, body) catch return null,
    } };
}

/// A message answering a thread, armed rather than made: the notice reaches
/// the screen before `gh` blocks.
pub fn reply(app: *App, root: u64, body: []const u8) void {
    _ = needRepo(app) orelse return;
    armWith(app, .{ .reply = .{ .root = root } }, body);
}

/// The half only the main thread may do: the store lookup that says which line
/// the thread is on, and the body, into the job's arena.
pub fn prepareReply(app: *App, arena: Allocator, req: Reply) ?Want {
    const repo = postRepo(app) orelse return null;
    const body = app.pr.body_buf[0..app.pr.body_len];

    // The root has to still be here: a thread that went away under the box
    // leaves nowhere to put the answer, and the endpoint is keyed on it.
    if (app.comments.findRemote(req.root) == null) {
        app.notice.set("that thread is no longer here - nothing was posted", .{});
        return null;
    }

    const payload = bodyJson(arena, body) orelse return null;

    return .{ .reply = .{
        .repo = arena.dupe(u8, repo) catch return null,
        .number = app.pr.number,
        .root = req.root,
        .payload = payload,
        .body = arena.dupe(u8, body) catch return null,
    } };
}

/// The reply, once the forge has it: adopted into the store beside the thread
/// it answers, so the overlay shows it without reopening the request and
/// `.lgtm/` never holds a copy to post twice.
fn replied(app: *App, req: Replying, id: u64) void {
    app.notice.set("replied on #{d}", .{req.number});

    const who = app.pr.viewer();
    const on = app.comments.findRemote(req.root);
    // No login, no honest author to file it under - and a remark with none
    // is one this checkout owns, which this is not.
    if (who.len == 0 or on == null) return;

    _ = app.comments.adopt(.{
        .path = on.?.path,
        .line = on.?.line,
        .span = on.?.span,
        .body = req.body,
        .author = who,
        .remote = id,
        .reply_to = req.root,
        .created = std.Io.Timestamp.now(app.io, .real).toSeconds(),
    }) catch return;
    app.rebuildRows(.line) catch {};
}

pub fn unposted(app: *const App) usize {
    var n: usize = 0;
    for (app.comments.items()) |c| {
        if (!c.posted) n += 1;
    }
    return n;
}

/// The half of a post only the main thread may do: read the comment store,
/// build the body, and list the remarks it covers. Into the job's arena, which
/// the worker and then the frame reporting it both outlive this call to read.
pub fn preparePost(app: *App, arena: Allocator, req: Post) ?Want {
    const repo = postRepo(app) orelse return null;

    var one: comments_mod.Store = .init(app.gpa);
    defer one.deinit();
    var store = &app.comments;
    if (req.one) |id| {
        const n = app.comments.find(id) orelse return null;
        _ = one.addFull(n.path, n.line, n.body, n.anchor, n.about_removed, n.span) catch return null;
        // The real store's id, not the scratch one's. `reviewBody` reports the
        // ids it covered and `apply` marks those posted: with the copy's own
        // id it marked whichever remark happened to hold it, and the remark
        // actually posted stayed unposted - so the next `<C-p>` posted it
        // again, and the request got a second copy.
        one.list.items[0].id = n.id;
        one.list.items[0].state = n.state;
        store = &one;
    }

    var out: std.ArrayList(u8) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    const note = app.pr.body_buf[0..app.pr.body_len];
    gh.reviewBody(&out, arena, store, app.review.files(), req.event, note, &ids) catch {
        app.notice.set("could not build the review", .{});
        return null;
    };

    return .{ .post = .{
        .repo = arena.dupe(u8, repo) catch return null,
        .number = app.pr.number,
        .payload = out.items,
        .ids = ids.items,
        .one = req.one,
        .event = req.event,
    } };
}

/// `<C-p>`: the remark the reader is looking at, whichever surface that is -
/// the highlighted row in the comment list, or the one the cursor sits on in
/// the diff. GitHub's "add single comment" beside its "submit review", which
/// is the split every reader already knows from the web.
pub fn postOne(app: *App) void {
    if (app.mode == .finder) {
        const n = notes.listSelected(app) orelse return;
        return postComment(app, n.id);
    }
    const n = notes.commentHere(app) orelse return;
    postComment(app, n.id);
}

/// One remark on its own, from wherever the reader is looking at it.
pub fn postComment(app: *App, id: u32) void {
    const n = app.comments.find(id) orelse return;
    _ = needRepo(app) orelse return;
    if (n.posted) {
        app.notice.set("already posted", .{});
        return;
    }
    armWith(app, .{ .post = .{ .event = .comment, .one = id } }, "");
    // Named rather than counted: the reader is looking at one remark, and
    // "posting to #16" would not say which.
    app.startBusy("posting {s}:{d}", .{ n.path, n.line });
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

    ask(app, .{ .open = .{ .number = number, .login = app.pr.login_len == 0 } });
}

/// Point the review at a request and start reading it.
///
/// Everything it keeps is copied out of the caller's arena, so the caller
/// is free to drop it - which is what lets the picker close first.
pub fn enterPr(app: *App, got: Opened) void {
    const refs = got.refs;
    app.review.base = keepRef(app, &app.pr.base, &app.pr.base_len, refs.base);
    app.review.target = keepRef(app, &app.pr.target, &app.pr.target_len, refs.target);
    app.review.setLabel(refs.label);
    app.pr.repo_len = @intCast(@min(refs.repo.len, app.pr.repo.len));
    @memcpy(app.pr.repo[0..app.pr.repo_len], refs.repo[0..app.pr.repo_len]);
    if (got.login.len > 0 and app.pr.login_len == 0) {
        app.pr.login_len = @intCast(@min(got.login.len, app.pr.login.len));
        @memcpy(app.pr.login[0..app.pr.login_len], got.login[0..app.pr.login_len]);
    }
    notes.swapComments(app, refs.number);
    const theirs = importRemarks(app, got);
    reopen(app);
    if (got.remarks_failed) {
        app.notice.set("#{d} - could not read the remarks already on it", .{refs.number});
        return;
    }
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
/// The main thread taking what the worker fetched. Ordered into threads on
/// the way in, so `]c`, the list, the review file and the overlay all agree
/// about what comes after what without each sorting for itself.
///
/// Not persisted and not counted as a change, so an import cannot make the
/// comment file dirty and cannot come back twice.
pub fn importRemarks(app: *App, got: Opened) usize {
    return adoptRemarks(app, got.remarks);
}

/// The forge's remarks into the store, in reading order.
fn adoptRemarks(app: *App, remarks: []const gh.Remark) usize {
    const was_dirty = app.comments.dirty;
    // Reading the request again replaces what it said last time. Without
    // this, opening the same request twice showed every remark twice.
    app.comments.dropTheirs();

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const ordered = threadOrder(scratch.allocator(), remarks) catch remarks;

    var taken: usize = 0;
    for (ordered) |r| {
        // A remark on a file rather than on a line has nowhere to sit in
        // the gutter. Hard rule 7 is about the reader's own remarks; this
        // one is on the request, where it stays.
        if (r.line == 0) continue;
        _ = app.comments.adopt(.{
            .path = r.path,
            .line = r.line,
            .span = r.span,
            .body = r.body,
            .author = r.author,
            .outdated = r.outdated,
            .remote = r.id,
            .reply_to = r.reply_to,
            .created = r.created,
            .hunk = r.hunk,
        }) catch continue;
        taken += 1;
    }
    app.comments.dirty = was_dirty;
    return taken;
}

/// One remark and where it sorts: which thread, where that thread first
/// appeared, and when this message was written.
const Placed = struct {
    remark: gh.Remark,
    at: usize,
    when: i64,
    id: u64,
};

/// The remarks grouped into threads, in the order they appeared.
///
/// `in_reply_to_id` is resolved to the thread's root rather than taken at face
/// value: a reply to a reply would otherwise split a thread of three.
fn threadOrder(arena: Allocator, remarks: []const gh.Remark) Allocator.Error![]const gh.Remark {
    if (remarks.len < 2) return remarks;
    const placed = try arena.alloc(Placed, remarks.len);
    for (remarks, placed) |r, *p| {
        p.* = .{ .remark = r, .at = 0, .when = r.created, .id = r.id };
    }
    // Quadratic over one request's remarks: a map would cost an allocation
    // and a hash to answer the same question about forty rows.
    const roots = try arena.alloc(u64, remarks.len);
    for (remarks, roots) |r, *root| root.* = rootOf(remarks, r);
    for (placed, roots) |*p, root| {
        // The resolved root, written back: `Comment.thread()` is what every
        // reader of this asks, and it can only answer with what it was given.
        p.remark.reply_to = if (root == p.remark.id) 0 else root;
        p.at = remarks.len;
        for (remarks, roots, 0..) |_, other, i| {
            if (other != root) continue;
            p.at = i;
            break;
        }
    }
    std.sort.insertion(Placed, placed, {}, beforeInThread);

    const out = try arena.alloc(gh.Remark, remarks.len);
    for (placed, out) |p, *o| o.* = p.remark;
    return out;
}

fn beforeInThread(_: void, a: Placed, b: Placed) bool {
    if (a.at != b.at) return a.at < b.at;
    if (a.when != b.when) return a.when < b.when;
    return a.id < b.id;
}

/// The thread a remark belongs to, following `in_reply_to_id` up. Bounded by
/// the set size, so a cycle costs one pass rather than the pane.
fn rootOf(remarks: []const gh.Remark, of: gh.Remark) u64 {
    var id = of.id;
    var up = of.reply_to;
    var steps: usize = 0;
    while (up != 0 and steps <= remarks.len) : (steps += 1) {
        id = up;
        up = 0;
        for (remarks) |r| {
            if (r.id != id) continue;
            up = r.reply_to;
            break;
        }
    }
    return id;
}

/// `<Space>lp`: the open requests, one per row, and Enter reviews one.
///
/// Nothing is asked of GitHub twice. The rows carry the same fields a
/// single view returns, so choosing one is a merge-base and a re-diff.
pub fn openPrList(app: *App, all: bool) Allocator.Error!void {
    if (app.mode == .finder) return finder_mod.closeFiles(app);
    ask(app, .{ .list = all });
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
        w_state = @max(w_state, wrap_mod.columns(i18n.word(r.status()), .{ .method = .unicode }));
        w_author = @max(w_author, wrap_mod.columns(who.*, .{ .method = .unicode }));
    }

    for (rows, whos) |r, who| {
        var label: std.ArrayList(u8) = .empty;
        try label.print(arena, "#{d}{s}", .{ r.number, finder_mod.pad(arena, w_num -| digits(r.number)) });
        if (mixed_state) {
            const state = i18n.word(r.status());
            const w = wrap_mod.columns(state, .{ .method = .unicode });
            try label.print(arena, "  {s}{s}", .{ state, finder_mod.pad(arena, w_state -| w) });
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
        .title = if (all) i18n.t(" pull requests ") else i18n.t(" open pull requests "),
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

    // Copied before the close, which lets the arena the row lives in go.
    const pr: Pr = .of(app.pr.rows.items[i]);
    finder_mod.closeFiles(app);
    ask(app, .{ .pick = .{ .pr = pr, .login = app.pr.login_len == 0 } });
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
    app.review.showWorking();
    app.file_index = 0;
    app.vp.cursor = 0;
    app.rediff() catch {};
}

const testing = std.testing;
const app_mod = @import("app.zig");
const anim = @import("anim.zig");
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

    i18n.lang = .ja;
    defer i18n.lang = .en;
    try showPrRows(fx, &mixed, true);
    try testing.expectEqualStrings("#19  下書き      kunkka19xx  feat: posting", fx.app.pick_list.items[0].path);
    try testing.expectEqualStrings("#16  マージ済み  someone     chore: config", fx.app.pick_list.items[1].path);
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
    try testing.expect(fx.app.pr.pending == null);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "not reviewing") != null);

    fx.onPr(16, "o/r", "");

    // Nothing to say is also answered on the spot.
    postReview(&fx.app, .comment, "");
    try testing.expect(fx.app.pr.pending == null);

    // With something to post the call is left for the loop, which draws
    // before it performs.
    _ = try fx.app.comments.add("a.zig", 1, "a remark");
    postReview(&fx.app, .request_changes, "have a look");
    const req = fx.app.pr.pending.?.post;
    try testing.expectEqual(gh.Event.request_changes, req.event);
    try testing.expect(req.one == null);
    try testing.expect(std.mem.indexOf(u8, fx.app.busy.?.label(), "posting") != null);
    // The note outlives the prompt buffer it was typed into.
    try testing.expectEqualStrings("have a look", fx.app.pr.body_buf[0..fx.app.pr.body_len]);
}

test "a forge call is armed with a sentence, not made on the keystroke" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // The key returns at once; the loop makes the call after the frame that
    // says it is happening. Without that the pane sits frozen for a second
    // and the keystroke looks like it missed.
    ask(&fx.app, .{ .open = .{ .number = 16 } });
    try testing.expect(fx.app.pr.want != null);
    try testing.expectEqualStrings("opening #16", fx.app.busy.?.label());
    // Busy is an animation with nothing to arrive at, so the loop paces
    // frames and the spinner turns.
    try testing.expect(fx.app.animating(20));

    fx.app.stepAnim(anim.Spinner.frame_ms * 3, 20);
    try testing.expectEqual(@as(usize, 3), fx.app.busy.?.spin.frame(10));

    try apply(&fx.app, fx.app.pr.want.?, .{ .failed = .failed });
    try testing.expect(fx.app.busy == null);
    try fx.expectNotice("could not open");
}

test "a call that ran out of time says so, not that it failed" {
    // Two different next moves. "is gh set up?" sends a reader who is behind
    // a slow network after the wrong thing entirely.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try apply(&fx.app, .{ .list = false }, .{ .failed = .timed_out });
    try fx.expectNotice("did not answer in time");
    try apply(&fx.app, .{ .list = false }, .{ .failed = .failed });
    try fx.expectNotice("is gh set up?");
}

test "opening a request brings its remarks and the login back with it" {
    // One job, not three: fetching the rest on the main thread froze the
    // pane with the spinner already gone.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try apply(&fx.app, .{ .open = .{ .number = 19 } }, .{
        .opened = .{
            .refs = .{ .number = 19, .repo = "o/r", .base = "b", .target = "t", .label = "#19 threads" },
            .login = "kunkka19xx",
            .remarks = &.{
                .{ .id = 4242, .path = "a.zig", .line = 7, .author = "someone", .body = "this retry never backs off", .outdated = false },
                // A remark on the file rather than on a line has nowhere to sit.
                .{ .id = 4243, .path = "a.zig", .line = 0, .author = "someone", .body = "whole file", .outdated = false },
            },
        },
    });

    try testing.expectEqual(@as(u32, 19), fx.app.pr.number);
    try testing.expectEqualStrings("kunkka19xx", fx.app.pr.viewer());
    try testing.expectEqual(@as(usize, 1), fx.app.comments.len());
    try fx.expectNotice("1 remark already on it");
}

test "a thread arrives in the order it was written, under the remark it answers" {
    // Store order is reading order, so nothing downstream has to sort - and
    // everything that walks these agrees about what comes after what.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // As the forge lists them: two threads interleaved, the later reply
    // ahead of the earlier one.
    try apply(&fx.app, .{ .open = .{ .number = 19 } }, .{ .opened = .{
        .refs = .{ .number = 19, .repo = "o/r", .base = "b", .target = "t", .label = "#19" },
        .remarks = &.{
            .{ .id = 10, .path = "a.zig", .line = 26, .author = "someone", .body = "root one", .outdated = false, .created = 100 },
            .{ .id = 13, .path = "b.zig", .line = 4, .author = "other", .body = "root two", .outdated = false, .created = 130 },
            .{ .id = 12, .path = "a.zig", .line = 26, .author = "me", .body = "second reply", .outdated = false, .reply_to = 10, .created = 120 },
            .{ .id = 11, .path = "a.zig", .line = 26, .author = "other", .body = "first reply", .outdated = false, .reply_to = 10, .created = 110 },
        },
    } });

    const list = fx.app.comments.items();
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqualStrings("root one", list[0].body);
    try testing.expectEqualStrings("first reply", list[1].body);
    try testing.expectEqualStrings("second reply", list[2].body);
    // The other thread stays whole rather than being interleaved into this one.
    try testing.expectEqualStrings("root two", list[3].body);

    // Every message of a thread answers to the same id, which is what lets
    // the overlay collect one.
    try testing.expectEqual(@as(u64, 10), list[0].thread());
    try testing.expectEqual(@as(u64, 10), list[1].thread());
    try testing.expectEqual(@as(u64, 10), list[2].thread());
    try testing.expectEqual(@as(u64, 13), list[3].thread());
}

test "a reply to a reply belongs to the thread, not to a thread of its own" {
    // Resolved by walking up, so a forge that answers with the parent does
    // not split a thread of three into two.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try apply(&fx.app, .{ .open = .{ .number = 19 } }, .{ .opened = .{
        .refs = .{ .number = 19, .repo = "o/r", .base = "b", .target = "t", .label = "#19" },
        .remarks = &.{
            .{ .id = 10, .path = "a.zig", .line = 26, .author = "someone", .body = "root", .outdated = false, .created = 100 },
            .{ .id = 11, .path = "a.zig", .line = 26, .author = "other", .body = "reply", .outdated = false, .reply_to = 10, .created = 110 },
            .{ .id = 12, .path = "a.zig", .line = 26, .author = "me", .body = "reply to the reply", .outdated = false, .reply_to = 11, .created = 120 },
        },
    } });

    const list = fx.app.comments.items();
    try testing.expectEqual(@as(usize, 3), list.len);
    for (list) |n| try testing.expectEqual(@as(u64, 10), n.thread());
    try testing.expectEqualStrings("reply to the reply", list[2].body);
}

test "a request whose remarks could not be read says so rather than looking empty" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try apply(&fx.app, .{ .open = .{ .number = 19 } }, .{ .opened = .{
        .refs = .{ .number = 19, .repo = "o/r", .base = "b", .target = "t", .label = "#19" },
        .remarks_failed = true,
    } });
    try fx.expectNotice("could not read the remarks");
}

test "a picked row outlives the arena its label was built in" {
    // `pick` carries a copy: the picker closes before the call is made, and
    // closing it is what lets the arena the row lived in be reset.
    const pr: Pr = .of(.{
        .number = 13,
        .state = "MERGED",
        .base_ref = "main",
        .base_oid = "be94b77",
        .head_oid = "c7143ba",
        .url = "https://github.com/o/r/pull/13",
        .title = "feat: syntax highlight for json",
    });
    const back = pr.back();
    try testing.expectEqual(@as(u32, 13), back.number);
    try testing.expectEqualStrings("c7143ba", back.head_oid);
    try testing.expectEqualStrings("feat: syntax highlight for json", back.title);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("opening #13", (Want{ .pick = .{ .pr = pr } }).says(&buf));
    try testing.expectEqualStrings("listing pull requests", (Want{ .list = true }).says(&buf));
}

test "every path that posts arms the spinner, not a notice" {
    // Three keys post: `:post` for the batch, `<C-p>` in the list for one,
    // and `<C-p>` in the box for the one being written. The third was missed
    // once, and a static notice is exactly what a frozen pane looks like.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.onPr(16, "o/r", "");
    _ = try fx.app.comments.add("a.zig", 1, "a remark");

    postReview(&fx.app, .comment, "");
    try testing.expect(fx.app.pr.pending != null);
    try testing.expect(fx.app.busy != null);
    try testing.expect(std.mem.indexOf(u8, fx.app.busy.?.label(), "...") == null);
}

test "editing a remark of the reader's own is a call, and the store waits for it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.onPr(16, "o/r", "");
    const id = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "was", .author = "me", .outdated = false, .remote = 555 });

    amend(&fx.app, id, 555, "now\twith a tab");
    const req = fx.app.pr.pending.?.amend;
    try testing.expectEqual(id, req.id);
    try testing.expectEqual(@as(u64, 555), req.remote);
    // Armed, not made: the copy here still says what the forge says.
    try testing.expectEqualStrings("was", fx.app.comments.find(id).?.body);

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const job = prepareAmend(&fx.app, a.allocator(), req).?;
    try testing.expectEqualStrings("o/r", job.amend.repo);
    try testing.expectEqualStrings("{\"body\":\"now\\twith a tab\"}", job.amend.payload);

    // Only once the forge has taken it does the copy here follow.
    try apply(&fx.app, job, .amended);
    try testing.expectEqualStrings("now\twith a tab", fx.app.comments.find(id).?.body);

    // A failed call leaves it exactly as the forge still has it.
    amend(&fx.app, id, 555, "never sent");
    const again = prepareAmend(&fx.app, a.allocator(), fx.app.pr.pending.?.amend).?;
    fx.app.pr.pending = null;
    try apply(&fx.app, again, .{ .failed = .failed });
    try testing.expectEqualStrings("now\twith a tab", fx.app.comments.find(id).?.body);
    try testing.expect(std.mem.indexOf(u8, fx.app.notice.text(), "unchanged") != null);
}

test "deleting a remark of the reader's own asks first, then takes it off the request" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.onPr(16, "o/r", "me");
    const id = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "mine", .author = "me", .outdated = false, .remote = 555 });

    dropAsk(&fx.app, fx.app.comments.find(id).?);
    try testing.expect(fx.app.pr.dropping != null);
    // Asked, not done: the remark is still on the request and still here.
    try testing.expect(fx.app.comments.find(id) != null);

    // Anything but `y` deletes nothing and arms nothing.
    dropAnswer(&fx.app, .{ .codepoint = 'n', .mods = .{} });
    try testing.expect(fx.app.pr.dropping == null);
    try testing.expect(fx.app.pr.pending == null);
    try testing.expect(fx.app.comments.find(id) != null);

    dropAsk(&fx.app, fx.app.comments.find(id).?);
    dropAnswer(&fx.app, .{ .codepoint = 'y', .mods = .{} });
    const req = fx.app.pr.pending.?.drop;
    try testing.expectEqual(@as(u64, 555), req.remote);

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const job = prepareDrop(&fx.app, a.allocator(), req).?;
    try testing.expectEqualStrings("o/r", job.drop.repo);
    try testing.expectEqual(@as(u64, 555), job.drop.remote);

    // A call that failed keeps the copy here: the remark is still on the
    // request, and dropping it would hide one that is.
    try apply(&fx.app, job, .{ .failed = .failed });
    try testing.expect(fx.app.comments.find(id) != null);

    try apply(&fx.app, job, .dropped);
    try testing.expect(fx.app.comments.find(id) == null);
}

test "the post key works on the remark under the cursor, not only in the list" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.onPr(16, "o/r", "me");
    const id = try fx.app.comments.add("a.zig", 2, "this retry never backs off");
    try fx.app.rebuildRows(.line);
    try notes.commentView(&fx.app, app_mod.body_rows);
    try fx.press("<Esc>");

    try fx.press("<C-p>");
    const req = fx.app.pr.pending.?.post;
    try testing.expectEqual(id, req.one.?);

    // Nothing under the cursor is the one case that has to say so: a key that
    // did nothing would read as a failed post.
    fx.app.pr.pending = null;
    fx.app.comments.remove(id);
    try fx.app.rebuildRows(.line);
    try fx.press("<C-p>");
    try testing.expect(fx.app.pr.pending == null);
    try testing.expect(fx.app.notice.text().len > 0);
}

test "a reply is a call, and the thread waits for the forge to mint an id" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.onPr(16, "o/r", "me");
    const root = try fx.app.comments.adopt(.{
        .path = "a.zig",
        .line = 26,
        .body = "why this approach?",
        .author = "other",
        .remote = 900,
    });
    _ = root;

    reply(&fx.app, 900, "because of the arena");
    const req = fx.app.pr.pending.?.reply;
    try testing.expectEqual(@as(u64, 900), req.root);
    // Armed, not made: nothing is on the thread until the call lands.
    try testing.expectEqual(@as(usize, 1), fx.app.comments.len());

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const job = prepareReply(&fx.app, a.allocator(), req).?;
    try testing.expectEqualStrings("o/r", job.reply.repo);
    try testing.expectEqual(@as(u32, 16), job.reply.number);
    try testing.expectEqualStrings("{\"body\":\"because of the arena\"}", job.reply.payload);

    // The id the forge minted is what makes it a message on the thread rather
    // than a second remark that happens to share a line.
    try apply(&fx.app, job, .{ .replied = 901 });
    try testing.expectEqual(@as(usize, 2), fx.app.comments.len());
    const posted = fx.app.comments.findRemote(901).?;
    try testing.expectEqualStrings("because of the arena", posted.body);
    try testing.expectEqualStrings("me", posted.author);
    try testing.expectEqual(@as(u64, 900), posted.reply_to);
    try testing.expectEqual(@as(u64, 900), posted.thread());
    // On the root's line, wherever that has moved to - a reply has no line of
    // its own to be anchored at.
    try testing.expectEqualStrings("a.zig", posted.path);
    try testing.expectEqual(@as(u32, 26), posted.line);
    // It lives on the forge now, so `.lgtm/` never writes it and `:post`
    // never sends it a second time.
    try testing.expect(posted.posted);
    try testing.expect(posted.theirs());
}

test "a reply that fails leaves the thread as the forge still has it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.onPr(16, "o/r", "");
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 26, .body = "root", .author = "other", .remote = 900 });

    reply(&fx.app, 900, "never sent");
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const job = prepareReply(&fx.app, a.allocator(), fx.app.pr.pending.?.reply).?;
    fx.app.pr.pending = null;

    try apply(&fx.app, job, .{ .failed = .failed });
    try testing.expectEqual(@as(usize, 1), fx.app.comments.len());
    try fx.expectNotice("could not reply on #16");

    // A deadline that fired is a different fact from a call that failed.
    try apply(&fx.app, job, .{ .failed = .timed_out });
    try fx.expectNotice("gh did not answer in time");
}

test "a thread that went away under the box takes nothing with it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.onPr(16, "o/r", "");

    reply(&fx.app, 900, "into the void");
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // Refused rather than posted at a root this checkout can no longer name.
    try testing.expect(prepareReply(&fx.app, a.allocator(), fx.app.pr.pending.?.reply) == null);
    try fx.expectNotice("no longer here");
}
