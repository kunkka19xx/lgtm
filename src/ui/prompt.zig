// SPDX-License-Identifier: Apache-2.0
//
// The one-line input at the bottom of the screen: `/` and `?` search, `:`
// commands. Text entry, not actions - which is why it does not go through
// `keymap.zig`. The rule there is that every *action* is a named command so
// dispatch has no hardcoded keys; a prompt has no actions, only characters,
// backspace and a decision to submit or abandon. Keeping that here means
// dispatch still contains no keys, and the editing rules are testable without
// a terminal.
//
// Fixed capacity, no allocator. A search query longer than this line is not a
// query, and a prompt that can fail to allocate is a prompt that can eat a
// keystroke.

const std = @import("std");
const event = @import("../core/event.zig");

pub const max_bytes = 256;

/// What the prompt is collecting. The kind is fixed when it opens, because the
/// leading character is not part of the text.
pub const Kind = enum {
    search_forward,
    command,

    /// Drawn at column 0, and the only thing that tells the user which of the
    /// two they are in.
    pub fn prefix(self: Kind) []const u8 {
        return switch (self) {
            .search_forward => "/",
            .command => ":",
        };
    }
};

pub const Result = enum {
    /// The line changed, or did not; either way the prompt stays open.
    typing,
    /// Enter: the caller reads `text()` and acts on it.
    submit,
    /// Escape, or backspace over the leading character. The line is cleared.
    cancel,
};

pub const Prompt = struct {
    kind: Kind = .command,
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    open: bool = false,

    pub fn start(self: *Prompt, kind: Kind) void {
        self.kind = kind;
        self.len = 0;
        self.open = true;
    }

    pub fn close(self: *Prompt) void {
        self.open = false;
        self.len = 0;
    }

    pub fn text(self: *const Prompt) []const u8 {
        return self.buf[0..self.len];
    }

    /// Feeds one key. Returns what the caller should do about it.
    pub fn feed(self: *Prompt, key: event.Key) Result {
        switch (key.codepoint) {
            event.code.enter => return .submit,
            event.code.escape => {
                self.len = 0;
                return .cancel;
            },
            event.code.backspace => {
                // Backspacing past the prefix abandons the prompt, as in vim.
                // The alternative - a stuck empty prompt with no visible way
                // out - is the worse of the two surprises.
                if (self.len == 0) return .cancel;
                self.len = prevBoundary(self.buf[0..self.len]);
                return .typing;
            },
            'u' => if (key.mods.ctrl) {
                self.len = 0;
                return .typing;
            },
            'w' => if (key.mods.ctrl) {
                self.len = prevWord(self.buf[0..self.len]);
                return .typing;
            },
            else => {},
        }
        // Any other control chord is ignored rather than inserted: a stray
        // Ctrl-a should not put a 0x01 into a search query.
        if (key.mods.ctrl or key.mods.alt or key.mods.super) return .typing;
        if (key.codepoint < 0x20) return .typing;
        self.insert(key.codepoint);
        return .typing;
    }

    /// Silently drops the keystroke when full. Truncating mid-codepoint would
    /// put invalid UTF-8 on the screen, which vaxis draws as a replacement
    /// glyph and search would then never match.
    fn insert(self: *Prompt, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..n], tmp[0..n]);
        self.len += n;
    }
};

/// Start of the last codepoint in `s`. Deleting a byte at a time would leave a
/// half-encoded character behind on any non-ASCII query.
fn prevBoundary(s: []const u8) usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xc0 != 0x80) return i;
    }
    return 0;
}

/// Start of the last whitespace-delimited word, for Ctrl-w.
fn prevWord(s: []const u8) usize {
    var i = s.len;
    while (i > 0 and s[i - 1] == ' ') i -= 1;
    while (i > 0 and s[i - 1] != ' ') i -= 1;
    return i;
}

const testing = std.testing;

fn tap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{} };
}

fn ctrlTap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

test "typing accumulates and Enter submits" {
    var p: Prompt = .{};
    p.start(.search_forward);
    for ("todo") |ch| try testing.expectEqual(Result.typing, p.feed(tap(ch)));
    try testing.expectEqualStrings("todo", p.text());
    try testing.expectEqual(Result.submit, p.feed(tap(event.code.enter)));
    // Submit leaves the text intact: the caller reads it after.
    try testing.expectEqualStrings("todo", p.text());
}

test "escape cancels and clears" {
    var p: Prompt = .{};
    p.start(.command);
    _ = p.feed(tap('q'));
    try testing.expectEqual(Result.cancel, p.feed(tap(event.code.escape)));
    try testing.expectEqual(@as(usize, 0), p.text().len);
}

test "backspace deletes a codepoint, and past the prefix it cancels" {
    var p: Prompt = .{};
    p.start(.search_forward);
    // A three-byte glyph arrives as one key press and must leave in one too.
    _ = p.feed(tap('a'));
    _ = p.feed(tap('\u{4e2d}'));
    try testing.expectEqual(@as(usize, 4), p.text().len);
    _ = p.feed(tap(event.code.backspace));
    try testing.expectEqualStrings("a", p.text());
    _ = p.feed(tap(event.code.backspace));
    try testing.expectEqualStrings("", p.text());
    try testing.expectEqual(Result.cancel, p.feed(tap(event.code.backspace)));
}

test "control chords edit or are ignored, never inserted" {
    var p: Prompt = .{};
    p.start(.search_forward);
    for ("fn main") |ch| _ = p.feed(tap(ch));
    _ = p.feed(ctrlTap('w'));
    try testing.expectEqualStrings("fn ", p.text());
    _ = p.feed(ctrlTap('u'));
    try testing.expectEqualStrings("", p.text());

    // An unbound chord leaves no byte behind.
    for ("x") |ch| _ = p.feed(tap(ch));
    _ = p.feed(ctrlTap('a'));
    _ = p.feed(tap(0x01));
    try testing.expectEqualStrings("x", p.text());
}

test "a full line drops keystrokes rather than splitting a codepoint" {
    var p: Prompt = .{};
    p.start(.search_forward);
    var i: usize = 0;
    while (i < max_bytes + 10) : (i += 1) _ = p.feed(tap('a'));
    try testing.expectEqual(@as(usize, max_bytes), p.text().len);

    // One byte free, a two-byte glyph offered: it must not be halved.
    p.len = max_bytes - 1;
    _ = p.feed(tap('\u{00e9}'));
    try testing.expectEqual(@as(usize, max_bytes - 1), p.text().len);
    try testing.expect(std.unicode.utf8ValidateSlice(p.text()));
}

test "each kind draws its own prefix" {
    try testing.expectEqualStrings("/", Kind.search_forward.prefix());
    try testing.expectEqualStrings(":", Kind.command.prefix());
    // No `?` kind: reverse search was dropped as redundant with `/` plus `N`,
    // which is what frees the key for the help popup (FEATURES.md 4.4).
    try testing.expectEqual(@as(usize, 2), @typeInfo(Kind).@"enum".fields.len);
}
