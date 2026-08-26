// SPDX-License-Identifier: Apache-2.0
//
// Terminal input on its own thread, translated into `core/event.zig` types and
// pushed onto the one queue the main loop drains.
//
// ARCHITECTURE.md 3 draws one background thread; this is a second. The reason
// is that the tty read blocks, and the main loop must stay free to service the
// watcher. The property that section actually cares about is preserved: the
// UI is single-threaded and the threads meet at one mutex-protected queue and
// nowhere else.
//
// vaxis parses the bytes and we drive the loop, rather than handing control to
// `vaxis.Loop` (ARCHITECTURE.md 5c).

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const event = @import("../core/event.zig");
const tty_mod = @import("tty.zig");

/// Translates a vaxis key into the core type, so nothing above `io/` needs to
/// know vaxis exists.
pub fn toKey(k: vaxis.Key) event.Key {
    return .{
        .codepoint = k.codepoint,
        .mods = .{
            .shift = k.mods.shift,
            .ctrl = k.mods.ctrl,
            .alt = k.mods.alt,
            .super = k.mods.super,
        },
    };
}

pub const Reader = struct {
    tty: *tty_mod.Tty,
    queue: *event.Queue,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(tty: *tty_mod.Tty, queue: *event.Queue) Reader {
        return .{ .tty = tty, .queue = queue };
    }

    pub fn start(self: *Reader) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// The read blocks, so this does not join: the thread ends with the
    /// process once the terminal is restored. Detaching is deliberate - a join
    /// here would hang until the user pressed a key.
    pub fn stop(self: *Reader) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.detach();
            self.thread = null;
        }
    }

    fn run(self: *Reader) void {
        var parser: vaxis.Parser = .{};
        var buf: [1024]u8 = undefined;
        var carry: usize = 0;

        while (self.running.load(.acquire)) {
            const got = self.tty.read(buf[carry..]) catch break;
            if (got == 0) break;
            const n = carry + got;

            var at: usize = 0;
            while (at < n) {
                const res = parser.parse(buf[at..n], null) catch break;
                if (res.n == 0) {
                    // A partial sequence: move it to the front and read more.
                    // Without this an escape sequence split across two reads
                    // is parsed as a bare ESC plus junk.
                    std.mem.copyForwards(u8, buf[0 .. n - at], buf[at..n]);
                    carry = n - at;
                    break;
                }
                at += res.n;
                carry = 0;
                const ev = res.event orelse continue;
                switch (ev) {
                    .key_press => |k| self.queue.push(.{ .key = toKey(k) }) catch return,
                    else => {},
                }
            }
        }
    }
};

/// Pushes a `resize` event when the terminal changes size.
///
/// The callback runs inside vaxis's SIGWINCH handler, which already takes a
/// mutex and is what `vaxis.Loop` does with its own queue - so this follows
/// the library's established pattern rather than inventing a riskier one.
pub const WinsizeNotifier = struct {
    tty: *tty_mod.Tty,
    queue: *event.Queue,

    pub fn register(self: *WinsizeNotifier) !void {
        try vaxis.tty.Tty.notifyWinsize(.{
            .context = @ptrCast(self),
            .callback = onWinch,
        });
    }

    fn onWinch(ctx: *anyopaque) void {
        const self: *WinsizeNotifier = @ptrCast(@alignCast(ctx));
        const ws = self.tty.winsize() catch return;
        self.queue.push(.{ .resize = .{ .cols = ws.cols, .rows = ws.rows } }) catch {};
    }
};

const testing = std.testing;

test "modifiers survive translation into the core key type" {
    const k = toKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(u21, 'd'), k.codepoint);
    try testing.expect(k.mods.ctrl);
    try testing.expect(!k.mods.shift);
}

test "translation drops modifiers the core type does not model" {
    // caps_lock and num_lock are terminal state, not part of a binding.
    const k = toKey(.{ .codepoint = 'j', .mods = .{ .caps_lock = true, .num_lock = true } });
    try testing.expectEqual(@as(u21, 'j'), k.codepoint);
    try testing.expect(!k.mods.ctrl);
    try testing.expect(!k.mods.alt);
}
