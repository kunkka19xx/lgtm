// SPDX-License-Identifier: Apache-2.0
//
// The buffer is the source of truth; the diff is an overlay over two of them
// (ARCHITECTURE.md 11.1).
//
// Two consequences fall out of this and are the reason it exists:
//   - Editing later is additive. A mutable worktree Buffer is what a TextEdit
//     applies to; git's diff text is not mutable.
//   - Context beyond the hunk becomes available. Git emits three lines either
//     side; the buffers hold the whole file, so expanding context is possible
//     at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../text/buffer.zig").Buffer;
const proc = @import("../io/proc.zig");
const fsmod = @import("../io/fs.zig");
const diff = @import("diff.zig");

pub const max_blob_bytes = 64 << 20;

pub const Error = proc.RunError || Allocator.Error || error{GitFailed};

/// Both sides of one file. `head` is absent for an added file, `work` for a
/// deleted one.
pub const FileSource = struct {
    path: []const u8,
    head: ?Buffer = null,
    work: ?Buffer = null,

    pub fn deinit(self: *FileSource, gpa: Allocator) void {
        if (self.head) |*b| b.deinit();
        if (self.work) |*b| b.deinit();
        gpa.free(self.path);
        self.* = undefined;
    }
};

pub const Sources = struct {
    files: []FileSource,

    pub fn deinit(self: *Sources, gpa: Allocator) void {
        for (self.files) |*f| f.deinit(gpa);
        gpa.free(self.files);
        self.* = undefined;
    }

    pub fn find(self: Sources, p: []const u8) ?*FileSource {
        for (self.files) |*f| {
            if (std.mem.eql(u8, f.path, p)) return f;
        }
        return null;
    }
};

/// Loads both sides of every file in `d`.
///
/// HEAD blobs come from a single `git cat-file --batch`, never one process per
/// file (PERFORMANCE.md 8.1). Worktree content is read directly, one whole-file
/// read each (8.2).
pub fn load(gpa: Allocator, io: std.Io, repo: ?[]const u8, d: diff.Diff) Error!Sources {
    return loadAt(gpa, io, repo, d, null);
}

/// As `load`, with the right-hand side read from a tree instead of from disk.
///
/// What the timeline needs (SNAPSHOTS.md 5.3): viewing a turn means the "new"
/// side of every file is a blob in a snapshot, not the file on disk. Everything
/// downstream is unchanged - `attach` still verifies each line against the
/// buffer it should have come from, which is what keeps the rule that the
/// buffer is the source of truth true for a historical view as well as a live
/// one (ARCHITECTURE.md 11.1).
pub fn loadAt(
    gpa: Allocator,
    io: std.Io,
    repo: ?[]const u8,
    d: diff.Diff,
    work_ref: ?[]const u8,
) Error!Sources {
    var files: std.ArrayList(FileSource) = .empty;
    errdefer {
        for (files.items) |*f| f.deinit(gpa);
        files.deinit(gpa);
    }

    // One request line per file that has a HEAD side.
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    var wanted: std.ArrayList(usize) = .empty;
    defer wanted.deinit(gpa);

    for (d.files, 0..) |f, i| {
        try files.append(gpa, .{ .path = try gpa.dupe(u8, f.path()) });
        if (f.status == .added or f.status == .binary) continue;
        try wanted.append(gpa, i);
        try req.appendSlice(gpa, "HEAD:");
        try req.appendSlice(gpa, f.old_path);
        try req.append(gpa, '\n');
    }

    if (wanted.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "git");
        if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
        try argv.appendSlice(gpa, &.{ "cat-file", "--batch" });

        const out = try proc.runWithInput(gpa, io, argv.items, req.items, max_blob_bytes);
        defer out.deinit(gpa);
        if (out.exit_code != 0) return error.GitFailed;

        var cursor: usize = 0;
        for (wanted.items) |i| {
            const blob = nextBlob(out.stdout, &cursor) orelse break;
            files.items[i].head = try Buffer.initOwned(gpa, try gpa.dupe(u8, blob));
        }
    }

    if (work_ref) |ref| {
        // One batch again, for the same reason the HEAD side is one.
        var wreq: std.ArrayList(u8) = .empty;
        defer wreq.deinit(gpa);
        var wwant: std.ArrayList(usize) = .empty;
        defer wwant.deinit(gpa);
        for (d.files, 0..) |f, i| {
            if (f.status == .deleted or f.status == .binary) continue;
            try wwant.append(gpa, i);
            try wreq.appendSlice(gpa, ref);
            try wreq.append(gpa, ':');
            try wreq.appendSlice(gpa, f.path());
            try wreq.append(gpa, '\n');
        }
        if (wwant.items.len > 0) {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.append(gpa, "git");
            if (repo) |r| try argv.appendSlice(gpa, &.{ "-C", r });
            try argv.appendSlice(gpa, &.{ "cat-file", "--batch" });

            const out = try proc.runWithInput(gpa, io, argv.items, wreq.items, max_blob_bytes);
            defer out.deinit(gpa);
            if (out.exit_code != 0) return error.GitFailed;

            var cursor: usize = 0;
            for (wwant.items) |i| {
                const blob = nextBlob(out.stdout, &cursor) orelse break;
                files.items[i].work = try Buffer.initOwned(gpa, try gpa.dupe(u8, blob));
            }
        }
        return .{ .files = try files.toOwnedSlice(gpa) };
    }

    for (d.files, 0..) |f, i| {
        if (f.status == .deleted or f.status == .binary) continue;
        const full = if (repo) |r| try std.fs.path.join(gpa, &.{ r, f.path() }) else try gpa.dupe(u8, f.path());
        defer gpa.free(full);
        const bytes = fsmod.readFile(io, gpa, full, max_blob_bytes) catch continue;
        files.items[i].work = try Buffer.initOwned(gpa, bytes);
    }

    return .{ .files = try files.toOwnedSlice(gpa) };
}

