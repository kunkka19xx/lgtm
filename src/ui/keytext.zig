// SPDX-License-Identifier: Apache-2.0
//
// How keys are *written*: the spelling of a chord sequence in both directions,
// the status-line hint strip, and the rows of the `?` overlay.
//
// Split from `keymap.zig`, which is about what keys mean. Everything here is
// text a human reads or types - `<Space>nf` in a config file, `]h [h hunk` in
// the status row, `<C-d>  down half a page` in the popup - and all of it is
// generated from the bindings rather than written out beside them, so a
// remapped key moves everywhere at once (FEATURES.md 4.3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("../core/event.zig");
const fuzzy = @import("fuzzy.zig");
const keymap = @import("keymap.zig");

const Binding = keymap.Binding;
const Chord = keymap.Chord;
const Keymap = keymap.Keymap;
const c = keymap.chord;
const leader = keymap.leader;
const default_bindings = keymap.default_bindings;

// -- spelling a sequence -------------------------------------------------

/// Renders a chord sequence the way a user would type it - `gg`, `<C-d>`,
/// `<Space>nf` - into `arena`, in practice the frame arena. Built from the
/// chords rather than written out beside them, so a remapped keymap describes
/// its own keys instead of the defaults (FEATURES.md 4.4).
pub fn writeChords(chords: []const Chord, arena: Allocator) Allocator.Error![]const u8 {
    var buf: [max_keys_bytes]u8 = undefined;
    return arena.dupe(u8, bufWriteChords(chords, &buf));
}

/// Longest a rendered sequence can be: `max_sequence` chords of `<Space>`.
pub const max_keys_bytes = max_sequence_bytes * Keymap.max_sequence;

/// Room for every spelling of one action on a single overlay row, separators
/// included. The most any command carries is the two forms of a motion plus
/// the list bindings' arrow and letter, so four sequences is slack rather than
/// a limit.
pub const max_row_keys_bytes = max_keys_bytes * 4 + row_keys_sep.len * 4;

/// What sits between two spellings of the same action. A space alone left
/// `]h <Space>nh` reading as one four-token key rather than two spellings of
/// one action, which is the confusion the merged row was supposed to remove.
pub const row_keys_sep = " / ";
const max_sequence_bytes = 8;

/// The allocation-free core of `writeChords`, so the same rendering feeds both
/// the drawn list and the filter that narrows it.
pub fn bufWriteChords(chords: []const Chord, buf: []u8) []const u8 {
    var n: usize = 0;
    for (chords) |ch| {
        var tmp: [max_sequence_bytes]u8 = undefined;
        const piece: []const u8 = if (ch.ctrl)
            std.fmt.bufPrint(&tmp, "<C-{u}>", .{ch.cp}) catch "<C-?>"
        else if (ch.shift) switch (ch.cp) {
            event.code.tab => "<S-Tab>",
            else => std.fmt.bufPrint(&tmp, "<S-{u}>", .{ch.cp}) catch "<S-?>",
        } else switch (ch.cp) {
            event.code.escape => "<Esc>",
            event.code.tab => "<Tab>",
            event.code.enter => "<CR>",
            event.code.backspace => "<BS>",
            // The arrows are kitty functional keycodes in a private-use area:
            // encoded as UTF-8 they render as nothing at all, so a name is the
            // only thing that shows up in the popup's own header.
            event.code.up => "<Up>",
            event.code.down => "<Down>",
            event.code.left => "<Left>",
            event.code.right => "<Right>",
            ' ' => "<Space>",
            else => tmp[0 .. std.unicode.utf8Encode(ch.cp, &tmp) catch 0],
        };
        if (n + piece.len > buf.len) break;
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
    }
    return buf[0..n];
}

pub const KeyParseError = error{
    /// `<`, with no `>` or no name inside it that means anything.
    BadKeyName,
    /// Longer than `Keymap.max_sequence`, which the matcher cannot hold.
    TooManyChords,
};

