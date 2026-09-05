// SPDX-License-Identifier: Apache-2.0
//
// Where the reader is, and where the screen has got to catching up with them.
//
// Eight fields and the arithmetic over them, lifted out of `ui/app.zig` because
// they are the one group in that struct that answers to each other and to
// nothing else. `App` is a state machine with seventy-odd fields; this is the
// subset that a scroll, a page key and a resize all read and write together,
// and keeping them apart from the diff, the comments and the bridge is what
// stops "where is the cursor" being answerable from anywhere in a seven
// thousand line file.
//
// **Nothing here knows what a row contains.** A row is a number and a height,
// which is what lets every function below be tested against a table instead of
// against a diff - the trick `scrollFor` was already using, applied to the rest
// of the section rather than to one function of it. The app supplies a `Body`:
// how many rows there are, how tall each one is, and how many screen rows there
// are to put them in.
//
// A body row is one screen row until it wraps, and everything that scrolls has
// to count the screen it is scrolling. That measurement stays in `ui/app.zig`,
// because it needs the file and `ui/wrap.zig`; what it feeds is here.

const std = @import("std");
const anim = @import("anim.zig");

// What every function below wants as its `b` parameter, duck-typed rather
// than an interface because that is the whole point: a caller that can answer
// three questions about numbers can drive all of this, and the tests do
// exactly that.
//
//   count()  - how many body rows there are
//   at(row)  - screen rows that one occupies, never more than body()
//   body()   - screen rows available to put them in

/// A body where every row is one screen row: what the arithmetic sees with
/// wrapping off, and what most of its tests want.
pub fn flat(rows: u32, body_rows: u16) Flat {
    return .{ .rows = rows, .body_rows = body_rows };
}

pub const Flat = struct {
    rows: u32,
    body_rows: u16,

    pub fn count(self: Flat) u32 {
        return self.rows;
    }
    pub fn at(_: Flat, _: u32) u16 {
        return 1;
    }
    pub fn body(self: Flat) u16 {
        return self.body_rows;
    }
};

/// A position displaced by the animation: a row, and how many of that row's
/// screen rows are above the top of the body.
pub const Top = struct { row: u32, skip: u16 };

