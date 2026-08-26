// SPDX-License-Identifier: Apache-2.0
//
// Quarantine boundary. No other module imports std.process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const RunError = std.process.RunError || error{ProcessFailed};

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
