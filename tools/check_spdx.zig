// SPDX-License-Identifier: Apache-2.0
//
// Build-time check, not part of the application module graph, so the io/
// quarantine rule does not apply here. Walks the given roots and fails if any
// .zig file lacks the licence header on its first line.

const std = @import("std");

const expected = "// SPDX-License-Identifier: Apache-2.0";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var missing: usize = 0;
    var checked: usize = 0;

    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |root| {
        if (std.mem.endsWith(u8, root, ".zig")) {
            try checkFile(io, gpa, root, &missing, &checked);
            continue;
        }
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            std.debug.print("check_spdx: cannot open {s}: {t}\n", .{ root, err });
            return 1;
        };
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const full = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(full);
            try checkFile(io, gpa, full, &missing, &checked);
        }
    }

    if (missing > 0) {
        std.debug.print("check_spdx: {d} of {d} files missing '{s}'\n", .{ missing, checked, expected });
        return 1;
    }
    return 0;
}

fn checkFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, missing: *usize, checked: *usize) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("check_spdx: cannot read {s}: {t}\n", .{ path, err });
        missing.* += 1;
        return;
    };
    defer gpa.free(bytes);

    checked.* += 1;
    const eol = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first = std.mem.trimEnd(u8, bytes[0..eol], "\r");
    if (!std.mem.eql(u8, first, expected)) {
        std.debug.print("check_spdx: {s}\n  want: {s}\n  got:  {s}\n", .{ path, expected, first });
        missing.* += 1;
    }
}
