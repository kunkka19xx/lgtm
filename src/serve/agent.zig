// SPDX-License-Identifier: Apache-2.0
//
// The agent's side of `lgtm serve`: what this backend can do, and its screen.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bridge = @import("../bridge/bridge.zig");
const tmux = @import("../bridge/tmux.zig");
const wire = @import("wire.zig");

/// `status` is whether a watcher is running for this pane.
pub fn caps(br: *const bridge.Bridge, pane: []const u8, status: bool) wire.Agent {
    const readable = br.readable();
    return .{
        .backend = br.name(),
        .pane = pane,
        .read = readable,
        .submit = readable,
        .stream = false,
        .status = status,
        .why = switch (br.*) {
            .tmux, .herdr, .wezterm, .kitty => "",
            .ghostty => "ghostty cannot be read; run the agent inside tmux, herdr, wezterm or kitty",
            .osc52 => "no multiplexer to reach the agent through",
        },
    };
}

/// What the pane is running, where the backend can say. Null when it cannot.
pub fn command(gpa: Allocator, arena: Allocator, io: std.Io, br: *const bridge.Bridge, pane: []const u8) ?[]const u8 {
    if (br.* != .tmux) return null;
    const listed = tmux.list(gpa, arena, io, true) catch return null;
    for (listed) |p| {
        if (std.mem.eql(u8, p.id, pane)) return p.command;
    }
    return null;
}

pub const Screen = struct {
    hash: u64 = 0,
    seen: bool = false,

    pub const Error = error{PaneGone} || Allocator.Error;

    /// Rows, in `arena`, when the screen changed since the last call; else null.
    pub fn poll(self: *Screen, br: *bridge.Bridge, cx: bridge.Ctx, arena: Allocator, pane: []const u8) Error!?[]const []const u8 {
        const text = br.read(cx, arena, pane) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PaneGone, error.Failed => error.PaneGone,
        };
        return self.changed(arena, text);
    }

    fn changed(self: *Screen, arena: Allocator, text: []const u8) Allocator.Error!?[]const []const u8 {
        const h = std.hash.Wyhash.hash(0, text);
        if (self.seen and h == self.hash) return null;
        self.seen = true;
        self.hash = h;
        var rows: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |row| try rows.append(arena, std.mem.trimEnd(u8, row, "\r"));
        return try rows.toOwnedSlice(arena);
    }
};

/// Capture interval: fast while the screen moves, backing off while it is still.
pub const Pacer = struct {
    pub const fastest: u32 = 150;
    pub const slowest: u32 = 2000;

    wait: u32 = fastest,

    pub fn after(self: *Pacer, moved: bool) u32 {
        self.wait = if (moved) fastest else @min(self.wait * 2, slowest);
        return self.wait;
    }

    pub fn wake(self: *Pacer) void {
        self.wait = fastest;
    }
};

const testing = std.testing;

test "a screen is sent once, then only when it changes, without its closing newline" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var s: Screen = .{};

    const first = (try s.changed(arena, "> hi\r\n● thinking\n")).?;
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualStrings("> hi", first[0]);
    try testing.expect(try s.changed(arena, "> hi\r\n● thinking\n") == null);
    try testing.expect(try s.changed(arena, "> hi\r\n● done") != null);

    var empty: Screen = .{};
    try testing.expect(try empty.changed(arena, "") != null);
    try testing.expect(try empty.changed(arena, "") == null);
}

test "polling backs off while nothing moves and snaps back when it does" {
    var p: Pacer = .{};
    for ([_]u32{ 300, 600, 1200, Pacer.slowest, Pacer.slowest }) |want| try testing.expectEqual(want, p.after(false));
    try testing.expectEqual(Pacer.fastest, p.after(true));
    _ = p.after(false);
    p.wake();
    try testing.expectEqual(Pacer.fastest, p.wait);
}

test "four backends can be read and submitted to, and ghostty says why not" {
    for ([_]bridge.Bridge{ .{ .tmux = .{} }, .{ .herdr = .{} }, .{ .wezterm = .{} }, .{ .kitty = .{} } }) |b| {
        const c = caps(&b, "1", false);
        try testing.expect(c.read and c.submit and !c.status and c.why.len == 0);
    }
    const g: bridge.Bridge = .{ .ghostty = .{} };
    const gc = caps(&g, "", false);
    try testing.expect(!gc.read and !gc.submit and gc.why.len > 0);
    const h: bridge.Bridge = .{ .herdr = .{} };
    try testing.expect(caps(&h, "w1:p1", true).status);
}
