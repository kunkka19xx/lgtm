// SPDX-License-Identifier: Apache-2.0
//
// Every action is a named command and the keymap maps sequences to names, so
// dispatch contains no hardcoded keys (FEATURES.md 4.3). Remapping and presets
// are phase 5c; the indirection is here from the start because retrofitting it
// means touching every call site.

const std = @import("std");
const event = @import("../core/event.zig");

pub const Command = enum {
    quit,
    line_down,
    line_up,
    page_down,
    page_up,
    top,
    bottom,
    next_hunk,
    prev_hunk,
    next_file,
    prev_file,
    center,
    refresh,
    /// Enter and leave visual line select. One command rather than two,
    /// because `V` in visual mode is what leaves it.
    visual_toggle,
    /// Escape: leave visual mode, and nothing at all in normal mode. Bound
    /// only in visual so that a stray Escape in normal mode stays inert.
    visual_cancel,
    search_forward,
    search_next,
    search_prev,
    open_editor,
    command_line,
    /// Hide the chrome and give the body the whole pane.
    toggle_zen,
};

/// Which modes a binding is live in. Motions are live in both, which is what
/// makes visual select "normal mode plus an anchor" rather than a second
/// dispatch table that has to be kept in step with the first.
pub const Modes = packed struct(u8) {
    normal: bool = false,
    visual: bool = false,
    _pad: u6 = 0,

    pub const both: Modes = .{ .normal = true, .visual = true };
    pub const normal_only: Modes = .{ .normal = true };
    pub const visual_only: Modes = .{ .visual = true };

    pub fn has(self: Modes, mode: event.Mode) bool {
        return switch (mode) {
            .normal => self.normal,
            .visual => self.visual,
            // The prompt modes never reach the keymap: `prompt.zig` takes the
            // keys, because they are text rather than actions.
            else => false,
        };
    }
};

pub const Chord = struct {
    cp: u21,
    ctrl: bool = false,

    pub fn matches(self: Chord, key: event.Key) bool {
        return self.cp == key.codepoint and self.ctrl == key.mods.ctrl;
    }
};

pub const Binding = struct {
    chords: []const Chord,
    command: Command,
    modes: Modes = Modes.both,
    /// Shown in the status-line hint strip. Null keeps a binding working but
    /// unadvertised, which is how aliases stay out of an already tight row.
    hint: ?[]const u8 = null,
};

fn c(cp: u21) Chord {
    return .{ .cp = cp };
}

fn ctrl(cp: u21) Chord {
    return .{ .cp = cp, .ctrl = true };
}

/// The leader. Named once so rebinding it is one edit rather than a sweep over
/// every sequence that starts with it. Space is unbound on its own and must
/// stay that way: `feed` resolves an exact match as soon as it finds one, so a
/// bare-Space binding would shadow every `<leader>x` sequence behind it.
pub const leader: Chord = c(' ');

/// The v0.1 set. Only bindings that do something are listed: a hint strip that
/// advertises keys the build does not implement is worse than a shorter one.
pub const default_bindings: []const Binding = &.{
    .{ .chords = &.{c('j')}, .command = .line_down, .hint = "j k move" },
    .{ .chords = &.{c('k')}, .command = .line_up },
    .{ .chords = &.{ctrl('d')}, .command = .page_down },
    .{ .chords = &.{ctrl('u')}, .command = .page_up },
    .{ .chords = &.{ c('g'), c('g') }, .command = .top },
    .{ .chords = &.{c('G')}, .command = .bottom },
    .{ .chords = &.{ c(']'), c('h') }, .command = .next_hunk, .hint = "]h [h hunk" },
    .{ .chords = &.{ c('['), c('h') }, .command = .prev_hunk },
    .{ .chords = &.{ c(']'), c('f') }, .command = .next_file, .hint = "]f [f file" },
    .{ .chords = &.{ c('['), c('f') }, .command = .prev_file },
    .{ .chords = &.{ leader, c('n'), c('f') }, .command = .next_file },
    .{ .chords = &.{ leader, c('p'), c('f') }, .command = .prev_file },
    .{ .chords = &.{ c('z'), c('z') }, .command = .center },
    .{ .chords = &.{c('/')}, .command = .search_forward, .hint = "/ search" },
    .{ .chords = &.{c('n')}, .command = .search_next },
    .{ .chords = &.{c('N')}, .command = .search_prev },
    .{ .chords = &.{c('V')}, .command = .visual_toggle, .hint = "V select" },
    .{ .chords = &.{c(event.code.escape)}, .command = .visual_cancel, .modes = Modes.visual_only, .hint = "Esc cancel" },
    .{ .chords = &.{c('e')}, .command = .open_editor, .hint = "e edit" },
    .{ .chords = &.{c(event.code.tab)}, .command = .toggle_zen },
    .{ .chords = &.{c(':')}, .command = .command_line },
    .{ .chords = &.{ctrl('l')}, .command = .refresh },
    .{ .chords = &.{c('q')}, .command = .quit, .modes = Modes.normal_only, .hint = "q quit" },
};

