const std = @import("std");
const linux = std.os.linux;

// Special characters constants
const ESC = "\x1B";
const CR = "\r";
const LF = "\n";
const CRLF = "\r\n";

fn formatWithControlChars(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (data) |byte| {
        switch (byte) {
            0x00 => try result.appendSlice("<NUL>"),
            0x07 => try result.appendSlice("<BEL>"),
            0x08 => try result.appendSlice("<BS>"),
            0x09 => try result.appendSlice("<TAB>"),
            0x0A => try result.appendSlice("<LF>"),
            0x0B => try result.appendSlice("<VT>"),
            0x0C => try result.appendSlice("<FF>"),
            0x0D => try result.appendSlice("<CR>"),
            0x1B => try result.appendSlice("<ESC>"),
            0x20...0x7E => try result.append(byte), // Printable ASCII
            else => {
                const hex_str = try std.fmt.allocPrint(allocator, "<{X:0>2}>", .{byte});
                defer allocator.free(hex_str);
                try result.appendSlice(hex_str);
            },
        }
    }

    return result.toOwnedSlice();
}

const SerialPort = struct {
    fd: linux.fd_t,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !*SerialPort {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        std.debug.print("Serial port opened successfully, fd: {}\n", .{file.handle});

        var self = try allocator.create(SerialPort);
        self.* = SerialPort{ .fd = file.handle };

        try self.configure();
        std.debug.print("Serial port configured successfully\n", .{});

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

        // Set baud rate in cflag (this is the traditional approach)
        const cflag_val = @as(u32, @bitCast(termios.cflag));
        const cbaud_mask: u32 = 0o010017; // CBAUD mask
        const new_cflag = (cflag_val & ~cbaud_mask) | @intFromEnum(linux.speed_t.B19200);
        termios.cflag = @bitCast(new_cflag);

        // Control characters for raw mode
        termios.cc[@intFromEnum(linux.V.MIN)] = 0; // Non-blocking read
        termios.cc[@intFromEnum(linux.V.TIME)] = 10; // 1 second timeout

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

fn tryLoadPl2303Driver(allocator: std.mem.Allocator) !bool {
    const stdout = std.fs.File.stdout();

    // First check if the driver is already loaded
    try stdout.writeAll("Checking if PL2303 driver is loaded...\n");
    const lsmod_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"lsmod"},
    }) catch {
        try stdout.writeAll("Warning: Could not run lsmod to check drivers\n");
        return false;
    };
    defer allocator.free(lsmod_result.stdout);
    defer allocator.free(lsmod_result.stderr);

    if (std.mem.indexOf(u8, lsmod_result.stdout, "pl2303") != null) {
        try stdout.writeAll("PL2303 driver is already loaded\n");
        return true;
    }

    try stdout.writeAll("PL2303 driver not loaded, attempting to load it...\n");

    // Try to load the usbserial module first (dependency)
    const modprobe_usbserial = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sudo", "modprobe", "usbserial" },
    }) catch {
        try stdout.writeAll("Warning: Could not load usbserial module (may already be loaded)\n");
        return false;
    };
    defer allocator.free(modprobe_usbserial.stdout);
    defer allocator.free(modprobe_usbserial.stderr);

    if (modprobe_usbserial.term.Exited != 0) {
        const err_msg = try std.fmt.allocPrint(allocator, "Failed to load usbserial module: {s}\n", .{modprobe_usbserial.stderr});
        defer allocator.free(err_msg);
        try stdout.writeAll(err_msg);
    }

    // Now try to load the pl2303 module
    const modprobe_pl2303 = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sudo", "modprobe", "pl2303" },
    }) catch {
        try stdout.writeAll("Error: Could not run modprobe to load PL2303 driver\n");
        return false;
    };
    defer allocator.free(modprobe_pl2303.stdout);
    defer allocator.free(modprobe_pl2303.stderr);

    if (modprobe_pl2303.term.Exited == 0) {
        try stdout.writeAll("Successfully loaded PL2303 driver\n");
        // Give the system a moment to detect the device
        std.Thread.sleep(1000000000); // 1 second
        return true;
    } else {
        const err_msg = try std.fmt.allocPrint(allocator, "Failed to load PL2303 driver: {s}\n", .{modprobe_pl2303.stderr});
        defer allocator.free(err_msg);
        try stdout.writeAll(err_msg);
        return false;
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.fs.File.stdout();

    try stdout.writeAll("Opening /dev/ttyUSB0...\n");
    const port = SerialPort.open("/dev/ttyUSB0", allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll("Device /dev/ttyUSB0 not found.\n");

            // Try to load the PL2303 driver
            if (tryLoadPl2303Driver(allocator) catch false) {
                try stdout.writeAll("Driver loaded, trying to open device again...\n");
                // Try opening the device again after loading the driver
                const retry_port = SerialPort.open("/dev/ttyUSB0", allocator) catch |retry_err| switch (retry_err) {
                    error.FileNotFound => {
                        try stdout.writeAll("Device still not found after loading driver. Available serial devices:\n");
                        _ = std.process.Child.run(.{
                            .allocator = allocator,
                            .argv = &[_][]const u8{ "ls", "-la", "/dev/tty*" },
                        }) catch {};
                        return;
                    },
                    error.AccessDenied => {
                        try stdout.writeAll("Permission denied. Make sure you're in the dialout group.\n");
                        return;
                    },
                    else => return retry_err,
                };
                defer retry_port.close(allocator);

                // Continue with the rest of the serial communication using retry_port
                return runSerialCommunication(retry_port, allocator);
            } else {
                try stdout.writeAll("Could not load driver. Available serial devices:\n");
                _ = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "ls", "-la", "/dev/tty*" },
                }) catch {};
                return;
            }
        },
        error.AccessDenied => {
            try stdout.writeAll("Permission denied. Make sure you're in the dialout group.\n");
            return;
        },
        else => return err,
    };
    defer port.close(allocator);

    return runSerialCommunication(port, allocator);
}

