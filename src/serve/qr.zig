// SPDX-License-Identifier: Apache-2.0
//
// QR codes for pairing: byte mode, error correction level M, versions 1 to 10.

const std = @import("std");

const max_size = 17 + 4 * 10;
/// Error-correction codewords per block, and blocks, at level M, by version.
const ec_len = [_]u8{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 };
const blocks = [_]u8{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 };

pub const Code = struct {
    size: usize,
    dark: [max_size][max_size]bool = @splat(@splat(false)),
    function: [max_size][max_size]bool = @splat(@splat(false)),

    fn set(self: *Code, x: usize, y: usize, v: bool) void {
        self.dark[y][x] = v;
        self.function[y][x] = true;
    }
};

const Bits = struct {
    buf: [512]u8 = @splat(0),
    len: usize = 0,

    fn put(self: *Bits, value: u32, count: usize) void {
        for (0..count) |k| {
            if (bit(value, count - 1 - k)) self.buf[self.len / 8] |= @as(u8, 0x80) >> @intCast(self.len % 8);
            self.len += 1;
        }
    }
};

fn bit(value: u32, i: usize) bool {
    return (value >> @intCast(i)) & 1 == 1;
}

fn rawCodewords(v: usize) usize {
    var n = (16 * v + 128) * v + 64;
    if (v >= 2) {
        const a = v / 7 + 2;
        n -= (25 * a - 10) * a - 55;
        if (v >= 7) n -= 36;
    }
    return n / 8;
}

fn dataCodewords(v: usize) usize {
    return rawCodewords(v) - @as(usize, ec_len[v]) * blocks[v];
}

pub fn encode(text: []const u8) error{TooLong}!Code {
    const v = for (1..11) |ver| {
        if (4 + @as(usize, if (ver < 10) 8 else 16) + text.len * 8 <= dataCodewords(ver) * 8) break ver;
    } else return error.TooLong;

    var b: Bits = .{};
    b.put(0b0100, 4);
    b.put(@intCast(text.len), @as(usize, if (v < 10) 8 else 16));
    for (text) |c| b.put(c, 8);
    const capacity = dataCodewords(v) * 8;
    b.put(0, @min(4, capacity - b.len));
    b.len = std.mem.alignForward(usize, b.len, 8);
    var pad: u32 = 0xEC;
    while (b.len < capacity) : (pad ^= 0xEC ^ 0x11) b.put(pad, 8);

    var code: Code = .{ .size = 17 + 4 * v };
    drawFunctions(&code, v);
    var all: [512]u8 = undefined;
    drawCodewords(&code, interleave(b.buf[0 .. capacity / 8], v, &all));

    var best: u3 = 0;
    var best_score: usize = std.math.maxInt(usize);
    for (0..8) |i| {
        const m: u3 = @intCast(i);
        applyMask(&code, m);
        drawFormat(&code, m);
        const s = penalty(&code);
        if (s < best_score) {
            best_score = s;
            best = m;
        }
        applyMask(&code, m);
    }
    applyMask(&code, best);
    drawFormat(&code, best);
    return code;
}

fn interleave(data: []const u8, v: usize, out: *[512]u8) []const u8 {
    const nb: usize = blocks[v];
    const ecl: usize = ec_len[v];
    const raw = rawCodewords(v);
    const short = nb - raw % nb;
    const len = raw / nb;
    var gen: [32]u8 = undefined;
    divisor(gen[0..ecl]);

    // A short block keeps a gap where a long one has its extra data byte.
    var bufs: [8][160]u8 = undefined;
    var k: usize = 0;
    for (0..nb) |i| {
        const dlen = len - ecl + @intFromBool(i >= short);
        @memcpy(bufs[i][0..dlen], data[k..][0..dlen]);
        k += dlen;
        remainder(bufs[i][0..dlen], gen[0..ecl], bufs[i][len - ecl + 1 ..][0..ecl]);
    }
    var n: usize = 0;
    for (0..len + 1) |i| {
        for (0..nb) |j| {
            if (i == len - ecl and j < short) continue;
            out[n] = bufs[j][i];
            n += 1;
        }
    }
    return out[0..n];
}

fn mul(x: u8, y: u8) u8 {
    var z: u16 = 0;
    for (0..8) |k| {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        if (bit(y, 7 - k)) z ^= x;
    }
    return @intCast(z & 0xFF);
}

