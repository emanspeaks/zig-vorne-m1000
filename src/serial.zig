const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

pub const SerialPort = struct {
    fd: linux.fd_t,

    pub fn open(io: Io, path: []const u8, allocator: std.mem.Allocator) !*SerialPort {
        const file = Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Device {s} not found.\n", .{path});
                return err;
            },
            error.AccessDenied => {
                std.debug.print("Permission denied accessing {s}. Make sure you're in the dialout or plugdev group.\n", .{path});
                return err;
            },
            else => return err,
        };
        // std.debug.print("Serial port opened successfully, fd: {}\n", .{file.handle});

        var self = try allocator.create(SerialPort);
        self.* = SerialPort{ .fd = file.handle };

        try self.configure();
        // std.debug.print("Serial port configured successfully\n", .{});

        return self;
    }

    fn configure(self: *SerialPort) !void {
        var termios: linux.termios = undefined;

        // Get current attributes
        if (linux.tcgetattr(self.fd, &termios) < 0) {
            return error.GetAttrFailed;
        }

        // Clear all flags for raw mode
        termios.lflag = .{};
        termios.oflag = .{};
        termios.iflag = .{};

        // Set control flags for 19200 8N1
        termios.cflag.CSIZE = linux.CSIZE.CS8;
        termios.cflag.PARENB = false; // No parity
        termios.cflag.CSTOPB = false; // 1 stop bit
        termios.cflag.CLOCAL = true; // Local connection
        termios.cflag.CREAD = true; // Enable receiver
        termios.cflag.HUPCL = false; // Don't hang up on close

        // Set baud rate in cflag
        const cflag_val = @as(u32, @bitCast(termios.cflag));

        const cbaud_mask: u32 = @intFromEnum(linux.speed_t.B4000000); // CBAUD mask for non-ppc, non-sparc linux
        const new_cflag = (cflag_val & ~cbaud_mask) | @intFromEnum(linux.speed_t.B19200);
        termios.cflag = @bitCast(new_cflag);

        // // Control characters for raw mode
        // termios.cc[@intFromEnum(linux.V.MIN)] = 0; // Non-blocking read
        // termios.cc[@intFromEnum(linux.V.TIME)] = 10; // 1 second timeout

        // Apply settings
        if (linux.tcsetattr(self.fd, linux.TCSA.NOW, &termios) < 0) {
            return error.SetAttrFailed;
        }

        std.debug.print("Serial port configured: 19200 8N1 raw mode\n", .{});
    }

    /// How long a single write attempt may wait for the port to be writable
    /// before giving up. A 20-column line is on the order of 17 ms of wire
    /// time at 19200 baud, so this is generous slack, not a tight budget --
    /// its only job is to convert "the kernel write buffer will never drain"
    /// (a wedged USB-serial adapter, a wiring/flow-control fault holding CTS
    /// low) from an unbounded hang into a bounded, logged, retried-next-pass
    /// failure. The display loop is a real-time task with a hard rule that
    /// nothing on it may block unboundedly; a plain blocking `write(2)` on a
    /// tty is exactly that hazard, since the kernel is free to block the
    /// caller until the device drains, however long that takes.
    const write_timeout_ms = 500;

    /// Write the whole of `data`, looping over short writes.
    ///
    /// `linux.write` returns the raw syscall result: a negated errno (as a
    /// huge `usize`, when reinterpreted as `isize` it is negative) on
    /// failure, or otherwise the number of bytes actually written -- which
    /// can be *less than requested even when nothing is wrong*, so a single
    /// call is not enough to guarantee the whole buffer reached the wire. A
    /// caller that only ever issued one call and ignored the count (as this
    /// used to) would have no way to notice a display command that was only
    /// partially sent.
    pub fn write(self: *SerialPort, data: []const u8) error{ WriteFailed, WriteTimeout }!void {
        var remaining = data;
        while (remaining.len > 0) {
            var poll_fd = linux.pollfd{
                .fd = self.fd,
                .events = linux.POLL.OUT,
                .revents = 0,
            };
            const poll_result = linux.poll(@ptrCast(&poll_fd), 1, write_timeout_ms);
            if (poll_result <= 0) return error.WriteTimeout;

            const result = linux.write(self.fd, remaining.ptr, remaining.len);
            const signed: isize = @bitCast(result);
            // <= 0 covers both a negated errno and a zero-byte write, which
            // on a real device means something is wrong (full buffer with no
            // drain in sight, or the far end has gone away) rather than
            // "try again" -- looping on it would spin the render loop
            // forever instead of ever reporting the failure.
            if (signed <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(signed)..];
        }
    }

    /// Block until everything written has actually been clocked out of the port.
    ///
    /// `write` returns as soon as the bytes are in the kernel's output buffer,
    /// which at 19200 baud is long before they are on the wire -- a 40 byte
    /// frame is still ~21 ms from being delivered. That is normally fine and
    /// deliberately so: the render loop must not block waiting on the wire.
    ///
    /// It is *not* fine when the next thing sent depends on the panel having
    /// finished acting on the last thing. The panel has no flow control and a
    /// small input buffer, so bytes that arrive while it is busy are simply
    /// dropped -- and the initialisation sequence, which clears the screen and
    /// sets the display window, is the slowest thing it is ever asked to do.
    /// Sending a frame straight after it means that frame lands in the middle
    /// of that work and is lost.
    pub fn drain(self: *SerialPort) void {
        // Failure here is not actionable -- the bytes are already queued and
        // will still go out; we simply did not get to wait for them.
        _ = linux.tcdrain(self.fd);
    }

    pub fn read(self: *SerialPort, buffer: []u8) usize {
        return linux.read(self.fd, buffer.ptr, buffer.len);
    }

    pub fn readWithTimeout(self: *SerialPort, buffer: []u8, timeout_ms: u32) !usize {
        var poll_fd = linux.pollfd{
            .fd = self.fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };

        const poll_result = linux.poll(@ptrCast(&poll_fd), 1, @intCast(timeout_ms));
        if (poll_result < 0) {
            return error.PollError;
        }

        if (poll_result == 0) {
            // Timeout occurred
            return 0;
        }

        if (poll_fd.revents & linux.POLL.IN != 0) {
            return linux.read(self.fd, buffer.ptr, buffer.len);
        }

        return 0;
    }

    pub fn close(self: *SerialPort, allocator: std.mem.Allocator) void {
        _ = linux.close(self.fd);
        allocator.destroy(self);
    }
};
