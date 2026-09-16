// SPDX-License-Identifier: Apache-2.0
//
// Review comments: the remarks collected while reading, and the machinery that
// keeps them pointing at the right line while the agent rewrites the file
// underneath them.
//
// The whole feature rests on `core/anchor.zig`, which is why that was built
// first and gated on its own, before any of this was written: a comment that drifts to the
// wrong line is worse than no comment at all, and finding that out with 300 lines
// of anchoring was far cheaper than with a comment UI attached. It passed at 100%
// across the fixture set, so this file can be written as if re-anchoring works
// - and handle the case where it does not by saying so rather than guessing.
//
// Two hard rules govern everything here:
//
//   - **Comments own their bytes** (rule 4). They outlive the diff arena, which
//     is reset on every re-diff, so `path` and `body` are copies taken from
//     the session allocator. A comment holding a slice into the arena would read
//     as plausible garbage one re-diff later.
//   - **A comment is never silently dropped** (rule 7). One that cannot be
//     re-anchored becomes `stale` and stays visible, because the reader wrote
//     it and only the reader gets to decide it no longer matters.
//
// `core/`, so no UI and no terminal: comments in, comments out, and a store that can
// be driven entirely from a test.

const std = @import("std");
const Allocator = std.mem.Allocator;

const anchor = @import("anchor.zig");

/// Where a comment is in its life.
///
/// `sent` rather than deleting on submit: a review that has been handed to the
/// agent is still the thing the reader wrote, and seeing it greyed out beside
/// the code is how they remember they already said it.
pub const State = enum {
    open,
    sent,
    /// The line it was written against is gone, or moved somewhere the anchor
    /// ladder could not follow. Kept, shown, and never quietly removed.
    stale,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .open => "open",
            .sent => "sent",
            .stale => "stale",
        };
    }
};

pub const Comment = struct {
    id: u32,
    /// Path as the review knows it: the new file's, or the old one's for a
    /// deletion. Owned.
    path: []const u8,
    /// 1-based line in the working tree. Carried forward on every re-diff.
    line: u32,
    /// Lines the remark covers, one being just `line`. A count and not an end
    /// line: re-anchoring moves one number and the span comes with it.
    span: u32 = 1,
    /// What the reader wrote. Owned, and may contain newlines - it is written
    /// to a file, not sent through `send-keys` (hard rule 1 is about the
    /// bridge, and `review.zig` sends one line naming the file).
    body: []const u8,
    state: State = .open,
    /// The text of the line the comment was written against. Owned.
    ///
    /// Within a session `carry` does better than this - it has both versions
    /// of the file and reads the answer out of a line map. Across a *restart*
    /// it is all there is: the file may have been rewritten while lgtm was not
    /// running, and there is no previous version to diff against. One line of
    /// text is enough to find where it went, or to say it has gone.
    anchor: []const u8 = "",
    /// Written against a line that the change removed. The comment hangs on
    /// the nearest surviving line of its hunk, and this is what stops that
    /// from reading as a remark about the code it landed next to.
    about_removed: bool = false,
    /// Handed to the forge. Separate from `state`, which says whether the
    /// *agent* has seen it: a remark legitimately goes to both audiences, and
    /// one field for two would make either destination skip the other's work.
    posted: bool = false,
    /// Who left it, when that is not the reader. Empty for their own.
    ///
    /// One field carries the whole of what it means to be somebody else's
    /// remark: it cannot be edited or deleted, it is already posted so it is
    /// never posted again, and it is not written to `.lgtm/` - the forge is
    /// where it lives and opening the request fetches it. Owned when set, and
    /// the empty default is a literal, which is why `deinit` asks.
    author: []const u8 = "",
    /// The forge's id, when it came from the request. What a `PATCH` names.
    /// Zero for a remark written in this pane.
    remote: u64 = 0,
    /// The remark on the request this one answers, or zero when it starts a
    /// thread. Without it, a reply is a row that happens to share a line.
    reply_to: u64 = 0,
    /// Seconds since the epoch, and zero for a remark written here: the
    /// reader was there, so there is no time worth showing.
    created: i64 = 0,
    /// The code it was written against, as the forge kept it. Owned, under
    /// rule 4 like every other string here - and carried rather than rebuilt,
    /// because a stale remark is one our diff no longer holds the line for.
    hunk: []const u8 = "",

    pub fn theirs(self: Comment) bool {
        return self.author.len > 0;
    }

    /// Which conversation it belongs to: the remark it answers, or itself.
    /// Zero in this pane, where two remarks on a line are two remarks rather
    /// than a conversation.
    pub fn thread(self: Comment) u64 {
        return if (self.reply_to != 0) self.reply_to else self.remote;
    }

    pub fn end(self: Comment) u32 {
        return self.line + @max(self.span, 1) - 1;
    }

    pub fn deinit(self: Comment, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.body);
        gpa.free(self.anchor);
        if (self.author.len > 0) gpa.free(self.author);
        if (self.hunk.len > 0) gpa.free(self.hunk);
    }
};

