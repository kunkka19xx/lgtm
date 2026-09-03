// SPDX-License-Identifier: Apache-2.0
//
// The compose box: the message on its way to the agent, while it is still
// being written.
//
// Every send used to be a fixed string - the reference, or the reference plus
// one of four canned questions - and a fixed string is the wrong shape for the
// thing being said. What a reviewer wants to tell an agent is "why this
// approach?" *and then two sentences of context*, and the second half had no
// home. This is that home.
//
// Text entry, not actions, so it does not go through `keymap.zig` for the same
// reason `prompt.zig` does not: inside a text box `j` is the letter j. What is
// here is a byte buffer, a cursor, and the editing rules - all pure, all
// testable without a terminal. `popup.zig` draws it and `app.zig` decides when
// it opens.
//
// Fixed capacity and no allocator, again like the prompt: a compose box that
// can fail to allocate is a compose box that can eat a keystroke halfway
// through a sentence.
//
// Built to be reused. v0.2's review notes are the same box with a different
// destination (SPEC.md 6.5), which is why nothing here knows about the bridge,
// the diff, or what the text is for.

const std = @import("std");
const event = @import("../core/event.zig");

/// Room for a paragraph. Far past any reference plus a question, and still
/// small enough to sit in the app struct rather than on the heap.
pub const max_bytes = 4096;

pub const Result = enum {
    /// The text changed, or did not; either way the box stays open.
    typing,
    /// Enter: the caller reads `text()`, flattens it, and sends it.
    submit,
    /// Escape: the message is abandoned.
    cancel,
    /// `Ctrl-i`: the caller opens the preset list.
    presets,
};