fn divisor(out: []u8) void {
    @memset(out, 0);
    out[out.len - 1] = 1;
    var root: u8 = 1;
    for (0..out.len) |_| {
        for (out, 0..) |*c, j| {
            c.* = mul(c.*, root);
            if (j + 1 < out.len) c.* ^= out[j + 1];
        }
        root = mul(root, 0x02);
    }
}

fn remainder(data: []const u8, gen: []const u8, out: []u8) void {
    @memset(out, 0);
    for (data) |d| {
        const factor = d ^ out[0];
        std.mem.copyForwards(u8, out[0 .. out.len - 1], out[1..]);
        out[out.len - 1] = 0;
        for (gen, out) |g, *o| o.* ^= mul(g, factor);
    }
}

/// Distance from the centre of a square pattern, which decides its rings.
fn ring(dx: usize, dy: usize, c: usize) usize {
    return @max(@max(dx, c) - @min(dx, c), @max(dy, c) - @min(dy, c));
}

fn drawFunctions(code: *Code, v: usize) void {
    const size = code.size;
    for (0..size) |i| {
        code.set(6, i, i % 2 == 0);
        code.set(i, 6, i % 2 == 0);
    }
    for ([_][2]usize{ .{ 0, 0 }, .{ size - 7, 0 }, .{ 0, size - 7 } }) |o| {
        for (0..9) |dy| {
            for (0..9) |dx| {
                if (o[0] + dx < 1 or o[1] + dy < 1 or o[0] + dx > size or o[1] + dy > size) continue;
                const d = ring(dx, dy, 4);
                code.set(o[0] + dx - 1, o[1] + dy - 1, d != 2 and d != 4);
            }
        }
    }

    var pos: [7]usize = undefined;
    const n = alignment(v, size, &pos);
    for (0..n) |i| {
        for (0..n) |j| {
            if ((i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0)) continue;
            for (0..5) |dy| {
                for (0..5) |dx| code.set(pos[i] + dx - 2, pos[j] + dy - 2, ring(dx, dy, 2) != 1);
            }
        }
    }

    drawFormat(code, 0);
    if (v >= 7) {
        var rem: u32 = @intCast(v);
        for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        const bits = (@as(u32, @intCast(v)) << 12) | rem;
        for (0..18) |i| {
            code.set(size - 11 + i % 3, i / 3, bit(bits, i));
            code.set(i / 3, size - 11 + i % 3, bit(bits, i));
        }
    }
}

fn alignment(v: usize, size: usize, out: *[7]usize) usize {
    if (v == 1) return 0;
    const n = v / 7 + 2;
    const step = (v * 4 + n * 2 + 1) / (n * 2 - 2) * 2;
    out[0] = 6;
    for (1..n) |i| out[i] = size - 7 - (n - 1 - i) * step;
    return n;
}

/// Level M is 0b00 in the format bits, so the mask alone is the data.
fn drawFormat(code: *Code, mask: u3) void {
    var rem: u32 = mask;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    const bits = ((@as(u32, mask) << 10) | rem) ^ 0x5412;
    const size = code.size;
    for (0..6) |i| code.set(8, i, bit(bits, i));
    code.set(8, 7, bit(bits, 6));
    code.set(8, 8, bit(bits, 7));
    code.set(7, 8, bit(bits, 8));
    for (9..15) |i| code.set(14 - i, 8, bit(bits, i));
    for (0..8) |i| code.set(size - 1 - i, 8, bit(bits, i));
    for (8..15) |i| code.set(8, size - 15 + i, bit(bits, i));
    code.set(8, size - 8, true);
}

/// Two columns at a time from the right, snaking up and down, around column 6.
fn drawCodewords(code: *Code, data: []const u8) void {
    const size = code.size;
    var i: usize = 0;
    var right: usize = size - 1;
    while (true) : (right -= 2) {
        if (right == 6) right = 5;
        for (0..size) |vert| {
            for (0..2) |j| {
                const x = right - j;
                const y = if ((right + 1) & 2 == 0) size - 1 - vert else vert;
                if (code.function[y][x] or i >= data.len * 8) continue;
                code.dark[y][x] = bit(data[i / 8], 7 - i % 8);
                i += 1;
            }
        }
        if (right < 2) break;
    }
}

