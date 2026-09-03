// SPDX-License-Identifier: Apache-2.0
//
// Which highlighter a file gets, and the cache that keeps re-diffs from
// re-scanning files nobody touched (ARCHITECTURE.md 5).
//
// The user never sees an unhighlighted screen as a failure: an unknown
// language, an oversized file or a missing lexer all fall back to `.plain`,
// which renders correctly and just has no colour.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const metrics = @import("../io/metrics.zig");

pub const LangDef = lexer.LangDef;
pub const Lexer = lexer.Lexer;
pub const Structure = lexer.Structure;
pub const Run = lexer.Run;
pub const State = lexer.State;

/// Guard rails, shared with the diff summary path's thresholds.
pub const max_bytes = 500 * 1024;
pub const max_lines = 10_000;

const zig_lang = @import("lang/zig.zig");
const rust_lang = @import("lang/rust.zig");
const go_lang = @import("lang/go.zig");
const python_lang = @import("lang/python.zig");
const swift_lang = @import("lang/swift.zig");
const javascript_lang = @import("lang/javascript.zig");
const typescript_lang = @import("lang/typescript.zig");
const css_lang = @import("lang/css.zig");
const html_lang = @import("lang/html.zig");

pub const languages = [_]*const LangDef{
    &zig_lang.def,
    &rust_lang.def,
    &go_lang.def,
    &python_lang.def,
    &swift_lang.def,
    &javascript_lang.def,
    &typescript_lang.def,
    &css_lang.def,
    &html_lang.def,
};

