// SPDX-License-Identifier: Apache-2.0
//
// How far the viewport is from where it has settled, while it catches up.
//
// A number and a speed, with no clock and no terminal in it: the caller says
// how much time has passed and reads back the displacement to draw at. That is
// what lets the awkward cases - a frame that took 80 ms, a second jump landing
// mid-flight, a budget of zero - be tested without a pane to watch.
//
// **Constant speed, with a floor of one screen row per frame.** Half a row
// cannot be drawn, so one row per frame is the finest motion a cell grid can
// express and there is nothing to be gained by asking for less. An ease-out
// curve was the first attempt and is worse here for exactly that reason: it
// spends its opening frames moving four and five rows at a time, which the eye
// reads as a jump, and its closing frames moving less than a row, which the
// terminal cannot draw at all. Constant speed puts every frame on the grid.
//
// A short jump therefore arrives sooner than a long one rather than moving
// more slowly - the velocity is what stays the same, which is what makes the
// motion feel like one thing rather than a duration being divided up.
//
// The unit throughout is screen rows, never logical ones. A wrapped line is
// several screen rows and scrolling past it should take several rows' worth of
// time, or the motion speeds up over exactly the lines that are hardest to
// read (`ui/wrap.zig`).

const std = @import("std");

/// One screen row per 60 Hz frame, in rows per millisecond: the finest motion
/// a cell grid can express. No jump moves slower than this, because a slower
/// one would spend frames drawing the same screen twice.
const finest: f32 = 1.0 / 16.0;

/// Below this there is nothing left to move: half a cell cannot be drawn, so
/// a displacement under it is already showing where it belongs. Rows for the
/// viewport and cells for the cursor are the same unit at the same scale, so
/// they take the same threshold.
const half_cell: f32 = 0.5;

/// A jump further than this many screens is not animated at all. `G` across a
/// ten-thousand-line review is a teleport in intent; easing it either takes
/// forever or moves so fast the frames are noise. Vim's smooth-scroll plugins
/// all draw the line somewhere, and this is where.
pub const max_screens: i32 = 2;

pub const Scroll = struct {
    /// Screen rows between where the viewport is drawn and where it has
    /// settled. Positive means it is drawn *above* the settled position, which
    /// is what scrolling down looks like while it catches up.
    offset: f32 = 0,
    /// Rows per millisecond, fixed when the jump starts.
    speed: f32 = 0,
    /// The longest a jump may take. A short one arrives sooner: it moves at
    /// one row per frame and runs out of rows. Zero animates nothing, which is
    /// what `ui.scroll_ms = 0` asks for.
    budget_ms: u32 = 250,

    pub fn active(self: Scroll) bool {
        return self.offset != 0;
    }

    /// The displacement to draw at, in whole screen rows.
    pub fn rows(self: Scroll) i32 {
        return @intFromFloat(@round(self.offset));
    }

    /// Adds a jump of `distance` screen rows, signed the way `offset` is.
    /// Adding rather than replacing is what makes a second jump mid-flight
    /// continue the first instead of restarting it.
    pub fn add(self: *Scroll, distance: i32, body: u16) void {
        if (self.budget_ms == 0) return;
        // One row has nothing between where it starts and where it lands.
        // This is what keeps a held `j` at the bottom of the pane instant:
        // animating it would be a frame of delay per keystroke and no motion
        // to show for it.
        if (@abs(distance) <= 1) return;
        if (@abs(distance) > max_screens * @as(i32, body)) return self.settle();

        self.offset += @floatFromInt(distance);
        // Recomputed from what is left rather than from this jump alone, so a
        // second one landing mid-flight speeds the travel up to cover both
        // inside the same budget instead of queueing behind the first.
        self.speed = @max(finest, @abs(self.offset) / @as(f32, @floatFromInt(self.budget_ms)));
    }

    /// Advances by `dt_ms` of real time. Real rather than assumed, so a frame
    /// the terminal was slow to flush does not stretch the animation out.
    pub fn step(self: *Scroll, dt_ms: f32) void {
        if (self.offset == 0) return;
        if (self.budget_ms == 0 or dt_ms <= 0) return self.settle();

        const travelled = self.speed * dt_ms;
        if (travelled + half_cell >= @abs(self.offset)) return self.settle();
        self.offset -= if (self.offset > 0) travelled else -travelled;
    }

    /// Arrive now. What a keystroke does: an animation the reader has already
    /// moved past is latency, not motion.
    pub fn settle(self: *Scroll) void {
        self.offset = 0;
        self.speed = 0;
    }
};