/// The inverse of `bufWriteChords`: turns `gg`, `<C-d>` or `<Space>nf` back
/// into chords, so a config file can name a key the same way the `?` popup
/// prints it. Written next to its inverse, and pinned to it by a round-trip
/// test over every default binding - the failure mode otherwise is a key the
/// help advertises in a spelling the config refuses to read.
///
/// An empty sequence is not an error: it is how `[keys]` unbinds a command.
pub fn parseChords(text: []const u8, out: []Chord) KeyParseError![]Chord {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (n == out.len) return error.TooManyChords;
        if (text[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return error.BadKeyName;
            out[n] = try namedChord(text[i + 1 .. end]);
            i = end + 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.BadKeyName;
            if (i + len > text.len) return error.BadKeyName;
            out[n] = .{ .cp = std.unicode.utf8Decode(text[i..][0..len]) catch return error.BadKeyName };
            i += len;
        }
        n += 1;
    }
    return out[0..n];
}

/// The `<...>` names. Ctrl chords lower-case their letter, because that is
/// what the terminal reports for `<C-D>` as well as `<C-d>`, and a binding
/// that only matches the spelling it was written in is a trap.
fn namedChord(name: []const u8) KeyParseError!Chord {
    if (name.len == 3 and std.ascii.toLower(name[0]) == 'c' and name[1] == '-') {
        return .{ .cp = std.ascii.toLower(name[2]), .ctrl = true };
    }
    const eq = std.ascii.eqlIgnoreCase;
    // Shift is only meaningful on a named key: on a character the shift is
    // the character, and `<S-v>` would be a second spelling of `V` that the
    // matcher could never see.
    if (name.len > 2 and std.ascii.toLower(name[0]) == 's' and name[1] == '-') {
        if (eq(name[2..], "Tab")) return .{ .cp = event.code.tab, .shift = true };
        return error.BadKeyName;
    }
    if (eq(name, "Space")) return c(' ');
    if (eq(name, "Esc") or eq(name, "Escape")) return c(event.code.escape);
    if (eq(name, "Tab")) return c(event.code.tab);
    if (eq(name, "CR") or eq(name, "Enter")) return c(event.code.enter);
    if (eq(name, "BS") or eq(name, "Backspace")) return c(event.code.backspace);
    if (eq(name, "Up")) return c(event.code.up);
    if (eq(name, "Down")) return c(event.code.down);
    if (eq(name, "Left")) return c(event.code.left);
    if (eq(name, "Right")) return c(event.code.right);
    if (eq(name, "lt")) return c('<');
    return error.BadKeyName;
}

// -- the status-line hint strip ------------------------------------------

/// The hint strip, rendered from the bindings themselves so it cannot drift
/// from what the keys actually do - a remapped key moves here as well as in
/// the `?` popup. Bindings that share a label share an entry, so `]f` and
/// `[f` come out as one `]f [f file` rather than two entries saying the same
/// word twice. Written into `buf`, which the caller owns - in practice the
/// frame arena.
pub fn hints(bindings: []const Binding, mode: event.Mode, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bindings, 0..) |b, i| {
        if (!b.modes.has(mode)) continue;
        const label = b.hint orelse continue;
        // Each label is written once, at its first binding; the rest of the
        // group is gathered below rather than starting an entry of its own.
        if (firstWith(bindings[0..i], mode, label)) continue;

        // Measured whole, then copied, so a strip that runs out of room ends
        // on an entry boundary. "]f [f fi" advertises a key that does not
        // exist, which is worse than one entry fewer.
        var entry: [max_keys_bytes * 4 + 32]u8 = undefined;
        var e: usize = 0;
        for (bindings[i..]) |g| {
            if (!g.modes.has(mode)) continue;
            const gl = g.hint orelse continue;
            if (!std.mem.eql(u8, gl, label)) continue;
            if (e != 0 and e < entry.len) {
                entry[e] = ' ';
                e += 1;
            }
            // A binding that says how it is typed says it here; everything
            // else renders its chords, so a remap still moves the strip.
            if (g.hint_keys) |k| {
                if (e + k.len > entry.len) continue;
                @memcpy(entry[e..][0..k.len], k);
                e += k.len;
            } else {
                const keys = bufWriteChords(g.chords, entry[e..]);
                e += keys.len;
            }
        }
        if (e + 1 + label.len > entry.len) continue;
        entry[e] = ' ';
        e += 1;
        @memcpy(entry[e..][0..label.len], label);
        e += label.len;

        const sep: usize = if (n == 0) 0 else 2;
        if (n + sep + e > buf.len) break;
        if (sep != 0) {
            buf[n] = ' ';
            buf[n + 1] = ' ';
            n += 2;
        }
        @memcpy(buf[n..][0..e], entry[0..e]);
        n += e;
    }
    return buf[0..n];
}

