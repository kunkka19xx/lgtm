// SPDX-License-Identifier: Apache-2.0
//
// How `lgtm serve` finds the agents `lgtm agent` runs: a socket each, in a directory only this user can enter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../io/fs.zig");
const net = @import("../io/net.zig");
const Host = @import("host.zig").Host;

const prefix = "agent-";
const suffix = ".sock";
const max_reply = 1 << 20;

/// `$XDG_RUNTIME_DIR`, else `$TMPDIR`, which macOS makes per-user, else `/tmp`.
pub fn dir(environ: *const std.process.Environ.Map, buf: []u8) []const u8 {
    const base = for ([_][]const u8{ "XDG_RUNTIME_DIR", "TMPDIR" }) |key| {
        if (environ.get(key)) |d| if (d.len > 0) break d;
    } else "/tmp";
    const user = environ.get("USER") orelse "user";
    return std.fmt.bufPrint(buf, "{s}/lgtm-{s}", .{ std.mem.trimEnd(u8, base, "/"), user }) catch "/tmp/lgtm";
}

const Request = struct { op: []const u8, text: []const u8 = "" };
const Reply = struct { ok: bool = false, name: []const u8 = "", dir: []const u8 = "", text: []const u8 = "" };

/// The agent's end: answers `lgtm serve` until the process exits. Returns the socket's path, to remove on exit.
pub fn listen(host: *Host, io: Io, sock_dir: []const u8, name: []const u8, cwd: []const u8, buf: []u8) ![]const u8 {
    try fs.privateDir(io, sock_dir);
    const path = try std.fmt.bufPrint(buf, "{s}/" ++ prefix ++ "{d}" ++ suffix, .{ sock_dir, std.posix.system.getpid() });
    fs.deleteFile(io, path);
    const server = try net.listenUnix(io, path);
    const t = try std.Thread.spawn(.{}, accept, .{ host, server, name, cwd });
    t.detach();
    return path;
}

fn accept(host: *Host, server: net.Server, name: []const u8, cwd: []const u8) void {
    var s = server;
    while (true) {
        const conn = s.accept(host.io) catch continue;
        answer(host, conn, name, cwd);
        conn.close(host.io);
    }
}

fn answer(host: *Host, conn: net.Conn, name: []const u8, cwd: []const u8) void {
    var a: std.heap.ArenaAllocator = .init(host.gpa);
    defer a.deinit();
    const arena = a.allocator();
    var rbuf: [64 << 10]u8 = undefined;
    var r = conn.reader(host.io, &rbuf);
    const line = (r.interface.takeDelimiter('\n') catch return) orelse return;
    const req = std.json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch return;
    const reply: Reply = if (std.mem.eql(u8, req.op, "info"))
        .{ .ok = host.alive(), .name = name, .dir = cwd }
    else if (std.mem.eql(u8, req.op, "read"))
        .{ .ok = host.alive(), .text = host.text(arena) catch return }
    else if (std.mem.eql(u8, req.op, "write"))
        .{ .ok = if (host.write(req.text)) |_| true else |_| false }
    else if (std.mem.eql(u8, req.op, "announce")) blk: {
        host.announce(req.text);
        break :blk .{ .ok = true };
    } else return;
    var wbuf: [16 << 10]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    std.json.Stringify.value(reply, .{}, &w.interface) catch return;
    w.interface.writeByte('\n') catch return;
    w.interface.flush() catch {};
}

pub const Agent = struct { pid: []const u8, path: []const u8, name: []const u8, dir: []const u8 };

/// Every live agent; a socket nobody answers on is left over from a crash and removed.
pub fn list(gpa: Allocator, arena: Allocator, io: Io, sock_dir: []const u8) Allocator.Error![]Agent {
    var out: std.ArrayList(Agent) = .empty;
    const names = fs.listDir(io, gpa, sock_dir) catch return out.toOwnedSlice(arena);
    defer fs.freeNames(gpa, names);
    for (names) |n| {
        if (!std.mem.startsWith(u8, n, prefix) or !std.mem.endsWith(u8, n, suffix)) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sock_dir, n });
        const reply = ask(arena, io, path, .{ .op = "info" }) catch |err| {
            if (err == error.Refused) fs.deleteFile(io, path);
            continue;
        };
        if (!reply.ok) continue;
        try out.append(arena, .{ .pid = try arena.dupe(u8, n[prefix.len .. n.len - suffix.len]), .path = path, .name = reply.name, .dir = reply.dir });
    }
    return out.toOwnedSlice(arena);
}

pub fn read(arena: Allocator, io: Io, path: []const u8) error{ PaneGone, OutOfMemory }![]const u8 {
    const reply = ask(arena, io, path, .{ .op = "read" }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.PaneGone;
    return if (reply.ok) reply.text else error.PaneGone;
}

pub fn write(arena: Allocator, io: Io, path: []const u8, bytes: []const u8) bool {
    const reply = ask(arena, io, path, .{ .op = "write", .text = bytes }) catch return false;
    return reply.ok;
}

pub fn announce(arena: Allocator, io: Io, path: []const u8, device: []const u8) void {
    _ = ask(arena, io, path, .{ .op = "announce", .text = device }) catch {};
}

fn ask(arena: Allocator, io: Io, path: []const u8, req: Request) !Reply {
    const conn = net.connectUnix(io, path) catch return error.Refused;
    defer conn.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try std.json.Stringify.value(req, .{}, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
    const rbuf = try arena.alloc(u8, max_reply);
    var r = conn.reader(io, rbuf);
    const line = try r.interface.takeDelimiter('\n') orelse return error.Closed;
    return std.json.parseFromSliceLeaky(Reply, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

const testing = std.testing;

test "the socket directory is per user, runtime dir first" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    try env.put("USER", "me");
    try testing.expectEqualStrings("/tmp/lgtm-me", dir(&env, &buf));
    try env.put("TMPDIR", "/var/folders/x/T/");
    try testing.expectEqualStrings("/var/folders/x/T/lgtm-me", dir(&env, &buf));
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try testing.expectEqualStrings("/run/user/1000/lgtm-me", dir(&env, &buf));
}
