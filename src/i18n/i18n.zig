// SPDX-License-Identifier: Apache-2.0
//
// English is the key. A translation omits an argument only as `{[k]-}`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Lang = enum { en, ja };

pub var lang: Lang = .en;

pub const Entry = struct { []const u8, []const u8 };

pub const Map = std.StaticStringMap([]const u8);

pub fn catalog(comptime l: Lang) ?Map {
    return switch (l) {
        .en => null,
        .ja => ja_map,
    };
}

pub const ja_entries = @import("ja.zig").entries;
const ja_map = Map.initComptime(ja_entries);

const max_args = 32;

const Plan = struct {
    fmt: []const u8,
    keep: []const usize,
    whole: bool,
};

fn plan(comptime l: Lang, comptime en: []const u8, comptime n: usize) Plan {
    const identity: Plan = .{ .fmt = en, .keep = &.{}, .whole = true };
    const map = catalog(l) orelse return identity;
    const to = map.get(en) orelse return identity;
    return comptime rewrite(en, to, n);
}

const Use = enum { unused, used, dropped };

fn rewrite(comptime en: []const u8, comptime to: []const u8, comptime n: usize) Plan {
    if (n > max_args) @compileError("too many arguments in '" ++ en ++ "'");
    @setEvalBranchQuota(64 * to.len + 4096);
    var use: [max_args]Use = @splat(.unused);
    scan(en, to, n, &use, null);

    var keep: []const usize = &.{};
    var new: [max_args]usize = undefined;
    for (0..n) |k| switch (use[k]) {
        .unused => @compileError(std.fmt.comptimePrint(
            "translation of '{s}' does not show argument {d}; write {{[{d}]-}} if that is deliberate",
            .{ en, k, k },
        )),
        .used => {
            new[k] = keep.len;
            keep = keep ++ .{k};
        },
        .dropped => {},
    };

    var out: []const u8 = "";
    scan(en, to, n, &use, .{ .out = &out, .new = &new });
    return .{ .fmt = out, .keep = keep, .whole = keep.len == n };
}

const Emit = struct { out: *[]const u8, new: *const [max_args]usize };

fn scan(comptime en: []const u8, comptime to: []const u8, comptime n: usize, use: *[max_args]Use, comptime emit: ?Emit) void {
    var next: usize = 0;
    var i: usize = 0;
    var lit: usize = 0;
    while (i < to.len) {
        const c = to[i];
        if ((c == '{' or c == '}') and i + 1 < to.len and to[i + 1] == c) {
            i += 2;
            continue;
        }
        if (c == '}') @compileError("missing opening { in translation of '" ++ en ++ "'");
        if (c != '{') {
            i += 1;
            continue;
        }
        if (emit) |e| e.out.* = e.out.* ++ to[lit..i];
        const close = std.mem.indexOfScalarPos(u8, to, i, '}') orelse
            @compileError("missing closing } in translation of '" ++ en ++ "'");
        const body: []const u8 = to[i + 1 .. close];
        var idx: usize = undefined;
        var rest: []const u8 = body;
        if (body.len > 0 and body[0] == '[') {
            const rb = std.mem.indexOfScalar(u8, body, ']') orelse
                @compileError("unclosed [ in translation of '" ++ en ++ "'");
            idx = std.fmt.parseInt(usize, body[1..rb], 10) catch
                @compileError("translations number their arguments, not name them: '" ++ en ++ "'");
            rest = body[rb + 1 ..];
        } else {
            idx = next;
            next += 1;
        }
        if (idx >= n) @compileError(std.fmt.comptimePrint(
            "translation of '{s}' refers to argument {d}, and there are {d}",
            .{ en, idx, n },
        ));
        if (std.mem.eql(u8, rest, "-")) {
            if (emit == null and use[idx] == .unused) use[idx] = .dropped;
        } else if (emit) |e| {
            e.out.* = e.out.* ++ std.fmt.comptimePrint("{{[{d}]", .{e.new[idx]}) ++ rest ++ "}";
        } else {
            use[idx] = .used;
        }
        i = close + 1;
        lit = i;
    }
    if (emit) |e| e.out.* = e.out.* ++ to[lit..];
}

fn Picked(comptime Args: type, comptime keep: []const usize) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var types: [keep.len]type = undefined;
    for (keep, 0..) |k, j| types[j] = fields[k].type;
    return @Tuple(&types);
}