/// Every comment in the session, in the order they were written.
///
/// Order is insertion order rather than by file and line: `]c` walks them the
/// way the review is laid out, and this list is what persists. Sorting on
/// write would make the file churn for no reason.
pub const Store = struct {
    gpa: Allocator,
    list: std.ArrayList(Comment) = .empty,
    /// Ids never repeat within a session, so a comment deleted and another added
    /// do not collide in `review-N.md`.
    next_id: u32 = 1,
    /// Set when anything changed since the last save, so an idle pane does no
    /// filesystem work.
    dirty: bool = false,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.list.items) |n| n.deinit(self.gpa);
        self.list.deinit(self.gpa);
    }

    pub fn items(self: *const Store) []const Comment {
        return self.list.items;
    }

    pub fn len(self: *const Store) usize {
        return self.list.items.len;
    }

    /// Copies both strings: the caller's `path` is a slice of the diff arena
    /// and its `body` is a slice of the compose box's fixed buffer, and
    /// neither outlives the next keystroke (rule 4).
    pub fn add(self: *Store, path: []const u8, line: u32, body: []const u8) Allocator.Error!u32 {
        return self.addAnchored(path, line, body, "");
    }

    pub fn addAnchored(
        self: *Store,
        path: []const u8,
        line: u32,
        body: []const u8,
        anchor_text: []const u8,
    ) Allocator.Error!u32 {
        return self.addFull(path, line, body, anchor_text, false, 1);
    }

    pub fn addFull(
        self: *Store,
        path: []const u8,
        line: u32,
        body: []const u8,
        anchor_text: []const u8,
        about_removed: bool,
        span: u32,
    ) Allocator.Error!u32 {
        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        const b = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(b);
        const a = try self.gpa.dupe(u8, anchor_text);
        errdefer self.gpa.free(a);

        const id = self.next_id;
        try self.list.append(self.gpa, .{ .id = id, .path = p, .line = line, .span = @max(span, 1), .body = b, .anchor = a, .about_removed = about_removed });
        self.next_id += 1;
        self.dirty = true;
        return id;
    }

    /// One remark already on the request, as the forge describes it. A struct
    /// rather than ten positional arguments, which is what this had grown to.
    pub const Remote = struct {
        path: []const u8,
        line: u32,
        span: u32 = 1,
        body: []const u8,
        author: []const u8,
        outdated: bool = false,
        remote: u64 = 0,
        reply_to: u64 = 0,
        created: i64 = 0,
        hunk: []const u8 = "",
    };

    /// Takes in a remark somebody else left on the request.
    ///
    /// Posted by definition, so `:post` never sends it back; stale when the
    /// forge says the line it was written against has gone, which is the same
    /// fact under the same name.
    pub fn adopt(self: *Store, r: Remote) Allocator.Error!u32 {
        const id = try self.addFull(r.path, r.line, r.body, "", false, r.span);
        const n = self.find(id).?;
        n.author = try self.gpa.dupe(u8, r.author);
        n.hunk = if (r.hunk.len > 0) try self.gpa.dupe(u8, r.hunk) else "";
        n.posted = true;
        n.remote = r.remote;
        n.reply_to = r.reply_to;
        n.created = r.created;
        if (r.outdated) n.state = .stale;
        return id;
    }

    /// Drops this checkout's copy of a remark the forge now holds.
    ///
    /// Posting leaves two of it: the one written here and the one that comes
    /// back with the request. Only the second can be edited - it is the one
    /// with an id the forge answers to - so the first is what goes. `follow`
    /// is moved onto the survivor, so a selection is not left pointing at a
    /// remark that is gone.
    pub fn dropPostedDuplicates(self: *Store, login: []const u8, follow: ?*u32) usize {
        var dropped: usize = 0;
        var i: usize = 0;
        while (i < self.list.items.len) {
            const n = self.list.items[i];
            if (!n.posted or n.theirs()) {
                i += 1;
                continue;
            }
            const twin = self.remoteTwin(n, login) orelse {
                i += 1;
                continue;
            };
            if (follow) |sel| {
                if (sel.* == n.id) sel.* = twin;
            }
            self.list.items[i].deinit(self.gpa);
            _ = self.list.orderedRemove(i);
            self.dirty = true;
            dropped += 1;
        }
        return dropped;
    }

    /// The forge's copy of a remark written here: same place, same words, and
    /// the reader's own name on it where the login is known.
    fn remoteTwin(self: *Store, n: Comment, login: []const u8) ?u32 {
        for (self.list.items) |o| {
            if (!o.theirs() or o.id == n.id) continue;
            if (o.line != n.line or !std.mem.eql(u8, o.path, n.path)) continue;
            if (!std.mem.eql(u8, o.body, n.body)) continue;
            if (login.len > 0 and !std.mem.eql(u8, o.author, login)) continue;
            return o.id;
        }
        return null;
    }

    /// Forgets every remark that came from the forge, so a fresh read of the
    /// request replaces them rather than doubling them.
    pub fn dropTheirs(self: *Store) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (!self.list.items[i].theirs()) {
                i += 1;
                continue;
            }
            self.list.items[i].deinit(self.gpa);
            _ = self.list.orderedRemove(i);
        }
    }

    pub fn find(self: *Store, id: u32) ?*Comment {
        for (self.list.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// The remark the forge calls `id`, when this checkout holds a copy. A
    /// thread is keyed on the forge's id throughout - `reply_to`, `thread()`
    /// and the replies endpoint - and the store's means nothing outside this
    /// process.
    pub fn findRemote(self: *Store, id: u64) ?*Comment {
        if (id == 0) return null;
        for (self.list.items) |*n| {
            if (n.remote == id) return n;
        }
        return null;
    }

    /// The comment on a line, if there is one. First match wins: two comments on one
    /// line is possible and the gutter can only mark it once.
    pub fn at(self: *Store, path: []const u8, line: u32) ?*Comment {
        for (self.list.items) |*n| {
            if (n.line == line and std.mem.eql(u8, n.path, path)) return n;
        }
        return null;
    }

    /// Every comment on a line, in store order, written into `buf`.
    ///
    /// `at` cannot be this: its first-match contract is what the gutter and
    /// the anchor lookups want. A caller's buffer rather than an allocation,
    /// because this is asked on a keystroke and the count is small; what does
    /// not fit is dropped.
    pub fn allAt(self: *Store, path: []const u8, line: u32, buf: []*Comment) []*Comment {
        var n: usize = 0;
        for (self.list.items) |*c| {
            if (n == buf.len) break;
            if (c.line != line or !std.mem.eql(u8, c.path, path)) continue;
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
    }

    /// Every remark in the conversation at a line: the ones sitting on it and
    /// the rest of any thread one of those belongs to, in store order.
    ///
    /// The union of the two, because a thread's later messages can land on a
    /// different line once the code moves, and a remark written in this pane
    /// belongs to no thread at all.
    pub fn conversationAt(self: *Store, path: []const u8, line: u32, buf: []*Comment) []*Comment {
        // Gathered first so the pass below stays in store order: appending
        // stragglers after would put a reply above what it answers.
        var threads: [16]u64 = undefined;
        var tn: usize = 0;
        for (self.list.items) |*c| {
            if (c.line != line or !std.mem.eql(u8, c.path, path)) continue;
            const t = c.thread();
            if (t == 0 or tn == threads.len) continue;
            if (std.mem.indexOfScalar(u64, threads[0..tn], t) != null) continue;
            threads[tn] = t;
            tn += 1;
        }

        var n: usize = 0;
        for (self.list.items) |*c| {
            if (n == buf.len) break;
            const here = c.line == line and std.mem.eql(u8, c.path, path);
            const t = c.thread();
            const joined = t != 0 and std.mem.indexOfScalar(u64, threads[0..tn], t) != null;
            if (!here and !joined) continue;
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
    }

    /// How many more messages follow `n` in its conversation on its own line,
    /// or null when an earlier message leads it there.
    ///
    /// Per line, unlike `conversationAt`: a reply re-anchors on its own once
    /// the code moves, and the diff draws each message where it actually
    /// sits. A remark written in this pane threads with nothing and leads.
    pub fn threadHead(self: *const Store, n: Comment) ?u16 {
        const t = n.thread();
        if (t == 0) return 0;
        var more: u16 = 0;
        var seen = false;
        for (self.list.items) |*c| {
            if (c.thread() != t) continue;
            if (c.line != n.line or !std.mem.eql(u8, c.path, n.path)) continue;
            if (c.id == n.id) {
                seen = true;
                continue;
            }
            if (!seen) return null;
            more += 1;
        }
        return more;
    }

    pub fn edit(self: *Store, id: u32, body: []const u8) Allocator.Error!void {
        const n = self.find(id) orelse return;
        const b = try self.gpa.dupe(u8, body);
        self.gpa.free(n.body);
        n.body = b;
        // Editing reopens: the text the agent was given is not this text.
        if (n.state == .sent) n.state = .open;
        self.dirty = true;
    }

    pub fn remove(self: *Store, id: u32) void {
        for (self.list.items, 0..) |n, i| {
            if (n.id != id) continue;
            n.deinit(self.gpa);
            _ = self.list.orderedRemove(i);
            self.dirty = true;
            return;
        }
    }

    /// Marks every open comment as sent. Called after a review file is written,
    /// because that is the moment the agent has them.
    /// Marks every comment `ids` names as handed to the forge.
    pub fn markPosted(self: *Store, ids: []const u32) void {
        for (self.list.items) |*n| {
            for (ids) |id| {
                if (n.id != id) continue;
                if (!n.posted) self.dirty = true;
                n.posted = true;
            }
        }
    }

    pub fn markSent(self: *Store) void {
        for (self.list.items) |*n| {
            if (n.state == .open) n.state = .sent;
        }
        self.dirty = true;
    }

    pub fn openCount(self: *const Store) u32 {
        var n: u32 = 0;
        for (self.list.items) |note| {
            if (note.state == .open) n += 1;
        }
        return n;
    }

    /// Re-places comments on `path` against a file that changed while lgtm was
    /// not running.
    ///
    /// `carry` is the good path and cannot be used here: it needs the previous
    /// version of the file, and after a restart there is none. What is left is
    /// the one line the comment was written against. If it is still where the
    /// comment says, nothing moves. If it is elsewhere in the file, the comment goes
    /// there. If it is nowhere, the comment is stale - never silently moved to a
    /// line that merely happens to have the right number (rule 7).
    pub fn reconcile(self: *Store, path: []const u8, text: []const u8) void {
        for (self.list.items) |*n| {
            if (n.state == .stale or n.anchor.len == 0) continue;
            if (!std.mem.eql(u8, n.path, path)) continue;

            var found: ?u32 = null;
            var no: u32 = 0;
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |raw| {
                no += 1;
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (!std.mem.eql(u8, line, n.anchor)) continue;
                // The nearest occurrence to where the comment thinks it is: a
                // line that appears twice should not drag the comment to the top
                // of the file.
                if (found == null or dist(no, n.line) < dist(found.?, n.line)) found = no;
            }
            if (found) |to| {
                if (to != n.line) self.dirty = true;
                n.line = to;
            } else {
                n.state = .stale;
                self.dirty = true;
            }
        }
    }

    /// Carries every comment on `path` from one version of the file to the next.
    ///
    /// The primary path is a line map, not a search, and
    /// `anchor.carryLine` is where that lives. A comment the ladder cannot place
    /// becomes stale rather than moving to a plausible-looking wrong line: a
    /// remark attached to the wrong code is a lie, and a stale one is merely
    /// out of date.
    pub fn carry(
        self: *Store,
        path: []const u8,
        from_text: []const u8,
        to_text: []const u8,
    ) Allocator.Error!void {
        for (self.list.items) |*n| {
            if (n.state == .stale) continue;
            if (!std.mem.eql(u8, n.path, path)) continue;
            // `carryLine` counts from zero; comments count from one, the way a
            // reader does and the way every reference the tool sends does.
            const from: u32 = if (n.line == 0) 0 else n.line - 1;
            if (try anchor.carryLine(self.gpa, from_text, to_text, from)) |to| {
                if (to + 1 != n.line) self.dirty = true;
                n.line = to + 1;
            } else {
                n.state = .stale;
                self.dirty = true;
            }
        }
    }
};

fn dist(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

// -- persistence -------------------------------------------------------------
//
// One comment per line, our own escaping rather than `std.json`: the fields are
// four scalars and a string, the project already hand-rolls its TOML reader
// for the same reason, and a format we own cannot break under a pre-1.0
// standard library.

/// Writes the store as jsonl. Order is the store's, so a file rewritten
/// without changes is byte-identical.
///
/// Somebody else's remarks are not written. They belong to the request, not to
/// this checkout, and a copy here would go stale the moment the author edited
/// one - or come back twice when the request is opened again.
pub fn write(out: *std.ArrayList(u8), gpa: Allocator, store: *const Store) Allocator.Error!void {
    for (store.items()) |n| {
        if (n.theirs()) continue;
        var num: [24]u8 = undefined;
        try out.appendSlice(gpa, "{\"id\":");
        try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n.id}) catch "0");
        try out.appendSlice(gpa, ",\"line\":");
        try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n.line}) catch "0");
        try out.appendSlice(gpa, ",\"state\":\"");
        try out.appendSlice(gpa, n.state.name());
        try out.appendSlice(gpa, "\",\"path\":");
        try quoteJson(out, gpa, n.path);
        if (n.about_removed) try out.appendSlice(gpa, ",\"removed\":true");
        if (n.span > 1) {
            try out.appendSlice(gpa, ",\"span\":");
            try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n.span}) catch "1");
        }
        if (n.posted) try out.appendSlice(gpa, ",\"posted\":true");
        try out.appendSlice(gpa, ",\"anchor\":");
        try quoteJson(out, gpa, n.anchor);
        try out.appendSlice(gpa, ",\"body\":");
        try quoteJson(out, gpa, n.body);
        try out.appendSlice(gpa, "}\n");
    }
}