pub const Match = union(enum) {
    /// The sequence is complete.
    command: Command,
    /// A prefix of at least one binding: keep collecting.
    pending,
    /// Nothing can match. The caller drops the sequence.
    none,
};

/// Sequence matcher. Holds the keys typed so far towards a binding.
pub const Keymap = struct {
    bindings: []const Binding = default_bindings,
    pending: [max_sequence]event.Key = undefined,
    len: usize = 0,

    pub const max_sequence = 4;

    pub fn reset(self: *Keymap) void {
        self.len = 0;
    }

    /// Feeds one key for `mode`. Resolving or failing both clear the pending
    /// sequence, so a mistyped prefix never leaves the next keystroke
    /// stranded. Bindings not live in `mode` are invisible to the match,
    /// including as prefixes - otherwise a key bound only in visual mode would
    /// swallow the next keystroke in normal mode.
    pub fn feed(self: *Keymap, key: event.Key, mode: event.Mode) Match {
        if (self.len == max_sequence) self.len = 0;
        self.pending[self.len] = key;
        self.len += 1;
        const typed = self.pending[0..self.len];

        var prefix = false;
        for (self.bindings) |b| {
            if (!b.modes.has(mode)) continue;
            if (b.chords.len < typed.len) continue;
            var i: usize = 0;
            while (i < typed.len) : (i += 1) {
                if (!b.chords[i].matches(typed[i])) break;
            } else {
                if (b.chords.len == typed.len) {
                    self.len = 0;
                    return .{ .command = b.command };
                }
                prefix = true;
            }
        }
        if (prefix) return .pending;
        self.len = 0;
        return .none;
    }
};

/// The hint strip, built from the bindings themselves so it cannot drift from
/// what the keys actually do. Written into `buf`, which the caller owns - in
/// practice the frame arena.
pub fn hints(bindings: []const Binding, mode: event.Mode, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bindings) |b| {
        if (!b.modes.has(mode)) continue;
        const h = b.hint orelse continue;
        const sep: usize = if (n == 0) 0 else 2;
        if (n + sep + h.len > buf.len) break;
        if (sep != 0) {
            buf[n] = ' ';
            buf[n + 1] = ' ';
            n += 2;
        }
        @memcpy(buf[n .. n + h.len], h);
        n += h.len;
    }
    return buf[0..n];
}

const testing = std.testing;

fn tap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{} };
}

fn ctrlTap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

test "a single-key binding resolves immediately" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
    try testing.expectEqual(@as(usize, 0), km.len);
}

test "a two-key sequence waits for its second key" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']'), .normal) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h'), .normal).command);
}

test "an unknown second key drops the sequence without stranding the next" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']'), .normal) == .pending);
    try testing.expect(km.feed(tap('x'), .normal) == .none);
    // The dropped prefix must not swallow what follows.
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "a leader sequence resolves on its last key" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('n'), .normal) == .pending);
    try testing.expectEqual(Command.next_file, km.feed(tap('f'), .normal).command);

    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('p'), .normal) == .pending);
    try testing.expectEqual(Command.prev_file, km.feed(tap('f'), .normal).command);
}

test "the leader is never bound on its own" {
    // `feed` returns the first exact match it finds, so a bare-leader binding
    // would shadow every sequence behind it. Pending is what proves it is a
    // prefix and nothing else.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    km.reset();
    try testing.expect(km.feed(tap(' '), .visual) == .pending);
}

