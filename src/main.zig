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
pub const status = @import("ui/status.zig");
pub const risk = @import("ui/risk.zig");
pub const serve = @import("serve/serve.zig");
const pty = @import("io/pty.zig");
const metrics = lib.metrics;
const gh = lib.gh;

const usage =
    \\lgtm - read what your agent wrote
    \\
    \\usage: lgtm [options]           review the working tree
    \\       lgtm diff [a] [b]        the same, against a ref or between two
    \\       lgtm status [options]    what changed, as a table
    \\       lgtm risk [options]      what the change did to the tests
    \\       lgtm themes              draw every bundled theme
    \\       lgtm serve [options]     every agent on this machine, to a paired phone
    \\       lgtm agent [options] <cmd>  run the agent here, for lgtm serve to find
    \\       lgtm <git command> ...   anything lgtm has no word for is git's
    \\       lgtm git <command> ...   git's own, even where lgtm has the word
    \\
    \\options:
    \\  --base <ref>     review against this ref instead of HEAD
    \\  --target <ref>   review this ref instead of the working tree (static)
    \\  --config <path>  read this file instead of the usual two
    \\  --init           write a starter config and exit; --config picks where
    \\  --pr [n]         review a pull request; bare, the current branch's
    \\                   (not with --base or --target: it sets both)
    \\  --pane <id>      send here: a tmux pane (%3), a herdr pane (w1:p1),
    \\                   a wezterm pane or a kitty window (3)
    \\  --theme <name>   use this bundled theme for this run
    \\  --strict         risk: fail on a fallen assertion count too
    \\  --listen <ip>    serve, agent: loopback or a Tailscale address (127.0.0.1);
    \\                   given to agent, it serves this machine itself
    \\  --port <n>       serve, agent: the port to listen on (7777)
    \\  --new-token      serve, agent: replace the saved token, unpairing every phone
    \\  --once           render one frame and exit, for screenshots and CI
    \\  --profile        print timing spans on exit (requires -Dprofile build)
    \\  -v, --version    print the banner and exit
    \\  -h, --help       print this help and exit
    \\
;

/// The bare words `lgtm` answers itself. Every other word is git's, so this
/// list is also the list of things `lgtm` shadows: `diff` and `status` on
/// purpose - reading a diff is what this tool is - and `help` and `version`
/// because a reader asking those of `lgtm` means `lgtm`. `lgtm git <command>`
/// reaches past all of them.
///
/// `init` is deliberately not here. `git init` is a thing people type, and a
/// tool that answered it by writing a config file into a directory with no
/// repository in it would be worse than no tool. Writing that config is
/// `--init`, which is the spelling it has always had.
const Verb = enum { status, diff, risk, themes, serve, agent, help, version };