/// Reads what `write` produced. A line that will not parse is skipped rather
/// than failing the load: one corrupt row must not cost the reader every note
/// they wrote.
pub fn read(store: *Store, text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const id = field(line, "\"id\":") orelse continue;
        const ln = field(line, "\"line\":") orelse continue;
        const path = string(line, "\"path\":") orelse continue;
        const body = string(line, "\"body\":") orelse continue;

        var buf_path: [4096]u8 = undefined;
        var buf_body: [8192]u8 = undefined;
        var buf_anchor: [4096]u8 = undefined;
        const p = unquote(&buf_path, path);
        const b = unquote(&buf_body, body);
        const a = if (string(line, "\"anchor\":")) |raw| unquote(&buf_anchor, raw) else "";

        const removed = std.mem.indexOf(u8, line, "\"removed\":true") != null;
        const new_id = try store.addFull(p, @intCast(ln), b, a, removed, 1);
        const n = store.find(new_id).?;
        n.id = @intCast(id);
        if (std.mem.indexOf(u8, line, "\"state\":\"sent\"") != null) n.state = .sent;
        if (std.mem.indexOf(u8, line, "\"state\":\"stale\"") != null) n.state = .stale;
        n.posted = std.mem.indexOf(u8, line, "\"posted\":true") != null;
        if (field(line, "\"span\":")) |sp| n.span = @max(1, @as(u32, @intCast(sp)));
        if (store.next_id <= n.id) store.next_id = n.id + 1;
    }
    store.dirty = false;
}

