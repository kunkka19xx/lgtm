// SPDX-License-Identifier: Apache-2.0
//
// The `?` overlay's state: the filter, the selected row, and the grid the last
// frame drew. Its own module rather than five fields on `App` because it is a
// small state machine with rules of its own - a narrowed list starts at the
// top, a selection is clamped against the filter it is drawn from, sideways
// movement is by a whole column - and those rules are worth reading in one
// place.
//
// What it deliberately does not own: the keys. Navigation inside the popup is
// a keymap binding like any other, so `App` matches the key
// and calls the move; this file never sees a chord.

const std = @import("std");
const Allocator = std.mem.Allocator;

const event = @import("../core/event.zig");
const keymap = @import("keymap.zig");
const keytext = @import("keytext.zig");
const prompt_mod = @import("prompt.zig");
const render = @import("render.zig");

/// What a key did to the popup, for the caller that owns `Mode`.
pub const Fed = enum { stay, close };

pub const Help = struct {
    /// The popup's own filter line, not the bottom-line prompt: opening `?`
    /// must not disturb a `/` query the user still wants.
    filter: prompt_mod.Prompt = .{},
    /// An index into the *filtered* list. A selection that survives a
    /// narrowing points at a different row than the one the user was looking
    /// at, so every narrowing resets it.
    index: usize = 0,
    /// The tab the list is narrowed to. Ignored while the filter has text in
    /// it: `shown` is what the list is actually drawn from, and finding a key
    /// must not require knowing which tab it was filed under.
    group: keymap.Group = .move,
    /// The mode `?` was opened from. It is both the mode to return to and the
    /// mode whose keys the overlay lists: the overlay describes the review,
    /// not itself.
    from: event.Mode = .normal,

    pub fn open(self: *Help, from: event.Mode) void {
        self.from = from;
        self.filter.start(.help_filter);
        self.index = 0;
        // Reopening lands on the first tab rather than wherever the last
        // reader left it: `?` is asked in order to start looking, and a
        // remembered tab makes the same key show a different screen.
        self.group = .move;
    }

    /// The group the list is narrowed to this frame, or null for all of them.
    /// A filter cuts across every tab, so the tabs stop narrowing while one
    /// is being typed.
    pub fn shown(self: Help) ?keymap.Group {
        return if (self.filter.text().len == 0) self.group else null;
    }

    pub fn close(self: *Help) void {
        self.filter.close();
    }

    /// Text typed into the popup is filter text, never a command - the same
    /// rule the bottom-line prompt follows. Escape closes, and so does
    /// backspacing past the start of an empty query, which is what
    /// `prompt.zig` already means by cancel.
    pub fn feed(self: *Help, key: event.Key) Fed {
        return switch (self.filter.feed(key)) {
            // A narrowed list is a different list: start at the top of it.
            .typing => blk: {
                self.index = 0;
                break :blk .stay;
            },
            .submit, .cancel => .close,
        };
    }

    /// One row, counted against the same filter the popup is drawn from, so the
    /// selection can never sit past the end of what is on screen.
    pub fn move(self: *Help, bindings: []const keymap.Binding, delta: i32) void {
        const n = keytext.helpCount(bindings, self.from, self.shown(), self.filter.text());
        if (n == 0) {
            self.index = 0;
            return;
        }
        // Wraps at both ends. A list you step through with Tab should come
        // back round rather than stop dead, and the review's own `]h`/`[h`
        // already read that way.
        const len: i64 = @intCast(n);
        // `@mod`, not `%`: the result must be non-negative so a step up from
        // the first row lands on the last.
        self.index = @intCast(@mod(@as(i64, @intCast(self.index)) + delta, len));
    }

    /// Sideways is the next tab, wrapping.
    ///
    /// It used to be one column of the grid, which has been one column wide
    /// since the two-column layout was rejected for pushing the box past most
    /// panes - so `H` and `L` were bound to a movement that could not happen,
    /// and the footer advertised them anyway. The tabs give them something to
    /// do, and cost no new key and no row of the box.
    pub fn moveGroup(self: *Help, delta: i32) void {
        self.group = self.group.step(delta);
        // A different tab is a different list: start at the top of it.
        self.index = 0;
    }

    /// The popup's contents for one frame, or null when it is not open. Needs
    /// the frame arena, which is why it is not part of the review's `View`,
    /// and is drawn over both the review and the empty screen.
    pub fn view(
        self: *Help,
        mode: event.Mode,
        bindings: []const keymap.Binding,
        arena: Allocator,
    ) Allocator.Error!?render.HelpView {
        if (mode != .help) return null;
        const filter = self.filter.text();
        return .{
            .entries = try keytext.helpEntries(bindings, self.from, self.shown(), filter, arena),
            .query = filter,
            .index = self.index,
            // The popup's own keys, along the bottom border: those live in
            // `.help`, not in the mode being described.
            .keys = try keytext.helpEntries(bindings, .help, null, "", arena),
            // The strip marks the tab the list came from. Null while a filter
            // is being typed, which is what says it is searching all of them.
            .group = self.shown(),
        };
    }
};

