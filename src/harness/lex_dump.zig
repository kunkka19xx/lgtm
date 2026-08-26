// SPDX-License-Identifier: Apache-2.0
//
// Points the lexer at a file and prints what it made of it, colourised, plus
// the timings that decide where the enclosing-function scan should run
// (ARCHITECTURE.md open question 5). `zig build lex -- <file> [line]`.
//
// This is to the lexer what `zig build diff` is to the parser: the cheap way
// to find out that a language definition is wrong about a real file, rather
// than only about the fixtures someone thought to write.

const std = @import("std");
const lgtm = @import("lgtm");
const lexer = lgtm.lexer;
const highlight = lgtm.highlight;

const preview_lines = 40;
/// Enough repetitions to reach the 5k-line file the open question names.
const scale_target_lines = 5000;

fn colour(kind: lexer.Kind) []const u8 {
    return switch (kind) {
        .text => "\x1b[0m",
        .comment => "\x1b[38;5;245m",
        .string => "\x1b[38;5;114m",
        .number => "\x1b[38;5;209m",
        .keyword => "\x1b[38;5;176m",
        .type_name => "\x1b[38;5;180m",
        .fn_name => "\x1b[38;5;75m",
        .punct => "\x1b[38;5;244m",
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [64 << 10]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse {
        try w.writeAll("usage: zig build lex -- <file> [line]\n");
        try w.flush();
        return 2;
    };
    const query_line: ?u32 = if (args.next()) |s| std.fmt.parseInt(u32, s, 10) catch null else null;

    const text = lgtm.fs.readFile(io, gpa, path, 8 << 20) catch |err| {
        try w.print("cannot read {s}: {t}\n", .{ path, err });
        try w.flush();
        return 1;
    };
    defer gpa.free(text);

    var lines: u32 = 0;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    if (text.len > 0 and text[text.len - 1] != '\n') lines += 1;

    const hl = highlight.Highlighter.choose(path, text.len, lines);
    const lang = switch (hl) {
        .lexer => |lx| lx.def.name,
        .tree_sitter => "tree-sitter",
        .plain => "plain (no lexer, or over the size guard)",
    };

    var st_start = std.Io.Timestamp.now(io, .awake);
    var st = try hl.structure(gpa, text);
    defer st.deinit(gpa);
    var st_ns: u64 = @intCast(@max(0, st_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));

    var runs: std.ArrayList(lexer.Run) = .empty;
    defer runs.deinit(gpa);
    const lex_start = std.Io.Timestamp.now(io, .awake);
    _ = try hl.lex(gpa, text, 0, text.len, .{}, &runs);
    const lex_ns: u64 = @intCast(@max(0, lex_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));

    try w.print("{s}: {s}, {d} lines, {d} bytes\n", .{ path, lang, lines, text.len });
    try w.print("{d} checkpoints, {d} function spans, {d} runs\n", .{
        st.checkpoints.len, st.fns.len, runs.items.len,
    });
    try w.print("structure {d:.3} ms, full lex {d:.3} ms\n", .{
        @as(f64, @floatFromInt(st_ns)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(lex_ns)) / std.time.ns_per_ms,
    });

    // Scale to the file size the open question is about, so the answer is
    // measured rather than extrapolated from a 100-line file.
    if (lines > 0 and lines < scale_target_lines) {
        const reps = (scale_target_lines / lines) + 1;
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(gpa);
        for (0..reps) |_| try big.appendSlice(gpa, text);

        st_start = std.Io.Timestamp.now(io, .awake);
        var big_st = try hl.structure(gpa, big.items);
        defer big_st.deinit(gpa);
        st_ns = @intCast(@max(0, st_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));

        var big_runs: std.ArrayList(lexer.Run) = .empty;
        defer big_runs.deinit(gpa);
        const big_lex_start = std.Io.Timestamp.now(io, .awake);
        _ = try hl.lex(gpa, big.items, 0, big.items.len, .{}, &big_runs);
        const big_lex_ns: u64 = @intCast(@max(0, big_lex_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));

        try w.print("scaled: {d} lines, structure {d:.3} ms, full lex {d:.3} ms\n", .{
            big_st.lines,
            @as(f64, @floatFromInt(st_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(big_lex_ns)) / std.time.ns_per_ms,
        });
        try w.writeAll("        (budgets: re-diff 100 ms, keystroke to frame 8 ms)\n");
    }

    if (query_line) |q| {
        if (st.enclosingFn(q)) |f| {
            try w.print("\nline {d} is inside {s} (lines {d}-{d})\n", .{ q, f.name, f.start_line, f.end_line });
        } else {
            try w.print("\nline {d} is not inside any function\n", .{q});
        }
    } else {
        // Indent-mode languages close spans on columns, not braces, so
        // printing a depth of 0 for every Python function would be noise.
        const by_indent = switch (hl) {
            .lexer => |lx| lx.def.blocks == .indent,
            else => false,
        };
        try w.writeAll("\nfunction spans\n");
        for (st.fns) |f| {
            if (by_indent) {
                try w.print("  {d: >5}-{d: <5} col {d: <4} {s}\n", .{ f.start_line, f.end_line, f.indent, f.name });
            } else {
                try w.print("  {d: >5}-{d: <5} depth {d: <2} {s}\n", .{ f.start_line, f.end_line, f.depth, f.name });
            }
        }
    }

    try w.print("\nfirst {d} lines\n", .{preview_lines});
    var line: u32 = 0;
    for (runs.items) |r| {
        if (line >= preview_lines) break;
        const bytes = text[r.start..r.end()];
        const nl = bytes.len > 0 and bytes[bytes.len - 1] == '\n';
        try w.print("{s}{s}\x1b[0m", .{ colour(r.kind), if (nl) bytes[0 .. bytes.len - 1] else bytes });
        if (nl) {
            try w.writeAll("\n");
            line += 1;
        }
    }

    try w.flush();
    return 0;
}