/// Whether `label` was already claimed by an earlier binding live in `mode`.
fn firstWith(before: []const Binding, mode: event.Mode, label: []const u8) bool {
    for (before) |p| {
        if (!p.modes.has(mode)) continue;
        const h = p.hint orelse continue;
        if (std.mem.eql(u8, h, label)) return true;
    }
    return false;
}

// -- the rows of the `?` overlay -----------------------------------------

/// One row of the `?` overlay: the keys as the user would type them, and what
/// they do.
pub const HelpEntry = struct {
    keys: []const u8,
    desc: []const u8,
};

/// Whether `b` belongs in the popup for `mode` under `filter`, and how well it
/// matched. One predicate, used by both `helpEntries` and `helpCount`.
/// Every spelling of `cmd` that `mode` can reach, joined: `]f <Space>nf`.
///
/// The overlay lists one row per *action*, not one per binding. Two rows for
/// the same command read as two commands, and the reader stops to work out
/// what the difference is - there is none, which is the worst answer to have
/// invited.
fn keysFor(bindings: []const Binding, cmd: keymap.Command, mode: event.Mode, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bindings) |b| {
        if (b.command != cmd or !b.modes.has(mode)) continue;
        if (n != 0 and n + row_keys_sep.len <= buf.len) {
            @memcpy(buf[n..][0..row_keys_sep.len], row_keys_sep);
            n += row_keys_sep.len;
        }
        n += bufWriteChords(b.chords, buf[n..]).len;
    }
    return buf[0..n];
}

fn ranked(bindings: []const Binding, b: Binding, mode: event.Mode, group: ?keymap.Group, filter: []const u8, kbuf: []u8) ?struct { keys: []const u8, desc: []const u8, tier: fuzzy.Tier } {
    if (!b.modes.has(mode)) return null;
    // A group narrows; null means every group, which is what a filter asks
    // for - finding a key must not require knowing which tab it is filed
    // under.
    if (group) |g| if (b.group != g) return null;
    // An alias carries no description, so the row its command already has is
    // the one its keys were gathered onto.
    const d = b.desc orelse return null;
    const keys = keysFor(bindings, b.command, mode, kbuf);
    // The filter runs over the keys as well as the description, so `spc` finds
    // the leader bindings and `ctrl` does not have to be spelled `<C-`.
    var hay: [max_row_keys_bytes + 128]u8 = undefined;
    const text = std.fmt.bufPrint(&hay, "{s} {s}", .{ keys, d }) catch keys;
    const tier = fuzzy.match(text, filter) orelse return null;
    return .{ .keys = keys, .desc = d, .tier = tier };
}

