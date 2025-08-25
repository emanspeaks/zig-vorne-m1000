const std = @import("std");
const serial = @import("serial.zig");
const str_utils = @import("str_utils.zig");

const maxbufsz = str_utils.maxbufsz;

// Special characters constants
pub const ESC = "\x1B";
pub const CR = "\r";
pub const LF = "\n";
pub const SOH = "\x01";
pub const EOT = "\x04";
pub const FF = "\x0c";
pub const DLE = "\x10";
pub const CRLF = "\r\n";

// Simple Packet Protocol (SPP) constants
pub const flush_cmd = ":F";
pub const display_cmd = ":D";
pub const single_nochk = SOH ++ "S";
pub const single_chksum = SOH ++ "T";
pub const single_crc16 = SOH ++ "U";
pub const group_nochk = SOH ++ "s";
pub const group_chksum = SOH ++ "t";
pub const group_crc16 = SOH ++ "u";

pub const timeout_ms: u32 = 2000;

pub fn send(port: *serial.SerialPort, msg: []const u8) !void {
    _ = port.write(msg);

    var buffer: [128]u8 = undefined;
    const received = port.readWithTimeout(&buffer, timeout_ms) catch |err| switch (err) {
        error.PollError => {
            std.debug.print("Error polling for data.\n", .{});
            return;
        },
    };

    if (received == 0) {
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        std.debug.print("No response (timeout after {d:.3} seconds).\n", .{timeout_seconds});
    }
}

pub fn sendVerbose(port: *serial.SerialPort, address: u8, msg: []const u8, allocator: std.mem.Allocator) !void {
    const sent = port.write(msg);

    // Print hex representation to see actual bytes
    std.debug.print("Sent {d} bytes to address {d}: ", .{ sent, address });

    for (msg) |byte| {
        std.debug.print("{X:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});

    // Also print string with escaped characters shown
    const escaped_msg = try formatWithControlChars(allocator, msg);
    defer allocator.free(escaped_msg);
    std.debug.print("Message: {s}\n", .{escaped_msg});

    var buffer: [128]u8 = undefined;
    const received = port.readWithTimeout(&buffer, timeout_ms) catch |err| switch (err) {
        error.PollError => {
            std.debug.print("Error polling for data.\n", .{});
            return;
        },
    };

    if (received > 0) {
        const recvbuf = try formatWithControlChars(allocator, buffer[0..received]);
        std.debug.print("Received {d} bytes: {s}\n", .{ received, recvbuf });
    } else {
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        std.debug.print("No response (timeout after {d:.3} seconds).\n", .{timeout_seconds});
    }
}

pub fn genCmdStr(
    allocator: std.mem.Allocator,
    addr_cmd: []const u8,
    address: u8,
    type_cmd: []const u8,
    data_no_cr: ?[]const u8,
) ![]u8 {
    var buf: [3]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&buf, "{d}", .{address}) catch unreachable;

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8){};
    defer cmd_parts.deinit(allocator);

    try cmd_parts.appendSlice(allocator, addr_cmd);
    try cmd_parts.appendSlice(allocator, addr_str);
    try cmd_parts.appendSlice(allocator, type_cmd);
    if (data_no_cr) |data| {
        if (data.len > 0) {
            try cmd_parts.appendSlice(allocator, data);
        }
    }
    try cmd_parts.appendSlice(allocator, CR);

    return try cmd_parts.toOwnedSlice(allocator);
}

// Generate single flush command
pub fn unitFlushCmd(
    allocator: std.mem.Allocator,
    address: u8,
) ![]u8 {
    const cmd = try genCmdStr(allocator, single_crc16, address, flush_cmd, null);
    defer allocator.free(cmd);
    return appendCrc16(allocator, cmd);
}

pub fn sendUnitFlushCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
) !void {
    const cmd = try unitFlushCmd(allocator, address);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send flush command: {}\n", .{err});
    //     return err;
    // };
}

// Generate group flush command
pub fn grpFlushCmd(
    allocator: std.mem.Allocator,
    address: u8,
) ![]u8 {
    const cmd = try genCmdStr(allocator, group_crc16, address, flush_cmd, null);
    defer allocator.free(cmd);
    return appendCrc16(allocator, cmd);
}

