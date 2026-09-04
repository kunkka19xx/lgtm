// SPDX-License-Identifier: Apache-2.0
//
// A small TOML subset, as a scanner: `[table]` headers, `key = value`,
// strings, booleans, integers, and single-line arrays of strings. No dates, no
// nested tables, no multi-line strings, no inline tables. That is everything
// lgtm's config surface needs, in a parser small enough to read in one sitting
// - and small enough to replace with a real dependency without any caller
// noticing, which is the point of it living behind this seam rather than
// inside `config.zig`.
//
// It reports faults rather than messages. What a user should be told about a
// bad line depends on what the key meant, and only `config.zig` knows that; a
// parser that wrote the sentences would either say too little ("parse error")
// or know too much about lgtm.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    list: []const []const u8,

    /// For the "wanted a string, got an integer" half of a message.
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .string => "a string",
            .boolean => "a boolean",
            .integer => "an integer",
            .list => "a list",
        };
    }
};

/// What is wrong with one line, in the parser's own terms.
pub const Fault = enum {
    /// `[` with no closing `]`.
    unterminated_table,
    /// A line that is neither a table header nor `key = value`.
    expected_assignment,
    missing_key,
    missing_value,
    /// Not a string, a number, a boolean or a list.
    unreadable_value,
    unterminated_string,
    /// A closing quote with something after it.
    trailing_text,
    bad_escape,
    unterminated_list,
    /// A list holding something that is not a string.
    list_wants_strings,
};

pub const Item = struct {
    key: []const u8,
    value: Value,
    line: u32,
};

pub const Problem = struct {
    fault: Fault,
    /// The offending text, for a message that wants to quote it: the value
    /// that could not be read, the escape that means nothing. Empty when the
    /// fault says everything.
    text: []const u8 = "",
    line: u32,
};

pub const Event = union(enum) {
    /// A `[name]` header. The caller decides whether it knows that name.
    table: struct { name: []const u8, line: u32 },
    /// A setting inside whichever table was last announced - or none, when the
    /// file opens with one, which the caller may or may not allow.
    item: Item,
    problem: Problem,
};

/// Walks a document one event at a time. Strings and lists are allocated from
/// `arena`, so an item's value outlives the parser and dies with the arena.
pub const Parser = struct {
    arena: Allocator,
    lines: std.mem.SplitIterator(u8, .scalar),
    line_no: u32 = 0,
    /// Set alongside `error.BadEscape`, which cannot carry a payload.
    bad_escape: []const u8 = "",

    pub fn init(arena: Allocator, text: []const u8) Parser {
        return .{ .arena = arena, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// The next event, or null at the end of the document. Blank lines and
    /// comments produce nothing; every other line produces exactly one event,
    /// so a caller that stops at the first problem and one that reports them
    /// all are both ordinary loops.
    pub fn next(self: *Parser) ?Event {
        while (self.lines.next()) |raw| {
            self.line_no += 1;
            const line = trim(stripComment(raw));
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line[line.len - 1] != ']') return self.fault(.unterminated_table, "");
                return .{ .table = .{ .name = trim(line[1 .. line.len - 1]), .line = self.line_no } };
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse
                return self.fault(.expected_assignment, "");
            const key = trim(line[0..eq]);
            if (key.len == 0) return self.fault(.missing_key, "");

            const value = self.parseValue(trim(line[eq + 1 ..])) catch |err| return self.faultOf(err, trim(line[eq + 1 ..]));
            return .{ .item = .{ .key = key, .value = value, .line = self.line_no } };
        }
        return null;
    }

    fn fault(self: *Parser, what: Fault, text: []const u8) Event {
        return .{ .problem = .{ .fault = what, .text = text, .line = self.line_no } };
    }

    fn faultOf(self: *Parser, err: ParseError, text: []const u8) Event {
        return self.fault(switch (err) {
            error.MissingValue => .missing_value,
            error.UnreadableValue => .unreadable_value,
            error.UnterminatedString => .unterminated_string,
            error.TrailingText => .trailing_text,
            error.BadEscape => .bad_escape,
            error.UnterminatedList => .unterminated_list,
            error.ListWantsStrings => .list_wants_strings,
            error.OutOfMemory => .unreadable_value,
        }, switch (err) {
            // The escape is the useful half of that message; for everything
            // else it is the value as written.
            error.BadEscape => self.bad_escape,
            else => text,
        });
    }

    const ParseError = error{
        MissingValue,
        UnreadableValue,
        UnterminatedString,
        TrailingText,
        BadEscape,
        UnterminatedList,
        ListWantsStrings,
    } || Allocator.Error;

    fn parseValue(self: *Parser, text: []const u8) ParseError!Value {
        if (text.len == 0) return error.MissingValue;
        if (text[0] == '"') return .{ .string = try self.parseString(text) };
        if (text[0] == '[') return self.parseList(text);
        if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
        return .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.UnreadableValue };
    }

    /// A basic TOML string: quotes, and the four escapes anything here could
    /// want. `\n` matters because a template string will want one long before
    /// dates or unicode escapes do.
    fn parseString(self: *Parser, text: []const u8) ParseError![]const u8 {
        const end = stringEnd(text) orelse return error.UnterminatedString;
        if (end != text.len - 1) return error.TrailingText;

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < end) : (i += 1) {
            if (text[i] != '\\') {
                try out.append(self.arena, text[i]);
                continue;
            }
            i += 1;
            if (i >= end) break;
            try out.append(self.arena, switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                else => {
                    self.bad_escape = text[i .. i + 1];
                    return error.BadEscape;
                },
            });
        }
        return out.items;
    }

    fn parseList(self: *Parser, text: []const u8) ParseError!Value {
        if (text[text.len - 1] != ']') return error.UnterminatedList;

        var items: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) {
            while (i < text.len - 1 and (text[i] == ' ' or text[i] == '\t' or text[i] == ',')) i += 1;
            if (i >= text.len - 1) break;
            if (text[i] != '"') return error.ListWantsStrings;
            const end = stringEnd(text[i..]) orelse return error.UnterminatedString;
            try items.append(self.arena, try self.parseString(text[i .. i + end + 1]));
            i += end + 1;
        }
        return .{ .list = items.items };
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Everything before an unquoted `#`. Quoted, because `"#{change_id}"` is a
/// template string a `[templates]` entry puts in this file, and truncating it
/// at the `#` would be a silent corruption rather than an error.
fn stripComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '#' => return line[0..i],
            '"' => {
                const end = stringEnd(line[i..]) orelse return line;
                i += end;
            },
            else => {},
        }
    }
    return line;
}

