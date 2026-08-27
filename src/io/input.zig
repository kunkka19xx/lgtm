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
//
// The read is guarded by a short `poll` rather than left to block. That is not
// about latency - it is what makes `stop()` able to *join*. `e` hands the
// terminal to `$EDITOR`, and a reader still blocked on the same descriptor
// would steal every other keystroke from it. A blocking read cannot be
// interrupted from another thread; a poll that times out can notice that it
// has been asked to stop.

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
    /// Set at `start`, from whether the tty gave us something pollable. When
    /// it did not, `stop` detaches instead of joining, because the read there
    /// is still uninterruptible.
    pollable: bool = false,

    /// How long a `poll` waits before rechecking `running`. Short enough that
    /// `e` does not feel delayed, long enough that idling costs twenty
    /// syscalls a second - microseconds of CPU, against a tool that sits in a
    /// pane all day.
    pub const poll_interval_ms: i32 = 50;

    pub fn init(tty: *tty_mod.Tty, queue: *event.Queue) Reader {
        return .{ .tty = tty, .queue = queue };
    }

    pub fn start(self: *Reader) !void {
        self.pollable = self.tty.handle() != null;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Returns once the thread has stopped touching the terminal, so the
    /// caller may hand it to a child process. Where the read cannot be
    /// interrupted this degrades to the old detach: the thread outlives the
    /// call, which is why `e` is only offered when `pollable`.
    pub fn stop(self: *Reader) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            if (self.pollable) t.join() else t.detach();
            self.thread = null;
        }
    }

    /// True when the descriptor has bytes waiting. A timeout returns false and
    /// the loop goes back to check `running`; an error returns true so the
    /// read reports the real failure rather than this one.
    fn readable(self: *Reader) bool {
        const fd = self.tty.handle() orelse return true;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, poll_interval_ms) catch return true;
        return n > 0;
    }

    fn run(self: *Reader) void {
        var parser: vaxis.Parser = .{};
        var buf: [1024]u8 = undefined;
        var carry: usize = 0;

        while (self.running.load(.acquire)) {
            if (!self.readable()) continue;
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

test "the core key codes are the ones vaxis reports" {
    // core/event.zig cannot import vaxis, so the constants are duplicated
    // there. This is the assertion that keeps the copy honest: a library
    // change becomes a failing test instead of a key that silently does
    // nothing.
    try testing.expectEqual(vaxis.Key.tab, event.code.tab);
    try testing.expectEqual(vaxis.Key.enter, event.code.enter);
    try testing.expectEqual(vaxis.Key.escape, event.code.escape);
    try testing.expectEqual(vaxis.Key.backspace, event.code.backspace);
}
