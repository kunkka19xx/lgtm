// SPDX-License-Identifier: Apache-2.0
//
// Everything on its way out: the reference the cursor makes, the box it is
// written in, and the payload the bridge is handed. Hard rule 1 lives in
// `bridge/bridge.zig`; this is what fills the line it checks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../i18n/i18n.zig");

const app_mod = @import("app.zig");
const App = app_mod.App;
const compose_mod = @import("compose.zig");
const config = @import("../config.zig");
const event = @import("../core/event.zig");
const finder_mod = @import("finder.zig");
const hunk = @import("../core/hunk.zig");
const keytext = @import("keytext.zig");
const keymap = @import("keymap.zig");
const notes = @import("notes.zig");
const pr_mod = @import("pr.zig");
const thread_mod = @import("thread.zig");
const render = @import("render.zig");
const template = @import("../bridge/template.zig");
const walks = @import("walks.zig");

/// What is in the box, into a caller's buffer. It has to be copied before the
/// box closes: `closeCompose` declares the buffer empty, and a slice of it
/// read afterwards is a slice of nothing. A note keeps its line breaks, so
/// this is the text rather than the flattened line.
fn copyTyped(app: *const App, buf: *[compose_mod.max_bytes]u8) []const u8 {
    const typed = app.compose.text();
    @memcpy(buf[0..typed.len], typed);
    return buf[0..typed.len];
}

pub fn closeCompose(app: *App) void {
    app.compose.close();
    app.preset_index = null;
    app.compose_for = .agent;
    // Back where the box was opened from, and only while that overlay still
    // has something to show.
    app.mode = if (app.compose_from == .thread and thread_mod.alive(app)) .thread else .normal;
    app.compose_from = .normal;
}

/// One keystroke inside the box, or inside the preset list floating over
/// it. Text, not actions, so it never reaches the keymap.
pub fn feedCompose(app: *App, key: event.Key, body: u16) !void {
    if (app.preset_index) |idx| return feedPresets(app, key, idx);

    // The box's own keys come from the keymap, like every other key in the
    // tool. Text and the motions over it do not, and cannot: in a box every
    // printable key is data, so a keymap able to bind `x` would be a keymap
    // able to take `x` away from typing.
    //
    // A pending operator outranks all of it. With `d` waiting, the next key
    // is that operator's motion and `<Esc>` cancels the operator - a
    // binding firing there would make `d<Esc>` throw away a half-written
    // message, which is the opposite of what `<Esc>` means in vim.
    if (!app.compose.hasPending()) {
        if (composeCommand(app, key)) |cmd| return composeDo(app, cmd, key, body);
    }
    _ = app.compose.feed(key);
}

/// The single-chord binding for `key` inside the box, if there is one.
///
/// Single chords only, deliberately: a box cannot hold a prefix waiting to
/// see whether a sequence completes, because the key after it is usually a
/// letter someone is typing. A multi-chord binding in `compose` mode is
/// therefore ignored rather than half-honoured.
pub fn composeCommand(app: *App, key: event.Key) ?keymap.Command {
    // A box that cannot be typed into has its own set: there, a plain letter
    // is a key rather than text.
    if (app.compose.read_only) {
        if (bound(app, key, .note_view)) |cmd| return cmd;
        // The box's own cancel still leaves it. A config that remapped that
        // key moved it out of the set above, and a read-only box with no way
        // out of it would be the result.
        const cmd = bound(app, key, .note_input) orelse return null;
        return if (cmd == .compose_cancel) cmd else null;
    }
    return bound(app, key, .note_input);
}

fn bound(app: *App, key: event.Key, mode: event.Mode) ?keymap.Command {
    for (app.km.bindings) |b| {
        if (!b.modes.has(mode) or b.chords.len != 1) continue;
        const ch = b.chords[0];
        if (ch.cp == key.codepoint and ch.ctrl == key.mods.ctrl) return b.command;
    }
    return null;
}

/// The read-only box's keys. Answering is the point of opening somebody
/// else's remark at all, and the reply goes to the request, so it is keyed on
/// the remark rather than on the copy being read.
fn viewDo(app: *App, cmd: keymap.Command) void {
    switch (cmd) {
        .compose_cancel => closeCompose(app),
        .thread_reply => {
            const id = app.compose_for.commentId() orelse return;
            const n = app.comments.find(id) orelse return;
            // On failure `reply` only leaves a notice, and the box stays up
            // with the remark still in it.
            thread_mod.reply(app, n);
        },
        else => {},
    }
}