/// Extension match, lower-cased. Everything unrecognised renders plain.
///
/// The basename is found by hand rather than with std.fs.path: std.fs is
/// quarantined to io/fs.zig, and this is one `lastIndexOfScalar`.
pub fn byExtension(path: []const u8) ?*const LangDef {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |n| path[n + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return null;

    var lower: [8]u8 = undefined;
    for (ext, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const want = lower[0..ext.len];

    for (languages) |def| {
        for (def.extensions) |e| {
            if (std.mem.eql(u8, e, want)) return def;
        }
    }
    return null;
}

pub fn byName(name: []const u8) ?*const LangDef {
    for (languages) |def| {
        if (std.mem.eql(u8, def.name, name)) return def;
    }
    return null;
}

/// Not built in v0.1. The variant exists so linking a grammar later is a
/// change here and nowhere else (ARCHITECTURE.md 5).
pub const TreeSitter = struct {};

pub const Highlighter = union(enum) {
    lexer: Lexer,
    tree_sitter: TreeSitter,
    plain,

    /// Chosen per language *and* per file size. `lines` comes from the caller
    /// because the Buffer already counted them; counting again would be a
    /// second pass over the file for nothing.
    pub fn choose(path: []const u8, byte_len: usize, lines: u32) Highlighter {
        if (byte_len > max_bytes or lines > max_lines) return .plain;
        const def = byExtension(path) orelse return .plain;
        return .{ .lexer = .init(def) };
    }

    /// Whole-file pass: checkpoints and function spans. Empty for `.plain`,
    /// which means callers need no special case - `enclosingFn` just returns
    /// null and `checkpointFor` returns the zero state.
    pub fn structure(self: Highlighter, gpa: Allocator, text: []const u8) Allocator.Error!Structure {
        return switch (self) {
            .lexer => |lx| lx.structure(gpa, text),
            // Zero-length allocations, so the caller's deinit is unconditional
            // and the field types stay the same on both paths.
            .tree_sitter, .plain => .{
                .checkpoints = try gpa.alloc(lexer.Checkpoint, 0),
                .fns = try gpa.alloc(lexer.FnDecl, 0),
                .lines = 0,
            },
        };
    }

    /// Runs for one span. `.plain` emits a single `.text` run per line so the
    /// renderer's walk is identical either way.
    pub fn lex(
        self: Highlighter,
        gpa: Allocator,
        text: []const u8,
        from: usize,
        to: usize,
        state: State,
        out: *std.ArrayList(Run),
    ) Allocator.Error!State {
        switch (self) {
            .lexer => |lx| return lx.lex(gpa, text, from, to, state, out),
            .tree_sitter, .plain => {
                var at = from;
                while (at < to) {
                    const nl = std.mem.indexOfScalarPos(u8, text[0..to], at, '\n');
                    const stop = if (nl) |n| n + 1 else to;
                    var chunk = at;
                    while (chunk < stop) {
                        const len: u16 = @intCast(@min(stop - chunk, lexer.max_run_len));
                        try out.append(gpa, .{ .start = @intCast(chunk), .len = len, .kind = .text });
                        chunk += len;
                    }
                    at = stop;
                }
                return state;
            },
        }
    }
};

/// Fallback key for a caller with nothing better. Prefer the blob hash git
/// already handed us on the `index a..b` line: hashing the file on every
/// lookup makes a cache hit cost the same order as the miss it was meant to
/// avoid - 5.1 us on a 200 KB corpus, measured, against 0.9 ms to just redo
/// the work.
pub fn hashContent(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// LRU over whole-file work, keyed by content hash. The agent touches six
/// files but usually changes one or two; the rest cost nothing on re-diff.
/// This is the optimisation that matters, not micro-tuning the lexer
/// (ARCHITECTURE.md 5).
///
/// An entry holds the structure pass eagerly and the whole-file token runs
/// lazily, because a caller that only wants a hunk header should not pay for
/// runs it will never draw.
///
/// Entries are self-contained: function names are copied into one block per
/// entry rather than borrowed from the file, so an entry outliving the buffer
/// it was built from is safe rather than a dangling read. Token runs are byte
/// offsets, which are safe for the same reason - though useless without the
/// text they index.
pub const Cache = struct {
    pub const capacity = 32;

    const Entry = struct {
        key: u64,
        used: u64,
        structure: Structure,
        names: []u8,
        /// Filled on the first `runsFor`, not on insert.
        runs: ?[]Run = null,

        fn deinit(self: *Entry, gpa: Allocator) void {
            self.structure.deinit(gpa);
            gpa.free(self.names);
            if (self.runs) |r| gpa.free(r);
            self.* = undefined;
        }
    };

    entries: [capacity]?Entry = @splat(null),
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn deinit(self: *Cache, gpa: Allocator) void {
        for (&self.entries) |*slot| {
            if (slot.*) |*e| e.deinit(gpa);
            slot.* = null;
        }
        self.* = undefined;
    }

    /// Cached structure, or null. Counts towards the hit/miss tally, so
    /// `--profile` can show whether the cache is earning its keep.
    pub fn get(self: *Cache, key: u64) ?*const Structure {
        if (self.find(key)) |e| return &e.structure;
        return null;
    }

    fn find(self: *Cache, key: u64) ?*Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |*e| {
                if (e.key != key) continue;
                self.clock += 1;
                e.used = self.clock;
                self.hits += 1;
                return e;
            }
        }
        self.misses += 1;
        return null;
    }

    /// Structure for `text`, computed on miss. Instrumented, so `--profile`
    /// answers whether the whole-file pass ever needs splitting into
    /// visible-range work (ARCHITECTURE.md open question 5).
    ///
    /// `key` identifies the content and is supplied by the caller rather than
    /// derived here: core/diff.zig already has git's blob hash, and re-hashing
    /// the file on every lookup would cost more than it saves.
    ///
    /// The returned pointer is valid until the next call that can evict.
    pub fn structureFor(
        self: *Cache,
        gpa: Allocator,
        hl: Highlighter,
        key: u64,
        text: []const u8,
    ) Allocator.Error!*const Structure {
        const e = try self.entryFor(gpa, hl, key, text);
        return &e.structure;
    }

    /// Whole-file token runs for `text`, lexed and cached on first use.
    ///
    /// A renderer drawing one screen should prefer `Highlighter.lex` from the
    /// nearest checkpoint over this: the point of checkpoints is that a
    /// visible range costs 64 lines, not the file. This exists for callers
    /// that genuinely walk the whole file.
    pub fn runsFor(
        self: *Cache,
        gpa: Allocator,
        hl: Highlighter,
        key: u64,
        text: []const u8,
    ) Allocator.Error![]const Run {
        const e = try self.entryFor(gpa, hl, key, text);
        if (e.runs) |r| return r;

        const span = metrics.span(.lex);
        defer span.end();

        var out: std.ArrayList(Run) = .empty;
        errdefer out.deinit(gpa);
        _ = try hl.lex(gpa, text, 0, text.len, .{}, &out);
        const owned = try out.toOwnedSlice(gpa);
        e.runs = owned;
        return owned;
    }

    fn entryFor(
        self: *Cache,
        gpa: Allocator,
        hl: Highlighter,
        key: u64,
        text: []const u8,
    ) Allocator.Error!*Entry {
        if (self.find(key)) |e| return e;

        const span = metrics.span(.lex);
        defer span.end();
        return self.put(gpa, key, try hl.structure(gpa, text));
    }

    /// Takes ownership of `s`. On failure `s` is freed rather than leaked,
    /// because the caller has already handed it over.
    fn put(self: *Cache, gpa: Allocator, key: u64, s: Structure) Allocator.Error!*Entry {
        var owned = s;
        errdefer owned.deinit(gpa);

        var total: usize = 0;
        for (owned.fns) |f| total += f.name.len;
        const names = try gpa.alloc(u8, total);
        errdefer gpa.free(names);

        var at: usize = 0;
        for (owned.fns) |*f| {
            @memcpy(names[at .. at + f.name.len], f.name);
            f.name = names[at .. at + f.name.len];
            at += f.name.len;
        }

        const idx = self.victim();
        if (self.entries[idx]) |*old| old.deinit(gpa);
        self.clock += 1;
        self.entries[idx] = .{
            .key = key,
            .used = self.clock,
            .structure = owned,
            .names = names,
        };
        return &self.entries[idx].?;
    }

    fn victim(self: *Cache) usize {
        var oldest: usize = 0;
        var oldest_used: u64 = std.math.maxInt(u64);
        for (&self.entries, 0..) |*slot, i| {
            const e = slot.* orelse return i;
            if (e.used < oldest_used) {
                oldest_used = e.used;
                oldest = i;
            }
        }
        return oldest;
    }
};

const testing = std.testing;

test "extensions map to languages, case-insensitively" {
    try testing.expectEqualStrings("zig", byExtension("src/core/diff.zig").?.name);
    try testing.expectEqualStrings("rust", byExtension("src/main.RS").?.name);
    try testing.expectEqualStrings("go", byExtension("cmd/serve.go").?.name);
    try testing.expectEqualStrings("python", byExtension("tools/run.py").?.name);
    try testing.expectEqualStrings("swift", byExtension("Views/Launchpad.swift").?.name);
    try testing.expectEqualStrings("javascript", byExtension("web/app.jsx").?.name);
    try testing.expectEqualStrings("typescript", byExtension("web/App.tsx").?.name);
    try testing.expectEqualStrings("css", byExtension("web/main.scss").?.name);
    try testing.expectEqualStrings("html", byExtension("web/index.html").?.name);
    try testing.expect(byExtension("Makefile") == null);
    try testing.expect(byExtension("notes.txt") == null);
    // A dot in a directory name is not an extension.
    try testing.expect(byExtension("a.b/Makefile") == null);
}

test "guard rails fall back to plain rather than failing" {
    try testing.expect(Highlighter.choose("a.zig", 100, 10) == .lexer);
    try testing.expect(Highlighter.choose("a.zig", max_bytes + 1, 10) == .plain);
    try testing.expect(Highlighter.choose("a.zig", 100, max_lines + 1) == .plain);
    try testing.expect(Highlighter.choose("a.unknown", 100, 10) == .plain);
}

test "plain emits one text run per line so the renderer's walk is uniform" {
    const gpa = testing.allocator;
    const src = "alpha\nbeta\n\ngamma";
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);

    const hl: Highlighter = .plain;
    _ = try hl.lex(gpa, src, 0, src.len, .{}, &out);

    try testing.expectEqual(@as(usize, 4), out.items.len);
    var at: u32 = 0;
    for (out.items) |r| {
        try testing.expectEqual(at, r.start);
        try testing.expectEqual(lexer.Kind.text, r.kind);
        at = r.end();
    }
    try testing.expectEqual(@as(u32, src.len), at);
}

