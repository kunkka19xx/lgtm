// SPDX-License-Identifier: Apache-2.0
//
// One frame of the unified diff view (mockup 2a): one status row, the diff
// body, one mode row. No persistent file list - files are reached with `]f`,
// which is what buys the body 22 of 26 rows instead of 17.
//
// This file is the chrome and the order things are drawn in. The body is
// `body.zig`, the `?` overlay is `popup.zig`, and what they all draw onto and
// from is `frame.zig`. The types are re-exported here because "the renderer"
// is one idea to everything above it, whatever it is split into underneath.

const std = @import("std");
const Allocator = std.mem.Allocator;

const event = @import("../core/event.zig");
const body_mod = @import("body.zig");
const motion = @import("motion.zig");
const frame_mod = @import("frame.zig");
const path_mod = @import("path.zig");
const popup = @import("popup.zig");

pub const Frame = frame_mod.Frame;
pub const View = frame_mod.View;
pub const Range = frame_mod.Range;
pub const Selection = frame_mod.Selection;
pub const PromptView = frame_mod.PromptView;
pub const HelpView = frame_mod.HelpView;
pub const HelpLayout = frame_mod.HelpLayout;
pub const Theme = frame_mod.Theme;
pub const Glyphs = frame_mod.Glyphs;
pub const chrome_rows = frame_mod.chrome_rows;
pub const bodyHeight = frame_mod.bodyHeight;
pub const drawHelpPopup = popup.draw;
pub const drawFileList = popup.drawFiles;

