// SPDX-License-Identifier: Apache-2.0
//
// `:tired` - every glyph on screen falls into a heap, rests there until the
// reader presses something, and flies home.
//
// The rise is the fall backwards rather than a second animation: a glyph
// leaves at the speed it landed with and the same gravity takes it away again,
// so nothing is recorded to replay and only each glyph's home is kept.
//
// Pure, and jittered by a hash of the cell rather than an RNG, so a fall
// replays exactly in a test. The loop draws it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const theme_mod = @import("theme.zig");

/// Rows per ms squared: a 30-row pane empties in about three quarters of a
/// second.
const gravity: f32 = 0.00013;

/// Sideways tumble, in columns per ms.
const drift: f32 = 0.0010;

/// The longest a glyph hangs on. Without it the screen falls as one sheet,
/// which reads as a scroll.
const stagger: f32 = 420;

const restitution: f32 = 0.3;

/// Under this a bounce is shorter than the cell it would leave.
const bounce_floor: f32 = 0.012;

/// Whole-frame steps lose a sliver of height on the way up, and a glyph snapped
/// home from a row short arrives with a visible jerk.
const launch_slack: f32 = 1.04;

/// Longer graphemes fall cut rather than costing an allocation each.
pub const max_bytes = 8;

pub const rests = [_][]const u8{
    "the diff will still be here tomorrow",
    "go to bed - the agent will wait",
    "close the laptop. it is fine.",
    "nothing here is worth 2am",
    "rest. review it with fresh eyes.",
    "you have read enough for today",
};

/// `gone` is off the side or out of a full column, until the rise fetches it.
const State = enum { moving, still, gone };

/// Same integrator either way; what stops a glyph differs.
pub const Phase = enum { fall, rise };

const Glyph = struct {
    col: f32,
    row: f32,
    /// The cell it came from, and the only thing the fall has to remember.
    home_col: f32,
    home_row: f32,
    vcol: f32,
    vrow: f32,
    /// Ms into the phase before it moves. Mirrored on the rise, so the last to
    /// let go is the first one home.
    wait: f32,
    style: vaxis.Style,
    bytes: [max_bytes]u8,
    len: u8,
    state: State,
    bounced: bool,
};

