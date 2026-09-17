// SPDX-License-Identifier: Apache-2.0
//
// `lgtm status`: the review as a table - what `git status` lists, plus the two
// counts and the clock it leaves out.
//
// Straight to stdout as SGR, like `ui/preview.zig` and the `-v` banner: this
// runs instead of the TUI, so there is no terminal to set up. Colour goes off
// for a pipe.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diff = @import("../core/diff.zig");
const git = @import("../core/git.zig");
const fs = @import("../io/fs.zig");
const i18n = @import("../i18n/i18n.zig");
const path_mod = @import("path.zig");
const preview = @import("preview.zig");
const theme_mod = @import("theme.zig");
// For `ago` only: "27m ago" is spelled once, in the comment thread.
const thread = @import("thread.zig");
const wrap = @import("wrap.zig");

const Glyphs = theme_mod.Glyphs;
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

const margin = 1;
const gap = 2;

/// The stage mark and the space after it. Only a working tree has an index,
/// so a two-ref review spends nothing here.
const mark_col = 2;

/// Where the path column starts: the margin, the stage mark, the status
/// letter, the gap after it. A directory header, the totals and the key all
/// hang off it.
fn headOf(opts: Options) u16 {
    return margin + @as(u16, if (marked(opts)) mark_col else 0) + 1 + gap;
}

/// Whether the stage column means anything. Between two refs there is no
/// index to be on either side of, and a column that answers nothing is worse
/// than no column.
fn marked(opts: Options) bool {
    return opts.target == null;
}

/// The narrowest the path column gets before there is no path left to read.
const min_text = 12;

const metrics: wrap.Metrics = .{ .method = .unicode };

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// One file's line.
pub const Row = struct {
    /// The directory line to print above this row, set on the first file of a
    /// group. Empty otherwise.
    header: []const u8 = "",
    /// The tree rail and the indent around it, or empty when the row is not
    /// in a group.
    rail: []const u8 = "",
    /// The name as shown: the base name inside a group, the whole path
    /// outside one - or git's `src/{old => new}.zig` when it moved.
    text: []const u8,
    status: diff.Status,
    /// Which side of the index this file's change is on. `unstaged` is the
    /// default because it is what a file git did not mention in `status` is.
    stage: git.Stage = .unstaged,
    added: u32,
    removed: u32,
    /// Seconds since the epoch, or null when there is nothing on disk to ask.
    when: ?i64 = null,
};

pub const Options = struct {
    theme: Theme,
    glyphs: Glyphs,
    /// Off for a pipe, the same rule the `-v` banner follows.
    colour: bool,
    /// What stdout has to draw in, or null for a pipe.
    cols: ?u16 = null,
    base: []const u8 = "HEAD",
    /// Set when `--target` or `--pr` reviewed a ref rather than the tree.
    target: ?[]const u8 = null,
    /// `[review] ignore`, passed to git as pathspecs.
    ignore: []const []const u8 = &.{},
    /// Files those patterns kept out, for the footer.
    hidden: u32 = 0,
    /// Now, in seconds since the epoch. `run` reads the clock; a test pins it.
    now: i64 = 0,
    /// Group files by directory. Off for a pipe, where a row has to carry its
    /// whole path for `grep` to find it.
    tree: bool = false,
};

