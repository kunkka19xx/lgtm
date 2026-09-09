// SPDX-License-Identifier: Apache-2.0
//
// GitHub, through the `gh` CLI.
//
// The same decision `core/git.zig` makes about libgit2: shell out rather than
// link a client. `gh` owns authentication, enterprise hosts, token refresh and
// rate limits, and nothing here ever learns what a token is.
//
// Tab-separated output from `--template`, not JSON. `gh` renders a Go template
// itself, so a title containing a quote or a brace costs nothing to read back
// and there is no parser here to get it wrong. The same shape `bridge/tmux.zig`
// gets from `-F`.
//
// Resolving is all this does. A pull request is two refs, and once they are
// known the existing two-tree review reads it with no help from GitHub.

const std = @import("std");
const Allocator = std.mem.Allocator;

const git = @import("git.zig");
const proc = @import("../io/proc.zig");

/// A resolve prints five short fields. The cap bounds a `gh` that has gone
/// wrong rather than a title that is long.
const view_output_max = 64 << 10;

pub const Error = error{
    /// `gh` is missing, unauthenticated, offline, or the number is not a pull
    /// request. One error because the caller can do nothing different about
    /// any of them, and `gh` says which on stderr.
    GhFailed,
} || Allocator.Error;

pub const Pr = struct {
    number: u32,
    /// `OPEN`, `MERGED` or `CLOSED`.
    state: []const u8,
    /// The branch the pull request targets. Only for fetching: the commit
    /// below is what the diff is taken against.
    base_ref: []const u8,
    /// The base branch *as it was* when the pull request was last synced.
    ///
    /// A commit, not the branch name. Once a pull request is merged its head
    /// is an ancestor of the branch, so `merge-base <branch> <head>` is the
    /// head itself and the diff comes back empty. This commit does not move
    /// under it.
    base_oid: []const u8,
    /// The head commit. A sha rather than a branch name, so a fork's branch
    /// and a push that lands mid-review both name the tree that was read.
    head_oid: []const u8,
    title: []const u8,
};

const fields = "number,state,baseRefName,baseRefOid,headRefOid,title";
const template = "{{.number}}\t{{.state}}\t{{.baseRefName}}\t{{.baseRefOid}}\t{{.headRefOid}}\t{{.title}}";

/// `gh pr view [n] --json ... --template ...`
///
/// Without a number `gh` resolves the current branch's pull request, which is
/// the common case: the branch is checked out because the agent just pushed it.
pub fn viewArgv(arena: Allocator, number: ?u32) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "gh", "pr", "view" });
    if (number) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
    try argv.appendSlice(arena, &.{ "--json", fields, "--template", template });
    return argv.toOwnedSlice(arena);
}