pub fn draw(f: Frame, v: View) Allocator.Error!void {
    f.win.clear();
    f.win.hideCursor();
    const h = f.win.height;
    if (h == 0 or f.width() < 20) return drawTooSmall(f);

    if (v.zen) {
        // No chrome at all, and no prompt either: `/` leaves zen rather than
        // drawing an input line with nothing to anchor it.
        try body_mod.draw(f, v, 0, h);
        if (v.help) |hv| try popup.draw(f, hv, 0, h);
        if (v.files) |fv| try popup.drawFiles(f, fv, 0, h);
        hideCursorUnder(f, v);
        return;
    }
    if (h < chrome_rows + 1) return drawTooSmall(f);

    try drawStatus(f, v, 0);
    f.put(1, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try body_mod.draw(f, v, 2, bodyHeight(h, false));
    f.put(h - 2, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    if (v.prompt) |p| drawPrompt(f, p, h - 1) else try drawMode(f, v, h - 1);

    // Last, and over everything: an overlay is a layer, not a pane. Only one
    // can be open, because each is its own mode.
    if (v.help) |hv| try popup.draw(f, hv, 2, bodyHeight(h, false));
    if (v.files) |fv| try popup.drawFiles(f, fv, 2, bodyHeight(h, false));
    hideCursorUnder(f, v);
}

/// The body parks the terminal cursor on the character under it. An overlay is
/// drawn over that character, so the cursor has to go with it - a block
/// blinking on top of the popup points at nothing.
fn hideCursorUnder(f: Frame, v: View) void {
    if (v.help != null or v.files != null) f.win.hideCursor();
}

/// The `/`, `?` or `:` line, with the terminal's own cursor parked at its end.
/// A real cursor rather than a drawn block: it blinks the way the user's
/// terminal blinks, and screen readers find it.
fn drawPrompt(f: Frame, p: PromptView, row: u16) void {
    f.put(row, 0, p.prefix, f.theme.prompt);
    const at = f.win.gwidth(p.prefix);
    f.put(row, at, p.text, f.theme.prompt);
    const col = at + f.win.gwidth(p.text);
    if (col < f.width()) f.win.showCursor(col, row);
}

fn modeLabel(mode: event.Mode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .visual => "VISUAL",
        .command => "COMMAND",
        .help => "HELP",
        .note_input => "NOTE",
        .finder => "FIND",
        .insert => "INSERT",
    };
}

/// Below this there is no honest layout, so say so instead of drawing a
/// corrupted one.
fn drawTooSmall(f: Frame) void {
    f.put(0, 0, "lgtm: window too small", f.theme.dim);
}

/// Columns the path keeps before a status field is dropped to pay for them,
/// and the floor below which nothing but the path is drawn at all.
const min_path = 16;
const min_name = 8;

fn drawStatus(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;
    const g = f.glyphs;

    // Which hunk the cursor is in, out of how many in the review.
    const right: []const u8 = blk: {
        const hi = v.rows.hunkAt(v.cursor) orelse break :blk "";
        if (hi >= v.file.hunks.len) break :blk "";
        break :blk try std.fmt.allocPrint(f.arena, "#{d} {s} {d}/{d} ", .{
            v.file.hunks[hi].id, g.sep, v.hunk_ordinal, v.total_hunks,
        });
    };
    const counter = try std.fmt.allocPrint(f.arena, " {s} {d}/{d}", .{
        g.sep, v.file_index + 1, v.file_count,
    });
    const bar = try std.fmt.allocPrint(f.arena, " {s} ", .{g.sep});
    const added = try std.fmt.allocPrint(f.arena, "+{d}", .{v.file.added});
    const removed = try std.fmt.allocPrint(f.arena, "{s}{d}", .{ g.del, v.file.removed });

    const counter_w = f.win.gwidth(counter);
    const counts_w = f.win.gwidth(bar) + f.win.gwidth(added) + 1 + f.win.gwidth(removed);

    const fit = statusFit(
        f.width(),
        if (right.len > 0) f.win.gwidth(right) + 1 else 0,
        counter_w,
        counts_w,
    );

    var col: u16 = 1;
    const shown = try path_mod.elide(f.arena, v.file.path(), fit.path, g.ellipsis, f.method());
    col += try f.print(row, col, t.path, "{s}", .{shown});
    if (fit.counter) {
        f.put(row, col, counter, t.dim);
        col += counter_w;
    }
    if (fit.counts) {
        f.put(row, col, bar, t.dim);
        col += f.win.gwidth(bar);
        f.put(row, col, added, t.added_count);
        col += f.win.gwidth(added) + 1;
        f.put(row, col, removed, t.removed_count);
    }
    if (fit.right and right.len > 0) f.putRight(row, right, t.hunk_id);
}

const StatusFit = struct {
    path: u16,
    right: bool = true,
    counter: bool = true,
    counts: bool = true,
};

/// Which status fields fit `total` columns, and what is left for the path.
///
/// The path is what names the file, so it is the field the others are dropped
/// for rather than the one that gets clipped by whatever is right-aligned over
/// it - which is what a 60-column pane used to do, silently eating `+3 −3` and
/// half the name with it. The hunk position goes first because `@@ #id` on the
/// header row below already says which hunk this is; the file counter next;
/// the change counts last, and only when even a bare name will not fit.
///
/// Pure, so hard rule 9 is checked at every width without a pane to draw in.
fn statusFit(total: u16, right_w: u16, counter_w: u16, counts_w: u16) StatusFit {
    // One leading column, always: a path flush against the edge reads as
    // clipped even when it is whole.
    var out: StatusFit = .{ .path = 0, .right = right_w > 0 };
    var used: u16 = 1 + right_w + counter_w + counts_w;
    if (total -| used < min_path) {
        out.right = false;
        used = 1 + counter_w + counts_w;
    }
    if (total -| used < min_path) {
        out.counter = false;
        used = 1 + counts_w;
    }
    if (total -| used < min_name) {
        out.counts = false;
        used = 1;
    }
    out.path = total -| used;
    return out;
}

fn drawMode(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;

    // The two visual modes share a `Mode` and are told apart by what is
    // selected, which is also the only place the difference matters.
    const label = if (v.mode == .visual and v.selection != null and v.selection.?.kind == .line)
        "VISUAL LINE"
    else
        modeLabel(v.mode);

    // Flush against the left edge: a leading space reads as the pill being
    // indented rather than as the bar starting there.
    var col: u16 = try f.print(row, 0, t.mode_badge, " {s} ", .{label});

    col += 2;

    // One slot, three claimants, in order of how much the reader needs it: a
    // torn read is a correctness warning, a notice answers the keystroke just
    // typed, and the row count is what fills the space when neither applies.
    const left: []const u8, const style = if (v.torn)
        .{ "file changed while reading, re-diffing", t.removed_count }
    else if (v.notice.len > 0)
        .{ v.notice, t.notice }
    else if (v.selection) |sel|
        .{ try selectionSize(f, v, sel), t.dim }
    else
        .{ try std.fmt.allocPrint(f.arena, "{d} rows", .{v.rows.len()}), t.dim };

    f.put(row, col, left, style);
    col += f.win.gwidth(left) + 2;

    const room = f.width() -| col -| 1;
    const fitted = fitHints(f, v.hints, room);
    if (fitted.len > 0) f.putRight(row, fitted, t.hint);
}

/// What the mode row says a selection is. Lines for a linewise one and for a
/// charwise one that has grown past a line; characters while it is still
/// inside one, because that is what the reader is choosing at that point.
fn selectionSize(f: Frame, v: View, sel: Selection) Allocator.Error![]const u8 {
    if (sel.kind == .char and sel.lo == sel.hi) {
        const text = v.rows.lineAt(sel.lo) orelse return f.arena.dupe(u8, "1 line selected");
        if (text >= v.file.lines.len()) return f.arena.dupe(u8, "1 line selected");
        const line = v.file.lines.text[text];
        const lo = @min(sel.lo_col, line.len);
        const hi = @min(sel.hi_col, line.len);
        const n = motion.graphemeCount(line[lo..hi]);
        return std.fmt.allocPrint(f.arena, "{d} character{s} selected", .{ n, if (n == 1) "" else "s" });
    }
    return std.fmt.allocPrint(f.arena, "{d} lines selected", .{sel.count()});
}

/// The longest prefix of the hint strip that fits `cols`.
///
/// Cut on the double space between hints, never mid-hint: "]f [f fi" advertises
/// a key that does not exist. Truncating rather than dropping the whole strip
/// is what keeps it visible at 80 columns, which is the width the layout is
/// designed for - and the strip outgrew that width the moment 5b added keys.
fn fitHints(f: Frame, hints: []const u8, cols: u16) []const u8 {
    if (hints.len == 0 or cols == 0) return "";
    if (f.win.gwidth(hints) <= cols) return hints;

    var cut: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, hints, at, "  ")) |sep| {
        if (f.win.gwidth(hints[0..sep]) > cols) break;
        cut = sep;
        at = sep + 2;
    }
    return hints[0..cut];
}

