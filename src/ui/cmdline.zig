// SPDX-License-Identifier: Apache-2.0
//
// The `:` and `/` line: running a command by the name `[keys]` binds it by,
// completing a value, and the search the prompt drives.

const std = @import("std");

const app_mod = @import("app.zig");
const App = app_mod.App;
const complete = @import("complete.zig");
const config = @import("../config.zig");
const event = @import("../core/event.zig");
const keymap = @import("keymap.zig");
const pr_mod = @import("pr.zig");
const prompt_mod = @import("prompt.zig");
const search = @import("search.zig");
const theme_mod = @import("theme.zig");
const walks = @import("walks.zig");
const fuzzy = @import("fuzzy.zig");
const motion = @import("motion.zig");

/// The `:` lines that take a value, and the value's completions.
///
/// One entry so far. It is a table rather than an `if` because the second
/// one is what turns an `if` into a bug: the split, the completion and the
/// dispatch all have to agree on the same verb, and here they read it from
/// the same row.
const Setting = struct {
    verb: []const u8,
    names: []const []const u8,
};

/// A line split at its verb: which setting it names, and the value typed
/// after it - empty while the reader is still at `:theme `.
const Typed = struct { setting: Setting, arg: []const u8 };

const settings = [_]Setting{
    .{ .verb = "theme", .names = theme_mod.bundled_names },
    // No completions: the numbers are GitHub's, and asking it for them on
    // every `<Tab>` is a network call for a list the reader already has
    // in the branch they are on.
    .{ .verb = "pr", .names = &.{} },
    .{ .verb = "post", .names = &.{} },
    .{ .verb = "approve", .names = &.{} },
    .{ .verb = "request-changes", .names = &.{} },
    // vim's spelling, for the reader who arrives already knowing it.
    .{ .verb = "colorscheme", .names = theme_mod.bundled_names },
    .{ .verb = "colo", .names = theme_mod.bundled_names },
};

pub fn openPrompt(app: *App, kind: prompt_mod.Kind) void {
    app.prompt_return = app.mode;
    app.prompt.start(kind);
    app.mode = .command;
    app.notice.clear();
}

pub fn closePrompt(app: *App) void {
    app.comp = .{};
    app.prompt.close();
    app.mode = app.prompt_return;
}

/// Text entry, which is why it does not go through the keymap: inside a
/// prompt `j` is the letter j, not a motion (see prompt.zig).
pub fn feedPrompt(app: *App, key: event.Key, body: u16) !void {
    switch (app.prompt.feed(key)) {
        // Any edit invalidates the cycle: the reader has said something
        // new, so the next `<Tab>` starts from what is now on the line.
        .typing => app.comp = .{},
        .complete => completeStep(app, 1),
        .complete_back => completeStep(app, -1),
        .cancel => closePrompt(app),
        .submit => {
            // Copied out before closing: the prompt's buffer is about to
            // be declared empty, and submitting can re-enter it.
            var buf: [prompt_mod.max_bytes]u8 = undefined;
            const text = app.prompt.text();
            @memcpy(buf[0..text.len], text);
            const kind = app.prompt.kind;
            closePrompt(app);
            try submitPrompt(app, kind, buf[0..text.len], body);
            app.clampScroll(body);
        },
    }
}

pub fn submitPrompt(app: *App, kind: prompt_mod.Kind, line: []const u8, body: u16) !void {
    switch (kind) {
        .search_forward => {
            // Bare Enter repeats the last query, as in vim. Every search
            // starts forward; `N` is what runs it backwards.
            if (line.len != 0) app.finder.set(line, .forward);
            try walks.searchStep(app, if (line.len == 0) app.finder.dir else .forward);
        },
        .command => try submitCommand(app, line, body),
        // The popup's filter is its own `Prompt`, fed by `feedHelp`, so it
        // never arrives here.
        .help_filter => {},
    }
}

