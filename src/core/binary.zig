// SPDX-License-Identifier: Apache-2.0
//
// What to say about a file whose bytes are not text.
//
// Git decides binary the same way and then prints one line about it; an
// untracked file never reaches git's diff at all, so the test lives here and
// both paths use it. Rendering the bytes is the one thing a reviewer can never
// use: a PNG drawn as latin-1 is a screen of noise that hides the rest of the
// review under it.

const std = @import("std");

/// Git's rule: a NUL byte in the first 8000 bytes. Matching it keeps a
/// synthesised entry for an untracked file and a parsed one for a tracked file
/// saying the same thing about the same file.
pub const sniff_bytes = 8000;

pub fn isBinary(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, sniff_bytes)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

/// Enough header bytes for every dimension probe below. WebP's VP8X is the
/// deepest at 30.
pub const head_bytes = 64;

/// What the header row shows in place of the diff.
pub const Info = struct {
    /// A static label, or the uppercased extension when the magic bytes are
    /// not one this knows.
    kind: []const u8 = "binary",
    /// Zero when the file is not an image, or is one whose header did not
    /// parse.
    width: u32 = 0,
    height: u32 = 0,
    size: u64 = 0,
    /// The file is in the diff but not on disk: it was deleted. There is
    /// nothing to describe beyond its name, so the row says that instead.
    gone: bool = false,

    pub fn hasDimensions(self: Info) bool {
        return self.width > 0 and self.height > 0;
    }
};

/// `head` may be short: every probe checks its own length first.
pub fn describe(path: []const u8, head: []const u8, size: u64) Info {
    var out: Info = .{ .size = size, .kind = kindOf(head) };
    if (out.kind.len == 0) out.kind = kindFromExt(path);
    dimensions(head, &out);
    return out;
}

fn kindOf(h: []const u8) []const u8 {
    if (starts(h, "\x89PNG\r\n\x1a\n")) return "PNG image";
    if (starts(h, "\xff\xd8\xff")) return "JPEG image";
    if (starts(h, "GIF87a") or starts(h, "GIF89a")) return "GIF image";
    if (starts(h, "RIFF") and h.len >= 12) {
        if (std.mem.eql(u8, h[8..12], "WEBP")) return "WebP image";
        if (std.mem.eql(u8, h[8..12], "WAVE")) return "WAV audio";
        if (std.mem.eql(u8, h[8..12], "AVI ")) return "AVI video";
    }
    if (starts(h, "BM")) return "BMP image";
    if (starts(h, "\x00\x00\x01\x00")) return "icon";
    if (starts(h, "%PDF")) return "PDF document";
    if (starts(h, "SQLite format 3")) return "SQLite database";
    if (starts(h, "\x00asm")) return "WebAssembly module";
    if (starts(h, "\x7fELF")) return "ELF binary";
    if (starts(h, "\xcf\xfa\xed\xfe") or starts(h, "\xca\xfe\xba\xbe")) return "Mach-O binary";
    if (starts(h, "OggS")) return "Ogg audio";
    if (starts(h, "ID3") or starts(h, "\xff\xfb")) return "MP3 audio";
    if (starts(h, "fLaC")) return "FLAC audio";
    if (starts(h, "\x1f\x8b")) return "gzip archive";
    if (starts(h, "PK\x03\x04")) return "zip archive";
    if (starts(h, "\xfd7zXZ")) return "xz archive";
    if (starts(h, "wOFF") or starts(h, "wOF2") or starts(h, "OTTO") or starts(h, "\x00\x01\x00\x00")) return "font";
    // An `ftyp` box at byte 4 is mp4, m4a, mov and heic all at once; the brand
    // that tells them apart is the extension, which the table below reads.
    return "";
}