/// Index of the closing quote of the string starting at index 0, or null when
/// there is not one. Escapes are honoured, so `"\""` closes at the last quote.
fn stringEnd(text: []const u8) ?usize {
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '"') return i;
    }
    return null;
}

const testing = std.testing;

/// Collects a whole document, which is what every test below wants.
fn parseAll(arena: Allocator, text: []const u8) !std.ArrayList(Event) {
    var out: std.ArrayList(Event) = .empty;
    var p: Parser = .init(arena, text);
    while (p.next()) |ev| try out.append(arena, ev);
    return out;
}

test "a document is tables, settings, and the lines that are neither" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const evs = (try parseAll(a.allocator(),
        \\# a comment, and a blank line follow
        \\
        \\[nav]
        \\hunk_crosses_files = false
        \\scrolloff = 8
        \\name = "gruvbox"
        \\keys = ["]w", "<Space>nf"]
    )).items;

    try testing.expectEqual(@as(usize, 5), evs.len);
    try testing.expectEqualStrings("nav", evs[0].table.name);
    try testing.expectEqual(@as(u32, 3), evs[0].table.line);

    try testing.expectEqualStrings("hunk_crosses_files", evs[1].item.key);
    try testing.expectEqual(false, evs[1].item.value.boolean);
    try testing.expectEqual(@as(i64, 8), evs[2].item.value.integer);
    try testing.expectEqualStrings("gruvbox", evs[3].item.value.string);

    const list = evs[4].item.value.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("]w", list[0]);
    try testing.expectEqualStrings("<Space>nf", list[1]);
    // The line number is what a message points the user at, so it counts the
    // blank and comment lines it skipped.
    try testing.expectEqual(@as(u32, 7), evs[4].item.line);
}

test "a `#` inside a string is data, not a comment" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // Template strings are full of them (
    // `ref_single = "#{change_id} {path}:{line}"`), and truncating one at the
    // `#` would be a silent corruption rather than an error.
    const evs = (try parseAll(a.allocator(),
        \\[templates]
        \\ref = "#{change_id} {path}"  # the real comment
    )).items;
    try testing.expectEqualStrings("#{change_id} {path}", evs[1].item.value.string);
}

test "the escapes a config file can want" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(),
        \\[t]
        \\x = "a\nb\tc\"d\\e"
    )).items;
    try testing.expectEqualStrings("a\nb\tc\"d\\e", evs[1].item.value.string);
}

test "every fault says which line, and quotes what it choked on" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const cases = [_]struct { text: []const u8, fault: Fault }{
        .{ .text = "[nav\n", .fault = .unterminated_table },
        .{ .text = "just some words\n", .fault = .expected_assignment },
        .{ .text = " = 3\n", .fault = .missing_key },
        .{ .text = "x =\n", .fault = .missing_value },
        .{ .text = "x = maybe\n", .fault = .unreadable_value },
        .{ .text = "x = \"unterminated\n", .fault = .unterminated_string },
        .{ .text = "x = \"one\" and more\n", .fault = .trailing_text },
        .{ .text = "x = \"a\\qb\"\n", .fault = .bad_escape },
        .{ .text = "x = [\"a\"\n", .fault = .unterminated_list },
        .{ .text = "x = [3]\n", .fault = .list_wants_strings },
    };
    for (cases) |case| {
        const evs = (try parseAll(a.allocator(), case.text)).items;
        try testing.expectEqual(@as(usize, 1), evs.len);
        try testing.expectEqual(case.fault, evs[0].problem.fault);
        try testing.expectEqual(@as(u32, 1), evs[0].problem.line);
    }

    // The two faults whose message is only useful with the offending text in
    // it carry that text rather than making the caller re-read the line.
    const bad_value = (try parseAll(a.allocator(), "x = maybe\n")).items;
    try testing.expectEqualStrings("maybe", bad_value[0].problem.text);
    const bad_escape = (try parseAll(a.allocator(), "x = \"a\\qb\"\n")).items;
    try testing.expectEqualStrings("q", bad_escape[0].problem.text);
}

test "a fault costs one line, and the document keeps going" {
    // The rule the whole config surface rests on: a typo
    // takes its own line down and nothing else.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(),
        \\[nav]
        \\broken = maybe
        \\scrolloff = 5
    )).items;

    try testing.expectEqual(@as(usize, 3), evs.len);
    try testing.expect(evs[1] == .problem);
    try testing.expectEqual(@as(i64, 5), evs[2].item.value.integer);
}

test "a setting before any table header still arrives" {
    // The parser does not decide whether that is allowed - the caller does,
    // because "outside any section" is a rule about lgtm's config, not about
    // the format.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(), "stray = 1\n")).items;
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings("stray", evs[0].item.key);
}