pub fn composeDo(app: *App, cmd: keymap.Command, key: event.Key, body: u16) !void {
    if (app.compose.read_only) return viewDo(app, cmd);
    switch (cmd) {
        .compose_cancel => {
            // One level at a time: out of insert, then out of the box.
            if (app.compose.mode == .insert) {
                app.compose.toNormal();
                return;
            }
            // `closeCompose` clears what the box was for, so cancelling
            // leaves nothing behind for the next one to inherit.
            closeCompose(app);
        },
        .compose_presets => app.preset_index = 0,
        .compose_newline => app.compose.insert("\n"),
        .compose_mention => {
            // Only while typing: in normal mode the key is a motion's, and
            // the picker would be a surprise rather than an offer.
            if (app.compose.mode != .insert) return;
            // The character goes in first, when it is one: a picker that is
            // cancelled leaves the `@` that was typed, because it was
            // typed. A binding moved onto a control key inserts nothing,
            // because there is nothing to insert.
            if (!key.mods.ctrl and key.codepoint >= 0x20) {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &utf8) catch 0;
                if (n > 0) app.compose.insert(utf8[0..n]);
            }
            // The compose box stays open underneath: the picker is a
            // layer over it, not a place the reader has gone instead.
            app.files_purpose = .mention;
            finder_mod.buildPickList(app);
            finder_mod.show(app, .{ .title = i18n.t(" mention a file ") });
        },
        // `<C-p>` means "to the forge" everywhere else, so on a box that only
        // goes there it does what Enter does.
        .compose_post_now => if (app.compose_for.onForge())
            try composeSubmit(app, body)
        else
            try composePostNow(app, body),
        // `<C-s>` is save-here-and-send-to-the-agent, and the first half has
        // nowhere to happen for a remark that lives on the request.
        .compose_send_now => if (app.compose_for.onForge()) {
            var kb: [32]u8 = undefined;
            app.notice.set("that one is on the request - {s} sends it there", .{
                app.keyFor(.compose_submit, .note_input, &kb),
            });
        } else try composeSendNow(app, body),
        .compose_submit => try composeSubmit(app, body),
        else => {},
    }
}

/// What the box holds, saved as a comment. Null when there was nothing to
/// save, or when the box is not holding one.
///
/// Shared by the two keys that save and then do something with it, which
/// otherwise differ only in where the result goes.
pub fn saveComposedComment(app: *App, body: u16) !?u32 {
    // Only the two that write a remark here: a box aimed at the forge used to
    // fall through and save a second remark saying what the reply said.
    if (!app.compose_for.savesHere()) return null;

    var raw_buf: [compose_mod.max_bytes]u8 = undefined;
    const raw = copyTyped(app, &raw_buf);
    if (raw.len == 0) {
        app.notice.set("nothing to save", .{});
        return null;
    }
    const what = app.compose_for;
    closeCompose(app);

    const id = try storeComposed(app, what, raw);
    notes.saveComments(app);
    app.rebuildRows(.line) catch {};
    app.clampScroll(body);
    return if (id == 0) null else id;
}

/// The typed text into the store, as whatever the box was pointed at. Zero
/// when it was pointed at something the store does not hold. Both keys that
/// save go through here, so a new field on `fresh` cannot reach one and miss
/// the other.
fn storeComposed(app: *App, what: app_mod.ComposeFor, raw: []const u8) !u32 {
    return switch (what) {
        .edit => |id| blk: {
            try app.comments.edit(id, raw);
            break :blk id;
        },
        // The line's text goes with the note, so a restart can find it again
        // when the file moved underneath.
        .fresh => |at| try app.comments.addFull(at.path, at.line, raw, notes.textOfNewLine(app, at.line), at.deleted, at.span),
        else => 0,
    };
}

/// `<C-s>` from inside a comment: save it *and* send it, so a remark that
/// cannot wait for the batch does not have to be typed, saved, found again and
/// sent. It is the same key that submits the whole review from normal mode,
/// which reads as "hand this over" either way.
pub fn composeSendNow(app: *App, body: u16) !void {
    if (!app.compose_for.isComment()) {
        // Not a comment: the key means the same thing the plain send does.
        try composeSubmit(app, body);
        return;
    }
    const id = try saveComposedComment(app, body) orelse return;
    const n = app.comments.find(id) orelse return;
    try notes.sendOne(app, n);
}

/// `<C-p>` in the box: save and post, without the detour through the list.
/// The same arm-then-perform the list's key uses, so the notice saying it
/// is happening reaches the screen before the call blocks.
pub fn composePostNow(app: *App, body: u16) !void {
    if (!app.compose_for.isComment()) return;
    _ = pr_mod.needRepo(app) orelse return;
    const id = try saveComposedComment(app, body) orelse return;
    pr_mod.postComment(app, id);
}

pub fn composeSubmit(app: *App, body: u16) !void {
    // Flattened here and nowhere else: hard rule 1 is about what `send-keys`
    // does with a newline, and this is the last point where one can still
    // exist.
    var flat: [compose_mod.max_bytes]u8 = undefined;
    const line = compose_mod.flatten(&flat, app.compose.text());
    var raw_buf: [compose_mod.max_bytes]u8 = undefined;
    const raw = copyTyped(app, &raw_buf);
    const how = app.compose_to;
    // Before the close, which clears both.
    const what = app.compose_for;
    closeCompose(app);
    if (line.len == 0) {
        app.notice.set("nothing to send", .{});
        return;
    }
    switch (what) {
        // Both wait for the forge: a call that fails must not leave a remark
        // here saying something GitHub never heard.
        .reply => |root| return pr_mod.reply(app, root, raw),
        .amend => |a| return pr_mod.amend(app, a.id, a.remote, raw),
        .edit, .fresh => {
            _ = try storeComposed(app, what, raw);
            var kb: [32]u8 = undefined;
            if (what == .edit)
                app.notice.set("comment updated", .{})
            else
                app.notice.set("comment added - {s} submits the review", .{
                    app.keyFor(.submit_review, .normal, &kb),
                });
        },
        .agent, .view => {
            app.outgoing.clearRetainingCapacity();
            try app.outgoing.appendSlice(app.gpa, line);
            app.want_send = how;
            app.clampScroll(body);
            return;
        },
    }
    notes.saveComments(app);
    // The note is a row now, and the reader should still be on the line they
    // noted rather than pushed off it.
    const on = notes.commentLine(app);
    app.rebuildRows(.reset) catch {};
    if (on) |at| _ = walks.gotoNewLine(app, at.line);
    app.clampScroll(body);
}

