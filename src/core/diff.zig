// SPDX-License-Identifier: Apache-2.0
//
// Parses `git diff` output into the hunk model. Everything allocated here
// belongs to the diff arena and dies on the next re-diff;
// text slices borrow from the raw output, which the arena also owns.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const hunk = @import("hunk.zig");

const Hunk = hunk.Hunk;
const DiffLines = hunk.DiffLines;
const LineKind = hunk.LineKind;

/// Above this many changed lines a file renders as a summary and its hunks are
/// parsed only when opened.
pub const large_file_lines = 5000;

pub const Status = enum { modified, added, deleted, renamed, binary };

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    status: Status,
    hunks: []Hunk = &.{},
    lines: DiffLines = .{},
    /// Set when the file exceeded `large_file_lines`; `hunks` and `lines` are
    /// then empty and the counts below are all the caller gets until it opens.
    summarised: bool = false,
    added: u32 = 0,
    removed: u32 = 0,
    /// Abbreviated blob hashes from git's `index <old>..<new>` line. These are
    /// the natural key for a parsed-diff cache, which is
    /// why they are captured even though nothing consumes them yet.
    old_blob: []const u8 = "",
    new_blob: []const u8 = "",
    /// Byte range of this file's section within the raw git output. A
    /// summarised file keeps it so its content can be materialised on open:
    /// the render is deferred, the code is never discarded.
    raw_lo: usize = 0,
    raw_hi: usize = 0,

    pub fn path(self: FileDiff) []const u8 {
        return if (self.status == .deleted) self.old_path else self.new_path;
    }
};

pub const Diff = struct {
    files: []FileDiff,

    pub fn deinit(self: *Diff, gpa: Allocator) void {
        for (self.files) |*f| {
            gpa.free(f.hunks);
            f.lines.deinit(gpa);
        }
        gpa.free(self.files);
        self.* = undefined;
    }

    pub fn find(self: Diff, p: []const u8) ?*const FileDiff {
        for (self.files) |*f| {
            if (std.mem.eql(u8, f.path(), p)) return f;
        }
        return null;
    }
};

pub const ParseError = error{MalformedHunkHeader} || Allocator.Error;

/// Parses a deferred file's content on demand.
///
/// Summarising is a rendering decision, never a discard: the code is the thing
/// being reviewed, so it always stays reachable. `raw` must be the same git
/// output the file was parsed from.
pub fn materialise(gpa: Allocator, f: *FileDiff, raw: []const u8) ParseError!void {
    if (!f.summarised) return;
    if (f.raw_hi > raw.len or f.raw_lo >= f.raw_hi) return;

    const one = try parseLimited(gpa, raw[f.raw_lo..f.raw_hi], std.math.maxInt(u32));
    defer gpa.free(one.files);
    if (one.files.len != 1) {
        for (one.files) |*x| {
            gpa.free(x.hunks);
            x.lines.deinit(gpa);
        }
        return;
    }

    const full = one.files[0];
    f.hunks = full.hunks;
    f.lines = full.lines;
    f.summarised = false;
}

/// Parses unified diff text. Unknown or unsupported sections are skipped rather
/// than rejected: a diff containing one binary file must still show the rest.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Diff {
    return parseLimited(gpa, text, large_file_lines);
}

/// As `parse`, with the summary threshold under caller control. `materialise`
/// passes no limit to force a file that was deferred into full content.
pub fn parseLimited(gpa: Allocator, text: []const u8, limit: u32) ParseError!Diff {
    var files: std.ArrayList(FileDiff) = .empty;
    errdefer files.deinit(gpa);

    var it = LineIter{ .text = text };
    var cur: ?Builder = null;
    errdefer if (cur) |*b| b.deinit(gpa);

    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (cur) |*b| try files.append(gpa, try b.finish(gpa, it.line_start, limit));
            cur = Builder.init(line, it.line_start);
            continue;
        }
        var b = if (cur) |*x| x else continue;

        if (std.mem.startsWith(u8, line, "--- ")) {
            b.setOld(line[4..]);
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            b.setNew(line[4..]);
        } else if (std.mem.startsWith(u8, line, "index ")) {
            b.setBlobs(line["index ".len..]);
        } else if (std.mem.startsWith(u8, line, "Binary files ")) {
            b.status = .binary;
        } else if (std.mem.startsWith(u8, line, "rename from ")) {
            b.old_path = line["rename from ".len..];
            b.status = .renamed;
        } else if (std.mem.startsWith(u8, line, "rename to ")) {
            b.new_path = line["rename to ".len..];
            b.status = .renamed;
        } else if (std.mem.startsWith(u8, line, "@@")) {
            try b.startHunk(gpa, line);
        } else if (b.in_hunk) {
            // A hunk body ends at the first line that is not part of it.
            if (line.len == 0) {
                // git emits a bare empty line for an empty context line.
                try b.addLine(gpa, .context, "");
            } else switch (line[0]) {
                ' ' => try b.addLine(gpa, .context, line[1..]),
                '+' => try b.addLine(gpa, .add, line[1..]),
                '-' => try b.addLine(gpa, .del, line[1..]),
                '\\' => {}, // "\ No newline at end of file"
                else => b.in_hunk = false,
            }
        }
    }
    if (cur) |*b| try files.append(gpa, try b.finish(gpa, text.len, limit));

    return .{ .files = try files.toOwnedSlice(gpa) };
}