/// Diffs, stats and prints. The whole of the subcommand.
pub fn run(gpa: Allocator, io: std.Io, w: *std.Io.Writer, opts_in: Options) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts = opts_in;
    opts.now = nowSeconds(io);

    // The same two calls `ui/review.zig` makes: two refs have nothing
    // untracked between them, and a working tree does.
    const parsed = (if (opts.target) |t|
        git.diffAt(arena, io, null, opts.ignore, opts.base, t)
    else
        git.diffPathsIn(arena, io, null, &.{}, opts.ignore, opts.base)) catch |err| switch (err) {
        // Every other failure has already said why on git's stderr.
        error.NotARepository => return w.print("lgtm: {s}\n", .{i18n.t("not a git repository")}),
        error.OutOfMemory => return error.OutOfMemory,
        else => return w.print("lgtm: {s}\n", .{i18n.t("could not read the diff")}),
    };
    opts.hidden = git.hiddenCount(gpa, io, opts.ignore, opts.base);

    // Only a working tree has an index. Between two refs there is nothing to
    // be on either side of, and asking would describe the tree instead of the
    // review that was requested.
    //
    // A failure here costs the column, not the table: every row falls back to
    // `unstaged`, which is what a file matching the index is anyway.
    var st: ?git.Stages = if (opts.target == null) (git.stages(gpa, io, null) catch null) else null;
    defer if (st) |*x| x.deinit();

    try draw(arena, w, try collect(
        arena,
        io,
        parsed.diff.files,
        opts.target == null,
        if (st) |*x| x else null,
    ), opts);
}

/// The rows behind a parsed diff. Split from `draw` so the table can be tested
/// without a repository.
fn collect(
    arena: Allocator,
    io: std.Io,
    files: []const diff.FileDiff,
    /// False for a two-ref review: the file on disk is not the file reported.
    ages: bool,
    /// What `git status` said about each path, or null when it was not asked
    /// or could not answer.
    st: ?*const git.Stages,
) Allocator.Error![]Row {
    const rows = try arena.alloc(Row, files.len);
    for (files, rows) |*f, *row| row.* = .{
        .text = if (f.status == .renamed)
            try path_mod.moved(arena, f.old_path, f.new_path)
        else
            f.path(),
        .status = f.status,
        // Keyed on the path git would use, which for a rename is the new one -
        // the same one `path()` returns.
        .stage = if (st) |x| x.get(f.path()) else .unstaged,
        .added = f.added,
        .removed = f.removed,
        .when = if (ages) mtime(io, f) else null,
    };
    return rows;
}

/// When the working tree's copy was last written. A deleted file has no
/// answer, and a failed stat is given the same one: the column is a
/// convenience, and a row without it is still a row.
fn mtime(io: std.Io, f: *const diff.FileDiff) ?i64 {
    if (f.status == .deleted) return null;
    const meta = fs.statFile(io, f.path()) orelse return null;
    return @intCast(@divFloor(meta.mtime_ns, std.time.ns_per_s));
}

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_s));
}