/// How many rows the popup will have. Lets the selection be clamped without
/// laying the list out first.
/// How many rows `helpEntries` will produce, without building them.
///
/// It has to agree with the list exactly: this is what clamps the selection,
/// and a count that ran ahead of the list would let the highlight sit past the
/// end of what is drawn. So it walks the same two tiers in the same order and
/// applies the same `joins` rule - allocation-free, because `help.zig` asks on
/// every navigation keystroke and has no arena to hand.
/// Keys that belong to the compose box, not to the review.
///
/// They are not bindings: the box reads keys directly, the way `prompt.zig`
/// does, so there is nothing in the keymap for the popup to find. But a reader
/// looking for "how do I ask a question" looks in `?`, and finding nothing
/// there is how a feature goes unused - which is exactly what happened when
/// the four ask keys retired and took the only visible trace of presets with
/// them. Listed under `send`, because that is the tab the box belongs to.
///
/// The same rows the box draws along its own bottom border, so the two cannot
/// disagree about what its keys are.
pub const compose_rows: []const HelpEntry = &.{
    .{ .keys = "<C-i>", .desc = "in the box: insert a preset at the caret" },
    .{ .keys = "@", .desc = "in the box: mention a file" },
    .{ .keys = "<Esc>", .desc = "in the box: normal mode - o opens a line" },
    .{ .keys = "<S-CR> <C-j>", .desc = "in the box: a line break, joined on send" },
};

/// The compose rows this filter and group keep, appended to whatever the
/// bindings produced. One helper, so the list and the count agree.
fn composeShown(mode: event.Mode, group: ?keymap.Group, filter: []const u8, out: ?*std.ArrayList(HelpEntry), arena: ?Allocator) Allocator.Error!usize {
    // Only where the review's own keys are live. Inside the box the popup
    // cannot be opened at all, and in a list of visual-mode keys these would
    // be four rows about somewhere the reader is not.
    if (mode != .normal) return 0;
    if (group) |g| if (g != .send) return 0;

    var n: usize = 0;
    for (compose_rows) |r| {
        var hay: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&hay, "{s} {s}", .{ r.keys, r.desc }) catch r.keys;
        if (fuzzy.match(text, filter) == null) continue;
        n += 1;
        if (out) |list| try list.append(arena.?, r);
    }
    return n;
}

pub fn helpCount(bindings: []const Binding, mode: event.Mode, group: ?keymap.Group, filter: []const u8) usize {
    var n: usize = 0;
    for ([_]fuzzy.Tier{ .solid, .loose }) |tier| {
        var open: ?[]const u8 = null;
        var width: usize = 0;
        var kbuf: [max_row_keys_bytes]u8 = undefined;
        for (bindings) |b| {
            const r = ranked(bindings, b, mode, group, filter, &kbuf) orelse continue;
            if (r.tier != tier) continue;
            const row: HelpEntry = .{ .keys = r.keys, .desc = r.desc };
            if (open) |d| {
                if (joins(d, width, row)) {
                    width += 1 + row.keys.len;
                    continue;
                }
            }
            n += 1;
            open = r.desc;
            width = row.keys.len;
        }
    }
    return n + (composeShown(mode, group, filter, null, null) catch 0);
}

/// Whether a row joins the one already open. The single place the merge rule
/// lives: `mergeByDesc` builds the list with it and `helpCount` counts with
/// it, so the two cannot drift into disagreeing about how many rows there are.
fn joins(open_desc: []const u8, open_width: usize, next: HelpEntry) bool {
    return std.mem.eql(u8, open_desc, next.desc) and
        open_width + 1 + next.keys.len <= max_merged_keys;
}