/// Which of them was asked for. `help` and `version` are not here: they beat
/// every other word, so they are answered where they are read.
const Command = enum { review, status, risk, init, themes, serve, agent };

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

    // `lgtm agent` re-runs itself here on the agent's pty; see `io/pty.zig`.
    if (childArgv(init.minimal.args)) |argv| pty.becomeChild(io, argv);
    // `lgtm serve` runs one of these in each repo a phone reviews.
    if (reviewArgs(init.minimal.args)) |device| lib.proc.exit(serve.reviewer(gpa, io, init.environ_map, device) catch 1);

    // Before anything is parsed: a word lgtm has no answer for is git's.
    // `lgtm` is what you type instead of `git`, so a subcommand it has not
    // grown yet is handed over rather than refused - and it is the *first*
    // word that decides, so everything after it reaches git untouched.
    if (gitWord(init.minimal.args)) |skip| try handToGit(gpa, io, w, init.minimal.args, skip);

    var want_profile = false;
    var want_once = false;
    var want_strict = false;
    var config_path: ?[]const u8 = null;
    var theme_name: ?[]const u8 = null;
    var pane: ?[]const u8 = null;
    var serving: serve.Options = .{};
    var serve_flag = false;
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    var base: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var want_pr = false;
    var pr_number: ?u32 = null;
    var want_version = false;
    var cmd: Command = .review;
    var refs: Refs = .{};
    var taking_refs = false;
    // Whether the word this run began with is one git has too. If it is, then
    // anything lgtm cannot express is not an error - it is the question git
    // was going to be asked anyway, and `alias git=lgtm` only holds if it
    // gets asked.
    var shadowing = false;
    var args = init.minimal.args.iterate();
    _ = args.next();
    // `--pr` takes an optional value, so it has to be able to look at the next
    // argument and leave it alone. The iterator does not rewind; one slot of
    // pushback is the whole of what is needed.
    var pushback: ?[]const u8 = null;
    while (blk: {
        if (pushback) |p| {
            pushback = null;
            break :blk p;
        }
        break :blk args.next();
    }) |arg| {
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
        } else if (std.mem.eql(u8, arg, "--strict")) {
            want_strict = true;
        } else if (cmd == .agent and (std.mem.eql(u8, arg, "--") or (arg.len > 0 and arg[0] != '-'))) {
            // Everything from the command on is the command's, flags included.
            if (!std.mem.eql(u8, arg, "--")) try command.append(gpa, arg);
            while (args.next()) |rest| try command.append(gpa, rest);
        } else if (taking_refs and arg.len > 0 and arg[0] != '-') {
            // After `diff`, a word is a ref - git's own rule, and the reason
            // `lgtm diff status` reviews a branch called status rather than
            // complaining about a second command.
            // `a...b`, a third ref, a path after `--`: all things git's diff
            // says something about and this one cannot.
            refs.add(arg) catch try handToGit(gpa, io, w, init.minimal.args, 1);
        } else if (arg.len > 0 and arg[0] != '-') {
            // The first word already decided whether this run is lgtm's or
            // git's, above. A word here is a second command on one line, or an
            // argument for something that does not take one.
            const verb = std.meta.stringToEnum(Verb, arg) orelse {
                if (shadowing) try handToGit(gpa, io, w, init.minimal.args, 1);
                try w.print("lgtm: unexpected '{s}'\n\ntry: lgtm git {s} ...\n\n{s}", .{ arg, arg, usage });
                try w.flush();
                return;
            };
            if (cmd != .review) {
                if (shadowing) try handToGit(gpa, io, w, init.minimal.args, 1);
                try w.print("lgtm: unexpected '{s}'\n\n{s}", .{ arg, usage });
                try w.flush();
                return;
            }
            switch (verb) {
                .help => {
                    // `git help rebase` is git's; bare `help` is this tool's,
                    // because this tool is what was typed.
                    if (args.next() != null) try handToGit(gpa, io, w, init.minimal.args, 1);
                    try w.writeAll(usage);
                    try w.flush();
                    return;
                },
                .version => want_version = true,
                // `diff` is the review this tool already opens with no word at
                // all, so it names the default rather than a command of its
                // own - what it adds is the refs that may follow it.
                .diff => {
                    taking_refs = true;
                    shadowing = true;
                },
                .status => {
                    cmd = .status;
                    shadowing = true;
                },
                inline else => |v| cmd = @field(Command, @tagName(v)),
            }
        } else if (std.mem.eql(u8, arg, "--init")) {
            // The three verbs in their older spelling. Still accepted, no
            // longer listed: `--init` is in every copy of the README that
            // has shipped so far, and breaking it buys nothing.
            cmd = .init;
        } else if (std.mem.eql(u8, arg, "--theme-preview")) {
            cmd = .themes;
        } else if (std.mem.eql(u8, arg, "--status")) {
            cmd = .status;
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
        } else if (std.mem.eql(u8, arg, "--new-token")) {
            serving.new_token = true;
            serve_flag = true;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            serving.listen = args.next() orelse {
                try w.print("lgtm: --listen needs an address\n\n{s}", .{usage});
                try w.flush();
                return;
            };
            serving.explicit = true;
            serve_flag = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const text = args.next() orelse "";
            serving.port = std.fmt.parseInt(u16, text, 10) catch {
                try w.print("lgtm: --port needs a number, not '{s}'\n\n{s}", .{ text, usage });
                try w.flush();
                return;
            };
            serving.explicit = true;
            serve_flag = true;
        } else if (std.mem.eql(u8, arg, "--pr")) {
            // The number is optional, so the next argument is taken only when
            // it is digits: `--pr --once` is two flags, not a parse error.
            want_pr = true;
            if (args.next()) |next| {
                if (next.len > 0 and std.ascii.isDigit(next[0])) {
                    pr_number = std.fmt.parseInt(u32, next, 10) catch {
                        try w.print("lgtm: --pr takes a number, not '{s}'\n\n{s}", .{ next, usage });
                        try w.flush();
                        return;
                    };
                } else pushback = next;
            }
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
            // `--stat`, `--porcelain`, `-s`: lgtm's `diff` and `status` answer
            // the bare question and the flags they know. Everything else was
            // always git's question.
            if (shadowing) try handToGit(gpa, io, w, init.minimal.args, 1);
            try w.print("lgtm: unknown option '{s}'\n\n{s}", .{ arg, usage });
            try w.flush();
            return;
        }
    }

    if (cmd == .init) {
        try writeStarter(gpa, io, init.environ_map, config_path, w);
        try w.flush();
        return;
    }

    if (serve_flag and cmd != .serve and cmd != .agent) {
        try w.print("lgtm: --listen, --port and --new-token are for serve and agent\n\n{s}", .{usage});
        try w.flush();
        return;
    }
    if (cmd == .agent) {
        if (command.items.len == 0) {
            try w.print("lgtm: agent needs a command, such as: lgtm agent claude\n\n{s}", .{usage});
            try w.flush();
            return;
        }
        serving.qr = tty.stdoutIsTerminal(io);
        const code = try serve.host(gpa, io, init.environ_map, w, serving, command.items);
        try w.flush();
        lib.proc.exit(code);
    }
    if (cmd == .serve) {
        serving.qr = tty.stdoutIsTerminal(io);
        const code = try serve.run(gpa, io, init.environ_map, w, serving);
        try w.flush();
        lib.proc.exit(code);
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
    if (cmd == .themes) {
        try preview.write(w, glyphs);
        try w.flush();
        return;
    }

    // A theme named on the command line beats the file, and a name that is
    // not a theme is refused here rather than reported on the status line:
    // this one was typed just now, and the user is watching.
    if (theme_name) |name| {
        const found = theme.lookup(name) orelse {
            var list: [256]u8 = undefined;
            try w.print("lgtm: no theme called '{s}'\n\ntry: {s}\n", .{ name, config.themeNames(&list) });
            try w.flush();
            return;
        };
        cfg.cfg.theme = found.theme;
        cfg.cfg.theme_name = found.name;
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

    // `--pr` is sugar for `--base` and `--target`, resolved before the review
    // starts so that nothing below this line knows about GitHub.
    var pr_arena: std.heap.ArenaAllocator = .init(gpa);
    defer pr_arena.deinit();
    var pr_label: []const u8 = "";
    var pr_scope: u32 = 0;
    var pr_repo: []const u8 = "";
    // `lgtm diff main` and `lgtm --base main` are the same request, so they
    // land in the same two variables - and asking for both at once is a
    // contradiction worth saying out loud rather than resolving quietly.
    if (refs.len > 0) {
        if (base != null or target != null) {
            try w.print("lgtm: --base and --target are the refs diff already took\n\n{s}", .{usage});
            try w.flush();
            return;
        }
        base = refs.items[0];
        if (refs.len == 2) target = refs.items[1];
    }

    if (want_pr) {
        if (base != null or target != null) {
            // Winning quietly would review something the reader did not ask
            // for and say nothing about it.
            try w.print("lgtm: --pr sets --base and --target itself\n\n{s}", .{usage});
            try w.flush();
            return;
        }
        const pr_refs = gh.resolve(gpa, pr_arena.allocator(), io, pr_number) catch {
            // No degrading into a local review: one specific diff was asked
            // for. `gh` has already said why on stderr.
            try w.print("lgtm: could not open that pull request\n", .{});
            try w.flush();
            return;
        };
        base = pr_refs.base;
        target = pr_refs.target;
        pr_label = pr_refs.label;
        pr_scope = pr_refs.number;
        pr_repo = pr_refs.repo;
    }

    // After `--pr` resolves, so `lgtm status --pr 42` reports the pull request
    // rather than the working tree. No terminal is touched: this prints and
    // exits.
    if (cmd == .risk) {
        lib.i18n.lang = cfg.cfg.ui.language;
        const term = tty.stdoutIsTerminal(io);
        const code = try risk.run(gpa, io, w, .{
            .theme = cfg.cfg.theme,
            .glyphs = glyphs,
            .colour = term,
            .cols = if (term) tty.stdoutColumns() else null,
            .base = base orelse "HEAD",
            .target = target,
            .ignore = cfg.cfg.ignore,
            .strict = want_strict,
        });
        try w.flush();
        // The answer is the exit code as much as the text: this one is meant
        // to be asked by a build as well as by a person.
        if (code != 0) lib.proc.exit(code);
        return;
    }

    if (cmd == .status) {
        lib.i18n.lang = cfg.cfg.ui.language;
        const term = tty.stdoutIsTerminal(io);
        try status.run(gpa, io, w, .{
            .theme = cfg.cfg.theme,
            .glyphs = glyphs,
            .colour = term,
            .cols = if (term) tty.stdoutColumns() else null,
            .tree = term,
            .base = base orelse "HEAD",
            .target = target,
            .ignore = cfg.cfg.ignore,
        });
        try w.flush();
        return;
    }

    try loop.run(gpa, io, init.environ_map, .{
        .once = want_once,
        .cfg = cfg.cfg,
        .problems = cfg.summary(&problem_buf),
        .config_path = config_path,
        .pane = pane,
        .base = base,
        .target = target,
        .label = pr_label,
        .pr = pr_scope,
        .repo = pr_repo,
    });

    if (want_profile) try metrics.report(w);
    try w.flush();
}

/// The command after `lgtm __pty-child --`, when this run is that helper.
fn childArgv(args: std.process.Args) ?[]const []const u8 {
    var it = args.iterate();
    _ = it.next();
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, pty.child_verb)) return null;
    _ = it.next();
    const S = struct {
        var buf: [256][]const u8 = undefined;
    };
    var n: usize = 0;
    while (it.next()) |a| : (n += 1) {
        if (n == S.buf.len) break;
        S.buf[n] = a;
    }
    return if (n == 0) null else S.buf[0..n];
}

