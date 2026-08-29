// SPDX-License-Identifier: Apache-2.0
//
// The bridge: how a line of text reaches the agent's input box. Runtime
// selected, so a tagged union rather than comptime dispatch (ARCHITECTURE.md
// 6). `detect` never fails - OSC 52 is always reachable, so there is always a
// working bridge - and a backend that fails at call time degrades to the
// clipboard with a notice rather than propagating as fatal.
//
// Two invariants live here and not in the backends, so no backend can get them
// wrong:
//
//   1. A payload containing `\n` is refused. In `tmux send-keys` a newline is
//      Enter, and Enter makes the agent submit a half-written message. This is
//      a returned error rather than `std.debug.assert`, because assert is
//      compiled out in ReleaseFast and this is exactly the build where the
//      mistake would be silent (hard rules 1 and 2).
//   2. A sent payload ends with one trailing space and no carriage return. The
//      space is added here, so no caller can forget it, and the user is the
//      one who decides when to press Enter.
//
// v0.1 ships tmux and OSC 52. WezTerm, kitty and Zellij are v0.2 (PLAN.md) and
// are absent rather than stubbed: a union variant whose `sendText` returns
// `error.Unsupported` is a backend `detect` would have to be careful never to
// return, which is more machinery than the three lines they will each need.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("../io/fs.zig");
const osc52 = @import("osc52.zig");
const tmux = @import("tmux.zig");

/// Pane ids are short; the target is held inline rather than allocated.
pub const max_pane_id = tmux.max_pane_id;

pub const Error = error{
    /// The payload contains a newline. Never sent, never truncated.
    Multiline,
    /// tmux is the backend but no pane has been chosen and none could be
    /// inferred. The caller says how to choose one.
    NoTarget,
} || Allocator.Error || std.Io.Writer.Error;

/// What actually happened, which is not always what was asked for: a send to a
/// dead pane lands on the clipboard instead, and the status line has to be
/// able to say so.
pub const Outcome = union(enum) {
    /// Reached the agent's input box, in this pane.
    sent: []const u8,
    /// Reached the clipboard. `why` is null when that was the plan, and the
    /// reason for the degrade when it was not.
    copied: ?[]const u8,
};

/// Where a send needs to go. Both are needed because the two backends want
/// different things: tmux spawns a subprocess, OSC 52 writes to the terminal.
pub const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    /// The writer `io/tty.zig` owns. Borrowed for the length of the call.
    w: *std.Io.Writer,
};

/// Pane ids are `%` and a small integer, so the target is held inline. It
/// outlives every arena in the program and is far too small to be worth a
/// lifetime.
pub const Tmux = struct {
    pane_buf: [tmux.max_pane_id]u8 = undefined,
    pane_len: usize = 0,
    /// Our own pane, from `$TMUX_PANE`, so inference can exclude it.
    self_buf: [tmux.max_pane_id]u8 = undefined,
    self_len: usize = 0,
    /// Inference runs once. A window with three panes cannot be guessed at,
    /// and re-running `list-panes` on every keystroke to fail the same way is
    /// a subprocess per keystroke.
    tried: bool = false,

    pub fn pane(self: *const Tmux) ?[]const u8 {
        return if (self.pane_len == 0) null else self.pane_buf[0..self.pane_len];
    }

    pub fn selfPane(self: *const Tmux) []const u8 {
        return self.self_buf[0..self.self_len];
    }

    pub fn setPane(self: *Tmux, id: []const u8) void {
        self.pane_len = @min(id.len, self.pane_buf.len);
        @memcpy(self.pane_buf[0..self.pane_len], id[0..self.pane_len]);
    }
};