test "plain structure is empty but safe to use and free" {
    const gpa = testing.allocator;
    const hl: Highlighter = .plain;
    var st = try hl.structure(gpa, "anything at all\n");
    defer st.deinit(gpa);

    try testing.expect(st.enclosingFn(0) == null);
    try testing.expectEqual(@as(u32, 0), st.checkpointFor(0).line);
}

test "the cache hits on identical content and misses on a change" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const hl = Highlighter.choose("x.zig", 40, 3);
    const a = "pub fn one() void {}\n";
    const b = "pub fn two() void {}\n";

    _ = try cache.structureFor(gpa, hl, hashContent(a), a);
    _ = try cache.structureFor(gpa, hl, hashContent(a), a);
    _ = try cache.structureFor(gpa, hl, hashContent(b), b);

    try testing.expectEqual(@as(u64, 1), cache.hits);
    try testing.expectEqual(@as(u64, 2), cache.misses);
}

test "cached entries do not borrow from the file they were built from" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const src = try gpa.dupe(u8, "pub fn borrowed() void {}\n");
    const hl = Highlighter.choose("x.zig", src.len, 1);
    const st = try cache.structureFor(gpa, hl, hashContent(src), src);

    const name = st.fns[0].name;
    // The copy is what makes an entry outliving its buffer safe rather than a
    // dangling read, so assert the pointer really moved.
    try testing.expect(@intFromPtr(name.ptr) < @intFromPtr(src.ptr) or
        @intFromPtr(name.ptr) >= @intFromPtr(src.ptr) + src.len);

    gpa.free(src);
    try testing.expectEqualStrings("borrowed", cache.get(hashContent("pub fn borrowed() void {}\n")).?.fns[0].name);
}