/// Struct of arrays: every field is walked once a frame, two of them by the
/// physics.
pub const Fall = struct {
    glyphs: std.MultiArrayList(Glyph) = .empty,
    /// Glyphs resting in each column, so where the next one lands.
    heap: []u16 = &.{},
    width: u16 = 0,
    height: u16 = 0,
    elapsed: f32 = 0,
    phase: Phase = .fall,
    /// Zero while anything is still in the air; the clock once it is not.
    settled_ms: f32 = 0,
    seed: u64 = 0,

    pub fn deinit(self: *Fall, gpa: Allocator) void {
        self.glyphs.deinit(gpa);
        gpa.free(self.heap);
        self.* = undefined;
    }

    /// `dt_ms` is measured, not assumed: a slow terminal drops frames rather
    /// than stretching the fall out behind it.
    pub fn step(self: *Fall, dt_ms: f32) void {
        self.elapsed += dt_ms;
        switch (self.phase) {
            .fall => self.stepFall(dt_ms),
            .rise => self.stepRise(dt_ms),
        }
    }

    fn stepFall(self: *Fall, dt_ms: f32) void {
        const s = self.glyphs.slice();
        const cols = s.items(.col);
        const rows = s.items(.row);
        const vcols = s.items(.vcol);
        const vrows = s.items(.vrow);
        const waits = s.items(.wait);
        const states = s.items(.state);
        const bounced = s.items(.bounced);

        var moving = false;
        for (0..self.glyphs.len) |i| {
            if (states[i] != .moving) continue;
            moving = true;
            if (self.elapsed < waits[i]) continue;

            vrows[i] += gravity * dt_ms;
            rows[i] += vrows[i] * dt_ms;
            cols[i] += vcols[i] * dt_ms;

            if (cols[i] < 0 or cols[i] >= @as(f32, @floatFromInt(self.width))) {
                states[i] = .gone;
                continue;
            }
            const column: u16 = @intFromFloat(cols[i]);
            const piled = self.heap[column];
            if (piled >= self.height) {
                states[i] = .gone;
                continue;
            }
            const floor: f32 = @floatFromInt(self.height - piled - 1);
            if (rows[i] < floor) continue;

            rows[i] = floor;
            if (!bounced[i] and vrows[i] > bounce_floor) {
                bounced[i] = true;
                vrows[i] = -vrows[i] * restitution;
                continue;
            }
            vrows[i] = 0;
            vcols[i] = 0;
            states[i] = .still;
            self.heap[column] = piled + 1;
        }
        // Counts one that has not let go yet, so the clock cannot start early.
        if (!moving) self.settled_ms += dt_ms;
    }

    /// Same gravity, still pointing down. That is the whole of the rewind.
    fn stepRise(self: *Fall, dt_ms: f32) void {
        const s = self.glyphs.slice();
        const cols = s.items(.col);
        const rows = s.items(.row);
        const homes_col = s.items(.home_col);
        const homes_row = s.items(.home_row);
        const vcols = s.items(.vcol);
        const vrows = s.items(.vrow);
        const waits = s.items(.wait);
        const states = s.items(.state);

        for (0..self.glyphs.len) |i| {
            if (states[i] != .moving) continue;
            if (self.elapsed < waits[i]) continue;

            vrows[i] += gravity * dt_ms;
            rows[i] += vrows[i] * dt_ms;
            cols[i] += vcols[i] * dt_ms;

            // Home, or out of climb - the sliver the integrator loses.
            if (rows[i] <= homes_row[i] or vrows[i] >= 0) {
                rows[i] = homes_row[i];
                cols[i] = homes_col[i];
                vrows[i] = 0;
                vcols[i] = 0;
                states[i] = .still;
            }
        }
    }

    /// Launch everything home. Called on any event, mid-fall included, so a
    /// keystroke turns the screen around where it is.
    pub fn rise(self: *Fall) void {
        if (self.phase == .rise) return;
        self.phase = .rise;
        self.elapsed = 0;

        const s = self.glyphs.slice();
        const cols = s.items(.col);
        const rows = s.items(.row);
        const homes_col = s.items(.home_col);
        const homes_row = s.items(.home_row);
        const vcols = s.items(.vcol);
        const vrows = s.items(.vrow);
        const waits = s.items(.wait);
        const states = s.items(.state);

        for (0..self.glyphs.len) |i| {
            // Back in from under the floor, rather than not coming back.
            if (states[i] == .gone) {
                cols[i] = homes_col[i];
                rows[i] = @floatFromInt(self.height);
            }
            waits[i] = stagger - waits[i];
            const climb = rows[i] - homes_row[i];
            if (climb <= 0) {
                rows[i] = homes_row[i];
                cols[i] = homes_col[i];
                states[i] = .still;
                continue;
            }
            // The speed it arrived with is the speed it leaves with.
            const speed = @sqrt(2 * gravity * climb);
            vrows[i] = -speed * launch_slack;
            // Divided over the flight rather than reversed: the way up has to
            // end on the exact cell it came from.
            vcols[i] = (homes_col[i] - cols[i]) / (speed / gravity);
            states[i] = .moving;
        }
    }

    /// Every glyph home, so the review can be drawn over it again.
    pub fn back(self: *const Fall) bool {
        if (self.phase != .rise) return false;
        for (self.glyphs.items(.state)) |st| {
            if (st == .moving) return false;
        }
        return true;
    }

    /// Nothing in the air. Never on the way back up, which has nothing to say.
    pub fn quiet(self: *const Fall) bool {
        return self.phase == .fall and self.settled_ms > 0;
    }

    /// How long the heap has been a heap.
    pub fn clock(self: *const Fall, buf: []u8) []const u8 {
        return elapsedText(buf, self.settled_ms);
    }

    /// Seeded, so it varies between falls and not within one.
    pub fn rest(self: *const Fall) []const u8 {
        return rests[self.seed % rests.len];
    }

    /// The seeded line, the shortest that fits, or none: a sentence cut off
    /// mid-word says less than no sentence.
    pub fn restFor(self: *const Fall, width: u16) []const u8 {
        const room = width -| 8;
        const pick = self.rest();
        if (pick.len <= room) return pick;
        var shortest: []const u8 = "";
        for (rests) |line| {
            if (line.len > room) continue;
            if (shortest.len == 0 or line.len < shortest.len) shortest = line;
        }
        return shortest;
    }

    /// The line and the clock, in the border the `?` overlay uses. Over a pile
    /// of glyphs a bare row of text reads as more of the wreckage.
    pub fn plaque(self: *const Fall, win: vaxis.Window, theme: theme_mod.Theme, glyphs: theme_mod.Glyphs) void {
        var buf: [16]u8 = undefined;
        const ticking = self.clock(&buf);
        const line = self.restFor(win.width);

        const content: u16 = @intCast(@max(line.len, ticking.len));
        const width = @min(content + 8, win.width);
        // A row of air above and below, where the pane can spare two.
        const pad: u16 = if (win.height >= 12) 1 else 0;
        const height = 2 + pad * 2 + @as(u16, if (line.len == 0) 1 else 2);
        if (width < 8 or height > win.height) return;

        const col = (win.width -| width) / 2;
        const top = @min((win.height / 3) -| 1, win.height - height);
        box(win, col, top, width, height, theme.popup_border, glyphs);

        var row = top + 1 + pad;
        if (line.len > 0) {
            centred(win, row, line, theme.notice);
            row += 1;
        }
        centred(win, row, ticking, theme.dim);
    }

    pub fn draw(self: *const Fall, win: vaxis.Window) void {
        const s = self.glyphs.slice();
        const cols = s.items(.col);
        const rows = s.items(.row);
        const styles = s.items(.style);
        const bytes = s.items(.bytes);
        const lens = s.items(.len);
        const states = s.items(.state);

        for (0..self.glyphs.len) |i| {
            if (states[i] == .gone) continue;
            if (rows[i] < 0) continue;
            const row: u16 = @intFromFloat(@round(rows[i]));
            const col: u16 = @intFromFloat(cols[i]);
            if (row >= self.height or col >= self.width) continue;
            win.writeCell(col, row, .{
                .char = .{ .grapheme = bytes[i][0..lens[i]], .width = 1 },
                .style = styles[i],
            });
        }
    }
};

