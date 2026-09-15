// SPDX-License-Identifier: Apache-2.0
//
// One line's conversation, stacked, selected by comment id rather than by
// line: `Store.at` is first match by contract, so on a line carrying two
// remarks the reader's own was unreachable. The geometry is in
// `ui/popup.zig`; what is here is the state machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../i18n/i18n.zig");

const app_mod = @import("app.zig");
const App = app_mod.App;
const comments_mod = @import("../core/comments.zig");
const event = @import("../core/event.zig");
const keymap = @import("keymap.zig");
const keytext = @import("keytext.zig");
const notes = @import("notes.zig");
const outgoing = @import("outgoing.zig");
const pr_mod = @import("pr.zig");
const render = @import("render.zig");

/// The most messages one overlay holds, so the set fits a frame buffer.
pub const max_messages = 64;

/// Lines of the root's code above the stack, from the end: the forge's
/// `diff_hunk` finishes on the line the remark is about.
pub const code_lines: usize = 4;

pub const State = struct {
    /// A comment id, not an index: the store is rebuilt on every re-diff.
    selected: u32 = 0,
    /// The mode to return to on close.
    from: event.Mode = .normal,
    path_buf: [1024]u8 = undefined,
    path_len: u16 = 0,
    line: u32 = 0,
    /// What the last frame drew, so a page is half of what is on screen.
    /// Written by the renderer, the only thing that knows the wrap.
    layout: render.ThreadLayout = .{},

    pub fn path(self: *const State) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Opens the overlay on a remark, selected on the reader's own if the
/// conversation has one: theirs is the only message the keys can act on.
pub fn open(app: *App, on: *const comments_mod.Comment) void {
    app.thread.from = app.mode;
    app.thread.line = on.line;
    app.thread.path_len = @intCast(@min(on.path.len, app.thread.path_buf.len));
    @memcpy(app.thread.path_buf[0..app.thread.path_len], on.path[0..app.thread.path_len]);
    app.thread.layout = .{};
    app.thread.selected = on.id;

    var buf: [max_messages]*comments_mod.Comment = undefined;
    for (messages(app, &buf)) |n| {
        if (!notes.mine(app, n.*)) continue;
        app.thread.selected = n.id;
        break;
    }

    app.mode = .thread;
    // The rest of the tool acts on this too, so the choice outlives the box.
    app.comment_sel = app.thread.selected;
}

pub fn close(app: *App) void {
    app.mode = app.thread.from;
}

/// Whether the overlay still has a conversation to draw: the remark it was
/// open on may have been the last one on the line.
pub fn alive(app: *App) bool {
    var buf: [max_messages]*comments_mod.Comment = undefined;
    return messages(app, &buf).len > 0;
}

/// Whether a remark is worth an overlay. One alone on its line is not: it
/// opens in the compose box the way it always has.
pub fn worthOpening(app: *App, on: *const comments_mod.Comment) bool {
    var buf: [max_messages]*comments_mod.Comment = undefined;
    return app.comments.conversationAt(on.path, on.line, &buf).len > 1;
}

/// The conversation as it stands, into a caller's buffer.
pub fn messages(app: *App, buf: []*comments_mod.Comment) []*comments_mod.Comment {
    return app.comments.conversationAt(app.thread.path(), app.thread.line, buf);
}

/// Where the selection sits, clamped: a remark deleted under the overlay
/// leaves the selection on whatever took its place.
pub fn selectedAt(app: *App, list: []const *comments_mod.Comment) usize {
    for (list, 0..) |n, i| {
        if (n.id == app.thread.selected) return i;
    }
    return 0;
}

/// The overlay's keys. Movement is the list's own commands over a different
/// set of things; only selecting, replying and closing are its own.
pub fn run(app: *App, cmd: keymap.Command, body: u16) !void {
    // A box that sizes itself has no use for the body height.
    _ = body;
    var buf: [max_messages]*comments_mod.Comment = undefined;
    const list = messages(app, &buf);
    if (list.len == 0) return close(app);
    const at = selectedAt(app, list);

    switch (cmd) {
        .list_down => select(app, list, at + 1),
        .list_up => select(app, list, at -| 1),
        .top => select(app, list, 0),
        .bottom => select(app, list, list.len - 1),
        // By rows, not messages: one reply can be taller than the box.
        .page_down => scroll(app, 1),
        .page_up => scroll(app, -1),
        .thread_select => try act(app, list, at),
        .thread_reply => reply(app, list[at]),
        .comment_delete => {
            // The neighbour's id first: after the remark goes, this list is
            // pointers into a store that has moved under it.
            const next = if (at + 1 < list.len) list[at + 1].id else if (at > 0) list[at - 1].id else 0;
            notes.commentDelete(app);
            // One on the request is only *asked* about here, and is still
            // there until the forge answers - so the selection moves only
            // once the remark it names has actually gone.
            if (next != 0 and app.comments.find(app.thread.selected) == null) {
                app.thread.selected = next;
                app.comment_sel = next;
                app.thread.layout.follow = true;
            }
            if (!alive(app)) close(app);
        },
        .thread_close => close(app),
        else => {},
    }
}

fn select(app: *App, list: []const *comments_mod.Comment, to: usize) void {
    const i = @min(to, list.len - 1);
    app.thread.selected = list[i].id;
    app.comment_sel = list[i].id;
    // The frame puts it on screen: only it knows how many rows are above.
    app.thread.layout.follow = true;
}

fn scroll(app: *App, delta: i32) void {
    const half: u16 = @max(1, app.thread.layout.rows / 2);
    const top = app.thread.layout.total -| app.thread.layout.rows;
    const at = app.thread.layout.scroll;
    app.thread.layout.scroll = if (delta > 0) @min(top, at + half) else at -| half;
    // An explicit scroll stops the selection dragging the view back.
    app.thread.layout.follow = false;
}

/// `<CR>`: the selected message in the compose box. The reader's own opens to
/// be edited; somebody else's is already fully on screen here.
fn act(app: *App, list: []const *comments_mod.Comment, at: usize) !void {
    const n = list[at];
    if (n.theirs() and !notes.mine(app, n.*)) {
        notes.sayTheirs(app, n.*, .thread);
        return;
    }
    // Left standing, so `<Esc>` puts the reader back in the conversation.
    app.compose_from = .thread;
    try notes.commentEdit(app);
}

/// `r`: a message on the conversation the selection belongs to. Keyed on the
/// thread's root, which is all the forge's endpoint takes - a reply has no
/// line of its own.
pub fn reply(app: *App, on: *const comments_mod.Comment) void {
    if (app.pr.number == 0) {
        app.notice.set("not reviewing a pull request", .{});
        return;
    }
    var root = on.thread();
    if (root == 0) {
        // A remark of this checkout's has no thread, but the conversation it
        // sits in may have one.
        var buf: [max_messages]*comments_mod.Comment = undefined;
        for (app.comments.conversationAt(on.path, on.line, &buf)) |n| {
            if (n.thread() == 0) continue;
            root = n.thread();
            break;
        }
    }
    if (root == 0) {
        // Not on the request yet: posting it is what makes a thread.
        var key: [32]u8 = undefined;
        app.notice.set("that one is not on the request yet - {s} lists what can be posted", .{
            app.keyFor(.comment_list, .normal, &key),
        });
        return;
    }

    if (app.mode == .thread) app.compose_from = .thread;
    app.compose_for = .{ .reply = root };
    app.compose_to = .copy;
    app.compose.start("");
    app.preset_index = null;
    app.mode = .note_input;
}

/// The same from outside the overlay, on whatever remark the cursor is at.
pub fn replyHere(app: *App) void {
    const n = notes.commentUnderCursor(app) orelse {
        app.notice.set("no comment here", .{});
        return;
    };
    reply(app, n);
}

/// How long ago, in one unit: `2d` answers "an hour or a month later" in
/// three columns where `2 days, 4 hours ago` takes eighteen.
pub fn ago(buf: []u8, seconds: i64) []const u8 {
    if (seconds < 0) return i18n.t("just now");
    if (seconds < 60) return i18n.t("just now");
    const mins = @divTrunc(seconds, 60);
    if (mins < 60) return i18n.bufPrint(buf, "{d}m ago", .{mins}) catch "";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return i18n.bufPrint(buf, "{d}h ago", .{hours}) catch "";
    const days = @divTrunc(hours, 24);
    if (days < 7) return i18n.bufPrint(buf, "{d}d ago", .{days}) catch "";
    const weeks = @divTrunc(days, 7);
    if (days < 365) return i18n.bufPrint(buf, "{d}w ago", .{weeks}) catch "";
    return i18n.bufPrint(buf, "{d}y ago", .{@divTrunc(days, 365)}) catch "";
}

/// The overlay for one frame, or null when it is not open.
pub fn view(app: *App, arena: Allocator) Allocator.Error!?render.ThreadView {
    if (app.mode != .thread) return null;
    var buf: [max_messages]*comments_mod.Comment = undefined;
    const list = messages(app, &buf);
    if (list.len == 0) return null;

    const now: i64 = std.Io.Timestamp.now(app.io, .real).toSeconds();
    const out = try arena.alloc(render.ThreadMessage, list.len);
    for (list, out) |n, *m| {
        var when: [24]u8 = undefined;
        m.* = .{
            // A remark written in this pane has no author to name and no time
            // worth showing: the reader was there.
            .author = if (n.theirs()) n.author else "",
            // Zero is a remark the forge gave no date for, which is not the
            // epoch and must not read as 1970.
            .when = if (n.created > 0) try arena.dupe(u8, ago(&when, now - n.created)) else "",
            .body = n.body,
            .mine = notes.mine(app, n.*),
            .stale = n.state == .stale,
            .sent = n.state == .sent,
        };
    }

    return .{
        .path = app.thread.path(),
        .line = app.thread.line,
        .ask = try pr_mod.askText(app, arena),
        .messages = out,
        .selected = selectedAt(app, list),
        // The forge's copy: our diff no longer holds a stale remark's line.
        .code = codeOf(list),
        .layout = &app.thread.layout,
        .bindings = app.km.bindings,
    };
}

/// The last lines of the root's hunk, which ends on the line the remark was
/// written against.
fn codeOf(list: []const *comments_mod.Comment) []const u8 {
    const hunk = list[0].hunk;
    if (hunk.len == 0) return "";
    const text = std.mem.trimEnd(u8, hunk, "\n");
    var at = text.len;
    var seen: usize = 0;
    while (at > 0) : (at -= 1) {
        if (text[at - 1] != '\n') continue;
        seen += 1;
        if (seen == code_lines) return text[at..];
    }
    return text;
}

const testing = std.testing;

/// Three remarks on one line: somebody else's, a reply of the reader's own,
/// and one more of theirs. The shape the overlay exists for.
fn conversationFixture(fx: *app_mod.Fixture) !void {
    fx.onPr(19, "o/r", "kunkka19xx");
    const path = fx.app.current().?.path();
    _ = try fx.app.comments.adopt(.{ .path = path, .line = 1, .body = "root", .author = "someone", .remote = 10, .created = 100 });
    _ = try fx.app.comments.adopt(.{ .path = path, .line = 1, .body = "mine", .author = "kunkka19xx", .remote = 11, .reply_to = 10, .created = 110 });
    _ = try fx.app.comments.adopt(.{ .path = path, .line = 1, .body = "last", .author = "other", .remote = 12, .reply_to = 10, .created = 120 });
}

test "a line carrying a conversation opens the overlay, on the reader's own" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);

    try notes.commentView(&fx.app, 20);
    try testing.expectEqual(event.Mode.thread, fx.app.mode);

    // Not whichever the forge listed first: the reader's own is the one they
    // can do anything to, and landing elsewhere is what made it unreachable.
    var buf: [max_messages]*comments_mod.Comment = undefined;
    const list = messages(&fx.app, &buf);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("mine", list[selectedAt(&fx.app, list)].body);
    // Left behind for everything else that acts on "the comment here".
    try testing.expectEqual(fx.app.thread.selected, fx.app.comment_sel);
}

