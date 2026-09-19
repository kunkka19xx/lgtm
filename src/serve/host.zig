// SPDX-License-Identifier: Apache-2.0
//
// `lgtm agent`: the agent on a pty lgtm owns, relayed untouched, with a copy through `vt.zig` for the phone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pty = @import("../io/pty.zig");
const vt = @import("vt.zig");

pub const Host = struct {
    gpa: Allocator,
    io: Io,
    master: Io.File,
    child: std.process.Child,
    size: pty.Size,
    /// Guards `screen`, which the relay writes and the daemon reads.
    mutex: Io.Mutex = .init,
    screen: vt.Screen,
    /// One writer into the pty at a time, so a phone's line never lands inside a keystroke's escape.
    input: Io.Mutex = .init,
    exited: std.atomic.Value(bool) = .init(false),
    /// One writer to the terminal: the relay, or a notification between its chunks.
    output: Io.Mutex = .init,
    pending: [160]u8 = undefined,
    pending_len: usize = 0,

    pub fn start(gpa: Allocator, io: Io, argv: []const []const u8) !*Host {
        const pair = try pty.open(io);
        errdefer pair.master.close(io);
        const size = pty.size(1) orelse pty.Size{ .rows = 24, .cols = 80 };
        pty.setSize(pair.master, size);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const child = try pty.spawn(io, pair.slave, argv, arena.allocator());
        // Closed here too, or the master never sees the agent's side close.
        pair.slave.close(io);

        const self = try gpa.create(Host);
        self.* = .{ .gpa = gpa, .io = io, .master = pair.master, .child = child, .size = size, .screen = try .init(gpa, size.cols, size.rows) };
        return self;
    }

    pub fn run(self: *Host) u8 {
        const saved = pty.makeRaw(0) catch null;
        defer if (saved) |s| pty.restore(0, s);
        // Detached: a read on stdin cannot be interrupted, and the process ends with the agent.
        if (std.Thread.spawn(.{}, pump, .{self})) |t| t.detach() else |_| {}
        if (std.Thread.spawn(.{}, follow, .{self})) |t| t.detach() else |_| {}

        const out = Io.File.stdout();
        var buf: [16 << 10]u8 = undefined;
        while (true) {
            const n = self.master.readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            self.output.lockUncancelable(self.io);
            defer self.output.unlock(self.io);
            out.writeStreamingAll(self.io, buf[0..n]) catch {};
            self.mutex.lockUncancelable(self.io);
            self.screen.feed(buf[0..n]);
            const clean = self.screen.settled();
            self.mutex.unlock(self.io);
            if (clean and self.pending_len > 0) {
                out.writeStreamingAll(self.io, self.pending[0..self.pending_len]) catch {};
                self.pending_len = 0;
            }
        }
        self.exited.store(true, .release);
        const term = self.child.wait(self.io) catch return 1;
        // A signal is 128 plus its number, as a shell reports it.
        return switch (term) {
            .exited => |code| code,
            .signal => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
            else => 1,
        };
    }

    /// OSC 9, the one way to say a phone connected without drawing over the agent; held back mid-sequence.
    pub fn announce(self: *Host, device: []const u8) void {
        self.output.lockUncancelable(self.io);
        defer self.output.unlock(self.io);
        const note = std.fmt.bufPrint(&self.pending, "\x1b]9;lgtm: {s} connected\x07", .{device}) catch return;
        self.mutex.lockUncancelable(self.io);
        const clean = self.screen.settled();
        self.mutex.unlock(self.io);
        if (!clean) {
            self.pending_len = note.len;
            return;
        }
        Io.File.stdout().writeStreamingAll(self.io, note) catch {};
        self.pending_len = 0;
    }

    pub fn alive(self: *Host) bool {
        return !self.exited.load(.acquire);
    }

    pub fn text(self: *Host, arena: Allocator) Allocator.Error![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.screen.text(arena);
    }

    pub fn write(self: *Host, bytes: []const u8) !void {
        if (!self.alive()) return error.Exited;
        self.input.lockUncancelable(self.io);
        defer self.input.unlock(self.io);
        try self.master.writeStreamingAll(self.io, bytes);
    }

    fn pump(self: *Host) void {
        const in = Io.File.stdin();
        var buf: [4096]u8 = undefined;
        while (self.alive()) {
            const n = in.readStreaming(self.io, &.{&buf}) catch return;
            if (n == 0) return;
            self.write(buf[0..n]) catch return;
        }
    }

    /// Polled, so a resize reaches the agent even while it is quiet.
    fn follow(self: *Host) void {
        while (self.alive()) {
            self.io.sleep(.fromMilliseconds(200), .awake) catch return;
            const now = pty.size(1) orelse continue;
            if (now.rows == self.size.rows and now.cols == self.size.cols) continue;
            self.size = now;
            self.mutex.lockUncancelable(self.io);
            self.screen.resize(now.cols, now.rows) catch {};
            self.mutex.unlock(self.io);
            pty.setSize(self.master, now);
        }
    }
};
