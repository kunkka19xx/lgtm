// SPDX-License-Identifier: Apache-2.0
//
// Re-anchoring. The primary path is a table lookup through an old-to-new line
// map, not a search (PERFORMANCE.md 3.1). Fallback tiers come later; this file
// is the part the go/no-go gate measures.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const window = 5;
const half_window = window / 2;

/// Maps each distinct line to a u32 so everything downstream compares integers
/// (PERFORMANCE.md 1.1). Wyhash, never a cryptographic hash (2.1).
pub const Interner = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    next: u32 = 0,

    pub fn deinit(self: *Interner, gpa: Allocator) void {
        self.map.deinit(gpa);
        self.* = undefined;
    }

    pub fn intern(self: *Interner, gpa: Allocator, line: []const u8) Allocator.Error!u32 {
        const gop = try self.map.getOrPut(gpa, line);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.next;
            self.next += 1;
        }
        return gop.value_ptr.*;
    }

    /// Interns every line of `text`. Slices borrow from `text`, so it must
    /// outlive the interner.
    pub fn internLines(self: *Interner, gpa: Allocator, text: []const u8) Allocator.Error![]u32 {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(gpa);

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            try ids.append(gpa, try self.intern(gpa, line));
        }
        // A trailing newline yields a final empty field that is not a line.
        if (ids.items.len > 0 and text.len > 0 and text[text.len - 1] == '\n') {
            _ = ids.pop();
        }
        return ids.toOwnedSlice(gpa);
    }
};

/// Hashes a window of lines centred on `line`, never a single line: duplicate
/// lines are the norm in source, duplicate windows are not (PERFORMANCE.md 2.2).
pub fn windowHash(ids: []const u32, line: usize) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var i: isize = @as(isize, @intCast(line)) - half_window;
    const end = i + window;
    while (i < end) : (i += 1) {
        const id: u32 = if (i < 0 or i >= ids.len) std.math.maxInt(u32) else ids[@intCast(i)];
        hasher.update(std.mem.asBytes(&id));
    }
    return hasher.final();
}

/// Exact correspondence between two versions of a file. `deleted` means the
/// line has no counterpart, which is what makes a note a candidate for the
/// fallback tiers.
pub const LineMap = struct {
    pub const deleted = std.math.maxInt(u32);

    old_to_new: []u32,

    pub fn deinit(self: *LineMap, gpa: Allocator) void {
        gpa.free(self.old_to_new);
        self.* = undefined;
    }

    pub fn get(self: LineMap, old_line: usize) ?u32 {
        if (old_line >= self.old_to_new.len) return null;
        const n = self.old_to_new[old_line];
        return if (n == deleted) null else n;
    }
};

/// Builds the old-to-new map by matching lines with a patience diff: anchor on
/// lines unique to both sides, take the longest increasing subsequence of those
/// anchors, recurse between them. O(n log n) typical, and it anchors on
/// distinctive lines rather than whichever match comes first.
pub fn lineMap(gpa: Allocator, a: []const u32, b: []const u32) Allocator.Error!LineMap {
    const out = try gpa.alloc(u32, a.len);
    @memset(out, LineMap.deleted);
    errdefer gpa.free(out);

    var ctx: MatchCtx = .{ .a = a, .b = b, .out = out, .gpa = gpa };
    try ctx.match(0, a.len, 0, b.len);
    return .{ .old_to_new = out };
}