pub const Compose = struct {
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    /// Byte offset of the caret, always on a UTF-8 boundary and always
    /// `<= len`. Bytes rather than columns, because that is what an insert
    /// needs and hard rule 3 says byte offsets internally.
    cursor: usize = 0,
    open: bool = false,

    /// Opens the box seeded with `text`, caret at the end - which is where
    /// someone about to add a sentence wants it. Nothing is selected and
    /// nothing is pending deletion: the seed is a starting point, not a
    /// placeholder that vanishes on the first keystroke.
    pub fn start(self: *Compose, seed: []const u8) void {
        self.len = @min(seed.len, self.buf.len);
        @memcpy(self.buf[0..self.len], seed[0..self.len]);
        self.cursor = self.len;
        self.open = true;
    }

    pub fn close(self: *Compose) void {
        self.open = false;
        self.len = 0;
        self.cursor = 0;
    }

    pub fn text(self: *const Compose) []const u8 {
        return self.buf[0..self.len];
    }

    /// Inserts at the caret, moving the caret to the end of what was
    /// inserted. Nothing is ever removed to make room: a preset dropped into
    /// the middle of a half-written sentence leaves both halves standing.
    ///
    /// Silently takes as much as fits rather than refusing the lot - at 4 KB
    /// the alternative is a keystroke that does nothing and says nothing.
    pub fn insert(self: *Compose, s: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(s.len, room);
        if (n == 0) return;

        // The tail first, or it is overwritten by what is being inserted.
        std.mem.copyBackwards(u8, self.buf[self.cursor + n ..][0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
        @memcpy(self.buf[self.cursor..][0..n], s[0..n]);
        self.len += n;
        self.cursor += n;
    }

    /// Deletes the grapheme before the caret. A whole codepoint, not a byte:
    /// backspacing over an emoji should not leave three bytes of rubble.
    pub fn backspace(self: *Compose) void {
        if (self.cursor == 0) return;
        const from = prevBoundary(self.buf[0..self.len], self.cursor);
        const n = self.cursor - from;
        std.mem.copyForwards(u8, self.buf[from..], self.buf[self.cursor..self.len]);
        self.len -= n;
        self.cursor = from;
    }

    pub fn deleteForward(self: *Compose) void {
        if (self.cursor >= self.len) return;
        const to = nextBoundary(self.buf[0..self.len], self.cursor);
        const n = to - self.cursor;
        std.mem.copyForwards(u8, self.buf[self.cursor..], self.buf[to..self.len]);
        self.len -= n;
    }

    /// `Ctrl-w`: the word before the caret, and the run of spaces before it.
    pub fn deleteWordBack(self: *Compose) void {
        var at = self.cursor;
        while (at > 0 and isSpace(self.buf[at - 1])) at -= 1;
        while (at > 0 and !isSpace(self.buf[at - 1])) at -= 1;
        const n = self.cursor - at;
        if (n == 0) return;
        std.mem.copyForwards(u8, self.buf[at..], self.buf[self.cursor..self.len]);
        self.len -= n;
        self.cursor = at;
    }

    /// `Ctrl-u`: everything before the caret, which is readline's rule and
    /// the one people expect from a terminal input.
    pub fn deleteToStart(self: *Compose) void {
        if (self.cursor == 0) return;
        std.mem.copyForwards(u8, self.buf[0..], self.buf[self.cursor..self.len]);
        self.len -= self.cursor;
        self.cursor = 0;
    }

    pub fn left(self: *Compose) void {
        self.cursor = prevBoundary(self.buf[0..self.len], self.cursor);
    }

    pub fn right(self: *Compose) void {
        self.cursor = nextBoundary(self.buf[0..self.len], self.cursor);
    }

    pub fn home(self: *Compose) void {
        self.cursor = 0;
    }

    pub fn end(self: *Compose) void {
        self.cursor = self.len;
    }

    /// One keystroke. The bindings are readline's, because this is a terminal
    /// input box and that is what a terminal input box answers to everywhere
    /// else the user types.
    pub fn feed(self: *Compose, key: event.Key) Result {
        const cp = key.codepoint;
        if (key.mods.ctrl) {
            switch (cp) {
                // Terminals send 0x09 for both Tab and Ctrl-i; they are the
                // same keystroke here, and nothing else in the box wants Tab.
                'i', event.code.tab => return .presets,
                // A literal newline, because Enter is spoken for. Flattened on
                // the way out - see `flatten`.
                'j' => self.insert("\n"),
                'a' => self.home(),
                'e' => self.end(),
                'u' => self.deleteToStart(),
                'w' => self.deleteWordBack(),
                'd' => self.deleteForward(),
                'b' => self.left(),
                'f' => self.right(),
                else => {},
            }
            return .typing;
        }

        switch (cp) {
            event.code.enter => return .submit,
            event.code.escape => return .cancel,
            event.code.backspace => self.backspace(),
            event.code.tab => return .presets,
            event.code.left => self.left(),
            event.code.right => self.right(),
            // Up and down are the ends of the text: the box wraps rather than
            // holding lines, so there is no row above to go to.
            event.code.up => self.home(),
            event.code.down => self.end(),
            else => {
                // Control bytes that are not bound are dropped rather than
                // inserted: a stray 0x07 in a payload is invisible here and
                // arrives at the agent as noise.
                if (cp < 0x20) return .typing;
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8) catch return .typing;
                self.insert(utf8[0..n]);
            },
        }
        return .typing;
    }
};

/// The message as the bridge takes it: one line, no newline anywhere.
///
/// Hard rule 1 is the whole reason this exists - in `tmux send-keys` a newline
/// is Enter, and Enter submits the agent's half-written message. The box lets
/// newlines be typed because a paragraph is easier to write with them, and
/// this is where that convenience is paid for: each run of whitespace
/// containing a newline becomes a single space.
///
/// Lossy on purpose, and the box says so in its footer while any newline is
/// present, because a payload that differs from what was typed should not be
/// a surprise discovered in the agent's input box.
pub fn flatten(out: []u8, text: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch != '\n' and ch != '\r') {
            if (n < out.len) {
                out[n] = ch;
                n += 1;
            }
            i += 1;
            continue;
        }
        // The whole run of whitespace around the break collapses, so a line
        // ending in a space does not become a double space.
        while (n > 0 and isSpace(out[n - 1])) n -= 1;
        while (i < text.len and isSpace(text[i])) i += 1;
        if (n > 0 and i < text.len and n < out.len) {
            out[n] = ' ';
            n += 1;
        }
    }
    while (n > 0 and isSpace(out[n - 1])) n -= 1;
    return out[0..n];
}

/// Whether flattening would change anything, so the box can say so before the
/// user finds out from the agent.
pub fn hasBreak(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "\n\r") != null;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn prevBoundary(text: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn nextBoundary(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    var i = at + 1;
    while (i < text.len and text[i] & 0xc0 == 0x80) i += 1;
    return i;
}

const testing = std.testing;

fn tap(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{} };
}

fn ctrl(cp: u21) event.Key {
    return .{ .codepoint = cp, .mods = .{ .ctrl = true } };
}

test "the box opens on the seed with the caret past it" {
    var c: Compose = .{};
    c.start("#1 auth.zig:47 - why this approach?");
    try testing.expect(c.open);
    try testing.expectEqualStrings("#1 auth.zig:47 - why this approach?", c.text());
    // At the end, which is where someone about to add a sentence wants it.
    try testing.expectEqual(c.text().len, c.cursor);
}

