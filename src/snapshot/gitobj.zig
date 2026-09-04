// SPDX-License-Identifier: Apache-2.0
//
// Git plumbing for the snapshot store: argv in, object ids out.
//
// Step 1 of SNAPSHOTS.md 5.6, and nothing more than that. No policy lives here:
// this file does not know what a turn is, when one should be taken, or how a
// session is named. It knows how to write a tree from a set of paths without
// touching anything of the user's, and how to read one back.
//
// The store is git's own object database, reached through plumbing. Nothing is
// invented: unchanged files cost zero bytes because git content-addresses them,
// `git diff` between two of our refs works with no custom format, refs keep the
// objects alive through `gc`, and a snapshot is recoverable by hand with
// `git show refs/lgtm/<session>/3:src/auth.zig` even if lgtm is not installed.
// That last property is the one worth protecting: a safety net nobody can open
// without the tool that made it is not a safety net.
//
// The hard boundaries are SNAPSHOTS.md 3.1 and they are what this file is for:
//
//   1. Never write `.git/index`. Every index-touching call carries
//      `GIT_INDEX_FILE`, which is why `indexEnv` exists and why `io/proc.zig`
//      grew `runEnv` - git reads that variable from the environment and offers
//      no flag for it.
//   2. Never move `HEAD`. No checkout, no reset, no commit. `commit-tree` is
//      plumbing: it writes a commit object and returns its id, and moves
//      nothing.
//   3. Never touch `refs/heads`, `refs/tags` or `refs/stash`. `refPrefix`
//      asserts this rather than trusting callers.
//   4. Never modify the working tree. Nothing here writes a file.
//
// Split the way `bridge/tmux.zig` is: the argv builders and the output parsers
// are pure and tested, the four functions that actually spawn git are thin
// enough to read. Testing argv is what catches a boundary violation; testing
// against a real repository is what the dogfood pass is for.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("../io/fs.zig");
const proc = @import("../io/proc.zig");

/// Where a snapshot's index lives. Inside `.lgtm/`, which lgtm already keeps
/// out of the review with its own `.gitignore` (`io/fs.zig`), so the file
/// cannot turn up as a change the reader has to look at.
pub const index_path = ".lgtm/index";

/// Every ref this module may write. A prefix rather than a formatted string at
/// each call site, so `refFor` is the only place that decides, and boundary 3
/// is checkable by reading one function.
pub const ref_prefix = "refs/lgtm/";

/// Abbreviated ids are what `core/diff.zig` already stores; full ones are what
/// plumbing returns. 64 is room for sha256 with space to spare.
pub const max_oid = 64;

pub const Error = proc.RunError || error{ GitFailed, BadOutput } || Allocator.Error;

/// A git object id, owned inline so a caller can keep one without allocating.
pub const Oid = struct {
    bytes: [max_oid]u8 = undefined,
    len: u8 = 0,

    pub fn from(text: []const u8) error{BadOutput}!Oid {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0 or t.len > max_oid) return error.BadOutput;
        for (t) |c| if (!std.ascii.isHex(c)) return error.BadOutput;
        var out: Oid = .{ .len = @intCast(t.len) };
        @memcpy(out.bytes[0..t.len], t);
        return out;
    }

    pub fn slice(self: *const Oid) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// `refs/lgtm/<session>/<turn>`.
///
/// The one place a ref name is built. A session id with a slash or a `..` in it
/// would let a caller name a ref outside the namespace, so the characters are
/// checked here rather than trusted: boundary 3 is not a convention, it is the
/// difference between a snapshot store and something that can overwrite a
/// branch.
pub fn refFor(buf: []u8, session: []const u8, turn: u32) error{BadOutput}![]const u8 {
    if (session.len == 0) return error.BadOutput;
    for (session) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return error.BadOutput;
    }
    return std.fmt.bufPrint(buf, "{s}{s}/{d}", .{ ref_prefix, session, turn }) catch error.BadOutput;
}

/// Whether a ref is one of ours. Used before anything that deletes.
pub fn ours(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, ref_prefix) and
        std.mem.indexOf(u8, ref, "..") == null;
}