/// Where the cursor block is drawn, chasing where it belongs.
///
/// Screen cells of the body rather than a row and a byte offset, because that
/// is the space the motion actually happens in: a column, a wrapped line and a
/// scrolling viewport all move the same block across the same grid, and
/// chasing a cell handles the three of them without knowing about any of them.
///
/// A cell is the unit here for the same reason it is in `Scroll`: one cell per
/// frame is the finest a terminal can draw. Four cells of a `w` motion is four
/// frames of visible travel - not much, and far more than none, which is what
/// this had before.
pub const Cursor = struct {
    pub const Cell = struct {
        row: f32,
        col: f32,

        pub fn eq(self: Cell, other: Cell) bool {
            return @abs(self.row - other.row) < half_cell and @abs(self.col - other.col) < half_cell;
        }
    };

    /// Null before the first frame places it: there is nowhere to travel from.
    at: ?Cell = null,
    /// Cells per millisecond, fixed for the trip. Recomputed only when the
    /// target moves *further* away, which is a new motion rather than progress
    /// on the old one - deriving it from the remaining distance every frame
    /// would decelerate into the same ease-out that `Scroll` had to abandon.
    speed: f32 = 0,
    /// The distance the current speed was set for.
    span: f32 = 0,
    /// Milliseconds to cross a distance, bounded below by one cell a frame.
    /// Zero puts the cursor where it belongs immediately.
    budget_ms: u32 = 80,

    /// Whether there is still ground to cover. Takes the target because it is
    /// the caller that knows where the cursor belongs this frame.
    pub fn travelling(self: Cursor, target: Cell) bool {
        const from = self.at orelse return false;
        return !from.eq(target);
    }

    /// The cell to draw, and the placement of a cursor that has never been
    /// drawn before.
    ///
    /// Placing here rather than in `step` is what lets the travel start at
    /// all: `step` only runs while something is travelling, and nothing is
    /// travelling until there is a cell to travel *from*. Drawing is the event
    /// that establishes one.
    pub fn cell(self: *Cursor, target: Cell) Cell {
        if (self.at == null) self.at = target;
        return self.at.?;
    }

    /// Somewhere else entirely - another file, a rebuilt diff, a resize. There
    /// is no path between two unrelated screens, so there is nothing to draw
    /// along one.
    pub fn place(self: *Cursor) void {
        self.at = null;
        self.span = 0;
        self.speed = 0;
    }

    fn arrive(self: *Cursor, target: Cell) void {
        self.at = target;
        self.span = 0;
        self.speed = 0;
    }

    pub fn step(self: *Cursor, target: Cell, dt_ms: f32) void {
        const from = self.at orelse {
            self.arrive(target);
            return;
        };
        if (self.budget_ms == 0 or dt_ms <= 0) {
            self.arrive(target);
            return;
        }

        const dr = target.row - from.row;
        const dc = target.col - from.col;
        const dist = @sqrt(dr * dr + dc * dc);
        if (dist < half_cell) {
            self.arrive(target);
            return;
        }

        if (dist > self.span) {
            self.span = dist;
            self.speed = @max(finest, dist / @as(f32, @floatFromInt(self.budget_ms)));
        }
        const travel = self.speed * dt_ms;
        if (travel >= dist) {
            self.arrive(target);
            return;
        }
        // Straight line at constant speed: the shortest path between two cells
        // and the one the eye predicts.
        self.at = .{
            .row = from.row + dr / dist * travel,
            .col = from.col + dc / dist * travel,
        };
    }
};