pub const Bridge = union(enum) {
    tmux: Tmux,
    osc52: void,

    pub fn name(self: Bridge) []const u8 {
        return switch (self) {
            .tmux => "tmux",
            .osc52 => "clipboard",
        };
    }

    /// Inserts `text` into the agent's input box, with a trailing space and
    /// without submitting it.
    pub fn sendText(self: *Bridge, cx: Ctx, text: []const u8) Error!Outcome {
        const payload = try normalise(cx.gpa, text);
        defer cx.gpa.free(payload);

        switch (self.*) {
            .osc52 => {
                try osc52.copy(cx.gpa, cx.w, payload);
                return .{ .copied = null };
            },
            .tmux => |*t| {
                const target = try self.tmuxTarget(cx) orelse return error.NoTarget;
                tmux.send(cx.gpa, cx.io, target, payload) catch |err| {
                    // A pane that has gone is the common one and the one worth
                    // naming; anything else is tmux itself failing. Both
                    // degrade, because losing the text is worse than losing
                    // the destination (ARCHITECTURE.md 6).
                    // Forget the target *and* the fact that inference has
                    // run: a pane that died is often replaced, and finding
                    // the replacement should not cost a restart. Bounded -
                    // the retry sets `tried` again on its way through.
                    t.pane_len = 0;
                    t.tried = false;
                    try osc52.copy(cx.gpa, cx.w, payload);
                    return .{ .copied = switch (err) {
                        error.PaneGone => "pane is gone",
                        else => "tmux failed",
                    } };
                };
                return .{ .sent = target };
            },
        }
    }

    /// `y` and `Y`: the clipboard, always, whatever the backend is. A
    /// reference copied for a commit message has no business being typed into
    /// an agent, and unlike a send it may legitimately contain newlines - the
    /// no-newline rule is about what `send-keys` does with one.
    pub fn copyText(self: *Bridge, cx: Ctx, text: []const u8) Error!Outcome {
        _ = self;
        try osc52.copy(cx.gpa, cx.w, text);
        return .{ .copied = null };
    }

    /// The chosen pane, inferring one on first use. Null when the window holds
    /// more than the two panes the inference can be sure about.
    fn tmuxTarget(self: *Bridge, cx: Ctx) Allocator.Error!?[]const u8 {
        const t = &self.tmux;
        if (t.pane()) |p| return p;
        if (t.tried) return null;
        t.tried = true;

        var scratch: std.heap.ArenaAllocator = .init(cx.gpa);
        defer scratch.deinit();
        const panes = tmux.list(cx.gpa, scratch.allocator(), cx.io, false) catch return null;
        const found = tmux.soleOther(panes, t.selfPane()) orelse return null;
        t.setPane(found);
        return t.pane();
    }
};

/// Env vars only, and infallible by construction (ARCHITECTURE.md 6).
pub fn detect(environ: *const std.process.Environ.Map) Bridge {
    const in_tmux = if (environ.get("TMUX")) |v| v.len > 0 else false;
    if (!in_tmux) return .osc52;

    var t: Tmux = .{};
    if (environ.get("TMUX_PANE")) |p| {
        t.self_len = @min(p.len, t.self_buf.len);
        @memcpy(t.self_buf[0..t.self_len], p[0..t.self_len]);
    }
    return .{ .tmux = t };
}

/// The payload as it goes out: newline refused, carriage returns dropped, one
/// trailing space guaranteed.
fn normalise(gpa: Allocator, text: []const u8) Error![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.Multiline;

    const trimmed = std.mem.trimEnd(u8, text, " \t\r");
    var out = try gpa.alloc(u8, trimmed.len + 1);
    @memcpy(out[0..trimmed.len], trimmed);
    out[trimmed.len] = ' ';
    return out;
}

// -- target persistence ------------------------------------------------------

/// Durable state lives in `.lgtm/` and nowhere else (ARCHITECTURE.md 1). One
/// pane id, one line, so it is readable and deletable by hand.
pub const target_path = ".lgtm/target";

/// The saved pane id, copied into `buf`. Best effort throughout: a missing
/// file is the normal first run, and a corrupt one is not worth a message the
/// user cannot act on - inference runs next and usually gets it right.
pub fn loadTarget(io: std.Io, gpa: Allocator, buf: []u8) ?[]const u8 {
    const bytes = fs.readFile(io, gpa, target_path, 256) catch return null;
    defer gpa.free(bytes);
    return parseTarget(bytes, buf);
}

/// Split from the read so the validation has a test that touches no file.
fn parseTarget(bytes: []const u8, buf: []u8) ?[]const u8 {
    const id = std.mem.trim(u8, bytes, " \t\r\n");
    if (id.len == 0 or id.len > buf.len or id[0] != '%') return null;
    @memcpy(buf[0..id.len], id);
    return buf[0..id.len];
}

/// Best effort: a read-only checkout should not stop a send that has already
/// worked, so a failure here is silent and the target lasts the session.
pub fn saveTarget(io: std.Io, pane: []const u8) void {
    fs.writeFile(io, target_path, pane) catch {};
}

