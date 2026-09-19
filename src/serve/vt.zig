// SPDX-License-Identifier: Apache-2.0
//
// Just enough of a terminal to turn an agent's output into plain rows for the phone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gwidth = @import("vaxis").gwidth;

const blank: u21 = ' ';
/// The cell a wide character's right half covers.
const tail: u21 = 0;

pub const Screen = struct {
    gpa: Allocator,
    cols: u16,
    rows: u16,
    main: []u21,
    alt: []u21,
    on_alt: bool = false,
    x: u16 = 0,
    y: u16 = 0,
    saved: [2]u16 = .{ 0, 0 },
    top: u16 = 0,
    bottom: u16,
    wrap_next: bool = false,
    autowrap: bool = true,
    state: enum { ground, esc, skip, csi, string, string_esc } = .ground,
    params: [16]u16 = undefined,
    nparams: u8 = 0,
    private: bool = false,
    intermediate: bool = false,
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,

    pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Screen {
        const main = try gpa.alloc(u21, @as(usize, cols) * rows);
        errdefer gpa.free(main);
        const alt = try gpa.alloc(u21, main.len);
        @memset(main, blank);
        @memset(alt, blank);
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .main = main, .alt = alt, .bottom = rows - 1 };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.main);
        self.gpa.free(self.alt);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) Allocator.Error!void {
        if (cols == self.cols and rows == self.rows) return;
        var next = try init(self.gpa, cols, rows);
        for ([_][2][]u21{ .{ self.main, next.main }, .{ self.alt, next.alt } }) |pair| {
            for (0..@min(rows, self.rows)) |r| {
                const n = @min(cols, self.cols);
                @memcpy(pair[1][r * cols ..][0..n], pair[0][r * self.cols ..][0..n]);
            }
        }
        next.on_alt = self.on_alt;
        next.autowrap = self.autowrap;
        next.x = @min(self.x, cols - 1);
        next.y = @min(self.y, rows - 1);
        self.deinit();
        self.* = next;
    }

    /// The visible rows as text, trailing blanks and blank rows dropped.
    pub fn text(self: *const Screen, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var kept: usize = 0;
        for (0..self.rows) |r| {
            for (self.row(@intCast(r))) |c| {
                if (c == tail) continue;
                var buf: [4]u8 = undefined;
                try out.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(c, &buf) catch 0]);
            }
            out.shrinkRetainingCapacity(std.mem.trimEnd(u8, out.items, " ").len);
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') kept = out.items.len;
            try out.append(arena, '\n');
        }
        return out.items[0..kept];
    }

    /// Between sequences, where bytes can be added to the stream without splitting one.
    pub fn settled(self: *const Screen) bool {
        return self.state == .ground and self.utf8_need == 0;
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |b| self.step(b);
    }

    fn cells(self: *Screen) []u21 {
        return if (self.on_alt) self.alt else self.main;
    }

    fn row(self: *const Screen, r: u16) []u21 {
        const all = if (self.on_alt) self.alt else self.main;
        return all[@as(usize, r) * self.cols ..][0..self.cols];
    }

    fn step(self: *Screen, b: u8) void {
        switch (self.state) {
            .ground => {
                if (self.utf8_need > 0) {
                    if (b & 0xC0 == 0x80) {
                        self.utf8[self.utf8_len] = b;
                        self.utf8_len += 1;
                        if (self.utf8_len < self.utf8_need) return;
                        self.utf8_need = 0;
                        self.print(std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch return);
                        return;
                    }
                    self.utf8_need = 0;
                }
                if (b < 0x20 or b == 0x7F) return self.control(b);
                if (b < 0x80) return self.print(b);
                self.utf8_need = std.unicode.utf8ByteSequenceLength(b) catch return;
                self.utf8[0] = b;
                self.utf8_len = 1;
            },
            .esc => self.escape(b),
            .skip => self.state = .ground,
            .csi => switch (b) {
                '0'...'9' => {
                    if (self.nparams == 0) self.param();
                    const p = &self.params[self.nparams - 1];
                    p.* = @min(p.* *| 10 +| (b - '0'), 9999);
                },
                ';', ':' => {
                    if (self.nparams == 0) self.param();
                    self.param();
                },
                '<'...'?' => self.private = true,
                0x20...0x2F => self.intermediate = true,
                0x40...0x7E => {
                    self.state = .ground;
                    if (!self.intermediate) self.dispatch(b);
                },
                0x1B => self.state = .esc,
                else => if (b < 0x20) self.control(b),
            },
            .string => switch (b) {
                0x07 => self.state = .ground,
                0x1B => self.state = .string_esc,
                else => {},
            },
            .string_esc => {
                self.state = .ground;
                if (b != '\\') self.escape(b);
            },
        }
    }

    fn param(self: *Screen) void {
        if (self.nparams == self.params.len) return;
        self.params[self.nparams] = 0;
        self.nparams += 1;
    }

    /// A parameter, with 0 and absent both meaning `default`.
    fn arg(self: *const Screen, i: usize, default: u16) u16 {
        return if (i < self.nparams and self.params[i] != 0) self.params[i] else default;
    }

    fn control(self: *Screen, b: u8) void {
        switch (b) {
            0x08 => self.x -|= 1,
            0x09 => self.x = @min(self.cols - 1, (self.x / 8 + 1) * 8),
            0x0A, 0x0B, 0x0C => self.lineFeed(),
            0x0D => self.x = 0,
            0x1B => self.state = .esc,
            else => return,
        }
        if (b != 0x0A and b != 0x0B and b != 0x0C and b != 0x1B) self.wrap_next = false;
    }

    fn escape(self: *Screen, b: u8) void {
        self.state = .ground;
        switch (b) {
            '[' => {
                self.state = .csi;
                self.nparams = 0;
                self.private = false;
                self.intermediate = false;
            },
            ']', 'P', 'X', '^', '_' => self.state = .string,
            '(', ')', '*', '+', '-', '.', '/' => self.state = .skip,
            '7' => self.saved = .{ self.x, self.y },
            '8' => self.restore(),
            'D' => self.lineFeed(),
            'E' => {
                self.x = 0;
                self.lineFeed();
            },
            'M' => if (self.y == self.top) self.scroll(self.top, self.bottom, -1) else {
                self.y -|= 1;
            },
            'c' => {
                @memset(self.main, blank);
                @memset(self.alt, blank);
                self.* = .{ .gpa = self.gpa, .cols = self.cols, .rows = self.rows, .main = self.main, .alt = self.alt, .bottom = self.rows - 1 };
            },
            else => {},
        }
    }

    fn restore(self: *Screen) void {
        self.x = @min(self.saved[0], self.cols - 1);
        self.y = @min(self.saved[1], self.rows - 1);
        self.wrap_next = false;
    }

    fn print(self: *Screen, cp: u21) void {
        var buf: [4]u8 = undefined;
        const w: u16 = if (cp < 0x300) 1 else gwidth.gwidth(buf[0 .. std.unicode.utf8Encode(cp, &buf) catch return], .unicode);
        if (w == 0) return;
        if (self.wrap_next or (w == 2 and self.x + 1 >= self.cols)) {
            if (!self.autowrap) return;
            self.x = 0;
            self.lineFeed();
        }
        const line = self.row(self.y);
        line[self.x] = cp;
        if (w == 2 and self.x + 1 < self.cols) line[self.x + 1] = tail;
        if (self.x + w >= self.cols) {
            self.x = self.cols - 1;
            self.wrap_next = true;
        } else self.x += w;
    }

    fn lineFeed(self: *Screen) void {
        self.wrap_next = false;
        if (self.y == self.bottom) self.scroll(self.top, self.bottom, 1) else if (self.y + 1 < self.rows) self.y += 1;
    }

    /// Moves rows `from..=to` up by `n` (down when negative), blanking what is uncovered.
    fn scroll(self: *Screen, from: u16, to: u16, n: i32) void {
        if (from > to) return;
        const all = self.cells();
        const w: usize = self.cols;
        const span: usize = @as(usize, to - from) + 1;
        const k = @min(@abs(n), span);
        const region = all[@as(usize, from) * w ..][0 .. span * w];
        if (n > 0) {
            std.mem.copyForwards(u21, region[0 .. (span - k) * w], region[k * w ..]);
            @memset(region[(span - k) * w ..], blank);
        } else {
            std.mem.copyBackwards(u21, region[k * w ..], region[0 .. (span - k) * w]);
            @memset(region[0 .. k * w], blank);
        }
    }

    fn dispatch(self: *Screen, final: u8) void {
        self.wrap_next = false;
        if (self.private) {
            if (final == 'h' or final == 'l') for (self.params[0..self.nparams]) |mode| self.setMode(mode, final == 'h');
            return;
        }
        const n = self.arg(0, 1);
        const line = self.row(self.y);
        switch (final) {
            'A' => self.y -|= n,
            'B', 'e' => self.y = @min(self.rows - 1, self.y +| n),
            'C', 'a' => self.x = @min(self.cols - 1, self.x +| n),
            'D' => self.x -|= n,
            'E', 'F' => {
                self.y = if (final == 'E') @min(self.rows - 1, self.y +| n) else self.y -| n;
                self.x = 0;
            },
            'G', '`' => self.x = @min(self.cols - 1, n - 1),
            'd' => self.y = @min(self.rows - 1, n - 1),
            'H', 'f' => {
                self.y = @min(self.rows - 1, n - 1);
                self.x = @min(self.cols - 1, self.arg(1, 1) - 1);
            },
            'J' => {
                const all = self.cells();
                const at = @as(usize, self.y) * self.cols + self.x;
                switch (self.arg(0, 0)) {
                    0 => @memset(all[at..], blank),
                    1 => @memset(all[0 .. at + 1], blank),
                    else => @memset(all, blank),
                }
            },
            'K' => switch (self.arg(0, 0)) {
                0 => @memset(line[self.x..], blank),
                1 => @memset(line[0 .. self.x + 1], blank),
                else => @memset(line, blank),
            },
            'L', 'M' => if (self.y >= self.top and self.y <= self.bottom)
                self.scroll(self.y, self.bottom, if (final == 'M') @as(i32, n) else -@as(i32, n)),
            '@' => {
                const k = @min(n, self.cols - self.x);
                std.mem.copyBackwards(u21, line[self.x + k ..], line[self.x .. self.cols - k]);
                @memset(line[self.x..][0..k], blank);
            },
            'P' => {
                const k = @min(n, self.cols - self.x);
                std.mem.copyForwards(u21, line[self.x .. self.cols - k], line[self.x + k ..]);
                @memset(line[self.cols - k ..], blank);
            },
            'X' => @memset(line[self.x..][0..@min(n, self.cols - self.x)], blank),
            'S' => self.scroll(self.top, self.bottom, n),
            'T' => self.scroll(self.top, self.bottom, -@as(i32, n)),
            'r' => {
                const t = self.arg(0, 1) - 1;
                const bot = @min(self.arg(1, self.rows), self.rows) - 1;
                self.top, self.bottom = if (t < bot) .{ t, bot } else .{ 0, self.rows - 1 };
                self.x = 0;
                self.y = 0;
            },
            's' => self.saved = .{ self.x, self.y },
            'u' => self.restore(),
            else => {},
        }
    }

    fn setMode(self: *Screen, mode: u16, on: bool) void {
        switch (mode) {
            7 => self.autowrap = on,
            47, 1047, 1049 => {
                if (on == self.on_alt) return;
                if (mode == 1049 and on) self.saved = .{ self.x, self.y };
                self.on_alt = on;
                if (on and mode != 47) @memset(self.alt, blank);
                if (mode == 1049 and !on) self.restore();
            },
            else => {},
        }
    }
};

