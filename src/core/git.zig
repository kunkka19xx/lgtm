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

pub const Error = proc.RunError || diff.ParseError || error{ GitFailed, NotARepository };

/// Whether there is a repository here at all.
///
/// Asked only when a diff has already failed, so the ordinary run never pays
/// for it. Distinguishing "no repository" from "no commits yet" matters because
/// they want opposite answers: the first has nothing this tool can ever show,
/// the second has everything, all of it new.
fn insideRepo(gpa: Allocator, io: std.Io, repo: ?[]const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, "git") catch return false;
    if (repo) |r| argv.appendSlice(gpa, &.{ "-C", r }) catch return false;
    argv.appendSlice(gpa, &.{ "rev-parse", "--git-dir" }) catch return false;

    const out = proc.run(gpa, io, argv.items, 1 << 12) catch return false;
    defer out.deinit(gpa);
    return out.exit_code == 0;
}

/// Diffs the working tree against HEAD, staged and unstaged both.
///
/// One subprocess for every path, never one per file: fork plus exec plus git
/// startup costs 5-20 ms and will dominate the profile long before the diff
/// itself does (PERFORMANCE.md 8.1).
pub fn diffPaths(gpa: Allocator, io: std.Io, paths: []const []const u8) Error!Parsed {
    return diffPathsIn(gpa, io, null, paths, &.{});
}

/// Files kept out of the review by `[review] ignore`.
///
/// Passed to git as `:(exclude)<pattern>` pathspecs rather than matched here,
/// which buys exact gitignore glob semantics - the syntax the user already
/// knows - for no matching code of our own to get subtly wrong. It also means
/// git never parses the hunks, so a 900-line lockfile costs nothing rather
/// than being parsed and then dropped.
///
/// What it is *for* is the file `.gitignore` cannot help with: the generated
/// ones that are tracked on purpose. A lockfile, a `*.pb.go`, a committed
/// bundle - all real files, none of them decisions, and all of them sitting
/// between two hunks that are.
pub fn excludeSpec(arena: Allocator, pattern: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, ":(exclude){s}", .{pattern});
}

/// As `diffPaths`, against a named repository. Uses `git -C` rather than
/// changing the process working directory, which is shared mutable state.
pub fn diffPathsIn(
    gpa: Allocator,
    io: std.Io,
    repo: ?[]const u8,
    paths: []const []const u8,
    ignore: []const []const u8,
) Error!Parsed {
    return diffBase(gpa, io, repo, paths, ignore, "HEAD", null);
}

/// The review as it stood at a snapshot, rather than as it stands now.
///
/// `git diff HEAD <ref>`: the same left-hand side, a different right-hand one.
/// That is what makes a turn a *diff source* rather than a second kind of view
/// (SNAPSHOTS.md 5.3) - hunks, change ids, syntax, search and the gutter all
/// work on it because none of them ever knew where the diff came from.
///
/// No untracked scan. `git diff HEAD` cannot see a new file, so one is
/// synthesised for the working tree; between two trees there is nothing to
/// synthesise, because the right-hand side already contains everything git
/// knew about at that moment.
pub fn diffAt(
    gpa: Allocator,
    io: std.Io,
    repo: ?[]const u8,
    ignore: []const []const u8,
    ref: []const u8,
) Error!Parsed {
    return diffBase(gpa, io, repo, &.{}, ignore, "HEAD", ref);
}

