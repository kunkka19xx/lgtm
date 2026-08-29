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
// a keymap binding like any other (FEATURES.md 4.4), so `App` matches the key
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
    /// The grid the last frame actually drew, written back by the renderer.
    /// Sideways movement is by a whole column, and only the renderer knows how
    /// tall a column came out - it depends on the pane, the filter and the
    /// widest description.
    layout: render.HelpLayout = .{},
    /// The mode `?` was opened from. It is both the mode to return to and the
    /// mode whose keys the overlay lists: the overlay describes the review,
    /// not itself.
    from: event.Mode = .normal,

    pub fn open(self: *Help, from: event.Mode) void {
        self.from = from;
        self.filter.start(.help_filter);
        self.index = 0;
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
        const n = keytext.helpCount(bindings, self.from, self.filter.text());
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

    /// The same step, stopping at the ends. What a page wants: wrapping a
    /// screenful lands nowhere the eye was looking.
    fn moveClamped(self: *Help, bindings: []const keymap.Binding, delta: i32) void {
        const n = keytext.helpCount(bindings, self.from, self.filter.text());
        if (n == 0) {
            self.index = 0;
            return;
        }
        const i = @as(i64, @intCast(self.index)) + delta;
        self.index = if (i < 0) 0 else if (i >= @as(i64, @intCast(n))) n - 1 else @intCast(i);
    }

    /// One column sideways. Clamping rather than wrapping at the edges: the
    /// last column is usually short, so wrapping would land on a different row
    /// than the one the eye came from.
    pub fn moveColumn(self: *Help, bindings: []const keymap.Binding, delta: i32) void {
        const per: i32 = @intCast(@min(@max(self.layout.per, 1), 1000));
        self.moveClamped(bindings, delta * per);
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
            .entries = try keytext.helpEntries(bindings, self.from, filter, arena),
            .query = filter,
            .index = self.index,
            // The popup's own keys, along the bottom border: those live in
            // `.help`, not in the mode being described.
            .keys = try keytext.helpEntries(bindings, .help, "", arena),
            .layout = &self.layout,
        };
    }
};

const testing = std.testing;

test "the selection wraps, but a page stops at the ends" {
    var h: Help = .{};
    h.open(.normal);
    const n = keytext.helpCount(keymap.default_bindings, .normal, "");

    // Up from the first row lands on the last: Tab and Shift-Tab are a cycle,
    // not two keys that stop working at the edges.
    h.move(keymap.default_bindings, -1);
    try testing.expectEqual(n - 1, h.index);
    h.move(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 0), h.index);

    // A page is clamped, because wrapping a screenful lands nowhere the eye
    // was looking.
    h.moveColumn(keymap.default_bindings, -1);
    try testing.expectEqual(@as(usize, 0), h.index);
    h.moveColumn(keymap.default_bindings, 1000);
    try testing.expectEqual(n - 1, h.index);
}

test "a filter that matches nothing leaves nothing to select" {
    var h: Help = .{};
    h.open(.normal);
    _ = h.feed(.{ .codepoint = 'z', .mods = .{} });
    _ = h.feed(.{ .codepoint = 'z', .mods = .{} });
    _ = h.feed(.{ .codepoint = 'q', .mods = .{} });
    try testing.expectEqual(@as(usize, 0), keytext.helpCount(keymap.default_bindings, .normal, h.filter.text()));
    h.move(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 0), h.index);
}

test "a column step is a whole column of the grid the frame drew" {
    var h: Help = .{};
    h.open(.normal);
    h.layout = .{ .cols = 2, .per = 11 };
    h.moveColumn(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 11), h.index);

    // A layout the renderer has not written yet moves by one row rather than
    // by zero - a first keypress that does nothing reads as a dropped key.
    var fresh: Help = .{};
    fresh.open(.normal);
    fresh.moveColumn(keymap.default_bindings, 1);
    try testing.expectEqual(@as(usize, 1), fresh.index);
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
