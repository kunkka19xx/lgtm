// SPDX-License-Identifier: Apache-2.0
//
// Quarantine boundary. No other module imports std.process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const RunError = std.process.RunError || error{ ProcessFailed, WriteFailure, ReadFailure };

/// How long a subprocess may take before it is killed. Every one of these
/// runs while the reader waits, and one that never answers hangs the pane.
/// Generous, because it is a backstop rather than a budget.
pub const default_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } };

/// What a call over somebody else's network gets. `gh` past ten seconds is a
/// rate limit or a host that is not answering; neither improves with thirty.
pub const network_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } };

/// A deadline in seconds, for a caller whose budget is neither of the two
/// above.
pub fn seconds(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } };
}

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Opens a `git` argv: the program, the flag that keeps it out of the reader's
/// way, and `-C <repo>` when there is one.
///
/// `--no-optional-locks` is the load-bearing part, and it lives here rather
/// than at each call site because forgetting it once is enough to break
/// somebody's rebase. `git status` and `git diff` refresh the index as a side
/// effect and write it back under `.git/index.lock`; this tool runs both on a
/// timer, against a repository whose owner is also using it. Two seconds into a
/// `git pull --rebase` the reader gets
///
///     error: Unable to create '.git/index.lock': File exists.
///     hint: Could not execute the todo command
///
/// from their *own* git, and the rebase stops mid-way. The flag drops the
/// optional write and changes no answer, which is what it exists for.
///
/// Only *optional* locks: a command whose job is to write an index still
/// writes one, so the snapshot store's plumbing is unaffected - it has an
/// index of its own through `GIT_INDEX_FILE` and never touches the repo's.
pub fn gitArgv(
    gpa: Allocator,
    argv: *std.ArrayList([]const u8),
    repo: ?[]const u8,
) Allocator.Error!void {
    try argv.appendSlice(gpa, &.{ "git", "--no-optional-locks" });
    if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
}

/// Runs argv to completion and captures stdout. Used for `git diff` and the
/// bridge backends, which are the only subprocesses lgtm spawns.
///
/// The module default applies: forty call sites, almost none with an opinion.
/// `runWithin` is for the few that have one.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, max_output: usize) RunError!Output {
    return runWithin(gpa, io, argv, max_output, default_timeout);
}

/// This binary again, as `lgtm <args>` in `cwd`, talking over pipes: a helper that outlives one request.
pub fn spawnSelf(io: Io, arena: Allocator, cwd: []const u8, args: []const []const u8) !std.process.Child {
    var exe_buf: [4096]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, args });
    return std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
}

/// As `run`, with the caller's own deadline. `gh` over a network and
/// `git diff` on a large repository do not want the same budget.
pub fn runWithin(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    max_output: usize,
    timeout: Io.Timeout,
) RunError!Output {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(64 << 10),
        .timeout = timeout,
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
        .timeout = default_timeout,
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

test "every git invocation carries --no-optional-locks" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try gitArgv(gpa, &argv, null);
    try std.testing.expectEqualStrings("git", argv.items[0]);
    // Second, and before any subcommand: it is a top-level option, and a
    // reader mid-rebase is what it is there for.
    try std.testing.expectEqualStrings("--no-optional-locks", argv.items[1]);
    try std.testing.expectEqual(@as(usize, 2), argv.items.len);

    argv.clearRetainingCapacity();
    try gitArgv(gpa, &argv, "/tmp/repo");
    try std.testing.expectEqualStrings("--no-optional-locks", argv.items[1]);
    try std.testing.expectEqualStrings("-C", argv.items[2]);
    try std.testing.expectEqualStrings("/tmp/repo", argv.items[3]);
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

/// Ends the process with a status of the caller's choosing.
///
/// Here rather than at its one call site because this file is where
/// `std.process` is allowed to be. `lgtm <git command>` is a hand-off, and
/// what a hand-off owes the shell is the code the child exited with.
pub fn exit(status: u8) noreturn {
    std.process.exit(status);
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
/// one subprocess instead of one per file, and for every `gh` call that takes
/// a JSON body on stdin.
pub fn runWithInput(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
) RunError!Output {
    return runWithInputWithin(gpa, io, argv, stdin_data, max_output, default_timeout);
}

/// As `runWithInput`, with the caller's own deadline.
///
/// Built on a `MultiReader` over stdout and stderr the way `std.process.run`
/// is: a drain that reads only stdout blocks forever on a child that fills
/// the stderr pipe first. The stdin write is all that is its own.
///
/// Known and not fixed: stdin is written in full before any output is read,
/// so a child that fills its output pipe meanwhile can still deadlock. The
/// payloads are small everywhere but the batch blob reads.
pub fn runWithInputWithin(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
    timeout: Io.Timeout,
) RunError!Output {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // What makes the deadline a deadline: a child still running when this
    // returns is killed rather than left behind.
    defer child.kill(io);

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

    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    const out_r = multi.reader(0);
    const err_r = multi.reader(1);
    while (multi.fill(64, timeout)) |_| {
        if (out_r.buffered().len > max_output) return error.StreamTooLong;
        if (err_r.buffered().len > stderr_max) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();

    const term = try child.wait(io);
    const out = try multi.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_text = try multi.toOwnedSlice(1);
    return .{
        .stdout = out,
        .stderr = err_text,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

/// What a child may say about itself before we stop listening. A diagnostic,
/// not an answer: anything past this is a program in a loop.
const stderr_max: usize = 64 << 10;

test "runWithInput feeds stdin and collects stdout" {
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    const out = try runWithInput(testing.allocator, threaded.io(), &.{"cat"}, "hello\nworld\n", 1 << 16);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), out.exit_code);
    try testing.expectEqualStrings("hello\nworld\n", out.stdout);
}

test "a noisy child comes back rather than blocking on its own stderr" {
    // A child that fills the stderr pipe before touching stdout used to block
    // forever. It now ends at the cap, and the test is that it ends at all.
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    try testing.expectError(error.StreamTooLong, runWithInput(
        testing.allocator,
        threaded.io(),
        &.{ "sh", "-c", "yes loud | head -c 200000 >&2; cat" },
        "quiet\n",
        1 << 20,
    ));

    // Under the cap it is read whole, alongside stdout, which the old drain
    // never returned at all.
    const out = try runWithInput(testing.allocator, threaded.io(), &.{
        "sh", "-c", "printf 'warned' >&2; cat",
    }, "quiet\n", 1 << 20);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("quiet\n", out.stdout);
    try testing.expectEqualStrings("warned", out.stderr);
}

test "a child that never answers hits the deadline instead of the pane" {
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{ .environ = testing.environ });
    defer threaded.deinit();

    const quick: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(150), .clock = .awake } };
    try testing.expectError(error.Timeout, runWithin(
        testing.allocator,
        threaded.io(),
        &.{ "sleep", "30" },
        1 << 16,
        quick,
    ));
    try testing.expectError(error.Timeout, runWithInputWithin(
        testing.allocator,
        threaded.io(),
        &.{ "sh", "-c", "cat >/dev/null; sleep 30" },
        "x",
        1 << 16,
        quick,
    ));
}
