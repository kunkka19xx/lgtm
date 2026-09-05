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
/// rather than iterating a reader.
pub fn readFile(io: Io, gpa: Allocator, path: []const u8, max_bytes: usize) ReadError![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
}

/// The first `buf.len` bytes, for callers that only need a header: sniffing a
/// binary file's kind must not pull a 40 MB video into memory to do it.
pub fn readHead(io: Io, path: []const u8, buf: []u8) ?[]u8 {
    const file = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

pub const WriteError = Dir.WriteFileError || Dir.CreateDirPathError;

/// Whole-file write, creating the parent directories it needs.
///
/// The only durable state lgtm writes is under `.lgtm/`,
/// and it is small enough that a whole-file write is the right shape: there is
/// nothing to append to and nothing to keep open.
pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) WriteError!void {
    if (std.fs.path.dirname(path)) |dir| {
        Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// The one directory lgtm writes durable state into.
pub const state_dir = ".lgtm";

/// What lgtm puts in `.lgtm/.gitignore` the first time it writes anything.
///
/// The state directory is created inside the user's repository, so without
/// this the pane id lgtm has just saved comes back as an untracked file in the
/// diff lgtm is drawing: the tool adding noise to its own review, in the first
/// five minutes, before anyone has formed an opinion about it. Written here
/// rather than into the repository's own `.gitignore`, which lgtm does not own
/// and has no business editing.
///
/// `config.toml` is re-included deliberately: it is per-repo configuration
/// meant to be committed and shared, and everything else
/// here is machine-local - a tmux pane id, a git index, a session id.
///
/// Two spellings that look right and are not. The pattern is `*` rather than
/// the directory itself, because git does not descend into an excluded
/// directory and a negation underneath one silently does nothing. And there is
/// no `!.gitignore`: the usual reason to exempt an ignore file is to commit it
/// so a team shares the rules, but lgtm writes this one on every machine it
/// runs on, so exempting it buys nothing and costs the exact thing the file
/// exists to prevent - one untracked file, in the review, from the tool. Git
/// reads ignore rules off the working tree whether or not the file is tracked,
/// so ignoring itself changes nothing about what it does.
const self_ignore =
    \\# Written by lgtm on first use. Everything here is machine-local except
    \\# config.toml, which is per-repo config and meant to be committed.
    \\*
    \\!config.toml
    \\
;

/// Whole-file write into `.lgtm/`, creating the directory and its self-ignore
/// the first time.
///
/// Every durable write goes through here rather than `writeFile`, so the next
/// writer - notes, snapshots, the session file - cannot forget the ignore and
/// put the noise back.
pub fn writeStateFile(io: Io, path: []const u8, bytes: []const u8) WriteError!void {
    std.debug.assert(std.mem.startsWith(u8, path, state_dir ++ "/"));

    try ensureStateDir(io);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// The working directory, resolved, or null when it cannot be had.
///
/// For the one screen that has to say *where* the reader is: told there is no
/// repository here, the first thing worth knowing is which "here" is meant.
/// Being in the wrong directory is a likelier explanation than having meant to
/// review an uninitialised one, and only the path can tell those apart.
pub fn cwdPath(io: Io, buf: []u8) ?[]const u8 {
    const n = Dir.cwd().realPathFile(io, ".", buf) catch return null;
    return buf[0..n];
}

/// Creates `.lgtm/` and its self-ignore, without writing anything into it.
///
/// `writeStateFile` does this on the way to writing a file, which is enough for
/// everything that keeps its state in one. The snapshot store does not: it
/// hands git a path and lets *git* create the file there, so the directory has
/// to exist first and there is no content to write in order to make it.
pub fn ensureStateDir(io: Io) WriteError!void {
    Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    ensureSelfIgnore(io);
}

/// Puts the self-ignore in place if it is not there already.
///
/// Called at startup as well as from `writeStateFile`, because writing is not
/// enough on its own: the pane id is only saved when it *changes*, so a repo
/// whose saved target is still correct never writes again. A `.lgtm/` created
/// by a version of lgtm without this file would keep showing its own state in
/// its own review, for good. Startup is where that gets repaired.
///
/// Nothing happens when the directory does not exist. lgtm has no business
/// creating one in a repo it has never written to, and a review pane opened in
/// someone else's checkout should leave no trace.
///
/// Best effort, and never an overwrite: a user who edited the file, or deleted
/// it on purpose, has said what they want and the tool does not argue. Failure
/// is silent for the same reason `saveTarget` is - a read-only checkout should
/// not break a session that otherwise works.
pub fn ensureSelfIgnore(io: Io) void {
    const path = state_dir ++ "/.gitignore";
    if (fileExists(io, path)) return;

    var dir = Dir.cwd().openDir(io, state_dir, .{}) catch return;
    dir.close(io);
    Dir.cwd().writeFile(io, .{ .sub_path = path, .data = self_ignore }) catch {};
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
    std.sort.pdq([]u8, out, {}, struct {
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
    std.sort.pdq([]u8, out, {}, struct {
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

test "the self-ignore hides the state and shares the config" {
    const testing = std.testing;

    // Exactly two rules, because every extra one has a way of being subtly
    // wrong. `*` rather than the directory: git will not descend into an
    // excluded directory, so a negation under it does nothing. Then
    // `config.toml` back, so a repo can commit its own config.
    var it = std.mem.tokenizeScalar(u8, self_ignore, '\n');
    var rules: [2][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) continue;
        try testing.expect(n < rules.len);
        rules[n] = line;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("*", rules[0]);
    try testing.expectEqualStrings("!config.toml", rules[1]);

    // A blanket `.lgtm/` is the tempting spelling and the broken one.
    try testing.expect(std.mem.indexOf(u8, self_ignore, state_dir) == null);

    // And no `!.gitignore`: exempting it puts the file back in the review,
    // which is the noise this whole thing exists to remove.
    try testing.expect(std.mem.indexOf(u8, self_ignore, "!.gitignore") == null);
}

test "state paths agree with the directory that ignores them" {
    // `writeStateFile` asserts its path is under `state_dir`, so a path
    // constant that drifts is a panic at the first send rather than a file
    // written somewhere nothing ignores.
    const testing = std.testing;
    const bridge = @import("../bridge/bridge.zig");
    const config = @import("../config.zig");

    try testing.expect(std.mem.startsWith(u8, bridge.target_path, state_dir ++ "/"));
    try testing.expect(std.mem.startsWith(u8, config.repo_path, state_dir ++ "/"));
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
