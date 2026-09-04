// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const lib = @import("lib.zig");
pub const config = @import("config.zig");
pub const theme = @import("ui/theme.zig");
pub const preview = @import("ui/preview.zig");
pub const tty = @import("io/tty.zig");
pub const app = @import("ui/app.zig");
pub const loop = @import("ui/loop.zig");
pub const splash = @import("ui/splash.zig");
const metrics = lib.metrics;

const usage =
    \\lgtm - read what your agent wrote
    \\
    \\usage: lgtm [options]
    \\
    \\  --base <ref>     review against this ref instead of HEAD
    \\  --target <ref>   review this ref instead of the working tree (static)
    \\  --config <path>  read this file instead of the usual two
    \\  --pane <id>      send here: a tmux pane (%3), a herdr pane (w1:p1),
    \\                   a wezterm pane or a kitty window (3)
    \\  --theme <name>   use this bundled theme for this run
    \\  --theme-preview  draw every bundled theme and exit
    \\  --once           render one frame and exit, for screenshots and CI
    \\  --profile        print timing spans on exit (requires -Dprofile build)
    \\  -v, --version    print the banner and exit
    \\  -h, --help       print this help and exit
    \\
;

/// A panic still says what went wrong; what this drops in a release build is
/// the stack trace under it, and with it the DWARF reader, the inflate for
/// compressed debug sections, and the stable sort they pull in - 304 KB
/// measured, against a 1 MB budget. Build with `-Dtraces` to get them back.
pub const panic = if (build_options.stack_traces)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.simple_panic;

/// Zig 0.16 hands main the process allocator, arena, and Io implementation.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    metrics.init(io);

    var out = try tty.Stdout.init(gpa, io, 64 << 10);
    defer out.deinit();
    const w = out.writer();

    var want_profile = false;
    var want_once = false;
    var config_path: ?[]const u8 = null;
    var theme_name: ?[]const u8 = null;
    var pane: ?[]const u8 = null;
    var base: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var want_preview = false;
    var want_version = false;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try w.writeAll(usage);
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            want_version = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            want_profile = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            want_once = true;
        } else if (std.mem.eql(u8, arg, "--theme-preview")) {
            want_preview = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            theme_name = args.next() orelse {
                try w.print("lgtm: --theme needs a name\n\n{s}", .{usage});
                try w.flush();
                return;
            };
        } else if (std.mem.eql(u8, arg, "--pane")) {
            pane = args.next() orelse {
                try w.print("lgtm: --pane needs a pane or window id\n\n{s}", .{usage});
                try w.flush();
                return;
            };
        } else if (std.mem.eql(u8, arg, "--base")) {
            base = args.next() orelse {
                try w.print("lgtm: --base needs a ref\n\n{s}", .{usage});
                try w.flush();
                return;
            };
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = args.next() orelse {
                try w.print("lgtm: --target needs a ref\n\n{s}", .{usage});
                try w.flush();
                return;
            };
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse {
                try w.print("lgtm: --config needs a path\n\n{s}", .{usage});
                try w.flush();
                return;
            };
        } else {
            try w.print("lgtm: unknown option '{s}'\n\n{s}", .{ arg, usage });
            try w.flush();
            return;
        }
    }

    try w.flush();

    // Read before the terminal is touched: a config error is a status-line
    // notice on the first frame, never a reason not to start (hard rule
    // 4.9). The loader owns the bindings the keymap is about to point at, so
    // it has to outlive the app.
    var cfg = config.load(gpa, io, init.environ_map, config_path);
    defer cfg.deinit();
    var problem_buf: [192]u8 = undefined;

    const glyphs = switch (cfg.cfg.ui.icons) {
        .unicode => theme.Glyphs.unicode,
        .ascii => theme.Glyphs.ascii,
        .nerd => theme.Glyphs.nerd,
    };
    if (want_preview) {
        try preview.write(w, glyphs);
        try w.flush();
        return;
    }

    // A theme named on the command line beats the file, and a name that is
    // not a theme is refused here rather than reported on the status line:
    // this one was typed just now, and the user is watching.
    if (theme_name) |name| {
        cfg.cfg.theme = theme.byName(name) orelse {
            var list: [256]u8 = undefined;
            try w.print("lgtm: no theme called '{s}'\n\ntry: {s}\n", .{ name, config.themeNames(&list) });
            try w.flush();
            return;
        };
    }

    // After the theme is resolved, so `lgtm -v --theme <name>` prints in the
    // theme it names and the icon set the config asked for: the banner is the
    // empty screen, and it should look like the one this run would draw.
    if (want_version) {
        const term = tty.stdoutIsTerminal(io);
        try splash.writeBanner(w, cfg.cfg.theme, glyphs, term, if (term) tty.stdoutColumns() else null);
        try w.flush();
        return;
    }

    try loop.run(gpa, io, init.environ_map, .{
        .once = want_once,
        .cfg = cfg.cfg,
        .problems = cfg.summary(&problem_buf),
        .pane = pane,
        .base = base,
        .target = target,
    });

    if (want_profile) try metrics.report(w);
    try w.flush();
}

test {
    _ = lib;
    _ = config;
    _ = loop;
    _ = preview;
    _ = theme;
    _ = tty;
    _ = app;
}