/// The `Ctrl-i` list. Escape closes it and gives the box back; Enter drops
/// the question in at the caret and deletes nothing.
pub fn feedPresets(app: *App, key: event.Key, idx: usize) void {
    const list = presets(app);
    const n = list.len;
    // Four keys each way, all wrapping. Spelled once so the arrows, the
    // letters and the control pairs cannot drift apart.
    const prev = if (idx == 0) n -| 1 else idx - 1;
    const next = if (idx + 1 >= n) 0 else idx + 1;
    switch (key.codepoint) {
        event.code.escape => app.preset_index = null,
        event.code.enter => {
            if (idx < n) {
                // A space in front unless the caret is already after one,
                // so a preset dropped mid-sentence does not weld itself to
                // the previous word.
                const before = app.compose.text();
                const at = app.compose.cursor;
                if (at > 0 and before[at - 1] != ' ') app.compose.insert(" ");
                app.compose.insert(list[idx].text);
            }
            app.preset_index = null;
        },
        event.code.up, 'k' => app.preset_index = prev,
        event.code.down, 'j' => app.preset_index = next,
        else => {
            if (!key.mods.ctrl) return;
            if (key.codepoint == 'p') app.preset_index = prev;
            if (key.codepoint == 'n') app.preset_index = next;
        },
    }
}

pub fn buildPayload(app: *App, how: App.Delivery, what: App.What) Allocator.Error!void {
    const r = refAt(app) orelse {
        app.notice.set("nothing here to point at", .{});
        return;
    };

    app.outgoing.clearRetainingCapacity();
    switch (what) {
        .ref => try refText(app, &app.outgoing, r),
        .ref_lines => {
            try refText(app, &app.outgoing, r);
            try appendLines(app, &app.outgoing);
        },
        .ask => |tmpl| {
            var ref: std.ArrayList(u8) = .empty;
            defer ref.deinit(app.gpa);
            try refText(app, &ref, r);
            try template.render(app.gpa, &app.outgoing, tmpl, &.{
                .{ .name = "ref", .value = ref.items },
            });
        },
    }
    app.want_send = how;

    // An operation on a selection ends it, the way an operator does in
    // vim: the range has been used, and leaving it highlighted invites a
    // second send of the same thing.
    if (app.mode == .visual) app.leaveVisual();
}

/// The composed payload, valid until the next `compose`.
pub fn payload(app: *const App) []const u8 {
    return app.outgoing.items;
}

/// The presets as the popup lists them. Built into the frame arena, so
/// the view holds no pointer that outlives the frame that drew it.
pub fn presetEntries(app: *App) []const render.PresetEntry {
    const list = presets(app);
    const out = app.frame_arena.allocator().alloc(render.PresetEntry, list.len) catch return &.{};
    for (list, 0..) |p, i| out[i] = .{ .name = p.name, .text = p.text };
    return out;
}

/// The four built-ins, for a config with no `[presets]` of its own. The
/// same questions the ask keys send, because someone who liked them
/// enough to bind a key to them will want them in the box too.
pub fn presets(app: *App) []const config.Preset {
    if (app.presets_cfg.len > 0) return app.presets_cfg;
    return &.{
        .{ .name = "why", .text = "why this approach?" },
        .{ .name = "revert", .text = "revert this, keep the rest" },
        .{ .name = "test", .text = "add a test covering this" },
        .{ .name = "explain", .text = "explain what this does" },
    };
}

/// Opens the compose box on what `compose` would have sent outright.
///
/// Every send goes through here now. A fixed string was the wrong shape
/// for the thing being said: "why this approach?" is the first half of a
/// sentence, and the second half - the part that says *what* looked wrong
/// - had nowhere to go. The reference and the question are the seed, the
/// caret is past them, and Enter is still what sends.
pub fn openCompose(app: *App, how: App.Delivery, what: App.What) Allocator.Error!void {
    // With nothing to review there is nothing to point at, and the box
    // opens empty rather than refusing. A clean tree is where a pane
    // spends most of its day (`ui/splash.zig`), and "talk to the agent"
    // is a thing to want there - having to make a change first before the
    // tool would let you type is the tail wagging the dog.
    if (app.current() == null) {
        app.outgoing.clearRetainingCapacity();
        app.want_send = null;
        app.compose_to = how;
        app.compose.start("");
        app.preset_index = null;
        app.mode = .note_input;
        return;
    }
    // The seed is the reference and nothing else, whichever key opened the
    // box. A canned question typed in for you is a sentence you now have
    // to read and mostly delete - and the presets have their own key
    // (`Ctrl-i`), which puts them in when they are wanted rather than
    // before anyone has decided.
    _ = what;
    try buildPayload(app, how, .ref);
    // `compose` sets `want_send`; the box is what decides now, so take it
    // back and hold the delivery until Enter.
    app.want_send = null;
    app.compose_to = how;
    app.compose.start(app.outgoing.items);
    app.preset_index = null;
    app.mode = .note_input;
}