/// The device after `lgtm __review`, when this run is that helper.
fn reviewArgs(args: std.process.Args) ?[]const u8 {
    var it = args.iterate();
    _ = it.next();
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, serve.review_verb)) return null;
    return it.next() orelse "";
}

/// Runs git with everything that was typed and exits with its status.
///
/// `skip` is how many leading argv entries to drop: one for the program name,
/// two when the word after it was a literal `git`.
///
/// Nothing comes back from here. Stdio is inherited rather than piped, so a
/// pager still pages, a prompt still prompts and the colours are git's own.
fn handToGit(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    args: std.process.Args,
    skip: usize,
) !noreturn {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    var rest = args.iterate();
    for (0..skip) |_| _ = rest.next();
    while (rest.next()) |a| try argv.append(gpa, a);

    try w.flush();
    const code = lib.proc.runInherit(io, argv.items) catch {
        try w.print("lgtm: cannot run git - is it installed?\n", .{});
        try w.flush();
        lib.proc.exit(1);
    };
    lib.proc.exit(code);
}

/// The refs written after `diff`, in the order they arrived.
///
/// A word is one side, and `main..HEAD` is both in one - which is how git
/// writes a range and therefore how a hand types one. `..HEAD` fills the left
/// with HEAD, the same shorthand meaning the same thing.
const Refs = struct {
    items: [2][]const u8 = undefined,
    len: usize = 0,

    const AddError = error{
        /// A third ref. There is no third side to a diff.
        TooMany,
        /// A range after a ref, or after another range.
        AlreadyRanged,
        /// `a...b`. Its merge-base is what `--pr` resolves, and guessing that
        /// is what was meant here would be guessing.
        Symmetric,
    };

    fn add(self: *Refs, word: []const u8) AddError!void {
        if (std.mem.indexOf(u8, word, "...") != null) return error.Symmetric;
        if (std.mem.indexOf(u8, word, "..")) |at| {
            if (self.len > 0) return error.AlreadyRanged;
            self.items[0] = if (at == 0) "HEAD" else word[0..at];
            self.len = 1;
            // `main..` is the left side of a range with the working tree still
            // on the right, which is the live review this tool is about.
            if (word[at + 2 ..].len > 0) {
                self.items[1] = word[at + 2 ..];
                self.len = 2;
            }
            return;
        }
        if (self.len == self.items.len) return error.TooMany;
        self.items[self.len] = word;
        self.len += 1;
    }
};

