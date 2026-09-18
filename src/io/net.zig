// SPDX-License-Identifier: Apache-2.0
//
// Sockets only: nothing above `io/` touches `std.Io.net`.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub const Address = net.IpAddress;

pub const ParseError = error{InvalidAddress};

pub fn parseAddress(text: []const u8, port: u16) ParseError!Address {
    return Address.parse(text, port) catch error.InvalidAddress;
}

pub const Server = struct {
    inner: net.Server,

    pub fn accept(self: *Server, io: Io) !Conn {
        return .{ .stream = try self.inner.accept(io) };
    }

    pub fn deinit(self: *Server, io: Io) void {
        self.inner.deinit(io);
    }
};

pub const ListenError = error{AlreadyServing} || net.IpAddress.ListenError;

/// Reuse also sets SO_REUSEPORT, which would let a second daemon split the clients, so a live one is refused first.
pub fn listen(io: Io, addr: Address) ListenError!Server {
    if (addr.connect(io, .{ .mode = .stream })) |s| {
        s.close(io);
        return error.AlreadyServing;
    } else |_| {}
    return .{ .inner = try addr.listen(io, .{ .reuse_address = true }) };
}

/// A local socket, such as the one herdr names in `$HERDR_SOCKET_PATH`.
pub fn connectUnix(io: Io, path: []const u8) !Conn {
    const ua = try net.UnixAddress.init(path);
    return .{ .stream = try ua.connect(io) };
}

pub const Conn = struct {
    stream: net.Stream,

    pub fn reader(self: Conn, io: Io, buf: []u8) net.Stream.Reader {
        return self.stream.reader(io, buf);
    }

    pub fn writer(self: Conn, io: Io, buf: []u8) net.Stream.Writer {
        return self.stream.writer(io, buf);
    }

    /// Wakes a reader blocked in recv, which close alone does not do on macOS.
    pub fn shutdown(self: Conn, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
    }

    pub fn close(self: Conn, io: Io) void {
        self.stream.close(io);
    }
};

pub fn loopback(addr: Address) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(net.Ip6Address.loopback(0).bytes)),
    };
}

/// Loopback or Tailscale only, because a paired client can type into a shell.
pub fn private(addr: Address) bool {
    return switch (addr) {
        .ip4 => |a| loopback(addr) or
            // Tailscale's CGNAT range, 100.64.0.0/10.
            (a.bytes[0] == 100 and (a.bytes[1] & 0xc0) == 0x40),
        .ip6 => |a| loopback(addr) or
            // Tailscale's ULA prefix, fd7a:115c:a1e0::/48.
            std.mem.eql(u8, a.bytes[0..6], &.{ 0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0 }),
    };
}

const testing = std.testing;

test "only loopback and tailscale addresses may be listened on" {
    for ([_][]const u8{ "127.0.0.1", "::1", "100.64.0.1", "100.101.2.3", "100.127.255.254", "fd7a:115c:a1e0::1" }) |a|
        try testing.expect(private(try parseAddress(a, 7777)));
    for ([_][]const u8{ "0.0.0.0", "::", "192.168.1.10", "10.0.0.2", "100.63.255.255", "100.128.0.1", "8.8.8.8", "fd00::1" }) |a|
        try testing.expect(!private(try parseAddress(a, 7777)));
    try testing.expectError(error.InvalidAddress, parseAddress("localhost", 7777));
}
