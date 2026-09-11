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