const testing = std.testing;

fn envWith(gpa: Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    for (pairs) |p| try map.put(p[0], p[1]);
    return map;
}

test "outside a multiplexer the bridge is the clipboard" {
    var map = try envWith(testing.allocator, &.{});
    defer map.deinit();
    try testing.expect(detect(&map) == .osc52);

    // An empty $TMUX is not being in tmux.
    var empty = try envWith(testing.allocator, &.{.{ "TMUX", "" }});
    defer empty.deinit();
    try testing.expect(detect(&empty) == .osc52);
}

test "$TMUX selects tmux and $TMUX_PANE names the pane to exclude" {
    var map = try envWith(testing.allocator, &.{
        .{ "TMUX", "/tmp/tmux-501/default,123,0" },
        .{ "TMUX_PANE", "%7" },
    });
    defer map.deinit();

    const br = detect(&map);
    try testing.expect(br == .tmux);
    try testing.expectEqualStrings("%7", br.tmux.selfPane());
    // Nothing has chosen a target yet: inference is lazy, so a pane opened
    // after lgtm started is still reachable.
    try testing.expect(br.tmux.pane() == null);
}

test "a newline is refused rather than truncated" {
    // The whole of hard rule 1: in send-keys a newline is Enter, and Enter
    // submits the user's half-written message.
    try testing.expectError(error.Multiline, normalise(testing.allocator, "a\nb"));
    try testing.expectError(error.Multiline, normalise(testing.allocator, "trailing\n"));
}

test "a sent payload ends in exactly one space and no carriage return" {
    const one = try normalise(testing.allocator, "#3 src/auth.rs:47");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("#3 src/auth.rs:47 ", one);

    // Whatever the caller's spacing, the result is the same: the space is the
    // bridge's job, so no caller can forget it or double it.
    const messy = try normalise(testing.allocator, "#3 src/auth.rs:47   ");
    defer testing.allocator.free(messy);
    try testing.expectEqualStrings("#3 src/auth.rs:47 ", messy);

    const cr = try normalise(testing.allocator, "#3 a.zig:1\r");
    defer testing.allocator.free(cr);
    try testing.expectEqualStrings("#3 a.zig:1 ", cr);
}

test "the clipboard path takes text a send would refuse" {
    // `Y` copies a reference and the lines under it, which is several lines.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var br: Bridge = .osc52;
    const res = try br.copyText(.{
        .gpa = testing.allocator,
        .io = undefined,
        .w = &out.writer,
    }, "#3 a.zig:1\n+    return 1;");
    try testing.expect(res == .copied);
    try testing.expect(res.copied == null);
    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b]52;c;"));
}

test "a send with no multiplexer lands on the clipboard and says so" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var br: Bridge = .osc52;
    const res = try br.sendText(.{
        .gpa = testing.allocator,
        .io = undefined,
        .w = &out.writer,
    }, "#3 a.zig:1");
    // `.copied` with no reason: this was the plan, not a degrade.
    try testing.expect(res.copied == null);

    try testing.expectError(error.Multiline, br.sendText(.{
        .gpa = testing.allocator,
        .io = undefined,
        .w = &out.writer,
    }, "one\ntwo"));
}

test "a saved target is a pane id, and nothing else is accepted" {
    var buf: [tmux.max_pane_id]u8 = undefined;
    try testing.expectEqualStrings("%12", parseTarget("%12\n", &buf).?);
    try testing.expectEqualStrings("%12", parseTarget("  %12  ", &buf).?);

    // Anything else is ignored in favour of the inference that runs next,
    // which is the better answer than sending text somewhere arbitrary.
    try testing.expect(parseTarget("", &buf) == null);
    try testing.expect(parseTarget("\n", &buf) == null);
    try testing.expect(parseTarget("12", &buf) == null);
    try testing.expect(parseTarget("%" ++ ("0" ** 64), &buf) == null);
}

test "a pane longer than the inline buffer is truncated, not overrun" {
    var t: Tmux = .{};
    t.setPane("%" ++ ("9" ** 64));
    try testing.expectEqual(@as(usize, tmux.max_pane_id), t.pane().?.len);
}

// The backends reach the test runner through here, the way `ui/loop.zig`
// reaches `editor.zig`: a module nothing references is a module whose tests
// never run.
test {
    _ = osc52;
    _ = tmux;
}