/// The compose box as a view, for the callers that draw it without a
/// `View` around it - the empty screen has no diff to build one from.
pub fn composeView(app: *App, arena: Allocator) render.ComposeView {
    // The line a note is being written against, in the title. The store
    // holds it, so the body does not have to - and a note whose text
    // repeats its own line number would say it twice in `review-N.md`.
    // The same switch `composeSubmit` runs, over the same union, so the
    // title can no longer disagree with what `<CR>` will do.
    const what: []const u8 = switch (app.compose_for) {
        .agent => i18n.t("compose"),
        // Whose it is and where, because the box has to say why it is shut.
        .view => |id| blk: {
            const n = app.comments.find(id) orelse break :blk i18n.t("comment");
            break :blk std.fmt.allocPrint(arena, "@{s} {s}:{d}", .{ n.author, n.path, n.line }) catch i18n.t("comment");
        },
        // Who is being answered: a reply box that said only the line would
        // look like the box that writes a new remark on it.
        .reply => |root| blk: {
            const n = app.comments.findRemote(root) orelse break :blk i18n.t("reply");
            break :blk i18n.allocPrint(arena, "reply to @{s} on #{d} {s}:{d}", .{
                n.author, app.pr.number, n.path, n.line,
            }) catch i18n.t("reply");
        },
        // The box looks like any other, and `<CR>` does not do the same.
        .amend => |a| blk: {
            const n = app.comments.find(a.id) orelse break :blk i18n.t("comment");
            break :blk i18n.allocPrint(arena, "your remark on #{d} {s}:{d}", .{ app.pr.number, n.path, n.line }) catch i18n.t("comment");
        },
        .edit => |id| blk: {
            const n = app.comments.find(id) orelse break :blk i18n.t("comment");
            break :blk i18n.allocPrint(arena, "comment {s}:{d}", .{ n.path, n.line }) catch i18n.t("comment");
        },
        // The spot the box opened on: the selection is gone by this frame,
        // and asking again would say one line for a range of three.
        .fresh => |at| blk: {
            const tail: []const u8 = if (at.deleted) i18n.t(" - removed code") else "";
            break :blk (if (at.span > 1)
                i18n.allocPrint(arena, "comment {s}:{d}-{d}{s}", .{ at.path, at.line, at.line + at.span - 1, tail })
            else
                i18n.allocPrint(arena, "comment {s}:{d}{s}", .{ at.path, at.line, tail })) catch i18n.t("comment");
        },
    };

    return .{
        .what = what,
        .bindings = app.km.bindings,
        .text = app.compose.text(),
        .cursor = app.compose.cursor,
        .joins = compose_mod.hasBreak(app.compose.text()),
        .presets = if (app.preset_index != null) presetEntries(app) else &.{},
        .selected = app.preset_index,
        .to_agent = app.compose_to == .send,
        .at = app.compose_at,
        .kind = app.compose_for,
        .posts = app.pr.number != 0,
        .normal = app.compose.mode == .normal,
    };
}

/// What the cursor, or the selection, is pointing at.
pub fn refAt(app: *App) ?App.Ref {
    const f = app.current() orelse return null;
    const path = f.path();

    const hunk_index = app.rows.hunkAt(app.vp.cursor);
    const id = if (hunk_index) |h|
        (if (h < f.hunks.len) f.hunks[h].id else hunk.no_id)
    else
        hunk.no_id;

    // A selection resolves to the new-file lines it covers; without one
    // the range is the cursor row alone. Rows that are chrome, and lines
    // that exist only in HEAD, contribute nothing either way.
    const sel = app.selection();
    const lo_row = if (sel) |s| s.lo else app.vp.cursor;
    const hi_row = if (sel) |s| s.hi else app.vp.cursor;

    var first: u32 = 0;
    var last: u32 = 0;
    var row = lo_row;
    while (row <= hi_row) : (row += 1) {
        const li = app.lineAt(row) orelse continue;
        if (li >= f.lines.len()) continue;
        const n = f.lines.new_no[li];
        if (n == 0) continue;
        if (first == 0) first = n;
        last = n;
    }
    if (first != 0) {
        return .{
            .change_id = id,
            .path = path,
            .line = first,
            .end = if (last > first) last else 0,
            .span = spanText(app, sel),
        };
    }

    // Nothing under the cursor survives in the new file. The enclosing
    // hunk is where the deletion happened, which is the closest thing to
    // a place the agent can look.
    if (hunk_index) |h| {
        if (h < f.hunks.len) return .{
            .change_id = id,
            .path = path,
            .line = f.hunks[h].new_start,
            .deleted = true,
        };
    }
    return .{ .change_id = id, .path = path };
}