pub fn helpEntries(
    bindings: []const Binding,
    mode: event.Mode,
    group: ?keymap.Group,
    filter: []const u8,
    arena: Allocator,
) Allocator.Error![]const HelpEntry {
    var solid: std.ArrayList(HelpEntry) = .empty;
    var loose: std.ArrayList(HelpEntry) = .empty;
    var kbuf: [max_row_keys_bytes]u8 = undefined;
    for (bindings) |b| {
        const r = ranked(bindings, b, mode, group, filter, &kbuf) orelse continue;
        const entry: HelpEntry = .{ .keys = try arena.dupe(u8, r.keys), .desc = r.desc };
        // Two tiers rather than a score: a run of the query as typed comes
        // first, scattered letters after. Without this, "file" pulls up
        // "gg first line" alongside "next file" and the list reads as noise.
        switch (r.tier) {
            .solid => try solid.append(arena, entry),
            .loose => try loose.append(arena, entry),
        }
    }
    try solid.appendSlice(arena, loose.items);
    var rows: std.ArrayList(HelpEntry) = .empty;
    try rows.appendSlice(arena, try mergeByDesc(arena, solid.items));
    _ = try composeShown(mode, group, filter, &rows, arena);
    return rows.toOwnedSlice(arena);
}

/// Neighbouring rows that say the same thing become one row with both keys.
///
/// The same rule the footer already uses, applied to the list: `j` and `k` are
/// one idea, and two rows reading "down a line" and "up a line" spend two rows
/// saying so. The `move` group was 22 rows - most of a pane - and half of them
/// were the other half with a word changed.
///
/// Adjacent only, and only within a tier. Bindings that belong together are
/// written together in the keymap, so adjacency *is* the relationship; pulling
/// same-description rows together from opposite ends of the list would invent
/// one that is not there.
///
/// And only while the joined keys stay narrow. `]h / <Space>nh [h / <Space>ph`
/// is one row that has swallowed the description column - past
/// `max_merged_keys` two short rows read better than one wide one, which is
/// the whole point of merging in the first place.
const max_merged_keys = 12;