fn diffBase(
    gpa: Allocator,
    io: std.Io,
    repo: ?[]const u8,
    paths: []const []const u8,
    ignore: []const []const u8,
    base: []const u8,
    /// The right-hand side, when it is a tree rather than the working tree.
    target: ?[]const u8,
) Error!Parsed {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, "git");
    if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
    // `HEAD` normally, `--cached` in a repository whose first commit has not
    // happened yet - see the retry below.
    try argv.appendSlice(gpa, &.{ "diff", base });
    if (target) |r| try argv.append(gpa, r);
    try argv.appendSlice(gpa, &.{
        // Stable output regardless of the user's config.
        "--no-color",
        "--no-ext-diff",
        "--find-renames",
        "-U3",
    });
    if (paths.len > 0 or ignore.len > 0) {
        try argv.append(gpa, "--");
        // A pathspec list of only exclusions matches nothing, so `.` has to
        // stand in for "everything" before the exclusions narrow it.
        if (paths.len > 0) try argv.appendSlice(gpa, paths) else if (ignore.len > 0) try argv.append(gpa, ".");
        for (ignore) |pat| try argv.append(gpa, try excludeSpec(gpa, pat));
    }
    defer for (argv.items) |a| {
        if (std.mem.startsWith(u8, a, ":(exclude)")) gpa.free(a);
    };

    const out = try proc.run(gpa, io, argv.items, max_diff_bytes);
    errdefer out.deinit(gpa);

    // git diff exits 0 with no changes and 1 only when --exit-code is set, so
    // any non-zero status here is a real failure - and there are two of them,
    // which used to be one crash.
    //
    // No repository at all is the end of the road: this tool is a reader of
    // `git diff` and there is nothing for it to read. It is still not an error
    // worth dying on (hard rule 8's spirit, and SNAPSHOTS.md 3.1 rule 6), so it
    // is named rather than lumped in with a real failure, and the caller shows
    // an empty review that says why.
    //
    // A repository whose first commit has not happened yet is the opposite:
    // everything in it is new, which is exactly what a reader wants to see when
    // an agent has just scaffolded a project. `HEAD` does not resolve, but
    // `--cached` diffs against the empty tree, and `untracked` below already
    // synthesises the rest. So the answer is a retry, not a refusal.
    if (out.exit_code != 0) {
        if (!insideRepo(gpa, io, repo)) return error.NotARepository;
        // The unborn-HEAD retry is for the working tree only. Diffing against
        // a snapshot in a repository with no commits is a question with no
        // answer rather than one to rephrase.
        if (target == null and std.mem.eql(u8, base, "HEAD")) {
            out.deinit(gpa);
            return diffBase(gpa, io, repo, paths, ignore, "--cached", null);
        }
        return error.GitFailed;
    }

    var parsed = try diff.parse(gpa, out.stdout);
    errdefer parsed.deinit(gpa);

    // Between two trees there is nothing untracked: the right-hand side is
    // already everything git knew about at that moment.
    if (target != null) return .{ .diff = parsed, .raw = out.stdout, .stderr = out.stderr };

    // `git diff HEAD` does not see untracked files, and an agent creating a
    // new file is one of the most common things it does. Without this they
    // would be silently absent from the review.
    var extra = try untracked(gpa, io, repo, paths, ignore);
    defer extra.deinit(gpa);
    if (extra.files.len > 0) {
        var all = try gpa.alloc(diff.FileDiff, parsed.files.len + extra.files.len);
        @memcpy(all[0..parsed.files.len], parsed.files);
        @memcpy(all[parsed.files.len..], extra.files);
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

fn untracked(
    gpa: Allocator,
    io: std.Io,
    repo: ?[]const u8,
    paths: []const []const u8,
    ignore: []const []const u8,
) Error!Untracked {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
    try argv.appendSlice(gpa, &.{ "ls-files", "--others", "--exclude-standard" });
    // The same exclusions the tracked side got. A new generated file is still
    // a generated file, and hiding it from one half of the review only would
    // be worse than not hiding it at all.
    if (paths.len > 0 or ignore.len > 0) {
        try argv.append(gpa, "--");
        if (paths.len > 0) try argv.appendSlice(gpa, paths) else try argv.append(gpa, ".");
        for (ignore) |pat| try argv.append(gpa, try excludeSpec(gpa, pat));
    }
    defer for (argv.items) |a| {
        if (std.mem.startsWith(u8, a, ":(exclude)")) gpa.free(a);
    };

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

/// A ceiling on the mention list. At this many paths one filter pass is a few
/// milliseconds against an 8 ms frame budget; past it the box stutters as you
/// type, which is worse than an incomplete list you can still filter.
pub const max_files = 50_000;

/// Every file git knows about and does not ignore: tracked plus untracked,
/// minus everything `.gitignore` covers. Git's own ordering, which is sorted -
/// what the `@` mention list wants underneath the changed files.
///
/// Measured rather than assumed: 10 ms on the largest repository to hand. The
/// cost that matters is not this one but the per-keystroke scan over the
/// result, about 9.5 ms at 200,000 paths, which is what `max_files` is for.
pub fn projectFiles(gpa: Allocator, io: std.Io) Error![][]const u8 {
    const out = try proc.run(gpa, io, &.{
        "git", "ls-files", "--cached", "--others", "--exclude-standard",
    }, max_diff_bytes);
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
        if (list.items.len >= max_files) break;
        try list.append(gpa, try gpa.dupe(u8, p));
    }
    return list.toOwnedSlice(gpa);
}

/// How many changed files the ignore patterns kept out.
///
/// Asked as the *inverse* pathspec - the patterns as includes rather than
/// excludes - so it counts exactly the files that were hidden, from the same
/// two populations the review is built from. Subtracting one list length from
/// another was the obvious way and the wrong one: `git diff` never sees
/// untracked files, so the two lists were not the same population and the
/// count came out short.
pub fn hiddenCount(gpa: Allocator, io: std.Io, ignore: []const []const u8) u32 {
    if (ignore.len == 0) return 0;
    return countMatching(gpa, io, &.{ "git", "diff", "HEAD", "--name-only" }, ignore) +
        countMatching(gpa, io, &.{ "git", "ls-files", "--others", "--exclude-standard" }, ignore);
}

fn countMatching(gpa: Allocator, io: std.Io, base: []const []const u8, pats: []const []const u8) u32 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.appendSlice(gpa, base) catch return 0;
    argv.append(gpa, "--") catch return 0;
    argv.appendSlice(gpa, pats) catch return 0;

    const out = proc.run(gpa, io, argv.items, max_diff_bytes) catch return 0;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return 0;

    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, out.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
    }
    return n;
}

pub fn freePaths(gpa: Allocator, paths: [][]const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}