/// Splits on newlines without allocating, and without a trailing empty field.
const LineIter = struct {
    text: []const u8,
    pos: usize = 0,
    /// Offset of the line most recently returned.
    line_start: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        self.line_start = self.pos;
        const nl = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const line = self.text[self.pos..nl];
        self.pos = nl + 1;
        return std.mem.trimEnd(u8, line, "\r");
    }
};

const Builder = struct {
    old_path: []const u8 = "",
    new_path: []const u8 = "",
    status: Status = .modified,
    in_hunk: bool = false,
    added: u32 = 0,
    removed: u32 = 0,
    old_no: u32 = 0,
    new_no: u32 = 0,
    old_blob: []const u8 = "",
    new_blob: []const u8 = "",
    /// Byte range of this file's section within the raw git output. A
    /// summarised file keeps it so its content can be materialised on open:
    /// the render is deferred, the code is never discarded.
    raw_lo: usize = 0,
    raw_hi: usize = 0,

    hunks: std.ArrayList(Hunk) = .empty,
    kind: std.ArrayList(LineKind) = .empty,
    old_nos: std.ArrayList(u32) = .empty,
    new_nos: std.ArrayList(u32) = .empty,
    text: std.ArrayList([]const u8) = .empty,

    fn init(header: []const u8, raw_lo: usize) Builder {
        var b: Builder = .{ .raw_lo = raw_lo };
        // "diff --git a/<old> b/<new>". Paths with spaces are handled by the
        // ---/+++ lines that follow, which is why these are only a fallback.
        const rest = header["diff --git ".len..];
        if (std.mem.indexOf(u8, rest, " b/")) |i| {
            b.old_path = stripPrefix(rest[0..i]);
            b.new_path = stripPrefix(rest[i + 1 ..]);
        }
        return b;
    }

    /// "index <old>..<new>[ mode]"
    fn setBlobs(self: *Builder, arg: []const u8) void {
        const sep = std.mem.indexOf(u8, arg, "..") orelse return;
        self.old_blob = arg[0..sep];
        var rest = arg[sep + 2 ..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
        self.new_blob = rest;
    }

    fn setOld(self: *Builder, arg: []const u8) void {
        if (std.mem.eql(u8, arg, "/dev/null")) {
            self.status = .added;
        } else {
            self.old_path = stripPrefix(arg);
        }
    }

    fn setNew(self: *Builder, arg: []const u8) void {
        if (std.mem.eql(u8, arg, "/dev/null")) {
            self.status = .deleted;
        } else {
            self.new_path = stripPrefix(arg);
        }
    }

    fn startHunk(self: *Builder, gpa: Allocator, header: []const u8) ParseError!void {
        const h = try parseHunkHeader(header);
        self.old_no = h.old_start;
        self.new_no = h.new_start;
        self.in_hunk = true;
        try self.hunks.append(gpa, .{
            .old_start = h.old_start,
            .old_count = h.old_count,
            .new_start = h.new_start,
            .new_count = h.new_count,
            .section = h.section,
            .lo = @intCast(self.kind.items.len),
            .hi = @intCast(self.kind.items.len),
        });
    }

    fn addLine(self: *Builder, gpa: Allocator, k: LineKind, s: []const u8) Allocator.Error!void {
        try self.kind.append(gpa, k);
        try self.text.append(gpa, s);
        switch (k) {
            .add => {
                try self.old_nos.append(gpa, 0);
                try self.new_nos.append(gpa, self.new_no);
                self.new_no += 1;
                self.added += 1;
            },
            .del => {
                try self.old_nos.append(gpa, self.old_no);
                try self.new_nos.append(gpa, 0);
                self.old_no += 1;
                self.removed += 1;
            },
            .context => {
                try self.old_nos.append(gpa, self.old_no);
                try self.new_nos.append(gpa, self.new_no);
                self.old_no += 1;
                self.new_no += 1;
            },
        }
        self.hunks.items[self.hunks.items.len - 1].hi = @intCast(self.kind.items.len);
    }

    fn finish(self: *Builder, gpa: Allocator, raw_hi: usize, limit: u32) Allocator.Error!FileDiff {
        var out: FileDiff = .{
            .old_path = self.old_path,
            .new_path = self.new_path,
            .status = self.status,
            .added = self.added,
            .removed = self.removed,
            .old_blob = self.old_blob,
            .new_blob = self.new_blob,
            .raw_lo = self.raw_lo,
            .raw_hi = raw_hi,
        };

        if (self.status == .binary or self.added + self.removed > limit) {
            out.summarised = self.status != .binary;
            self.discard(gpa);
            return out;
        }

        out.lines = .{
            .kind = try self.kind.toOwnedSlice(gpa),
            .old_no = try self.old_nos.toOwnedSlice(gpa),
            .new_no = try self.new_nos.toOwnedSlice(gpa),
            .text = try self.text.toOwnedSlice(gpa),
        };
        out.hunks = try self.hunks.toOwnedSlice(gpa);
        for (out.hunks) |*h| h.hash = hunk.hashHunk(out.lines, h.lo, h.hi);
        return out;
    }

    fn discard(self: *Builder, gpa: Allocator) void {
        self.hunks.deinit(gpa);
        self.kind.deinit(gpa);
        self.old_nos.deinit(gpa);
        self.new_nos.deinit(gpa);
        self.text.deinit(gpa);
        self.* = .{};
    }

    fn deinit(self: *Builder, gpa: Allocator) void {
        self.discard(gpa);
    }
};

fn stripPrefix(p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, "a/") or std.mem.startsWith(u8, p, "b/")) return p[2..];
    return p;
}