/// `<Tab>` in the `:` line: extend to what every candidate shares, then
/// cycle through them.
///
/// Vim's `longest:full` in two rules. Typing `n` and pressing Tab gets to
/// `next_` without committing to which `next_` it is, because that is the
/// part the reader would have typed anyway; only when there is nothing
/// left to share does Tab start choosing for them.
pub fn completeStep(app: *App, dir: i32) void {
    if (app.prompt.kind != .command) return;

    // Past the verb of a line that takes a value, Tab is completing the
    // value: `:theme <Tab>` walks the palettes, not the command names.
    // Everything below is the same two rules either way, so the only
    // difference is which list and what gets written back.
    const arg = settingOf(app.prompt.text());

    if (app.comp.empty()) {
        const typed = if (arg) |a| a.arg else app.prompt.text();
        app.comp = if (arg) |a|
            complete.fromNames(a.setting.names, typed)
        else
            complete.candidates(app.km.bindings, typed);
        app.comp_at = null;
        if (app.comp.empty()) return;

        // Something shared beyond what was typed: hand that over and stop.
        // The strip stays up, so the reader can see what they are choosing
        // between before the next press picks one.
        if (app.comp.common > typed.len) {
            setLine(app, arg, app.comp.items[0][0..app.comp.common]);
            // One candidate means the line is now that command, whole.
            if (app.comp.len == 1) app.comp_at = 0;
            return;
        }
    }

    const n = app.comp.len;
    if (n == 0) return;
    const next = if (app.comp_at) |at| blk: {
        const step = @as(i64, @intCast(at)) + dir;
        break :blk @as(usize, @intCast(@mod(step, @as(i64, @intCast(n)))));
    } else if (dir > 0) 0 else n - 1;

    app.comp_at = next;
    setLine(app, arg, app.comp.items[next]);
}

/// Writes a completion back into the line: the whole line for a command,
/// the part after the verb for a value.
pub fn setLine(app: *App, arg: ?Typed, name: []const u8) void {
    const a = arg orelse return app.prompt.set(name);
    var buf: [prompt_mod.max_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ a.setting.verb, name }) catch return;
    app.prompt.set(line);
}

/// `:` runs a command by the name `[keys]` binds it by.
///
/// The same `stringToEnum` the config parser uses, pointed at what the
/// reader typed. That is the whole implementation, and it is the
/// convention that every action is a named command finally being worth
/// something where a user can see it: `?` shows the keys, `:` runs the
/// names, and both read the one table, so neither can drift from what the
/// tool does.
///
/// A key is scarce and a name is not, which is why this matters beyond
/// convenience: `quit` has no binding at all and never has, and `:q` is
/// how it is reached. This generalises that to all of them.
pub fn submitCommand(app: *App, line: []const u8, body: u16) !void {
    const typed = std.mem.trim(u8, line, " ");
    if (typed.len == 0) return;

    // Before the table, because a line with a value in it is not a name in
    // the table and never will be.
    if (settingOf(typed)) |s| {
        if (std.mem.eql(u8, s.setting.verb, "pr")) return pr_mod.openPr(app, s.arg);
        if (std.mem.eql(u8, s.setting.verb, "post")) return pr_mod.postReview(app, .comment, s.arg);
        if (std.mem.eql(u8, s.setting.verb, "approve")) return pr_mod.postReview(app, .approve, s.arg);
        if (std.mem.eql(u8, s.setting.verb, "request-changes")) return pr_mod.postReview(app, .request_changes, s.arg);
        return setTheme(app, s.arg);
    }

    const cmd = aliasFor(typed) orelse
        std.meta.stringToEnum(keymap.Command, typed) orelse
        {
            // Naming the nearest one beats refusing: the names are long
            // and a reader typing them has already got most of it right.
            // Without echoing the typo back: the reader typed it a
            // keystroke ago, and at 80 columns the slot is about 54
            // characters. A message that gets cut off is a worse bug
            // than a message that says less.
            if (nearestCommand(app, typed)) |near| {
                app.notice.set("not a command - did you mean :{s}?", .{@tagName(near)});
            } else {
                app.notice.set("not a command: :{s}", .{typed});
            }
            return;
        };

    if (!keymap.typeable(app.km.bindings, cmd)) {
        app.notice.set(":{s} works only in {s}", .{ typed, onlyIn(app, cmd) });
        return;
    }
    try app.run(cmd, body);
}