test "a key under the leader keeps its own meaning outside it" {
    // `n` is search_next; it must not be eaten by `<leader>nf`.
    var km: Keymap = .{};
    try testing.expectEqual(Command.search_next, km.feed(tap('n'), .normal).command);
    // And an unknown key after the leader drops without stranding the next.
    try testing.expect(km.feed(tap(' '), .normal) == .pending);
    try testing.expect(km.feed(tap('x'), .normal) == .none);
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "leader motions are live in visual mode like the bracket forms" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(' '), .visual) == .pending);
    try testing.expect(km.feed(tap('n'), .visual) == .pending);
    try testing.expectEqual(Command.next_file, km.feed(tap('f'), .visual).command);
}

test "ctrl is part of the match, not ignored" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.page_down, km.feed(ctrlTap('d'), .normal).command);
    // Plain 'd' is not bound, and must not fall through to Ctrl-d.
    try testing.expect(km.feed(tap('d'), .normal) == .none);
}

test "? is reserved for the help popup, not bound to anything" {
    // FEATURES.md 4.4: reverse search was dropped as redundant with `/` plus
    // `N`, so nothing may claim `?` before the help overlay does.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap('?'), .normal) == .none);
    km.reset();
    try testing.expect(km.feed(tap('?'), .visual) == .none);
}

test "case is significant" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.bottom, km.feed(tap('G'), .normal).command);
    try testing.expect(km.feed(tap('g'), .normal) == .pending);
    try testing.expectEqual(Command.top, km.feed(tap('g'), .normal).command);
    // And it separates `n` from `N`, which search relies on.
    try testing.expectEqual(Command.search_next, km.feed(tap('n'), .normal).command);
    try testing.expectEqual(Command.search_prev, km.feed(tap('N'), .normal).command);
}

test "every command is reachable from the default bindings" {
    // A command with no binding is dead code that looks alive.
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        const want: Command = @enumFromInt(f.value);
        var found = false;
        for (default_bindings) |b| {
            if (b.command == want) found = true;
        }
        try testing.expect(found);
    }
}

test "every binding is live in at least one mode" {
    // An empty mode set is a binding that can never fire, and nothing else in
    // the file would ever say so.
    for (default_bindings) |b| {
        try testing.expect(b.modes.normal or b.modes.visual);
    }
}

test "motions work in visual mode, so selecting is moving with an anchor" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .visual).command);
    try testing.expect(km.feed(tap(']'), .visual) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h'), .visual).command);
}

test "a visual-only binding is invisible in normal mode, prefix included" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.visual_cancel, km.feed(tap(event.code.escape), .visual).command);
    try testing.expect(km.feed(tap(event.code.escape), .normal) == .none);
    // Having been dropped, it does not strand the next keystroke either.
    try testing.expectEqual(Command.line_down, km.feed(tap('j'), .normal).command);
}

test "quit is normal-only, so q mid-selection does not exit" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.quit, km.feed(tap('q'), .normal).command);
    try testing.expect(km.feed(tap('q'), .visual) == .none);
}

test "the prompt modes reach no binding at all" {
    // While `/foo` is being typed, `j` is the letter j.
    var km: Keymap = .{};
    try testing.expect(km.feed(tap('j'), .command) == .none);
    try testing.expect(km.feed(tap('q'), .finder) == .none);
}

test "hints come from the bindings and fit the width given" {
    var buf: [80]u8 = undefined;
    const h = hints(default_bindings, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, h, "j k move") != null);
    try testing.expect(std.mem.indexOf(u8, h, "q quit") != null);

    // A narrow strip truncates on a boundary rather than overrunning.
    var tiny: [10]u8 = undefined;
    const t = hints(default_bindings, .normal, &tiny);
    try testing.expect(t.len <= tiny.len);
    try testing.expectEqualStrings("j k move", t);
}

test "the hint strip advertises only what the current mode can do" {
    var buf: [160]u8 = undefined;
    const normal = hints(default_bindings, .normal, &buf);
    try testing.expect(std.mem.indexOf(u8, normal, "Esc cancel") == null);
    try testing.expect(std.mem.indexOf(u8, normal, "q quit") != null);

    var buf2: [160]u8 = undefined;
    const visual = hints(default_bindings, .visual, &buf2);
    try testing.expect(std.mem.indexOf(u8, visual, "Esc cancel") != null);
    // `q` does not quit from visual mode, so the strip must not claim it does.
    try testing.expect(std.mem.indexOf(u8, visual, "q quit") == null);
}