pub const Viewport = struct {
    /// The row the cursor has settled on, and its byte offset within that
    /// row's line. Where the reader *is*, as against where the block is drawn
    /// while it travels there.
    cursor: u32 = 0,
    col: u32 = 0,
    /// First body row of the pane, once the scroll has settled.
    scroll: u32 = 0,
    /// The pane width, from the last resize the loop reported. Scrolling has
    /// to count screen rows and a wrapped row is more than one of them, so the
    /// state that decides where the cursor goes needs to know how wide the
    /// pane it is going onto is.
    cols: u16 = 80,
    /// How wide text is on this screen: the grapheme method and the tab stop;
    /// see `ui/wrap.zig`. The method is set by the loop from the terminal's
    /// answer, because vaxis only knows it after the capability query comes
    /// back; the tab comes from the config at startup.
    metrics: @import("wrap.zig").Metrics = .{ .method = .unicode },
    /// `Tab`: chrome hidden, the body gets the whole pane.
    zen: bool = false,
    /// The viewport catching up with where it has settled, in screen rows.
    /// Zero except while a jump is in flight; see `ui/anim.zig`.
    scroll_anim: anim.Scroll = .{},
    /// The cursor block travelling to where it belongs. Every motion moves it,
    /// which is the difference between this and `scroll_anim`: the viewport
    /// only animates for a jump, because it moves under a step as a side
    /// effect, but the cursor is what the reader is actually following.
    cursor_anim: anim.Cursor = .{},

    /// `<C-d>` and `<C-u>`: half a screen, and the *screen* is what moves.
    ///
    /// Moving only the cursor is what this did before, and it made the first
    /// press of a page key do nothing visible - the cursor slid down inside a
    /// stationary view and the text only started moving once it reached the
    /// bottom margin. Vim moves both by the same amount, so the cursor keeps
    /// its place on screen and the page turns under it, which is the whole
    /// point of a page key.
    ///
    /// Returns where the cursor should land; the caller moves it, because
    /// moving a cursor is more than assigning to one.
    pub fn pageTo(self: *Viewport, b: anytype, dir: i32) u32 {
        const half = @max(1, b.body() / 2);
        if (dir > 0) {
            self.scroll = self.rowBelow(b, self.scroll, half);
            return self.rowBelow(b, self.cursor, half);
        }
        self.scroll = self.rowAbove(b, self.scroll, half);
        return self.rowAbove(b, self.cursor, half);
    }

    /// The row `screens` screen rows below `from`, and above for the other.
    /// Both move at least one row: a page motion that cannot move because the
    /// line under the cursor fills the pane is a key that does nothing.
    pub fn rowBelow(_: *const Viewport, b: anytype, from: u32, screens: u16) u32 {
        const last = b.count() -| 1;
        var acc: u32 = 0;
        var i = from;
        while (i < last) {
            i += 1;
            acc += b.at(i);
            if (acc >= screens) break;
        }
        return i;
    }

    pub fn rowAbove(_: *const Viewport, b: anytype, from: u32, screens: u16) u32 {
        var acc: u32 = 0;
        var i = from;
        while (i > 0) {
            i -= 1;
            acc += b.at(i);
            if (acc >= screens) break;
        }
        return i;
    }

    /// Puts the cursor's row half a pane down, counting the screen rows a
    /// wrapped line takes rather than the one row it is.
    pub fn centre(self: *Viewport, b: anytype) void {
        const half = b.body() / 2;
        var top = self.cursor;
        var acc: u32 = 0;
        while (top > 0) {
            const above = b.at(top - 1);
            if (acc + above > half) break;
            acc += above;
            top -= 1;
        }
        self.scroll = top;
    }

    /// Screen rows between two scroll positions, positive when `to` is below
    /// `from`. Capped, because the only caller refuses to animate past two
    /// screens and walking ten thousand rows to find that out is waste.
    pub fn screenRowsBetween(_: *const Viewport, b: anytype, from: u32, to: u32) i32 {
        const cap: u32 = @as(u32, anim.max_screens) * @as(u32, b.body()) + 1;
        var acc: u32 = 0;
        var i = @min(from, to);
        const end = @max(from, to);
        while (i < end and acc <= cap) : (i += 1) acc += b.at(i);
        const d: i32 = @intCast(@min(acc, cap));
        return if (to >= from) d else -d;
    }

    /// Starts the viewport catching up, if it moved at all.
    pub fn animateFrom(self: *Viewport, b: anytype, was_at: u32) void {
        if (was_at == self.scroll) return;
        self.scroll_anim.add(self.screenRowsBetween(b, was_at, self.scroll), b.body());
    }

    /// Arrive now. What the loop does when a key arrives mid-flight: an
    /// animation the reader has already moved past is latency, not motion.
    pub fn settle(self: *Viewport) void {
        self.scroll_anim.settle();
    }

    /// The cursor is somewhere else entirely rather than somewhere further:
    /// another file, a rebuilt diff, a pane that changed size. There is no
    /// path between two unrelated screens to draw the block along.
    pub fn place(self: *Viewport) void {
        self.cursor_anim.place();
    }

    /// A position displaced by the animation: the row `up` screen rows above
    /// `from`, and how many of that row's screen rows are above the result.
    /// Negative `up` walks the other way.
    ///
    /// A wrapped line is several screen rows, so this is a walk rather than
    /// arithmetic - and the walk is bounded by the displacement, which
    /// `anim.Scroll` has already capped at two screens.
    pub fn displaced(_: *const Viewport, b: anytype, from: u32, up: i32) Top {
        if (up == 0) return .{ .row = from, .skip = 0 };

        if (up > 0) {
            // Drawn above where it settles, which is what scrolling *down*
            // looks like while the screen catches up.
            var row = from;
            var left: u32 = @intCast(up);
            while (left > 0 and row > 0) {
                row -= 1;
                const h = b.at(row);
                if (h > left) return .{ .row = row, .skip = @intCast(h - left) };
                left -= h;
            }
            return .{ .row = row, .skip = 0 };
        }

        var row = from;
        var left: u32 = @intCast(-up);
        const last = b.count() -| 1;
        while (left > 0 and row < last) {
            const h = b.at(row);
            if (h > left) return .{ .row = row, .skip = @intCast(left) };
            left -= h;
            row += 1;
        }
        return .{ .row = row, .skip = 0 };
    }

    /// Where the body is drawn from while the viewport catches up.
    pub fn drawnTop(self: *const Viewport, b: anytype) Top {
        return self.displaced(b, self.scroll, self.scroll_anim.rows());
    }

    /// Which row the cursor is *drawn* on while the viewport catches up.
    ///
    /// Displaced by the same amount as the viewport, so the cursor holds its
    /// place on screen and the text slides underneath it - which is what a
    /// page key does, and what the eye is tracking. Left at its settled row it
    /// does the opposite: on the first frame the old screen is still showing
    /// but the cursor is already half a page further down, so it snaps away
    /// (often off the bottom edge, where it disappears altogether) and then
    /// crawls back. Text and cursor moving in opposite directions is the one
    /// thing that reads worse than not animating at all.
    pub fn drawnCursor(self: *const Viewport, b: anytype) u32 {
        return self.displaced(b, self.cursor, self.scroll_anim.rows()).row;
    }

    /// Keeps the cursor inside the body with a margin, and never scrolls past
    /// the end of the rows.
    pub fn clampScroll(self: *Viewport, b: anytype, scrolloff: u32) void {
        self.scroll = scrollFor(b, self.cursor, self.scroll, b.count(), b.body(), scrolloff);
    }
};