const MatchCtx = struct {
    a: []const u32,
    b: []const u32,
    out: []u32,
    gpa: Allocator,

    fn match(self: *MatchCtx, a_lo_in: usize, a_hi_in: usize, b_lo_in: usize, b_hi_in: usize) Allocator.Error!void {
        var a_lo = a_lo_in;
        var a_hi = a_hi_in;
        var b_lo = b_lo_in;
        var b_hi = b_hi_in;

        // Common prefix and suffix first: an agent editing one function in a
        // large file leaves a small problem behind (PERFORMANCE.md 1.2).
        while (a_lo < a_hi and b_lo < b_hi and self.a[a_lo] == self.b[b_lo]) {
            self.out[a_lo] = @intCast(b_lo);
            a_lo += 1;
            b_lo += 1;
        }
        while (a_lo < a_hi and b_lo < b_hi and self.a[a_hi - 1] == self.b[b_hi - 1]) {
            self.out[a_hi - 1] = @intCast(b_hi - 1);
            a_hi -= 1;
            b_hi -= 1;
        }
        if (a_lo >= a_hi or b_lo >= b_hi) return;

        const anchors = try self.uniqueAnchors(a_lo, a_hi, b_lo, b_hi);
        defer self.gpa.free(anchors);
        if (anchors.len == 0) return; // genuinely replaced region

        const keep = try longestIncreasing(self.gpa, anchors);
        defer self.gpa.free(keep);
        if (keep.len == 0) return;

        var prev_a = a_lo;
        var prev_b = b_lo;
        for (keep) |p| {
            try self.match(prev_a, p.a, prev_b, p.b);
            self.out[p.a] = @intCast(p.b);
            prev_a = p.a + 1;
            prev_b = p.b + 1;
        }
        try self.match(prev_a, a_hi, prev_b, b_hi);
    }

    /// Lines occurring exactly once on both sides, paired and ordered by
    /// position in `a`.
    fn uniqueAnchors(self: *MatchCtx, a_lo: usize, a_hi: usize, b_lo: usize, b_hi: usize) Allocator.Error![]Pair {
        var a_count: std.AutoHashMapUnmanaged(u32, Occurrence) = .empty;
        defer a_count.deinit(self.gpa);
        var b_count: std.AutoHashMapUnmanaged(u32, Occurrence) = .empty;
        defer b_count.deinit(self.gpa);

        for (self.a[a_lo..a_hi], a_lo..) |id, i| try bump(self.gpa, &a_count, id, i);
        for (self.b[b_lo..b_hi], b_lo..) |id, i| try bump(self.gpa, &b_count, id, i);

        var pairs: std.ArrayList(Pair) = .empty;
        errdefer pairs.deinit(self.gpa);

        var i = a_lo;
        while (i < a_hi) : (i += 1) {
            const ao = a_count.get(self.a[i]).?;
            if (ao.count != 1) continue;
            const bo = b_count.get(self.a[i]) orelse continue;
            if (bo.count != 1) continue;
            try pairs.append(self.gpa, .{ .a = ao.first, .b = bo.first });
        }
        return pairs.toOwnedSlice(self.gpa);
    }
};

const Occurrence = struct { count: u32, first: usize };
const Pair = struct { a: usize, b: usize };

fn bump(gpa: Allocator, m: *std.AutoHashMapUnmanaged(u32, Occurrence), id: u32, idx: usize) Allocator.Error!void {
    const gop = try m.getOrPut(gpa, id);
    if (gop.found_existing) {
        gop.value_ptr.count += 1;
    } else {
        gop.value_ptr.* = .{ .count = 1, .first = idx };
    }
}

/// Longest strictly increasing subsequence by `b`, keeping crossing matches out
/// of the result. Patience sorting, O(n log n).
fn longestIncreasing(gpa: Allocator, pairs: []const Pair) Allocator.Error![]Pair {
    if (pairs.len == 0) return gpa.alloc(Pair, 0);

    const tails = try gpa.alloc(usize, pairs.len); // index into pairs
    defer gpa.free(tails);
    const prev = try gpa.alloc(usize, pairs.len);
    defer gpa.free(prev);

    var len: usize = 0;
    for (pairs, 0..) |p, i| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (pairs[tails[mid]].b < p.b) lo = mid + 1 else hi = mid;
        }
        prev[i] = if (lo == 0) std.math.maxInt(usize) else tails[lo - 1];
        tails[lo] = i;
        if (lo == len) len += 1;
    }

    const out = try gpa.alloc(Pair, len);
    var k = len;
    var cur = tails[len - 1];
    while (k > 0) {
        k -= 1;
        out[k] = pairs[cur];
        cur = prev[cur];
    }
    return out;
}