// -- argv builders ---------------------------------------------------------
//
// Separate from the running so they can be asserted. A boundary violation is
// an argv that names the wrong thing, and this is where it would be visible.

/// Primes the isolated index from HEAD, so `write-tree` emits a whole tree
/// rather than one containing only the paths we added. Fails harmlessly in a
/// repo with no commits, where there is no HEAD to read and an empty index is
/// the right starting point anyway.
pub fn readTreeArgv(out: *[3][]const u8) []const []const u8 {
    out.* = .{ "git", "read-tree", "HEAD" };
    return out[0..3];
}

/// Stages the given paths into the isolated index.
///
/// `--add --remove` together are what make a deleted file a deletion rather
/// than a file that silently stayed: `--add` alone would leave the old blob in
/// the tree and the snapshot would claim the file still exists.
///
/// `--` before the paths, always. A path that begins with a dash is a path, and
/// git has no way to know that without being told.
pub fn updateIndexArgv(gpa: Allocator, paths: []const []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "update-index", "--add", "--remove", "--" });
    try argv.appendSlice(gpa, paths);
    return argv.toOwnedSlice(gpa);
}

pub fn writeTreeArgv(out: *[2][]const u8) []const []const u8 {
    out.* = .{ "git", "write-tree" };
    return out[0..2];
}

/// `commit-tree` writes a commit object and returns its id. It moves no ref and
/// touches no branch, which is what makes it safe here and what separates it
/// from `git commit`.
///
/// The parent is what gives the store its shape: a chain while the agent works,
/// and a fork the moment a restore makes turn N+1 a child of an older turn
/// (SNAPSHOTS.md 5.3a). Null for the first snapshot of a session.
pub fn commitTreeArgv(gpa: Allocator, tree: []const u8, parent: ?[]const u8, message: []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "commit-tree", tree });
    if (parent) |p| try argv.appendSlice(gpa, &.{ "-p", p });
    try argv.appendSlice(gpa, &.{ "-m", message });
    return argv.toOwnedSlice(gpa);
}

pub fn updateRefArgv(out: *[4][]const u8, ref: []const u8, oid: []const u8) []const []const u8 {
    out.* = .{ "git", "update-ref", ref, oid };
    return out[0..4];
}

/// Every path and blob id in a snapshot, which is what the timeline reads to
/// answer "did the agent walk this file back to where it was" without parsing a
/// single diff (SNAPSHOTS.md 5.3c).
pub fn lsTreeArgv(out: *[5][]const u8, ref: []const u8) []const []const u8 {
    out.* = .{ "git", "ls-tree", "-r", "-z", ref };
    return out[0..5];
}

/// Every ref we have written, newest-sorted by the caller. Only ours: the
/// pattern is the namespace, so this cannot list a branch even by accident.
pub fn listRefsArgv(out: *[4][]const u8) []const []const u8 {
    out.* = .{ "git", "for-each-ref", "--format=%(refname)", ref_prefix };
    return out[0..4];
}

/// Every ref of ours with the commit it points at, which is what turns a
/// `git log` walk back into turn numbers. One call rather than a `rev-parse`
/// per ref: the list is read to draw a list, and a subprocess per row is how a
/// list becomes slow.
pub fn listRefOidsArgv(out: *[4][]const u8) []const []const u8 {
    out.* = .{ "git", "for-each-ref", "--format=%(objectname) %(refname)", ref_prefix };
    return out[0..4];
}

/// Deletes one ref. Pruning is ref deletion and nothing else: the objects
/// become unreachable and ordinary `git gc` reclaims them, so this file never
/// deletes an object and cannot delete one someone else still points at.
pub fn deleteRefArgv(out: *[4][]const u8, ref: []const u8) []const []const u8 {
    out.* = .{ "git", "update-ref", "-d", ref };
    return out[0..4];
}

// -- output parsers --------------------------------------------------------

/// One `ls-tree -r -z` record: `<mode> SP <type> SP <oid> TAB <path> NUL`.
pub const Entry = struct {
    oid: []const u8,
    path: []const u8,
};