const testing = std.testing;

fn screenOf(cols: u16, rows: u16, bytes: []const u8) !Screen {
    var s = try Screen.init(testing.allocator, cols, rows);
    s.feed(bytes);
    return s;
}

fn expectText(s: *const Screen, want: []const u8) !void {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings(want, try s.text(a.allocator()));
}

test "text, newlines and wrapping land where a terminal puts them" {
    var s = try screenOf(10, 4, "hello\r\nworld, wrapped\r\n");
    defer s.deinit();
    try expectText(&s, "hello\nworld, wra\npped");
}

test "an agent redrawing its last lines leaves only the new ones" {
    // What ink-based TUIs send: up, erase, rewrite.
    var s = try screenOf(20, 5, "> task\r\n● thinking\r\n\x1b[1A\x1b[2K\x1b[G● done\r\n\x1b[31mred\x1b[0m\x1b]0;title\x07");
    defer s.deinit();
    try expectText(&s, "> task\n● done\nred");
}

test "a sequence split across reads is the same sequence" {
    var s = try Screen.init(testing.allocator, 20, 3);
    defer s.deinit();
    for ("ab\x1b[2;3Hé日\x1b[1;1H") |b| s.feed(&.{b});
    try expectText(&s, "ab\n  é日");
    try testing.expectEqual(@as(u16, 0), s.y);
}

