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
const frame_mod = @import("frame.zig");
const popup = @import("popup.zig");

pub const Frame = frame_mod.Frame;
pub const View = frame_mod.View;
pub const Range = frame_mod.Range;
pub const PromptView = frame_mod.PromptView;
pub const HelpView = frame_mod.HelpView;
pub const HelpLayout = frame_mod.HelpLayout;
pub const Theme = frame_mod.Theme;
pub const Glyphs = frame_mod.Glyphs;
pub const chrome_rows = frame_mod.chrome_rows;
pub const bodyHeight = frame_mod.bodyHeight;
pub const drawHelpPopup = popup.draw;

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
        return;
    }
    if (h < chrome_rows + 1) return drawTooSmall(f);

    try drawStatus(f, v, 0);
    f.put(1, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    try body_mod.draw(f, v, 2, bodyHeight(h, false));
    f.put(h - 2, 0, try f.rule(f.glyphs.rule, f.width()), f.theme.rule);
    if (v.prompt) |p| drawPrompt(f, p, h - 1) else try drawMode(f, v, h - 1);

    // Last, and over everything: it is a layer, not a pane.
    if (v.help) |hv| try popup.draw(f, hv, 2, bodyHeight(h, false));
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

fn drawStatus(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;
    const g = f.glyphs;

    var col: u16 = 1;
    col += try f.print(row, col, t.path, "{s}", .{v.file.path()});
    col += try f.print(row, col, t.dim, " {s} {d}/{d} {s} ", .{
        g.sep, v.file_index + 1, v.file_count, g.sep,
    });
    col += try f.print(row, col, t.added_count, "+{d}", .{v.file.added}) + 1;
    _ = try f.print(row, col, t.removed_count, "{s}{d}", .{ g.del, v.file.removed });

    // Right side: which hunk the cursor is in, out of how many in this file.
    if (v.rows.hunkAt(v.cursor)) |hi| {
        if (hi < v.file.hunks.len) {
            const right = try std.fmt.allocPrint(f.arena, "#{d} {s} {d}/{d} ", .{
                v.file.hunks[hi].id, g.sep, v.hunk_ordinal, v.total_hunks,
            });
            f.putRight(row, right, t.hunk_id);
        }
    }
}

fn drawMode(f: Frame, v: View, row: u16) Allocator.Error!void {
    const t = f.theme;

    var col: u16 = 1 + try f.print(row, 1, t.mode_badge, " {s} ", .{modeLabel(v.mode)}) + 2;

    // One slot, three claimants, in order of how much the reader needs it: a
    // torn read is a correctness warning, a notice answers the keystroke just
    // typed, and the row count is what fills the space when neither applies.
    const left: []const u8, const style = if (v.torn)
        .{ "file changed while reading, re-diffing", t.removed_count }
    else if (v.notice.len > 0)
        .{ v.notice, t.notice }
    else if (v.selection) |sel|
        .{ try std.fmt.allocPrint(f.arena, "{d} lines selected", .{sel.count()}), t.dim }
    else
        .{ try std.fmt.allocPrint(f.arena, "{d} rows", .{v.rows.len()}), t.dim };

    f.put(row, col, left, style);
    col += f.win.gwidth(left) + 2;

    const room = f.width() -| col -| 1;
    const fitted = fitHints(f, v.hints, room);
    if (fitted.len > 0) f.putRight(row, fitted, t.hint);
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

test "every mode has a label, including the ones v0.1 cannot reach" {
    // A mode with no label would render as an empty badge rather than fail.
    inline for (@typeInfo(event.Mode).@"enum".fields) |f| {
        const m: event.Mode = @enumFromInt(f.value);
        try testing.expect(modeLabel(m).len > 0);
    }
}
