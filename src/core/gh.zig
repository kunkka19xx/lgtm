// SPDX-License-Identifier: Apache-2.0
//
// GitHub, through the `gh` CLI.
//
// The same decision `core/git.zig` makes about libgit2: shell out rather than
// link a client. `gh` owns authentication, enterprise hosts and rate limits,
// and nothing here learns what a token is.
//
// Tab-separated output from `--template`, not JSON, so a title containing a
// quote costs nothing to read back and there is no parser to get it wrong.
// The shape `bridge/tmux.zig` gets from `-F`.
//
// Resolving is all this does: a pull request is two refs, and the existing
// two-tree review reads it from there with no help from GitHub.

const std = @import("std");
const Allocator = std.mem.Allocator;

const git = @import("git.zig");
const proc = @import("../io/proc.zig");

/// Bounds a `gh` that has gone wrong, not a title that is long.
const view_output_max = 64 << 10;

pub const Error = error{
    /// Missing, unauthenticated, offline, or not a pull request. One error:
    /// the caller can do nothing different about any of them, and `gh` says
    /// which on stderr.
    GhFailed,
} || Allocator.Error;

pub const Pr = struct {
    number: u32,
    /// `OPEN`, `MERGED` or `CLOSED`.
    state: []const u8,
    /// The branch the request targets. For fetching only.
    base_ref: []const u8,
    /// The base branch *as it was* when the request last synced. A commit,
    /// because once merged the head is an ancestor of the branch and
    /// `merge-base <branch> <head>` is then the head itself, which diffs to
    /// nothing.
    base_oid: []const u8,
    /// The head commit. A sha, so a fork's branch and a push landing
    /// mid-review both name the tree that was read.
    head_oid: []const u8,
    /// Where the owning repository is read from.
    url: []const u8,
    title: []const u8,
};

const fields = "number,state,baseRefName,baseRefOid,headRefOid,url,title";
const template = "{{.number}}\t{{.state}}\t{{.baseRefName}}\t{{.baseRefOid}}\t{{.headRefOid}}\t{{.url}}\t{{.title}}";

/// Without a number `gh` answers for the current branch, which is the common
/// case: the branch is checked out because the agent just pushed it.
pub fn viewArgv(arena: Allocator, number: ?u32) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "gh", "pr", "view" });
    if (number) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
    try argv.appendSlice(arena, &.{ "--json", fields, "--template", template });
    return argv.toOwnedSlice(arena);
}

/// One line, six fields. Null when it is not: a `gh` too old to know a field
/// prints the template back unexpanded rather than failing, so the shape is
/// checked and not the exit code alone.
pub fn parseView(text: []const u8) ?Pr {
    const line = std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "\n"), "\r");
    var it = std.mem.splitScalar(u8, line, '\t');
    const number = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const state = it.next() orelse return null;
    const base_ref = it.next() orelse return null;
    const base_oid = it.next() orelse return null;
    const head_oid = it.next() orelse return null;
    const url = it.next() orelse return null;
    if (base_ref.len == 0 or base_oid.len == 0 or head_oid.len == 0) return null;
    // The title takes the rest: it is a person's sentence, tabs and all.
    return .{
        .number = number,
        .state = state,
        .base_ref = base_ref,
        .base_oid = base_oid,
        .head_oid = head_oid,
        .url = url,
        .title = it.rest(),
    };
}

pub fn view(gpa: Allocator, arena: Allocator, io: std.Io, number: ?u32) Error!Pr {
    const argv = try viewArgv(arena, number);
    const out = proc.run(gpa, io, argv, view_output_max) catch return error.GhFailed;
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.GhFailed;
    return parseView(try arena.dupe(u8, out.stdout)) orelse error.GhFailed;
}

/// A pull request as two refs. The whole of what GitHub is asked for.
pub const Refs = struct {
    number: u32,
    /// The merge base, which is what a three-dot diff is taken against.
    base: []const u8,
    /// The head commit.
    target: []const u8,
    /// For the status row, where two shas would say nothing usable.
    label: []const u8,
};

/// The two path segments before `/pull/`. Extracts rather than validates: a
/// malformed address matches no remote and the caller falls back to `origin`,
/// so a stricter parse buys nothing.
///
/// Taken from the URL that came back with everything else rather than asked
/// for separately: it is the same round trip, and the alternative is a second
/// call to learn something already on screen.
pub fn ownerRepo(url: []const u8) ?[]const u8 {
    const marker = "/pull/";
    const cut = std.mem.lastIndexOf(u8, url, marker) orelse return null;
    const head = url[0..cut];
    // The two path segments before `/pull/`, whatever host preceded them.
    const repo_at = std.mem.lastIndexOfScalar(u8, head, '/') orelse return null;
    const owner_at = std.mem.lastIndexOfScalar(u8, head[0..repo_at], '/') orelse return null;
    const name = head[owner_at + 1 ..];
    return if (name.len > 1) name else null;
}

/// Where a forge puts a request's head. Spelled here and not in `core/git.zig`
/// because it is a forge's convention, not git's.
///
/// It is on the repository the request is *against*, so a fork never has to
/// become a remote - and it is why this is a fetch rather than
/// `gh pr checkout`, which would move the reader's working tree.
fn pullRef(arena: Allocator, number: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "pull/{d}/head", .{number});
}

pub const ResolveError = Error || git.Error;