test "one remark on a line still opens in the box, not in an overlay" {
    // An overlay listing one message is a lid on a thing already open.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.app.comments.add(fx.app.current().?.path(), 1, "mine, alone");

    try notes.commentView(&fx.app, 20);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
}

test "j and k walk the messages, and gg and G reach the ends" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    var buf: [max_messages]*comments_mod.Comment = undefined;
    try run(&fx.app, .list_up, 20);
    try testing.expectEqualStrings("root", messages(&fx.app, &buf)[selectedAt(&fx.app, messages(&fx.app, &buf))].body);
    // The ends hold rather than wrapping: a conversation is read in order.
    try run(&fx.app, .list_up, 20);
    try testing.expectEqualStrings("root", messages(&fx.app, &buf)[selectedAt(&fx.app, messages(&fx.app, &buf))].body);

    try run(&fx.app, .bottom, 20);
    try testing.expectEqualStrings("last", messages(&fx.app, &buf)[selectedAt(&fx.app, messages(&fx.app, &buf))].body);
    try run(&fx.app, .top, 20);
    try testing.expectEqualStrings("root", messages(&fx.app, &buf)[selectedAt(&fx.app, messages(&fx.app, &buf))].body);
}

test "a page is half of what is on screen, and it stops the view following" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    // What a frame would have written back.
    fx.app.thread.layout = .{ .rows = 10, .total = 40, .scroll = 0, .follow = false };
    try run(&fx.app, .page_down, 20);
    try testing.expectEqual(@as(u16, 5), fx.app.thread.layout.scroll);
    try testing.expect(!fx.app.thread.layout.follow);
    try run(&fx.app, .page_up, 20);
    try testing.expectEqual(@as(u16, 0), fx.app.thread.layout.scroll);
    // Never past the last window.
    for (0..20) |_| try run(&fx.app, .page_down, 20);
    try testing.expectEqual(@as(u16, 30), fx.app.thread.layout.scroll);

    // Moving the selection hands the view back to it.
    try run(&fx.app, .list_up, 20);
    try testing.expect(fx.app.thread.layout.follow);
}

