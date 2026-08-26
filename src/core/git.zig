// SPDX-License-Identifier: Apache-2.0
//
// Invokes git and hands the output to the parser. Kept separate from diff.zig
// so parsing stays a pure function that tests can drive without a process.
//
// v0.1 shells out rather than linking libgit2: less linkage, no version skew,
// and it inherits the user's git config and worktree handling for free
// (ARCHITECTURE.md 5b).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proc = @import("../io/proc.zig");
const fsmod = @import("../io/fs.zig");
pub const diff = @import("diff.zig");

/// Enough for a very large diff; beyond this the output is truncated rather
/// than allowed to exhaust memory.
pub const max_diff_bytes = 64 << 20;

pub const Error = proc.RunError || diff.ParseError || error{GitFailed};

/// Diffs the working tree against HEAD, staged and unstaged both.
///
/// One subprocess for every path, never one per file: fork plus exec plus git
/// startup costs 5-20 ms and will dominate the profile long before the diff
/// itself does (PERFORMANCE.md 8.1).
pub fn diffPaths(gpa: Allocator, io: std.Io, paths: []const []const u8) Error!Parsed {
    return diffPathsIn(gpa, io, null, paths);
}

/// As `diffPaths`, against a named repository. Uses `git -C` rather than
/// changing the process working directory, which is shared mutable state.
pub fn diffPathsIn(gpa: Allocator, io: std.Io, repo: ?[]const u8, paths: []const []const u8) Error!Parsed {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, "git");
    if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
    try argv.appendSlice(gpa, &.{
        "diff",
        "HEAD",
        // Stable output regardless of the user's config.
        "--no-color",
        "--no-ext-diff",
        "--find-renames",
        "-U3",
    });
    if (paths.len > 0) {
        try argv.append(gpa, "--");
        try argv.appendSlice(gpa, paths);
    }

    const out = try proc.run(gpa, io, argv.items, max_diff_bytes);
    errdefer out.deinit(gpa);

    // git diff exits 0 with no changes and 1 only when --exit-code is set, so
    // any non-zero status here is a real failure.
    if (out.exit_code != 0) return error.GitFailed;

    var parsed = try diff.parse(gpa, out.stdout);
    errdefer parsed.deinit(gpa);

    // `git diff HEAD` does not see untracked files, and an agent creating a
    // new file is one of the most common things it does. Without this they
    // would be silently absent from the review.
    var extra = try untracked(gpa, io, repo, paths);
    defer extra.deinit(gpa);
    if (extra.files.len > 0) {
        var all = try gpa.alloc(diff.FileDiff, parsed.files.len + extra.files.len);
        @memcpy(all[0..parsed.files.len], parsed.files);
        @memcpy(all[parsed.files.len ..], extra.files);
        gpa.free(parsed.files);
        gpa.free(extra.files);
        extra.files = &.{};
        parsed.files = all;
    }

    return .{ .diff = parsed, .raw = out.stdout, .stderr = out.stderr, .extra = extra.owned };
}

/// Owns the raw git output that every text slice in `diff` borrows from, which
/// is why the two are freed together.
pub const Parsed = struct {
    diff: diff.Diff,
    raw: []u8,
    stderr: []u8,
    /// Contents of untracked files, which the synthesised diffs borrow from.
    extra: [][]u8 = &.{},

    pub fn deinit(self: *Parsed, gpa: Allocator) void {
        self.diff.deinit(gpa);
        gpa.free(self.raw);
        gpa.free(self.stderr);
        for (self.extra) |b| gpa.free(b);
        gpa.free(self.extra);
        self.* = undefined;
    }
};

/// A brand new file has no blob to diff against, so its entry is synthesised
/// rather than parsed: every line is an addition.
///
/// SPEC.md open question 2 is answered: full contents, always, whatever the
/// size. A new file is entirely new code and summarising it would remove the
/// only thing there is to review. The code is the source of truth; a summary is
/// not a substitute for it.
const Untracked = struct {
    files: []diff.FileDiff,
    owned: [][]u8,

    fn deinit(self: *Untracked, gpa: Allocator) void {
        gpa.free(self.files);
        // `owned` is handed to Parsed on success, so it is not freed here.
    }
};

fn untracked(gpa: Allocator, io: std.Io, repo: ?[]const u8, paths: []const []const u8) Error!Untracked {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
    try argv.appendSlice(gpa, &.{ "ls-files", "--others", "--exclude-standard" });
    if (paths.len > 0) {
        try argv.append(gpa, "--");
        try argv.appendSlice(gpa, paths);
    }

    const out = try proc.run(gpa, io, argv.items, max_diff_bytes);
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.GitFailed;

    var files: std.ArrayList(diff.FileDiff) = .empty;
    errdefer files.deinit(gpa);
    var owned: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned.items) |b| gpa.free(b);
        owned.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, out.stdout, '\n');
    while (it.next()) |raw_line| {
        const rel = std.mem.trim(u8, raw_line, " \t\r");
        if (rel.len == 0) continue;

        const full = if (repo) |r| try std.fs.path.join(gpa, &.{ r, rel }) else try gpa.dupe(u8, rel);
        defer gpa.free(full);

        const bytes = fsmod.readFile(io, gpa, full, max_diff_bytes) catch continue;
        try owned.append(gpa, bytes);
        const path_copy = try gpa.dupe(u8, rel);
        try owned.append(gpa, path_copy);

        try files.append(gpa, try synthesiseAdd(gpa, path_copy, bytes));
    }

    return .{ .files = try files.toOwnedSlice(gpa), .owned = try owned.toOwnedSlice(gpa) };
}

fn synthesiseAdd(gpa: Allocator, path: []const u8, bytes: []const u8) Allocator.Error!diff.FileDiff {
    var count: u32 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |_| count += 1;
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n' and count > 0) count -= 1;

    var out: diff.FileDiff = .{
        .old_path = "/dev/null",
        .new_path = path,
        .status = .added,
        .added = count,
        .removed = 0,
    };
    const kind = try gpa.alloc(diff.hunk.LineKind, count);
    const old_no = try gpa.alloc(u32, count);
    const new_no = try gpa.alloc(u32, count);
    const text = try gpa.alloc([]const u8, count);

    var i: u32 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (i >= count) break;
        kind[i] = .add;
        old_no[i] = 0;
        new_no[i] = i + 1;
        text[i] = std.mem.trimEnd(u8, line, "\r");
        i += 1;
    }

    out.lines = .{ .kind = kind, .old_no = old_no, .new_no = new_no, .text = text };
    const hunks = try gpa.alloc(diff.hunk.Hunk, 1);
    hunks[0] = .{
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = count,
        .lo = 0,
        .hi = count,
    };
    hunks[0].hash = diff.hunk.hashHunk(out.lines, 0, count);
    out.hunks = hunks;
    return out;
}

/// Paths that differ from HEAD, for the watcher to narrow re-diffs to.
/// One subprocess instead of N stat calls (PERFORMANCE.md 8.1).
pub fn changedPaths(gpa: Allocator, io: std.Io) Error![][]const u8 {
    const out = try proc.run(gpa, io, &.{ "git", "diff", "HEAD", "--name-only" }, max_diff_bytes);
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.GitFailed;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, out.stdout, '\n');
    while (it.next()) |line| {
        const p = std.mem.trim(u8, line, " \t\r");
        if (p.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, p));
    }
    return list.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: Allocator, paths: [][]const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}