/// How many leading argv entries to skip before handing the rest to git, or
/// null when this run is lgtm's own.
///
/// One is the program name alone: the word after it is git's and git needs it.
/// Two also drops a literal `git`, which was the reader asking for *the real
/// one* - passing it on would make `git git status`.
///
/// A leading flag is lgtm's unless it is one of git's own, which are a closed
/// set and come before the subcommand: `--once` is far more likely a typo of
/// an lgtm option than an attempt at `git --once`, but `-c` and `-C` are
/// nobody's but git's, and `alias git=lgtm` does not survive without them.
fn gitWord(args: std.process.Args) ?usize {
    var it = args.iterate();
    _ = it.next();
    const first = it.next() orelse return null;
    if (std.mem.eql(u8, first, "git")) return 2;
    if (first.len == 0) return null;
    if (first[0] == '-') return if (gitGlobal(first)) 1 else null;
    return if (std.meta.stringToEnum(Verb, first) == null) 1 else null;
}

/// git's options that come before a subcommand. Listed rather than guessed at,
/// because the guess in either direction is wrong: treat every leading flag as
/// git's and a mistyped lgtm option becomes a confusing git error, treat none
/// of them as git's and `git -c user.name=x commit` stops working under the
/// alias.
///
/// `-h` and `-v` are deliberately absent. Under the alias they are being asked
/// of lgtm, because lgtm is what the name now means; `lgtm git --version`
/// still reaches git's.
const git_globals: []const []const u8 = &.{
    "-c",                   "-C",                  "-p",               "-P",
    "--paginate",           "--no-pager",          "--bare",           "--git-dir",
    "--work-tree",          "--namespace",         "--exec-path",      "--config-env",
    "--no-optional-locks",  "--literal-pathspecs", "--glob-pathspecs", "--icase-pathspecs",
    "--no-replace-objects", "--attr-source",       "--html-path",      "--man-path",
    "--info-path",
};

