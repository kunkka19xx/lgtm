// SPDX-License-Identifier: Apache-2.0
//
// What a forge is, to the rest of lgtm: the types a review is made of, and the
// handful of operations one has to answer. `core/gh.zig` is the GitHub
// implementation and the only one so far.
//
// Split out because the alternative was worse later rather than now. Every
// forge feature added another GitHub assumption to `ui/pr.zig`, and the
// coupling was still one file's worth - nine calls and four types - which is
// the cheapest this separation will ever be.
//
// A plain struct of function pointers, not a vtable with a context: an
// implementation shells out to a CLI that owns its own authentication, so
// there is no state to carry and nothing for a `*anyopaque` to point at.

const std = @import("std");
const Allocator = std.mem.Allocator;

const comments = @import("comments.zig");
const diff = @import("diff.zig");
const git = @import("git.zig");

/// Missing, unauthenticated, offline, or not a request. One error: the caller
/// can do nothing different about any of them, and the CLI says which on
/// stderr.
///
/// `TimedOut` is its own because the reader's next move differs - nothing is
/// wrong with the request or the login, and the key is worth pressing again.
pub const Error = error{
    Failed,
    TimedOut,
} || Allocator.Error;

/// Resolving reads git as well as the forge, and a missing object is a git
/// failure rather than a forge one.
pub const ResolveError = Error || git.Error;

/// One request, as a list row and as the thing a review is taken of.
///
/// `state` is the forge's own spelling; `status` is what a reader thinks of.
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
    /// Open but not finished. Its own field because `state` stays `OPEN` for
    /// a draft, and a draft is the row a reader most often skips.
    draft: bool = false,
    author: []const u8 = "",
    /// How big the read is, which is the one thing a list cannot say in
    /// words and the reader most wants before choosing.
    added: u32 = 0,
    removed: u32 = 0,
    /// Last, so a title containing a tab stays the person's sentence.
    title: []const u8,

    /// The state as a reader thinks of it: a draft is one of them, though to
    /// the forge it is a flag on an open request.
    pub fn status(self: Pr) []const u8 {
        if (self.draft) return "draft";
        if (std.mem.eql(u8, self.state, "OPEN")) return "open";
        if (std.mem.eql(u8, self.state, "MERGED")) return "merged";
        if (std.mem.eql(u8, self.state, "CLOSED")) return "closed";
        return self.state;
    }
};

/// A request as two refs. The whole of what a forge is asked for.
pub const Refs = struct {
    number: u32,
    /// `owner/repo`, kept so posting a review needs no second question.
    repo: []const u8,
    /// The merge base, which is what a three-dot diff is taken against.
    base: []const u8,
    /// The head commit.
    target: []const u8,
    /// For the status row, where two shas would say nothing usable.
    label: []const u8,
};

/// Somebody else's remark on the request, as it sits in the gutter beside the
/// reader's own.
pub const Remark = struct {
    /// What a later edit names.
    id: u64 = 0,
    path: []const u8,
    /// Where it sits in the request's head. Zero when the forge knows of no
    /// line at all, which is a comment on a file rather than on code.
    line: u32,
    /// Lines it covers, one being just `line`.
    span: u32 = 1,
    author: []const u8,
    body: []const u8,
    /// The line it was written against has gone from the diff. The forge
    /// answers with no line and keeps the original, which is the same fact
    /// `comments.State.stale` records.
    outdated: bool,
    /// The remark this one answers, or zero when it starts a thread. Without
    /// it, a reply is an unrelated row that happens to share a line.
    reply_to: u64 = 0,
    /// Seconds since the epoch, from the creation time. What orders a thread:
    /// ids rising with time is not a guarantee worth resting on.
    created: i64 = 0,
    /// The code the remark was written against, as the forge kept it: for a
    /// stale remark our own diff no longer holds the line.
    hunk: []const u8 = "",
};

/// What a review says when it is submitted.
pub const Event = enum {
    comment,
    approve,
    request_changes,

    pub fn wire(self: Event) []const u8 {
        return switch (self) {
            .comment => "COMMENT",
            .approve => "APPROVE",
            .request_changes => "REQUEST_CHANGES",
        };
    }
};

/// One forge, as everything above `core/` sees it.
///
/// Nine calls and a payload builder. Deliberately not a general client: these
/// are the operations the review loop actually makes, and an operation nothing
/// calls is one nobody can check still works.
pub const Forge = struct {
    /// What the messages call it.
    name: []const u8,

    /// Number to refs, asking the forge what the request is. Null number means
    /// the current branch, which is the common case - the branch is checked
    /// out because the agent just pushed it.
    resolve: *const fn (Allocator, Allocator, std.Io, ?u32) ResolveError!Refs,
    /// The same for a row already in hand, which needs no second round trip.
    refsOf: *const fn (Allocator, Allocator, std.Io, Pr) ResolveError!Refs,
    /// The open requests, or every one of them when `all`.
    list: *const fn (Allocator, Allocator, std.Io, bool) Error![]Pr,
    /// The inline remarks on one request: the ones carrying a path and a line.
    remarks: *const fn (Allocator, Allocator, std.Io, []const u8, u32) Error![]Remark,
    /// Who the reader is on the forge. Without it their own remark is
    /// indistinguishable from anybody else's.
    viewer: *const fn (Allocator, Allocator, std.Io) Error![]const u8,

    /// A whole review, in one request so a partial failure cannot happen.
    post: *const fn (Allocator, Allocator, std.Io, []const u8, u32, []const u8) Error!void,
    /// New text for a remark the reader already left.
    amend: *const fn (Allocator, Allocator, std.Io, []const u8, u64, []const u8) Error!void,
    /// A message on an existing thread, answering with the id the forge minted
    /// for it - or zero when its answer did not carry one.
    reply: *const fn (Allocator, Allocator, std.Io, []const u8, u32, u64, []const u8) Error!u64,
    /// One remark of the reader's own, off the request.
    drop: *const fn (Allocator, Allocator, std.Io, []const u8, u64) Error!void,

    /// The payload `post` sends, built from the store rather than from the
    /// screen. In the interface because the shape is the forge's: what goes
    /// inline, what falls back into the body, and how either is spelled.
    ///
    /// `ids` is filled with the remarks that went out, so the caller can mark
    /// exactly what was handed over.
    reviewBody: *const fn (
        *std.ArrayList(u8),
        Allocator,
        *const comments.Store,
        []const diff.FileDiff,
        Event,
        []const u8,
        *std.ArrayList(u32),
    ) Allocator.Error!void,
};