/// The table, then the totals under it.
pub fn draw(arena: Allocator, w: *std.Io.Writer, rows: []const Row, opts: Options) Error!void {
    const t = opts.theme;
    const head = headOf(opts);
    try w.writeByte('\n');

    if (rows.len == 0) {
        // A clean tree is an answer, not an empty result.
        try w.splatByteAll(' ', margin);
        try paint(w, opts, t.dim, try i18n.allocPrint(arena, "nothing to review: {s} matches {s}", .{
            opts.target orelse i18n.t("the working tree"),
            opts.base,
        }));
        try w.writeAll("\n\n");
        return;
    }

    const shown = if (opts.tree) try grouped(arena, rows, opts.glyphs) else rows;
    const col = fitted(measure(shown, opts), opts.cols, head);
    var total_added: u64 = 0;
    var total_removed: u64 = 0;

    for (shown) |r| {
        total_added += r.added;
        total_removed += r.removed;

        if (r.header.len > 0) {
            try w.splatByteAll(' ', head);
            try paint(w, opts, t.dim, try path_mod.elideFront(
                arena,
                r.header,
                (opts.cols orelse std.math.maxInt(u16)) -| head,
                opts.glyphs.ellipsis,
                metrics,
            ));
            try w.writeByte('\n');
        }

        try w.splatByteAll(' ', margin);
        if (marked(opts)) {
            const mark = stageMark(r.stage, opts.glyphs);
            try paint(w, opts, stageStyle(t, r.stage), mark);
            try w.splatByteAll(' ', mark_col - wrap.columns(mark, metrics));
        }
        try paint(w, opts, statusStyle(t, r.status, r.stage), letter(r.status, r.stage));
        try w.splatByteAll(' ', gap);

        try paint(w, opts, t.dim, r.rail);
        // From the front, the way `git diff --stat` shortens one: the name
        // at the end is the answer to "which file".
        const room = col.text -| wrap.columns(r.rail, metrics);
        const text = try path_mod.elideFront(arena, r.text, room, opts.glyphs.ellipsis, metrics);
        try paint(w, opts, t.path, text);
        try w.splatByteAll(' ', room - wrap.columns(text, metrics) + gap);

        var buf: [count_max]u8 = undefined;
        const added = addedCell(&buf, r);
        try w.splatByteAll(' ', col.added - wrap.columns(added, metrics));
        try paint(w, opts, if (r.added == 0) t.dim else t.added_count, added);
        try w.splatByteAll(' ', gap);

        const removed = removedCell(&buf, r, opts.glyphs);
        try w.splatByteAll(' ', col.removed - wrap.columns(removed, metrics));
        try paint(w, opts, if (r.removed == 0) t.dim else t.removed_count, removed);

        if (col.age > 0) {
            var when: [age_max]u8 = undefined;
            // A row with no age ends at its counts, not at trailing spaces.
            const age = ageCell(&when, r, opts.now);
            if (age.len > 0) {
                try w.splatByteAll(' ', gap);
                try paint(w, opts, t.dim, age);
            }
        }
        try w.writeByte('\n');
    }

    try w.writeByte('\n');
    // Indented to the path column: a line at the left edge reads as a new
    // section rather than as the sum of the one above it.
    try w.splatByteAll(' ', head);
    try paint(w, opts, t.text, try i18n.allocPrint(arena, "{d} file{s}", .{
        rows.len,
        // The plural as an argument, the way the rest of the tool asks.
        if (rows.len == 1) "" else "s",
    }));
    // Signed even at zero, where a row prints a bare `0`: a row has columns
    // to say which side a number is on, this line has only itself.
    try w.splatByteAll(' ', gap);
    try paint(w, opts, t.added_count, try std.fmt.allocPrint(arena, "+{d}", .{total_added}));
    try w.splatByteAll(' ', gap);
    try paint(w, opts, t.removed_count, try std.fmt.allocPrint(arena, "{s}{d}", .{
        opts.glyphs.del,
        total_removed,
    }));
    try w.splatByteAll(' ', gap);
    try paint(w, opts, t.dim, try scope(arena, opts));
    try w.writeByte('\n');

    try key(w, rows, opts);
    try w.writeByte('\n');
}

/// What the stage marks mean, under the totals, listing only the ones the
/// table actually used.
///
/// Silent for a tree where nothing is staged. Every row then carries the same
/// mark, and a key explaining a column that says the same thing all the way
/// down is the kind of permanent furniture that stops being read. It appears
/// as soon as the index has anything to say, which is the moment the marks
/// start differing and the moment the reader needs them.
fn key(w: *std.Io.Writer, rows: []const Row, opts: Options) Error!void {
    if (!marked(opts)) return;

    var seen: [4]bool = @splat(false);
    for (rows) |r| seen[@intFromEnum(r.stage)] = true;
    if (!seen[@intFromEnum(git.Stage.staged)] and
        !seen[@intFromEnum(git.Stage.both)] and
        !seen[@intFromEnum(git.Stage.untracked)]) return;

    try w.splatByteAll(' ', headOf(opts));
    var first = true;
    for ([_]git.Stage{ .staged, .both, .unstaged, .untracked }) |st| {
        if (!seen[@intFromEnum(st)]) continue;
        if (!first) try w.splatByteAll(' ', gap + 1);
        first = false;
        // Untracked is marked by its letter, not by a fill, so the key shows
        // the letter - otherwise it names a glyph that is nowhere above it.
        const mark = if (st == .untracked) "?" else stageMark(st, opts.glyphs);
        try paint(w, opts, stageStyle(opts.theme, st), mark);
        try w.writeByte(' ');
        try paint(w, opts, opts.theme.dim, word(st));
    }
    try w.writeByte('\n');
}

