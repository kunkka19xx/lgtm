// SPDX-License-Identifier: Apache-2.0
//
// The universal fallback: OSC 52 puts text on the clipboard through the
// terminal itself, which is why it and not a system clipboard call is the
// fallback - it works over SSH, and the tool stays usable on a remote box
// (SPEC.md 6.3).
//
// ARCHITECTURE.md 5c asks that libvaxis's implementation be evaluated before
// hand-rolling escape sequences. It was: `Vaxis.copyToSystemClipboard` is a
// method on a receiver it never reads, so reuse means passing `undefined` at
// the call site and importing the whole TUI into `bridge/` for one sequence.
// The encoder below is `std.base64` and one `print`, and it keeps `bridge/`
// free of vaxis, which is what lets these tests run without a terminal.
//
// One caveat, discovered the hard way rather than written down in time: inside
// tmux this reaches nothing at all under the default `set-clipboard external`,
// which lets tmux set the terminal clipboard itself but ignores an application
// that tries. There is no reply to an OSC 52, so `y` reported a success that
// had not happened. `bridge.clipboard` now prefers `tmux load-buffer -w -`
// there, and this file is the fallback for everything outside tmux - where it
// is still the right answer, because it works over SSH.

const std = @import("std");
const Allocator = std.mem.Allocator;

const encoder = std.base64.standard.Encoder;

/// OSC 52 addressed to selection `c`, the clipboard, and the ST that ends it.
/// Named because `bridge.zig` asserts on the prefix too; the tests below keep
/// the bytes spelled out, since a test that rebuilds its expectation from the
/// constant it is testing checks nothing.
pub const prefix = "\x1b]52;c;";
pub const terminator = "\x1b\\";

/// The sequence, without a writer. Split out so the encoding has a test that
/// does not need a terminal, and so the writer path stays three lines.
pub fn sequence(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const b64 = try gpa.alloc(u8, encoder.calcSize(text.len));
    defer gpa.free(b64);
    _ = encoder.encode(b64, text);
    return std.mem.concat(gpa, u8, &.{ prefix, b64, terminator });
}

/// Writes the sequence and flushes. The writer is the one `io/tty.zig` owns
/// and `ui/loop.zig` lends out; nothing here constructs one.
pub fn copy(gpa: Allocator, w: *std.Io.Writer, text: []const u8) !void {
    const seq = try sequence(gpa, text);
    defer gpa.free(seq);
    try w.writeAll(seq);
    try w.flush();
}

const testing = std.testing;

test "the payload is base64 inside OSC 52" {
    const seq = try sequence(testing.allocator, "#3 src/auth.rs:47");
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1b]52;c;IzMgc3JjL2F1dGgucnM6NDc=\x1b\\", seq);
}

test "a multi-line payload is fine here, unlike a send" {
    // `y` and `Y` are the clipboard, not the agent's input box: hard rule 1
    // is about what a newline does to `send-keys`, and there is no send-keys
    // in this path.
    const seq = try sequence(testing.allocator, "a\nb");
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1b]52;c;YQpi\x1b\\", seq);
}

test "an empty payload still produces a well-formed sequence" {
    const seq = try sequence(testing.allocator, "");
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1b]52;c;\x1b\\", seq);
}