/// Whitespace-normalised form of a line, for tier 3. Leading and trailing
/// space is dropped and internal runs collapse to one, so a reindent or a
/// realignment leaves the key unchanged.
pub fn normalise(gpa: Allocator, line: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, line, " \t");
    var first = true;
    while (it.next()) |word| {
        if (!first) try out.append(gpa, ' ');
        try out.appendSlice(gpa, word);
        first = false;
    }
    return out.toOwnedSlice(gpa);
}

/// Sorted (hash, line) pairs supporting range lookup. Parallel arrays rather
/// than a map of lists: no per-key allocation, and lookups stay cache-friendly
/// (PERFORMANCE.md 7.3).
pub const HashIndex = struct {
    hashes: []u64,
    lines: []u32,

    pub fn build(gpa: Allocator, ids: []const u32) Allocator.Error!HashIndex {
        const Entry = struct { h: u64, line: u32 };
        const pairs = try gpa.alloc(Entry, ids.len);
        defer gpa.free(pairs);
        for (ids, 0..) |_, i| pairs[i] = .{ .h = windowHash(ids, i), .line = @intCast(i) };

        std.mem.sort(Entry, pairs, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.h < b.h;
            }
        }.lessThan);

        const hashes = try gpa.alloc(u64, pairs.len);
        errdefer gpa.free(hashes);
        const lines = try gpa.alloc(u32, pairs.len);
        for (pairs, 0..) |p, i| {
            hashes[i] = p.h;
            lines[i] = p.line;
        }
        return .{ .hashes = hashes, .lines = lines };
    }

    pub fn deinit(self: *HashIndex, gpa: Allocator) void {
        gpa.free(self.hashes);
        gpa.free(self.lines);
        self.* = undefined;
    }

    /// Lines whose window hashes equal `h`, in ascending hash order.
    pub fn lookup(self: HashIndex, h: u64) []const u32 {
        const lo = std.sort.lowerBound(u64, self.hashes, h, order);
        if (lo >= self.hashes.len or self.hashes[lo] != h) return &.{};
        const hi = std.sort.upperBound(u64, self.hashes, h, order);
        return self.lines[lo..hi];
    }

    fn order(key: u64, item: u64) std.math.Order {
        return std.math.order(key, item);
    }
};

/// One version of a file, prepared for re-anchoring against.
///
/// The hash indexes are built on first use, never eagerly. Most re-diffs place
/// every note through the line map and never touch them, and the cheapest work
/// is work not done at all (PERFORMANCE.md 0).
pub const Version = struct {
    ids: []u32,
    norm_ids: []u32,
    exact: ?HashIndex = null,
    norm: ?HashIndex = null,

    /// How often laziness failed to pay off, for the harness to report.
    pub var index_builds: usize = 0;

    pub fn init(
        gpa: Allocator,
        exact_interner: *Interner,
        norm_interner: *Interner,
        norm_arena: Allocator,
        text: []const u8,
    ) !Version {
        const ids = try exact_interner.internLines(gpa, text);
        errdefer gpa.free(ids);

        var norm_list: std.ArrayList(u32) = .empty;
        errdefer norm_list.deinit(gpa);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const n = try normalise(norm_arena, line);
            try norm_list.append(gpa, try norm_interner.intern(gpa, n));
        }
        if (norm_list.items.len > 0 and text.len > 0 and text[text.len - 1] == '\n') {
            _ = norm_list.pop();
        }
        const norm_ids = try norm_list.toOwnedSlice(gpa);
        return .{ .ids = ids, .norm_ids = norm_ids };
    }

    fn exactIndex(self: *Version, gpa: Allocator) Allocator.Error!HashIndex {
        if (self.exact == null) {
            self.exact = try HashIndex.build(gpa, self.ids);
            index_builds += 1;
        }
        return self.exact.?;
    }

    fn normIndex(self: *Version, gpa: Allocator) Allocator.Error!HashIndex {
        if (self.norm == null) {
            self.norm = try HashIndex.build(gpa, self.norm_ids);
            index_builds += 1;
        }
        return self.norm.?;
    }

    pub fn deinit(self: *Version, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.norm_ids);
        if (self.exact) |*i| i.deinit(gpa);
        if (self.norm) |*i| i.deinit(gpa);
        self.* = undefined;
    }
};

