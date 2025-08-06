const std = @import("std");
const linux = std.os.linux;

pub const SerialPort = struct {
    fd: linux.fd_t,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !*SerialPort {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
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

    pub fn write(self: *SerialPort, data: []const u8) usize {
        return linux.write(self.fd, data.ptr, data.len);
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