/// The words a charwise selection covers, trimmed, or empty when there is
/// no such thing to point at. Only within one line: the text of a
/// selection spanning two would contain the newline between them.
pub fn spanText(app: *App, sel: ?render.Selection) []const u8 {
    const s = sel orelse return "";
    if (s.kind != .char or s.lo != s.hi) return "";
    const text = app.textOfRow(s.lo);
    const lo = @min(s.lo_col, text.len);
    const hi = @min(s.hi_col, text.len);
    if (hi <= lo) return "";
    return std.mem.trim(u8, text[lo..hi], " \t");
}

/// The reference as text. Which template applies is decided here and
/// nowhere else, so a user who replaces one of them replaces exactly the
/// case they meant to.
pub fn refText(app: *App, out: *std.ArrayList(u8), r: App.Ref) Allocator.Error!void {
    var id_buf: [12]u8 = undefined;
    var line_buf: [12]u8 = undefined;
    var end_buf: [12]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{r.change_id}) catch unreachable;
    const line = std.fmt.bufPrint(&line_buf, "{d}", .{r.line}) catch unreachable;
    const end = std.fmt.bufPrint(&end_buf, "{d}", .{r.end}) catch unreachable;

    // No hunk and no line is a file whose body was never parsed. `#0` and
    // `:0` would both be lies, so the path is the whole reference.
    // Three shapes, twice: with a change id for a file in the review, and
    // without for one being read outside it. The `#id` is a claim that
    // this hunk changed, so a file with no hunks does not get one.
    const tmpl = if (r.line == 0)
        app.templates.ref_file
    else if (r.change_id == hunk.no_id)
        (if (r.end != 0)
            app.templates.ref_file_range
        else if (r.span.len > 0)
            app.templates.ref_file_span
        else
            app.templates.ref_file_line)
    else if (r.deleted)
        app.templates.ref_hunk
    else if (r.end != 0)
        app.templates.ref_range
    else if (r.span.len > 0)
        app.templates.ref_span
    else
        app.templates.ref_single;

    var pr_buf: [12]u8 = undefined;
    const pr = std.fmt.bufPrint(&pr_buf, "{d}", .{app.pr.number}) catch "";
    const vars = [_]template.Var{
        .{ .name = "pr", .value = pr },
        .{ .name = "change_id", .value = id },
        .{ .name = "path", .value = r.path },
        .{ .name = "line", .value = line },
        .{ .name = "start", .value = line },
        .{ .name = "end", .value = end },
        .{ .name = "span", .value = r.span },
    };
    // Every reference, not just the ones a comment carries: `<CR>` sends
    // one straight from the diff and it lands in the same agent.
    if (app.pr.number != 0) try template.render(app.gpa, out, app.templates.ref_prefix, &vars);
    try template.render(app.gpa, out, tmpl, &vars);
}

/// The lines themselves, under the reference, markers kept. `Y` exists to
/// paste a change into a message, and `+`/`-` is what says which side of
/// it a line is on - without them a mixed range reads as nonsense.
pub fn appendLines(app: *App, out: *std.ArrayList(u8)) Allocator.Error!void {
    const f = app.current() orelse return;
    const sel = app.selection();
    const lo_row = if (sel) |s| s.lo else app.vp.cursor;
    const hi_row = if (sel) |s| s.hi else app.vp.cursor;

    var row = lo_row;
    while (row <= hi_row) : (row += 1) {
        const li = app.lineAt(row) orelse continue;
        if (li >= f.lines.len()) continue;
        try out.append(app.gpa, '\n');
        try out.append(app.gpa, switch (f.lines.kind[li]) {
            .add => '+',
            .del => '-',
            .context => ' ',
        });
        try out.appendSlice(app.gpa, f.lines.text[li]);
    }
}

/// `y` and `Y`: the selected text itself, onto the clipboard.
///
/// This is the vim key doing the vim thing, and it is separate from
/// `<leader>y` on purpose. `y` used to copy a *reference* - the text
/// wrapped in `#3 path:47` - which is what the tool is for but not what
/// the most-known key in vim means. The surprise was silent: nothing looks
/// wrong until the paste lands somewhere else, and by then the selection
/// is gone. Pointing at code has its own key and always did (`Enter`), so
/// `y` does not need to carry it too.
///
/// Newlines are fine here. Hard rule 1 is about what `send-keys` does with
/// one, and this never reaches `send-keys`: `y` is the clipboard whatever
/// the backend is.
/// Whether `cmd` has a binding live in `mode`.
fn keysIn(bindings: []const keymap.Binding, cmd: keymap.Command, mode: event.Mode) bool {
    for (bindings) |b| {
        if (b.command == cmd and b.modes.has(mode)) return true;
    }
    return false;
}

fn append(app: *App, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [keytext.max_row_keys_bytes]u8 = undefined;
    try app.outgoing.appendSlice(app.gpa, std.fmt.bufPrint(&buf, fmt, args) catch return);
}