/// Parses `ls-tree -r -z`. Slices borrow from `text`.
///
/// `-z` rather than the default, because a path may contain anything but NUL
/// and the default output quotes such a path instead of printing it - which
/// would make a file with a newline in its name parse as two entries, or as
/// none. Rare, and the kind of rare that corrupts a safety net silently.
pub fn parseTree(gpa: Allocator, text: []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, 0);
    while (it.next()) |rec| {
        if (rec.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
        const head = rec[0..tab];
        const path = rec[tab + 1 ..];
        if (path.len == 0) continue;

        // `<mode> <type> <oid>`: the id is the last field, and taking it from
        // the end means a mode or type git grows a variant of does not break
        // the parse.
        const sp = std.mem.lastIndexOfScalar(u8, head, ' ') orelse continue;
        const oid = head[sp + 1 ..];
        if (oid.len == 0) continue;
        try out.append(gpa, .{ .oid = oid, .path = path });
    }
    return out.toOwnedSlice(gpa);
}

/// The blob id for one path, or null when the snapshot did not contain it.
pub fn blobOf(entries: []const Entry, path: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.oid;
    }
    return null;
}

// -- running ---------------------------------------------------------------

/// The parent environment with `GIT_INDEX_FILE` pointing at ours.
///
/// A copy, because `std.process` replaces the child environment rather than
/// extending it: handing git a map containing only this one key would take
/// `PATH`, `HOME` and the user's git configuration away from it.
pub fn indexEnv(
    gpa: Allocator,
    parent: *const std.process.Environ.Map,
    path: []const u8,
) Allocator.Error!std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    var it = parent.iterator();
    while (it.next()) |kv| try map.put(kv.key_ptr.*, kv.value_ptr.*);
    try map.put("GIT_INDEX_FILE", path);
    return map;
}

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    /// Null runs git with our environment unchanged, which is right for
    /// everything that does not touch an index.
    env: ?*const std.process.Environ.Map = null,

    fn out(self: Ctx, argv: []const []const u8) Error![]u8 {
        const r = if (self.env) |e|
            try proc.runEnv(self.gpa, self.io, argv, 1 << 20, e)
        else
            try proc.run(self.gpa, self.io, argv, 1 << 20);
        if (r.exit_code != 0) {
            r.deinit(self.gpa);
            return error.GitFailed;
        }
        // Only stderr is dropped; stdout is the return value. No `errdefer`
        // above it, because there is nothing between here and the return that
        // can fail - one was there and freed `r` a second time on the failure
        // path, which the harness found on its first run against a real repo.
        self.gpa.free(r.stderr);
        return r.stdout;
    }

    fn oid(self: Ctx, argv: []const []const u8) Error!Oid {
        const text = try self.out(argv);
        defer self.gpa.free(text);
        return Oid.from(text);
    }
};