const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: []const u8,
};

/// Parses `@@ -old[,count] +new[,count] @@ section`.
pub fn parseHunkHeader(line: []const u8) ParseError!HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.MalformedHunkHeader;
    const close = std.mem.indexOf(u8, line, " @@") orelse return error.MalformedHunkHeader;
    var ranges = std.mem.tokenizeScalar(u8, line[4..close], ' ');

    const old = ranges.next() orelse return error.MalformedHunkHeader;
    const new_raw = ranges.next() orelse return error.MalformedHunkHeader;
    if (new_raw.len == 0 or new_raw[0] != '+') return error.MalformedHunkHeader;

    const o = try parseRange(old);
    const n = try parseRange(new_raw[1..]);
    const after = line[close + 3 ..];

    return .{
        .old_start = o.start,
        .old_count = o.count,
        .new_start = n.start,
        .new_count = n.count,
        .section = std.mem.trim(u8, after, " "),
    };
}

fn parseRange(s: []const u8) ParseError!struct { start: u32, count: u32 } {
    const comma = std.mem.indexOfScalar(u8, s, ',');
    const start_s = if (comma) |c| s[0..c] else s;
    const count_s = if (comma) |c| s[c + 1 ..] else "1";
    const start = std.fmt.parseInt(u32, start_s, 10) catch return error.MalformedHunkHeader;
    const count = std.fmt.parseInt(u32, count_s, 10) catch return error.MalformedHunkHeader;
    return .{ .start = start, .count = count };
}

const testing = std.testing;

test "hunk header with counts" {
    const h = try parseHunkHeader("@@ -12,7 +12,9 @@ fn validate_token");
    try testing.expectEqual(@as(u32, 12), h.old_start);
    try testing.expectEqual(@as(u32, 7), h.old_count);
    try testing.expectEqual(@as(u32, 12), h.new_start);
    try testing.expectEqual(@as(u32, 9), h.new_count);
    try testing.expectEqualStrings("fn validate_token", h.section);
}

test "hunk header with implicit single-line counts" {
    const h = try parseHunkHeader("@@ -3 +4 @@");
    try testing.expectEqual(@as(u32, 3), h.old_start);
    try testing.expectEqual(@as(u32, 1), h.old_count);
    try testing.expectEqual(@as(u32, 4), h.new_start);
    try testing.expectEqual(@as(u32, 1), h.new_count);
    try testing.expectEqualStrings("", h.section);
}

