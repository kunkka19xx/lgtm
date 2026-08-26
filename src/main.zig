// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

pub const fs = @import("io/fs.zig");
pub const proc = @import("io/proc.zig");
pub const tty = @import("io/tty.zig");
pub const metrics = @import("io/metrics.zig");
pub const buffer = @import("text/buffer.zig");
pub const edit = @import("text/edit.zig");
pub const event = @import("core/event.zig");
pub const anchor = @import("core/anchor.zig");
pub const smoke = @import("ui/smoke.zig");

const usage =
    \\lgtm - read what your agent wrote
    \\
    \\usage: lgtm [options]
    \\
    \\  --smoke     render one sample frame at 80 columns and exit
    \\  --profile   print timing spans on exit (requires -Dprofile build)
    \\  --version   print version and exit
    \\  -h, --help  print this help and exit
    \\
;

const version = "0.0.0-dev";
const smoke_hold_ms = 2500;

/// Zig 0.16 hands main the process allocator, arena, and Io implementation.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    metrics.init(io);

    var out = try tty.Stdout.init(gpa, io, 64 << 10);
    defer out.deinit();
    const w = out.writer();

    var want_profile = false;
    var want_smoke = false;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try w.writeAll(usage);
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try w.print("lgtm {s}\n", .{version});
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            want_profile = true;
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            want_smoke = true;
        } else {
            try w.print("lgtm: unknown option '{s}'\n\n{s}", .{ arg, usage });
            try w.flush();
            return;
        }
    }

    if (want_smoke) {
        try w.flush();
        try smoke.run(gpa, io, init.environ_map, smoke_hold_ms);
    } else {
        try w.print("lgtm {s}: scaffold. No diff view yet, see docs/PLAN.md.\n", .{version});
    }

    if (want_profile) try metrics.report(w);
    try w.flush();
}

test {
    _ = fs;
    _ = proc;
    _ = tty;
    _ = metrics;
    _ = buffer;
    _ = edit;
    _ = event;
    _ = anchor;
    _ = smoke;
}
