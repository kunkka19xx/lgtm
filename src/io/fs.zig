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

/// Entry names of a directory, sorted. Caller owns the slice and each name.
pub fn listDir(io: Io, gpa: Allocator, path: []const u8) ![][]u8 {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    const out = try names.toOwnedSlice(gpa);
    std.mem.sort([]u8, out, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out;
}

/// Every file under `root` whose extension is in `exts`, recursively, sorted.
/// Paths are relative to `root` prefixed with it, so they are usable as-is.
/// Caller owns the slice and each path.
pub fn walkExt(io: Io, gpa: Allocator, root: []const u8, exts: []const []const u8) ![][]u8 {
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const dot = std.mem.lastIndexOfScalar(u8, entry.basename, '.') orelse continue;
        const ext = entry.basename[dot + 1 ..];
        for (exts) |want| {
            if (!std.mem.eql(u8, ext, want)) continue;
            try paths.append(gpa, try std.mem.concat(gpa, u8, &.{ root, "/", entry.path }));
            break;
        }
    }

    const out = try paths.toOwnedSlice(gpa);
    std.mem.sort([]u8, out, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out;
}

pub fn freeNames(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Size and modification time, for cheap change detection. Absent when the
/// file cannot be stat'd, which the watcher treats as "not there right now"
/// rather than an error: files appear and disappear under an active agent.
pub const Meta = struct { size: u64, mtime_ns: i128 };

pub fn statFile(io: Io, path: []const u8) ?Meta {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
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