fn argCount(comptime Args: type) usize {
    return @typeInfo(Args).@"struct".fields.len;
}

fn pick(args: anytype, comptime p: Plan) if (p.whole) @TypeOf(args) else Picked(@TypeOf(args), p.keep) {
    if (p.whole) return args;
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var out: Picked(@TypeOf(args), p.keep) = undefined;
    inline for (p.keep, 0..) |k, j| out[j] = @field(args, fields[k].name);
    return out;
}

pub fn bufPrint(buf: []u8, comptime en: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    return switch (lang) {
        inline else => |l| {
            const p = comptime plan(l, en, argCount(@TypeOf(args)));
            return std.fmt.bufPrint(buf, p.fmt, pick(args, p));
        },
    };
}

pub fn allocPrint(gpa: Allocator, comptime en: []const u8, args: anytype) Allocator.Error![]u8 {
    return switch (lang) {
        inline else => |l| {
            const p = comptime plan(l, en, argCount(@TypeOf(args)));
            return std.fmt.allocPrint(gpa, p.fmt, pick(args, p));
        },
    };
}

pub fn t(comptime en: []const u8) []const u8 {
    return switch (lang) {
        inline else => |l| comptime blk: {
            const map = catalog(l) orelse break :blk en;
            break :blk map.get(en) orelse en;
        },
    };
}

pub fn word(en: []const u8) []const u8 {
    return switch (lang) {
        inline else => |l| {
            const map = comptime catalog(l);
            return if (map) |m| m.get(en) orelse en else en;
        },
    };
}

pub fn whole(buf: []u8) []u8 {
    var end = buf.len;
    var back: usize = 0;
    while (end > 0 and back < 4) : (back += 1) {
        const b = buf[end - 1];
        if (b & 0xC0 != 0x80) {
            const need = std.unicode.utf8ByteSequenceLength(b) catch 1;
            return if (need <= back + 1) buf else buf[0 .. end - 1];
        }
        end -= 1;
    }
    return buf;
}

const testing = std.testing;

test "a cut message ends on a whole character" {
    var buf = "ab\xe3\x81\x82\xe3\x81".*;
    try testing.expectEqualStrings("ab\xe3\x81\x82", whole(&buf));
    var fine = "ab\xe3\x81\x82".*;
    try testing.expectEqualStrings("ab\xe3\x81\x82", whole(&fine));
}

test "english is the key and a missing entry stays english" {
    lang = .ja;
    defer lang = .en;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("nothing here at all 3", try bufPrint(&buf, "nothing here at all {d}", .{3}));
    try testing.expectEqualStrings("not in any catalog", word("not in any catalog"));
}

test "a translation may reorder and drop what it marks" {
    const p = comptime rewrite("{d} file{s} in {s}", "{[2]s} に {[0]d} 個{[1]-}", 3);
    try testing.expectEqualStrings("{[1]s} に {[0]d} 個", p.fmt);
    try testing.expectEqual(@as(usize, 2), p.keep.len);
    try testing.expect(!p.whole);

    var buf: [64]u8 = undefined;
    const args = .{ @as(u32, 4), "s", "src" };
    const got = try std.fmt.bufPrint(&buf, p.fmt, pick(args, p));
    try testing.expectEqualStrings("src に 4 個", got);

    const r = comptime rewrite("{s} then {s}", "{[1]s} の前に {[0]s}", 2);
    try testing.expect(r.whole);
    try testing.expectEqualStrings("{[1]s} の前に {[0]s}", r.fmt);
    const b = comptime rewrite("{{{d}}}", "{{{d}}} 件", 1);
    try testing.expectEqualStrings("{{{[0]d}}} 件", b.fmt);
}

test "every catalog entry formats against its english" {
    @setEvalBranchQuota(1 << 24);
    inline for (comptime ja_entries) |e| {
        _ = comptime rewrite(e[0], e[1], countArgs(e[0]));
    }
}

fn countArgs(comptime fmt: []const u8) usize {
    @setEvalBranchQuota(16 * fmt.len + 1024);
    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '{') continue;
        if (i + 1 < fmt.len and fmt[i + 1] == '{') {
            i += 1;
            continue;
        }
        n += 1;
    }
    return n;
}