fn applyMask(code: *Code, mask: u3) void {
    for (0..code.size) |y| {
        for (0..code.size) |x| {
            if (code.function[y][x]) continue;
            code.dark[y][x] = code.dark[y][x] != switch (mask) {
                0 => (x + y) % 2 == 0,
                1 => y % 2 == 0,
                2 => x % 3 == 0,
                3 => (x + y) % 3 == 0,
                4 => (x / 3 + y / 2) % 2 == 0,
                5 => x * y % 2 + x * y % 3 == 0,
                6 => (x * y % 2 + x * y % 3) % 2 == 0,
                7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
            };
        }
    }
}

/// The standard's four penalties; the mask scoring lowest is the easiest to scan.
fn penalty(code: *const Code) usize {
    const n = code.size;
    var score: usize = 0;
    var dark: usize = 0;
    for (0..2) |axis| {
        for (0..n) |a| {
            var run: usize = 0;
            var window: u11 = 0;
            for (0..n) |b| {
                const m = if (axis == 0) code.dark[a][b] else code.dark[b][a];
                if (axis == 0 and m) dark += 1;
                if (b > 0 and m == (window & 1 == 1)) {
                    run += 1;
                    if (run == 5) score += 3 else if (run > 5) score += 1;
                } else run = 1;
                window = (window << 1) | @intFromBool(m);
                if (b >= 10 and (window == 0b10111010000 or window == 0b00001011101)) score += 40;
            }
        }
    }
    for (0..n - 1) |y| {
        for (0..n - 1) |x| {
            const c = code.dark[y][x];
            if (c == code.dark[y][x + 1] and c == code.dark[y + 1][x] and c == code.dark[y + 1][x + 1]) score += 3;
        }
    }
    const pct = dark * 100 / (n * n);
    return score + (@max(pct, 50) - @min(pct, 50)) / 5 * 10;
}

/// Two module rows per line in half blocks, dark on light whatever the terminal's colours.
pub fn render(w: *std.Io.Writer, code: *const Code) std.Io.Writer.Error!void {
    const span = code.size + 4;
    var row: usize = 0;
    while (row < span) : (row += 2) {
        try w.writeAll("\x1b[38;5;16;48;5;231m");
        for (0..span) |col| {
            const top = module(code, col, row);
            const bottom = module(code, col, row + 1);
            try w.writeAll(if (top and bottom) "█" else if (top) "▀" else if (bottom) "▄" else " ");
        }
        try w.writeAll("\x1b[0m\n");
    }
}

fn module(code: *const Code, col: usize, row: usize) bool {
    if (col < 2 or row < 2 or col - 2 >= code.size or row - 2 >= code.size) return false;
    return code.dark[row - 2][col - 2];
}

const testing = std.testing;

test "the version grows with the text, stops at ten, and the finders sit in three corners" {
    const url = "lgtm://pair?h=100.101.102.103&p=7777&t=0123456789abcdef0123456789abcdef&n=lgtm";
    try testing.expectEqual(@as(usize, 37), (try encode(url)).size);
    try testing.expectEqual(@as(usize, 41), (try encode(url ++ "-longer-repo-name")).size);
    const long: [300]u8 = @splat('a');
    try testing.expectError(error.TooLong, encode(&long));

    const c = try encode("lgtm");
    try testing.expectEqual(@as(usize, 21), c.size);
    for ([_][2]usize{ .{ 0, 0 }, .{ 14, 0 }, .{ 0, 14 } }) |o| {
        try testing.expect(c.dark[o[1]][o[0]] and !c.dark[o[1] + 1][o[0] + 1] and c.dark[o[1] + 3][o[0] + 3]);
    }
    try testing.expect(c.dark[c.size - 8][8]);
}

test "data codewords at level M match the standard's table" {
    const want = [_]usize{ 0, 16, 28, 44, 64, 86, 108, 124, 154, 182, 216 };
    for (1..11) |v| try testing.expectEqual(want[v], dataCodewords(v));
}

test "reed-solomon matches the standard's worked example" {
    // ISO 18004 annex I: version 1-M "01234567".
    const data = [_]u8{ 0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
    var gen: [10]u8 = undefined;
    divisor(&gen);
    var ec: [10]u8 = undefined;
    remainder(&data, &gen, &ec);
    try testing.expectEqualSlices(u8, &.{ 0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55 }, &ec);
}