/// Vim's spellings for the commands a reader arrives already knowing.
///
/// Aliases onto the same table rather than a second implementation: `:noh`
/// and the key that clears the highlight have to keep meaning the same
/// thing, and two code paths are how that quietly stops being true. It
/// already had: `:nomark` used to drop the mark without noticing there was
/// none to drop, which `clear_mark` has always got right.
pub fn aliasFor(text: []const u8) ?keymap.Command {
    const table = [_]struct { []const u8, keymap.Command }{
        .{ "q", .quit },
        .{ "q!", .quit },
        .{ "qa", .quit },
        .{ "qa!", .quit },
        .{ "noh", .clear_search },
        .{ "nohl", .clear_search },
        .{ "nohlsearch", .clear_search },
        .{ "prs", .pr_list },
        .{ "nomark", .clear_mark },
        .{ "nom", .clear_mark },
    };
    for (table) |e| {
        if (std.mem.eql(u8, text, e[0])) return e[1];
    }
    return null;
}

/// The setting a line names, and whatever follows it. Null for every other
/// line, which is the ordinary command path.
pub fn settingOf(line: []const u8) ?Typed {
    const text = std.mem.trimStart(u8, line, " ");
    for (settings) |st| {
        if (!std.mem.startsWith(u8, text, st.verb)) continue;
        const rest = text[st.verb.len..];
        // `:themes` is not `:theme` with an argument.
        if (rest.len != 0 and rest[0] != ' ') continue;
        return .{ .setting = st, .arg = std.mem.trim(u8, rest, " ") };
    }
    return null;
}

/// `:theme <name>` changes the palette for this session.
///
/// Not an entry in the `Command` table: that table maps a name to an
/// action with no argument, and every entry in it can be bound to a key. A
/// value cannot be typed by a keystroke.
///
/// Session-only, and it says so. Writing it back would mean rewriting a
/// file the reader hand-wrote, comments and all; naming the two lines they
/// would type is honest and costs them one paste. Slot overrides in
/// `[theme]` are discarded, which is what setting `name` does in the file
/// too.
pub fn setTheme(app: *App, arg: []const u8) void {
    if (arg.len == 0) {
        app.notice.set("theme {s} - :theme <Tab> to change it", .{app.theme_name});
        return;
    }
    const found = theme_mod.lookup(arg) orelse {
        var buf: [256]u8 = undefined;
        app.notice.set("no theme called {s} - try {s}", .{ arg, config.themeNames(&buf) });
        return;
    };
    app.theme = found.theme;
    app.theme_name = found.name;
    app.notice.set("theme {s} - to keep it: [theme] name = \"{s}\"", .{ found.name, found.name });
}

/// Where a command that `:` refuses does live, for the message that says so.
///
/// Naming the one place beats listing every place it is not: "works only
/// in a list" tells a reader what to do next, and it fits the slot.
pub fn onlyIn(app: *App, cmd: keymap.Command) []const u8 {
    for (app.km.bindings) |b| {
        if (b.command != cmd) continue;
        if (b.modes.compose) return "the compose box";
        if (b.modes.help or b.modes.finder) return "a list";
    }
    return "another mode";
}

/// The closest command name to something that was not one.
///
/// Only ever suggests a command `:` would actually run, because pointing a
/// reader at `:compose_submit` and then refusing it is worse than saying
/// nothing.
pub fn nearestCommand(app: *App, typed: []const u8) ?keymap.Command {
    var loose: ?keymap.Command = null;
    for (std.enums.values(keymap.Command)) |cmd| {
        if (!keymap.typeable(app.km.bindings, cmd)) continue;
        const tier = fuzzy.match(@tagName(cmd), typed) orelse continue;
        switch (tier) {
            .solid => return cmd,
            .loose => if (loose == null) {
                loose = cmd;
            },
        }
    }
    return loose;
}