/// `heights.at(row)` is the screen rows that row occupies, which is one for
/// every row until a line wraps. Passed in rather than computed here so this
/// stays arithmetic: the app measures the real thing, and the tests below hand
/// it a table.
pub fn scrollFor(
    heights: anytype,
    cursor: u32,
    scroll: u32,
    rows_len: u32,
    body: u16,
    scrolloff: u32,
) u32 {
    if (body == 0 or rows_len == 0) return 0;
    const last = rows_len - 1;
    const margin: u32 = @min(scrolloff, body / 3);
    var out = scroll;

    // The row a margin above the cursor has to be on screen.
    const want_top = cursor -| margin;
    if (want_top < out) out = want_top;

    // So does the one a margin below it - but never at the cursor's expense.
    // Walking up from there is what makes the margin a number of *rows* while
    // the room it needs is a number of screen rows.
    const target = @min(cursor +| margin, last);
    var lo = target;
    var acc: u32 = heights.at(target);
    while (lo > 0) {
        const above = heights.at(lo - 1);
        if (acc + above > body) break;
        acc += above;
        lo -= 1;
    }
    if (out < lo) out = @min(lo, cursor);
    // And never blank rows below the last one: the largest offset that still
    // fills the body, found by walking back from the end for the same reason.
    var max_scroll = rows_len;
    var tail: u32 = 0;
    while (max_scroll > 0) {
        const h = heights.at(max_scroll - 1);
        if (tail + h > body) break;
        tail += h;
        max_scroll -= 1;
    }
    if (max_scroll > last) max_scroll = last;
    if (out > max_scroll) out = max_scroll;
    return out;
}

const testing = std.testing;

/// A body with one tall row in it, for the cases the flat table cannot reach.
const Tall = struct {
    hs: []const u16,
    body_rows: u16,

    pub fn count(self: Tall) u32 {
        return @intCast(self.hs.len);
    }
    pub fn at(self: Tall, row: u32) u16 {
        return if (row < self.hs.len) self.hs[row] else 1;
    }
    pub fn body(self: Tall) u16 {
        return self.body_rows;
    }
};

test "a page moves the screen and the cursor by the same amount" {
    var v: Viewport = .{ .cursor = 0, .scroll = 0 };
    const b = flat(100, 22);

    // Half a screen down: both move eleven, so the cursor keeps its place on
    // screen and the page turns under it.
    const to = v.pageTo(b, 1);
    try testing.expectEqual(@as(u32, 11), to);
    try testing.expectEqual(@as(u32, 11), v.scroll);

    v.cursor = to;
    const back = v.pageTo(b, -1);
    try testing.expectEqual(@as(u32, 0), back);
    try testing.expectEqual(@as(u32, 0), v.scroll);
}

test "a page over a tall row moves one row rather than none" {
    // Row 1 fills the whole body. A page that measured only screen rows would
    // stop before it and do nothing visible, which is a key that appears
    // broken.
    var v: Viewport = .{ .cursor = 0, .scroll = 0 };
    const b: Tall = .{ .hs = &.{ 1, 30, 1, 1 }, .body_rows = 10 };
    try testing.expectEqual(@as(u32, 1), v.pageTo(b, 1));
}

test "centring counts screen rows, not rows" {
    var v: Viewport = .{ .cursor = 20 };
    v.centre(flat(100, 22));
    // Eleven flat rows fit in half a body of twenty-two.
    try testing.expectEqual(@as(u32, 9), v.scroll);

    // The same cursor with a tall row above it lands lower, because the tall
    // row eats the half-pane on its own.
    var w: Viewport = .{ .cursor = 3 };
    w.centre(Tall{ .hs = &.{ 1, 1, 20, 1, 1, 1 }, .body_rows = 10 });
    try testing.expectEqual(@as(u32, 3), w.scroll);
}