fn word(st: git.Stage) []const u8 {
    return switch (st) {
        .staged => i18n.t("staged"),
        .both => i18n.t("both"),
        .unstaged => i18n.t("unstaged"),
        .untracked => i18n.t("untracked"),
    };
}

/// What the totals are totals *of*: the two sides compared, and how many files
/// `[review] ignore` kept out of them. One whole sentence per case, because a
/// translation of ", {d} ignored" alone would not know what it followed.
fn scope(arena: Allocator, opts: Options) Allocator.Error![]const u8 {
    if (opts.target) |target| {
        // A range reads the same in every language.
        if (opts.hidden == 0) return std.fmt.allocPrint(arena, "{s}..{s}", .{ opts.base, target });
        return i18n.allocPrint(arena, "{s}..{s}, {d} ignored", .{ opts.base, target, opts.hidden });
    }
    if (opts.hidden == 0) return i18n.allocPrint(arena, "against {s}", .{opts.base});
    return i18n.allocPrint(arena, "against {s}, {d} ignored", .{ opts.base, opts.hidden });
}

/// Rows in tree order: a directory holding more than one changed file becomes
/// a header, its files listed under it by name. Everything else keeps its
/// whole path - a lone file is not a tree, and a file at the root has no
/// directory to hang under.
///
/// Grouped by the directory of the *shown* name, which is what makes a rename
/// need no special case: `src/ui/{app => screen}.zig` sits under `src/ui`
/// like any other file there, and one that moved between directories reads as
/// `src/{ui => core}/app.zig`, whose directory matches nothing and is left
/// whole.
fn grouped(arena: Allocator, rows: []const Row, g: Glyphs) Allocator.Error![]Row {
    const claimed = try arena.alloc(bool, rows.len);
    @memset(claimed, false);

    // Two columns of rail with an indent before it and a space after, so
    // every name under a header starts at the same column.
    const branch = try std.fmt.allocPrint(arena, "  {s} ", .{g.tree_branch});
    const closing = try std.fmt.allocPrint(arena, "  {s} ", .{g.tree_last});

    var out: std.ArrayList(Row) = try .initCapacity(arena, rows.len);
    var members: std.ArrayList(usize) = .empty;

    for (rows, 0..) |r, i| {
        if (claimed[i]) continue;
        const dir = dirOf(r.text);

        // Forward only: anything earlier in this directory has already taken
        // this row into its own group.
        members.clearRetainingCapacity();
        try members.append(arena, i);
        if (dir.len > 0) {
            for (rows[i + 1 ..], i + 1..) |other, j| {
                if (claimed[j] or !std.mem.eql(u8, dir, dirOf(other.text))) continue;
                claimed[j] = true;
                try members.append(arena, j);
            }
        }

        if (members.items.len == 1) {
            out.appendAssumeCapacity(r);
            continue;
        }

        const last = members.items.len - 1;
        for (members.items, 0..) |m, n| {
            var row = rows[m];
            row.header = if (n == 0) try std.fmt.allocPrint(arena, "{s}/", .{dir}) else "";
            row.rail = if (n == last) closing else branch;
            row.text = row.text[dir.len + 1 ..];
            out.appendAssumeCapacity(row);
        }
    }
    return out.items;
}

/// The directory a shown name sits in, without its trailing slash. Empty at
/// the root.
fn dirOf(text: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, text, '/') orelse return "";
    return text[0..cut];
}

/// The widest cell in each column, before the terminal gets a say.
const Widths = struct {
    text: u16,
    added: u16,
    removed: u16,
    /// Zero when no row has an age; the column then does not exist.
    age: u16,
};

/// Room for `+4294967295` with a three-byte minus in front of it.
const count_max = 16;
const age_max = 32;

