// SPDX-License-Identifier: Apache-2.0
//
// The run loop, and everything that owns the terminal: the vaxis screen, the
// input and watch threads, one frame per drained batch, and the handover to
// `$EDITOR`. `ui/app.zig` holds the state and decides what a key means; this
// file is what a key means *to a terminal*.
//
// Splitting them is what makes the state testable without one. Nothing here
// has a unit test, by construction - it is threads, a tty and a child process
// - and nothing in `app.zig` needs a tty, which is where the tests are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const event = @import("../core/event.zig");
const input = @import("../io/input.zig");
const metrics = @import("../io/metrics.zig");
const proc = @import("../io/proc.zig");
const tty_mod = @import("../io/tty.zig");
const watch = @import("../io/watch.zig");

const config = @import("../config.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const editor = @import("editor.zig");
const keytext = @import("keytext.zig");
const render = @import("render.zig");
const theme_mod = @import("theme.zig");

pub const Options = struct {
    /// Render one frame and exit. What CI and a screenshot need, and the only
    /// way to exercise the render path without a human at a keyboard.
    once: bool = false,
    /// Everything the config file decided. Defaults throughout when there is
    /// no file, which is the case this has to stay fast for.
    cfg: config.Config = .{},
    /// The one line of the config's complaints the status row has space for,
    /// or null when it had none. Shown as a notice on the first frame: a
    /// config error belongs in the status line, never in a refusal to start
    /// (FEATURES.md 4.9).
    problems: ?[]const u8 = null,
};

/// Runs the review UI until the user quits.
pub fn run(gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map, opts: Options) !void {
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

    var queue = event.Queue.init(gpa, io);
    defer queue.deinit();

    var app = App.init(gpa, io, &queue);
    defer app.deinit();
    app.nav = opts.cfg.nav;
    app.km.bindings = opts.cfg.keys;
    app.theme = opts.cfg.theme;
    app.glyphs = switch (opts.cfg.ui.icons) {
        .unicode => theme_mod.Glyphs.unicode,
        .ascii => theme_mod.Glyphs.ascii,
    };
    // Said once, on the first frame, and cleared by the first keystroke like
    // any other notice - long enough to read, and not a modal the user has to
    // dismiss before reviewing anything.
    if (opts.problems) |p| app.notice.set("config: {s}", .{p});

    var reader = input.Reader.init(&term, &queue);
    var winsize: input.WinsizeNotifier = .{ .tty = &term, .queue = &queue };
    // The reader services SIGWINCH on its own wake, because the handler is
    // only allowed to set a flag - see `io/input.zig`.
    reader.winsize = &winsize;
    var watcher = watch.Watcher.init(gpa, io, &queue, .{});
    if (!opts.once) {
        winsize.register() catch {};
        try reader.start();
        watcher.start() catch {};
    }
    defer {
        if (!opts.once) {
            // Before the reader stops, so the last thing to touch the flag is
            // gone by the time this frame is.
            winsize.unregister();
            reader.stop();
        }
        // `deinit`, not `stop`: stopping only joins the thread. The poller
        // still holds a duped path per watched file in `prev` and `pending`,
        // and those are what a leak check sees on exit. Unconditional because
        // deinit of a watcher that never started is a no-op.
        watcher.deinit();
    }

    // Sized once here and again only when a resize event says so. Calling
    // `vx.resize` per frame reallocates both screen buffers and throws away
    // `screen_last` - which is the damage-tracking baseline - so every
    // keystroke repainted every cell. That is what a flickering terminal is.
    var ws = term.winsize() catch tty_mod.Winsize{ .cols = 80, .rows = 26, .x_pixel = 0, .y_pixel = 0 };
    try vx.resize(gpa, w, ws);

    try app.rediff();

    while (!app.quit) {
        app.clampScroll(render.bodyHeight(ws.rows, app.zen));

        try drawFrame(&app, &vx, w);
        if (opts.once) break;

        const events = try queue.drain(gpa);
        defer gpa.free(events);
        if (events.len == 0) break; // queue closed

        for (events) |ev| {
            if (ev == .resize) {
                ws = .{ .cols = ev.resize.cols, .rows = ev.resize.rows, .x_pixel = 0, .y_pixel = 0 };
                try vx.resize(gpa, w, ws);
            }
            try app.handle(ev, render.bodyHeight(ws.rows, app.zen));
        }

        if (app.want_editor) {
            app.want_editor = false;
            try openEditor(&app, &vx, &term, w, environ, &reader, opts);
            // The screen belongs to the editor until it exits; nothing vaxis
            // drew is still on it, so the damage baseline is a lie.
            vx.queueRefresh();
        }
    }
}

/// Hands the terminal to `$EDITOR` and takes it back.
///
/// Order matters in both directions and every step has a failure that looks
/// like a hang if it is skipped: stop reading input (or the reader and the
/// editor race for keystrokes), leave the alt screen (or the editor draws over
/// the diff), restore the shell's termios (or the editor starts with no echo).
/// Coming back is the same list reversed, and it runs even when the spawn
/// failed - a `lgtm` that returns to a raw terminal is one the user has to
/// `reset`.
fn openEditor(
    app: *App,
    vx: *vaxis.Vaxis,
    term: *tty_mod.Tty,
    w: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    reader: *input.Reader,
    opts: Options,
) !void {
    const target = app.editTarget() orelse {
        app.notice.set("nothing here to open", .{});
        return;
    };

    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const spec = editor.specFrom(environ);
    const argv = try editor.argv(scratch.allocator(), spec, target.path, target.line) orelse {
        app.notice.set("$EDITOR is empty", .{});
        return;
    };

    // Where the read cannot be interrupted, the reader would keep the tty and
    // eat the editor's input. Refusing is the honest outcome; silently opening
    // an editor that ignores half the keystrokes is not.
    if (!opts.once and !reader.pollable) {
        app.notice.set("cannot suspend input on this terminal", .{});
        return;
    }

    if (!opts.once) reader.stop();
    vx.exitAltScreen(w) catch {};
    w.flush() catch {};
    term.suspendRaw();

    const code = proc.runInherit(app.io, argv) catch |err| blk: {
        app.notice.set("{s}: {t}", .{ spec, err });
        break :blk @as(u8, 0);
    };

    term.resumeRaw();
    vx.enterAltScreen(w) catch {};
    w.flush() catch {};
    if (!opts.once) try reader.start();

    if (code != 0 and app.notice.len == 0) {
        app.notice.set("{s} exited with {d}", .{ spec, code });
    }
    // The user very likely changed the file, and the watcher may or may not
    // have seen it while we were not draining events.
    try app.rediff();
}

fn frameOf(app: *App, win: vaxis.Window, arena: Allocator) render.Frame {
    return .{ .win = win, .arena = arena, .theme = app.theme, .glyphs = app.glyphs };
}

fn drawFrame(app: *App, vx: *vaxis.Vaxis, w: *std.Io.Writer) !void {
    const frame = metrics.span(.frame);
    defer frame.end();

    const arena = app.frame_arena.allocator();
    const win = vx.window();

    if (app.view()) |v| {
        var shown = v;
        var hint_buf: [256]u8 = undefined;
        shown.hints = try arena.dupe(u8, keytext.hints(app.km.bindings, app.mode, &hint_buf));
        shown.help = try app.help.view(app.mode, app.km.bindings, arena);
        shown.files = try app.file_list.view(app.mode, app.review.files(), app.file_index, app.km.bindings, arena);
        try render.draw(frameOf(app, win, arena), shown);
    } else {
        win.clear();
        _ = win.printSegment(
            .{ .text = " lgtm: no changes against HEAD", .style = app.theme.dim },
            .{ .row_offset = 0, .wrap = .none },
        );
        // An empty review is exactly when a reader is most likely to want the
        // key list - there is nothing on screen to learn the keys from.
        // Both overlays float over the empty screen too: a review with nothing
        // in it is exactly when a reader wants to know what the keys are, and
        // an empty file list still has to say that it is empty.
        if (try app.help.view(app.mode, app.km.bindings, arena)) |hv| {
            try render.drawHelpPopup(frameOf(app, win, arena), hv, 0, win.height);
        }
        if (try app.file_list.view(app.mode, app.review.files(), app.file_index, app.km.bindings, arena)) |fv| {
            try render.drawFileList(frameOf(app, win, arena), fv, 0, win.height);
        }
    }

    const render_span = metrics.span(.render);
    try vx.render(w);
    render_span.end();
    try w.flush();

    // After render and flush, never before: the cells above point into this
    // arena (ARCHITECTURE.md 5c).
    _ = app.frame_arena.reset(.retain_capacity);
}

// The modules only the loop reaches. See the note in `app.zig`: a module whose
// tests nothing references is a module whose tests never run.
test {
    _ = editor;
}
