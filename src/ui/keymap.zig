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
    .{ .chords = &.{ c('z'), c('z') }, .command = .center },
    .{ .chords = &.{ctrl('l')}, .command = .refresh },
    .{ .chords = &.{c('q')}, .command = .quit, .hint = "q quit" },
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

    /// Feeds one key. Resolving or failing both clear the pending sequence, so
    /// a mistyped prefix never leaves the next keystroke stranded.
    pub fn feed(self: *Keymap, key: event.Key) Match {
        if (self.len == max_sequence) self.len = 0;
        self.pending[self.len] = key;
        self.len += 1;
        const typed = self.pending[0..self.len];

        var prefix = false;
        for (self.bindings) |b| {
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
pub fn hints(bindings: []const Binding, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bindings) |b| {
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
    try testing.expectEqual(Command.line_down, km.feed(tap('j')).command);
    try testing.expectEqual(@as(usize, 0), km.len);
}

test "a two-key sequence waits for its second key" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']')) == .pending);
    try testing.expectEqual(Command.next_hunk, km.feed(tap('h')).command);
}

test "an unknown second key drops the sequence without stranding the next" {
    var km: Keymap = .{};
    try testing.expect(km.feed(tap(']')) == .pending);
    try testing.expect(km.feed(tap('x')) == .none);
    // The dropped prefix must not swallow what follows.
    try testing.expectEqual(Command.line_down, km.feed(tap('j')).command);
}

test "ctrl is part of the match, not ignored" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.page_down, km.feed(ctrlTap('d')).command);
    // Plain 'd' is not bound, and must not fall through to Ctrl-d.
    try testing.expect(km.feed(tap('d')) == .none);
}

test "case is significant" {
    var km: Keymap = .{};
    try testing.expectEqual(Command.bottom, km.feed(tap('G')).command);
    try testing.expect(km.feed(tap('g')) == .pending);
    try testing.expectEqual(Command.top, km.feed(tap('g')).command);
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

test "hints come from the bindings and fit the width given" {
    var buf: [80]u8 = undefined;
    const h = hints(default_bindings, &buf);
    try testing.expect(std.mem.indexOf(u8, h, "j k move") != null);
    try testing.expect(std.mem.indexOf(u8, h, "q quit") != null);

    // A narrow strip truncates on a boundary rather than overrunning.
    var tiny: [10]u8 = undefined;
    const t = hints(default_bindings, &tiny);
    try testing.expect(t.len <= tiny.len);
    try testing.expectEqualStrings("j k move", t);
}