fn measure(rows: []const Row, opts: Options) Widths {
    var out: Widths = .{ .text = 0, .added = 0, .removed = 0, .age = 0 };
    for (rows) |r| {
        var buf: [count_max]u8 = undefined;
        var when: [age_max]u8 = undefined;
        out.text = @max(out.text, wrap.columns(r.rail, metrics) + wrap.columns(r.text, metrics));
        out.added = @max(out.added, wrap.columns(addedCell(&buf, r), metrics));
        out.removed = @max(out.removed, wrap.columns(removedCell(&buf, r, opts.glyphs), metrics));
        out.age = @max(out.age, wrap.columns(ageCell(&when, r, opts.now), metrics));
    }
    return out;
}

/// The same widths, fitted to what stdout has. The path column is what gives:
/// every other one is a number, already as short as it can be said.
fn fitted(natural: Widths, cols: ?u16, head: u16) Widths {
    var out = natural;
    const room = cols orelse return out;

    // Unless shrinking it would leave no path to read. Then the age goes
    // instead: it is the widest of the trailing columns and the least of what
    // a row says.
    if (out.age > 0 and room -| fixedOf(out, head) < min_text) out.age = 0;

    const budget = room -| fixedOf(out, head);
    if (budget < natural.text) out.text = @max(min_text, budget);
    return out;
}

/// What a row spends that is not the path, in the order it spends it.
fn fixedOf(w: Widths, head: u16) u16 {
    return head + gap + w.added + gap + w.removed + (if (w.age > 0) gap + w.age else 0);
}

/// A letter as well as the colour, where the `F` list uses colour alone: this
/// output is routinely a pipe, and a pipe has no colours.
/// Untracked answers before the diff status does. Every untracked file is a
/// synthesised whole-file add, so it arrives as `.added` and would otherwise
/// be lettered `A` - the same letter as a file deliberately staged for
/// addition, which is the opposite intention.
fn letter(status: diff.Status, stage: git.Stage) []const u8 {
    if (stage == .untracked) return "?";
    return switch (status) {
        .modified => "M",
        .added => "A",
        .deleted => "D",
        .renamed => "R",
        .binary => "B",
    };
}

/// The same five answers `ui/render.zig` paints a path with, so a file is the
/// same colour here as it is on the screen.
fn statusStyle(t: Theme, status: diff.Status, stage: git.Stage) Style {
    if (stage == .untracked) return t.stage_untracked;
    return switch (status) {
        .added => t.file_added,
        .deleted => t.file_deleted,
        .modified => t.file_modified,
        .renamed => t.file_renamed,
        .binary => t.file_binary,
    };
}

/// How much of this file's change is in the index, as a fill: full, half,
/// empty. Untracked has none - the `?` in the letter column is the whole
/// answer, and a mark beside it would be a second one.
fn stageMark(stage: git.Stage, g: Glyphs) []const u8 {
    return switch (stage) {
        .staged => g.stage_staged,
        .both => g.stage_both,
        .unstaged => g.stage_unstaged,
        .untracked => "",
    };
}

fn stageStyle(t: Theme, stage: git.Stage) Style {
    return switch (stage) {
        .staged => t.stage_staged,
        .both => t.stage_both,
        .unstaged => t.stage_unstaged,
        .untracked => t.stage_untracked,
    };
}

/// `+12`, or a bare `0`. Nothing for a binary file: it has no lines, and a `0`
/// would read as a file that did not change.
fn addedCell(buf: []u8, r: Row) []const u8 {
    if (r.status == .binary) return "";
    if (r.added == 0) return "0";
    return std.fmt.bufPrint(buf, "+{d}", .{r.added}) catch "";
}

fn removedCell(buf: []u8, r: Row, g: Glyphs) []const u8 {
    if (r.status == .binary) return "";
    if (r.removed == 0) return "0";
    return std.fmt.bufPrint(buf, "{s}{d}", .{ g.del, r.removed }) catch "";
}

fn ageCell(buf: []u8, r: Row, now: i64) []const u8 {
    const when = r.when orelse return "";
    return thread.ago(buf, now - when);
}