/// `git cat-file --batch` emits "<sha> <type> <size>\n<contents>\n" per
/// request, or "<name> missing\n". Size is authoritative, so contents
/// containing newlines parse correctly.
///
/// Public because the snapshot store reads blobs out of a marked tree the same
/// way, with `<ref>:<path>` request lines instead of blob ids. One parser for
/// one output format, rather than a second copy that drifts.
pub fn nextBlob(out: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= out.len) return null;
    const nl = std.mem.indexOfScalarPos(u8, out, cursor.*, '\n') orelse return null;
    const header = out[cursor.*..nl];
    cursor.* = nl + 1;

    if (std.mem.endsWith(u8, header, " missing")) return "";

    var it = std.mem.tokenizeScalar(u8, header, ' ');
    _ = it.next() orelse return null; // sha
    _ = it.next() orelse return null; // type
    const size_s = it.next() orelse return null;
    const size = std.fmt.parseInt(usize, size_s, 10) catch return null;
    if (cursor.* + size > out.len) return null;

    const body = out[cursor.* .. cursor.* + size];
    cursor.* += size + 1; // trailing newline
    return body;
}

pub const AttachError = error{ContentMismatch} || Allocator.Error;

/// Repoints every line's text at the buffers, so rendering reads from the
/// buffers rather than from git's diff output.
///
/// Each line is checked against the buffer it should have come from. A mismatch
/// means the file changed between git running and the read, which is exactly
/// the torn-read hazard of watching a tree an agent is writing to (SPEC.md 9).
/// Reporting it lets the caller re-diff rather than render a blend of two
/// states.
pub fn attach(f: *diff.FileDiff, src: FileSource) AttachError!void {
    if (f.summarised) return;

    for (0..f.lines.len()) |i| {
        const buf: ?Buffer = switch (f.lines.kind[i]) {
            .del => src.head,
            .add, .context => src.work,
        };
        const b = buf orelse continue;
        const no = switch (f.lines.kind[i]) {
            .del => f.lines.old_no[i],
            .add, .context => f.lines.new_no[i],
        };
        if (no == 0) continue;
        const line = b.line(no - 1) orelse return error.ContentMismatch;
        if (!std.mem.eql(u8, line, f.lines.text[i])) return error.ContentMismatch;
        f.lines.text[i] = line;
    }
}

const testing = std.testing;

test "cat-file batch splits blobs by their declared size" {
    const out = "abc123 blob 6\nhello\n\ndef456 blob 4\nhi!\n\n";
    var cursor: usize = 0;
    try testing.expectEqualStrings("hello\n", nextBlob(out, &cursor).?);
    try testing.expectEqualStrings("hi!\n", nextBlob(out, &cursor).?);
    try testing.expect(nextBlob(out, &cursor) == null);
}