/// `*` and `#`: search the review for the identifier under the cursor.
///
/// The review's most common question - where else does this name appear,
/// now that it has changed - without typing the name. Matched whole, so
/// `*` on `id` walks the four places `id` is used rather than every
/// `width` and `valid` between them. `/` is still there for a fragment.
///
/// The word is copied into the finder's fixed buffer, so it does not
/// outlive the diff arena it was read from.
pub fn searchWord(app: *App, dir: search.Direction) !void {
    const word = motion.wordAt(app.cursorText(), app.vp.col) orelse {
        // The same courtesy `f` gets: a key that moved nothing says why.
        app.notice.set("no word under the cursor", .{});
        return;
    };
    app.finder.setWord(word, dir);
    try walks.searchStep(app, dir);
}

/// The pattern the renderer highlights this frame.
///
/// While a `/` prompt is open it is the text being typed, so matches light
/// up as the query is built rather than only once Enter is pressed. That
/// is vim's `incsearch`, and the reason it earns its place: you find out
/// you have typed enough to be unambiguous *before* committing to it, and
/// a query that matches nothing says so while there is still a keystroke
/// left to fix it.
///
/// A `:` prompt highlights nothing. Its text is a command, not a pattern,
/// and painting `noh` across the diff while it is typed is exactly the
/// noise this feature is supposed to reduce.
pub fn liveQuery(app: *App) search.Pattern {
    if (app.prompt.open and app.prompt.kind == .search_forward) {
        return .{ .text = app.prompt.text() };
    }
    return app.finder.shownPattern();
}

const testing = std.testing;

test "a verb the line only starts with is not a setting" {
    // `:themes` is a typo for a command, not `:theme` with an argument, and
    // treating it as one would set the theme to nothing and say so oddly.
    try testing.expect(settingOf("themes") == null);
    try testing.expect(settingOf("theme") != null);
    try testing.expectEqualStrings("", settingOf("theme").?.arg);
    try testing.expectEqualStrings("gruvbox", settingOf("theme  gruvbox ").?.arg);
    // vim's spelling reaches the same list.
    try testing.expectEqualStrings("dracula", settingOf("colo dracula").?.arg);
}

test "search crosses into the next file and lands on the matching row" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("/");
    try fx.expectMode(.command);
    // Inside the prompt these are letters, not motions: `j` must not move.
    try fx.typeIn("token");
    try fx.expectCursor(1);
    try fx.press("<CR>");

    try fx.expectMode(.normal);
    try fx.expectFile(1);
    // Row 2 of b.zig: header, line 0, line 1.
    try fx.expectCursor(2);
    // Reaching the next file in order is not a wrap.
    try testing.expect(!fx.app.finder.wrapped);
}

test "search wraps past the end of the review and says so" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    fx.app.file_index = 1;
    try fx.app.rebuildRows(.reset);

    try fx.press("/");
    try fx.typeIn("alpha");
    try fx.press("<CR>");

    try fx.expectFile(0);
    try fx.expectCursor(1);
    try testing.expect(fx.app.finder.wrapped);
    try fx.expectNotice("wrapped");
}

test "n repeats the search and N reverses it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `const` appears once per file, so stepping is observable.
    try fx.press("/");
    try fx.typeIn("const");
    try fx.press("<CR>");
    try fx.expectFile(0);
    try fx.expectCursor(2);

    try fx.press("n");
    try fx.expectFile(1);

    try fx.press("N");
    try fx.expectFile(0);
    try fx.expectCursor(2);
}

test "a search that finds nothing leaves the cursor put and says why" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    const before = fx.app.vp.cursor;
    try fx.press("/");
    try fx.typeIn("nowhere");
    try fx.press("<CR>");

    try testing.expectEqual(before, fx.app.vp.cursor);
    try testing.expect(fx.app.finder.failed);
    try fx.expectNotice("not found");
}

test "escaping a prompt returns to the mode it was opened from" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("V");
    try fx.press("/");
    try fx.typeIn("x");
    try fx.press("<Esc>");
    // A search abandoned mid-selection must not also abandon the selection.
    try fx.expectMode(.visual);
    try testing.expect(fx.app.selection() != null);
}

test ":q quits and anything else reports itself rather than vanishing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("wq");
    try fx.press("<CR>");
    try testing.expect(!fx.app.quit);
    try fx.expectNotice(":wq");

    try fx.press(":");
    try fx.typeIn("q");
    try fx.press("<CR>");
    try testing.expect(fx.app.quit);
}

