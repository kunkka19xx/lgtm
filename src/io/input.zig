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
/// Whether a codepoint is one a keyboard produces as text. Below `0x20` are
/// the C0 controls the named keys live in; `0xE000` up is the private-use area
/// kitty puts its functional keycodes in.
fn typesText(cp: u21) bool {
    return cp >= 0x20 and cp != event.code.backspace and cp < 0xE000;
}

pub fn toKey(k: vaxis.Key) event.Key {
    return .{
        .codepoint = k.codepoint,
        .mods = .{
            // Dropped for anything that types a character: the shift is
            // already in the codepoint, and terminals disagree about whether
            // to report it as well, so keeping it would make `V` match a
            // binding on one terminal and miss on another. It survives for the
            // named keys, where `<S-Tab>` really is a different key.
            .shift = k.mods.shift and !typesText(k.codepoint),
            .ctrl = k.mods.ctrl,
            .alt = k.mods.alt,
            .super = k.mods.super,
        },
    };
}

pub const Reader = struct {
    tty: *tty_mod.Tty,
    queue: *event.Queue,
    /// Optional: when set, the reader's existing wake is what converts a
    /// SIGWINCH into an event, so no third thread exists to poll one flag.
    /// Null in `--once`, where nothing is running to service it anyway.
    winsize: ?*WinsizeNotifier = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Set at `start`, from whether the tty gave us something pollable. When
    /// it did not, `stop` detaches instead of joining, because the read there
    /// is still uninterruptible.
    pollable: bool = false,
    /// The descriptor readiness is actually asked about, which is not always
    /// the one we read from - see `pollableFd`.
    poll_fd: ?std.posix.fd_t = null,

    /// How long a `poll` waits before rechecking `running`. Short enough that
    /// `e` does not feel delayed, long enough that idling costs twenty
    /// syscalls a second - microseconds of CPU, against a tool that sits in a
    /// pane all day.
    pub const poll_interval_ms: i32 = 50;

    pub fn init(tty: *tty_mod.Tty, queue: *event.Queue) Reader {
        return .{ .tty = tty, .queue = queue };
    }

    pub fn start(self: *Reader) !void {
        self.poll_fd = pollableFd(self.tty);
        self.pollable = self.poll_fd != null;
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
    ///
    /// `HUP` counts as readable so the terminal going away is reported by the
    /// read, which sees the end of the file, rather than spun on here.
    fn readable(self: *Reader) bool {
        const fd = self.poll_fd orelse return true;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, poll_interval_ms) catch return true;
        if (n == 0) return false;
        return fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0;
    }

    /// A descriptor whose readiness `poll` will actually answer.
    ///
    /// macOS answers `POLLNVAL` for `/dev/tty`: the controlling-terminal clone
    /// device is not pollable there, though the pty behind it polls normally.
    /// Taking `n > 0` as "readable" then dropped the thread into a read that
    /// parks until the next keystroke, and everything that waits for the
    /// thread - quitting, and handing the terminal to `$EDITOR` - waited with
    /// it. That is the `:q` that needed a second Enter.
    ///
    /// The two descriptors are the same terminal, so readiness on one is
    /// readiness to read on the other. Probed rather than assumed, because
    /// which descriptor is pollable is a property of the platform.
    fn pollableFd(tty: *tty_mod.Tty) ?std.posix.fd_t {
        if (tty.handle()) |fd| {
            if (pollAnswers(fd)) return fd;
        }
        // Only when stdin is this terminal: polling a redirect that is always
        // ready would spin instead of waiting.
        if (std.c.isatty(0) != 0 and pollAnswers(0)) return 0;
        return null;
    }

    fn pollAnswers(fd: std.posix.fd_t) bool {
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, 0) catch return false;
        return fds[0].revents & (std.posix.POLL.NVAL | std.posix.POLL.ERR) == 0;
    }

    fn run(self: *Reader) void {
        var parser: vaxis.Parser = .{};
        var buf: [1024]u8 = undefined;
        var carry: usize = 0;

        while (self.running.load(.acquire)) {
            // Before the poll, so a resize that arrives while the pane is idle
            // is serviced on the next tick rather than waiting for a keypress.
            if (self.winsize) |wn| wn.take();
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

/// Turns SIGWINCH into a `resize` event on the queue.
///
/// The callback runs inside vaxis's signal handler, so it does exactly one
/// thing: an atomic store. It does **not** measure the terminal or push, both
/// of which were done here first and both of which are unsafe from a handler.
/// `Queue.push` takes a mutex and allocates, and a signal is delivered on
/// whichever thread happens not to be blocking it - so a SIGWINCH landing on a
/// thread that already holds the queue mutex, or that is inside the allocator,
/// hangs the process with no way out. It is a small window and a rare signal,
/// which is exactly the kind of hang that survives a release.
///
/// `take` is the other half, called from an ordinary thread (the reader's
/// 50 ms wake). Coalescing falls out of the flag: a drag across the screen is
/// hundreds of signals and one `resize` carrying the size the pane settled at,
/// rather than hundreds of screen reallocations.
pub const WinsizeNotifier = struct {
    tty: *tty_mod.Tty,
    queue: *event.Queue,
    /// Written by the signal handler, cleared by whoever services it.
    pending: std.atomic.Value(bool) = .init(false),

    pub fn register(self: *WinsizeNotifier) !void {
        try vaxis.tty.Tty.notifyWinsize(self.handler());
    }

    /// Symmetry with `register`, and not only tidiness: the handler holds a
    /// pointer to this struct, which lives on `app.run`'s stack. A SIGWINCH
    /// arriving after that frame is gone would run against freed memory.
    pub fn unregister(self: *WinsizeNotifier) void {
        vaxis.tty.Tty.removeWinsize(self.handler());
    }

    fn handler(self: *WinsizeNotifier) vaxis.tty.Tty.SignalHandler {
        return .{ .context = @ptrCast(self), .callback = onWinch };
    }

    /// Pushes one `resize` if a signal arrived since the last call. Safe to
    /// call as often as the caller likes: with no signal outstanding it is one
    /// uncontended atomic and nothing else.
    pub fn take(self: *WinsizeNotifier) void {
        if (!self.consume()) return;
        // Measured here rather than in the handler, so the size reported is
        // the one the terminal has now - the point of coalescing.
        const ws = self.tty.winsize() catch return;
        self.queue.push(.{ .resize = .{ .cols = ws.cols, .rows = ws.rows } }) catch {};
    }

    /// True once per burst of signals. Split out from `take` because it is the
    /// part that has no terminal in it, and so the part a test can reach.
    fn consume(self: *WinsizeNotifier) bool {
        return self.pending.swap(false, .acq_rel);
    }

    fn onWinch(ctx: *anyopaque) void {
        const self: *WinsizeNotifier = @ptrCast(@alignCast(ctx));
        self.pending.store(true, .release);
    }
};

const testing = std.testing;

test "a burst of SIGWINCH collapses into one resize" {
    // No terminal is touched on this path, so the tty pointer is never read.
    var wn: WinsizeNotifier = .{ .tty = undefined, .queue = undefined };

    // Idle: nothing to report, and reporting nothing must be cheap enough to
    // sit in the reader's 50 ms wake.
    try testing.expect(!wn.consume());

    // Dragging a pane border delivers the signal over and over. What the main
    // loop should see is one re-layout at the size it settled on, not one per
    // signal - each of which reallocates both vaxis screen buffers.
    WinsizeNotifier.onWinch(@ptrCast(&wn));
    WinsizeNotifier.onWinch(@ptrCast(&wn));
    WinsizeNotifier.onWinch(@ptrCast(&wn));
    try testing.expect(wn.consume());
    try testing.expect(!wn.consume());

    // And a signal after the drain is a fresh resize, not a swallowed one.
    WinsizeNotifier.onWinch(@ptrCast(&wn));
    try testing.expect(wn.consume());
}

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
    try testing.expectEqual(vaxis.Key.up, event.code.up);
    try testing.expectEqual(vaxis.Key.down, event.code.down);
    try testing.expectEqual(vaxis.Key.left, event.code.left);
    try testing.expectEqual(vaxis.Key.right, event.code.right);
}