/// Blanked inside, so the heap does not show through.
fn box(
    win: vaxis.Window,
    col: u16,
    top: u16,
    width: u16,
    height: u16,
    style: vaxis.Style,
    glyphs: theme_mod.Glyphs,
) void {
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        const edge = row == 0 or row == height - 1;
        var at: u16 = 0;
        while (at < width) : (at += 1) {
            const side = at == 0 or at == width - 1;
            const glyph: ?[]const u8 = if (edge and side)
                if (row == 0)
                    if (at == 0) glyphs.box_tl else glyphs.box_tr
                else if (at == 0) glyphs.box_bl else glyphs.box_br
            else if (edge)
                glyphs.box_h
            else if (side)
                glyphs.box_v
            else
                null;
            win.writeCell(col + at, top + row, if (glyph) |g|
                .{ .char = .{ .grapheme = g, .width = 1 }, .style = style }
            else
                .{});
        }
    }
}

fn centred(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    const width: u16 = @intCast(@min(text.len, win.width));
    _ = win.printSegment(
        .{ .text = text, .style = style },
        .{ .row_offset = row, .col_offset = (win.width -| width) / 2, .wrap = .none },
    );
}

/// The screen as it stands, turned into something that can fall. Graphemes are
/// copied because a vaxis cell points into the frame arena, which is reset
/// before the first frame of the fall is drawn.
pub fn capture(gpa: Allocator, screen: *const vaxis.Screen, seed: u64) Allocator.Error!Fall {
    var fall: Fall = .{
        .width = screen.width,
        .height = screen.height,
        .seed = seed,
        .heap = try gpa.alloc(u16, screen.width),
    };
    errdefer fall.deinit(gpa);
    @memset(fall.heap, 0);

    for (0..screen.height) |r| {
        for (0..screen.width) |c| {
            const col: u16 = @intCast(c);
            const row: u16 = @intCast(r);
            const cell = screen.readCell(col, row) orelse continue;
            const g = cell.char.grapheme;
            if (g.len == 0 or g.len > max_bytes) continue;
            // Blanks are the pane, not the review. Dropping them is also what
            // makes the status row fall as its words rather than as a bar.
            if (std.mem.indexOfNone(u8, g, " ") == null) continue;
            // A cell holding half of a wide glyph, or bytes from an arena that
            // has moved on. Neither is anything to drop on the floor.
            if (!std.unicode.utf8ValidateSlice(g)) continue;

            const bits = jitter(seed, col, row);
            var glyph: Glyph = .{
                .col = @floatFromInt(col),
                .row = @floatFromInt(row),
                .home_col = @floatFromInt(col),
                .home_row = @floatFromInt(row),
                .vcol = spread(bits) * drift,
                .vrow = 0,
                .wait = fraction(bits >> 20) * stagger,
                .style = cell.style,
                .bytes = undefined,
                .len = @intCast(g.len),
                .state = .moving,
                .bounced = false,
            };
            @memcpy(glyph.bytes[0..g.len], g);
            try fall.glyphs.append(gpa, glyph);
        }
    }
    return fall;
}