/// A JSON string literal. Shared with `core/gh.zig`, which builds a review
/// out of the same bytes this stores.
pub fn quoteJson(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (text) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

/// The raw, still-escaped bytes between the quotes after `key`.
fn string(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    if (i >= line.len or line[i] != '"') return null;
    i += 1;
    const from = i;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') return line[from..i];
    }
    return null;
}

fn unquote(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < buf.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            buf[n] = text[i];
            n += 1;
            continue;
        }
        i += 1;
        buf[n] = switch (text[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => text[i],
        };
        n += 1;
    }
    return buf[0..n];
}

fn field(line: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    var v: u64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

const testing = std.testing;

test "a comment owns its bytes, so the diff arena may go" {
    // Hard rule 4, stated as the test that would catch breaking it: the
    // strings handed in are freed, and the comment still reads correctly.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    const path = try arena.allocator().dupe(u8, "src/auth.zig");
    const body = try arena.allocator().dupe(u8, "this allocates on every request");

    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const id = try store.add(path, 47, body);

    arena.deinit();

    const n = store.find(id).?;
    try testing.expectEqualStrings("src/auth.zig", n.path);
    try testing.expectEqualStrings("this allocates on every request", n.body);
}

test "a comment follows its line when the agent rewrites the file" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 3, "why b and not a?");

    const before =
        \\fn alpha() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    return a + b;
        \\}
        \\
    ;
    // Two lines added at the top: the comment's line moves from 3 to 5.
    const after =
        \\const std = @import("std");
        \\
        \\fn alpha() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    return a + b;
        \\}
        \\
    ;
    try store.carry("a.zig", before, after);
    try testing.expectEqual(@as(u32, 5), store.items()[0].line);
    try testing.expectEqual(State.open, store.items()[0].state);
}