test "wide characters take two cells and wrap as one" {
    var s = try screenOf(5, 3, "ab日本語");
    defer s.deinit();
    try expectText(&s, "ab日\n本語");
}

test "the alternate screen comes and goes and the main one survives it" {
    var s = try screenOf(10, 3, "shell$ \x1b[?1049h\x1b[Hfull screen");
    defer s.deinit();
    try expectText(&s, "full scree\nn");
    s.feed("\x1b[?1049lok");
    try expectText(&s, "shell$ ok");
}

test "a full screen scrolls, and a scroll region keeps what is outside it" {
    var s = try screenOf(8, 3, "1\r\n2\r\n3\r\n4");
    defer s.deinit();
    try expectText(&s, "2\n3\n4");
    s.feed("\x1b[2;3r\x1b[3;1H\n5");
    try expectText(&s, "2\n4\n5");
}

test "erasing, inserting and deleting characters and lines" {
    var s = try screenOf(10, 4, "abcdef\r\nline2\r\nline3");
    defer s.deinit();
    s.feed("\x1b[1;3H\x1b[2P\x1b[1;1H\x1b[1@\x1b[2;1H\x1b[1M\x1b[1;4H\x1b[K");
    try expectText(&s, " ab\nline3");
}

test "resizing keeps the top left" {
    var s = try screenOf(10, 3, "abcdefghij\r\n2\r\n3");
    defer s.deinit();
    try s.resize(4, 2);
    try expectText(&s, "abcd\n2");
}

test "settled only between sequences, never inside one" {
    var s = try Screen.init(testing.allocator, 10, 2);
    defer s.deinit();
    try testing.expect(s.settled());
    for ([_][]const u8{ "\x1b", "\x1b[3", "\x1b]0;tit", "\xe6\x97" }) |part| {
        s.feed(part);
        try testing.expect(!s.settled());
        s.feed(switch (part[part.len - 1]) {
            '3' => "1m",
            't' => "le\x07",
            0x97 => "\xa5",
            else => "[m",
        });
        try testing.expect(s.settled());
    }
}
