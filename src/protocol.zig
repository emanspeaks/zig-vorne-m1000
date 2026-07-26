const std = @import("std");
const serial = @import("serial.zig");
const str_utils = @import("str_utils.zig");
const vorne_charset = @import("vorne_charset.zig");

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

/// Discard whatever the unit has sent back, without blocking.
///
/// Nothing in this program interprets the reply, so waiting for one only adds
/// latency to the render loop. Draining keeps the tty input buffer from filling
/// up (there is no hardware flow control configured, so unread bytes are simply
/// dropped by the kernel).
fn drainInput(port: *serial.SerialPort) void {
    var buffer: [128]u8 = undefined;
    while (true) {
        const received = port.readWithTimeout(&buffer, 0) catch return;
        // A short read means the buffer is empty; an oversized value means the
        // underlying read() returned an error code rather than a length.
        if (received == 0 or received > buffer.len) return;
    }
}

pub fn send(port: *serial.SerialPort, msg: []const u8) !void {
    _ = port.write(msg);
    drainInput(port);
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
    var cmd_parts = std.ArrayList(u8).empty;
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

// The character repertoire lives in its own module so the cue parser can use
// it without importing the serial layer.
pub const control_chars = vorne_charset.control_chars;
pub const extended_chars = vorne_charset.extended_chars;