test "a comment that cannot be placed goes stale rather than moving somewhere wrong" {
    // Hard rule 7. A remark attached to the wrong code is a lie; one marked
    // stale is merely out of date, and the reader decides what to do with it.
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("a.zig", 2, "this branch is dead");

    const before =
        \\fn alpha() void {
        \\    if (never()) unreachable;
        \\}
        \\
    ;
    const after =
        \\fn completely() void {
        \\}
        \\
    ;
    try store.carry("a.zig", before, after);
    try testing.expectEqual(State.stale, store.items()[0].state);
    // Still there. Never dropped.
    try testing.expectEqual(@as(usize, 1), store.len());
    try testing.expectEqualStrings("this branch is dead", store.items()[0].body);
}

test "a comment finds its line again after a restart, when the file moved" {
    // The gap `carry` cannot cover: lgtm was not running when the file
    // changed, so there is no previous version to diff. One line of stored
    // text is what is left, and it is enough.
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.addAnchored("a.zig", 2, "why not a set?", "    const list = init();");

    const now =
        \\const std = @import("std");
        \\
        \\fn a() void {
        \\    const list = init();
        \\}
        \\
    ;
    store.reconcile("a.zig", now);
    try testing.expectEqual(@as(u32, 4), store.items()[0].line);
    try testing.expectEqual(State.open, store.items()[0].state);
}