test "displacement walks screen rows and reports the part above the top" {
    const v: Viewport = .{};
    const b: Tall = .{ .hs = &.{ 1, 5, 1, 1, 1 }, .body_rows = 10 };

    // Two screen rows above row 2 lands inside the five-row row 1, with three
    // of its rows still above the body.
    const up = v.displaced(b, 2, 2);
    try testing.expectEqual(@as(u32, 1), up.row);
    try testing.expectEqual(@as(u16, 3), up.skip);

    // Not moving is not a walk.
    const still = v.displaced(b, 2, 0);
    try testing.expectEqual(@as(u32, 2), still.row);
    try testing.expectEqual(@as(u16, 0), still.skip);
}

test "the distance between two positions is capped rather than walked" {
    const v: Viewport = .{};
    const b = flat(100_000, 20);
    // Two screens is what `anim.Scroll` will animate; measuring the true
    // distance to row 99,999 is a walk with no reader at the end of it.
    const d = v.screenRowsBetween(b, 0, 99_999);
    try testing.expectEqual(@as(i32, @intCast(@as(u32, anim.max_screens) * 20 + 1)), d);
    // And it is signed by direction, not by magnitude.
    try testing.expect(v.screenRowsBetween(b, 40, 10) < 0);
}

// -- the scroll offset ----------------------------------------------------

test "scrolling keeps the cursor inside the body with a margin" {
    // Cursor near the top pins the view to the top rather than showing rows
    // that do not exist above it.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(100, 22), 0, 0, 100, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(100, 22), 2, 0, 100, 22, 3));

    // Moving down past the bottom margin scrolls by exactly what is needed:
    // cursor 20 with a 3-row margin needs rows 21-23 visible, and 2+22-1 = 23.
    try testing.expectEqual(@as(u32, 2), scrollFor(flat(100, 22), 20, 0, 100, 22, 3));
    // Moving back up above the top margin scrolls back.
    try testing.expectEqual(@as(u32, 7), scrollFor(flat(100, 22), 10, 20, 100, 22, 3));
}

test "scrolling never runs past the last row" {
    // A cursor at the end still leaves a full body on screen, not a screen
    // half full of blanks.
    try testing.expectEqual(@as(u32, 78), scrollFor(flat(100, 22), 99, 90, 100, 22, 3));
    // Fewer rows than the body means no scrolling at all.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(5, 22), 3, 0, 5, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(5, 22), 4, 3, 5, 22, 3));
}

test "a tall row costs the screen rows it takes, not the one row it is" {
    // Row 3 wraps onto five screen rows; everything else is one.
    const t: Tall = .{ .hs = &.{ 1, 1, 1, 5, 1, 1, 1, 1, 1, 1 }, .body_rows = 10 };

    // Rows 0-9 are exactly ten screen rows, so a ten-row body shows them all.
    try testing.expectEqual(@as(u32, 0), scrollFor(t, 5, 0, 10, 10, 0));

    // The last row cannot be reached without scrolling the tall one off:
    // rows 4-9 are six screen rows, rows 3-9 are eleven.
    try testing.expectEqual(@as(u32, 4), scrollFor(t, 9, 0, 10, 10, 0));

    // Flat rows in the same shape need no scroll at all, which is the whole
    // difference this arithmetic exists to make.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(10, 10), 9, 0, 10, 10, 0));
}

test "a row taller than the body is shown from its top rather than skipped" {
    // Row 2 is a generated line: twenty screen rows in a body of ten.
    const t: Tall = .{ .hs = &.{ 1, 1, 20, 1, 1, 1 }, .body_rows = 10 };
    try testing.expectEqual(@as(u32, 2), scrollFor(t, 2, 0, 6, 10, 3));
}

test "degenerate sizes do not underflow" {
    // A one-row body has no room for a margin; the arithmetic must still hold.
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(0, 22), 0, 0, 0, 22, 3));
    try testing.expectEqual(@as(u32, 0), scrollFor(flat(10, 0), 5, 0, 10, 0, 3));
    _ = scrollFor(flat(1, 1), 0, 0, 1, 1, 3);
    _ = scrollFor(flat(10, 1), 9, 0, 10, 1, 3);
    _ = scrollFor(flat(10, 2), 0, 9, 10, 2, 3);
}
