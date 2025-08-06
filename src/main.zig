const std = @import("std");
const linux = std.os.linux;

// Special characters constants
const ESC = "\x1B";
const CR = "\r";
const LF = "\n";
const CRLF = "\r\n";
const SOH = "\x01";
const FF = "\x0c";

// Simple Packet Protocol (SPP) constants
const flush_cmd = ":F";
const display_cmd = ":D";
const single_nochk = SOH ++ "S";
const single_chksum = SOH ++ "T";
const single_crc16 = SOH ++ "U";
const group_nochk = SOH ++ "s";
const group_chksum = SOH ++ "t";
const group_crc16 = SOH ++ "u";

fn formatWithControlChars(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (data) |byte| {
        switch (byte) {
            0x00 => try result.appendSlice("<NUL>"),
            0x01 => try result.appendSlice("<SOH>"),
            0x02 => try result.appendSlice("<STX>"),
            0x03 => try result.appendSlice("<ETX>"),
            0x04 => try result.appendSlice("<EOT>"),
            0x05 => try result.appendSlice("<ENQ>"),
            0x06 => try result.appendSlice("<ACK>"),
            0x07 => try result.appendSlice("<BEL>"),
            0x08 => try result.appendSlice("<BS>"),
            0x09 => try result.appendSlice("<HT>"),
            0x0A => try result.appendSlice("<LF>"),
            0x0B => try result.appendSlice("<VT>"),
            0x0C => try result.appendSlice("<FF>"),
            0x0D => try result.appendSlice("<CR>"),
            0x0E => try result.appendSlice("<SO>"),
            0x0F => try result.appendSlice("<SI>"),
            0x10 => try result.appendSlice("<DLE>"),
            0x11 => try result.appendSlice("<DC1>"),
            0x12 => try result.appendSlice("<DC2>"),
            0x13 => try result.appendSlice("<DC3>"),
            0x14 => try result.appendSlice("<DC4>"),
            0x15 => try result.appendSlice("<NAK>"),
            0x16 => try result.appendSlice("<SYN>"),
            0x17 => try result.appendSlice("<ETB>"),
            0x18 => try result.appendSlice("<CAN>"),
            0x19 => try result.appendSlice("<EM>"),
            0x1A => try result.appendSlice("<SUB>"),
            0x1B => try result.appendSlice("<ESC>"),
            0x1C => try result.appendSlice("<FS>"),
            0x1D => try result.appendSlice("<GS>"),
            0x1E => try result.appendSlice("<RS>"),
            0x1F => try result.appendSlice("<US>"),
            0x7F => try result.appendSlice("<DEL>"),
            0x80 => try result.appendSlice("Ç"),
            0x81 => try result.appendSlice("ü"),
            0x82 => try result.appendSlice("é"),
            0x83 => try result.appendSlice("â"),
            0x84 => try result.appendSlice("ä"),
            0x85 => try result.appendSlice("à"),
            0x86 => try result.appendSlice("å"),
            0x87 => try result.appendSlice("ç"),
            0x88 => try result.appendSlice("ê"),
            0x89 => try result.appendSlice("ë"),
            0x8A => try result.appendSlice("è"),
            0x8B => try result.appendSlice("ï"),
            0x8C => try result.appendSlice("î"),
            0x8D => try result.appendSlice("ì"),
            0x8E => try result.appendSlice("Ä"),
            0x8F => try result.appendSlice("Å"),
            0x90 => try result.appendSlice("É"),
            0x91 => try result.appendSlice("æ"),
            0x92 => try result.appendSlice("Æ"),
            0x93 => try result.appendSlice("ô"),
            0x94 => try result.appendSlice("ö"),
            0x95 => try result.appendSlice("ò"),
            0x96 => try result.appendSlice("û"),
            0x97 => try result.appendSlice("ù"),
            0x98 => try result.appendSlice("ÿ"),
            0x99 => try result.appendSlice("Ö"),
            0x9A => try result.appendSlice("Ü"),
            0x9B => try result.appendSlice("¢"),
            0x9C => try result.appendSlice("£"),
            0x9D => try result.appendSlice("¥"),
            0x9E => try result.appendSlice("<Pt>"),
            0x9F => try result.appendSlice("ƒ"),
            0xA0 => try result.appendSlice("á"),
            0xA1 => try result.appendSlice("í"),
            0xA2 => try result.appendSlice("ó"),
            0xA3 => try result.appendSlice("ú"),
            0xA4 => try result.appendSlice("ñ"),
            0xA5 => try result.appendSlice("Ñ"),
            0xA6 => try result.appendSlice("a"),
            0xA7 => try result.appendSlice("o"),
            0xA8 => try result.appendSlice("¿"),
            0xA9 => try result.appendSlice("⌐"),
            0xAA => try result.appendSlice("¬"),
            0xAB => try result.appendSlice("½"),
            0xAC => try result.appendSlice("¼"),
            0xAD => try result.appendSlice("¡"),
            0xAE => try result.appendSlice("«"),
            0xAF => try result.appendSlice("»"),
            0xB0 => try result.appendSlice("░"),
            0xB1 => try result.appendSlice("▒"),
            0xB2 => try result.appendSlice("▓"),
            0xB3 => try result.appendSlice("│"),
            0xB4 => try result.appendSlice("┤"),
            0xB5 => try result.appendSlice("╡"),
            0xB6 => try result.appendSlice("╢"),
            0xB7 => try result.appendSlice("╖"),
            0xB8 => try result.appendSlice("╕"),
            0xB9 => try result.appendSlice("╣"),
            0xBA => try result.appendSlice("║"),
            0xBB => try result.appendSlice("╗"),
            0xBC => try result.appendSlice("╝"),
            0xBD => try result.appendSlice("╜"),
            0xBE => try result.appendSlice("╛"),
            0xBF => try result.appendSlice("┐"),
            0xC0 => try result.appendSlice("└"),
            0xC1 => try result.appendSlice("┴"),
            0xC2 => try result.appendSlice("┬"),
            0xC3 => try result.appendSlice("├"),
            0xC4 => try result.appendSlice("─"),
            0xC5 => try result.appendSlice("┼"),
            0xC6 => try result.appendSlice("╞"),
            0xC7 => try result.appendSlice("╟"),
            0xC8 => try result.appendSlice("╚"),
            0xC9 => try result.appendSlice("╔"),
            0xCA => try result.appendSlice("╩"),
            0xCB => try result.appendSlice("╦"),
            0xCC => try result.appendSlice("╠"),
            0xCD => try result.appendSlice("═"),
            0xCE => try result.appendSlice("╬"),
            0xCF => try result.appendSlice("╧"),
            0xD0 => try result.appendSlice("╨"),
            0xD1 => try result.appendSlice("╤"),
            0xD2 => try result.appendSlice("╥"),
            0xD3 => try result.appendSlice("╙"),
            0xD4 => try result.appendSlice("╘"),
            0xD5 => try result.appendSlice("╒"),
            0xD6 => try result.appendSlice("╓"),
            0xD7 => try result.appendSlice("╫"),
            0xD8 => try result.appendSlice("╪"),
            0xD9 => try result.appendSlice("┘"),
            0xDA => try result.appendSlice("┌"),
            0xDB => try result.appendSlice("█"),
            0xDC => try result.appendSlice("▄"),
            0xDD => try result.appendSlice("▌"),
            0xDE => try result.appendSlice("▐"),
            0xDF => try result.appendSlice("▀"),
            0xE0 => try result.appendSlice("α"),
            0xE1 => try result.appendSlice("ß"),
            0xE2 => try result.appendSlice("Γ"),
            0xE3 => try result.appendSlice("π"),
            0xE4 => try result.appendSlice("Σ"),
            0xE5 => try result.appendSlice("σ"),
            0xE6 => try result.appendSlice("µ"),
            0xE7 => try result.appendSlice("τ"),
            0xE8 => try result.appendSlice("Φ"),
            0xE9 => try result.appendSlice("Θ"),
            0xEA => try result.appendSlice("Ω"),
            0xEB => try result.appendSlice("δ"),
            0xEC => try result.appendSlice("∞"),
            0xED => try result.appendSlice("φ"),
            0xEE => try result.appendSlice("ε"),
            0xEF => try result.appendSlice("∩"),
            0xF0 => try result.appendSlice("≡"),
            0xF1 => try result.appendSlice("±"),
            0xF2 => try result.appendSlice("≥"),
            0xF3 => try result.appendSlice("≤"),
            0xF4 => try result.appendSlice("⌠"),
            0xF5 => try result.appendSlice("⌡"),
            0xF6 => try result.appendSlice("÷"),
            0xF7 => try result.appendSlice("≈"),
            0xF8 => try result.appendSlice("°"),
            0xF9 => try result.appendSlice("∙"),
            0xFA => try result.appendSlice("·"),
            0xFB => try result.appendSlice("√"),
            0xFC => try result.appendSlice("ⁿ"),
            0xFD => try result.appendSlice("²"),
            0xFE => try result.appendSlice("■"),
            0xFF => try result.appendSlice("�"),
            0x20...0x7E => try result.append(byte), // Printable ASCII
            // else => {
            //     const hex_str = try std.fmt.allocPrint(allocator, "<{X:0>2}>", .{byte});
            //     defer allocator.free(hex_str);
            //     try result.appendSlice(hex_str);
            // },
        }
    }

    return result.toOwnedSlice();
}

