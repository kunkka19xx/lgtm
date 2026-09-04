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
// destination, which is why nothing here knows about the bridge,
// the diff, or what the text is for.

const std = @import("std");
const event = @import("../core/event.zig");
const motion = @import("motion.zig");

/// Room for a paragraph. Far past any reference plus a question, and still
/// small enough to sit in the app struct rather than on the heap.
pub const max_bytes = 4096;

/// What the box does with a key it did not consume.
///
/// Only one answer left. Submitting, cancelling, the preset list and the file
/// picker used to be values here, decided by keys spelled out in this file;
/// they are keymap commands now (`Modes.compose_only`), so the caller has
/// already dealt with them by the time a key arrives. What is left is text and
/// the vim motions over it, which is the one thing a box cannot delegate: in a
/// text box every printable key is data, and a keymap that could bind `x`
/// would be a keymap that could take `x` away from typing.
pub const Result = enum { typing };

/// Which half of the box has the keyboard.
///
/// Modal because the terminal is: Shift-Enter cannot be told from Enter
/// without the kitty keyboard protocol, and tmux swallows the difference
/// unless `extended-keys` is on. Vim's modality exists for exactly that
/// reason - `o` opens a line with no modifier to encode and nothing to
/// negotiate. Chasing one chord through three layers of terminal was the
/// argument for building this rather than against it.
pub const Mode = enum { insert, normal };

/// An operator waiting for the motion that says how far it reaches, or an
/// `f`/`t` waiting for its character.
const Pending = union(enum) {
    delete,
    change,
    find: struct { forward: bool, till: bool },
};