pub fn sendGrpFlushCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
) !void {
    const cmd = try grpFlushCmd(allocator, address);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send group flush command: {}\n", .{err});
    //     return err;
    // };
}

// Generate group display command
pub fn unitDisplayCmd(
    allocator: std.mem.Allocator,
    address: u8,
    input_no_cr: []const u8,
) ![]u8 {
    const cmd = try genCmdStr(allocator, single_crc16, address, display_cmd, input_no_cr);
    defer allocator.free(cmd);
    return appendCrc16(allocator, cmd);
}

pub fn sendUnitDisplayCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
    input_no_cr: []const u8,
) !void {
    const cmd = try unitDisplayCmd(allocator, address, input_no_cr);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send display command: {}\n", .{err});
    //     return err;
    // };
}

// Generate group display command
pub fn grpDisplayCmd(
    allocator: std.mem.Allocator,
    address: u8,
    input_no_cr: []const u8,
) ![]u8 {
    const cmd = try genCmdStr(allocator, group_crc16, address, display_cmd, input_no_cr);
    defer allocator.free(cmd);
    return appendCrc16(allocator, cmd);
}

pub fn sendGrpDisplayCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
    input_no_cr: []const u8,
) !void {
    const cmd = try grpDisplayCmd(allocator, address, input_no_cr);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send group display command: {}\n", .{err});
    //     return err;
    // };
}

pub fn unitDefaultInitCmd(
    allocator: std.mem.Allocator,
    address: u8,
) ![]u8 {
    return unitDisplayCmd(allocator, address, ESC ++ "-g" ++ ESC ++ "0;3H" ++ ESC ++ "0i" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "-B" ++ ESC ++ "-b" ++ FF);
}

pub fn sendUnitDefaultInitCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
) !void {
    const cmd = try unitDefaultInitCmd(allocator, address);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send clear command: {}\n", .{err});
    //     return err;
    // };
}

pub fn grpDefaultInitCmd(
    allocator: std.mem.Allocator,
    address: u8,
) ![]u8 {
    return grpDisplayCmd(allocator, address, ESC ++ "-g" ++ ESC ++ "0;3H" ++ ESC ++ "0i" ++ ESC ++ "0;0;119;15w" ++ ESC ++ "-B" ++ ESC ++ "-b" ++ FF);
}

pub fn sendGrpDefaultInitCmd(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
) !void {
    const cmd = try grpDefaultInitCmd(allocator, address);
    defer allocator.free(cmd);
    try send(port, cmd);
    // sendVerbose(port, address, cmd, allocator) catch |err| {
    //     std.debug.print("Failed to send group clear command: {}\n", .{err});
    //     return err;
    // };
}

pub fn appendStrToCmdList(
    allocator: std.mem.Allocator,
    cmd_parts: *std.ArrayList(u8),
    line: u8,
    column: u8,
    text: []const u8,
) !void {
    var line_buf: [2 * maxbufsz]u8 = undefined;
    // Trim null characters from the text if present
    const trimmed_text = std.mem.sliceTo(text, 0);
    const line_cmd = std.fmt.bufPrint(&line_buf, "{s}{d};{d}C{s}", .{ ESC, line, column, trimmed_text }) catch unreachable;
    try cmd_parts.appendSlice(allocator, line_cmd);
}

// Update a single character at specified line and column
pub fn unitUpdateChar(
    buf: []u8,
    line: u8,
    column: u8,
    new_char: u8,
) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{d};{d}C{c}", .{ ESC, line, column, new_char }) catch unreachable;
}

pub fn sendUnitUpdateChar(
    allocator: std.mem.Allocator,
    port: *serial.SerialPort,
    address: u8,
    line: u8,
    column: u8,
    new_char: u8,
) !void {
    // Build the command string: "<ESC><line>;<col>C<newchar>"
    var cmd_buf: [2 * maxbufsz]u8 = undefined;
    const update_cmd = unitUpdateChar(&cmd_buf, line, column, new_char);

    // Send the command using unitDisplayCmd
    try sendUnitDisplayCmd(allocator, port, address, update_cmd);
}

