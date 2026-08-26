// SPDX-License-Identifier: Apache-2.0
//
// Quarantine boundary. Zig 0.16 moved Dir and File out of std.fs into std.Io;
// no other module imports either.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Io = std.Io;
pub const Dir = std.Io.Dir;
pub const File = std.Io.File;

pub const ReadError = Dir.ReadFileAllocError;

/// Whole-file read in one allocation. Callers slice the result for lines
/// rather than iterating a reader (PERFORMANCE.md 8.2).
pub fn readFile(io: Io, gpa: Allocator, path: []const u8, max_bytes: usize) ReadError![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
}

pub fn fileExists(io: Io, path: []const u8) bool {
    const file = Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

test "readFile returns file contents" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = readFile(io, testing.allocator, "build.zig.zon", 1 << 20) catch |err| {
        // The test runner's cwd is not guaranteed to be the project root.
        if (err == error.FileNotFound) return;
        return err;
    };
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 0);
}
