// SPDX-License-Identifier: Apache-2.0
//
// The watched pane's screen: sent when it changed, captured faster while it moves.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Screen = struct {
    hash: u64 = 0,
    seen: bool = false,

    /// Rows, in `arena`, when the screen changed since the last call; else null.
    pub fn changed(self: *Screen, arena: Allocator, text: []const u8) Allocator.Error!?[]const []const u8 {
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