/// Writes one snapshot and points `ref` at it. Returns the commit id.
///
/// The whole sequence, in the only order it works in: prime the index from
/// HEAD, stage the changed paths into it, turn it into a tree, wrap the tree in
/// a commit, and move a ref of ours to it. Every step before the last writes
/// only objects, so a failure part way through leaves unreferenced objects that
/// `git gc` collects and nothing that anyone can see.
///
/// `paths` must come from `git status --porcelain --untracked-files=all` or
/// something equally ignore-clean. `update-index --add` is plumbing and will
/// happily stage `node_modules`; what keeps boundary 5 true is the path list,
/// not this call (SNAPSHOTS.md, PLAN.md v0.2 item 2).
pub fn writeSnapshot(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: struct {
        paths: []const []const u8,
        ref: []const u8,
        parent: ?[]const u8 = null,
        message: []const u8,
    },
) Error!Oid {
    if (!ours(opts.ref)) return error.GitFailed;

    // git creates the index file itself, but not the directory holding it, and
    // its failure to do so is a `fatal:` about a lock file that says nothing
    // about the real cause. Cheap to make sure, and it is the same directory
    // and the same self-ignore everything else durable already uses.
    fs.ensureStateDir(io) catch return error.GitFailed;

    var env = try indexEnv(gpa, environ, index_path);
    defer env.deinit();
    const idx: Ctx = .{ .gpa = gpa, .io = io, .env = &env };
    const plain: Ctx = .{ .gpa = gpa, .io = io };

    // Priming from HEAD is what makes this a snapshot of the whole tree rather
    // than of the changed paths alone. Without it `write-tree` emits a tree
    // containing only what `update-index` staged, and 5.5's "recover the
    // pre-agent state" would recover a handful of files and call it a working
    // tree. A repo with no commits has no HEAD to read, and an empty index is
    // then the correct start - so that one failure is expected and ignored,
    // and no other kind is.
    var rt: [3][]const u8 = undefined;
    if (idx.out(readTreeArgv(&rt))) |text| gpa.free(text) else |err| switch (err) {
        error.GitFailed => {},
        else => return err,
    }

    const stage = try updateIndexArgv(gpa, opts.paths);
    defer gpa.free(stage);
    gpa.free(try idx.out(stage));

    var wt: [2][]const u8 = undefined;
    const tree = try idx.oid(writeTreeArgv(&wt));

    const ct = try commitTreeArgv(gpa, tree.slice(), opts.parent, opts.message);
    defer gpa.free(ct);
    const commit = try plain.oid(ct);

    var ur: [4][]const u8 = undefined;
    gpa.free(try plain.out(updateRefArgv(&ur, opts.ref, commit.slice())));
    return commit;
}

/// The refs we have written, in git's order. Caller owns both slices.
pub fn listRefs(gpa: Allocator, io: std.Io) Error!struct { text: []u8, refs: [][]const u8 } {
    var lr: [4][]const u8 = undefined;
    const ctx: Ctx = .{ .gpa = gpa, .io = io };
    const text = try ctx.out(listRefsArgv(&lr));
    errdefer gpa.free(text);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ref = std.mem.trim(u8, line, " \r");
        if (ref.len > 0 and ours(ref)) try out.append(gpa, ref);
    }
    return .{ .text = text, .refs = try out.toOwnedSlice(gpa) };
}

/// `<oid> <ref>` for every ref of ours. Caller owns the text and the slice.
pub fn listRefOids(gpa: Allocator, io: std.Io) Error!struct { text: []u8, pairs: []Entry } {
    var lr: [4][]const u8 = undefined;
    const ctx: Ctx = .{ .gpa = gpa, .io = io };
    const text = try ctx.out(listRefOidsArgv(&lr));
    errdefer gpa.free(text);

    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const row = std.mem.trim(u8, line, " \r");
        const sp = std.mem.indexOfScalar(u8, row, ' ') orelse continue;
        const ref = row[sp + 1 ..];
        if (!ours(ref)) continue;
        try out.append(gpa, .{ .oid = row[0..sp], .path = ref });
    }
    return .{ .text = text, .pairs = try out.toOwnedSlice(gpa) };
}

/// Deletes a ref of ours, or does nothing. Never reports failure: pruning is
/// housekeeping, and a ref that could not be removed is a little wasted disk
/// rather than anything the reader needs to hear about.
pub fn deleteRef(gpa: Allocator, io: std.Io, ref: []const u8) void {
    if (!ours(ref)) return;
    var dr: [4][]const u8 = undefined;
    const ctx: Ctx = .{ .gpa = gpa, .io = io };
    const text = ctx.out(deleteRefArgv(&dr, ref)) catch return;
    gpa.free(text);
}

/// Reads a snapshot's paths and blob ids. Caller owns the slice; the strings
/// borrow from `text`, which the caller also owns and must outlive it.
pub fn readTree(gpa: Allocator, io: std.Io, ref: []const u8) Error!struct { text: []u8, entries: []Entry } {
    var lt: [5][]const u8 = undefined;
    const ctx: Ctx = .{ .gpa = gpa, .io = io };
    const text = try ctx.out(lsTreeArgv(&lt, ref));
    errdefer gpa.free(text);
    return .{ .text = text, .entries = try parseTree(gpa, text) };
}