fn paint(w: *std.Io.Writer, opts: Options, style: Style, text: []const u8) std.Io.Writer.Error!void {
    // An empty cell is padding, not a colour: without this a binary file's
    // blank counts go out as escapes wrapped around nothing.
    if (!opts.colour or text.len == 0) return w.writeAll(text);
    return preview.styled(w, style, text);
}

const testing = std.testing;

/// The plain rendering, as a pipe would get it.
fn drawn(arena: Allocator, buf: []u8, rows: []const Row, opts_in: Options) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var opts = opts_in;
    opts.colour = false;
    try draw(arena, &w, rows, opts);
    return w.buffered();
}

const test_opts: Options = .{
    .theme = theme_mod.default,
    .glyphs = Glyphs.ascii,
    .colour = false,
    .now = 1_000_000,
};

const test_rows: []const Row = &.{
    .{ .text = "src/ui/app.zig", .status = .modified, .added = 12, .removed = 4, .when = 1_000_000 - 120 },
    .{ .text = "src/ui/status.zig", .status = .added, .added = 210, .removed = 0, .when = 1_000_000 - 30 },
    .{ .text = "src/ui/app_old.zig", .status = .deleted, .added = 0, .removed = 99 },
    .{ .text = "logo.png", .status = .binary, .added = 0, .removed = 0, .when = 1_000_000 - 86400 },
};

test "every file is a row, with its counts and its age" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_rows, test_opts);

    var it = std.mem.tokenizeScalar(u8, out, '\n');
    const modified = it.next().?;
    try testing.expect(std.mem.startsWith(u8, modified, " . M  src/ui/app.zig"));
    try testing.expect(std.mem.indexOf(u8, modified, "+12") != null);
    try testing.expect(std.mem.indexOf(u8, modified, "-4") != null);
    try testing.expect(std.mem.endsWith(u8, modified, "2m ago"));

    const added = it.next().?;
    try testing.expect(std.mem.startsWith(u8, added, " . A  src/ui/status.zig"));
    try testing.expect(std.mem.endsWith(u8, added, "just now"));

    // Nothing on disk to stat, so the row ends at its counts.
    const deleted = it.next().?;
    try testing.expect(std.mem.startsWith(u8, deleted, " . D  src/ui/app_old.zig"));
    try testing.expect(std.mem.endsWith(u8, deleted, "-99"));

    // A binary file has no lines to count. Neither cell says zero.
    const binary = it.next().?;
    try testing.expect(std.mem.startsWith(u8, binary, " . B  logo.png"));
    try testing.expect(std.mem.indexOf(u8, binary, "0") == null);
    try testing.expect(std.mem.endsWith(u8, binary, "1d ago"));
}

test "the totals are what the rows add up to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_rows, test_opts);

    try testing.expect(std.mem.indexOf(u8, out, "4 files  +222  -103  against HEAD") != null);
}

test "the base, the ref pair and the ignored count all reach the footer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.base = "main";
    opts.hidden = 2;
    try testing.expect(std.mem.indexOf(
        u8,
        try drawn(arena.allocator(), &buf, test_rows, opts),
        "against main, 2 ignored",
    ) != null);

    // A ref against a ref is a range, not a comparison with the tree that
    // happens to be checked out.
    var buf2: [4 << 10]u8 = undefined;
    opts.target = "v1.2";
    opts.hidden = 0;
    try testing.expect(std.mem.indexOf(
        u8,
        try drawn(arena.allocator(), &buf2, test_rows, opts),
        "main..v1.2",
    ) != null);
}

test "one file is a file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_rows[0..1], test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "1 file  +12") != null);
}

test "a clean tree says so rather than printing an empty table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, &.{}, test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "nothing to review: the working tree matches HEAD") != null);

    var opts = test_opts;
    opts.target = "v1.2";
    var buf2: [1 << 10]u8 = undefined;
    const ref = try drawn(arena.allocator(), &buf2, &.{}, opts);
    try testing.expect(std.mem.indexOf(u8, ref, "nothing to review: v1.2 matches HEAD") != null);
}

