// SPDX-License-Identifier: Apache-2.0
//
// What herdr says the agent is doing, pushed over herdr's own socket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const net = @import("../io/net.zig");
const wire = @import("wire.zig");

pub const State = wire.AgentState;

pub const Update = struct { state: State, agent: []const u8 };

/// The answer to `pane.get` or a `pane.agent_status_changed` event for `pane`;
/// null for any other line. Strings point into `arena`.
pub fn parse(arena: Allocator, line: []const u8, pane: []const u8) ?Update {
    const Info = struct { pane_id: ?[]const u8 = null, agent_status: ?[]const u8 = null, agent: ?[]const u8 = null };
    const Line = struct {
        event: ?[]const u8 = null,
        data: ?Info = null,
        result: ?struct { pane: ?Info = null } = null,
    };
    const l = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    const info = if (l.event) |e|
        (if (std.mem.eql(u8, e, "pane.agent_status_changed")) l.data else null)
    else if (l.result) |r| r.pane else null;
    const i = info orelse return null;
    if (i.pane_id) |id| if (!std.mem.eql(u8, id, pane)) return null;
    const raw = i.agent_status orelse return null;
    return .{ .state = std.meta.stringToEnum(State, raw) orelse .unknown, .agent = i.agent orelse "" };
}

/// Holds the latest state for the serving thread, which sends it on when `seq`
/// moves. Reconnects on its own; herdr restarting is not fatal.
pub const Watch = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    pane: []const u8,
    mutex: Io.Mutex = .init,
    state: State = .unknown,
    agent_buf: [64]u8 = undefined,
    agent_len: usize = 0,
    seq: u32 = 0,

    pub const Snapshot = struct { state: State, agent: []const u8, seq: u32 };

    pub fn start(self: *Watch) !void {
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
    }

    /// `agent` is copied into `buf`, so the snapshot outlives the lock.
    pub fn snapshot(self: *Watch, buf: *[64]u8) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memcpy(buf[0..self.agent_len], self.agent_buf[0..self.agent_len]);
        return .{ .state = self.state, .agent = buf[0..self.agent_len], .seq = self.seq };
    }

    fn set(self: *Watch, u: Update) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(u.agent.len, self.agent_buf.len);
        if (u.state == self.state and std.mem.eql(u8, self.agent_buf[0..self.agent_len], u.agent[0..n])) return;
        self.state = u.state;
        @memcpy(self.agent_buf[0..n], u.agent[0..n]);
        self.agent_len = n;
        self.seq +%= 1;
    }

    fn run(self: *Watch) void {
        while (true) {
            self.once() catch {};
            self.io.sleep(.fromSeconds(2), .awake) catch return;
        }
    }

    /// herdr closes a connection that sends anything after `events.subscribe`,
    /// so the current state is asked for on a second one, after subscribing so
    /// that a change between the two is not missed.
    fn once(self: *Watch) !void {
        const sub = try net.connectUnix(self.io, self.path);
        defer sub.close(self.io);
        try self.request(sub, "{{\"id\":\"lgtm-sub\",\"method\":\"events.subscribe\",\"params\":{{\"subscriptions\":[{{\"type\":\"pane.agent_status_changed\",\"pane_id\":{f}}}]}}}}\n");

        const rbuf = try self.gpa.alloc(u8, 64 << 10);
        defer self.gpa.free(rbuf);
        var events = sub.reader(self.io, rbuf);
        _ = try events.interface.takeDelimiter('\n');

        self.ask() catch {};
        while (try events.interface.takeDelimiter('\n')) |line| self.take(line);
    }

    fn ask(self: *Watch) !void {
        const get = try net.connectUnix(self.io, self.path);
        defer get.close(self.io);
        try self.request(get, "{{\"id\":\"lgtm-get\",\"method\":\"pane.get\",\"params\":{{\"pane_id\":{f}}}}}\n");
        var buf: [16 << 10]u8 = undefined;
        var r = get.reader(self.io, &buf);
        if (try r.interface.takeDelimiter('\n')) |line| self.take(line);
    }

    fn request(self: *Watch, conn: net.Conn, comptime fmt: []const u8) !void {
        var wbuf: [512]u8 = undefined;
        var cw = conn.writer(self.io, &wbuf);
        try cw.interface.print(fmt, .{std.json.fmt(self.pane, .{})});
        try cw.interface.flush();
    }

    fn take(self: *Watch, line: []const u8) void {
        var a: std.heap.ArenaAllocator = .init(self.gpa);
        defer a.deinit();
        if (parse(a.allocator(), line, self.pane)) |u| self.set(u);
    }
};

const testing = std.testing;

test "herdr's status lines parse as herdr 0.9.1 sends them, and nothing else does" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const event = parse(arena,
        \\{"data":{"agent":"claude","agent_status":"blocked","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}
    , "w1:p1").?;
    try testing.expect(event.state == .blocked and std.mem.eql(u8, event.agent, "claude"));
    const get = parse(arena,
        \\{"id":"lgtm-get","result":{"pane":{"agent_status":"idle","pane_id":"w1:p1","revision":2},"type":"pane_info"}}
    , "w1:p1").?;
    try testing.expect(get.state == .idle and get.agent.len == 0);
    // A state herdr adds later reads as unknown rather than as nothing.
    try testing.expectEqual(State.unknown, parse(arena,
        \\{"data":{"agent_status":"thinking","pane_id":"w1:p1"},"event":"pane.agent_status_changed"}
    , "w1:p1").?.state);

    for ([_][]const u8{
        \\{"data":{"agent_status":"blocked","pane_id":"w1:p2"},"event":"pane.agent_status_changed"}
        ,
        \\{"id":"s1","result":{"type":"subscription_started"}}
        ,
        \\{"data":{"pane_id":"w1:p1"},"event":"pane.updated"}
        ,
        "not json",
    }) |line| try testing.expect(parse(arena, line, "w1:p1") == null);
}