/// The kind an extension claims, for the one case the magic bytes cannot
/// answer: a file that is in the diff because it was deleted.
pub fn kindFromExt(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "binary";
    const ext = path[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return "binary";
    // Uppercased in place would need an allocation; the extensions worth
    // naming are few enough to answer from a table, and anything else is
    // honestly just "binary".
    const known = [_]struct { []const u8, []const u8 }{
        .{ "png", "PNG image" },
        .{ "jpg", "JPEG image" },
        .{ "jpeg", "JPEG image" },
        .{ "gif", "GIF image" },
        .{ "webp", "WebP image" },
        .{ "bmp", "BMP image" },
        .{ "ico", "icon" },
        .{ "pdf", "PDF document" },
        .{ "zip", "zip archive" },
        .{ "gz", "gzip archive" },
        .{ "mp3", "MP3 audio" },
        .{ "wav", "WAV audio" },
        .{ "ogg", "Ogg audio" },
        .{ "flac", "FLAC audio" },
        .{ "sqlite", "SQLite database" },
        .{ "mp4", "MP4 video" },
        .{ "mov", "MOV video" },
        .{ "webm", "WebM video" },
        .{ "m4a", "M4A audio" },
        .{ "heic", "HEIC image" },
        .{ "avif", "AVIF image" },
        .{ "svgz", "compressed SVG" },
        .{ "ttf", "font" },
        .{ "otf", "font" },
        .{ "woff", "font" },
        .{ "woff2", "font" },
        .{ "so", "shared library" },
        .{ "dylib", "shared library" },
        .{ "a", "static library" },
        .{ "o", "object file" },
        .{ "wasm", "WebAssembly module" },
        .{ "db", "database" },
        .{ "bin", "binary" },
    };
    for (known) |k| if (std.ascii.eqlIgnoreCase(ext, k[0])) return k[1];
    return "binary";
}

fn dimensions(h: []const u8, out: *Info) void {
    if (starts(h, "\x89PNG\r\n\x1a\n") and h.len >= 24) {
        out.width = be32(h[16..20]);
        out.height = be32(h[20..24]);
        return;
    }
    if (starts(h, "GIF8") and h.len >= 10) {
        out.width = le16(h[6..8]);
        out.height = le16(h[8..10]);
        return;
    }
    if (starts(h, "BM") and h.len >= 26) {
        out.width = le32(h[18..22]);
        // A negative height means top-down rows, not a negative image.
        const raw = le32(h[22..26]);
        out.height = if (raw & 0x8000_0000 != 0) ~raw +% 1 else raw;
        return;
    }
    if (starts(h, "RIFF") and h.len >= 30 and std.mem.eql(u8, h[8..12], "WEBP")) {
        webp(h, out);
        return;
    }
    if (starts(h, "\xff\xd8\xff")) jpeg(h, out);
}

/// Three container shapes, one format. Lossy holds the size in 14 bits after
/// the start code, lossless packs 14+14 across four bytes, and the extended
/// header stores each side minus one in three little-endian bytes.
fn webp(h: []const u8, out: *Info) void {
    const tag = h[12..16];
    if (std.mem.eql(u8, tag, "VP8 ") and h.len >= 30) {
        out.width = le16(h[26..28]) & 0x3fff;
        out.height = le16(h[28..30]) & 0x3fff;
    } else if (std.mem.eql(u8, tag, "VP8L") and h.len >= 25) {
        const bits: u32 = @as(u32, h[21]) | (@as(u32, h[22]) << 8) | (@as(u32, h[23]) << 16) | (@as(u32, h[24]) << 24);
        out.width = (bits & 0x3fff) + 1;
        out.height = ((bits >> 14) & 0x3fff) + 1;
    } else if (std.mem.eql(u8, tag, "VP8X") and h.len >= 30) {
        out.width = le24(h[24..27]) + 1;
        out.height = le24(h[27..30]) + 1;
    }
}

/// Walks the marker segments to the first frame header. `head_bytes` is rarely
/// enough to reach it - a JPEG usually carries EXIF first - so this stops at
/// whatever it was given and leaves the dimensions at zero.
fn jpeg(h: []const u8, out: *Info) void {
    var i: usize = 2;
    while (i + 9 < h.len) {
        if (h[i] != 0xff) {
            i += 1;
            continue;
        }
        const marker = h[i + 1];
        if (marker == 0xd8 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) {
            i += 2;
            continue;
        }
        const len = (@as(usize, h[i + 2]) << 8) | h[i + 3];
        const frame = marker >= 0xc0 and marker <= 0xcf and
            marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (frame) {
            out.height = (@as(u32, h[i + 5]) << 8) | h[i + 6];
            out.width = (@as(u32, h[i + 7]) << 8) | h[i + 8];
            return;
        }
        if (len < 2) return;
        i += 2 + len;
    }
}

fn starts(h: []const u8, magic: []const u8) bool {
    return h.len >= magic.len and std.mem.eql(u8, h[0..magic.len], magic);
}

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn le16(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8);
}

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn le24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// `244 KB`, `1.2 MB`. Two significant figures is all the row needs: the
/// question it answers is "how big roughly", never "how many bytes".
pub fn humanSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ n, units[0] }) catch "?";
    if (value >= 100) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ value, units[unit] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

