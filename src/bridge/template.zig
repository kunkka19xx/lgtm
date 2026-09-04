// SPDX-License-Identifier: Apache-2.0
//
// Every outgoing string is a template, from day one. The
// table below is the internal default set; `[templates]` in a config file is
// v0.2 and lands as an override of these fields, which is the whole reason
// the strings are data rather than format literals scattered through dispatch.
//
// Pure text in, pure text out. No allocator lifetime beyond the caller's list,
// no knowledge of what a hunk is.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The v0.1 set. Field names are the config keys they will become.
pub const Table = struct {
    /// The cursor on a line that exists in the new file.
    ref_single: []const u8 = "#{change_id} {path}:{line}",
    /// A visual selection, resolved against the new file.
    ref_range: []const u8 = "#{change_id} {path}:{start}-{end}",
    /// A charwise selection inside one line: the line, and the text itself.
    /// A column number would be no use to an agent - it does not count
    /// columns, it reads the line - but the words do the pointing.
    ref_span: []const u8 = "#{change_id} {path}:{line} `{span}`",
    /// The cursor on a deleted line: the new file has no such line, so the
    /// reference is the enclosing hunk plus a note saying why.
    ref_hunk: []const u8 = "#{change_id} {path}:{line} (deleted lines in this hunk)",
    /// No hunk to point at - a file whose body was never parsed because it
    /// exceeded `large_file_lines`. The path is the whole of the honest answer.
    ref_file: []const u8 = "{path}",

    /// A line in a file that has no hunks at all: one opened with `<Space>d`
    /// and read rather than reviewed. There is no `#id` because nothing
    /// changed in it, and inventing one would claim otherwise - but the line
    /// is real and is the whole point of pointing at it.
    ref_file_line: []const u8 = "{path}:{line}",
    ref_file_range: []const u8 = "{path}:{start}-{end}",
    ref_file_span: []const u8 = "{path}:{line} `{span}`",

    /// Handing over a whole review: the file that was written, and how many
    /// remarks are in it.
    ///
    /// The one sentence the reader sends most and at the moment that matters
    /// most, and for a long time the only one they could not change - it was
    /// a `bufPrint` in `submitReview` while every smaller thing the tool says
    /// was already data. `{s}` is the plural, empty for one comment, because
    /// a template cannot branch and "1 comments" is the kind of detail that
    /// makes a tool look unfinished.
    submit_review: []const u8 = "review ready: {path} ({count} comment{s})",

    /// The ask presets. `{ref}` is whichever of the above
    /// the cursor produced.
    ask_why: []const u8 = "{ref} - why this approach?",
    ask_revert: []const u8 = "{ref} - revert this, keep the rest",
    ask_test: []const u8 = "{ref} - add a test covering this",
    ask_explain: []const u8 = "{ref} - explain what this does",
};

pub const default: Table = .{};

pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

/// Expands `{name}` from `vars`, appending to `out`.
///
/// An unrecognised placeholder is emitted verbatim rather than dropped. A
/// user who writes `{lines}` where the table offers `{line}` should see their
/// typo in the message they just sent, not a silently shorter one - the same
/// rule the config loader follows for a key it does not know.
/// There is no escape syntax: a `{` with no closing brace, or one wrapping
/// something that is not a name, is literal text and stays literal.
pub fn render(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tmpl: []const u8,
    vars: []const Var,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < tmpl.len) {
        const open = std.mem.indexOfScalarPos(u8, tmpl, i, '{') orelse {
            try out.appendSlice(gpa, tmpl[i..]);
            return;
        };
        try out.appendSlice(gpa, tmpl[i..open]);

        const close = std.mem.indexOfScalarPos(u8, tmpl, open + 1, '}') orelse {
            try out.appendSlice(gpa, tmpl[open..]);
            return;
        };
        const name = tmpl[open + 1 .. close];
        try out.appendSlice(gpa, lookup(vars, name) orelse tmpl[open .. close + 1]);
        i = close + 1;
    }
}

fn lookup(vars: []const Var, name: []const u8) ?[]const u8 {
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, name)) return v.value;
    }
    return null;
}

const testing = std.testing;

fn expand(tmpl: []const u8, vars: []const Var) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try render(testing.allocator, &out, tmpl, vars);
    return out.toOwnedSlice(testing.allocator);
}

test "the review handover is a template like everything else" {
    const got = try expand(default.submit_review, &.{
        .{ .name = "path", .value = ".lgtm/review-3.md" },
        .{ .name = "count", .value = "7" },
        .{ .name = "s", .value = "s" },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("review ready: .lgtm/review-3.md (7 comments)", got);

    // One comment, and the plural is a variable rather than a branch: a
    // template language with an `if` in it is a template language.
    const one = try expand(default.submit_review, &.{
        .{ .name = "path", .value = ".lgtm/review-1.md" },
        .{ .name = "count", .value = "1" },
        .{ .name = "s", .value = "" },
    });
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("review ready: .lgtm/review-1.md (1 comment)", one);
}

test "a reference expands from its parts" {
    const got = try expand(default.ref_single, &.{
        .{ .name = "change_id", .value = "3" },
        .{ .name = "path", .value = "src/auth.rs" },
        .{ .name = "line", .value = "47" },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("#3 src/auth.rs:47", got);
}

test "a range template takes start and end" {
    const got = try expand(default.ref_range, &.{
        .{ .name = "change_id", .value = "3" },
        .{ .name = "path", .value = "src/auth.rs" },
        .{ .name = "start", .value = "47" },
        .{ .name = "end", .value = "52" },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("#3 src/auth.rs:47-52", got);
}

test "an ask preset wraps a finished reference" {
    const got = try expand(default.ask_why, &.{.{ .name = "ref", .value = "#3 src/auth.rs:47" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("#3 src/auth.rs:47 - why this approach?", got);
}

test "an unknown placeholder survives as itself" {
    // Dropping it would send a message with a hole in it and say nothing.
    const got = try expand("{path}:{lines}", &.{.{ .name = "path", .value = "a.zig" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a.zig:{lines}", got);
}

test "an unclosed brace is literal text" {
    const got = try expand("100% {path", &.{.{ .name = "path", .value = "a.zig" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("100% {path", got);
}

test "a template with no placeholders is copied through" {
    const got = try expand("look at this", &.{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("look at this", got);

    const empty = try expand("", &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "the same placeholder can appear twice" {
    const got = try expand("{path} -> {path}", &.{.{ .name = "path", .value = "a.zig" }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a.zig -> a.zig", got);
}

test "no default template contains a newline" {
    // Hard rule 1 is enforced in bridge.zig, but a default that could never
    // pass it would be a bug shipped rather than caught at the boundary.
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        const s = @field(default, f.name);
        try testing.expect(std.mem.indexOfScalar(u8, s, '\n') == null);
        try testing.expect(std.mem.indexOfScalar(u8, s, '\r') == null);
    }
}