test "enter edits the reader's own and says who wrote the rest" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    // Somebody else's is already fully shown.
    try run(&fx.app, .top, 20);
    try run(&fx.app, .thread_select, 20);
    try testing.expectEqual(event.Mode.thread, fx.app.mode);
    try fx.expectNotice("someone wrote that one");

    // The reader's own opens to be edited, saving to the forge.
    try run(&fx.app, .list_down, 20);
    try run(&fx.app, .thread_select, 20);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expect(!fx.app.compose.read_only);
    try testing.expectEqual(@as(u64, 11), fx.app.compose_for.amend.remote);
    try testing.expectEqualStrings("mine", fx.app.compose.text());
}

test "escape closes back to where it was opened from" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    try run(&fx.app, .thread_close, 20);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    // The selection outlives the overlay, so a delete means the highlighted one.
    try testing.expectEqualStrings("mine", notes.commentUnderCursor(&fx.app).?.body);
}

test "deleting the selection leaves the overlay pointing at something real" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    fx.app.comments.remove(fx.app.thread.selected);
    var buf: [max_messages]*comments_mod.Comment = undefined;
    const list = messages(&fx.app, &buf);
    try testing.expectEqual(@as(usize, 2), list.len);
    // Clamped to the top rather than left pointing at a remark that is gone.
    try testing.expectEqual(@as(usize, 0), selectedAt(&fx.app, list));
    try run(&fx.app, .list_down, 20);
    try testing.expectEqualStrings("last", list[selectedAt(&fx.app, list)].body);
}

