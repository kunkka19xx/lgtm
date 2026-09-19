// SPDX-License-Identifier: Apache-2.0
//
// tmux's control mode as a doorbell: it says the watched pane printed, and the daemon captures it then.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const proc = @import("../io/proc.zig");

pub const Bell = struct {
    child: std.process.Child,
    thread: std.Thread,
    /// Starts rung, so the pane is captured once as soon as it is watched.
    rung: std.atomic.Value(bool) = .init(true),
    ended: std.atomic.Value(bool) = .init(false),
    prefix_buf: [48]u8 = undefined,
    prefix_len: usize = 0,

    /// A client that never resizes the reader's windows and never types, on the pane's session. Not `read-only`: tmux then refuses every send to that session.
    pub fn start(gpa: Allocator, io: Io, pane: []const u8) !*Bell {
        const b = try gpa.create(Bell);
        errdefer gpa.destroy(b);
        b.* = .{ .child = undefined, .thread = undefined };
        b.prefix_len = (try std.fmt.bufPrint(&b.prefix_buf, "{s} ", .{pane})).len;
        b.child = try proc.spawnPiped(io, &.{ "tmux", "-C", "attach-session", "-f", "ignore-size", "-t", pane }, null);
        b.thread = std.Thread.spawn(.{}, listen, .{ b, gpa, io }) catch |err| {
            b.child.kill(io);
            return err;
        };
        return b;
    }

    /// Whether the pane printed since the last call.
    pub fn take(b: *Bell) bool {
        return b.rung.swap(false, .acq_rel);
    }

    pub fn alive(b: *Bell) bool {
        return !b.ended.load(.acquire);
    }

    /// Closing its stdin detaches the client.
    pub fn stop(b: *Bell, gpa: Allocator, io: Io) void {
        if (b.child.stdin) |f| f.close(io);
        b.child.stdin = null;
        b.thread.join();
        _ = b.child.wait(io) catch {};
        gpa.destroy(b);
    }

    fn listen(b: *Bell, gpa: Allocator, io: Io) void {
        defer b.ended.store(true, .release);
        const buf = gpa.alloc(u8, 64 << 10) catch return;
        defer gpa.free(buf);
        var r = b.child.stdout.?.readerStreaming(io, buf);
        while (true) {
            const line = (r.interface.takeDelimiter('\n') catch |err| switch (err) {
                // A long burst of output: it rang, and the rest of the line is not needed.
                error.StreamTooLong => {
                    b.rung.store(true, .release);
                    r.interface.tossBuffered();
                    continue;
                },
                else => return,
            }) orelse return;
            if (rings(line, b.prefix_buf[0..b.prefix_len])) b.rung.store(true, .release);
            if (std.mem.startsWith(u8, line, "%exit")) return;
        }
    }
};

fn rings(line: []const u8, prefix: []const u8) bool {
    for ([_][]const u8{ "%output ", "%extended-output " }) |kind| {
        if (std.mem.startsWith(u8, line, kind) and std.mem.startsWith(u8, line[kind.len..], prefix)) return true;
    }
    return false;
}

test "only the watched pane's output rings" {
    try std.testing.expect(rings("%output %12 hello\\015\\012", "%12 "));
    try std.testing.expect(rings("%extended-output %12 40 : hi", "%12 "));
    try std.testing.expect(!rings("%output %120 hello", "%12 "));
    try std.testing.expect(!rings("%output %3 hello", "%12 "));
    try std.testing.expect(!rings("%window-renamed @906 %12 ", "%12 "));
}