// Calculate 8-bit checksum (two's complement) and append as uppercase hex
pub fn appendChecksum8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var sum: u8 = 0;
    for (input) |byte| {
        sum = sum +% byte; // Wrapping addition to handle overflow
    }
    const checksum = (~sum) +% 1; // Two's complement

    var result = try allocator.alloc(u8, input.len + 2);
    @memcpy(result[0..input.len], input);
    _ = std.fmt.bufPrint(result[input.len..], "{X:0>2}", .{checksum}) catch unreachable;

    return result;
}

test "appendChecksum8" {
    const testing = std.testing;

    const test_data = "Hello World";
    const result = try appendChecksum8(testing.allocator, test_data);
    defer testing.allocator.free(result);

    // Test that result starts with original data
    try testing.expect(std.mem.startsWith(u8, result, test_data));
    // Test that result is 2 characters longer (original + 2 hex chars)
    try testing.expectEqual(test_data.len + 2, result.len);

    std.debug.print("Checksum8 test: '{s}' -> '{s}'\n", .{ test_data, result });
}

// Calculate Xmodem CRC16 and append as uppercase hex
pub fn appendCrc16(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const crc = calculateXmodemCrc16(input);

    var result = try allocator.alloc(u8, input.len + 4);
    @memcpy(result[0..input.len], input);
    _ = std.fmt.bufPrint(result[input.len..], "{X:0>4}", .{crc}) catch unreachable;

    return result;
}

test "appendCrc16" {
    const testing = std.testing;

    const test_data = "Hello World";
    const result = try appendCrc16(testing.allocator, test_data);
    defer testing.allocator.free(result);

    // Test that result starts with original data
    try testing.expect(std.mem.startsWith(u8, result, test_data));
    // Test that result is 4 characters longer (original + 4 hex chars)
    try testing.expectEqual(test_data.len + 4, result.len);

    std.debug.print("CRC16 test: '{s}' -> '{s}'\n", .{ test_data, result });
}

// Xmodem CRC16 calculation (polynomial 0x1021)
fn calculateXmodemCrc16(data: []const u8) u16 {
    var crc: u16 = 0;

    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;

        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc = crc << 1;
            }
        }
    }

    return crc;
}

test "checksum and crc calculations" {
    const testing = std.testing;

    // Test with known values
    const simple_data = "A";

    const checksum_result = try appendChecksum8(testing.allocator, simple_data);
    defer testing.allocator.free(checksum_result);

    const crc_result = try appendCrc16(testing.allocator, simple_data);
    defer testing.allocator.free(crc_result);

    std.debug.print("Simple test: '{s}' -> checksum: '{s}', crc: '{s}'\n", .{ simple_data, checksum_result, crc_result });
}

// Format data with control character representations for display
pub fn formatWithControlChars(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (data) |byte| {
        switch (byte) {
            0x00...0x1F => {
                // Use lookup table for control characters
                try result.appendSlice(control_chars[byte]);
            },
            0x20...0x7E => {
                // Printable ASCII characters
                try result.append(byte);
            },
            0x7F => {
                // DEL character (index 32 in control_chars array)
                try result.appendSlice(control_chars[32]);
            },
            0x80...0xFF => {
                // Use lookup table for extended characters (CP437/DOS)
                try result.appendSlice(extended_chars[byte - 0x80]);
            },
        }
    }

    return result.toOwnedSlice();
}