const testing = std.testing;

/// Frames a jump takes at 60 Hz, and the largest step any one of them made.
fn fly(s: *Scroll) struct { frames: u32, biggest: f32 } {
    var frames: u32 = 0;
    var biggest: f32 = 0;
    while (s.active() and frames < 1000) : (frames += 1) {
        const before = s.offset;
        s.step(16);
        const moved = @abs(before - s.offset);
        // The final frame lands on zero from wherever it was; that arrival is
        // not a step the eye sees as motion.
        if (s.active() and moved > biggest) biggest = moved;
    }
    return .{ .frames = frames, .biggest = biggest };
}

test "a short jump moves one row a frame, the finest a cell grid can show" {
    var s: Scroll = .{};
    s.add(12, 26);
    const flight = fly(&s);
    try testing.expect(!s.active());

    // Twelve rows, one a frame: nothing coarser, and nothing finer exists.
    try testing.expect(flight.biggest <= 1.01);
    try testing.expect(flight.frames >= 10);
    // And it arrives well inside the budget rather than dawdling to fill it.
    try testing.expect(flight.frames * 16 <= 250);
}

test "a long jump moves faster rather than taking longer" {
    var s: Scroll = .{};
    s.add(52, 26);
    const flight = fly(&s);
    try testing.expect(!s.active());

    // Twice the budget's worth of rows in the budget: the steps get bigger,
    // the wait does not.
    try testing.expect(flight.frames * 16 <= 260);
    try testing.expect(flight.biggest > 1.0);
}

test "a jump arrives, from one side, without overshooting" {
    var s: Scroll = .{};
    s.add(20, 26);
    var prev = s.offset;
    while (s.active()) {
        s.step(16);
        try testing.expect(s.offset < prev or s.offset == 0);
        try testing.expect(s.offset >= 0);
        prev = s.offset;
    }
    try testing.expect(!s.active());
}

test "the pace does not depend on the frame rate" {
    var fast: Scroll = .{};
    var slow: Scroll = .{};
    fast.add(30, 26);
    slow.add(30, 26);

    // 60 fps against 20 fps over the same 48 ms of real time.
    fast.step(16);
    fast.step(16);
    fast.step(16);
    slow.step(48);
    try testing.expect(@abs(fast.offset - slow.offset) < 0.01);
}

test "scrolling up is the same animation with the other sign" {
    var s: Scroll = .{};
    s.add(-12, 26);
    try testing.expectEqual(@as(i32, -12), s.rows());
    var guard: u32 = 0;
    while (s.active() and guard < 1000) : (guard += 1) {
        s.step(16);
        try testing.expect(s.offset <= 0);
    }
    try testing.expect(!s.active());
}

test "a second jump mid-flight covers both inside the same budget" {
    var s: Scroll = .{};
    s.add(20, 26);
    s.step(16);
    const alone = s.speed;
    s.add(20, 26);
    // Faster, not queued: the reader asked to be somewhere further away, not
    // to wait twice as long.
    try testing.expect(s.speed > alone);
    const flight = fly(&s);
    try testing.expect(flight.frames * 16 <= 260);
}

test "a jump too far to be motion is not animated" {
    var s: Scroll = .{};
    // Two screens is the limit; `G` across a long review is past it.
    s.add(max_screens * 26, 26);
    try testing.expect(s.active());
    s.settle();

    s.add(max_screens * 26 + 1, 26);
    try testing.expect(!s.active());

    // And one arriving mid-flight settles what was already running rather
    // than leaving the screen halfway to somewhere it is no longer going.
    s.add(10, 26);
    s.add(9999, 26);
    try testing.expect(!s.active());
}

test "a one-row scroll is not motion, it is the next row" {
    var s: Scroll = .{};
    s.add(1, 26);
    try testing.expect(!s.active());
    s.add(-1, 26);
    try testing.expect(!s.active());
    // Two is the smallest jump with anything in between it.
    s.add(2, 26);
    try testing.expect(s.active());
}