fn mergeByDesc(arena: Allocator, rows: []const HelpEntry) Allocator.Error![]const HelpEntry {
    var out: std.ArrayList(HelpEntry) = .empty;
    var i: usize = 0;
    while (i < rows.len) {
        var last = i;
        var width = rows[i].keys.len;
        while (last + 1 < rows.len and joins(rows[i].desc, width, rows[last + 1])) {
            width += 1 + rows[last + 1].keys.len;
            last += 1;
        }
        if (last == i) {
            try out.append(arena, rows[i]);
        } else {
            var keys: std.ArrayList(u8) = .empty;
            for (rows[i .. last + 1], 0..) |r, n| {
                if (n > 0) try keys.append(arena, ' ');
                try keys.appendSlice(arena, r.keys);
            }
            try out.append(arena, .{ .keys = try keys.toOwnedSlice(arena), .desc = rows[i].desc });
        }
        i = last + 1;
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

/// A ctrl chord, for the tests below. `keymap.chord` covers the plain case.
fn ctrl(cp: u21) Chord {
    return .{ .cp = cp, .ctrl = true };
}

test "hints come from the bindings and fit the width given" {
    var buf: [80]u8 = undefined;
    const h = hints(default_bindings, .normal, &buf);
    // The strip is two entries by design: how to leave, and where everything
    // else is written down. Every other key lives in the `?` popup, which is
    // the one the strip points at.
    try testing.expectEqualStrings(":q quit  ? help", h);

    // A narrow strip truncates on a boundary rather than overrunning.
    var tiny: [10]u8 = undefined;
    const t = hints(default_bindings, .normal, &tiny);
    try testing.expect(t.len <= tiny.len);
    try testing.expectEqualStrings(":q quit", t);
}

test "the hint strip advertises only what the current mode can do" {
    var buf: [160]u8 = undefined;
    const normal = hints(default_bindings, .normal, &buf);
    // Nothing about leaving a selection you are not in.
    try testing.expectEqualStrings(":q quit  ? help", normal);

    var buf2: [160]u8 = undefined;
    const visual = hints(default_bindings, .visual, &buf2);
    // Escape comes first because it is the way out of the mode you are in.
    // Spelled the way the popup spells it, because both render the same
    // chords rather than each carrying its own hand-written text.
    try testing.expectEqualStrings("<Esc> cancel  :q quit  ? help", visual);
}

test "every default binding parses back from the way the popup spells it" {
    // `bufWriteChords` and `parseChords` are inverses, and a config file names
    // keys in the spelling the `?` popup shows. If they ever disagree, the
    // user reads a key off the overlay, puts it in `[keys]`, and it is
    // rejected - which is the kind of thing that gets found by a user.
    var buf: [max_keys_bytes]u8 = undefined;
    var out: [Keymap.max_sequence]Chord = undefined;
    for (default_bindings) |b| {
        const text = bufWriteChords(b.chords, &buf);
        const back = try parseChords(text, &out);
        try testing.expectEqual(b.chords.len, back.len);
        for (b.chords, back) |want, got| {
            try testing.expectEqual(want.cp, got.cp);
            try testing.expectEqual(want.ctrl, got.ctrl);
        }
    }
}

test "key names a user might reasonably write" {
    var out: [Keymap.max_sequence]Chord = undefined;

    // Case-insensitive names, and `<C-D>` is the same key the terminal sends
    // for `<C-d>`.
    const upper = try parseChords("<C-D>", &out);
    try testing.expectEqual(@as(u21, 'd'), upper[0].cp);
    try testing.expect(upper[0].ctrl);

    var out2: [Keymap.max_sequence]Chord = undefined;
    const seq = try parseChords("<space>nf", &out2);
    try testing.expectEqual(@as(usize, 3), seq.len);
    try testing.expectEqual(@as(u21, ' '), seq[0].cp);

    // Empty is not an error: it is how a command is unbound.
    var out3: [Keymap.max_sequence]Chord = undefined;
    try testing.expectEqual(@as(usize, 0), (try parseChords("", &out3)).len);

    // A name that means nothing, and a sequence longer than the matcher can
    // hold, are both refused rather than silently truncated.
    try testing.expectError(error.BadKeyName, parseChords("<Meta-x>", &out3));
    try testing.expectError(error.BadKeyName, parseChords("<C-d", &out3));
    try testing.expectError(error.TooManyChords, parseChords("abcde", &out3));
}

test "a remapped key moves in the hint strip too" {
    // The strip used to carry its own text - `"]f [f file"` written out beside
    // the binding - so a config that rebound `next_file` left the status line
    // advertising a key that no longer did anything. Rendering the chords is
    // what makes that impossible.
    const remapped: []const Binding = &.{
        .{ .chords = &.{ c(']'), c('w') }, .command = .next_file, .hint = "file", .desc = "next file" },
        .{ .chords = &.{ c('['), c('f') }, .command = .prev_file, .hint = "file", .desc = "previous file" },
        .{ .chords = &.{c('Q')}, .command = .quit, .hint = "quit", .desc = "quit" },
    };
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("]w [f file  Q quit", hints(remapped, .normal, &buf));
}

test "chords render the way a user would type them" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    try testing.expectEqualStrings("j", try writeChords(&.{c('j')}, arena));
    try testing.expectEqualStrings("gg", try writeChords(&.{ c('g'), c('g') }, arena));
    try testing.expectEqualStrings("<C-d>", try writeChords(&.{ctrl('d')}, arena));
    try testing.expectEqualStrings("<Esc>", try writeChords(&.{c(event.code.escape)}, arena));
    try testing.expectEqualStrings("<Tab>", try writeChords(&.{c(event.code.tab)}, arena));
    // Named, not encoded: these codepoints sit in a private-use area and draw
    // as nothing, so an unnamed arrow would be an invisible row in the popup.
    try testing.expectEqualStrings("<Down>", try writeChords(&.{c(event.code.down)}, arena));
    try testing.expectEqualStrings("<Left>", try writeChords(&.{c(event.code.left)}, arena));
    try testing.expectEqualStrings("<Space>nf", try writeChords(&.{ leader, c('n'), c('f') }, arena));
}

test "the overlay lists the mode it was opened from, aliases excluded" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const normal = try helpEntries(default_bindings, .normal, null, "", arena);
    var saw_quit = false;
    var saw_leader = false;
    for (normal) |e| {
        // The visual-only Escape is not a normal-mode key and must not be listed.
        try testing.expect(!std.mem.eql(u8, e.desc, "leave visual select"));
        // Quitting is `:q`, so the overlay lists the key that opens it.
        if (std.mem.eql(u8, e.keys, ":")) saw_quit = true;
        // The leader form shares a row with the bracket form it duplicates.
        if (std.mem.eql(u8, e.keys, "]f / <Space>nf")) saw_leader = true;
    }
    try testing.expect(saw_quit);
    try testing.expect(saw_leader);
}