test "the columns line up, whatever is in them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_rows, test_opts);

    // The counts are right-aligned and the path is padded, so the age starts
    // at one column on every row that has one.
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    const at = std.mem.indexOf(u8, it.next().?, "2m ago").?;
    try testing.expectEqual(at, std.mem.indexOf(u8, it.next().?, "just now").?);
    _ = it.next();
    try testing.expectEqual(at, std.mem.indexOf(u8, it.next().?, "1d ago").?);
}

test "a narrow terminal takes the path apart from the front, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.cols = 40;
    const out = try drawn(arena.allocator(), &buf, test_rows, opts);

    var it = std.mem.tokenizeScalar(u8, out, '\n');
    for (0..test_rows.len) |_| {
        const row = it.next().?;
        try testing.expect(wrap.columns(row, metrics) <= 40);
    }
    // The name survives; the directories above it are what went.
    try testing.expect(std.mem.indexOf(u8, out, "status.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+210") != null);
}

test "a pipe has no width to fit to, so nothing is shortened" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    const out = try drawn(arena.allocator(), &buf, test_rows, test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "src/ui/app_old.zig") != null);
}

test "a directory with more than one changed file becomes a header with rails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.tree = true;
    const out = try drawn(arena.allocator(), &buf, test_rows, opts);

    var it = std.mem.tokenizeScalar(u8, out, '\n');
    try testing.expectEqualStrings("      src/ui/", it.next().?);
    try testing.expect(std.mem.startsWith(u8, it.next().?, " . M    |- app.zig"));
    try testing.expect(std.mem.startsWith(u8, it.next().?, " . A    |- status.zig"));
    // The last of a group closes it.
    try testing.expect(std.mem.startsWith(u8, it.next().?, " . D    \\- app_old.zig"));
    // A file at the root is in no directory, so it is in no group.
    try testing.expect(std.mem.startsWith(u8, it.next().?, " . B  logo.png"));

    // Grouping only moves the names; the numbers are the same ones.
    try testing.expect(std.mem.indexOf(u8, out, "4 files  +222  -103  against HEAD") != null);
}

test "one file in a directory is not a tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.tree = true;
    const rows: []const Row = &.{
        .{ .text = "src/core/git.zig", .status = .modified, .added = 87, .removed = 2 },
        .{ .text = "build.zig", .status = .modified, .added = 20, .removed = 1 },
    };
    const out = try drawn(arena.allocator(), &buf, rows, opts);

    try testing.expect(std.mem.indexOf(u8, out, "src/core/git.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "|-") == null);
    try testing.expect(std.mem.indexOf(u8, out, "src/core/\n") == null);
}

test "a rename that left its directory is left whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.tree = true;
    const rows: []const Row = &.{
        // Its directory is `src/{ui => core}`, which is nothing else's.
        .{ .text = "src/{ui => core}/app.zig", .status = .renamed, .added = 3, .removed = 3 },
        // This one never left `src/ui`, so it groups like any other file there.
        .{ .text = "src/ui/{app => screen}.zig", .status = .renamed, .added = 1, .removed = 1 },
        .{ .text = "src/ui/theme.zig", .status = .modified, .added = 2, .removed = 0 },
    };
    const out = try drawn(arena.allocator(), &buf, rows, opts);

    try testing.expect(std.mem.indexOf(u8, out, " R  src/{ui => core}/app.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    src/ui/\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "|- {app => screen}.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\- theme.zig") != null);
}

test "a terminal too narrow for both drops the age before the path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.tree = true;
    opts.cols = 34;
    const out = try drawn(arena.allocator(), &buf, test_rows, opts);

    // The table rows only: the totals under them are a sentence, and a
    // sentence wraps rather than being cut.
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    for (0..test_rows.len + 1) |_| {
        try testing.expect(wrap.columns(it.next().?, metrics) <= 34);
    }
    // The names and the rails both survive; the clock is what went.
    try testing.expect(std.mem.indexOf(u8, out, "\\- app_old.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ago") == null);
}

test "a moved file is named the way git names one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files: []const diff.FileDiff = &.{
        .{ .old_path = "src/ui/app.zig", .new_path = "src/core/app.zig", .status = .renamed, .added = 3, .removed = 3 },
    };
    // Ages off, so nothing is stat'd - the same thing a two-ref review passes.
    const rows = try collect(arena.allocator(), undefined, files, false, null);
    try testing.expectEqualStrings("src/{ui => core}/app.zig", rows[0].text);
}

