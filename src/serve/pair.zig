// SPDX-License-Identifier: Apache-2.0
//
// The pairing token, kept in `.lgtm/` so a paired phone survives a restart,
// and the URL a phone scans to learn it.

const std = @import("std");
const fs = @import("../io/fs.zig");

pub const token_path = fs.state_dir ++ "/serve-token";

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

/// The saved token, or a new one saved owner-only. `fresh` replaces it, which
/// unpairs every device.
pub fn loadOrCreate(io: std.Io, gpa: std.mem.Allocator, fresh: bool) std.Io.RandomSecureError!Token {
    if (!fresh) {
        if (fs.readFile(io, gpa, token_path, 128)) |bytes| {
            defer gpa.free(bytes);
            if (Token.parse(std.mem.trim(u8, bytes, " \t\r\n"))) |t| return t;
        } else |_| {}
    }
    const t = try Token.generate(io);
    fs.writeSecretStateFile(io, token_path, &t.hex) catch {};
    return t;
}

/// `lgtm://pair?h=...&p=...&t=...&n=...`. One-letter keys keep the QR code a
/// size smaller, which is the difference on a phone held to a terminal.
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

test "the pairing url escapes the repository name and nothing else" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeUrl(&out.writer, "100.64.0.1", 7777, &Token.parse("0123456789abcdef0123456789abcdef").?, "my repo&co");
    try testing.expectEqualStrings(
        "lgtm://pair?h=100.64.0.1&p=7777&t=0123456789abcdef0123456789abcdef&n=my%20repo%26co",
        out.written(),
    );
}