test "the filter narrows the overlay, run matches before scattered ones" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const all = try helpEntries(default_bindings, .normal, null, "", arena);
    const some = try helpEntries(default_bindings, .normal, null, "file", arena);
    try testing.expect(some.len < all.len);
    try testing.expect(some.len > 0);

    // "file" is a run in "next file" and only scattered letters in "first
    // line", so the runs come first or the list reads as noise.
    try testing.expect(std.mem.indexOf(u8, some[0].desc, "file") != null);

    // The filter reaches the keys too, so the leader bindings are findable by
    // the name a user would type for them.
    const leader_hits = try helpEntries(default_bindings, .normal, null, "space", arena);
    var leaders: usize = 0;
    for (leader_hits) |e| {
        if (std.mem.indexOf(u8, e.keys, "<Space>") != null) leaders += 1;
    }
    // Actions, not bindings: a row carries both spellings where there are two,
    // so the leader form is inside the keys rather than at the front of them.
    try testing.expectEqual(@as(usize, 13), leaders);
    // The rows that actually contain the query come first, which is the whole
    // point of the two tiers - the scattered-letter matches a query like this
    // also drags in sit behind them rather than among them.
    for (leader_hits[0..leaders]) |e| try testing.expect(std.mem.indexOf(u8, e.keys, "<Space>") != null);

    const none = try helpEntries(default_bindings, .normal, null, "zzzz", arena);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "the popup's own keys collapse to one label in its footer" {
    // The footer joins *runs* of entries that share a description, which is
    // what turns four bindings into `J K move  H L tab`. That only works
    // while the ones sharing a word are adjacent in the table, so the pairs
    // are ordered rather than interleaved.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    const own = try helpEntries(default_bindings, .help, null, "", a.allocator());
    try testing.expectEqual(@as(usize, 4), own.len);
    try testing.expectEqualStrings("move", own[0].desc);
    try testing.expectEqualStrings("move", own[1].desc);
    // Sideways says something different now: it changes tab in the `?`
    // overlay rather than moving within one list.
    try testing.expectEqualStrings("tab", own[2].desc);
    try testing.expectEqualStrings("tab", own[3].desc);
    // Each row carries every spelling of its action; the footer prints only
    // the first, which is what keeps the label short.
    try testing.expectEqualStrings("J / <Down> / <C-n> / <Tab>", own[0].keys);
    try testing.expectEqualStrings("L / <Right>", own[3].keys);
}

test "the count and the list agree, whatever the filter" {
    // They are what clamps the selection and what draws it. If they can
    // disagree, the highlight can sit past the end of the visible list.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    for ([_][]const u8{ "", "file", "next", "spc", "zzzz", "<C-" }) |q| {
        const list = try helpEntries(default_bindings, .normal, null, q, arena);
        try testing.expectEqual(list.len, helpCount(default_bindings, .normal, null, q));
    }
}

test "every advertised key also explains itself in the overlay" {
    // A key in the hint strip with no description would appear in the status
    // line and then be missing from `?`, which is where a user goes to look
    // it up.
    for (default_bindings) |b| {
        if (b.hint != null) try testing.expect(b.desc != null);
    }
}
