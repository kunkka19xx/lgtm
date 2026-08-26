// SPDX-License-Identifier: Apache-2.0
//
// Quarantine boundary. No other module imports std.process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const RunError = std.process.RunError || error{ ProcessFailed, WriteFailure, ReadFailure };

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Runs argv to completion and captures stdout. Used for `git diff` and the
/// bridge backends, which are the only subprocesses lgtm spawns.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, max_output: usize) RunError!Output {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(64 << 10),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

test "run captures stdout" {
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const out = try run(testing.allocator, threaded.io(), &.{ "echo", "ok" }, 1 << 16);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), out.exit_code);
    try testing.expectEqualStrings("ok\n", out.stdout);
}

/// Runs argv, writes `stdin_data` to its standard input, and collects stdout.
///
/// Needed for `git cat-file --batch`, which is how many blobs are fetched in
/// one subprocess instead of one per file (PERFORMANCE.md 8.1).
pub fn runWithInput(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
) RunError!Output {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer _ = child.wait(io) catch {};

    // Feed stdin and close it before draining, so the child sees EOF and
    // finishes rather than both sides waiting on each other.
    {
        var buf: [64 << 10]u8 = undefined;
        var w = child.stdin.?.writer(io, &buf);
        w.interface.writeAll(stdin_data) catch return error.WriteFailure;
        w.interface.flush() catch return error.WriteFailure;
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var out_buf: [64 << 10]u8 = undefined;
    var reader = child.stdout.?.reader(io, &out_buf);
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(gpa);
    reader.interface.appendRemaining(gpa, &collected, .limited(max_output)) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailure,
        else => |e| return e,
    };

    const term = try child.wait(io);
    return .{
        .stdout = try collected.toOwnedSlice(gpa),
        .stderr = try gpa.dupe(u8, ""),
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

test "runWithInput feeds stdin and collects stdout" {
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const out = try runWithInput(testing.allocator, threaded.io(), &.{"cat"}, "hello\nworld\n", 1 << 16);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), out.exit_code);
    try testing.expectEqualStrings("hello\nworld\n", out.stdout);
}