fn runSerialCommunication(port: *SerialPort, allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();

    // const msg = ESC ++ "01A" ++ ESC ++ "S Hello M1000" ++ CR;
    const msg = ESC ++ "25;-B" ++ ESC ++ "25;-b" ++ ESC ++ "2s" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "@" ++ ESC ++ "0;0c" ++ ESC ++ "0;3H" ++ ESC ++ "2FTest from randy" ++ ESC ++ "8;60c" ++ ESC ++ "20W" ++ ESC ++ "1W" ++ ESC ++ "E" ++ ESC ++ "1G" ++ CR;
    const sent = port.write(msg);

    // Print hex representation to see actual bytes
    const sent_msg = try std.fmt.allocPrint(allocator, "Sent {d} bytes: ", .{sent});
    defer allocator.free(sent_msg);
    try stdout.writeAll(sent_msg);

    for (msg) |byte| {
        const hex_byte = try std.fmt.allocPrint(allocator, "{X:0>2} ", .{byte});
        defer allocator.free(hex_byte);
        try stdout.writeAll(hex_byte);
    }
    try stdout.writeAll("\n");

    // Also print string with escaped characters shown
    const escaped_msg = try formatWithControlChars(allocator, msg);
    defer allocator.free(escaped_msg);
    const display_msg = try std.fmt.allocPrint(allocator, "Message: {s}\n", .{escaped_msg});
    defer allocator.free(display_msg);
    try stdout.writeAll(display_msg);

    var buffer: [128]u8 = undefined;
    const timeout_ms: u32 = 15000;
    const received = port.readWithTimeout(&buffer, timeout_ms) catch |err| switch (err) {
        error.PollError => {
            try stdout.writeAll("Error polling for data.\n");
            return;
        },
    };

    if (received > 0) {
        const recv_msg = try std.fmt.allocPrint(allocator, "Received: {s}\n", .{buffer[0..received]});
        defer allocator.free(recv_msg);
        try stdout.writeAll(recv_msg);
    } else {
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        const timeout_msg = try std.fmt.allocPrint(allocator, "No response (timeout after {d:.3} seconds).\n", .{timeout_seconds});
        defer allocator.free(timeout_msg);
        try stdout.writeAll(timeout_msg);
    }
}
