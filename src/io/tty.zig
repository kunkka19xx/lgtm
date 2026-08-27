// SPDX-License-Identifier: Apache-2.0
//
// Owns the terminal handle and the buffered writer handed to the renderer.
// ui/ receives the writer as a parameter and never constructs one
// (ARCHITECTURE.md 5c).

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One flush per frame is the budget (PERFORMANCE.md 7.4). Sized so a full
/// repaint with styling never forces an early flush.
pub const default_buffer_bytes = 256 << 10;

pub const Winsize = vaxis.Winsize;

pub const Tty = struct {
    inner: vaxis.tty.Tty,
    buffer: []u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator, io: Io, buffer_bytes: usize) !Tty {
        const buffer = try gpa.alloc(u8, buffer_bytes);
        errdefer gpa.free(buffer);
        return .{
            .inner = try vaxis.tty.Tty.init(io, buffer),
            .buffer = buffer,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Tty) void {
        self.inner.deinit();
        self.gpa.free(self.buffer);
        self.* = undefined;
    }

    /// The interface passed to vaxis render(). Callers must flush.
    pub fn writer(self: *Tty) *Io.Writer {
        return self.inner.writer();
    }

    pub fn winsize(self: *Tty) !Winsize {
        return self.inner.getWinsize();
    }

    pub fn read(self: *const Tty, buf: []u8) !usize {
        return self.inner.read(buf);
    }

    /// The raw descriptor, for `poll`. Null where there is nothing pollable -
    /// Windows consoles - and callers fall back to a blocking read there.
    pub fn handle(self: *const Tty) ?std.posix.fd_t {
        if (builtin.os.tag == .windows) {
            return null;
        } else {
            const F = @TypeOf(self.inner.fd);
            // The test tty stores a bare descriptor; the real one wraps it.
            return if (F == std.posix.fd_t) self.inner.fd else self.inner.fd.handle;
        }
    }

    /// Hands the terminal back to the shell's settings, for the duration of a
    /// child process that expects to own it - `e` and `$EDITOR`. Without this
    /// the editor starts in raw mode with no echo, which looks like a hang.
    ///
    /// `resumeRaw` is the other half and must always follow, including on the
    /// error paths: a `lgtm` that exits leaving the terminal raw is a terminal
    /// the user has to `reset`.
    pub fn suspendRaw(self: *Tty) void {
        if (comptime !@hasField(@TypeOf(self.inner), "termios")) return;
        std.posix.tcsetattr(self.inner.fd.handle, .FLUSH, self.inner.termios) catch {};
    }

    pub fn resumeRaw(self: *Tty) void {
        if (comptime !@hasField(@TypeOf(self.inner), "termios")) return;
        _ = vaxis.tty.PosixTty.makeRaw(self.inner.fd.handle) catch {};
    }
};

/// Plain stdout writer for non-TUI output: --help, --version, --profile.
pub const Stdout = struct {
    file_writer: Io.File.Writer,
    buffer: []u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator, io: Io, buffer_bytes: usize) Allocator.Error!Stdout {
        const buffer = try gpa.alloc(u8, buffer_bytes);
        const file = Io.File.stdout();
        return .{
            .file_writer = file.writer(io, buffer),
            .buffer = buffer,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Stdout) void {
        self.gpa.free(self.buffer);
        self.* = undefined;
    }

    pub fn writer(self: *Stdout) *Io.Writer {
        return &self.file_writer.interface;
    }
};