// Control character lookup table for characters 0x00-0x1F and 0x7F
pub const control_chars = [_][]const u8{
    "<NUL>", // x00 - @
    "<SOH>", //"☺︎",  // x01 - A
    "☻", //"<STX>",  // x02 - B
    "♥︎", //"<ETX>",  // x03 - C
    "<EOT>", //"♦︎",  // x04 - D
    "♣︎", //"<ENQ>",  // x05 - E
    "♠︎", //"<ACK>",  // x06 - F
    "•", //"<BEL>",  // x07 - G  (rendered as small square bullet)
    "<BS>", //"◘",   // x08 - H
    "<HT>", //"○",   // x09 - I
    "<LF>", //"◙",   // x0a - J
    "<VT>", //"♂︎",   // x0b - K
    "<FF>", //"♀︎",   // x0c - L
    "<CR>", //"♪",   // x0d - M
    "♫", //"<SO>",   // x0e - N
    "☼", //"<SI>",   // x0f - O
    "►", //"<DLE>",  // x10 - P
    "◄", //"<DC1>",  // x11 - Q
    "↕︎", //"<DC2>",  // x12 - R
    "‼︎", //"<DC3>",  // x13 - S
    "¶", //"<DC4>",  // x14 - T
    "§", //"<NAK>",  // x15 - U
    "▬", //"<SYN>",  // x16 - V
    "↨", //"<ETB>",  // x17 - W
    "↑", //"<CAN>",  // x18 - X
    "↓", //"<EM>",   // x19 - Y
    "→", //"<SUB>",  // x1a - Z
    "<ESC>", //"←",  // x1b - [
    "∟", //"<FS>",   // x1c - \
    "↔︎", //"<GS>",   // x1d - ]
    "▲", //"<RS>",   // x1e - ^
    "▼", //"<US>",   // x1f - _
    "⌂", //"<DEL>",  // x7f - `
};

// Extended character lookup table for characters 0x80-0xFF (CP437/DOS)
pub const extended_chars = [_][]const u8{
    "Ç", // x80
    "ü", // x81
    "é", // x82
    "â", // x83
    "ä", // x84
    "à", // x85
    "å", // x86
    "ç", // x87
    "ê", // x88
    "ë", // x89
    "è", // x8a
    "ï", // x8b
    "î", // x8c
    "ì", // x8d
    "Ä", // x8e
    "Å", // x8f
    "É", // x90
    "æ", // x91
    "Æ", // x92
    "ô", // x93
    "ö", // x94
    "ò", // x95
    "û", // x96
    "ù", // x97
    "ÿ", // x98
    "Ö", // x99
    "Ü", // x9a
    "¢", // x9b
    "£", // x9c
    "¥", // x9d
    "<Pt>", // x9e
    "ƒ", // x9f
    "á", // xa0
    "í", // xa1
    "ó", // xa2
    "ú", // xa3
    "ñ", // xa4
    "Ñ", // xa5
    "a", // xa6
    "o", // xa7
    "¿", // xa8
    "⌐", // xa9
    "¬", // xaa
    "½", // xab
    "¼", // xac
    "¡", // xad
    "«", // xae
    "»", // xaf
    "░", // xb0
    "▒", // xb1
    "▓", // xb2
    "│", // xb3
    "┤", // xb4
    "╡", // xb5
    "╢", // xb6
    "╖", // xb7
    "╕", // xb8
    "╣", // xb9
    "║", // xba
    "╗", // xbb
    "╝", // xbc
    "╜", // xbd
    "╛", // xbe
    "┐", // xbf
    "└", // xc0
    "┴", // xc1
    "┬", // xc2
    "├", // xc3
    "─", // xc4
    "┼", // xc5
    "╞", // xc6
    "╟", // xc7
    "╚", // xc8
    "╔", // xc9
    "╩", // xca
    "╦", // xcb
    "╠", // xcc
    "═", // xcd
    "╬", // xce
    "╧", // xcf
    "╨", // xd0
    "╤", // xd1
    "╥", // xd2
    "╙", // xd3
    "╘", // xd4
    "╒", // xd5
    "╓", // xd6
    "╫", // xd7
    "╪", // xd8
    "┘", // xd9
    "┌", // xda
    "█", // xdb
    "▄", // xdc
    "▌", // xdd
    "▐", // xde
    "▀", // xdf
    "α", // xe0
    "ß", // xe1
    "Γ", // xe2
    "π", // xe3
    "Σ", // xe4
    "σ", // xe5
    "µ", // xe6
    "τ", // xe7
    "Φ", // xe8
    "Θ", // xe9
    "Ω", // xea
    "δ", // xeb
    "∞", // xec
    "φ", // xed
    "ε", // xee
    "∩", // xef
    "≡", // xf0
    "±", // xf1
    "≥", // xf2
    "≤", // xf3
    "⌠", // xf4
    "⌡", // xf5
    "÷", // xf6
    "≈", // xf7
    "°", // xf8
    "∙", // xf9
    "·", // xfa
    "√", // xfb
    "ⁿ", // xfc
    "²", // xfd
    "■", // xfe
    "�", // xff
};