test "a comment whose line is gone after a restart goes stale, not somewhere wrong" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.addAnchored("a.zig", 2, "dead branch", "    if (never()) unreachable;");

    store.reconcile("a.zig", "fn a() void {\n}\n");
    try testing.expectEqual(State.stale, store.items()[0].state);
    try testing.expectEqual(@as(usize, 1), store.len());
}

test "a line that appears twice takes the nearest one" {
    // Otherwise a comment on the second `}` of a file jumps to the first.
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.addAnchored("a.zig", 6, "this one", "}");

    store.reconcile("a.zig", "fn a() void {\n}\nfn b() void {\n}\nfn c() void {\n}\n");
    try testing.expectEqual(@as(u32, 6), store.items()[0].line);
}

test "comments survive a round trip through the file, newlines and quotes included" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.addAnchored("src/a.zig", 12, "why \"this\" way?\nand not the other", "    const x = 1;");
    _ = try store.add("src/b.zig", 3, "back\\slash");
    store.markSent();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try write(&out, testing.allocator, &store);

    var back: Store = .init(testing.allocator);
    defer back.deinit();
    try read(&back, out.items);

    try testing.expectEqual(@as(usize, 2), back.len());
    try testing.expectEqualStrings("why \"this\" way?\nand not the other", back.items()[0].body);
    try testing.expectEqualStrings("src/a.zig", back.items()[0].path);
    try testing.expectEqual(@as(u32, 12), back.items()[0].line);
    try testing.expectEqual(State.sent, back.items()[0].state);
    try testing.expectEqualStrings("back\\slash", back.items()[1].body);
    // The anchor line rides along, or a restart has nothing to place it with.
    try testing.expectEqualStrings("    const x = 1;", back.items()[0].anchor);

    // Ids are preserved, and the next one does not collide with them.
    try testing.expectEqual(store.items()[1].id, back.items()[1].id);
    try testing.expect(back.next_id > back.items()[1].id);
}