test "a preset lands at the caret and deletes nothing" {
    // The rule the user asked for by name: whatever is being inserted goes in
    // at the cursor and both halves of the sentence survive it.
    var c: Compose = .{};
    c.start("#1 auth.zig:47 - and then?");
    c.home();
    var i: usize = 0;
    while (i < 15) : (i += 1) c.right(); // just past `#1 auth.zig:47 `

    c.insert("why this approach? ");
    try testing.expectEqualStrings("#1 auth.zig:47 why this approach? - and then?", c.text());
    // The caret follows the insert, so typing continues where it left off.
    try testing.expectEqual(@as(usize, 34), c.cursor);
}

test "editing keys behave the way a terminal input box does" {
    var c: Compose = .{};
    c.start("hello world");

    _ = c.feed(ctrl('w'));
    try testing.expectEqualStrings("hello ", c.text());

    _ = c.feed(tap('t'));
    _ = c.feed(tap('h'));
    _ = c.feed(tap('e'));
    _ = c.feed(tap('r'));
    _ = c.feed(tap('e'));
    try testing.expectEqualStrings("hello there", c.text());

    _ = c.feed(ctrl('a'));
    try testing.expectEqual(@as(usize, 0), c.cursor);
    _ = c.feed(ctrl('d'));
    try testing.expectEqualStrings("ello there", c.text());

    _ = c.feed(ctrl('e'));
    _ = c.feed(tap(event.code.backspace));
    try testing.expectEqualStrings("ello ther", c.text());

    _ = c.feed(ctrl('u'));
    try testing.expectEqualStrings("", c.text());
}

test "enter submits, escape abandons, ctrl-i asks for the presets" {
    var c: Compose = .{};
    c.start("x");
    try testing.expectEqual(Result.submit, c.feed(tap(event.code.enter)));
    try testing.expectEqual(Result.cancel, c.feed(tap(event.code.escape)));
    try testing.expectEqual(Result.presets, c.feed(ctrl('i')));
    // Tab is the same keystroke: terminals send 0x09 for both.
    try testing.expectEqual(Result.presets, c.feed(tap(event.code.tab)));
}

test "a newline is typed with ctrl-j and flattened on the way out" {
    var c: Compose = .{};
    c.start("check the token");
    _ = c.feed(ctrl('j'));
    _ = c.feed(tap('o'));
    try testing.expectEqualStrings("check the token\no", c.text());
    try testing.expect(hasBreak(c.text()));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("check the token o", flatten(&buf, c.text()));
}

test "flattening never leaves a newline, whatever it is given" {
    var buf: [128]u8 = undefined;

    // Runs of whitespace around a break collapse to exactly one space.
    try testing.expectEqualStrings("a b", flatten(&buf, "a\nb"));
    try testing.expectEqualStrings("a b", flatten(&buf, "a \n b"));
    try testing.expectEqualStrings("a b", flatten(&buf, "a\n\n\nb"));
    try testing.expectEqualStrings("a b", flatten(&buf, "a  \r\n  b"));
    // Leading and trailing breaks leave no edge whitespace behind.
    try testing.expectEqualStrings("a", flatten(&buf, "\na\n"));
    try testing.expectEqualStrings("", flatten(&buf, "\n\n"));
    try testing.expectEqualStrings("", flatten(&buf, ""));

    // Hard rule 1, stated as the property rather than as examples.
    const nasty = "one\ntwo\r\nthree\n\n\nfour   \n";
    const out = flatten(&buf, nasty);
    try testing.expect(std.mem.indexOfAny(u8, out, "\n\r") == null);
    try testing.expectEqualStrings("one two three four", out);
}

test "multi-byte text is not cut in half by a caret move" {
    var c: Compose = .{};
    c.start("héllo");
    c.home();
    c.right(); // past `h`
    c.right(); // past `é`, which is two bytes
    try testing.expectEqual(@as(usize, 3), c.cursor);
    c.left();
    try testing.expectEqual(@as(usize, 1), c.cursor);

    c.end();
    _ = c.feed(tap(event.code.backspace));
    _ = c.feed(tap(event.code.backspace));
    _ = c.feed(tap(event.code.backspace));
    _ = c.feed(tap(event.code.backspace));
    try testing.expectEqualStrings("h", c.text());
}

test "a full buffer takes what fits rather than trapping" {
    var c: Compose = .{};
    var big: [max_bytes + 100]u8 = undefined;
    @memset(&big, 'x');
    c.start(&big);
    try testing.expectEqual(@as(usize, max_bytes), c.text().len);

    // And an insert into a full box is a no-op, not a corruption.
    c.home();
    c.insert("more");
    try testing.expectEqual(@as(usize, max_bytes), c.text().len);
}
