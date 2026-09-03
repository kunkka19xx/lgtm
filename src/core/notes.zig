// SPDX-License-Identifier: Apache-2.0
//
// Review notes: the remarks collected while reading, and the machinery that
// keeps them pointing at the right line while the agent rewrites the file
// underneath them.
//
// The whole feature rests on `core/anchor.zig`, which is why that was built
// first and gated on its own (PLAN.md phase 1): a note that drifts to the
// wrong line is worse than no note at all, and finding that out with 300 lines
// of anchoring was far cheaper than with a note UI attached. It passed at 100%
// across the fixture set, so this file can be written as if re-anchoring works
// - and handle the case where it does not by saying so rather than guessing.
//
// Two hard rules govern everything here:
//
//   - **Notes own their bytes** (rule 4). They outlive the diff arena, which
//     is reset on every re-diff, so `path` and `body` are copies taken from
//     the session allocator. A note holding a slice into the arena would read
//     as plausible garbage one re-diff later.
//   - **A note is never silently dropped** (rule 7). One that cannot be
//     re-anchored becomes `stale` and stays visible, because the reader wrote
//     it and only the reader gets to decide it no longer matters.
//
// `core/`, so no UI and no terminal: notes in, notes out, and a store that can
// be driven entirely from a test.

const std = @import("std");
const Allocator = std.mem.Allocator;

const anchor = @import("anchor.zig");

/// Where a note is in its life.
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

pub const Note = struct {
    id: u32,
    /// Path as the review knows it: the new file's, or the old one's for a
    /// deletion. Owned.
    path: []const u8,
    /// 1-based line in the working tree. Carried forward on every re-diff.
    line: u32,
    /// What the reader wrote. Owned, and may contain newlines - it is written
    /// to a file, not sent through `send-keys` (hard rule 1 is about the
    /// bridge, and `review.zig` sends one line naming the file).
    body: []const u8,
    state: State = .open,

    pub fn deinit(self: Note, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.body);
    }
};

/// Every note in the session, in the order they were written.
///
/// Order is insertion order rather than by file and line: `]c` walks them the
/// way the review is laid out, and this list is what persists. Sorting on
/// write would make the file churn for no reason.
pub const Store = struct {
    gpa: Allocator,
    list: std.ArrayList(Note) = .empty,
    /// Ids never repeat within a session, so a note deleted and another added
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

    pub fn items(self: *const Store) []const Note {
        return self.list.items;
    }

    pub fn len(self: *const Store) usize {
        return self.list.items.len;
    }

    /// Copies both strings: the caller's `path` is a slice of the diff arena
    /// and its `body` is a slice of the compose box's fixed buffer, and
    /// neither outlives the next keystroke (rule 4).
    pub fn add(self: *Store, path: []const u8, line: u32, body: []const u8) Allocator.Error!u32 {
        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        const b = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(b);

        const id = self.next_id;
        try self.list.append(self.gpa, .{ .id = id, .path = p, .line = line, .body = b });
        self.next_id += 1;
        self.dirty = true;
        return id;
    }

    pub fn find(self: *Store, id: u32) ?*Note {
        for (self.list.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// The note on a line, if there is one. First match wins: two notes on one
    /// line is possible and the gutter can only mark it once.
    pub fn at(self: *Store, path: []const u8, line: u32) ?*Note {
        for (self.list.items) |*n| {
            if (n.line == line and std.mem.eql(u8, n.path, path)) return n;
        }
        return null;
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

    /// Marks every open note as sent. Called after a review file is written,
    /// because that is the moment the agent has them.
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

    /// Carries every note on `path` from one version of the file to the next.
    ///
    /// The primary path is a line map, not a search (PERFORMANCE.md 3.1), and
    /// `anchor.carryLine` is where that lives. A note the ladder cannot place
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
            // `carryLine` counts from zero; notes count from one, the way a
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

// -- persistence -------------------------------------------------------------
//
// One note per line, our own escaping rather than `std.json`: the fields are
// four scalars and a string, the project already hand-rolls its TOML reader
// for the same reason, and a format we own cannot break under a pre-1.0
// standard library.

/// Writes the store as jsonl. Order is the store's, so a file rewritten
/// without changes is byte-identical.
pub fn write(out: *std.ArrayList(u8), gpa: Allocator, store: *const Store) Allocator.Error!void {
    for (store.items()) |n| {
        var num: [24]u8 = undefined;
        try out.appendSlice(gpa, "{\"id\":");
        try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n.id}) catch "0");
        try out.appendSlice(gpa, ",\"line\":");
        try out.appendSlice(gpa, std.fmt.bufPrint(&num, "{d}", .{n.line}) catch "0");
        try out.appendSlice(gpa, ",\"state\":\"");
        try out.appendSlice(gpa, n.state.name());
        try out.appendSlice(gpa, "\",\"path\":");
        try quote(out, gpa, n.path);
        try out.appendSlice(gpa, ",\"body\":");
        try quote(out, gpa, n.body);
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
        const p = unquote(&buf_path, path);
        const b = unquote(&buf_body, body);

        const new_id = try store.add(p, @intCast(ln), b);
        const n = store.find(new_id).?;
        n.id = @intCast(id);
        if (std.mem.indexOf(u8, line, "\"state\":\"sent\"") != null) n.state = .sent;
        if (std.mem.indexOf(u8, line, "\"state\":\"stale\"") != null) n.state = .stale;
        if (store.next_id <= n.id) store.next_id = n.id + 1;
    }
    store.dirty = false;
}

fn quote(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8) Allocator.Error!void {
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

test "a note owns its bytes, so the diff arena may go" {
    // Hard rule 4, stated as the test that would catch breaking it: the
    // strings handed in are freed, and the note still reads correctly.
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

test "a note follows its line when the agent rewrites the file" {
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
    // Two lines added at the top: the note's line moves from 3 to 5.
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

test "a note that cannot be placed goes stale rather than moving somewhere wrong" {
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

test "notes survive a round trip through the file, newlines and quotes included" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    _ = try store.add("src/a.zig", 12, "why \"this\" way?\nand not the other");
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

    // Ids are preserved, and the next one does not collide with them.
    try testing.expectEqual(store.items()[1].id, back.items()[1].id);
    try testing.expect(back.next_id > back.items()[1].id);
}

test "a corrupt line costs one note, not all of them" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    try read(&store,
        \\{"id":1,"line":4,"state":"open","path":"a.zig","body":"first"}
        \\this line is not a note
        \\{"id":2,"line":9,"state":"open","path":"b.zig","body":"second"}
        \\
    );
    try testing.expectEqual(@as(usize, 2), store.len());
    try testing.expectEqualStrings("second", store.items()[1].body);
}

test "editing reopens a sent note, because the agent has the old text" {
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