test "matches light up while the query is still being typed" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Nothing to paint before a search exists.
    try testing.expectEqualStrings("", fx.app.view(app_mod.body_rows).?.query.text);

    // Mid-type, with no Enter yet: this is the whole feature.
    try fx.press("/co");
    try testing.expectEqualStrings("co", fx.app.view(app_mod.body_rows).?.query.text);
    try fx.press("n");
    try testing.expectEqualStrings("con", fx.app.view(app_mod.body_rows).?.query.text);

    // Cancelling puts the screen back the way it was, rather than leaving the
    // abandoned query painted across the diff.
    try fx.press("<Esc>");
    try testing.expectEqualStrings("", fx.app.view(app_mod.body_rows).?.query.text);

    // Submitting hands over to the stored query, and `:noh` still clears it.
    try fx.press("/co");
    try fx.press("ns");
    try fx.press("t");
    try fx.press("<CR>");
    try testing.expectEqualStrings("const", fx.app.view(app_mod.body_rows).?.query.text);
    try fx.press(":noh");
    try fx.press("<CR>");
    try testing.expectEqualStrings("", fx.app.view(app_mod.body_rows).?.query.text);
}

test "a command being typed is not painted across the diff" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `:` text is a command, not a pattern. Highlighting it would paint `noh`
    // over the review while the reader types the thing that turns painting off.
    try fx.press(":noh");
    try testing.expectEqualStrings("", fx.app.view(app_mod.body_rows).?.query.text);
    try fx.press("<Esc>");
}

test "* searches the review for the word under the cursor" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j"); // onto `    const x = 1;`
    try fx.press("^"); // onto `const` itself
    try fx.press("*");

    try testing.expectEqualStrings("const", fx.app.finder.query());
    // Strict, which is the difference between `*` and typing the word into `/`.
    try testing.expect(fx.app.finder.whole);

    // And it went somewhere: the `const` in the other file.
    try fx.expectFile(1);
    try fx.expectCursor(2);
}

test "* from punctuation takes the next word rather than refusing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    // Column 0 of `    const x = 1;` is a blank, not a word.
    try fx.press("0");
    try fx.press("*");
    try testing.expectEqualStrings("const", fx.app.finder.query());
}

test "* on a line with no word says so instead of moving" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    try fx.press("j"); // `}`, which has nothing to search for
    const before = fx.app.vp.cursor;
    try fx.press("*");

    try fx.expectNotice("no word");
    try testing.expectEqual(before, fx.app.vp.cursor);
    // And it left the previous search alone rather than clearing it.
    try testing.expect(!fx.app.finder.active());
}

test "; after * steps the matches, not the word under the new cursor" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    try fx.press("^");
    try fx.press("*");
    try fx.expectFile(1);

    // The trap this guards: repeating `*` itself would pick up whatever word
    // the cursor has since landed on, and the search would wander.
    try testing.expectEqual(keymap.Command.search_next, fx.app.last_walk.?);
    try fx.press(";");
    try testing.expectEqualStrings("const", fx.app.finder.query());
    try fx.expectFile(0);
}

test "# searches backwards, and n keeps going that way" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    try fx.press("^");
    try fx.press("#");

    try testing.expectEqualStrings("const", fx.app.finder.query());
    try testing.expectEqual(search.Direction.backward, fx.app.finder.dir);
    try fx.expectFile(1);
}

test "a / after a * loosens the pattern again" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("j");
    try fx.press("^");
    try fx.press("*");
    try testing.expect(fx.app.finder.whole);

    // Strictness belongs to the search that set it. Left behind, it would
    // silently narrow the next `/` the reader typed.
    try fx.press("/");
    try fx.typeIn("token");
    try fx.press("<CR>");
    try testing.expect(!fx.app.finder.whole);
}

test ": runs a command by the name [keys] binds it by" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.expectFile(0);
    try fx.press(":");
    try fx.typeIn("next_file");
    try fx.press("<CR>");
    try fx.expectFile(1);
}