const testing = std.testing;

test "the selection wraps within the tab it is drawn from" {
    var h: Help = .{};
    h.open(.normal);
    // Counted against the tab the list is actually showing, which is what
    // the selection is clamped against.
    const n = keytext.helpCount(keymap.default_bindings, .normal, h.shown(), "");

    // Up from the first row lands on the last: Tab and Shift-Tab are a cycle,
    // not two keys that stop working at the edges.
    h.move(keymap.default_bindings, -1);
    try testing.expectEqual(n - 1, h.index);
    h.move(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 0), h.index);
}

test "a filter that matches nothing leaves nothing to select" {
    var h: Help = .{};
    h.open(.normal);
    _ = h.feed(.{ .codepoint = 'z', .mods = .{} });
    _ = h.feed(.{ .codepoint = 'z', .mods = .{} });
    _ = h.feed(.{ .codepoint = 'q', .mods = .{} });
    try testing.expectEqual(@as(usize, 0), keytext.helpCount(keymap.default_bindings, .normal, null, h.filter.text()));
    h.move(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 0), h.index);
}

test "sideways is the next tab, and it wraps" {
    var h: Help = .{};
    h.open(.normal);
    try testing.expectEqual(keymap.Group.move, h.group);

    h.moveGroup(1);
    try testing.expectEqual(keymap.Group.jump, h.group);

    // A different tab is a different list, so the selection starts at its top
    // rather than pointing into the middle of a list that is no longer there.
    h.index = 5;
    h.moveGroup(1);
    try testing.expectEqual(@as(usize, 0), h.index);

    // Back past the first lands on the last: the tabs are a cycle, the way
    // `]h` and `[h` already are.
    h.group = .move;
    h.moveGroup(-1);
    try testing.expectEqual(keymap.Group.view, h.group);
    h.moveGroup(1);
    try testing.expectEqual(keymap.Group.move, h.group);
}

test "a tab narrows the list, and a filter cuts across every tab" {
    var h: Help = .{};
    h.open(.normal);
    const bindings = keymap.default_bindings;

    // Narrowed to one tab, the list is a fraction of the whole.
    const all = keytext.helpCount(bindings, .normal, null, "");
    const moves = keytext.helpCount(bindings, .normal, .move, "");
    try testing.expect(moves > 0);
    try testing.expect(moves < all);

    // Every entry lands in exactly one tab, so the tabs partition the list
    // rather than sampling it: nothing is listed twice and nothing is lost.
    var sum: usize = 0;
    for (std.enums.values(keymap.Group)) |g| sum += keytext.helpCount(bindings, .normal, g, "");
    try testing.expectEqual(all, sum);

    // Empty filter follows the tab; any filter at all searches all of them,
    // because finding a key must not require knowing where it was filed.
    try testing.expectEqual(keymap.Group.move, h.shown().?);
    _ = h.filter.feed(.{ .codepoint = 'f', .mods = .{} });
    try testing.expect(h.shown() == null);
}

test "backspacing past the start closes, and typing does not" {
    var h: Help = .{};
    h.open(.visual);
    try testing.expectEqual(Fed.stay, h.feed(.{ .codepoint = 'f', .mods = .{} }));
    try testing.expectEqual(Fed.stay, h.feed(.{ .codepoint = event.code.backspace, .mods = .{} }));
    try testing.expectEqual(Fed.close, h.feed(.{ .codepoint = event.code.backspace, .mods = .{} }));
    try testing.expectEqual(Fed.close, h.feed(.{ .codepoint = event.code.escape, .mods = .{} }));

    // The mode it was opened from is what it lists and what it returns to.
    try testing.expectEqual(event.Mode.visual, h.from);
}
