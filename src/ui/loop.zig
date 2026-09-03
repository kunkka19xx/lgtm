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
const fs = @import("../io/fs.zig");
const input = @import("../io/input.zig");
const metrics = @import("../io/metrics.zig");
const proc = @import("../io/proc.zig");
const tty_mod = @import("../io/tty.zig");
const watch = @import("../io/watch.zig");

const bridge = @import("../bridge/bridge.zig");

const config = @import("../config.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const editor = @import("editor.zig");
const keytext = @import("keytext.zig");
const render = @import("render.zig");
const splash = @import("splash.zig");
const theme_mod = @import("theme.zig");

/// One animation frame. 60 Hz is smooth and is what the terminal can flush;
/// asking for more would spend bandwidth on frames a pane cannot show.
const frame_ms: i64 = 16;

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
    /// `--pane <id>`: the multiplexer pane the agent is running in. Beats both
    /// the saved target and the inference, and replaces the saved one, because
    /// it was typed just now and the inference was a guess.
    pane: ?[]const u8 = null,
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
    app.wrap = opts.cfg.ui.wrap;
    app.scroll_anim.budget_ms = opts.cfg.ui.scroll_ms;
    app.cursor_anim.budget_ms = opts.cfg.ui.cursor_ms;
    app.km.bindings = opts.cfg.keys;
    app.presets_cfg = opts.cfg.presets;
    app.comments_inline = opts.cfg.ui.comments == .inline_;
    app.compose_at = switch (opts.cfg.ui.compose) {
        .bottom => .bottom,
        .top => .top,
        .centre => .centre,
    };
    app.review.ignore = opts.cfg.ignore;
    app.theme = opts.cfg.theme;
    app.glyphs = switch (opts.cfg.ui.icons) {
        .unicode => theme_mod.Glyphs.unicode,
        .ascii => theme_mod.Glyphs.ascii,
        .nerd => theme_mod.Glyphs.nerd,
    };
    // Said once, on the first frame, and cleared by the first keystroke like
    // any other notice - long enough to read, and not a modal the user has to
    // dismiss before reviewing anything.
    if (opts.problems) |p| app.notice.set("config: {s}", .{p});

    // Detection is env vars and cannot fail; the target is the part that can,
    // and it resolves lazily on the first send so a pane opened after lgtm
    // started is still reachable (ARCHITECTURE.md 6).
    var br = bridge.detect(environ);
    var saved: SavedTarget = .{};
    if (br == .tmux) {
        var saved_buf: [bridge.max_pane_id]u8 = undefined;
        if (bridge.loadTarget(io, gpa, &saved_buf)) |p| {
            br.tmux.setPane(p);
            saved.set(p);
        }
        // Typed just now, so it beats what a previous run inferred. Not
        // recorded as saved: the first send that works is what persists it.
        if (opts.pane) |p| br.tmux.setPane(p);
    }

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
    // Resize events keep this in step from here on; the app needs the width
    // because a wrapped row is more screen rows than one (`ui/wrap.zig`).
    app.cols = ws.cols;

    // Before the first diff, so lgtm's own state never appears in it. Repairs
    // a `.lgtm/` left behind by a version that did not write the ignore; a no-op
    // in a repo lgtm has never written to.
    fs.ensureSelfIgnore(io);
    // Notes outlive the process: the whole point of `.lgtm/` is that killing
    // the pane costs scroll position and nothing else (ARCHITECTURE.md 1).
    app.loadComments();

    try app.rediff();

    while (!app.quit) {
        // A SIGWINCH that never reached the queue leaves the screen wider
        // than the pane, and the terminal then wraps every row vaxis writes:
        // one rule becomes two, one line of code becomes two. The reader
        // services the flag on its own wake, so this only catches the pane
        // with no pollable descriptor - but there it is the difference
        // between correcting on the next event and staying wrong all session.
        if (term.winsize()) |now| {
            if (now.cols != ws.cols or now.rows != ws.rows) {
                ws = now;
                try vx.resize(gpa, w, ws);
                try app.handle(
                    .{ .resize = .{ .cols = ws.cols, .rows = ws.rows } },
                    render.bodyHeight(ws.rows, app.zen),
                );
            }
        } else |_| {}

        // Once for the iteration: every use below is the same answer, and a
        // resize inside `applyEvents` is picked up by the next pass.
        const body = render.bodyHeight(ws.rows, app.zen);
        app.clampScroll(body);

        try drawFrame(&app, &vx, w, body);
        if (opts.once) break;

        // Two ways to wait. Settled, the loop blocks - a review pane is idle
        // almost all of the time and should cost nothing while it is. With the
        // viewport still catching up it paces itself instead, and goes back to
        // blocking the moment it arrives.
        if (app.animating(body)) {
            const events = try queue.tryDrain(gpa);
            defer gpa.free(events);
            if (events.len == 0) {
                app.stepAnim(pace(io, &queue, frame_ms), body);
            } else {
                // Whether this cancels what is in flight is the command's
                // decision, not the loop's: another jump adds to it and the
                // two travel together, anything else arrives at once. See
                // `App.run`.
                try applyEvents(&app, &vx, w, gpa, &ws, events);
            }
        } else {
            const events = try queue.drain(gpa);
            defer gpa.free(events);
            if (events.len == 0) break; // queue closed
            try applyEvents(&app, &vx, w, gpa, &ws, events);
        }

        if (app.want_send) |how| {
            app.want_send = null;
            try deliver(&app, &br, w, how, &saved);
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

/// The pane id currently on disk. A target that changes mid-session - the
/// agent's pane died and its replacement was inferred - is persisted, and one
/// that has not changed is not rewritten on every send.
const SavedTarget = struct {
    buf: [bridge.max_pane_id]u8 = undefined,
    len: usize = 0,

    fn matches(self: *const SavedTarget, id: []const u8) bool {
        return std.mem.eql(u8, self.buf[0..self.len], id);
    }

    fn set(self: *SavedTarget, id: []const u8) void {
        self.len = @min(id.len, self.buf.len);
        @memcpy(self.buf[0..self.len], id[0..self.len]);
    }
};

/// Performs a composed payload. Which bridge, and whether it degraded, is the
/// bridge's business; what the status line says about it is this file's.
fn deliver(
    app: *App,
    br: *bridge.Bridge,
    w: *std.Io.Writer,
    how: App.Delivery,
    saved: *SavedTarget,
) !void {
    const text = app.payload();
    if (text.len == 0) return;

    const cx: bridge.Ctx = .{ .gpa = app.gpa, .io = app.io, .w = w };
    const res = switch (how) {
        .send => br.sendText(cx, text),
        .copy => br.copyText(cx, text),
    } catch |err| {
        switch (err) {
            // The one case the user can act on, so it says what to do rather
            // than what went wrong. Inference has already declined: the window
            // holds more than the two panes it can be sure about.
            error.NoTarget => app.notice.set("no agent pane: restart with --pane %N", .{}),
            error.Multiline => app.notice.set("refusing to send a multi-line payload", .{}),
            else => app.notice.set("bridge: {t}", .{err}),
        }
        return;
    };

    switch (res) {
        .sent => |pane| {
            // Only a target that has actually worked is persisted: writing a
            // guess down would make the next run inherit a wrong pane and
            // start by sending the user's first reference to the clipboard.
            if (!saved.matches(pane)) {
                bridge.saveTarget(app.io, pane);
                saved.set(pane);
            }
            app.notice.set("sent to {s}", .{pane});
        },
        .copied => |why| if (why) |reason|
            app.notice.set("{s}: copied to the clipboard instead", .{reason})
        else
            app.notice.set("copied to the clipboard", .{}),
    }
}

/// One animation frame's worth of waiting, and the real time it took.
///
/// Real rather than assumed: a terminal slow to flush would otherwise stretch
/// every animation out behind it. Slept in slices with the queue checked
/// between, for the same reason `io/watch.zig` slices its interval - a
/// keystroke arriving mid-animation should wait a slice, not a whole frame.
fn pace(io: std.Io, queue: *event.Queue, ms: i64) f32 {
    const slice: i64 = 4;
    const start: std.Io.Timestamp = .now(io, .awake);
    var slept: i64 = 0;
    while (slept < ms) : (slept += slice) {
        std.Io.sleep(io, .fromMilliseconds(@min(slice, ms - slept)), .awake) catch break;
        if (queue.pending()) break;
    }
    const ns = start.durationTo(.now(io, .awake)).nanoseconds;
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// A drained batch, applied. Shared by the two waits above so that pacing an
/// animation cannot drift from blocking on a keystroke.
fn applyEvents(
    app: *App,
    vx: *vaxis.Vaxis,
    w: *std.Io.Writer,
    gpa: Allocator,
    ws: *tty_mod.Winsize,
    events: []const event.Event,
) !void {
    for (events) |ev| {
        if (ev == .resize) {
            ws.* = .{ .cols = ev.resize.cols, .rows = ev.resize.rows, .x_pixel = 0, .y_pixel = 0 };
            try vx.resize(gpa, w, ws.*);
        }
        try app.handle(ev, render.bodyHeight(ws.rows, app.zen));
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

fn drawFrame(app: *App, vx: *vaxis.Vaxis, w: *std.Io.Writer, body: u16) !void {
    const frame = metrics.span(.frame);
    defer frame.end();

    const arena = app.frame_arena.allocator();
    const win = vx.window();
    // Only known once the terminal has answered the capability query, so it is
    // read per frame rather than captured at startup.
    app.width_method = vx.screen.width_method;

    if (app.view(body)) |v| {
        var shown = v;
        var hint_buf: [256]u8 = undefined;
        shown.hints = try arena.dupe(u8, keytext.hints(app.km.bindings, app.mode, &hint_buf));
        shown.help = try app.help.view(app.mode, app.km.bindings, arena);
        shown.files = try app.file_list.view(app.mode, app.pick_list.items, app.file_index, app.km.bindings, arena);
        try render.draw(frameOf(app, win, arena), shown);
    } else {
        win.clear();
        try splash.draw(frameOf(app, win, arena), app.km.bindings);
        // An empty review is exactly when a reader is most likely to want the
        // key list - there is nothing on screen to learn the keys from.
        // Both overlays float over the empty screen too: a review with nothing
        // in it is exactly when a reader wants to know what the keys are, and
        // an empty file list still has to say that it is empty.
        if (try app.help.view(app.mode, app.km.bindings, arena)) |hv| {
            try render.drawHelpPopup(frameOf(app, win, arena), hv, 0, win.height);
        }
        // The compose box floats here too: with nothing to review there is
        // still an agent to talk to, and the box opens empty rather than
        // refusing. Drawn *before* the overlays it opens, the same order the
        // diff path uses - drawing it last painted it over the file list it
        // had just summoned.
        var room_top: u16 = 0;
        var room = win.height;
        if (app.compose.open) {
            const cv = app.composeView(arena);
            try render.drawCompose(frameOf(app, win, arena), cv, 0, win.height);
            if (render.composeBox(frameOf(app, win, arena), cv, 0, win.height)) |box| {
                room_top = box.roomTop(0, win.height);
                room = box.room(0, win.height);
            }
        }
        if (try app.file_list.view(app.mode, app.pick_list.items, app.file_index, app.km.bindings, arena)) |fv| {
            try render.drawFileList(frameOf(app, win, arena), fv, room_top, room);
        }
        // The bottom row is the prompt when one is open, and whatever the last
        // keystroke had to say otherwise. Without it `:q` is typed blind: the
        // splash owns the whole window, so a line with nowhere to go is a line
        // the reader never sees.
        if (win.height > 0) {
            const f = frameOf(app, win, arena);
            if (app.prompt.open) {
                render.drawPromptLine(f, .{
                    .prefix = app.prompt.kind.prefix(),
                    .text = app.prompt.text(),
                }, win.height - 1);
            } else if (app.notice.text().len > 0) {
                f.put(win.height - 1, 1, app.notice.text(), f.theme.notice);
            }
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
    _ = bridge;
    _ = editor;
    _ = splash;
    _ = @import("path.zig");
}