test "a conversation emptied under the overlay closes it rather than drawing nothing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try view(&fx.app, arena.allocator()) != null);

    while (fx.app.comments.len() > 0) fx.app.comments.remove(fx.app.comments.items()[0].id);
    try testing.expect(try view(&fx.app, arena.allocator()) == null);
    try run(&fx.app, .list_down, 20);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "how long ago reads in one unit" {
    var buf: [24]u8 = undefined;
    // Under a minute has no number worth printing.
    try testing.expectEqualStrings("just now", ago(&buf, 0));
    try testing.expectEqualStrings("just now", ago(&buf, 59));
    try testing.expectEqualStrings("1m ago", ago(&buf, 60));
    try testing.expectEqualStrings("59m ago", ago(&buf, 59 * 60));
    try testing.expectEqualStrings("1h ago", ago(&buf, 60 * 60));
    try testing.expectEqualStrings("23h ago", ago(&buf, 23 * 3600));
    try testing.expectEqualStrings("1d ago", ago(&buf, 24 * 3600));
    try testing.expectEqualStrings("6d ago", ago(&buf, 6 * 24 * 3600));
    try testing.expectEqualStrings("1w ago", ago(&buf, 7 * 24 * 3600));
    try testing.expectEqualStrings("52w ago", ago(&buf, 364 * 24 * 3600));
    try testing.expectEqualStrings("1y ago", ago(&buf, 365 * 24 * 3600));
    // A clock that disagrees with the forge's is not worth a negative number.
    try testing.expectEqualStrings("just now", ago(&buf, -90));
}

test "the code shown is the tail of the hunk, where the remark is" {
    var one: comments_mod.Comment = .{ .id = 1, .path = "a.zig", .line = 1, .body = "b" };
    one.hunk = "@@ -1,8 +1,8 @@\n a\n b\n c\n d\n-e\n+f\n";
    var list = [_]*comments_mod.Comment{&one};

    // Four lines from the end, where the forge's hunk is about the remark.
    try testing.expectEqualStrings(" c\n d\n-e\n+f", codeOf(&list));

    // A short hunk is all of it; no hunk draws nothing.
    one.hunk = "@@ -1 +1 @@\n+a";
    try testing.expectEqualStrings("@@ -1 +1 @@\n+a", codeOf(&list));
    one.hunk = "";
    try testing.expectEqualStrings("", codeOf(&list));
}

