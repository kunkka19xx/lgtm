// SPDX-License-Identifier: Apache-2.0
//
// Pseudo-terminals for `lgtm agent`: nothing above `io/` opens or sizes one.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Io = std.Io;
const File = std.Io.File;
const posix = std.posix;

pub const Size = struct { rows: u16, cols: u16 };

/// The ioctls std names on one platform and not the other, from the kernel headers.
const ctl = switch (builtin.os.tag) {
    .macos => .{ .grant = 0x20007454, .unlock = 0x20007452, .name = 0x40807453, .set_size = 0x80087467, .take = 0x20007461 },
    else => .{ .unlock = 0x40045431, .number = 0x80045430, .set_size = 0x5414, .take = 0x540E },
};

/// macOS takes the request as a signed int, Linux as unsigned.
fn ioctl(fd: posix.fd_t, request: u32, arg: usize) bool {
    const r = if (builtin.os.tag == .macos) @as(c_int, @bitCast(request)) else request;
    return posix.system.ioctl(fd, r, arg) == 0;
}

pub const Pair = struct { master: File, slave: File };

pub fn open(io: Io) !Pair {
    const master = try Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write, .allow_ctty = false });
    errdefer master.close(io);
    var name_buf: [128]u8 = undefined;
    const name = switch (builtin.os.tag) {
        .macos => blk: {
            if (!ioctl(master.handle, ctl.grant, 0) or !ioctl(master.handle, ctl.unlock, 0) or
                !ioctl(master.handle, ctl.name, @intFromPtr(&name_buf))) return error.PtyFailed;
            break :blk std.mem.sliceTo(&name_buf, 0);
        },
        .linux => blk: {
            var n: c_uint = 0;
            if (!ioctl(master.handle, ctl.unlock, @intFromPtr(&n)) or !ioctl(master.handle, ctl.number, @intFromPtr(&n))) return error.PtyFailed;
            break :blk try std.fmt.bufPrint(&name_buf, "/dev/pts/{d}", .{n});
        },
        else => return error.PtyUnsupported,
    };
    const slave = try Io.Dir.openFileAbsolute(io, name, .{ .mode = .read_write, .allow_ctty = false });
    return .{ .master = master, .slave = slave };
}

pub fn setSize(file: File, to: Size) void {
    const ws: posix.winsize = .{ .row = to.rows, .col = to.cols, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(file.handle, ctl.set_size, @intFromPtr(&ws));
}

pub fn size(fd: posix.fd_t) ?Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0 or ws.col == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

pub fn makeRaw(fd: posix.fd_t) !posix.termios {
    return vaxis.Tty.makeRaw(fd);
}

pub fn restore(fd: posix.fd_t, state: posix.termios) void {
    posix.tcsetattr(fd, .FLUSH, state) catch {};
}

/// Runs `lgtm __pty-child -- argv` on the slave, because a spawn cannot make the pty its controlling terminal.
pub fn spawn(io: Io, slave: File, argv: []const []const u8, arena: std.mem.Allocator) !std.process.Child {
    var exe_buf: [4096]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(arena, &.{ exe, child_verb, "--" });
    try full.appendSlice(arena, argv);
    return std.process.spawn(io, .{
        .argv = full.items,
        .stdin = .{ .file = slave },
        .stdout = .{ .file = slave },
        .stderr = .{ .file = slave },
    });
}

pub const child_verb = "__pty-child";

/// A new session on stdin's terminal, so `/dev/tty` and Ctrl-C are the pty's, then the command.
pub fn becomeChild(io: Io, argv: []const []const u8) noreturn {
    _ = posix.system.setsid();
    _ = ioctl(0, ctl.take, 0);
    const err = std.process.replace(io, .{ .argv = argv, .expand_arg0 = .expand });
    std.debug.print("lgtm agent: cannot run {s}: {t}\n", .{ argv[0], err });
    std.process.exit(127);
}