/// `<C-y>` in the `?` overlay: the selected row as the `[keys]` lines that
/// would bind it, on the clipboard.
///
/// A paste rather than a write, for the reason `:theme` names its line instead
/// of saving it - the config file is hand-written and lgtm does not rewrite it.
/// Composing the line is the fiddly part, and the popup is already rendering
/// the spelling the parser accepts.
pub fn copyBinding(app: *App) Allocator.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();

    const mode = app.help.from;
    const rows = try keytext.helpEntries(
        app.km.bindings,
        mode,
        app.help.shown(),
        app.help.filter.text(),
        scratch.allocator(),
    );
    if (app.help.index >= rows.len or rows[app.help.index].cmds.len == 0) {
        app.notice.set("nothing selected", .{});
        return;
    }
    // A merged row gives a line each: `gg G` is one row and two commands, and
    // binding only `top` would be half a remap with nothing to say so.
    const cmds = rows[app.help.index].cmds;

    app.outgoing.clearRetainingCapacity();
    for (cmds, 0..) |cmd, i| {
        // Compose rows are drawn in the normal-mode popup but their keys are
        // live in the box, so the row's mode is not always theirs.
        const live: event.Mode = if (keysIn(app.km.bindings, cmd, mode)) mode else .note_input;
        if (i > 0) try app.outgoing.append(app.gpa, '\n');
        try append(app, "{s} = [", .{@tagName(cmd)});

        var n: usize = 0;
        for (app.km.bindings) |b| {
            if (b.command != cmd or !b.modes.has(live)) continue;
            var kbuf: [keytext.max_keys_bytes]u8 = undefined;
            defer n += 1;
            try append(app, "{s}\"{s}\"", .{
                if (n > 0) ", " else "",
                keytext.bufWriteChords(b.chords, &kbuf),
            });
        }
        try app.outgoing.append(app.gpa, ']');
    }

    app.want_send = .copy;
    // Named, because the clipboard is the one place the reader cannot see
    // what they just took.
    if (cmds.len == 1) {
        app.notice.set("copied {s} - paste it under [keys]", .{@tagName(cmds[0])});
    } else {
        app.notice.set("copied {d} lines - paste them under [keys]", .{cmds.len});
    }
}

pub fn yank(app: *App, extent: App.Extent) Allocator.Error!void {
    const f = app.current() orelse {
        app.notice.set("nothing here to yank", .{});
        return;
    };
    const sel = app.selection();
    const lo = if (sel) |s| s.lo else app.vp.cursor;
    const hi = if (sel) |s| s.hi else app.vp.cursor;

    app.outgoing.clearRetainingCapacity();
    var rows: u32 = 0;
    var row = lo;
    while (row <= hi) : (row += 1) {
        const li = app.lineAt(row) orelse continue;
        if (li >= f.lines.len()) continue;
        const text = f.lines.text[li];

        // The diff's sign column is lgtm's, not the file's: a yanked line
        // pasted into an editor should compile, so the `+` goes nowhere.
        const part = if (extent == .selection and sel != null) blk: {
            const span = sel.?.span(row, @intCast(text.len)) orelse break :blk "";
            break :blk text[span.lo..span.hi];
        } else text;

        if (rows > 0) try app.outgoing.append(app.gpa, '\n');
        try app.outgoing.appendSlice(app.gpa, part);
        rows += 1;
    }

    if (app.outgoing.items.len == 0) {
        app.notice.set("nothing here to yank", .{});
        return;
    }
    app.want_send = .copy;
    if (app.mode == .visual) app.leaveVisual();
}

const testing = std.testing;

test "a yank takes the column the reader is standing in" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();
    try app_mod.App.splitReplacement(fx);

    const lines = fx.app.current().?.lines;
    fx.app.vp.cursor = 2;

    try fx.press("Y");
    try testing.expectEqualStrings(lines.text[2], fx.app.outgoing.items);

    // The whole point of `H`: the removed text was unreachable before it, and
    // copying it is most of what anyone wants the old column for.
    try fx.press("H");
    try fx.press("Y");
    try testing.expectEqualStrings(lines.text[1], fx.app.outgoing.items);
}

test "a charwise selection points the agent at the words, not at a column" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Select `alpha` on `fn alpha() {`.
    try fx.press("w");
    try fx.press("v");
    try fx.press("e");
    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 `alpha`", payload(&fx.app));

    // Grown past one line, the text would have to carry the newline between
    // them - so it becomes the line range it always was.
    try fx.press("w");
    try fx.press("v");
    try fx.press("j");
    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-2", payload(&fx.app));
}

test "Enter composes a reference to the line under the cursor" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // Enter opens the box seeded with the reference; nothing is sent yet.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());
    try testing.expect(fx.app.want_send == null);

    // The second Enter is the send. A request, not an action: the loop owns
    // the terminal and the subprocess.
    try fx.press("<CR>");
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", payload(&fx.app));
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "@ picks a file out of the review and puts its path at the caret" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press(" see");
    try fx.press(" @");
    // The `@` is typed, and the picker is over the box rather than instead of
    // it - the box is still open underneath.
    try testing.expectEqual(event.Mode.finder, fx.app.mode);
    try testing.expect(fx.app.compose.open);
    try testing.expectEqualStrings("#1 a.zig:1 see @", fx.app.compose.text());

    // Enter takes the highlighted file; the keyboard goes back to the box.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("#1 a.zig:1 see @a.zig", fx.app.compose.text());

    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 see @a.zig", payload(&fx.app));
}

