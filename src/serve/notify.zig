// SPDX-License-Identifier: Apache-2.0
//
// A POST to `[notify] url` when nobody is watching, which ntfy or Bark turn into a push.

const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("../io/proc.zig");
const wire = @import("wire.zig");

/// A screen still this long after moving is an agent that stopped.
pub const quiet_ms: i64 = 20_000;
/// At most one push in this long, so a flapping agent does not buzz a pocket.
pub const spacing_ms: i64 = 30_000;

pub const Quiet = struct {
    hash: u64 = 0,
    seen: bool = false,
    moving: bool = false,
    settled: bool = false,
    moved_at: i64 = 0,

    /// True once, when the screen has been still for `quiet_ms` after moving.
    pub fn screen(self: *Quiet, hash: u64, now: i64) bool {
        if (!self.seen or hash != self.hash) {
            self.moving = self.seen;
            self.settled = self.settled and !self.moving;
            self.seen = true;
            self.hash = hash;
            self.moved_at = now;
            return false;
        }
        if (!self.moving or now - self.moved_at < quiet_ms) return false;
        self.moving = false;
        self.settled = true;
        return true;
    }

    /// Working while the screen moves, idle once it went still after moving.
    pub fn state(self: *const Quiet) wire.AgentState {
        return if (self.moving) .working else if (self.settled) .idle else .unknown;
    }
};

pub const Event = enum { waiting, finished, quiet };

/// A status change worth a push: blocked, or done after working.
pub fn forStatus(before: wire.AgentState, now: wire.AgentState) ?Event {
    if (now == before) return null;
    return switch (now) {
        .blocked => .waiting,
        .done, .idle => if (before == .working) .finished else null,
        else => null,
    };
}

pub fn message(buf: []u8, what: Event, agent: []const u8, repo: []const u8) []const u8 {
    const who = if (agent.len > 0) agent else "the agent";
    return switch (what) {
        .waiting => std.fmt.bufPrint(buf, "{s} is waiting for you in {s}", .{ who, repo }),
        .finished => std.fmt.bufPrint(buf, "{s} finished in {s}", .{ who, repo }),
        .quiet => std.fmt.bufPrint(buf, "{s} went quiet in {s}", .{ who, repo }),
    } catch "the agent needs you";
}

pub fn post(gpa: Allocator, io: std.Io, url: []const u8, text: []const u8) bool {
    const out = proc.run(gpa, io, &.{ "curl", "-fsS", "-m", "10", "-H", "Title: lgtm", "-d", text, url }, 4 << 10) catch return false;
    defer out.deinit(gpa);
    return out.exit_code == 0;
}

const testing = std.testing;

test "a screen is quiet once, after it moved and then held still" {
    var q: Quiet = .{};
    try testing.expect(!q.screen(1, 0));
    try testing.expect(!q.screen(1, quiet_ms * 2)); // never moved
    try testing.expect(!q.screen(2, 100_000));
    try testing.expect(!q.screen(2, 100_000 + quiet_ms - 1));
    try testing.expect(q.screen(2, 100_000 + quiet_ms));
    try testing.expect(!q.screen(2, 200_000)); // already told
    try testing.expect(!q.screen(3, 210_000));
    try testing.expect(q.screen(3, 210_000 + quiet_ms));
}

test "a screen reads as working while it moves and idle once it settled" {
    var q: Quiet = .{};
    _ = q.screen(1, 0);
    try testing.expectEqual(wire.AgentState.unknown, q.state());
    _ = q.screen(2, 1000);
    try testing.expectEqual(wire.AgentState.working, q.state());
    _ = q.screen(2, 1000 + quiet_ms);
    try testing.expectEqual(wire.AgentState.idle, q.state());
    _ = q.screen(3, 100_000);
    try testing.expectEqual(wire.AgentState.working, q.state());
}

test "blocked is always news, and finishing only after working" {
    try testing.expectEqual(Event.waiting, forStatus(.working, .blocked).?);
    try testing.expectEqual(Event.waiting, forStatus(.idle, .blocked).?);
    try testing.expectEqual(Event.finished, forStatus(.working, .done).?);
    try testing.expectEqual(Event.finished, forStatus(.working, .idle).?);
    try testing.expect(forStatus(.unknown, .idle) == null);
    try testing.expect(forStatus(.blocked, .blocked) == null);
    try testing.expect(forStatus(.idle, .working) == null);
}