test "the cache evicts least-recently-used past capacity" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const hl = Highlighter.choose("x.zig", 40, 3);
    var buf: [64]u8 = undefined;

    // Fill it, then keep entry 0 warm while pushing one more in.
    for (0..Cache.capacity) |i| {
        const src = try std.fmt.bufPrint(&buf, "pub fn f{d}() void {{}}\n", .{i});
        _ = try cache.structureFor(gpa, hl, hashContent(src), src);
    }
    const first = try std.fmt.bufPrint(&buf, "pub fn f{d}() void {{}}\n", .{0});
    try testing.expect(cache.get(hashContent(first)) != null);

    const extra = "pub fn extra() void {}\n";
    _ = try cache.structureFor(gpa, hl, hashContent(extra), extra);

    // The warm entry survived; the coldest one did not.
    const refetch = try std.fmt.bufPrint(&buf, "pub fn f{d}() void {{}}\n", .{0});
    try testing.expect(cache.get(hashContent(refetch)) != null);
    const cold = try std.fmt.bufPrint(&buf, "pub fn f{d}() void {{}}\n", .{1});
    try testing.expect(cache.get(hashContent(cold)) == null);
}

test "token runs are lexed once and reused" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const src = "pub fn once() void {\n    const s = \"x\";\n}\n";
    const hl = Highlighter.choose("x.zig", src.len, 3);

    const first = try cache.runsFor(gpa, hl, hashContent(src), src);
    const second = try cache.runsFor(gpa, hl, hashContent(src), src);

    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expect(first.len > 5);
    // Structure and runs share one entry, so asking for the structure after
    // the runs is a hit rather than a second whole-file pass.
    const st = try cache.structureFor(gpa, hl, hashContent(src), src);
    try testing.expectEqualStrings("once", st.fns[0].name);
}

test "eviction frees cached runs as well as the structure" {
    const gpa = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);

    const hl = Highlighter.choose("x.zig", 40, 3);
    var buf: [64]u8 = undefined;
    // One more than capacity, each with runs materialised: a leak here shows
    // up as a testing.allocator failure.
    for (0..Cache.capacity + 1) |i| {
        const src = try std.fmt.bufPrint(&buf, "pub fn f{d}() void {{}}\n", .{i});
        _ = try cache.runsFor(gpa, hl, hashContent(src), src);
    }
}