/// Which path placed a note. Recorded so the remaining tiers get built against
/// evidence rather than speculation.
pub const Outcome = enum {
    /// Primary path: the line map had a counterpart (PERFORMANCE.md 3.1).
    mapped,
    /// Tier 1: exact window hash within the near window.
    near_hash,
    /// Tier 2: exact window hash anywhere in the file.
    far_hash,
    /// Tier 3: whitespace-normalised window hash.
    normalised_hash,
    /// Tier 6. Tiers 4 and 5 are not built: 5 needs `hunk_hash` from phase 2,
    /// and nothing has yet produced a case that 4 would rescue.
    stale,
};

/// How far tier 1 looks before falling through to a whole-file lookup.
pub const near_window = 50;

/// A note's position, carried across versions.
pub const Anchor = struct {
    line: u32,
    exact_hash: u64,
    norm_hash: u64,
    stale: bool = false,

    pub fn init(v: Version, line: u32) Anchor {
        return .{
            .line = line,
            .exact_hash = windowHash(v.ids, line),
            .norm_hash = windowHash(v.norm_ids, line),
        };
    }

    /// Walks the ladder, stopping at the first tier that places the note. The
    /// anchor is only ever marked stale, never silently dropped (hard rule 7).
    pub fn reanchor(self: *Anchor, gpa: Allocator, map: LineMap, to: *Version) Allocator.Error!Outcome {
        if (self.stale) return .stale;
        const from_line = self.line;

        // Primary path. No index is built when this succeeds, which is the
        // common case (PERFORMANCE.md 3.1).
        if (map.get(from_line)) |n| {
            self.line = n;
            return .mapped;
        }
        if (nearest((try to.exactIndex(gpa)).lookup(self.exact_hash), from_line)) |n| {
            self.line = n;
            const delta = if (n > from_line) n - from_line else from_line - n;
            return if (delta <= near_window) .near_hash else .far_hash;
        }
        if (nearest((try to.normIndex(gpa)).lookup(self.norm_hash), from_line)) |n| {
            self.line = n;
            return .normalised_hash;
        }
        self.stale = true;
        return .stale;
    }
};

/// Of several equally-hashing candidates, the one closest to where the note
/// used to be. Ties go to the lower line.
fn nearest(candidates: []const u32, to: u32) ?u32 {
    var best: ?u32 = null;
    var best_delta: u32 = std.math.maxInt(u32);
    for (candidates) |c| {
        const delta = if (c > to) c - to else to - c;
        if (delta < best_delta) {
            best_delta = delta;
            best = c;
        }
    }
    return best;
}

const testing = std.testing;

test "interner assigns stable ids and dedupes" {
    var in: Interner = .{};
    defer in.deinit(testing.allocator);

    const a = try in.intern(testing.allocator, "let x = 1;");
    const b = try in.intern(testing.allocator, "let y = 2;");
    const c = try in.intern(testing.allocator, "let x = 1;");

    try testing.expectEqual(a, c);
    try testing.expect(a != b);
}