test "zero budget is no animation at all" {
    var s: Scroll = .{ .budget_ms = 0 };
    s.add(20, 26);
    try testing.expect(!s.active());
    try testing.expectEqual(@as(i32, 0), s.rows());

    // And one already in flight when the setting changes stops at the next
    // frame rather than hanging.
    var running: Scroll = .{};
    running.add(20, 26);
    running.budget_ms = 0;
    running.step(16);
    try testing.expect(!running.active());
}

test "a stray frame with no time in it does not stall the animation" {
    var s: Scroll = .{};
    s.add(20, 26);
    s.step(0);
    // Rather than standing still forever, it arrives.
    try testing.expect(!s.active());
}

test "the cursor travels a cell a frame, whatever the motion" {
    var c: Cursor = .{};
    // Placed on the first frame: there is nowhere to travel from.
    c.step(.{ .row = 4, .col = 10 }, 16);
    try testing.expect(!c.travelling(.{ .row = 4, .col = 10 }));

    // A word motion is four columns, which is four frames of visible travel -
    // not much, and far more than none.
    const target: Cursor.Cell = .{ .row = 4, .col = 14 };
    var frames: u32 = 0;
    var biggest: f32 = 0;
    while (c.travelling(target) and frames < 100) : (frames += 1) {
        const before = c.at.?;
        c.step(target, 16);
        const moved = @abs(c.at.?.col - before.col);
        if (c.travelling(target) and moved > biggest) biggest = moved;
    }
    try testing.expect(frames >= 3);
    try testing.expect(biggest <= 1.01);
    try testing.expectEqual(@as(f32, 14), c.at.?.col);
}

test "a long hop moves faster rather than taking longer" {
    var c: Cursor = .{};
    c.step(.{ .row = 0, .col = 0 }, 16);
    const target: Cursor.Cell = .{ .row = 20, .col = 60 };
    var frames: u32 = 0;
    while (c.travelling(target) and frames < 1000) : (frames += 1) c.step(target, 16);
    // Inside the budget, rather than sixty cells at a cell a frame.
    try testing.expect(frames * 16 <= 100);
}

test "the cursor travels in a straight line" {
    var c: Cursor = .{};
    c.step(.{ .row = 0, .col = 0 }, 16);
    const target: Cursor.Cell = .{ .row = 10, .col = 10 };
    var frames: u32 = 0;
    while (c.travelling(target) and frames < 100) : (frames += 1) {
        c.step(target, 16);
        // The diagonal is the shortest path and the one the eye predicts, so
        // the two axes stay in step rather than one finishing first.
        try testing.expect(@abs(c.at.?.row - c.at.?.col) < 0.01);
    }
    try testing.expect(!c.travelling(target));
}

test "drawing places a cursor that has never been drawn" {
    var c: Cursor = .{};
    const first: Cursor.Cell = .{ .row = 3, .col = 3 };
    // Nothing is travelling until there is a cell to travel from, and drawing
    // is what establishes one - without this the animation can never start.
    try testing.expect(!c.travelling(first));
    try testing.expectEqual(first, c.cell(first));
    try testing.expect(c.travelling(.{ .row = 3, .col = 9 }));
}

test "somewhere else entirely is placed, not travelled to" {
    var c: Cursor = .{};
    c.step(.{ .row = 2, .col = 2 }, 16);
    c.place();
    // No path between two unrelated screens: the next frame puts it there.
    c.step(.{ .row = 30, .col = 70 }, 16);
    try testing.expect(!c.travelling(.{ .row = 30, .col = 70 }));
}

test "zero budget puts the cursor where it belongs at once" {
    var c: Cursor = .{ .budget_ms = 0 };
    c.step(.{ .row = 0, .col = 0 }, 16);
    c.step(.{ .row = 9, .col = 9 }, 16);
    try testing.expect(!c.travelling(.{ .row = 9, .col = 9 }));
}