const SerialPort = struct {
    fd: linux.fd_t,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !*SerialPort {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.fs.File.stdout();
    const ttydev = "/dev/ttyUSB0";

    try stdout.writeAll("Opening {s}...\n", .{ttydev});
    const port_result = SerialPort.open(ttydev, allocator);

    // If initial open failed but driver is loaded, try again
    if (port_result) |port| {
        // Initial open succeeded, proceed with communication
        defer port.close(allocator);
        return runSerialCommunication(port, allocator);
    } else |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll("Device {s} not found.\n", .{ttydev});
            return;
        },
        error.AccessDenied => {
            try stdout.writeAll("Permission denied. Make sure you're in the dialout group.\n");
            return;
        },
        else => return err,
    }
}

fn runSerialCommunication(port: *SerialPort, allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();

    // const msg = ESC ++ "01A" ++ ESC ++ "S Hello M1000" ++ CR;
    // const msg = ESC ++ "25;-B" ++ ESC ++ "25;-b" ++ ESC ++ "2s" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "@" ++ ESC ++ "0;0c" ++ ESC ++ "0;3H" ++ ESC ++ "2FTest from randy" ++ ESC ++ "8;60c" ++ ESC ++ "20W" ++ ESC ++ "1W" ++ ESC ++ "E" ++ ESC ++ "1G" ++ CR;
    const flushmsg = group_crc16 ++ "0" ++ flush_cmd ++ CR ++ "233B";
    const clearmsg = group_crc16 ++ "0" ++ display_cmd ++ ESC ++ "-g" ++ ESC ++ "0;3H" ++ ESC ++ "0i" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "-B" ++ ESC ++ "-b" ++ FF ++ CR ++ "A965";
    const testmsg = group_crc16 ++ "0" ++ display_cmd ++ ESC ++ "25;-B" ++ ESC ++ "25;-b" ++ ESC ++ "2s" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "@" ++ ESC ++ "0;0c" ++ ESC ++ "0;3H" ++ ESC ++ "2FTest from randy" ++ ESC ++ "8;60c" ++ ESC ++ "20W" ++ ESC ++ "1W" ++ ESC ++ "E" ++ ESC ++ "1G" ++ CR ++ "254C";
    const msg = flushmsg ++ clearmsg ++ testmsg;
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
        const recv_msg = try std.fmt.allocPrint(allocator, "Received {d} bytes: {s}\n", .{ received, buffer[0..received] });
        defer allocator.free(recv_msg);
        try stdout.writeAll(recv_msg);
    } else {
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        const timeout_msg = try std.fmt.allocPrint(allocator, "No response (timeout after {d:.3} seconds).\n", .{timeout_seconds});
        defer allocator.free(timeout_msg);
        try stdout.writeAll(timeout_msg);
    }
}
