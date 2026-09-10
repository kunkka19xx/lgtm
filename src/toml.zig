// SPDX-License-Identifier: Apache-2.0
//
// A small TOML subset, as a scanner: `[table]` headers, `key = value`,
// strings, booleans, integers, and arrays of strings. No dates, no
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
    /// The bad line, saved before list recovery advances the scanner.
    fault_line: ?u32 = null,

    pub fn init(arena: Allocator, text: []const u8) Parser {
        return .{ .arena = arena, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// The next event, or null at the end of the document. Blank lines and
    /// comments produce nothing; a setting produces one event even when its
    /// list spans several lines. A caller that stops at the first problem and
    /// one that reports them all are both ordinary loops.
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

            const start_line = self.line_no;
            const value = self.parseValue(trim(line[eq + 1 ..])) catch |err| {
                var event = self.faultOf(err, trim(line[eq + 1 ..]));
                if (self.fault_line) |at| {
                    event.problem.line = at;
                    self.fault_line = null;
                } else if (err == error.UnterminatedList) {
                    event.problem.line = start_line;
                }
                return event;
            };
            return .{ .item = .{ .key = key, .value = value, .line = start_line } };
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
        var items: std.ArrayList([]const u8) = .empty;
        var rest = text[1..];
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t\r,");
            if (rest.len == 0) {
                const raw = self.lines.peek() orelse return error.UnterminatedList;
                const line = trim(stripComment(raw));
                // A missing `]` must not eat the next setting or table.
                if (startsSetting(line)) return error.UnterminatedList;
                _ = self.lines.next();
                self.line_no += 1;
                rest = line;
                continue;
            }
            if (rest[0] == ']') {
                if (trim(rest[1..]).len != 0) return error.TrailingText;
                return .{ .list = items.items };
            }
            if (rest[0] != '"') return self.abandonList(rest, error.ListWantsStrings);
            const end = stringEnd(rest) orelse return self.abandonList(rest, error.UnterminatedString);
            const item = self.parseString(rest[0 .. end + 1]) catch |err| return self.abandonList(rest, err);
            items.append(self.arena, item) catch |err| return self.abandonList(rest, err);
            rest = rest[end + 1 ..];
        }
    }

    /// Drop a faulty list's remaining body so it cannot become top-level
    /// settings. A missing `]` must still leave the next setting or table alone.
    fn abandonList(self: *Parser, rest: []const u8, err: ParseError) ParseError {
        self.fault_line = self.line_no;
        if (indexUnquoted(rest, ']') != null) return err;
        while (self.lines.peek()) |raw| {
            const line = trim(stripComment(raw));
            if (startsSetting(line)) break;
            _ = self.lines.next();
            self.line_no += 1;
            if (indexUnquoted(line, ']') != null) break;
        }
        return err;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Everything before an unquoted `#`. Quoted, because `"#{change_id}"` is a
/// template string a `[templates]` entry puts in this file, and truncating it
/// at the `#` would be a silent corruption rather than an error.
fn stripComment(line: []const u8) []const u8 {
    return line[0 .. indexUnquoted(line, '#') orelse line.len];
}

/// A continuation may start with a comma before a string containing `=`.
/// Only an unquoted assignment or a table header ends an unfinished list.
fn startsSetting(line: []const u8) bool {
    return line.len != 0 and (line[0] == '[' or indexUnquoted(line, '=') != null);
}

/// Find punctuation outside strings; nothing after a comment counts.
fn indexUnquoted(line: []const u8, needle: u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == needle) return i;
        switch (line[i]) {
            '#' => return null,
            '"' => {
                const end = stringEnd(line[i..]) orelse return null;
                i += end;
            },
            else => {},
        }
    }
    return null;
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

test "string lists can span lines" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(),
        \\[settings]
        \\names = [ # opening comment
        \\    "alpha", # first item
        \\
        \\    # between items
        \\    "bravo#]", "charlie\"",
        \\] # closing comment
        \\count = 3
    )).items;

    try testing.expectEqual(@as(usize, 3), evs.len);
    try testing.expect(evs[1] == .item);
    try testing.expectEqualStrings("names", evs[1].item.key);
    try testing.expectEqual(@as(u32, 2), evs[1].item.line);
    const list = evs[1].item.value.list;
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("alpha", list[0]);
    try testing.expectEqualStrings("bravo#]", list[1]);
    try testing.expectEqualStrings("charlie\"", list[2]);
    try testing.expectEqual(@as(i64, 3), evs[2].item.value.integer);
    try testing.expectEqual(@as(u32, 8), evs[2].item.line);
}

test "list layout does not change its values" {
    const cases = [_][]const u8{
        "names = [\"alpha\", \"bravo\"]",
        "names = [\n\"alpha\",\n\"bravo\"\n]",
        "names = [\"alpha\",\n\"bravo\",]\n",
        "names = [\r\n\t\"alpha\", # first\r\n\t\"bravo\",\r\n]\r\n",
    };
    for (cases) |text| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const evs = (try parseAll(a.allocator(), text)).items;
        try testing.expectEqual(@as(usize, 1), evs.len);
        try testing.expect(evs[0] == .item);
        const list = evs[0].item.value.list;
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqualStrings("alpha", list[0]);
        try testing.expectEqualStrings("bravo", list[1]);
    }
}

test "a multiline list can be empty" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(), "names = [\n# nothing here\n\n]\n")).items;
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expect(evs[0] == .item);
    try testing.expectEqual(@as(usize, 0), evs[0].item.value.list.len);
}