const testing = std.testing;

// The files this one is split into. Zig collects tests from a module only when
// something references it, so a split that forgets this line is a split that
// silently stops running two hundred lines of tests. See `app.zig`.
test {
    _ = body_mod;
    _ = frame_mod;
    _ = popup;
}

test "the status row drops fields rather than drawing them over the path" {
    // `path ▏ 1/2 ▏ +1 −1` with `#1 ▏ 1/2 ` right-aligned: 10, 6 and 8.
    const right: u16 = 10;
    const counter: u16 = 6;
    const counts: u16 = 8;

    // 80 columns is the pane the layout is designed for: everything fits.
    const wide = statusFit(80, right, counter, counts);
    try testing.expect(wide.right and wide.counter and wide.counts);
    try testing.expectEqual(@as(u16, 55), wide.path);

    // Narrow enough that the right block would eat the name, so it goes.
    const mid = statusFit(34, right, counter, counts);
    try testing.expect(!mid.right);
    try testing.expect(mid.counter and mid.counts);

    // Narrower still: the file counter follows it.
    const tight = statusFit(26, right, counter, counts);
    try testing.expect(!tight.right and !tight.counter);
    try testing.expect(tight.counts);

    // The change counts are last to go, so they survive the narrowest pane
    // that draws a layout at all - `+1 −1` is why the file is open.
    const tiny = statusFit(20, right, counter, counts);
    try testing.expect(tiny.counts);
    try testing.expectEqual(@as(u16, 11), tiny.path);

    // Below that there is no honest row, and the name is all that is left.
    try testing.expect(!statusFit(16, right, counter, counts).counts);
}

test "the status fields never claim more columns than the row has" {
    // The invariant the old layout broke: whatever is drawn has to fit
    // beside the path, at every width, with no field overwriting another.
    var total: u16 = 20;
    while (total <= 200) : (total += 1) {
        const fit = statusFit(total, 10, 6, 8);
        var used: u16 = 1 + fit.path;
        if (fit.right) used += 10;
        if (fit.counter) used += 6;
        if (fit.counts) used += 8;
        try testing.expect(used <= total);
        // And the path is never squeezed below what still names a file.
        try testing.expect(fit.path >= min_name);
    }

    // No hunk under the cursor is a right block of nothing, not a gap held
    // open for one.
    const none = statusFit(40, 0, 6, 8);
    try testing.expect(!none.right);
    try testing.expectEqual(@as(u16, 25), none.path);
}

test "every mode has a label, including the ones v0.1 cannot reach" {
    // A mode with no label would render as an empty badge rather than fail.
    inline for (@typeInfo(event.Mode).@"enum".fields) |f| {
        const m: event.Mode = @enumFromInt(f.value);
        try testing.expect(modeLabel(m).len > 0);
    }
}
