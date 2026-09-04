// SPDX-License-Identifier: Apache-2.0
//
// `e` - open the cursor's line in the user's editor. Only the argv is built
// here, and it is built without spawning anything, because that is the part
// that is wrong in every tool that gets this wrong: the line-number flag is
// not portable, and getting it wrong silently opens the file at line 1.
//
// v1 is read-only, so this is an escape hatch rather than an edit
// path: you leave, you fix it yourself, you come back and the watcher has
// already re-diffed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How an editor is told which line to open at. Unknown editors get `.none`
/// and open at the top - wrong-but-harmless, where guessing `+47` at something
/// that does not understand it would open a *file* called `+47`.
pub const LineSyntax = enum {
    /// `editor +47 path` - vi and everything descended from it.
    plus,
    /// `editor path:47` - helix, sublime, zed.
    suffix,
    /// `editor --goto path:47` - the vscode family.
    goto,
    none,
};

pub fn lineSyntaxFor(program: []const u8) LineSyntax {
    const name = basename(program);
    const plus = [_][]const u8{ "vi", "vim", "nvim", "view", "gvim", "emacs", "emacsclient", "nano", "pico", "kak", "micro", "joe", "ne" };
    const suffix = [_][]const u8{ "hx", "helix", "subl", "sublime_text", "zed", "zeditor" };
    const goto = [_][]const u8{ "code", "code-insiders", "codium", "vscodium", "cursor", "windsurf" };

    for (plus) |p| if (std.mem.eql(u8, name, p)) return .plus;
    for (suffix) |p| if (std.mem.eql(u8, name, p)) return .suffix;
    for (goto) |p| if (std.mem.eql(u8, name, p)) return .goto;
    return .none;
}

/// The vscode family forks and returns immediately unless told to wait, which
/// would drop the user back into `lgtm` over the top of their own editor. Only
/// added when the user has not already asked for it themselves.
fn needsWait(program: []const u8) bool {
    return lineSyntaxFor(program) == .goto;
}

fn hasWait(words: []const []const u8) bool {
    for (words) |w| {
        if (std.mem.eql(u8, w, "-w") or std.mem.eql(u8, w, "--wait")) return true;
    }
    return false;
}

fn basename(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[cut + 1 ..];
}

/// Splits `$EDITOR` on spaces. Not a shell: `EDITOR="my editor"` with a space
/// in the *path* will not work, and neither will quoting or `$VAR`. Documented
/// rather than half-implemented, because a half-parser for shell quoting is a
/// source of surprises out of all proportion to the case it serves.
pub fn split(arena: Allocator, spec: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, spec, ' ');
    while (it.next()) |word| try out.append(arena, word);
    return try out.toOwnedSlice(arena);
}

/// The full argv for opening `path` at `line`. `line` of 0 means "no line",
/// which is what a cursor sitting on a deleted line amounts to: the new file
/// has no such line, so opening at the top is the only honest answer.
pub fn argv(
    arena: Allocator,
    spec: []const u8,
    path: []const u8,
    line: u32,
) Allocator.Error!?[]const []const u8 {
    const words = try split(arena, spec);
    if (words.len == 0) return null;

    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, words);
    if (needsWait(words[0]) and !hasWait(words)) try out.append(arena, "--wait");

    const syntax = if (line == 0) .none else lineSyntaxFor(words[0]);
    switch (syntax) {
        .plus => {
            try out.append(arena, try std.fmt.allocPrint(arena, "+{d}", .{line}));
            try out.append(arena, path);
        },
        .suffix => try out.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line })),
        .goto => {
            try out.append(arena, "--goto");
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line }));
        },
        .none => try out.append(arena, path),
    }
    return try out.toOwnedSlice(arena);
}

/// `$VISUAL`, then `$EDITOR`, then `vi`. VISUAL first is the convention and it
/// is the right one here: it is defined as the full-screen editor, and this is
/// a full-screen context.
pub fn specFrom(environ: *const std.process.Environ.Map) []const u8 {
    if (environ.get("VISUAL")) |v| {
        if (v.len > 0) return v;
    }
    if (environ.get("EDITOR")) |v| {
        if (v.len > 0) return v;
    }
    return "vi";
}

const testing = std.testing;

fn build(arena: Allocator, spec: []const u8, line: u32) ![]const []const u8 {
    return (try argv(arena, spec, "src/auth.zig", line)).?;
}

test "vi-family editors get +N before the path" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try build(a.allocator(), "nvim", 47);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("nvim", got[0]);
    try testing.expectEqualStrings("+47", got[1]);
    try testing.expectEqualStrings("src/auth.zig", got[2]);
}

test "helix and friends take the line as a suffix on the path" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try build(a.allocator(), "hx", 47);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("src/auth.zig:47", got[1]);
}

test "the vscode family gets --goto and is made to wait" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try build(a.allocator(), "code", 47);
    // Without --wait it returns instantly and lgtm redraws over the editor.
    try testing.expectEqualStrings("--wait", got[1]);
    try testing.expectEqualStrings("--goto", got[2]);
    try testing.expectEqualStrings("src/auth.zig:47", got[3]);

    // Already asked for by the user: not added twice.
    const twice = try build(a.allocator(), "code -w", 47);
    var waits: usize = 0;
    for (twice) |w| {
        if (std.mem.eql(u8, w, "-w") or std.mem.eql(u8, w, "--wait")) waits += 1;
    }
    try testing.expectEqual(@as(usize, 1), waits);
}

test "an unknown editor is opened at the top rather than handed a bad flag" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // `+47` at something that does not understand it opens a file named +47.
    const got = try build(a.allocator(), "acme", 47);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("src/auth.zig", got[1]);
}

test "a deleted line has no line number in the new file, so none is sent" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try build(a.allocator(), "vim", 0);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("src/auth.zig", got[1]);
}

test "existing flags in $EDITOR are preserved, and a path is matched by basename" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const got = try build(a.allocator(), "emacsclient -nw", 12);
    try testing.expectEqualStrings("emacsclient", got[0]);
    try testing.expectEqualStrings("-nw", got[1]);
    try testing.expectEqualStrings("+12", got[2]);

    // /usr/local/bin/nvim is still nvim.
    try testing.expectEqual(LineSyntax.plus, lineSyntaxFor("/usr/local/bin/nvim"));
    try testing.expectEqual(LineSyntax.none, lineSyntaxFor(""));
}

test "an empty or whitespace-only spec yields no command at all" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // Spawning `""` would be an error dialog for something the user can fix by
    // setting a variable, so the caller is told there is nothing to run.
    try testing.expect(try argv(a.allocator(), "", "a.zig", 1) == null);
    try testing.expect(try argv(a.allocator(), "   ", "a.zig", 1) == null);
}