test "colour is one escape run per cell, and a pipe gets none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var opts = test_opts;
    opts.colour = true;
    try draw(arena.allocator(), &w, test_rows, opts);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[") != null);

    var plain: [4 << 10]u8 = undefined;
    try testing.expect(std.mem.indexOf(
        u8,
        try drawn(arena.allocator(), &plain, test_rows, test_opts),
        "\x1b[",
    ) == null);
}

test "the stage mark says which side of the index a change is on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    const rows: []const Row = &.{
        .{ .text = "staged.zig", .status = .modified, .stage = .staged, .added = 1, .removed = 0 },
        .{ .text = "both.zig", .status = .modified, .stage = .both, .added = 2, .removed = 0 },
        .{ .text = "unstaged.zig", .status = .modified, .stage = .unstaged, .added = 3, .removed = 0 },
        .{ .text = "untracked.zig", .status = .added, .stage = .untracked, .added = 4, .removed = 0 },
    };
    const out = try drawn(arena.allocator(), &buf, rows, test_opts);

    var it = std.mem.tokenizeScalar(u8, out, '\n');
    try testing.expect(std.mem.startsWith(u8, it.next().?, " * M  staged.zig"));
    try testing.expect(std.mem.startsWith(u8, it.next().?, " o M  both.zig"));
    try testing.expect(std.mem.startsWith(u8, it.next().?, " . M  unstaged.zig"));
    // An untracked file is a synthesised whole-file add, so its status is
    // `.added`. Lettering it `A` would make it identical to the file above it
    // in a tree where one was staged and the other never added at all.
    try testing.expect(std.mem.startsWith(u8, it.next().?, "   ?  untracked.zig"));
}

test "the key lists only the marks the table used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    const some: []const Row = &.{
        .{ .text = "a.zig", .status = .modified, .stage = .staged, .added = 1, .removed = 0 },
        .{ .text = "b.zig", .status = .modified, .stage = .unstaged, .added = 1, .removed = 0 },
    };
    const out = try drawn(arena.allocator(), &buf, some, test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "* staged") != null);
    try testing.expect(std.mem.indexOf(u8, out, ". unstaged") != null);
    // Neither of these is on screen, so neither is explained.
    try testing.expect(std.mem.indexOf(u8, out, "o both") == null);
    try testing.expect(std.mem.indexOf(u8, out, "? untracked") == null);
}

test "a tree with nothing staged gets no key at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    // The ordinary case: every row carries the same mark, so a key would
    // explain a column that says the same thing all the way down.
    const out = try drawn(arena.allocator(), &buf, test_rows, test_opts);
    try testing.expect(std.mem.indexOf(u8, out, "unstaged") == null);
    try testing.expect(std.mem.indexOf(u8, out, "staged") == null);
}

test "a two-ref review spends no width on a column it cannot answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [4 << 10]u8 = undefined;

    var opts = test_opts;
    opts.target = "feature";
    const out = try drawn(arena.allocator(), &buf, test_rows, opts);

    // Between two refs there is no index, so the row starts at its letter and
    // the table is two columns narrower.
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    try testing.expect(std.mem.startsWith(u8, it.next().?, " M  src/ui/app.zig"));
    try testing.expect(std.mem.indexOf(u8, out, "staged") == null);
}