fn gitGlobal(arg: []const u8) bool {
    for (git_globals) |g| {
        if (std.mem.eql(u8, arg, g)) return true;
        // `--git-dir=/path` attaches its value rather than taking the next
        // argument, and both spellings are in use.
        if (arg.len > g.len and arg[g.len] == '=' and std.mem.startsWith(u8, arg, g)) return true;
    }
    return false;
}

/// `--init`. Writes the starter config to `--config <path>` if one was named,
/// and to the global path otherwise.
///
/// Never overwrites. A config file is a thing the user wrote by hand, and the
/// one command that would destroy it is the one they reach for when they are
/// not sure whether they have one yet.
fn writeStarter(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    explicit: ?[]const u8,
    w: *std.Io.Writer,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const path = explicit orelse config.globalPath(arena.allocator(), environ) orelse {
        try w.print("lgtm: no HOME or XDG_CONFIG_HOME, so there is nowhere to put it\n" ++
            "try: lgtm --init --config <path>\n", .{});
        return;
    };

    if (lib.fs.fileExists(io, path)) {
        try w.print("lgtm: {s} already exists, leaving it alone\n", .{path});
        return;
    }

    lib.fs.writeFile(io, path, config.starter) catch |err| {
        try w.print("lgtm: cannot write {s}: {t}\n", .{ path, err });
        return;
    };
    try w.print("wrote {s}\n\nEvery line is commented out, so nothing changed yet.\n", .{path});
}

test "git's own leading options are git's, and lgtm's are not" {
    const testing = std.testing;

    try testing.expect(gitGlobal("-c"));
    try testing.expect(gitGlobal("-C"));
    try testing.expect(gitGlobal("--no-pager"));
    // The attached-value spelling, which is what a script writes.
    try testing.expect(gitGlobal("--git-dir=/tmp/x/.git"));

    // lgtm's own, and the two every tool answers for itself.
    try testing.expect(!gitGlobal("--once"));
    try testing.expect(!gitGlobal("--base"));
    try testing.expect(!gitGlobal("-h"));
    try testing.expect(!gitGlobal("-v"));
    try testing.expect(!gitGlobal("--version"));
    // A prefix of one is not one.
    try testing.expect(!gitGlobal("--git"));
}

test "diff takes its refs the way git writes them" {
    const testing = std.testing;

    var one: Refs = .{};
    try one.add("main");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("main", one.items[0]);

    var two: Refs = .{};
    try two.add("main");
    try two.add("HEAD");
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("HEAD", two.items[1]);

    // A range is the same two refs in one word.
    var range: Refs = .{};
    try range.add("main..HEAD");
    try testing.expectEqual(@as(usize, 2), range.len);
    try testing.expectEqualStrings("main", range.items[0]);
    try testing.expectEqualStrings("HEAD", range.items[1]);

    // An open right side stays open: the working tree is still the review.
    var open: Refs = .{};
    try open.add("main..");
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("main", open.items[0]);

    // An open left side is HEAD, which is what git means by it.
    var left: Refs = .{};
    try left.add("..main");
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqualStrings("HEAD", left.items[0]);
    try testing.expectEqualStrings("main", left.items[1]);
}

test "a third ref, a second range and a symmetric one are all refused" {
    const testing = std.testing;

    var full: Refs = .{};
    try full.add("a");
    try full.add("b");
    try testing.expectError(error.TooMany, full.add("c"));

    // A range already filled both sides, so a word after it is a third ref.
    var ranged: Refs = .{};
    try ranged.add("a..b");
    try testing.expectError(error.TooMany, ranged.add("c"));

    // A range after a ref is two ways of saying the left side.
    var after: Refs = .{};
    try after.add("a");
    try testing.expectError(error.AlreadyRanged, after.add("b..c"));

    var sym: Refs = .{};
    try testing.expectError(error.Symmetric, sym.add("a...b"));
}

test {
    _ = lib;
    _ = config;
    _ = loop;
    _ = preview;
    _ = theme;
    _ = tty;
    _ = app;
    _ = status;
    _ = risk;
    _ = serve;
}