test "a corrupt line costs one comment, not all of them" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    try read(&store,
        \\{"id":1,"line":4,"state":"open","path":"a.zig","body":"first"}
        \\this line is not a comment
        \\{"id":2,"line":9,"state":"open","path":"b.zig","body":"second"}
        \\
    );
    try testing.expectEqual(@as(usize, 2), store.len());
    try testing.expectEqualStrings("second", store.items()[1].body);
}

test "editing reopens a sent comment, because the agent has the old text" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const id = try store.add("a.zig", 1, "first thought");
    store.markSent();
    try testing.expectEqual(State.sent, store.find(id).?.state);

    try store.edit(id, "second thought");
    try testing.expectEqual(State.open, store.find(id).?.state);
    try testing.expectEqualStrings("second thought", store.find(id).?.body);
    try testing.expectEqual(@as(u32, 1), store.openCount());
}

test "a conversation on a line has one head, and it counts the rest" {
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    const root = try store.adopt(.{ .path = "docs/CONFIG.md", .line = 26, .body = "that's nice", .author = "someone", .remote = 10 });
    const reply = try store.adopt(.{ .path = "docs/CONFIG.md", .line = 26, .body = "fixed", .author = "kunkka19xx", .remote = 11, .reply_to = 10 });
    const later = try store.adopt(.{ .path = "docs/CONFIG.md", .line = 26, .body = "thanks", .author = "someone", .remote = 12, .reply_to = 10 });

    try testing.expectEqual(@as(?u16, 2), store.threadHead(store.find(root).?.*));
    try testing.expectEqual(@as(?u16, null), store.threadHead(store.find(reply).?.*));
    try testing.expectEqual(@as(?u16, null), store.threadHead(store.find(later).?.*));
}

test "a reply that drifted to another line leads there" {
    // Collapsing across lines would take the reply off the line it sits on.
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    const root = try store.adopt(.{ .path = "a.zig", .line = 4, .body = "why this way?", .author = "someone", .remote = 10 });
    const moved = try store.adopt(.{ .path = "a.zig", .line = 9, .body = "because", .author = "someone", .remote = 11, .reply_to = 10 });

    try testing.expectEqual(@as(?u16, 0), store.threadHead(store.find(root).?.*));
    try testing.expectEqual(@as(?u16, 0), store.threadHead(store.find(moved).?.*));
}

test "two remarks written in this pane are two conversations" {
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    const a = try store.add("a.zig", 4, "one");
    const b = try store.add("a.zig", 4, "two");
    try testing.expectEqual(@as(?u16, 0), store.threadHead(store.find(a).?.*));
    try testing.expectEqual(@as(?u16, 0), store.threadHead(store.find(b).?.*));
}

test "the copy that was posted gives way to the forge's" {
    // Posting leaves two of the same remark on the line: this one, and the
    // one that comes back with the request carrying the id an edit needs.
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    const local = try store.add("a.zig", 26, "that retry never backs off");
    store.markPosted(&.{local});
    const unposted = try store.add("a.zig", 26, "and this one is still a draft");
    const theirs = try store.adopt(.{ .path = "a.zig", .line = 26, .body = "that retry never backs off", .author = "me", .remote = 4242 });
    _ = try store.adopt(.{ .path = "a.zig", .line = 40, .body = "somebody else's", .author = "someone", .remote = 4243 });

    var sel: u32 = local;
    try testing.expectEqual(@as(usize, 1), store.dropPostedDuplicates("me", &sel));
    // The selection followed the survivor rather than pointing at nothing.
    try testing.expectEqual(theirs, sel);
    try testing.expect(store.find(local) == null);
    // A draft that was never posted is nobody's duplicate.
    try testing.expect(store.find(unposted) != null);

    // Same words, somebody else's name: not this checkout's copy coming back.
    var other: Store = .init(gpa);
    defer other.deinit();
    const ours = try other.add("a.zig", 26, "same words");
    other.markPosted(&.{ours});
    _ = try other.adopt(.{ .path = "a.zig", .line = 26, .body = "same words", .author = "someone", .remote = 7 });
    try testing.expectEqual(@as(usize, 0), other.dropPostedDuplicates("me", null));
}