const testing = std.testing;

test "a NUL in the first 8000 bytes is what makes a file binary" {
    try testing.expect(!isBinary("plain text\nwith no zero byte\n"));
    try testing.expect(isBinary("PK\x03\x04\x00\x00"));
    var late: [9000]u8 = @splat('a');
    late[8500] = 0;
    try testing.expect(!isBinary(&late));
}

test "PNG, GIF and BMP headers give dimensions" {
    var png: [24]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    png[18] = 0x02; // 512
    png[23] = 0x40; // 64
    const p = describe("logo.png", &png, 1024);
    try testing.expectEqualStrings("PNG image", p.kind);
    try testing.expectEqual(@as(u32, 512), p.width);
    try testing.expectEqual(@as(u32, 64), p.height);

    const gif = "GIF89a\x20\x00\x10\x00";
    const g = describe("anim.gif", gif, 10);
    try testing.expectEqualStrings("GIF image", g.kind);
    try testing.expectEqual(@as(u32, 32), g.width);
    try testing.expectEqual(@as(u32, 16), g.height);

    var bmp: [26]u8 = @splat(0);
    @memcpy(bmp[0..2], "BM");
    bmp[18] = 0x0a;
    bmp[22] = 0x05;
    const b = describe("x.bmp", &bmp, 26);
    try testing.expectEqualStrings("BMP image", b.kind);
    try testing.expectEqual(@as(u32, 10), b.width);
    try testing.expectEqual(@as(u32, 5), b.height);
}

test "a JPEG frame header inside the sniffed bytes gives dimensions" {
    var jpg: [20]u8 = @splat(0);
    @memcpy(jpg[0..3], "\xff\xd8\xff");
    jpg[3] = 0xc0;
    jpg[4] = 0x00;
    jpg[5] = 0x11;
    jpg[7] = 0x01; // height 256
    jpg[10] = 0x80; // width 128
    const j = describe("photo.jpg", &jpg, 5000);
    try testing.expectEqualStrings("JPEG image", j.kind);
    try testing.expectEqual(@as(u32, 128), j.width);
    try testing.expectEqual(@as(u32, 256), j.height);
}

test "an unknown magic falls back to the extension, then to binary" {
    const bytes = "\x01\x02\x03\x04";
    try testing.expectEqualStrings("MP4 video", describe("clip.mp4", bytes, 1).kind);
    try testing.expectEqualStrings("binary", describe("blob.xyz", bytes, 1).kind);
    try testing.expectEqualStrings("binary", describe("noext", bytes, 1).kind);
}

test "sizes round to two significant figures" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512 B", humanSize(&buf, 512));
    try testing.expectEqualStrings("1.0 KB", humanSize(&buf, 1024));
    try testing.expectEqualStrings("244 KB", humanSize(&buf, 250_000));
    try testing.expectEqualStrings("1.2 MB", humanSize(&buf, 1_258_291));
}