test "r opens an empty box aimed at the thread, not at the line" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    // On somebody else's, which is the message a reply usually answers.
    try run(&fx.app, .top, 20);
    try run(&fx.app, .thread_reply, 20);

    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expect(!fx.app.compose.read_only);
    try testing.expectEqualStrings("", fx.app.compose.text());
    // The root, not the selection: the endpoint is keyed on what started it.
    try testing.expectEqual(@as(u64, 10), fx.app.compose_for.reply);
}

test "replying to a reply answers the thread it belongs to" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    try run(&fx.app, .bottom, 20);
    try run(&fx.app, .thread_reply, 20);
    // The last message's own id is 12; the conversation's is still 10.
    try testing.expectEqual(@as(u64, 10), fx.app.compose_for.reply);
}

test "a remark still local to this checkout has no thread to answer" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.app.pr.number = 16;
    const path = fx.app.current().?.path();
    const n = fx.app.comments.find(try fx.app.comments.add(path, 1, "mine, unposted")).?;

    reply(&fx.app, n);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try testing.expect(fx.app.compose_for == .agent);
    try fx.expectNotice("not on the request yet");
}

test "replying without a request open says so rather than opening a box" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    const path = fx.app.current().?.path();
    const n = fx.app.comments.find(try fx.app.comments.add(path, 1, "working tree")).?;

    reply(&fx.app, n);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try fx.expectNotice("not reviewing a pull request");
}

test "save-and-send in a reply box does not leave a second remark on the line" {
    // A reply saves to the forge, never into the store as a remark of its own.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);
    try run(&fx.app, .thread_reply, 20);

    const before = fx.app.comments.len();
    _ = fx.app.compose.feed(.{ .codepoint = 'x', .mods = .{} });
    try outgoing.composeDo(&fx.app, .compose_send_now, .{ .codepoint = 's', .mods = .{ .ctrl = true } }, 20);

    try testing.expectEqual(before, fx.app.comments.len());
    try fx.expectNotice("on the request");
}

test "r on an unposted remark of your own still answers the thread beside it" {
    // A line carrying both a posted conversation and a local remark: the
    // overlay selects the reader's own.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    const path = fx.app.current().?.path();
    const local = fx.app.comments.find(try fx.app.comments.add(path, 1, "not posted yet")).?;

    reply(&fx.app, local);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqual(@as(u64, 10), fx.app.compose_for.reply);
}

test "a line with nothing from the request has no thread to answer" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    fx.onPr(16, "o/r", "me");
    const path = fx.app.current().?.path();
    const n = fx.app.comments.find(try fx.app.comments.add(path, 1, "mine, alone")).?;

    reply(&fx.app, n);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
    try fx.expectNotice("not on the request yet");
}

test "C-p in a reply box posts it, rather than naming another key" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);
    try run(&fx.app, .top, 20);
    try run(&fx.app, .thread_reply, 20);

    _ = fx.app.compose.feed(.{ .codepoint = 'x', .mods = .{} });
    try outgoing.composeDo(&fx.app, .compose_post_now, .{ .codepoint = 'p', .mods = .{ .ctrl = true } }, 20);

    // The same call Enter arms, not a notice telling the reader to press it.
    try testing.expectEqual(@as(u64, 10), fx.app.pr.pending.?.reply.root);
    // And back in the conversation it was written on, not out at the diff.
    try testing.expectEqual(event.Mode.thread, fx.app.mode);
}

test "a box opened from the thread closes back into it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);

    // Out of the box is back into the conversation, same message selected.
    const was = fx.app.thread.selected;
    try run(&fx.app, .thread_select, 20);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    // The box is modal: the first `<Esc>` leaves insert, the second the box.
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try testing.expectEqual(event.Mode.thread, fx.app.mode);
    try testing.expectEqual(was, fx.app.thread.selected);

    // And out of the overlay is out to the diff, as it always was.
    try run(&fx.app, .thread_close, 20);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "a conversation emptied under the box does not close into an empty overlay" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try conversationFixture(fx);
    try notes.commentView(&fx.app, 20);
    try run(&fx.app, .thread_reply, 20);

    while (fx.app.comments.len() > 0) fx.app.comments.remove(fx.app.comments.items()[0].id);
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "a box opened from the diff still closes to the diff" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.app.comments.add(fx.app.current().?.path(), 1, "mine, alone");

    try notes.commentView(&fx.app, 20);
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try outgoing.composeDo(&fx.app, .compose_cancel, .{ .codepoint = 27, .mods = .{} }, 20);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}