/// `m:ss`, and `h:mm:ss` for the reader who really did need the break.
fn elapsedText(buf: []u8, ms: f32) []const u8 {
    const total: u64 = @intFromFloat(@max(ms, 0) / 1000);
    const seconds = total % 60;
    const minutes = (total / 60) % 60;
    const hours = total / 3600;
    const out = if (hours > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds })
    else
        std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, seconds });
    return out catch buf[0..0];
}

/// Wyhash, as everywhere else here, over the cell's position.
fn jitter(seed: u64, col: u16, row: u16) u64 {
    var h: std.hash.Wyhash = .init(seed);
    h.update(std.mem.asBytes(&col));
    h.update(std.mem.asBytes(&row));
    return h.final();
}

/// Sixteen bits of a hash as a fraction of one.
fn fraction(bits: u64) f32 {
    return @as(f32, @floatFromInt(bits & 0xffff)) / 65535.0;
}

/// The same, centred on zero: `-1` to `1`.
fn spread(bits: u64) f32 {
    return fraction(bits) * 2 - 1;
}

const testing = std.testing;

/// A screen with no terminal anywhere near it.
fn fakeScreen(gpa: Allocator, width: u16, height: u16) !vaxis.Screen {
    const screen: vaxis.Screen = .{
        .width = width,
        .height = height,
        .buf = try gpa.alloc(vaxis.Cell, @as(usize, width) * height),
    };
    for (screen.buf) |*cell| cell.* = .{ .char = .{ .grapheme = "x", .width = 1 } };
    return screen;
}

test "every glyph on the screen falls, and blanks do not" {
    var screen = try fakeScreen(testing.allocator, 8, 4);
    defer testing.allocator.free(screen.buf);
    // A blank row has nothing to drop.
    for (0..8) |c| screen.writeCell(@intCast(c), 1, .{ .char = .{ .grapheme = " ", .width = 1 } });

    var fall = try capture(testing.allocator, &screen, 7);
    defer fall.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 24), fall.glyphs.len);
}

test "the heap ends up as tall as what fell into it" {
    var screen = try fakeScreen(testing.allocator, 4, 6);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 3);
    defer fall.deinit(testing.allocator);

    // A ceiling, not a duration: it stops long before this runs out.
    var frames: usize = 0;
    while (!fall.quiet() and frames < 1000) : (frames += 1) fall.step(16);
    try testing.expect(fall.quiet());

    const states = fall.glyphs.items(.state);
    for (states) |s| try testing.expect(s != .moving);
    var total: u32 = 0;
    for (fall.heap) |h| total += h;
    var gone: u32 = 0;
    for (states) |s| {
        if (s == .gone) gone += 1;
    }
    try testing.expectEqual(@as(u32, @intCast(fall.glyphs.len)), total + gone);
}

test "a glyph rests on the one that landed before it" {
    var screen = try fakeScreen(testing.allocator, 6, 4);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 11);
    defer fall.deinit(testing.allocator);
    while (!fall.quiet()) fall.step(16);

    // Two glyphs in one cell would be a heap with glyphs missing from it.
    var taken = std.AutoHashMap(u32, void).init(testing.allocator);
    defer taken.deinit();
    const rows = fall.glyphs.items(.row);
    const cols = fall.glyphs.items(.col);
    for (fall.glyphs.items(.state), 0..) |st, i| {
        if (st != .still) continue;
        const at = @as(u32, @intFromFloat(@round(rows[i]))) * 100 +
            @as(u32, @intFromFloat(cols[i]));
        try testing.expect(!taken.contains(at));
        try taken.put(at, {});
        try testing.expect(rows[i] >= @as(f32, @floatFromInt(fall.height - fall.heap[@intFromFloat(cols[i])])));
    }
}

test "the clock starts only once the last glyph is down" {
    var screen = try fakeScreen(testing.allocator, 6, 8);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 5);
    defer fall.deinit(testing.allocator);
    var buf: [16]u8 = undefined;

    fall.step(16);
    try testing.expect(!fall.quiet());

    while (!fall.quiet()) fall.step(16);
    try testing.expectEqualStrings("0:00", fall.clock(&buf));
    fall.step(9_000);
    try testing.expectEqualStrings("0:09", fall.clock(&buf));
    // It keeps counting: the heap waits for a keystroke and nothing else.
    fall.step(60_000);
    try testing.expectEqualStrings("1:09", fall.clock(&buf));
}

