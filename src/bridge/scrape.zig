// SPDX-License-Identifier: Apache-2.0
//
// The shape every backend that reads a pane list has: build an argv, run it,
// scrape the output. Four of them had a copy each, differing only in which
// two functions they named and how much output they would take.
//
// Failure is an empty list, never an error: a multiplexer that is not running,
// or one whose remote control is off, is a reason to infer nothing rather than
// a reason to stop.

const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("../io/proc.zig");

pub fn ids(
    comptime argv: fn (Allocator) Allocator.Error![]const []const u8,
    comptime parse: fn (Allocator, []const u8, *std.ArrayList([]const u8)) Allocator.Error!void,
    comptime max_output: usize,
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const args = argv(arena) catch return out.toOwnedSlice(arena);
    const res = proc.run(gpa, io, args, max_output) catch return out.toOwnedSlice(arena);
    defer res.deinit(gpa);
    if (res.exit_code != 0) return out.toOwnedSlice(arena);
    try parse(arena, res.stdout, &out);
    return out.toOwnedSlice(arena);
}

pub const RunError = error{ PaneGone, Failed } || Allocator.Error;

/// A backend command's output, or how it failed. `gone` recognises the
/// backend's own words for a pane that closed.
pub fn read(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    argv: []const []const u8,
    comptime gone: fn ([]const u8) bool,
) RunError![]const u8 {
    const res = proc.run(gpa, io, argv, read_output_max) catch return error.Failed;
    defer res.deinit(gpa);
    if (res.exit_code != 0) return if (gone(res.stderr)) error.PaneGone else error.Failed;
    return trimBlankTail(try arena.dupe(u8, res.stdout));
}

const read_output_max = 1 << 20;

pub fn trimBlankTail(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trimEnd(u8, text[line_start .. end - 1], " \t\r");
        if (line.len > 0) break;
        end = line_start;
    }
    return text[0..end];
}

const testing = std.testing;

test "a screen loses its blank tail and keeps everything above it" {
    try testing.expectEqualStrings("> hi\nok\n", trimBlankTail("> hi\nok\n  \n\n\t\n"));
    try testing.expectEqualStrings("", trimBlankTail("\n\n"));
    try testing.expectEqualStrings("no newline", trimBlankTail("no newline"));
}
