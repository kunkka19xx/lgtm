// SPDX-License-Identifier: Apache-2.0
//
// The pairing token, one per machine so a paired phone survives a restart,
// and the URL a phone scans to learn it.

const std = @import("std");
const fs = @import("../io/fs.zig");

/// `$XDG_STATE_HOME/lgtm/serve-token`, else under `~/.local/state`.
pub fn tokenPath(environ: *const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (environ.get("XDG_STATE_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/lgtm/serve-token", .{d}) catch null;
    const home = environ.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/lgtm/serve-token", .{home}) catch null;
}

pub const Token = struct {
    hex: [32]u8,

    pub fn generate(io: std.Io) std.Io.RandomSecureError!Token {
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        return .{ .hex = std.fmt.bytesToHex(raw, .lower) };
    }

    pub fn parse(text: []const u8) ?Token {
        if (text.len != 32) return null;
        for (text) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return null;
        return .{ .hex = text[0..32].* };
    }

    /// Constant time, so timing leaks nothing about a guess.
    pub fn matches(self: *const Token, given: []const u8) bool {
        if (given.len != self.hex.len) return false;
        return std.crypto.timing_safe.eql([32]u8, self.hex, given[0..32].*);
    }
};

/// The saved token, or a new one saved owner-only; `fresh` replaces it, unpairing every device.
pub fn loadOrCreate(io: std.Io, gpa: std.mem.Allocator, path: []const u8, fresh: bool) std.Io.RandomSecureError!Token {
    if (!fresh) {
        if (fs.readFile(io, gpa, path, 128)) |bytes| {
            defer gpa.free(bytes);
            if (Token.parse(std.mem.trim(u8, bytes, " \t\r\n"))) |t| return t;
        } else |_| {}
    }
    const t = try Token.generate(io);
    fs.writeSecretFile(io, path, &t.hex) catch {};
    return t;
}

/// `lgtm://pair?h=...&p=...&t=...&n=...`; one-letter keys keep the QR code a size smaller.
pub fn writeUrl(w: *std.Io.Writer, host: []const u8, port: u16, token: *const Token, name: []const u8) std.Io.Writer.Error!void {
    try w.print("lgtm://pair?h={s}&p={d}&t={s}&n=", .{ host, port, &token.hex });
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~')
            try w.writeByte(c)
        else
            try w.print("%{X:0>2}", .{c});
    }
}

const testing = std.testing;

test "a token is 128 random bits as hex, only itself matches, and a saved one is read back only when it is one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const a = try Token.generate(threaded.io());
    const b = try Token.generate(threaded.io());
    try testing.expect(!std.mem.eql(u8, &a.hex, &b.hex));
    try testing.expect(Token.parse(&a.hex) != null);
    try testing.expect(a.matches(&a.hex) and !a.matches(&b.hex) and !a.matches(a.hex[0..31]) and !a.matches(""));

    for ([_][]const u8{ "0123456789ABCDEF0123456789abcdef", "0123456789abcdef", "zz23456789abcdef0123456789abcdef" }) |bad|
        try testing.expect(Token.parse(bad) == null);
}

test "the token lives in the state directory, XDG first" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    try testing.expect(tokenPath(&env, &buf) == null);
    try env.put("HOME", "/home/me");
    try testing.expectEqualStrings("/home/me/.local/state/lgtm/serve-token", tokenPath(&env, &buf).?);
    try env.put("XDG_STATE_HOME", "/state");
    try testing.expectEqualStrings("/state/lgtm/serve-token", tokenPath(&env, &buf).?);
}

test "the pairing url escapes the machine name and nothing else" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeUrl(&out.writer, "100.64.0.1", 7777, &Token.parse("0123456789abcdef0123456789abcdef").?, "my repo&co");
    try testing.expectEqualStrings(
        "lgtm://pair?h=100.64.0.1&p=7777&t=0123456789abcdef0123456789abcdef&n=my%20repo%26co",
        out.written(),
    );
}