const testing = std.testing;

test "a ref is built inside our namespace and nowhere else" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "refs/lgtm/20260904-1418-a3f9/7",
        try refFor(&buf, "20260904-1418-a3f9", 7),
    );

    // Boundary 3 is not a convention. A session id that could escape the
    // namespace is refused here rather than trusted to be well formed, because
    // the thing on the other side of the mistake is someone's branch.
    try testing.expectError(error.BadOutput, refFor(&buf, "../heads/main", 1));
    try testing.expectError(error.BadOutput, refFor(&buf, "a/b", 1));
    try testing.expectError(error.BadOutput, refFor(&buf, "", 1));
}

test "ours() refuses anything outside the namespace" {
    try testing.expect(ours("refs/lgtm/s1/3"));
    try testing.expect(!ours("refs/heads/main"));
    try testing.expect(!ours("refs/stash"));
    try testing.expect(!ours("refs/tags/v1"));
    // A traversal that starts inside is still a traversal.
    try testing.expect(!ours("refs/lgtm/../heads/main"));
}

test "staging carries --add --remove, and -- before the paths" {
    const argv = try updateIndexArgv(testing.allocator, &.{ "src/a.zig", "-weird-name" });
    defer testing.allocator.free(argv);

    try testing.expectEqualStrings("git", argv[0]);
    try testing.expectEqualStrings("update-index", argv[1]);
    // Without --remove a deleted file stays in the tree and the snapshot lies
    // about what the working tree contained.
    try testing.expectEqualStrings("--add", argv[2]);
    try testing.expectEqualStrings("--remove", argv[3]);
    // Everything after this is a path, including one that looks like a flag.
    try testing.expectEqualStrings("--", argv[4]);
    try testing.expectEqualStrings("src/a.zig", argv[5]);
    try testing.expectEqualStrings("-weird-name", argv[6]);
}

test "commit-tree takes a parent only when there is one" {
    const first = try commitTreeArgv(testing.allocator, "abc123", null, "turn 0");
    defer testing.allocator.free(first);
    try testing.expectEqualSlices([]const u8, &.{ "git", "commit-tree", "abc123", "-m", "turn 0" }, first);

    const next = try commitTreeArgv(testing.allocator, "def456", "abc123", "turn 1");
    defer testing.allocator.free(next);
    try testing.expectEqualSlices(
        []const u8,
        &.{ "git", "commit-tree", "def456", "-p", "abc123", "-m", "turn 1" },
        next,
    );
}

test "nothing in the argv can move HEAD or a branch" {
    // Boundary 2 and 3, asserted rather than reviewed. If a future edit adds
    // `commit`, `checkout` or `reset` to any of these, this fails.
    const banned = [_][]const u8{ "commit", "checkout", "reset", "merge", "rebase", "stash", "push" };

    var a: [3][]const u8 = undefined;
    var b: [2][]const u8 = undefined;
    var c: [4][]const u8 = undefined;
    var d: [5][]const u8 = undefined;
    const stage = try updateIndexArgv(testing.allocator, &.{"x.zig"});
    defer testing.allocator.free(stage);
    const ct = try commitTreeArgv(testing.allocator, "abc", null, "m");
    defer testing.allocator.free(ct);

    const all = [_][]const []const u8{
        readTreeArgv(&a),
        writeTreeArgv(&b),
        updateRefArgv(&c, "refs/lgtm/s/1", "abc"),
        lsTreeArgv(&d, "refs/lgtm/s/1"),
        stage,
        ct,
    };
    for (all) |argv| {
        // argv[1] is the subcommand; a banned word later is a path or a
        // message and means nothing.
        for (banned) |word| try testing.expect(!std.mem.eql(u8, argv[1], word));
    }
    // And the only ref any of them names is ours.
    try testing.expect(ours(updateRefArgv(&c, "refs/lgtm/s/1", "abc")[2]));
}

