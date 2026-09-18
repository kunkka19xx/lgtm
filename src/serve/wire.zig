// SPDX-License-Identifier: Apache-2.0
//
// The `lgtm serve` protocol: one JSON object per line, tagged by `type`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Zero while unstable; a client speaking any other version is refused.
pub const version: u32 = 0;

/// The longest line either side may send. Bounds the reader's buffer.
pub const max_line = 64 << 10;

pub const Inbound = union(enum) {
    hello: struct { token: []const u8, version: u32, device: []const u8 },
    /// `submit` presses Enter after the text, and only a person's tap sets it.
    send: struct { text: []const u8, submit: bool },
    ping,
};

pub const ParseError = error{ Malformed, UnknownType, MissingField } || Allocator.Error;

const Raw = struct {
    type: []const u8,
    token: ?[]const u8 = null,
    version: ?u32 = null,
    device: ?[]const u8 = null,
    text: ?[]const u8 = null,
    submit: bool = false,
};

/// The strings point into `arena`.
pub fn parse(arena: Allocator, line: []const u8) ParseError!Inbound {
    const raw = std.json.parseFromSliceLeaky(Raw, arena, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    const kind = std.meta.stringToEnum(std.meta.Tag(Inbound), raw.type) orelse return error.UnknownType;
    return switch (kind) {
        .hello => .{ .hello = .{
            .token = raw.token orelse return error.MissingField,
            .version = raw.version orelse return error.MissingField,
            .device = raw.device orelse "",
        } },
        .send => .{ .send = .{
            .text = raw.text orelse return error.MissingField,
            .submit = raw.submit,
        } },
        .ping => .ping,
    };
}

pub const Agent = struct {
    backend: []const u8,
    pane: []const u8,
    read: bool,
    submit: bool,
    stream: bool,
    /// Whether `status` messages will come: what the agent is doing, from a
    /// backend that knows.
    status: bool = false,
    /// Why `read` or `submit` is false, in words a person can act on.
    why: []const u8 = "",
};

pub const AgentState = enum { unknown, working, blocked, idle, done };

pub const Outbound = union(enum) {
    session: struct { version: u32, repo: []const u8, agent: Agent },
    screen: struct { pane: []const u8, rows: []const []const u8 },
    sent: struct { ok: bool, submitted: bool, why: []const u8 = "" },
    /// `blocked` is the agent waiting on a person.
    status: struct { state: AgentState, agent: []const u8 },
    @"error": struct { code: Code, message: []const u8 },
    pong,
};

pub const Code = enum { malformed, unknown_type, missing_field, version, token, no_hello, too_long, pane_gone };

/// Field order is declaration order, so a message always encodes to the same bytes.
pub fn write(w: *Writer, msg: Outbound) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(msg));
    switch (msg) {
        .pong => {},
        inline else => |payload| {
            inline for (@typeInfo(@TypeOf(payload)).@"struct".fields) |f| {
                try s.objectField(f.name);
                try s.write(@field(payload, f.name));
            }
        },
    }
    try s.endObject();
    try w.writeByte('\n');
}

const testing = std.testing;

/// Every message the daemon can send, as the recorded fixture spells it.
const outbound_fixture = [_]Outbound{
    .{ .session = .{ .version = 0, .repo = "lgtm", .agent = .{
        .backend = "tmux",
        .pane = "%3",
        .read = true,
        .submit = true,
        .stream = false,
    } } },
    .{ .session = .{ .version = 0, .repo = "lgtm", .agent = .{
        .backend = "ghostty",
        .pane = "",
        .read = false,
        .submit = false,
        .stream = false,
        .why = "ghostty cannot be read; run the agent inside tmux",
    } } },
    .{ .session = .{ .version = 0, .repo = "lgtm", .agent = .{
        .backend = "herdr",
        .pane = "w1:p1",
        .read = true,
        .submit = true,
        .stream = false,
        .status = true,
    } } },
    .{ .screen = .{ .pane = "%3", .rows = &.{ "> fix the retry backoff", "", "● Reading server.zig", "  \"quoted\" \\ tab\there" } } },
    .{ .sent = .{ .ok = true, .submitted = true } },
    .{ .sent = .{ .ok = false, .submitted = false, .why = "pane is gone" } },
    .{ .status = .{ .state = .blocked, .agent = "claude" } },
    .{ .@"error" = .{ .code = .token, .message = "wrong token" } },
    .pong,
};

test "every outbound message encodes to the recorded fixture" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (outbound_fixture) |msg| try write(&out.writer, msg);
    try testing.expectEqualStrings(@embedFile("wire_outbound"), out.written());
}

test "every inbound message in the fixture parses" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var lines = std.mem.tokenizeScalar(u8, @embedFile("wire_inbound"), '\n');

    const hello = try parse(a.allocator(), lines.next().?);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", hello.hello.token);
    try testing.expectEqual(@as(u32, 0), hello.hello.version);
    try testing.expectEqualStrings("iPhone", hello.hello.device);

    const send = try parse(a.allocator(), lines.next().?);
    try testing.expectEqualStrings("run the tests again", send.send.text);
    try testing.expect(send.send.submit);

    const insert = try parse(a.allocator(), lines.next().?);
    try testing.expect(!insert.send.submit);

    try testing.expect(try parse(a.allocator(), lines.next().?) == .ping);
    try testing.expect(lines.next() == null);
}

test "a message that is not one is refused, never guessed at" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try testing.expectError(error.Malformed, parse(arena, "not json"));
    try testing.expectError(error.Malformed, parse(arena, "{\"text\":\"no type\"}"));
    try testing.expectError(error.UnknownType, parse(arena, "{\"type\":\"exec\",\"text\":\"rm -rf /\"}"));
    try testing.expectError(error.MissingField, parse(arena, "{\"type\":\"send\"}"));
    try testing.expectError(error.MissingField, parse(arena, "{\"type\":\"hello\",\"version\":0}"));
    // An absent submit is an insert: Enter is only ever pressed when asked for.
    try testing.expect(!(try parse(arena, "{\"type\":\"send\",\"text\":\"x\"}")).send.submit);
    // A newer client's extra fields do not stop an older daemon reading it.
    _ = try parse(arena, "{\"type\":\"ping\",\"later\":true}");
}
