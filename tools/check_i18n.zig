// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const i18n = @import("i18n");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var literals: std.StringHashMapUnmanaged(void) = .empty;
    defer literals.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var args = init.minimal.args.iterate();
    _ = args.next();
    const root = args.next() orelse {
        std.debug.print("check_i18n: usage: check-i18n <src>\n", .{});
        return 1;
    };
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        std.debug.print("check_i18n: cannot open {s}: {t}\n", .{ root, err });
        return 1;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "i18n")) continue;
        const bytes = try dir.readFileAllocOptions(io, entry.path, arena.allocator(), .limited(16 << 20), .of(u8), 0);
        try collect(arena.allocator(), gpa, bytes, &literals);
    }

    var failed: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    inline for (.{.{ "ja", i18n.ja_entries }}) |cat| {
        for (cat[1]) |e| {
            if (!literals.contains(e[0])) {
                std.debug.print("check_i18n: {s}: no source string \"{s}\"\n", .{ cat[0], e[0] });
                failed += 1;
            }
            if ((try seen.getOrPut(gpa, e[0])).found_existing) {
                std.debug.print("check_i18n: {s}: \"{s}\" is listed twice\n", .{ cat[0], e[0] });
                failed += 1;
            }
            if (!hasWords(e[0])) {
                std.debug.print("check_i18n: {s}: \"{s}\" has no words outside its placeholders, so it would translate every call site shaped like it\n", .{ cat[0], e[0] });
                failed += 1;
            }
            if (e[1].len == 0) {
                std.debug.print("check_i18n: {s}: \"{s}\" translates to nothing\n", .{ cat[0], e[0] });
                failed += 1;
            }
        }
        seen.clearRetainingCapacity();
    }
    return if (failed == 0) 0 else 1;
}

fn hasWords(key: []const u8) bool {
    var depth: usize = 0;
    for (key) |c| switch (c) {
        '{' => depth += 1,
        '}' => depth -|= 1,
        'a'...'z', 'A'...'Z' => if (depth == 0) return true,
        else => {},
    };
    return false;
}

fn collect(arena: std.mem.Allocator, gpa: std.mem.Allocator, src: [:0]const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var tok: std.zig.Tokenizer = .init(src);
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .eof => return,
            .string_literal => {
                const text = std.zig.string_literal.parseAlloc(arena, src[t.loc.start..t.loc.end]) catch continue;
                try out.put(gpa, text, {});
            },
            else => {},
        }
    }
}