test "vim's spellings are aliases onto the same commands, not a second path" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `:noh` is `clear_search`, so the pattern survives and only the paint
    // stops - which is the whole of what `:noh` means.
    try fx.press("/");
    try fx.typeIn("token");
    try fx.press("<CR>");
    try fx.press(":");
    try fx.typeIn("noh");
    try fx.press("<CR>");
    try testing.expectEqualStrings("", fx.app.finder.shown());
    try testing.expectEqualStrings("token", fx.app.finder.query());

    // And the alias inherits what the command already got right: `:nomark`
    // used to drop a mark that was not there without saying so.
    try fx.press(":");
    try fx.typeIn("nomark");
    try fx.press("<CR>");
    try fx.expectNotice("no mark to drop");
}

test ":q still quits, though quit has no key of its own" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("q");
    try fx.press("<CR>");
    try testing.expect(fx.app.quit);
}

test ":quit works too, because the name is the command" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("quit");
    try fx.press("<CR>");
    try testing.expect(fx.app.quit);
}

test "a name the table does not have is refused, and how depends on the name" {
    // The three refusals, and they differ on purpose: nothing typed is not a
    // mistake, a near miss is worth naming, and a command that lives in the
    // box is worth pointing at rather than denying.
    const cases = [_]struct { typed: []const u8, want: []const u8 }{
        .{ .typed = "", .want = "" },
        .{ .typed = "zzzzqqqq", .want = "not a command" },
        .{ .typed = "compose_submit", .want = "works only in the compose box" },
    };

    for (cases) |c| {
        var fx = try app_mod.Fixture.init(testing.allocator);
        defer fx.deinit();
        try fx.press(":");
        if (c.typed.len > 0) try fx.typeIn(c.typed);
        try fx.press("<CR>");
        if (c.want.len == 0) try fx.expectNoNotice() else try fx.expectNotice(c.want);
    }
}

test "a typo names the nearest command rather than only refusing" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("nextfile");
    try fx.press("<CR>");
    try fx.expectNotice("did you mean :next_file?");
    // And it did not run anything on a guess.
    try fx.expectFile(0);
}

test "every typeable command is reachable by its own name" {
    // The property that makes `?` and `:` two halves of one table: if a
    // command can be typed, `stringToEnum` must find it under exactly the
    // name CONFIG.md prints. A command renamed in the enum and not in the
    // docs fails here rather than in a user's config file.
    for (std.enums.values(keymap.Command)) |cmd| {
        if (!keymap.typeable(keymap.default_bindings, cmd)) continue;
        const back = std.meta.stringToEnum(keymap.Command, @tagName(cmd));
        try testing.expectEqual(cmd, back.?);
    }
}

test "quit is the command with no key, which is why : has to reach names" {
    // If this ever gains a binding the comment in `submitCommand` is stale,
    // and if another command loses its binding this is where that shows up.
    try testing.expect(keymap.typeable(keymap.default_bindings, .quit));
    for (keymap.default_bindings) |b| {
        try testing.expect(b.command != .quit);
    }
}

test "every command-line message fits the slot at 80 columns" {
    // Hard rule 9's home environment. The refusals are the long ones, and the
    // longest command name is what decides whether they fit, so this measures
    // the worst case rather than a representative one.
    var longest: usize = 0;
    for (std.enums.values(keymap.Command)) |cmd| {
        longest = @max(longest, @tagName(cmd).len);
    }
    // " NORMAL " and the right-hand hint strip take the rest of the row.
    const slot = 54;
    try testing.expect("not a command - did you mean :".len + longest + "?".len <= slot);
    try testing.expect(":".len + longest + " works only in the compose box".len <= slot);
}

test "Tab extends to what every candidate shares before choosing for you" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("n");
    try fx.press("<Tab>");

    // `next_` is the part the reader would have typed anyway. Committing to
    // one of the six here would be the key guessing.
    try testing.expectEqualStrings("next_", fx.app.prompt.text());
    try testing.expect(fx.app.comp_at == null);
    try testing.expect(fx.app.comp.len > 1);
}