test "ls-tree is parsed NUL-separated, so a path may contain anything" {
    const text =
        "100644 blob aaa111\tsrc/a.zig\x00" ++
        "100644 blob bbb222\tsrc/b.zig\x00" ++
        // A newline in a filename is legal and would be quoted, and so
        // misparsed, without -z.
        "100644 blob ccc333\tweird\nname.txt\x00";

    const entries = try parseTree(testing.allocator, text);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("aaa111", entries[0].oid);
    try testing.expectEqualStrings("src/a.zig", entries[0].path);
    try testing.expectEqualStrings("weird\nname.txt", entries[2].path);
}

test "a blob is found by path, and a missing one says so" {
    const text = "100644 blob aaa111\tsrc/a.zig\x00100644 blob bbb222\tsrc/b.zig\x00";
    const entries = try parseTree(testing.allocator, text);
    defer testing.allocator.free(entries);

    try testing.expectEqualStrings("bbb222", blobOf(entries, "src/b.zig").?);
    try testing.expect(blobOf(entries, "src/gone.zig") == null);
}

test "the same content in two turns is the same blob, which is the revert check" {
    // SNAPSHOTS.md 5.3c: "the agent undid its own work" is `==` on two hashes,
    // because git content-addresses. This is that comparison, on the shape the
    // parser produces.
    const turn4 = try parseTree(testing.allocator, "100644 blob aaa111\tsrc/auth.zig\x00");
    defer testing.allocator.free(turn4);
    const turn7 = try parseTree(testing.allocator, "100644 blob aaa111\tsrc/auth.zig\x00");
    defer testing.allocator.free(turn7);
    const turn5 = try parseTree(testing.allocator, "100644 blob zzz999\tsrc/auth.zig\x00");
    defer testing.allocator.free(turn5);

    const at4 = blobOf(turn4, "src/auth.zig").?;
    try testing.expect(std.mem.eql(u8, at4, blobOf(turn7, "src/auth.zig").?));
    try testing.expect(!std.mem.eql(u8, at4, blobOf(turn5, "src/auth.zig").?));
}

test "an object id is hex and nothing else" {
    const oid = try Oid.from("  a1b2c3d4\n");
    try testing.expectEqualStrings("a1b2c3d4", oid.slice());

    // Anything else is git having said something we did not expect, and
    // guessing at it is how a bad id ends up in a ref.
    try testing.expectError(error.BadOutput, Oid.from(""));
    try testing.expectError(error.BadOutput, Oid.from("not-hex"));
    try testing.expectError(error.BadOutput, Oid.from("fatal: not a git repository"));
}

test "the index is ours, and inside the directory lgtm already hides" {
    // Boundary 1. If this ever becomes `.git/index` the user's staged changes
    // are the thing that breaks, and they would not find out from us.
    try testing.expectEqualStrings(".lgtm/index", index_path);
    try testing.expect(std.mem.startsWith(u8, index_path, ".lgtm/"));
}

test "the index is primed from HEAD, so a snapshot is a whole tree" {
    // `read-tree HEAD` and not `read-tree --empty HEAD`, which is a
    // contradiction git rejects. The first version of this file had the
    // second, the failure was swallowed, and every snapshot silently contained
    // only the changed files - a store that cannot restore a working tree.
    var buf: [3][]const u8 = undefined;
    const argv = readTreeArgv(&buf);
    try testing.expectEqualSlices([]const u8, &.{ "git", "read-tree", "HEAD" }, argv);
    for (argv) |word| try testing.expect(!std.mem.eql(u8, word, "--empty"));
}

test "listing and deleting name our namespace and nothing else" {
    var a: [4][]const u8 = undefined;
    const list = listRefsArgv(&a);
    try testing.expectEqualStrings("for-each-ref", list[1]);
    // The pattern is the namespace, so the listing cannot return a branch even
    // if someone later widens what is done with the result.
    try testing.expectEqualStrings(ref_prefix, list[3]);

    var b: [4][]const u8 = undefined;
    const del = deleteRefArgv(&b, "refs/lgtm/s/1");
    try testing.expectEqualSlices([]const u8, &.{ "git", "update-ref", "-d", "refs/lgtm/s/1" }, del);
}