test "internLines ignores the trailing newline" {
    var in: Interner = .{};
    defer in.deinit(testing.allocator);

    const with = try in.internLines(testing.allocator, "a\nb\n");
    defer testing.allocator.free(with);
    const without = try in.internLines(testing.allocator, "a\nb");
    defer testing.allocator.free(without);

    try testing.expectEqual(@as(usize, 2), with.len);
    try testing.expectEqualSlices(u32, without, with);
}

test "window hash separates duplicate lines by context" {
    var in: Interner = .{};
    defer in.deinit(testing.allocator);

    // The same line `}` in two different neighbourhoods.
    const ids = try in.internLines(testing.allocator, "fn a() {\n  one();\n}\nfn b() {\n  two();\n}\n");
    defer testing.allocator.free(ids);

    try testing.expectEqual(ids[2], ids[5]); // identical lines
    try testing.expect(windowHash(ids, 2) != windowHash(ids, 5)); // distinct windows
}

test "line map tracks a pure insertion above" {
    var in: Interner = .{};
    defer in.deinit(testing.allocator);
    const a = try in.internLines(testing.allocator, "one\ntwo\nthree\n");
    defer testing.allocator.free(a);
    const b = try in.internLines(testing.allocator, "zero\nzero_b\none\ntwo\nthree\n");
    defer testing.allocator.free(b);

    var map = try lineMap(testing.allocator, a, b);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(@as(?u32, 2), map.get(0));
    try testing.expectEqual(@as(?u32, 3), map.get(1));
    try testing.expectEqual(@as(?u32, 4), map.get(2));
}

test "line map reports deletion as no counterpart" {
    var in: Interner = .{};
    defer in.deinit(testing.allocator);
    const a = try in.internLines(testing.allocator, "keep\ndrop_me\nkeep2\n");
    defer testing.allocator.free(a);
    const b = try in.internLines(testing.allocator, "keep\nkeep2\n");
    defer testing.allocator.free(b);

    var map = try lineMap(testing.allocator, a, b);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(@as(?u32, 0), map.get(0));
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expectEqual(@as(?u32, 1), map.get(2));
}

test "line map survives a duplicated guard clause" {
    // The real-session-1 case: a helper copies an existing line verbatim, so
    // the line is no longer unique and must be placed by its neighbours.
    var in: Interner = .{};
    defer in.deinit(testing.allocator);
    const a = try in.internLines(testing.allocator,
        \\fn line(n) {
        \\    if (n >= count) return null;
        \\    return body;
        \\}
    );
    defer testing.allocator.free(a);
    const b = try in.internLines(testing.allocator,
        \\fn lineStart(n) {
        \\    if (n >= count) return null;
        \\    return start;
        \\}
        \\
        \\fn line(n) {
        \\    if (n >= count) return null;
        \\    return body;
        \\}
    );
    defer testing.allocator.free(b);

    var map = try lineMap(testing.allocator, a, b);
    defer map.deinit(testing.allocator);

    // The original guard is the one inside line(), at index 6, not the copy.
    try testing.expectEqual(@as(?u32, 5), map.get(0));
    try testing.expectEqual(@as(?u32, 6), map.get(1));
    try testing.expectEqual(@as(?u32, 7), map.get(2));
}