test "with nothing to review the box still opens, empty" {
    var fx = try app_mod.Fixture.emptyReview(testing.allocator);
    defer fx.deinit();

    // A clean tree is where a review pane spends most of its day, and "talk to
    // the agent" is a thing to want there. Refusing until the reader makes a
    // change first would be the tail wagging the dog.
    try fx.press("<CR>");
    try testing.expectEqual(event.Mode.note_input, fx.app.mode);
    try testing.expectEqualStrings("", fx.app.compose.text());

    try fx.press("hi");
    try fx.press("<CR>");
    try testing.expectEqualStrings("hi", payload(&fx.app));
    try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
}

test "the box opens on the reference and nothing else" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // No question is typed in for the reader. A canned sentence that arrives
    // uninvited is one they have to read and mostly delete; the presets have
    // their own key for when they are actually wanted.
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());

    try fx.press(" it");
    try fx.press("s wr");
    try fx.press("ong");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 its wrong", payload(&fx.app));
}

test "a selection sends a range, and using it ends the selection" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("Vj");
    try testing.expectEqual(@as(u32, 2), fx.app.selection().?.count());
    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-2", payload(&fx.app));

    // An operator consumes its range, the way it does in vim. Leaving the
    // rows highlighted invites sending the same lines twice.
    try testing.expect(fx.app.selection() == null);
    try testing.expectEqual(event.Mode.normal, fx.app.mode);
}

test "a one-row selection is a single line, not a range of one" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("V<CR>");
    try testing.expectEqualStrings("#1 a.zig:1", payload(&fx.app));
}

test "y yanks the text, the way the key means in vim" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // No selection: the cursor line, and without the diff's sign column -
    // yanked code should paste into an editor and still compile.
    try fx.press("y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("fn alpha() {", payload(&fx.app));

    // Charwise: exactly the characters under the selection, which is the case
    // that sent people a reference when they wanted a word.
    try fx.press("vll");
    try fx.press("y");
    try testing.expectEqualStrings("fn ", payload(&fx.app));

    // Linewise across two rows, joined by the newline the clipboard allows.
    try fx.press("Vj");
    try fx.press("y");
    try testing.expectEqualStrings("fn alpha() {\n    const x = 1;", payload(&fx.app));
}

test "the popup copies a row as the [keys] line that would bind it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // `?` opens on the `move` tab, whose first row is `line_down`. Every
    // spelling of it, because an entry replaces the defaults rather than adds
    // to them - a line naming only `j` would silently drop `<Down>`.
    try fx.press("?");
    try fx.press("<C-y>");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("line_down = [\"j\", \"<Down>\"]", payload(&fx.app));

    // Four rows down is `gg G`: one row, two commands, a line each.
    try fx.press("JJJ");
    try fx.press("<C-y>");
    try testing.expectEqualStrings(
        \\top = ["gg"]
        \\bottom = ["G"]
    , payload(&fx.app));

    // And what comes out has to go back in: a spelling the parser complains
    // about is not worth copying.
    var l = config.Loader.init(testing.allocator);
    defer l.deinit();
    var doc: [256]u8 = undefined;
    l.merge("test.toml", try std.fmt.bufPrint(&doc, "[keys]\n{s}\n", .{payload(&fx.app)}));
    try testing.expectEqual(@as(usize, 0), l.problems.items.len);
}

test "Y yanks whole lines even from a charwise selection" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // vim's `Y` is linewise whatever `v` selected.
    try fx.press("vll");
    try fx.press("Y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("fn alpha() {", payload(&fx.app));
}

test "the reference moved to <leader>y rather than being lost" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<Space>y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings("#1 a.zig:1", payload(&fx.app));
}

test "<leader>Y puts the lines under the reference, markers kept" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // The marker is what says which side of the change a line is on; a mixed
    // range pasted without them reads as nonsense.
    try fx.press("Vj");
    try fx.press("<Space>Y");
    try testing.expectEqual(App.Delivery.copy, fx.app.want_send.?);
    try testing.expectEqualStrings(
        "#1 a.zig:1-2\n fn alpha() {\n     const x = 1;",
        payload(&fx.app),
    );
}

test "a deleted line points at its hunk and says why" {
    var fx = try app_mod.Fixture.withDeletion(testing.allocator, 1);
    defer fx.deinit();

    // References resolve against the new file. This line is not
    // in it, so the enclosing hunk is the closest honest answer - and the
    // agent is told that is what happened.
    fx.app.vp.cursor = 2;
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1 (deleted lines in this hunk)", payload(&fx.app));
}

