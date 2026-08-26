// SPDX-License-Identifier: Apache-2.0
//
// Walking skeleton: proves the vaxis integration, the io/tty.zig writer
// boundary and 80-column layout before any real view exists. Delete once
// ui/view/diff.zig renders (docs/PLAN.md phase 5).

const std = @import("std");
const vaxis = @import("vaxis");
const tty_mod = @import("../io/tty.zig");
const metrics = @import("../io/metrics.zig");

pub const target_cols = 80;
const target_rows = 12;

/// Enters the alt screen, renders one frame, holds so the result is visible or
/// capturable, then restores the terminal. Holding rather than blocking on a
/// key keeps this runnable non-interactively.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    hold_ms: u64,
) !void {
    var term = try tty_mod.Tty.init(gpa, io, tty_mod.default_buffer_bytes);
    defer term.deinit();
    const w = term.writer();

    var vx = try vaxis.Vaxis.init(io, gpa, environ, .{ .kitty_keyboard_flags = .{} });
    defer vx.deinit(gpa, w);

    try vx.enterAltScreen(w);
    try w.flush();
    defer {
        vx.exitAltScreen(w) catch {};
        w.flush() catch {};
    }

    const ws = term.winsize() catch tty_mod.Winsize{
        .cols = target_cols,
        .rows = target_rows,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    try vx.resize(gpa, w, ws);

    // Cells reference this text rather than copying it, so it must outlive
    // render(). Per-frame row content belongs in the frame arena, which is
    // reset after render, never before (ARCHITECTURE.md 4).
    var ruler_buf: [512]u8 = undefined;
    const ruler = rulerInto(ruler_buf[0..@min(ws.cols, ruler_buf.len)]);

    const frame = metrics.span(.frame);
    const win = vx.window();
    win.clear();
    draw(win, ruler);

    const render_span = metrics.span(.render);
    try vx.render(w);
    render_span.end();

    // One flush per frame is the budget (PERFORMANCE.md 7.4).
    try w.flush();
    frame.end();

    std.Io.sleep(io, .fromMilliseconds(@intCast(hold_ms)), .awake) catch {};
}

const added: vaxis.Style = .{ .fg = .{ .index = 2 } };
const removed: vaxis.Style = .{ .fg = .{ .index = 1 } };
const meta: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true };
const dim: vaxis.Style = .{ .fg = .{ .index = 8 } };

/// A ruler makes an off-by-one at the right edge visible immediately, which is
/// the failure hard rule 9 exists to catch.
pub fn rulerInto(buf: []u8) []u8 {
    @memset(buf, '-');
    var i: usize = 9;
    while (i < buf.len) : (i += 10) buf[i] = '|';
    return buf;
}

fn draw(win: vaxis.Window, ruler: []const u8) void {
    row(win, 0, meta, "@@ #3  fn validate_token @@");
    row(win, 1, dim, "  41   let claims = decode(&t)?;");
    row(win, 2, removed, "- 46   if claims.exp < now() {");
    row(win, 3, added, "+ 47   if claims.exp <= now() {");
    row(win, 4, dim, "  48       return Err(Expired);");
    row(win, 6, dim, ruler);
    row(win, 7, dim, "The ruler above must end flush with the right edge.");
    row(win, 9, meta, "lgtm walking skeleton. Restores the terminal on exit.");
}

fn row(win: vaxis.Window, y: u16, style: vaxis.Style, text: []const u8) void {
    _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = y, .wrap = .none });
}

test "ruler spans exactly the requested width" {
    var buf: [target_cols]u8 = undefined;
    const ruler = rulerInto(&buf);
    try std.testing.expectEqual(@as(usize, target_cols), ruler.len);
    try std.testing.expectEqual(@as(u8, '|'), ruler[9]);
    try std.testing.expectEqual(@as(u8, '|'), ruler[79]);
    try std.testing.expectEqual(@as(u8, '-'), ruler[0]);
}

test "ruler adapts to narrow widths without overrun" {
    var buf: [40]u8 = undefined;
    const ruler = rulerInto(&buf);
    try std.testing.expectEqual(@as(usize, 40), ruler.len);
    try std.testing.expectEqual(@as(u8, '|'), ruler[39]);
}