/// One line, five fields. Null when it is not one, which is what a `gh` too
/// old to know a field looks like: it prints the template back unexpanded
/// rather than failing, so the shape is checked and not the exit code alone.
pub fn parseView(text: []const u8) ?Pr {
    const line = std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "\n"), "\r");
    var it = std.mem.splitScalar(u8, line, '\t');
    const number = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const state = it.next() orelse return null;
    const base_ref = it.next() orelse return null;
    const base_oid = it.next() orelse return null;
    const head_oid = it.next() orelse return null;
    if (base_ref.len == 0 or base_oid.len == 0 or head_oid.len == 0) return null;
    // The title takes the rest, tabs included: it is a person's sentence.
    return .{
        .number = number,
        .state = state,
        .base_ref = base_ref,
        .base_oid = base_oid,
        .head_oid = head_oid,
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

/// A pull request as two refs the review can be pointed at.
///
/// The whole of what GitHub is asked for. Everything after this is git.
pub const Refs = struct {
    number: u32,
    /// The merge base, which is what a three-dot diff is taken against.
    base: []const u8,
    /// The head commit.
    target: []const u8,
    /// `#13 feat: syntax highlight for json`, for the status row. Two shas
    /// there would say nothing a reader could use.
    label: []const u8,
};

pub const ResolveError = Error || git.Error;

/// Number to refs: ask `gh` what the pull request is, make sure the objects
/// are here, then work out the base with git.
///
/// The fetch is skipped when the commit is already in the object store, which
/// is the usual case for a branch that is checked out, and is what keeps
/// re-opening the same pull request offline.
pub fn resolve(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    number: ?u32,
) ResolveError!Refs {
    const pr = try view(gpa, arena, io, number);

    // Both sides, not just the head. The base commit is a past tip of the
    // base branch, and a repository whose `origin/main` is behind does not
    // have it: the merge base then fails and a pull request that is perfectly
    // readable reports that it cannot be opened.
    //
    // Fetched only when something is missing, and that is a complete check
    // rather than a cheap one: these shas come from GitHub rather than from a
    // local ref, so a pull request that has moved since the last look has a
    // head this repository has never seen. There is nothing an unconditional
    // fetch would catch that this does not.
    const want_head = !git.hasCommit(gpa, io, pr.head_oid);
    const want_base = !git.hasCommit(gpa, io, pr.base_oid);
    if (want_head or want_base) {
        const remote = try git.defaultRemote(gpa, arena, io);
        if (want_head) try git.fetchPull(gpa, io, remote, pr.number);
        // The branch, not the commit: fetching a bare sha is something not
        // every server allows, and the branch contains it.
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
    const pr = parseView("13\tMERGED\tmain\tbe94b77\tc7143ba\tfeat: syntax highlight for json\n").?;
    try testing.expectEqual(@as(u32, 13), pr.number);
    try testing.expectEqualStrings("MERGED", pr.state);
    try testing.expectEqualStrings("main", pr.base_ref);
    // A commit, not a branch name: see `Pr.base_oid`.
    try testing.expectEqualStrings("be94b77", pr.base_oid);
    try testing.expectEqualStrings("c7143ba", pr.head_oid);
    try testing.expectEqualStrings("feat: syntax highlight for json", pr.title);

    // A title is a person's sentence: a tab in it is theirs, not a field.
    const tabbed = parseView("1\tOPEN\tmain\tdef\tabc\tfix:\tthe thing").?;
    try testing.expectEqualStrings("fix:\tthe thing", tabbed.title);
}

test "a pull request names a branch to fetch and a commit to diff against" {
    // Two different things, and using one for the other is the bug each was
    // added for: the branch moves, so it cannot be the base of the diff; the
    // commit may be absent, so it cannot be what is fetched.
    const pr = parseView("13\tOPEN\tmain\tbe94b77\tc7143ba\tfeat: json").?;
    try testing.expectEqualStrings("main", pr.base_ref);
    try testing.expectEqualStrings("be94b77", pr.base_oid);
    try testing.expect(!std.mem.eql(u8, pr.base_ref, pr.base_oid));
}

test "a merged pull request still has a base that is not its own head" {
    // The failure this guards: `merge-base <branch> <head>` is the head once
    // the branch contains it, and the review comes back empty. `baseRefOid`
    // is the branch as it was, which does not move under a merged request.
    const pr = parseView("12\tMERGED\tmain\tbe94b77\te721393\tfeat: v0.1.3").?;
    try testing.expect(!std.mem.eql(u8, pr.base_oid, pr.head_oid));
}

test "anything that is not a pull request is not guessed at" {
    // A `gh` too old to know a field prints the template back rather than
    // failing, so the shape is what says whether the answer is usable.
    try testing.expect(parseView("{{.number}}\t{{.state}}\n") == null);
    try testing.expect(parseView("") == null);
    try testing.expect(parseView("13\tOPEN\n") == null);
    // Present but empty is no answer either.
    try testing.expect(parseView("13\tOPEN\tmain\t\t\ttitle") == null);
}