test "malformed hunk headers are rejected" {
    try testing.expectError(error.MalformedHunkHeader, parseHunkHeader("@@ nonsense @@"));
    try testing.expectError(error.MalformedHunkHeader, parseHunkHeader("not a header"));
    try testing.expectError(error.MalformedHunkHeader, parseHunkHeader("@@ -1,2 1,2 @@"));
}

const sample =
    \\diff --git a/src/auth.rs b/src/auth.rs
    \\index 1234567..89abcde 100644
    \\--- a/src/auth.rs
    \\+++ b/src/auth.rs
    \\@@ -44,7 +44,8 @@ fn validate_token
    \\ let claims = decode(&t)?;
    \\
    \\-if claims.exp < now() {
    \\+if claims.exp <= now() {
    \\+    metrics::expired();
    \\     return Err(Expired);
    \\ }
    \\ Ok(claims)
    \\
;

test "parses a single file with one hunk" {
    var d = try parse(testing.allocator, sample);
    defer d.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), d.files.len);
    const f = d.files[0];
    try testing.expectEqualStrings("src/auth.rs", f.path());
    try testing.expectEqual(Status.modified, f.status);
    try testing.expectEqual(@as(usize, 1), f.hunks.len);
    try testing.expectEqual(@as(u32, 2), f.added);
    try testing.expectEqual(@as(u32, 1), f.removed);
    try testing.expectEqualStrings("fn validate_token", f.hunks[0].section);
}

test "line numbers advance independently on each side" {
    var d = try parse(testing.allocator, sample);
    defer d.deinit(testing.allocator);
    const f = d.files[0];

    // " let claims" is context at old 44 / new 44.
    try testing.expectEqual(LineKind.context, f.lines.kind[0]);
    try testing.expectEqual(@as(u32, 44), f.lines.old_no[0]);
    try testing.expectEqual(@as(u32, 44), f.lines.new_no[0]);

    // The deletion consumes an old number and no new number.
    try testing.expectEqual(LineKind.del, f.lines.kind[2]);
    try testing.expectEqual(@as(u32, 46), f.lines.old_no[2]);
    try testing.expectEqual(@as(u32, 0), f.lines.new_no[2]);

    // The additions consume new numbers and no old ones.
    try testing.expectEqual(LineKind.add, f.lines.kind[3]);
    try testing.expectEqual(@as(u32, 0), f.lines.old_no[3]);
    try testing.expectEqual(@as(u32, 46), f.lines.new_no[3]);
    try testing.expectEqual(@as(u32, 47), f.lines.new_no[4]);
}

test "text slices exclude the leading marker" {
    var d = try parse(testing.allocator, sample);
    defer d.deinit(testing.allocator);
    const f = d.files[0];

    try testing.expectEqualStrings("let claims = decode(&t)?;", f.lines.text[0]);
    try testing.expectEqualStrings("if claims.exp < now() {", f.lines.text[2]);
    try testing.expectEqualStrings("if claims.exp <= now() {", f.lines.text[3]);
}

test "added and deleted files are detected" {
    const added_src =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+one
        \\+two
        \\
    ;
    var d = try parse(testing.allocator, added_src);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(Status.added, d.files[0].status);
    try testing.expectEqualStrings("new.txt", d.files[0].path());

    const deleted_src =
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-one
        \\-two
        \\
    ;
    var d2 = try parse(testing.allocator, deleted_src);
    defer d2.deinit(testing.allocator);
    try testing.expectEqual(Status.deleted, d2.files[0].status);
    try testing.expectEqualStrings("old.txt", d2.files[0].path());
}

test "a binary file does not stop the rest of the diff" {
    const src =
        \\diff --git a/logo.png b/logo.png
        \\index aaa..bbb 100644
        \\Binary files a/logo.png and b/logo.png differ
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\
    ;
    var d = try parse(testing.allocator, src);
    defer d.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), d.files.len);
    try testing.expectEqual(Status.binary, d.files[0].status);
    try testing.expectEqual(@as(usize, 0), d.files[0].hunks.len);
    try testing.expectEqual(@as(usize, 1), d.files[1].hunks.len);
}

