// SPDX-License-Identifier: Apache-2.0
//
// The bridge: how a line of text reaches the agent's input box. Runtime
// selected, so a tagged union rather than comptime dispatch (the backend is
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
// tmux, herdr, WezTerm, kitty, Ghostty and OSC 52. Zellij is later and is absent rather
// than stubbed: a union variant whose `sendText` returns `error.Unsupported` is a
// backend `detect` would have to be careful never to return, which is more
// machinery than the three lines it will need.
//
// The five are the same shape and deliberately so - an argv, a
// subprocess, one named failure worth degrading on, and an inference that
// refuses to guess past two panes. What differs is only what each calls a
// pane and how each says a pane has gone, which is why those two things live
// in the backend files and everything else lives here.
//
// herdr is the one built for agents rather than for people, and it shows in
// the one place that matters here: `send-text` is a separate verb from
// `send-keys`, so raw text goes in and nothing is pressed. Everywhere else
// that separation is ours to maintain - `tmux send-keys -l` will happily press
// Enter if a newline reaches it, which is what hard rule 1 exists to prevent.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("../io/fs.zig");
const ghostty = @import("ghostty.zig");
const herdr = @import("herdr.zig");
const kitty = @import("kitty.zig");
const osc52 = @import("osc52.zig");
const tmux = @import("tmux.zig");
const wezterm = @import("wezterm.zig");

/// Pane ids are short in every multiplexer; the target is held inline rather
/// than allocated. The widest of the three, so one buffer serves all.
pub const max_pane_id = @max(
    @max(tmux.max_pane_id, herdr.max_pane_id),
    @max(ghostty.max_pane_id, @max(wezterm.max_pane_id, kitty.max_window_id)),
);