test "a selection spanning a deletion keeps the lines that still exist" {
    var fx = try app_mod.Fixture.withDeletion(testing.allocator, 1);
    defer fx.deinit();

    // Rows 1-3 are lines 1, deleted, 3. The range is what survives.
    fx.app.vp.cursor = 1;
    try fx.press("Vjj");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:1-3", payload(&fx.app));
}

test "every opener seeds the same thing: the reference" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // One opener, because there is only one thing to open. The four ask keys
    // that used to sit beside it are gone: once the box stopped typing a
    // question in for you, they did exactly what Enter does.
    for ([_][]const u8{"<CR>"}) |keys| {
        try fx.press(keys);
        try testing.expectEqual(event.Mode.note_input, fx.app.mode);
        try testing.expectEqualStrings("#1 a.zig:1", fx.app.compose.text());
        try fx.press("<CR>");
        try testing.expectEqualStrings("#1 a.zig:1", payload(&fx.app));
        try testing.expectEqual(App.Delivery.send, fx.app.want_send.?);
    }
}

test "nothing sent to the agent ever contains a newline" {
    // Hard rule 1, checked where the payload is built as well as where it is
    // sent: in `tmux send-keys` a newline is Enter, and Enter submits the
    // user's half-written message. The yanks and `<leader>Y` are exempt by
    // design - they are the clipboard, which no send-keys ever sees.
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    for ([_][]const u8{ "<CR>", "<Space>y" }) |keys| {
        try fx.press("Vj");
        try fx.press(keys);
        // Everything but the yank now goes through the compose box, and the
        // flattening on submit is the last place a newline could survive.
        if (fx.app.mode == .note_input) try fx.press("<CR>");
        try testing.expect(std.mem.indexOfScalar(u8, payload(&fx.app), '\n') == null);
    }
}

test "a change id follows the hunk, not the row" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    // The second file's hunk is #2, and its reference has to say so - the id
    // is what the user and the agent say to each other.
    try fx.press("]f");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#2 b.zig:1", payload(&fx.app));
}

test "composing again replaces the payload rather than appending to it" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try fx.press("<CR>");
    try fx.press("<CR>");
    try fx.press("j");
    try fx.press("<CR>");
    try fx.press("<CR>");
    try testing.expectEqualStrings("#1 a.zig:2", payload(&fx.app));
}

test "the box's feature keys are bindings, and a remap moves them" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    var a: [4]keymap.Chord = undefined;
    var b: [4]keymap.Chord = undefined;
    const moved = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("<C-g>", &a), .command = .compose_cancel, .modes = keymap.Modes.compose_only },
        .{ .chords = try keytext.parseChords("<CR>", &b), .command = .compose_submit, .modes = keymap.Modes.compose_only },
    };
    fx.app.km.bindings = &moved;

    try openCompose(&fx.app, .send, .ref);
    try fx.expectMode(.note_input);
    try fx.typeIn("hello");

    // `<Esc>` is no longer bound, so in the box it is just a key that types
    // nothing - it must not close what the reader is writing.
    try fx.app.handle(.{ .key = .{ .codepoint = event.code.escape, .mods = .{} } }, app_mod.body_rows);
    try fx.expectMode(.note_input);

    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } }, app_mod.body_rows);
    try fx.expectMode(.note_input);
    // First press leaves insert, second leaves the box - the two levels are
    // the command's, not the key's.
    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } }, app_mod.body_rows);
    try fx.expectMode(.normal);
}

test "a remapped cancel still leaves a remark opened to be read" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    var a: [4]keymap.Chord = undefined;
    const moved = [_]keymap.Binding{
        .{ .chords = try keytext.parseChords("<C-g>", &a), .command = .compose_cancel, .modes = keymap.Modes.compose_only },
    };
    fx.app.km.bindings = &moved;

    // No remote, so it opens in the box rather than in the overlay.
    _ = try fx.app.comments.adopt(.{ .path = "a.zig", .line = 2, .span = 1, .body = "theirs", .author = "someone", .outdated = false, .remote = 0 });
    try notes.commentView(&fx.app, app_mod.body_rows);
    try fx.expectMode(.note_view);

    // The box's own keys went with the remap, and a box with no way out of it
    // is the one thing this must not become.
    try fx.app.handle(.{ .key = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } }, app_mod.body_rows);
    try fx.expectMode(.normal);
}

test "a pending operator outranks the keymap, so d<Esc> cancels the operator" {
    var fx = try app_mod.Fixture.init(testing.allocator);
    defer fx.deinit();

    try openCompose(&fx.app, .send, .ref);
    try fx.typeIn("one two");
    try fx.press("<Esc>"); // leave insert, stay in the box
    try fx.expectMode(.note_input);
    try testing.expect(fx.app.compose.mode == .normal);

    try fx.typeIn("d");
    try testing.expect(fx.app.compose.hasPending());
    try fx.press("<Esc>");
    // The operator went, the box stayed, and the text is untouched.
    try testing.expect(!fx.app.compose.hasPending());
    try fx.expectMode(.note_input);
    // The box was seeded with the reference; what matters is that the typed
    // half survived the operator being cancelled.
    try testing.expect(std.mem.endsWith(u8, fx.app.compose.text(), "one two"));
}
