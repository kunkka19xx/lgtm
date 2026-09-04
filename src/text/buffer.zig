// SPDX-License-Identifier: Apache-2.0
//
// The buffer is the source of truth; the diff is an overlay over two of them
//. Read-only in v0.1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const edit = @import("edit.zig");

pub const Buffer = struct {
    /// Owned. Lines are slices into this, so it outlives them.
    bytes: []const u8,
    /// Byte offset of each line start, plus a terminating sentinel at bytes.len.
    /// Line i spans starts[i]..starts[i+1], newline included.
    starts: []const u32,
    version: u32,
    gpa: Allocator,

    pub fn initOwned(gpa: Allocator, bytes: []const u8) Allocator.Error!Buffer {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);

        try starts.append(gpa, 0);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, i, '\n')) |nl| {
            try starts.append(gpa, @intCast(nl + 1));
            i = nl + 1;
        }
        if (starts.items[starts.items.len - 1] != bytes.len) {
            try starts.append(gpa, @intCast(bytes.len));
        }

        return .{
            .bytes = bytes,
            .starts = try starts.toOwnedSlice(gpa),
            .version = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.gpa.free(self.bytes);
        self.gpa.free(self.starts);
        self.* = undefined;
    }

    pub fn lineCount(self: Buffer) u32 {
        return @intCast(self.starts.len - 1);
    }

    /// Line contents without the trailing newline. Out of range returns null
    /// rather than trapping: renderers ask for rows past the end routinely.
    pub fn line(self: Buffer, n: u32) ?[]const u8 {
        if (n >= self.lineCount()) return null;
        const from = self.starts[n];
        var to = self.starts[n + 1];
        if (to > from and self.bytes[to - 1] == '\n') to -= 1;
        if (to > from and self.bytes[to - 1] == '\r') to -= 1;
        return self.bytes[from..to];
    }

    pub fn apply(self: *Buffer, e: edit.TextEdit) !void {
        _ = self;
        _ = e;
        return error.NotImplemented;
    }
};

test "line splitting and bounds" {
    const testing = std.testing;
    const src = try testing.allocator.dupe(u8, "alpha\nbeta\n\ngamma");
    var buf = try Buffer.initOwned(testing.allocator, src);
    defer buf.deinit();

    try testing.expectEqual(@as(u32, 4), buf.lineCount());
    try testing.expectEqualStrings("alpha", buf.line(0).?);
    try testing.expectEqualStrings("beta", buf.line(1).?);
    try testing.expectEqualStrings("", buf.line(2).?);
    try testing.expectEqualStrings("gamma", buf.line(3).?);
    try testing.expect(buf.line(4) == null);
}

test "trailing newline does not create a phantom line" {
    const testing = std.testing;
    const src = try testing.allocator.dupe(u8, "one\ntwo\n");
    var buf = try Buffer.initOwned(testing.allocator, src);
    defer buf.deinit();

    try testing.expectEqual(@as(u32, 2), buf.lineCount());
    try testing.expectEqualStrings("two", buf.line(1).?);
}

test "crlf is stripped from line contents" {
    const testing = std.testing;
    const src = try testing.allocator.dupe(u8, "one\r\ntwo\r\n");
    var buf = try Buffer.initOwned(testing.allocator, src);
    defer buf.deinit();

    try testing.expectEqualStrings("one", buf.line(0).?);
    try testing.expectEqualStrings("two", buf.line(1).?);
}

test "empty buffer has no lines" {
    const testing = std.testing;
    const src = try testing.allocator.dupe(u8, "");
    var buf = try Buffer.initOwned(testing.allocator, src);
    defer buf.deinit();

    try testing.expectEqual(@as(u32, 0), buf.lineCount());
    try testing.expect(buf.line(0) == null);
}

test "apply is not implemented in v0.1" {
    const testing = std.testing;
    const src = try testing.allocator.dupe(u8, "x");
    var buf = try Buffer.initOwned(testing.allocator, src);
    defer buf.deinit();

    const zero: edit.Position = .{ .line = 0, .byte = 0 };
    try testing.expectError(error.NotImplemented, buf.apply(.{
        .range = .{ .start = zero, .end = zero },
        .new_text = "y",
    }));
}