test "an unfinished list leaves the next setting or table alone" {
    const cases = [_][]const u8{ "count = 3", "[next]" };
    for (cases) |next| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const text = try std.fmt.allocPrint(a.allocator(), "names = [\n\"alpha\",\n{s}\n", .{next});
        const evs = (try parseAll(a.allocator(), text)).items;
        try testing.expectEqual(@as(usize, 2), evs.len);
        try testing.expect(evs[0] == .problem);
        try testing.expectEqual(Fault.unterminated_list, evs[0].problem.fault);
        try testing.expectEqual(@as(u32, 1), evs[0].problem.line);
        if (next[0] == '[') {
            try testing.expectEqualStrings("next", evs[1].table.name);
            try testing.expectEqual(@as(u32, 3), evs[1].table.line);
        } else {
            try testing.expectEqual(@as(i64, 3), evs[1].item.value.integer);
            try testing.expectEqual(@as(u32, 3), evs[1].item.line);
        }
    }
}

test "multiline list faults name the bad line unless the closing bracket is missing" {
    const cases = [_]struct { text: []const u8, fault: Fault, line: u32 }{
        .{ .text = "names = [\n\"alpha\",\n", .fault = .unterminated_list, .line = 1 },
        .{ .text = "names = [\n3]\n", .fault = .list_wants_strings, .line = 2 },
        .{ .text = "names = [\n\"unfinished\n", .fault = .unterminated_string, .line = 2 },
        .{ .text = "names = [\n\"a\\qb\"]\n", .fault = .bad_escape, .line = 2 },
        .{ .text = "names = [\n\"alpha\"\n] extra\n", .fault = .trailing_text, .line = 3 },
    };
    for (cases) |case| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const evs = (try parseAll(a.allocator(), case.text)).items;
        try testing.expectEqual(@as(usize, 1), evs.len);
        try testing.expect(evs[0] == .problem);
        try testing.expectEqual(case.fault, evs[0].problem.fault);
        try testing.expectEqual(case.line, evs[0].problem.line);
    }
}

test "a comma before a quoted equals sign does not start a setting" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const evs = (try parseAll(a.allocator(),
        \\names = [
        \\    "alpha"
        \\  , "k=v"
        \\]
        \\count = 1
    )).items;
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expect(evs[0] == .item);
    const list = evs[0].item.value.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("alpha", list[0]);
    try testing.expectEqualStrings("k=v", list[1]);
    try testing.expectEqual(@as(i64, 1), evs[1].item.value.integer);
    try testing.expectEqual(@as(u32, 5), evs[1].item.line);
}

test "a bad list produces one fault and skips quoted brackets during recovery" {
    const cases = [_]struct { item: []const u8, fault: Fault }{
        .{ .item = "3,", .fault = .list_wants_strings },
        .{ .item = "\"a\\qb\",", .fault = .bad_escape },
        .{ .item = "\"unfinished", .fault = .unterminated_string },
        .{ .item = "\"a\\q]b\",", .fault = .bad_escape },
        .{ .item = "3, \"]\",", .fault = .list_wants_strings },
        .{ .item = "3, # ]", .fault = .list_wants_strings },
    };
    for (cases) |case| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const text = try std.fmt.allocPrint(a.allocator(),
            \\names = [
            \\{s}
            \\  , "k=v",
            \\  "]", # ]
            \\  "bravo\"=]",
            \\  # ]
            \\]
            \\broken = maybe
            \\count = 1
        , .{case.item});
        const evs = (try parseAll(a.allocator(), text)).items;
        try testing.expectEqual(@as(usize, 3), evs.len);
        try testing.expect(evs[0] == .problem);
        try testing.expectEqual(case.fault, evs[0].problem.fault);
        try testing.expectEqual(@as(u32, 2), evs[0].problem.line);
        if (case.fault == .bad_escape) try testing.expectEqualStrings("q", evs[0].problem.text);
        // Recovery must not leave the saved fault line on the next event.
        try testing.expectEqual(Fault.unreadable_value, evs[1].problem.fault);
        try testing.expectEqual(@as(u32, 8), evs[1].problem.line);
        try testing.expectEqual(@as(i64, 1), evs[2].item.value.integer);
        try testing.expectEqual(@as(u32, 9), evs[2].item.line);
    }
}

test "list recovery stops before the next setting or table without a closing bracket" {
    const cases = [_][]const u8{ "count = 3", "[next]" };
    for (cases) |next| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const text = try std.fmt.allocPrint(a.allocator(), "names = [\n3,\n\"alpha\",\n{s}\n", .{next});
        const evs = (try parseAll(a.allocator(), text)).items;
        try testing.expectEqual(@as(usize, 2), evs.len);
        try testing.expectEqual(Fault.list_wants_strings, evs[0].problem.fault);
        try testing.expectEqual(@as(u32, 2), evs[0].problem.line);
        if (next[0] == '[') {
            try testing.expectEqualStrings("next", evs[1].table.name);
            try testing.expectEqual(@as(u32, 4), evs[1].table.line);
        } else {
            try testing.expectEqual(@as(i64, 3), evs[1].item.value.integer);
            try testing.expectEqual(@as(u32, 4), evs[1].item.line);
        }
    }
}

test "list recovery stops at a closing bracket on the bad line or at end of file" {
    const cases = [_][]const u8{
        "names = [3]\ncount = 1",
        "names = [\"a\\qb\"]\ncount = 1",
        "names = [3,\n\"alpha\"]\ncount = 1",
        "names = [3,\n\"alpha\",\n",
    };
    for (cases, 0..) |text, i| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const evs = (try parseAll(a.allocator(), text)).items;
        try testing.expectEqual(@as(usize, if (i == 3) 1 else 2), evs.len);
        try testing.expect(evs[0] == .problem);
        try testing.expectEqual(@as(u32, 1), evs[0].problem.line);
        if (evs.len == 2) try testing.expectEqual(@as(i64, 1), evs[1].item.value.integer);
    }
}