test "the clock grows an hours field and not before" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:00", elapsedText(&buf, 0));
    try testing.expectEqualStrings("0:59", elapsedText(&buf, 59_999));
    try testing.expectEqualStrings("59:59", elapsedText(&buf, 3_599_000));
    try testing.expectEqualStrings("1:00:00", elapsedText(&buf, 3_600_000));
    try testing.expectEqualStrings("2:07:05", elapsedText(&buf, 7_625_000));
}

test "the rise puts every glyph back on the cell it came from" {
    var screen = try fakeScreen(testing.allocator, 12, 8);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 17);
    defer fall.deinit(testing.allocator);
    while (!fall.quiet()) fall.step(16);
    // Some are off the screen by now, and the rise has to fetch those too or
    // the review comes back with holes in it.
    try testing.expect(fall.glyphs.len > 0);

    fall.rise();
    var frames: usize = 0;
    while (!fall.back() and frames < 2000) : (frames += 1) fall.step(16);
    try testing.expect(fall.back());

    const s = fall.glyphs.slice();
    for (0..fall.glyphs.len) |i| {
        try testing.expectEqual(s.items(.home_row)[i], s.items(.row)[i]);
        try testing.expectEqual(s.items(.home_col)[i], s.items(.col)[i]);
        try testing.expect(s.items(.state)[i] == .still);
    }
}

test "a keystroke during the fall turns it around where it is" {
    var screen = try fakeScreen(testing.allocator, 12, 8);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 23);
    defer fall.deinit(testing.allocator);
    // Mid-air: some have let go, some have not, none has landed.
    for (0..12) |_| fall.step(16);
    try testing.expect(!fall.quiet());

    fall.rise();
    try testing.expect(!fall.back());
    var frames: usize = 0;
    while (!fall.back() and frames < 2000) : (frames += 1) fall.step(16);
    try testing.expect(fall.back());
    const s = fall.glyphs.slice();
    for (0..fall.glyphs.len) |i| {
        try testing.expectEqual(s.items(.home_row)[i], s.items(.row)[i]);
    }
}

test "the rise is the fall backwards: last to let go is first home" {
    var screen = try fakeScreen(testing.allocator, 2, 20);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 29);
    defer fall.deinit(testing.allocator);
    while (!fall.quiet()) fall.step(16);

    const before = try testing.allocator.dupe(f32, fall.glyphs.items(.wait));
    defer testing.allocator.free(before);
    fall.rise();
    for (fall.glyphs.items(.wait), before) |after, first| {
        try testing.expectApproxEqAbs(stagger, after + first, 0.001);
    }
}

test "nothing is said over a screen on its way back up" {
    var screen = try fakeScreen(testing.allocator, 6, 6);
    defer testing.allocator.free(screen.buf);

    var fall = try capture(testing.allocator, &screen, 31);
    defer fall.deinit(testing.allocator);
    while (!fall.quiet()) fall.step(16);
    try testing.expect(fall.quiet());

    fall.rise();
    try testing.expect(!fall.quiet());
}

test "a pane too narrow for the line keeps the clock and drops the words" {
    var screen = try fakeScreen(testing.allocator, 4, 4);
    defer testing.allocator.free(screen.buf);
    var fall = try capture(testing.allocator, &screen, 2);
    defer fall.deinit(testing.allocator);

    // Room for the one it drew, for a shorter one only, and for none.
    try testing.expectEqualStrings(fall.rest(), fall.restFor(200));
    const narrow = fall.restFor(@intCast(fall.rest().len + 7));
    try testing.expect(narrow.len < fall.rest().len);
    try testing.expectEqualStrings("", fall.restFor(20));
}

test "the same seed falls the same way twice" {
    var screen = try fakeScreen(testing.allocator, 10, 5);
    defer testing.allocator.free(screen.buf);

    var a = try capture(testing.allocator, &screen, 42);
    defer a.deinit(testing.allocator);
    var b = try capture(testing.allocator, &screen, 42);
    defer b.deinit(testing.allocator);
    for (0..20) |_| {
        a.step(16);
        b.step(16);
    }
    try testing.expectEqualSlices(f32, a.glyphs.items(.row), b.glyphs.items(.row));
    try testing.expectEqualStrings(a.rest(), b.rest());
}