pub const Error = error{
    /// The payload contains a newline. Never sent, never truncated.
    Multiline,
    /// A multiplexer is the backend but no pane has been chosen and none
    /// could be inferred. The caller says how to choose one.
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
/// The chosen pane and our own, for whichever multiplexer is in front. One
/// type rather than three: the fields are identical and only the subprocess
/// that consumes them differs, so three copies would be three places to fix
/// the next time inference changes.
pub const Panes = struct {
    pane_buf: [max_pane_id]u8 = undefined,
    pane_len: usize = 0,
    /// Our own pane, from the multiplexer's env var, so inference can exclude
    /// it.
    self_buf: [max_pane_id]u8 = undefined,
    self_len: usize = 0,
    /// Inference runs once. A window with three panes cannot be guessed at,
    /// and re-running `list-panes` on every keystroke to fail the same way is
    /// a subprocess per keystroke.
    tried: bool = false,

    pub fn pane(self: *const Panes) ?[]const u8 {
        return if (self.pane_len == 0) null else self.pane_buf[0..self.pane_len];
    }

    pub fn selfPane(self: *const Panes) []const u8 {
        return self.self_buf[0..self.self_len];
    }

    pub fn setPane(self: *Panes, id: []const u8) void {
        self.pane_len = @min(id.len, self.pane_buf.len);
        @memcpy(self.pane_buf[0..self.pane_len], id[0..self.pane_len]);
    }
};

/// Kept for the callers that still say `Tmux`; the type is shared now.
pub const Tmux = Panes;

pub const Bridge = union(enum) {
    tmux: Panes,
    herdr: Panes,
    wezterm: Panes,
    kitty: Panes,
    ghostty: Panes,
    osc52: void,

    pub fn name(self: Bridge) []const u8 {
        return switch (self) {
            .tmux => "tmux",
            .herdr => "herdr",
            .wezterm => "wezterm",
            .kitty => "kitty",
            .ghostty => "ghostty",
            .osc52 => "clipboard",
        };
    }

    /// What this backend calls the thing a send goes to.
    ///
    /// Not decoration. kitty's splits are *windows* - "pane" there means
    /// nothing, and a message telling a kitty user to pick a pane sends them
    /// looking through documentation for a word kitty does not use. tmux and
    /// WezTerm both say pane. The one flag stays `--pane` because it is one
    /// flag; the prose around it follows the terminal the reader is in.
    pub fn unit(self: Bridge) []const u8 {
        return switch (self) {
            .kitty => "window",
            .tmux, .herdr, .wezterm, .ghostty, .osc52 => "pane",
        };
    }

    /// The pane state, for the backends that have any.
    pub fn panes(self: *Bridge) ?*Panes {
        return switch (self.*) {
            .tmux, .herdr, .wezterm, .kitty, .ghostty => |*p| p,
            .osc52 => null,
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
            .tmux, .herdr, .wezterm, .kitty, .ghostty => {
                const dest = try self.target(cx) orelse return error.NoTarget;
                const why = self.deliver(cx, dest, payload) orelse return .{ .sent = dest };

                // A pane that has gone is the common failure and the one worth
                // naming; the rest is the multiplexer itself. All of them
                // degrade, because losing the text is worse than losing the
                // destination.
                //
                // Forget the target *and* the fact that inference has run: a
                // pane that died is often replaced, and finding the
                // replacement should not cost a restart. Bounded - the retry
                // sets `tried` again on its way through.
                const p = self.panes().?;
                p.pane_len = 0;
                p.tried = false;
                try self.clipboard(cx, payload);
                return .{ .copied = why };
            },
        }
    }

    /// Hands the payload to whichever multiplexer is in front. Null is
    /// success; a string is what went wrong, in words the status line can
    /// show.
    ///
    /// The three failures are not the same three, which is the whole reason
    /// this is a switch and not one call: kitty can refuse because remote
    /// control is off, and that is a *setting* the reader can change rather
    /// than a pane that died. Saying "kitty failed" there would send them
    /// looking for the wrong thing.
    fn deliver(self: *Bridge, cx: Ctx, dest: []const u8, payload: []const u8) ?[]const u8 {
        switch (self.*) {
            .tmux => tmux.send(cx.gpa, cx.io, dest, payload) catch |err| return switch (err) {
                error.PaneGone => "pane is gone",
                else => "tmux failed",
            },
            .herdr => herdr.send(cx.gpa, cx.io, dest, payload) catch |err| return switch (err) {
                error.PaneGone => "pane is gone",
                else => "herdr failed",
            },
            .wezterm => wezterm.send(cx.gpa, cx.io, dest, payload) catch |err| return switch (err) {
                error.PaneGone => "pane is gone",
                else => "wezterm failed",
            },
            .kitty => kitty.send(cx.gpa, cx.io, dest, payload) catch |err| return switch (err) {
                error.WindowGone => "window is gone",
                error.NotAllowed => "kitty: set allow_remote_control yes",
                else => "kitty failed",
            },
            .ghostty => ghostty.send(cx.gpa, cx.io, dest, payload) catch |err| return switch (err) {
                error.PaneGone => "pane is gone",
                // Named, because both causes are things the reader can fix and
                // neither is about their splits: a Ghostty older than 1.3 has
                // no AppleScript dictionary, and macOS refuses one app
                // scripting another until it is allowed in Automation.
                error.Unavailable => "ghostty: needs 1.3+ and Automation access",
                else => "ghostty failed",
            },
            .osc52 => return "no multiplexer",
        }
        return null;
    }

    /// `y` and `Y`: the clipboard, always, whatever the backend is. A
    /// reference copied for a commit message has no business being typed into
    /// an agent, and unlike a send it may legitimately contain newlines - the
    /// no-newline rule is about what `send-keys` does with one.
    pub fn copyText(self: *Bridge, cx: Ctx, text: []const u8) Error!Outcome {
        try self.clipboard(cx, text);
        return .{ .copied = null };
    }

    /// Text onto the clipboard: the backend's own route if it has one that
    /// works, the OSC 52 escape underneath it if not.
    ///
    /// Every clipboard path in the bridge comes through here, including the
    /// degrade in `sendText` - a reference that lands on the clipboard because
    /// the agent's pane died is the case where losing it silently hurts most.
    fn clipboard(self: *Bridge, cx: Ctx, text: []const u8) Error!void {
        if (self.backendCopy(cx, text)) |_| return else |_| {}
        try osc52.copy(cx.gpa, cx.w, text);
    }

    /// The backend's own way of reaching the clipboard, above the escape.
    ///
    /// This exists because the escape is not always enough, and finding that
    /// out cost a bug that shipped: inside tmux, the default `set-clipboard
    /// external` lets tmux set the terminal clipboard *itself* but ignores an
    /// application that tries - so `y` put nothing on the clipboard and said
    /// it had. Asking tmux to do the copy is the same operation from the side
    /// tmux permits. Every multiplexer has a rule like this, and none of them
    /// are the same rule, so the answer belongs per backend rather than in one
    /// clever escape sequence.
    ///
    /// The switch is exhaustive on purpose. A new variant does not compile
    /// until someone has decided how it reaches the clipboard, which is the
    /// only mechanism here that stops the next backend inheriting this bug by
    /// saying nothing.
    fn backendCopy(self: *Bridge, cx: Ctx, text: []const u8) error{ Unsupported, Failed }!void {
        switch (self.*) {
            // Falls back rather than failing outright: a tmux too old for
            // `load-buffer -w` is the same tmux whose `set-clipboard` is
            // likely to be `on` and forwarding the escape anyway.
            .tmux => tmux.copy(cx.gpa, cx.io, text) catch return error.Failed,
            // Neither intercepts the escape the way tmux's `set-clipboard
            // external` does, so the escape below is the right route and
            // there is nothing above it to try.
            .herdr, .wezterm, .kitty, .ghostty => return error.Unsupported,
            // The escape *is* this backend. There is nothing above it to try,
            // and it is the right answer outside a multiplexer: it is the one
            // route that survives SSH.
            .osc52 => return error.Unsupported,
        }
    }

    /// The chosen pane, inferring one on first use. Null when the window holds
    /// more than the two panes the inference can be sure about.
    ///
    /// Inference runs once per backend and per death. Three panes cannot be
    /// guessed at, and re-listing on every keystroke to fail the same way is a
    /// subprocess per keystroke.
    fn target(self: *Bridge, cx: Ctx) Allocator.Error!?[]const u8 {
        const p = self.panes() orelse return null;
        if (p.pane()) |chosen| return chosen;
        if (p.tried) return null;
        p.tried = true;

        var scratch: std.heap.ArenaAllocator = .init(cx.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const mine = p.selfPane();
        const found = switch (self.*) {
            .tmux => tmux.soleOther(tmux.list(cx.gpa, arena, cx.io, false) catch return null, mine),
            .herdr => herdr.soleOther(herdr.list(cx.gpa, arena, cx.io) catch return null, mine),
            .wezterm => wezterm.soleOther(wezterm.list(cx.gpa, arena, cx.io) catch return null, mine),
            .kitty => kitty.soleOther(kitty.list(cx.gpa, arena, cx.io) catch return null, mine),
            // Ghostty injects no per-pane id, so "ours" is the terminal that
            // is focused the first time this is asked - which is the moment
            // just after the reader typed `lgtm` into it. The one inference
            // here resting on a habit rather than an identifier, and the
            // reason `--pane` exists.
            .ghostty => blk: {
                var self_buf: [max_pane_id]u8 = undefined;
                const me = ghostty.front(cx.gpa, cx.io, &self_buf) orelse "";
                break :blk ghostty.soleOther(ghostty.list(cx.gpa, arena, cx.io) catch return null, me);
            },
            .osc52 => null,
        } orelse return null;
        p.setPane(found);
        return p.pane();
    }
};

/// Env vars only, and infallible by construction: OSC 52 is always reachable,
/// so there is always a working bridge.
///
/// **Innermost first, which is not alphabetical.** tmux inside WezTerm sets
/// both `$TMUX` and `$WEZTERM_PANE`, and there the pane the agent is in is a
/// *tmux* pane - asking WezTerm to type into its own pane would put the text
/// into tmux's status line or into whichever pane tmux happens to be showing.
/// Whichever multiplexer is innermost owns the panes, and both tmux and herdr
/// nest inside a terminal rather than the other way about. tmux is ahead of
/// herdr on the same reasoning: herdr runs terminals, and a tmux inside one of
/// them is the thing actually holding the agent's pane.
pub fn detect(environ: *const std.process.Environ.Map) Bridge {
    if (nonEmpty(environ, "TMUX")) return .{ .tmux = panesFrom(environ, "TMUX_PANE") };
    if (nonEmpty(environ, "HERDR_ENV")) return .{ .herdr = panesFrom(environ, "HERDR_PANE_ID") };
    if (nonEmpty(environ, "WEZTERM_PANE")) return .{ .wezterm = panesFrom(environ, "WEZTERM_PANE") };
    if (nonEmpty(environ, "KITTY_WINDOW_ID")) return .{ .kitty = panesFrom(environ, "KITTY_WINDOW_ID") };
    // Last of the five, and the only one with nothing to put in `Panes`:
    // Ghostty says *that* you are in it and never *where*, so self-exclusion
    // is deferred to the first inference.
    if (isGhostty(environ)) return .{ .ghostty = .{} };
    return .osc52;
}

/// `$GHOSTTY_RESOURCES_DIR` is injected by Ghostty itself; `$TERM_PROGRAM` is
/// the conventional one and survives a shell that clears the first. Either
/// will do, because the question is only which backend to try.
fn isGhostty(environ: *const std.process.Environ.Map) bool {
    if (nonEmpty(environ, "GHOSTTY_RESOURCES_DIR")) return true;
    const tp = environ.get("TERM_PROGRAM") orelse return false;
    return std.mem.eql(u8, tp, "ghostty");
}

fn nonEmpty(environ: *const std.process.Environ.Map, key: []const u8) bool {
    return if (environ.get(key)) |v| v.len > 0 else false;
}

/// Our own pane id, so inference can exclude it. Absent is fine: `soleOther`
/// then refuses anything but a window holding exactly one pane, which is the
/// safe way to be wrong.
fn panesFrom(environ: *const std.process.Environ.Map, key: []const u8) Panes {
    var p: Panes = .{};
    if (environ.get(key)) |v| {
        p.self_len = @min(v.len, p.self_buf.len);
        @memcpy(p.self_buf[0..p.self_len], v[0..p.self_len]);
    }
    return p;
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

/// Durable state lives in `.lgtm/` and nowhere else. One
/// pane id, one line, so it is readable and deletable by hand.
pub const target_path = fs.state_dir ++ "/target";

/// One pane id and a newline. The cap is a sanity bound on a file the user can
/// edit by hand, not a budget.
const target_read_max = 256;

/// The saved pane id, copied into `buf`. Best effort throughout: a missing
/// file is the normal first run, and a corrupt one is not worth a message the
/// user cannot act on - inference runs next and usually gets it right.
pub fn loadTarget(io: std.Io, gpa: Allocator, buf: []u8) ?[]const u8 {
    const bytes = fs.readFile(io, gpa, target_path, target_read_max) catch return null;
    defer gpa.free(bytes);
    return parseTarget(bytes, buf);
}

/// Split from the read so the validation has a test that touches no file.
///
/// Two shapes, because the three multiplexers do not agree on what a pane id
/// looks like: tmux writes `%12`, WezTerm and kitty write a bare integer. The
/// file does not say which wrote it and does not need to - a target saved
/// under one multiplexer and read under another simply will not match
/// anything, and the inference that runs next is the better answer than
/// sending text somewhere arbitrary.
///
/// What the check is actually for is a file the user has edited by hand into
/// something that is not an id at all.
fn parseTarget(bytes: []const u8, buf: []u8) ?[]const u8 {
    const id = std.mem.trim(u8, bytes, " \t\r\n");
    if (id.len == 0 or id.len > buf.len) return null;
    const digits = if (id[0] == tmux.pane_sigil) id[1..] else id;
    if (digits.len == 0) return null;
    // Digits, and the two characters herdr's `w1:p1` adds. Loose on purpose:
    // the check is for a file someone has hand-edited into prose, not a
    // parser for four id grammars that would reject the next one.
    for (digits) |c| {
        if (!std.ascii.isDigit(c) and c != ':' and c != 'w' and c != 'p') return null;
    }
    @memcpy(buf[0..id.len], id);
    return buf[0..id.len];
}

/// Best effort: a read-only checkout should not stop a send that has already
/// worked, so a failure here is silent and the target lasts the session.
pub fn saveTarget(io: std.Io, pane: []const u8) void {
    fs.writeStateFile(io, target_path, pane) catch {};
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
    try testing.expect(std.mem.startsWith(u8, out.written(), osc52.prefix));
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

test "a saved target is a pane id in either spelling, and nothing else" {
    var buf: [max_pane_id]u8 = undefined;
    // tmux's.
    try testing.expectEqualStrings("%12", parseTarget("%12\n", &buf).?);
    try testing.expectEqualStrings("%12", parseTarget("  %12  ", &buf).?);
    // WezTerm's and kitty's, which are bare integers. Rejecting these was the
    // bug the moment there was a second multiplexer: the target was saved and
    // then silently thrown away on the next run.
    try testing.expectEqualStrings("12", parseTarget("12\n", &buf).?);
    try testing.expectEqualStrings("0", parseTarget("0", &buf).?);
    // herdr's, which is a workspace and a pane.
    try testing.expectEqualStrings("w1:p1", parseTarget("w1:p1\n", &buf).?);

    // Anything else is ignored in favour of the inference that runs next,
    // which is the better answer than sending text somewhere arbitrary.
    try testing.expect(parseTarget("", &buf) == null);
    try testing.expect(parseTarget("\n", &buf) == null);
    try testing.expect(parseTarget("%", &buf) == null);
    try testing.expect(parseTarget("agent", &buf) == null);
    try testing.expect(parseTarget("%1a", &buf) == null);
    try testing.expect(parseTarget("%" ++ ("0" ** 64), &buf) == null);
}

test "the vocabulary follows the terminal, because they do not agree" {
    // kitty's splits are windows. A message telling a kitty user to pick a
    // pane sends them looking for a word kitty's documentation does not use.
    try testing.expectEqualStrings("window", (Bridge{ .kitty = .{} }).unit());
    try testing.expectEqualStrings("pane", (Bridge{ .tmux = .{} }).unit());
    try testing.expectEqualStrings("pane", (Bridge{ .wezterm = .{} }).unit());
    try testing.expectEqualStrings("pane", (Bridge{ .herdr = .{} }).unit());
    try testing.expectEqualStrings("pane", (Bridge{ .ghostty = .{} }).unit());
}

test "detection prefers the multiplexer that owns the panes" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expect(detect(&env) == .osc52);

    try env.put("TERM_PROGRAM", "ghostty");
    try testing.expect(detect(&env) == .ghostty);

    try env.put("KITTY_WINDOW_ID", "4");
    try testing.expect(detect(&env) == .kitty);

    try env.put("WEZTERM_PANE", "7");
    try testing.expect(detect(&env) == .wezterm);

    // herdr is a multiplexer of its own and owns panes inside whatever
    // terminal it was launched from.
    try env.put("HERDR_ENV", "1");
    try testing.expect(detect(&env) == .herdr);

    // tmux inside any of them sets `$TMUX`, and there the agent's pane is a
    // *tmux* pane: asking the outer one to type into its own pane would put
    // the review into whichever pane tmux happens to be showing. Innermost
    // wins.
    try env.put("TMUX", "/tmp/tmux-501/default,123,0");
    try testing.expect(detect(&env) == .tmux);
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
