// SPDX-License-Identifier: Apache-2.0
//
// Images from the phone for an agent: saved inside its repo, where it can read them without asking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../io/fs.zig");

pub const max_bytes = 20 << 20;
const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".heic", ".gif", ".webp" };

pub const Error = error{ NotAnImage, OutOfOrder, TooBig, BadData } || Allocator.Error;

/// A name safe on disk, kept only for an image: letters, digits, `.`, `-` and `_`.
pub fn clean(buf: []u8, name: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(name);
    const ext = std.fs.path.extension(base);
    const ok = for (exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) break true;
    } else false;
    if (!ok or base.len > buf.len) return null;
    for (base, buf[0..base.len]) |c, *o| o.* = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_';
    return buf[0..base.len];
}

/// One image arriving in parts, in order.
pub const Upload = struct {
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    sub_buf: [160]u8 = undefined,
    sub: []const u8 = "",
    next: u32 = 0,
    size: usize = 0,

    /// Writes one part; once `last` has come, the saved file's full path.
    pub fn take(u: *Upload, io: Io, arena: Allocator, root: []const u8, in_repo: bool, name: []const u8, part: u32, data: []const u8, last: bool, secs: i64) !?[]const u8 {
        errdefer u.sub = "";
        if (part == 0) {
            var name_buf: [96]u8 = undefined;
            const n = clean(&name_buf, name) orelse return error.NotAnImage;
            if (root.len > u.root_buf.len) return error.NotAnImage;
            @memcpy(u.root_buf[0..root.len], root);
            u.root = u.root_buf[0..root.len];
            u.sub = try std.fmt.bufPrint(&u.sub_buf, "{s}{d}-{s}", .{ if (in_repo) fs.state_dir ++ "/attachments/" else "attachments/", secs, n });
            u.next = 0;
            u.size = 0;
        } else if (u.sub.len == 0 or part != u.next) return error.OutOfOrder;

        const d = std.base64.standard.Decoder;
        const bytes = try arena.alloc(u8, d.calcSizeForSlice(data) catch return error.BadData);
        d.decode(bytes, data) catch return error.BadData;
        u.size += bytes.len;
        if (u.size > max_bytes) return error.TooBig;
        try fs.writeUnder(io, u.root, u.sub, bytes, part != 0);
        u.next = part + 1;
        if (!last) return null;
        defer u.sub = "";
        return try std.fs.path.join(arena, &.{ u.root, u.sub });
    }
};

const testing = std.testing;

test "only an image name is kept, and nothing in it can leave the directory" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("shot_1.JPG", clean(&buf, "shot 1.JPG").?);
    try testing.expectEqualStrings("x.png", clean(&buf, "../../etc/x.png").?);
    try testing.expect(clean(&buf, "run.sh") == null);
    try testing.expect(clean(&buf, "noext") == null);
}

test "an image arrives in order, and a part out of order is refused" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    var u: Upload = .{};
    try testing.expect(try u.take(io, a.allocator(), root, true, "a.png", 0, "aGVs", false, 7) == null);
    try testing.expectError(error.OutOfOrder, u.take(io, a.allocator(), root, true, "a.png", 5, "bG8=", true, 7));
    try testing.expect(try u.take(io, a.allocator(), root, true, "a.png", 0, "aGVs", false, 7) == null);
    const path = (try u.take(io, a.allocator(), root, true, "a.png", 1, "bG8=", true, 7)).?;
    try testing.expect(std.mem.endsWith(u8, path, ".lgtm/attachments/7-a.png"));
    const got = try tmp.dir.readFileAlloc(io, ".lgtm/attachments/7-a.png", a.allocator(), .limited(64));
    try testing.expectEqualStrings("hello", got);
    _ = try tmp.dir.statFile(io, ".lgtm/.gitignore", .{});
}