test "multiple hunks in one file each get a hash" {
    const src =
        \\diff --git a/m.txt b/m.txt
        \\--- a/m.txt
        \\+++ b/m.txt
        \\@@ -1,2 +1,2 @@
        \\-a
        \\+A
        \\ ctx
        \\@@ -40,2 +40,2 @@
        \\-b
        \\+B
        \\ ctx2
        \\
    ;
    var d = try parse(testing.allocator, src);
    defer d.deinit(testing.allocator);
    const f = d.files[0];

    try testing.expectEqual(@as(usize, 2), f.hunks.len);
    try testing.expectEqual(@as(u32, 1), f.hunks[0].new_start);
    try testing.expectEqual(@as(u32, 40), f.hunks[1].new_start);
    try testing.expect(f.hunks[0].hash != 0);
    try testing.expect(f.hunks[0].hash != f.hunks[1].hash);
    try testing.expectEqual(@as(u32, 3), f.hunks[1].lo);
}

test "no newline at end of file marker is ignored" {
    const src =
        \\diff --git a/n.txt b/n.txt
        \\--- a/n.txt
        \\+++ b/n.txt
        \\@@ -1 +1 @@
        \\-x
        \\\ No newline at end of file
        \\+y
        \\
    ;
    var d = try parse(testing.allocator, src);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.files[0].lines.len());
}

test "empty input yields no files" {
    var d = try parse(testing.allocator, "");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), d.files.len);
}

// Recorded from real `git diff --cached`, covering add, rename, modify,
// binary, delete and a git-merged multi-change hunk. The expectations below
// are `git diff --numstat` output, so git itself is the oracle.
const recorded = @embedFile("mixed_diff");

test "parses recorded git output against numstat" {
    var d = try parse(testing.allocator, recorded);
    defer d.deinit(testing.allocator);

    const Want = struct {
        path: []const u8,
        status: Status,
        added: u32,
        removed: u32,
    };
    const want = [_]Want{
        .{ .path = "src/added.txt", .status = .added, .added = 1, .removed = 0 },
        .{ .path = "src/after.txt", .status = .renamed, .added = 0, .removed = 0 },
        .{ .path = "src/auth.rs", .status = .modified, .added = 2, .removed = 1 },
        .{ .path = "src/blob.bin", .status = .binary, .added = 0, .removed = 0 },
        .{ .path = "src/gone.txt", .status = .deleted, .added = 0, .removed = 2 },
        .{ .path = "src/list.txt", .status = .modified, .added = 2, .removed = 2 },
    };

    try testing.expectEqual(want.len, d.files.len);
    for (want, d.files) |w, f| {
        try testing.expectEqualStrings(w.path, f.path());
        try testing.expectEqual(w.status, f.status);
        try testing.expectEqual(w.added, f.added);
        try testing.expectEqual(w.removed, f.removed);
    }
}

test "recorded rename keeps both paths" {
    var d = try parse(testing.allocator, recorded);
    defer d.deinit(testing.allocator);

    const f = d.files[1];
    try testing.expectEqualStrings("src/before.txt", f.old_path);
    try testing.expectEqualStrings("src/after.txt", f.new_path);
    try testing.expectEqual(@as(usize, 0), f.hunks.len);
}

test "git merges nearby changes into one hunk" {
    var d = try parse(testing.allocator, recorded);
    defer d.deinit(testing.allocator);

    // list.txt changes lines 3 and 10; with 3 lines of context those hunks
    // touch, so git emits a single hunk. This is the merge case from SPEC 6.5
    // arriving from real git rather than a contrived fixture.
    const f = d.find("src/list.txt").?;
    try testing.expectEqual(@as(usize, 1), f.hunks.len);
    try testing.expectEqual(@as(u32, 1), f.hunks[0].new_start);
    try testing.expectEqual(@as(u32, 12), f.hunks[0].new_count);
}

test "every parsed line number matches its position in the new file" {
    var d = try parse(testing.allocator, recorded);
    defer d.deinit(testing.allocator);

    const f = d.find("src/auth.rs").?;
    var expected_new: u32 = 1;
    for (0..f.lines.len()) |i| {
        switch (f.lines.kind[i]) {
            .del => try testing.expectEqual(@as(u32, 0), f.lines.new_no[i]),
            else => {
                try testing.expectEqual(expected_new, f.lines.new_no[i]);
                expected_new += 1;
            },
        }
    }
}