/// Number to refs: ask `gh` what the request is, make sure the objects are
/// here, then work out the base with git.
pub fn resolve(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    number: ?u32,
) ResolveError!Refs {
    const pr = try view(gpa, arena, io, number);

    // Both sides: the base commit is a past tip of its branch, and a stale
    // `origin/main` does not have it.
    //
    // Missing-only is a complete check, not a cheap one: these shas come from
    // GitHub rather than a local ref, so a request that has moved has a head
    // this repository has never seen. An unconditional fetch would catch
    // nothing more.
    const want_head = !git.hasCommit(gpa, io, pr.head_oid);
    const want_base = !git.hasCommit(gpa, io, pr.base_oid);
    if (want_head or want_base) {
        const remote = try git.defaultRemote(gpa, arena, io, ownerRepo(pr.url));
        if (want_head) try git.fetchRef(gpa, io, remote, try pullRef(arena, pr.number));
        // The branch, not the commit: not every server serves a bare sha,
        // and the branch contains it.
        if (want_base) try git.fetchRef(gpa, io, remote, pr.base_ref);
    }

    const base = try git.mergeBase(gpa, arena, io, pr.base_oid, pr.head_oid);

    return .{
        .number = pr.number,
        .base = base,
        .target = try arena.dupe(u8, pr.head_oid),
        .label = try std.fmt.allocPrint(arena, "#{d} {s}", .{ pr.number, pr.title }),
    };
}

const testing = std.testing;

test "a resolve names the pull request or the current branch's" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const numbered = try viewArgv(arena, 13);
    try testing.expectEqualStrings("13", numbered[3]);
    try testing.expectEqualStrings("--json", numbered[4]);

    // Without one, `gh` answers for the branch that is checked out.
    const bare = try viewArgv(arena, null);
    try testing.expectEqualStrings("--json", bare[3]);
}

test "a view parses into two refs and a title" {
    const pr = parseView("13\tMERGED\tmain\tbe94b77\tc7143ba\thttps://github.com/o/r/pull/13\tfeat: syntax highlight for json\n").?;
    try testing.expectEqual(@as(u32, 13), pr.number);
    try testing.expectEqualStrings("MERGED", pr.state);
    try testing.expectEqualStrings("main", pr.base_ref);
    // A commit, not a branch name: see `Pr.base_oid`.
    try testing.expectEqualStrings("be94b77", pr.base_oid);
    try testing.expectEqualStrings("c7143ba", pr.head_oid);
    try testing.expectEqualStrings("feat: syntax highlight for json", pr.title);

    // A title is a person's sentence: a tab in it is theirs, not a field.
    const tabbed = parseView("1\tOPEN\tmain\tdef\tabc\thttps://github.com/o/r/pull/1\tfix:\tthe thing").?;
    try testing.expectEqualStrings("fix:\tthe thing", tabbed.title);
}

test "the owning repository is read out of the address, not asked for again" {
    try testing.expectEqualStrings("kunkka19xx/lgtm", ownerRepo("https://github.com/kunkka19xx/lgtm/pull/13").?);
    // An enterprise host is two segments before `/pull/` like any other.
    try testing.expectEqualStrings("team/app", ownerRepo("https://git.example.com/team/app/pull/7").?);
    // A repository whose name contains the marker still cuts at the last one.
    try testing.expectEqualStrings("o/pull", ownerRepo("https://github.com/o/pull/pull/1").?);

    try testing.expect(ownerRepo("") == null);
    try testing.expect(ownerRepo("not a url") == null);

    // It extracts rather than validates: an address with only one segment
    // before `/pull/` yields the host and that segment. Nothing checks the
    // answer is a repository because nothing has to - it is matched against
    // the remotes, and one that matches none falls back to `origin`.
    try testing.expectEqualStrings("github.com/lgtm", ownerRepo("https://github.com/lgtm/pull/13").?);
}

test "a head is fetched from the ref the forge puts it at" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("pull/13/head", try pullRef(a.allocator(), 13));
}

test "a pull request names a branch to fetch and a commit to diff against" {
    // Two different things, and using one for the other is the bug each was
    // added for: the branch moves, so it cannot be the base of the diff; the
    // commit may be absent, so it cannot be what is fetched.
    const pr = parseView("13\tOPEN\tmain\tbe94b77\tc7143ba\thttps://github.com/o/r/pull/13\tfeat: json").?;
    try testing.expectEqualStrings("main", pr.base_ref);
    try testing.expectEqualStrings("be94b77", pr.base_oid);
    try testing.expect(!std.mem.eql(u8, pr.base_ref, pr.base_oid));
}

test "a merged pull request still has a base that is not its own head" {
    // The failure this guards: `merge-base <branch> <head>` is the head once
    // the branch contains it, and the review comes back empty. `baseRefOid`
    // is the branch as it was, which does not move under a merged request.
    const pr = parseView("12\tMERGED\tmain\tbe94b77\te721393\thttps://github.com/o/r/pull/12\tfeat: v0.1.3").?;
    try testing.expect(!std.mem.eql(u8, pr.base_oid, pr.head_oid));
}

test "anything that is not a pull request is not guessed at" {
    // A `gh` too old to know a field prints the template back rather than
    // failing, so the shape is what says whether the answer is usable.
    try testing.expect(parseView("{{.number}}\t{{.state}}\n") == null);
    try testing.expect(parseView("") == null);
    try testing.expect(parseView("13\tOPEN\n") == null);
    // Present but empty is no answer either.
    try testing.expect(parseView("13\tOPEN\tmain\t\t\turl\ttitle") == null);
}