test "a blob containing newlines is not split early" {
    const body = "line1\nline2\nline3\n";
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "sha blob {d}\n{s}\n", .{ body.len, body });
    var cursor: usize = 0;
    try testing.expectEqualStrings(body, nextBlob(out, &cursor).?);
}

test "a missing object yields empty content rather than desyncing" {
    const out = "HEAD:nope missing\nsha blob 3\nabc\n";
    var cursor: usize = 0;
    try testing.expectEqualStrings("", nextBlob(out, &cursor).?);
    try testing.expectEqualStrings("abc", nextBlob(out, &cursor).?);
}

test "attach repoints text at the buffers" {
    const gpa = testing.allocator;
    var d = try diff.parse(gpa,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old
        \\+new
        \\
    );
    defer d.deinit(gpa);

    var src: FileSource = .{
        .path = try gpa.dupe(u8, "f.txt"),
        .head = try Buffer.initOwned(gpa, try gpa.dupe(u8, "keep\nold\n")),
        .work = try Buffer.initOwned(gpa, try gpa.dupe(u8, "keep\nnew\n")),
    };
    defer src.deinit(gpa);

    try attach(&d.files[0], src);

    // Text now points into the buffers, not into the diff output.
    const work = src.work.?;
    try testing.expectEqual(work.line(0).?.ptr, d.files[0].lines.text[0].ptr);
    try testing.expectEqual(src.head.?.line(1).?.ptr, d.files[0].lines.text[1].ptr);
    try testing.expectEqual(work.line(1).?.ptr, d.files[0].lines.text[2].ptr);
}

test "attach reports a torn read instead of blending two states" {
    const gpa = testing.allocator;
    var d = try diff.parse(gpa,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    );
    defer d.deinit(gpa);

    // The worktree moved on after git ran.
    var src: FileSource = .{
        .path = try gpa.dupe(u8, "f.txt"),
        .head = try Buffer.initOwned(gpa, try gpa.dupe(u8, "old\n")),
        .work = try Buffer.initOwned(gpa, try gpa.dupe(u8, "something else entirely\n")),
    };
    defer src.deinit(gpa);

    try testing.expectError(error.ContentMismatch, attach(&d.files[0], src));
}

test "buffers hold context beyond what git emits" {
    const gpa = testing.allocator;

    // Git gives three lines of context either side. A note or a reader wanting
    // line 1 of a hunk starting at line 8 has nothing to read in the diff text.
    var d = try diff.parse(gpa,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -7,2 +7,2 @@
        \\ seven
        \\-eight
        \\+EIGHT
        \\
    );
    defer d.deinit(gpa);

    const whole = "one\ntwo\nthree\nfour\nfive\nsix\nseven\nEIGHT\nnine\nten\n";
    var src: FileSource = .{
        .path = try gpa.dupe(u8, "f.txt"),
        .head = try Buffer.initOwned(gpa, try gpa.dupe(u8, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")),
        .work = try Buffer.initOwned(gpa, try gpa.dupe(u8, whole)),
    };
    defer src.deinit(gpa);

    try attach(&d.files[0], src);

    // The diff carried three lines around the change. The buffer carries the
    // whole file, which is what makes expanding context possible at all.
    try testing.expectEqual(@as(usize, 3), d.files[0].lines.len());
    try testing.expectEqual(@as(u32, 10), src.work.?.lineCount());
    try testing.expectEqualStrings("one", src.work.?.line(0).?);
    try testing.expectEqualStrings("ten", src.work.?.line(9).?);
}

test "attach tolerates a file with only one side" {
    const gpa = testing.allocator;
    var d = try diff.parse(gpa,
        \\diff --git a/new.txt b/new.txt
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+alpha
        \\+beta
        \\
    );
    defer d.deinit(gpa);

    var src: FileSource = .{
        .path = try gpa.dupe(u8, "new.txt"),
        .work = try Buffer.initOwned(gpa, try gpa.dupe(u8, "alpha\nbeta\n")),
    };
    defer src.deinit(gpa);

    try attach(&d.files[0], src);
    try testing.expectEqualStrings(src.work.?.line(0).?, d.files[0].lines.text[0]);
}
