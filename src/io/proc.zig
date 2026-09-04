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

/// As `run`, with the child's whole environment replaced.
///
/// Replaced rather than extended, because that is what `std.process` offers -
/// so the caller passes the parent's map with its own keys added, and a caller
/// that forgets loses `PATH` for everything but `argv[0]`. The one user is the
/// snapshot store, which needs `GIT_INDEX_FILE` and has no other way to set it:
/// git reads it from the environment and there is no flag for it, which is the
/// whole reason this function exists (never write the
/// user's own `.git/index`).
pub fn runEnv(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    max_output: usize,
    environ: *const std.process.Environ.Map,
) RunError!Output {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = environ,
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
    // The real binary gets its environ from `std.process.Init`; a test has to
    // hand it over explicitly, or the child inherits no PATH and std falls back
    // to "/usr/local/bin:/bin/:/usr/bin" - empty on NixOS, so argv[0] never resolves.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    const out = try run(testing.allocator, threaded.io(), &.{ "echo", "ok" }, 1 << 16);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), out.exit_code);
    try testing.expectEqualStrings("ok\n", out.stdout);
}

/// Runs argv with the parent's own terminal and waits for it to finish.
///
/// The child owns the tty while it runs, which is the whole point - `e` hands
/// it to `$EDITOR`. The caller is responsible for having stopped reading input
/// and restored the terminal modes first; nothing here can check that.
pub fn runInherit(io: Io, argv: []const []const u8) RunError!u8 {
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = child.wait(io) catch return error.ProcessFailed;
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

test "runInherit waits for the child and reports its status" {
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    try testing.expectEqual(@as(u8, 0), try runInherit(threaded.io(), &.{"true"}));
    // A non-zero exit must come back as itself: an editor that failed to open
    // is something the status line should be able to say.
    try testing.expect(try runInherit(threaded.io(), &.{"false"}) != 0);
}

/// Runs argv, writes `stdin_data` to its standard input, and collects stdout.
///
/// Needed for `git cat-file --batch`, which is how many blobs are fetched in
/// one subprocess instead of one per file.
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
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    const out = try runWithInput(testing.allocator, threaded.io(), &.{"cat"}, "hello\nworld\n", 1 << 16);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), out.exit_code);
    try testing.expectEqualStrings("hello\nworld\n", out.stdout);
}