pub const Compose = struct {
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    /// Byte offset of the caret, always on a UTF-8 boundary and always
    /// `<= len`. Bytes rather than columns, because that is what an insert
    /// needs and hard rule 3 says byte offsets internally.
    cursor: usize = 0,
    open: bool = false,
    mode: Mode = .insert,
    pending: ?Pending = null,
    /// One level, which is vi's own `u`: it undoes the last change, and again
    /// redoes it. Enough to take back a `dd` typed by accident, which is what
    /// undo is for here, and it costs one buffer rather than a stack of them
    /// in a struct that lives on the caller's frame.
    undo_buf: [max_bytes]u8 = undefined,
    undo_len: usize = 0,
    undo_cursor: usize = 0,
    undo_valid: bool = false,

    /// Opens the box seeded with `text`, caret at the end - which is where
    /// someone about to add a sentence wants it. Nothing is selected and
    /// nothing is pending deletion: the seed is a starting point, not a
    /// placeholder that vanishes on the first keystroke.
    pub fn start(self: *Compose, seed: []const u8) void {
        self.len = @min(seed.len, self.buf.len);
        @memcpy(self.buf[0..self.len], seed[0..self.len]);
        self.cursor = self.len;
        self.open = true;
        // Insert, because the box was opened to write in. Normal mode is
        // where you go to edit what is already there, which is the second
        // thing that happens, not the first.
        self.mode = .insert;
        self.pending = null;
        self.undo_valid = false;
    }

    /// Remembers the buffer so `u` can put it back. Called before anything
    /// that changes the text in normal mode; insert-mode typing is one change
    /// from the moment `i` was pressed, the way vi counts it.
    fn mark(self: *Compose) void {
        @memcpy(self.undo_buf[0..self.len], self.buf[0..self.len]);
        self.undo_len = self.len;
        self.undo_cursor = self.cursor;
        self.undo_valid = true;
    }

    /// Swaps the buffer with the remembered one, so a second `u` is a redo.
    fn undo(self: *Compose) void {
        if (!self.undo_valid) return;
        var tmp: [max_bytes]u8 = undefined;
        const tmp_len = self.len;
        const tmp_cursor = self.cursor;
        @memcpy(tmp[0..tmp_len], self.buf[0..tmp_len]);

        @memcpy(self.buf[0..self.undo_len], self.undo_buf[0..self.undo_len]);
        self.len = self.undo_len;
        self.cursor = @min(self.undo_cursor, self.len);

        @memcpy(self.undo_buf[0..tmp_len], tmp[0..tmp_len]);
        self.undo_len = tmp_len;
        self.undo_cursor = tmp_cursor;
    }

    // -- lines ---------------------------------------------------------------

    /// Start of the line the caret is on. The buffer is one string with
    /// newlines in it rather than an array of lines: `flatten` has to see the
    /// whole thing anyway, and a line array would be a second representation
    /// to keep in step with the first.
    pub fn lineStart(self: *const Compose) usize {
        var i = self.cursor;
        while (i > 0 and self.buf[i - 1] != '\n') i -= 1;
        return i;
    }

    pub fn lineEnd(self: *const Compose) usize {
        var i = self.cursor;
        while (i < self.len and self.buf[i] != '\n') i += 1;
        return i;
    }

    fn line(self: *const Compose) []const u8 {
        return self.buf[self.lineStart()..self.lineEnd()];
    }

    fn col(self: *const Compose) u32 {
        return @intCast(self.cursor - self.lineStart());
    }

    fn deleteRange(self: *Compose, from: usize, to: usize) void {
        if (to <= from) return;
        std.mem.copyForwards(u8, self.buf[from..], self.buf[to..self.len]);
        self.len -= to - from;
        self.cursor = from;
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
    /// Whether an operator or an `f`/`t` is waiting for the key after it.
    ///
    /// The caller asks before consulting the keymap: with a `d` pending, the
    /// next key is that operator's motion and `<Esc>` cancels the operator
    /// rather than the box. A binding firing there would make `d<Esc>` close
    /// a half-written message, which is the opposite of what `<Esc>` means
    /// everywhere else in vim.
    pub fn hasPending(self: *const Compose) bool {
        return self.pending != null;
    }

    /// Out to normal mode, not out of the box: `<Esc>` backs out one level,
    /// and from normal mode a second one leaves. The caller decides which of
    /// those two a key means, because only it knows what the key is bound to.
    pub fn toNormal(self: *Compose) void {
        self.mode = .normal;
        self.cursor = motion.clamp(self.line(), self.col()) + self.lineStart();
    }

    pub fn feed(self: *Compose, key: event.Key) Result {
        if (self.mode == .normal) return self.feedNormal(key);
        return self.feedInsert(key);
    }

    /// Normal mode: motions from `ui/motion.zig` - the same ones the diff uses,
    /// so `w` means in the box what it means outside it - plus the operators
    /// that make a long message editable.
    fn feedNormal(self: *Compose, key: event.Key) Result {
        const cp = key.codepoint;

        // A pending `f`/`t` takes the next key as its character, never as a
        // command, exactly the way the review does.
        if (self.pending) |p| switch (p) {
            .find => |fd| {
                self.pending = null;
                if (cp == event.code.escape) return .typing;
                const ln = self.line();
                if (motion.find(ln, self.col(), .{
                    .target = cp,
                    .forward = fd.forward,
                    .till = fd.till,
                })) |at| self.cursor = self.lineStart() + at;
                return .typing;
            },
            else => {},
        };

        // An operator waiting for a motion. `dd` and `cc` are the operator
        // doubled, which is how vim spells "this line".
        if (self.pending) |p| {
            const change = p == .change;
            self.pending = null;
            if (cp == event.code.escape) return .typing;
            if ((change and cp == 'c') or (!change and cp == 'd')) {
                self.mark();
                const from = self.lineStart();
                var to = self.lineEnd();
                // `dd` takes the line's newline with it; `cc` leaves the line
                // in place and empties it, which is what makes it a change.
                if (!change and to < self.len) to += 1;
                self.deleteRange(from, to);
                if (change) self.mode = .insert;
                return .typing;
            }
            if (self.motionTarget(cp)) |to| {
                self.mark();
                const from = self.cursor;
                var target = to;
                // `dw` on the last word of a line deletes to the end of it.
                // `wordNext` has nowhere to go and reports so, which as a
                // *motion* correctly leaves the caret where it is - but as an
                // operator that silently deletes nothing, which is the key
                // appearing not to work. Vim's rule is the same: a forward
                // motion that would run off the line stops at its end.
                if (target == from and forward(cp)) target = self.lineEnd();
                if (target > from) self.deleteRange(from, target) else self.deleteRange(target, from);
                if (change) self.mode = .insert;
            }
            return .typing;
        }

        switch (cp) {
            // Entering insert, at the five places vim enters it.
            'i' => self.mode = .insert,
            'a' => {
                self.cursor = motion.charRight(self.line(), self.col()) orelse self.col();
                self.cursor += self.lineStart();
                self.mode = .insert;
            },
            'I' => {
                self.cursor = self.lineStart() + motion.firstNonBlank(self.line());
                self.mode = .insert;
            },
            'A' => {
                self.cursor = self.lineEnd();
                self.mode = .insert;
            },
            // The keys this whole mode was built for: a new line with no
            // modifier to encode and nothing for tmux to swallow.
            'o' => {
                self.mark();
                self.cursor = self.lineEnd();
                self.insert("\n");
                self.mode = .insert;
            },
            'O' => {
                self.mark();
                self.cursor = self.lineStart();
                self.insert("\n");
                self.cursor -= 1;
                self.mode = .insert;
            },
            'x' => {
                self.mark();
                self.deleteForward();
            },
            'D' => {
                self.mark();
                self.deleteRange(self.cursor, self.lineEnd());
            },
            'C' => {
                self.mark();
                self.deleteRange(self.cursor, self.lineEnd());
                self.mode = .insert;
            },
            'd' => self.pending = .delete,
            'c' => self.pending = .change,
            'u' => self.undo(),
            'f' => self.pending = .{ .find = .{ .forward = true, .till = false } },
            't' => self.pending = .{ .find = .{ .forward = true, .till = true } },
            'F' => self.pending = .{ .find = .{ .forward = false, .till = false } },
            'T' => self.pending = .{ .find = .{ .forward = false, .till = true } },
            'j' => self.lineStep(1),
            'k' => self.lineStep(-1),
            else => {
                if (self.motionTarget(cp)) |at| self.cursor = at;
            },
        }
        return .typing;
    }

    /// Whether a motion runs towards the end of the line, and so should be
    /// clamped there rather than doing nothing when it runs out of line.
    fn forward(cp: u21) bool {
        return switch (cp) {
            'w', 'W', 'e', 'E', 'l' => true,
            else => false,
        };
    }

    /// Where a motion key would put the caret, or null when the key is not a
    /// motion. Shared by the operators, so `dw` and `w` cannot disagree about
    /// where a word ends.
    fn motionTarget(self: *Compose, cp: u21) ?usize {
        const ln = self.line();
        const at = self.col();
        const base = self.lineStart();
        const target: ?u32 = switch (cp) {
            'h', event.code.left => motion.charLeft(ln, at),
            'l', event.code.right => motion.charRight(ln, at),
            'w' => motion.wordNext(ln, at, .word),
            'b' => motion.wordPrev(ln, at, .word),
            'e' => motion.wordEnd(ln, at, .word),
            'W' => motion.wordNext(ln, at, .big),
            'B' => motion.wordPrev(ln, at, .big),
            'E' => motion.wordEnd(ln, at, .big),
            '0' => motion.lineStart(ln),
            '$' => motion.lineEnd(ln),
            '^' => motion.firstNonBlank(ln),
            else => return null,
        };
        return base + (target orelse at);
    }

    /// `j` and `k` over the real lines the buffer holds, keeping the column
    /// where the caret already was - which is what makes them useful once `o`
    /// has produced more than one line.
    fn lineStep(self: *Compose, delta: i32) void {
        const want = self.col();
        if (delta < 0) {
            const from = self.lineStart();
            if (from == 0) return;
            self.cursor = from - 1;
            self.cursor = self.lineStart();
        } else {
            const to = self.lineEnd();
            if (to >= self.len) return;
            self.cursor = to + 1;
        }
        const ln = self.line();
        self.cursor = self.lineStart() + motion.clamp(ln, want);
    }

    fn feedInsert(self: *Compose, key: event.Key) Result {
        const cp = key.codepoint;
        if (key.mods.ctrl) {
            switch (cp) {
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

        // Shift-Enter is a line break, the way every chat box in the world
        // treats it. Whether it *arrives* is not up to this file: a terminal
        // cannot tell Shift-Enter from Enter without the kitty keyboard
        // protocol, which vaxis turns on where the terminal supports it - but
        // tmux swallows the distinction unless `extended-keys` is on, and it
        // is off by default. Under that tmux this key sends the message
        // instead, which is why `Ctrl-j` stays and why both are advertised.
        if (cp == event.code.enter and (key.mods.shift or key.mods.alt)) {
            self.insert("\n");
            return .typing;
        }

        switch (cp) {
            event.code.backspace => self.backspace(),
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

// `@`, Enter, `<Esc>`, `Ctrl-i` and `Ctrl-j` are keymap commands rather than
// keys this file knows, so what they do is tested in `ui/app.zig` where the
// keymap is. What stays here is `toNormal`, which the box owns because only it
// knows where the caret has to land.

test "toNormal clamps the caret onto the line it lands on" {
    var c: Compose = .{};
    c.start("first\n");
    try testing.expectEqual(Mode.insert, c.mode);
    c.toNormal();
    try testing.expectEqual(Mode.normal, c.mode);
    // Past the end of an empty last line is not a column normal mode has.
    try testing.expect(c.cursor <= c.text().len);
}

test "normal mode: o opens a line without a modifier to encode" {
    // The reason this mode exists. Shift-Enter needs the kitty protocol and a
    // tmux with `extended-keys on`; `o` needs a terminal that can send `o`.
    var c: Compose = .{};
    c.start("first");
    c.toNormal();
    _ = c.feed(tap('o'));
    try testing.expectEqual(Mode.insert, c.mode);
    _ = c.feed(tap('s'));
    _ = c.feed(tap('e'));
    _ = c.feed(tap('c'));
    try testing.expectEqualStrings("first\nsec", c.text());

    // `O` opens above instead.
    c.toNormal();
    _ = c.feed(tap('O'));
    _ = c.feed(tap('m'));
    try testing.expectEqualStrings("first\nm\nsec", c.text());
}

test "normal mode: motions and operators agree with the review's own" {
    var c: Compose = .{};
    c.start("the quick brown fox");
    c.toNormal();

    // `0` then `w` twice: the same word motion `w` runs in the diff, because
    // it is literally the same function.
    _ = c.feed(tap('0'));
    _ = c.feed(tap('w'));
    _ = c.feed(tap('w'));
    try testing.expectEqual(@as(usize, 10), c.cursor);

    // `dw` deletes what `w` would have crossed.
    _ = c.feed(tap('d'));
    _ = c.feed(tap('w'));
    try testing.expectEqualStrings("the quick fox", c.text());

    // `u` puts it back, and again takes it away: vi's own toggle.
    _ = c.feed(tap('u'));
    try testing.expectEqualStrings("the quick brown fox", c.text());
    _ = c.feed(tap('u'));
    try testing.expectEqualStrings("the quick fox", c.text());

    // `D` to the end of the line, `x` a character, `A` to append.
    _ = c.feed(tap('0'));
    _ = c.feed(tap('x'));
    try testing.expectEqualStrings("he quick fox", c.text());
    _ = c.feed(tap('D'));
    try testing.expectEqualStrings("", c.text());
}

test "dw on the last word of a line deletes to the end of it" {
    // The bug: `wordNext` has nowhere to go and says so, which is right for a
    // motion and silently wrong for an operator - `dw` deleted nothing.
    var c: Compose = .{};
    c.start("solo");
    c.toNormal();
    _ = c.feed(tap('0'));
    _ = c.feed(tap('d'));
    _ = c.feed(tap('w'));
    try testing.expectEqualStrings("", c.text());

    // The same on the last word of a longer line, which is the common case.
    c.start("two words");
    c.toNormal();
    _ = c.feed(tap('0'));
    _ = c.feed(tap('w'));
    _ = c.feed(tap('d'));
    _ = c.feed(tap('w'));
    try testing.expectEqualStrings("two ", c.text());

    // `de` too, and `cw` leaves you in insert where the word was.
    c.start("alpha beta");
    c.toNormal();
    _ = c.feed(tap('$'));
    _ = c.feed(tap('d'));
    _ = c.feed(tap('e'));
    try testing.expectEqualStrings("alpha bet", c.text());

    c.start("only");
    c.toNormal();
    _ = c.feed(tap('0'));
    _ = c.feed(tap('c'));
    _ = c.feed(tap('w'));
    try testing.expectEqual(Mode.insert, c.mode);
    try testing.expectEqualStrings("", c.text());
}

test "a word motion that goes nowhere still moves nothing on its own" {
    // The clamp is for operators only: `w` on the last word leaves the caret
    // where it is, which is what the review's own `w` does.
    var c: Compose = .{};
    c.start("solo");
    c.toNormal();
    _ = c.feed(tap('0'));
    _ = c.feed(tap('w'));
    try testing.expectEqual(@as(usize, 0), c.cursor);
    try testing.expectEqualStrings("solo", c.text());
}

test "normal mode: dd takes the line and j k walk them" {
    var c: Compose = .{};
    c.start("one");
    c.toNormal();
    _ = c.feed(tap('o'));
    _ = c.feed(tap('t'));
    _ = c.feed(tap('w'));
    _ = c.feed(tap('o'));
    c.toNormal();
    _ = c.feed(tap('o'));
    _ = c.feed(tap('3'));
    c.toNormal();
    try testing.expectEqualStrings("one\ntwo\n3", c.text());

    // `k` up two lines keeps the column where it can.
    _ = c.feed(tap('k'));
    _ = c.feed(tap('k'));
    try testing.expectEqual(@as(usize, 0), c.lineStart());

    // `dd` removes the line and its newline.
    _ = c.feed(tap('d'));
    _ = c.feed(tap('d'));
    try testing.expectEqualStrings("two\n3", c.text());
}

test "shift-enter is a line break, enter is still send" {
    var c: Compose = .{};
    c.start("one");
    try testing.expectEqual(Result.typing, c.feed(.{
        .codepoint = event.code.enter,
        .mods = .{ .shift = true },
    }));
    try testing.expectEqualStrings("one\n", c.text());

    // Alt-Enter too: the other spelling terminals use for the same idea.
    _ = c.feed(.{ .codepoint = event.code.enter, .mods = .{ .alt = true } });
    try testing.expectEqualStrings("one\n\n", c.text());
}

test "a typed newline is flattened on the way out" {
    var c: Compose = .{};
    c.start("check the token");
    c.insert("\n");
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