test "every remark on a line is reachable, not only the first" {
    // `at` answers with whichever the forge listed first, which is the wrong
    // one half the time and the only one either way.
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();
    _ = try store.adopt(.{ .path = "a.zig", .line = 26, .span = 1, .body = "that's nice", .author = "someone", .outdated = false, .remote = 4242 });
    const mine = try store.add("a.zig", 26, "fixed in the follow-up");
    _ = try store.add("a.zig", 40, "elsewhere");

    var buf: [8]*Comment = undefined;
    const on = store.allAt("a.zig", 26, &buf);
    try testing.expectEqual(@as(usize, 2), on.len);
    try testing.expectEqualStrings("that's nice", on[0].body);
    try testing.expectEqual(mine, on[1].id);

    // The first-match contract stays what it was.
    try testing.expectEqualStrings("that's nice", store.at("a.zig", 26).?.body);
    try testing.expectEqual(@as(usize, 0), store.allAt("b.zig", 26, &buf).len);

    // A buffer too small takes what fits rather than reading past its end.
    var one: [1]*Comment = undefined;
    try testing.expectEqual(@as(usize, 1), store.allAt("a.zig", 26, &one).len);
}

test "a conversation is the line's remarks and the rest of their threads" {
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    // A thread of three whose last reply landed elsewhere, an unrelated
    // remark on the same line, and one somewhere else entirely.
    _ = try store.adopt(.{ .path = "a.zig", .line = 26, .body = "root", .author = "someone", .remote = 10 });
    _ = try store.adopt(.{ .path = "a.zig", .line = 26, .body = "reply", .author = "other", .remote = 11, .reply_to = 10 });
    _ = try store.adopt(.{ .path = "a.zig", .line = 31, .body = "late reply", .author = "me", .remote = 12, .reply_to = 10 });
    const mine = try store.add("a.zig", 26, "mine, unrelated");
    _ = try store.add("a.zig", 40, "elsewhere");

    var buf: [16]*Comment = undefined;
    const on = store.conversationAt("a.zig", 26, &buf);
    try testing.expectEqual(@as(usize, 4), on.len);
    // Store order throughout, so a reply never floats above what it answers.
    try testing.expectEqualStrings("root", on[0].body);
    try testing.expectEqualStrings("reply", on[1].body);
    try testing.expectEqualStrings("late reply", on[2].body);
    try testing.expectEqual(mine, on[3].id);

    // From the straggler's line the thread comes back whole, without the
    // unrelated remark sharing the root's line.
    const from_31 = store.conversationAt("a.zig", 31, &buf);
    try testing.expectEqual(@as(usize, 3), from_31.len);
    try testing.expectEqualStrings("root", from_31[0].body);

    // A remark written in this pane belongs to no thread, so a line carrying
    // only one is a conversation of one rather than of every local remark.
    try testing.expectEqual(@as(usize, 1), store.conversationAt("a.zig", 40, &buf).len);
    try testing.expectEqual(@as(usize, 0), store.conversationAt("b.zig", 40, &buf).len);
}

test "somebody else's remark is theirs and stays theirs" {
    const gpa = testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();

    const mine = try store.add("a.zig", 10, "I would rename this");
    const theirs = try store.adopt(.{ .path = "a.zig", .line = 47, .span = 3, .body = "this retry never backs off", .author = "kunkka19xx", .outdated = false, .remote = 4242 });
    const gone = try store.adopt(.{ .path = "b.zig", .line = 12, .span = 1, .body = "the line this was on has moved", .author = "someone", .outdated = true, .remote = 4243 });

    // Posted by definition, so a review never sends it back to its author.
    try testing.expect(store.find(theirs).?.posted);
    try testing.expect(store.find(theirs).?.theirs());
    try testing.expect(!store.find(mine).?.theirs());
    // The forge saying `null` for the line is the same fact `stale` records.
    try testing.expectEqual(State.stale, store.find(gone).?.state);
    try testing.expectEqual(@as(u32, 49), store.find(theirs).?.end());

    // Not written to `.lgtm/`: the request is where they live, and a copy
    // here would go stale the moment the author edited one.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(&out, gpa, &store);
    try testing.expect(std.mem.indexOf(u8, out.items, "I would rename this") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "never backs off") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "kunkka19xx") == null);

    // Reading the request again replaces them rather than doubling them.
    store.dropTheirs();
    try testing.expectEqual(@as(usize, 1), store.len());
    try testing.expect(store.find(mine) != null);

    // And reading back gets only the reader's own, so opening the request
    // again cannot come back with two of everything.
    var back: Store = .init(gpa);
    defer back.deinit();
    try read(&back, out.items);
    try testing.expectEqual(@as(usize, 1), back.len());
}