test "blob hashes are captured for the cache key" {
    var d = try parse(testing.allocator, recorded);
    defer d.deinit(testing.allocator);

    const f = d.find("src/auth.rs").?;
    try testing.expect(f.old_blob.len >= 7);
    try testing.expect(f.new_blob.len >= 7);
    try testing.expect(!std.mem.eql(u8, f.old_blob, f.new_blob));
    // The mode suffix must not leak into the hash.
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, f.new_blob, ' '));
}

test "an oversized file is summarised instead of parsed" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator,
        \\diff --git a/big.txt b/big.txt
        \\--- a/big.txt
        \\+++ b/big.txt
        \\
    );
    var header: [64]u8 = undefined;
    try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&header, "@@ -1,{d} +1,{d} @@\n", .{ large_file_lines + 10, large_file_lines + 10 }));
    for (0..large_file_lines + 10) |i| {
        try buf.appendSlice(testing.allocator, if (i % 2 == 0) "+added\n" else "-removed\n");
    }

    var d = try parse(testing.allocator, buf.items);
    defer d.deinit(testing.allocator);

    const f = d.files[0];
    try testing.expect(f.summarised);
    try testing.expectEqual(@as(usize, 0), f.hunks.len);
    try testing.expectEqual(@as(usize, 0), f.lines.len());
    // The counts survive, because the file list still has to show them.
    try testing.expect(f.added + f.removed > large_file_lines);
}

test "a file just under the limit is parsed in full" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator,
        \\diff --git a/ok.txt b/ok.txt
        \\--- a/ok.txt
        \\+++ b/ok.txt
        \\@@ -1,10 +1,10 @@
        \\
    );
    for (0..10) |_| try buf.appendSlice(testing.allocator, "+line\n");

    var d = try parse(testing.allocator, buf.items);
    defer d.deinit(testing.allocator);

    try testing.expect(!d.files[0].summarised);
    try testing.expectEqual(@as(usize, 10), d.files[0].lines.len());
}

test "a deferred file materialises to full content, losing nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator,
        \\diff --git a/big.txt b/big.txt
        \\--- a/big.txt
        \\+++ b/big.txt
        \\
    );
    var header: [64]u8 = undefined;
    const n = large_file_lines + 10;
    try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&header, "@@ -1,{d} +1,{d} @@\n", .{ n, n }));
    for (0..n) |i| {
        try buf.appendSlice(testing.allocator, if (i % 2 == 0) "+added\n" else "-removed\n");
    }

    var d = try parse(testing.allocator, buf.items);
    defer d.deinit(testing.allocator);

    // Deferred, so nothing is rendered yet.
    try testing.expect(d.files[0].summarised);
    try testing.expectEqual(@as(usize, 0), d.files[0].lines.len());

    // But the code is still reachable, which is the whole point.
    try materialise(testing.allocator, &d.files[0], buf.items);
    try testing.expect(!d.files[0].summarised);
    try testing.expectEqual(@as(usize, n), d.files[0].lines.len());
    try testing.expectEqual(@as(usize, 1), d.files[0].hunks.len);
    try testing.expectEqualStrings("added", d.files[0].lines.text[0]);
}

test "materialising one file leaves its neighbours alone" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator,
        \\diff --git a/small.txt b/small.txt
        \\--- a/small.txt
        \\+++ b/small.txt
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\diff --git a/big.txt b/big.txt
        \\--- a/big.txt
        \\+++ b/big.txt
        \\
    );
    var header: [64]u8 = undefined;
    const n = large_file_lines + 4;
    try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&header, "@@ -1,{d} +1,{d} @@\n", .{ n, n }));
    for (0..n) |_| try buf.appendSlice(testing.allocator, "+line\n");

    var d = try parse(testing.allocator, buf.items);
    defer d.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), d.files.len);
    try testing.expect(!d.files[0].summarised);
    try testing.expect(d.files[1].summarised);

    try materialise(testing.allocator, &d.files[1], buf.items);
    try testing.expectEqual(@as(usize, n), d.files[1].lines.len());
    // The small file is untouched by its neighbour materialising.
    try testing.expectEqual(@as(usize, 2), d.files[0].lines.len());
    try testing.expectEqualStrings("y", d.files[0].lines.text[1]);
}

test "materialise is a no-op on a file that was never deferred" {
    var d = try parse(testing.allocator, sample);
    defer d.deinit(testing.allocator);
    const before = d.files[0].lines.len();
    try materialise(testing.allocator, &d.files[0], sample);
    try testing.expectEqual(before, d.files[0].lines.len());
}