/// Wires up the two interners and the normalisation arena that Version needs.
const Harness = struct {
    gpa: Allocator,
    exact: Interner = .{},
    norm: Interner = .{},
    arena: std.heap.ArenaAllocator,
    versions: std.ArrayList(Version) = .empty,

    fn init(gpa: Allocator) Harness {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Returns a pointer into the list, so callers can trigger lazy index builds.
    fn add(self: *Harness, text: []const u8) !*Version {
        const v = try Version.init(self.gpa, &self.exact, &self.norm, self.arena.allocator(), text);
        try self.versions.append(self.gpa, v);
        return &self.versions.items[self.versions.items.len - 1];
    }

    fn deinit(self: *Harness) void {
        for (self.versions.items) |*v| v.deinit(self.gpa);
        self.versions.deinit(self.gpa);
        self.exact.deinit(self.gpa);
        self.norm.deinit(self.gpa);
        self.arena.deinit();
    }
};

test "anchor takes the primary path when the line maps" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add("one\ntwo\nthree\n");
    const v1 = try h.add("zero\none\ntwo\nthree\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 1);
    try testing.expectEqual(Outcome.mapped, try a.reanchor(testing.allocator, map, v1));
    try testing.expectEqual(@as(u32, 2), a.line);
}

test "tier 3 rescues a whitespace-only reindent" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add(
        \\fn f() {
        \\    if (a) {
        \\        return b;
        \\    }
        \\}
        \\
    );
    const v1 = try h.add(
        \\fn f() {
        \\  if (a) {
        \\    return b;
        \\  }
        \\}
        \\
    );

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    // `return b;` is reindented, so no exact hash can match it.
    var a: Anchor = .init(v0.*, 2);
    try testing.expectEqual(Outcome.normalised_hash, try a.reanchor(testing.allocator, map, v1));
    try testing.expectEqual(@as(u32, 2), a.line);
    try testing.expect(!a.stale);
}

test "a rewritten neighbourhood goes stale rather than relocating" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();

    const v0 = try h.add("fn f() {\n    let x = 1;\n    deprecated(x);\n    total(x)\n}\n");
    const v1 = try h.add("fn f() {\n    let x = compute();\n    summarise(x)\n}\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 2);
    try testing.expectEqual(Outcome.stale, try a.reanchor(testing.allocator, map, v1));
    try testing.expect(a.stale);
}

test "a stale anchor stays stale" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    const v0 = try h.add("a\nb\nc\n");
    const v1 = try h.add("a\nb\nc\n");

    var map = try lineMap(testing.allocator, v0.ids, v1.ids);
    defer map.deinit(testing.allocator);

    var a: Anchor = .init(v0.*, 1);
    a.stale = true;
    try testing.expectEqual(Outcome.stale, try a.reanchor(testing.allocator, map, v1));
}

test "hash index finds every line sharing a window" {
    var h = Harness.init(testing.allocator);
    defer h.deinit();
    const v = try h.add("a\nb\nc\nd\n");

    var idx = try HashIndex.build(testing.allocator, v.ids);
    defer idx.deinit(testing.allocator);
    const hits = idx.lookup(windowHash(v.ids, 2));
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0]);

    try testing.expectEqual(@as(usize, 0), idx.lookup(0xdead_beef).len);
}

test "normalise collapses indentation and internal runs" {
    const gpa = testing.allocator;
    const a = try normalise(gpa, "    if (x)   { y(); }  ");
    defer gpa.free(a);
    try testing.expectEqualStrings("if (x) { y(); }", a);

    const b = try normalise(gpa, "\t\tif (x) { y(); }");
    defer gpa.free(b);
    try testing.expectEqualStrings("if (x) { y(); }", b);
}

test "nearest candidate wins, ties go low" {
    try testing.expectEqual(@as(?u32, 8), nearest(&.{ 3, 8, 20 }, 9));
    try testing.expectEqual(@as(?u32, 5), nearest(&.{ 5, 15 }, 10));
    try testing.expectEqual(@as(?u32, null), nearest(&.{}, 4));
}

test "longest increasing subsequence drops crossings" {
    const pairs = [_]Pair{
        .{ .a = 0, .b = 5 },
        .{ .a = 1, .b = 1 },
        .{ .a = 2, .b = 6 },
    };
    const keep = try longestIncreasing(testing.allocator, &pairs);
    defer testing.allocator.free(keep);

    try testing.expectEqual(@as(usize, 2), keep.len);
    try testing.expectEqual(@as(usize, 1), keep[0].a);
    try testing.expectEqual(@as(usize, 2), keep[1].a);
}