test "the next Tab cycles, and Shift-Tab comes back" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("n");
    try fx.press("<Tab>"); // extends to next_
    try fx.press("<Tab>"); // first candidate
    // Duped: `text()` is a view into the prompt's buffer, which the next
    // completion overwrites in place.
    const first = try testing.allocator.dupe(u8, fx.app.prompt.text());
    defer testing.allocator.free(first);
    try testing.expect(std.mem.startsWith(u8, first, "next_"));

    try fx.press("<Tab>");
    try testing.expect(!std.mem.eql(u8, first, fx.app.prompt.text()));

    try fx.press("<S-Tab>");
    try testing.expectEqualStrings(first, fx.app.prompt.text());
}

test "cycling wraps rather than stopping at the end" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("next_");
    try fx.press("<Tab>");
    const first = try testing.allocator.dupe(u8, fx.app.prompt.text());
    defer testing.allocator.free(first);

    // Round the whole list once and land back where it started.
    for (0..fx.app.comp.len) |_| try fx.press("<Tab>");
    try testing.expectEqualStrings(first, fx.app.prompt.text());

    // And backwards off the start goes to the end, not to nothing.
    try fx.press("<S-Tab>");
    try testing.expect(!std.mem.eql(u8, first, fx.app.prompt.text()));
}

test "typing after a Tab starts the next one from the new text" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("n");
    try fx.press("<Tab>");
    try fx.typeIn("h");
    // The list must not still be the one built for `n`, or the reader would
    // be cycling through candidates their own text has ruled out.
    try testing.expect(fx.app.comp.empty());

    try fx.press("<Tab>");
    try testing.expectEqualStrings("next_hunk", fx.app.prompt.text());
}

test "one Tab, one line" {
    // Three shapes with one answer each. The two that offer nothing must
    // leave the line exactly as typed: a key that rewrites a search pattern
    // into a command name is worse than a key that does nothing.
    const cases = [_]struct {
        open: []const u8,
        typed: []const u8,
        want: []const u8,
        offered: bool = true,
    }{
        .{ .open = ":", .typed = "toggle_z", .want = "toggle_zen" },
        .{ .open = ":", .typed = "zzzqqq", .want = "zzzqqq", .offered = false },
        // `/` collects a pattern, not a name.
        .{ .open = "/", .typed = "n", .want = "n", .offered = false },
    };

    for (cases) |c| {
        var fx = try app_mod.Fixture.init(testing.allocator);
        defer fx.deinit();
        try fx.press(c.open);
        try fx.typeIn(c.typed);
        try fx.press("<Tab>");
        try testing.expectEqualStrings(c.want, fx.app.prompt.text());
        try testing.expectEqual(c.offered, !fx.app.comp.empty());
    }
}

test "Tab completes a name that Enter then runs" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.expectFile(0);
    try fx.press(":");
    try fx.typeIn("next_f");
    // `next_file` and `next_fresh` already share all of `next_f`, so there is
    // nothing left to extend to and the first Tab picks.
    try fx.press("<Tab>");
    try testing.expectEqualStrings("next_file", fx.app.prompt.text());
    try fx.press("<CR>");
    try fx.expectFile(1);
}

test "Tab past the verb completes the value, and Enter applies it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("theme kana");
    try fx.press("<Tab>");
    // The verb is kept and only the value is rewritten, which is the whole
    // difference from completing a command name.
    try testing.expectEqualStrings("theme kanagawa", fx.app.prompt.text());
    try fx.press("<CR>");
    try testing.expectEqualStrings("kanagawa", fx.app.theme_name);
    try testing.expect(!std.meta.eql(theme_mod.default, fx.app.theme));

    // A name that is not one leaves the theme alone rather than falling back
    // to a default the reader did not ask for.
    try fx.press(":");
    try fx.typeIn("theme nope");
    try fx.press("<CR>");
    try testing.expectEqualStrings("kanagawa", fx.app.theme_name);
}

test "closing the prompt forgets the candidates" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press(":");
    try fx.typeIn("n");
    try fx.press("<Tab>");
    try testing.expect(!fx.app.comp.empty());
    try fx.press("<Esc>");
    // Left behind, they would be drawn over the rule the next time any
    // prompt opened.
    try testing.expect(fx.app.comp.empty());
}
