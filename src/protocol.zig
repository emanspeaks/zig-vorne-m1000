const std = @import("std");
const dbg = @import("debug_log.zig");
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

/// Send a command and wait for the panel's reply, up to `timeout_ms`.
///
/// This is the pacing mechanism between commands, and deliberately not a
/// fixed delay. The panel has no flow control and a small input buffer, so a
/// command that arrives while it is still busy with the last one is simply
/// dropped rather than queued -- and its reply is the one signal available
/// that it has finished and is ready for another. Waiting for that reply,
/// rather than guessing a fixed gap, means a command the panel answers
/// quickly is not held up for no reason, and a command that takes longer
/// (the initialisation sequence, which clears the screen and sets the display
/// window, most of all) is not raced.
///
/// Nothing here interprets the reply's *content* -- only its arrival matters.
/// `timeout_ms` (2 s) bounds the wait for the case where the panel does not
/// answer at all, so a disconnected or wedged unit cannot hang this call
/// forever; on that path a diagnostic is worth logging; `try port.write`
/// still propagates a genuine write failure (a short or failed send, or the
/// port itself timing out -- see `SerialPort.write`), which is a different
/// and more serious condition than the unit simply not replying.
pub fn send(port: *serial.SerialPort, msg: []const u8) !void {
    try port.write(msg);

    var buffer: [128]u8 = undefined;
    const received = port.readWithTimeout(&buffer, timeout_ms) catch |err| switch (err) {
        error.PollError => {
            dbg.print(.serial, "Error polling for a reply.\n", .{});
            return;
        },
    };
    if (received == 0) {
        dbg.print(.serial, "No response after {d} ms.\n", .{timeout_ms});
    }
}

pub fn sendVerbose(port: *serial.SerialPort, address: u8, msg: []const u8, allocator: std.mem.Allocator) !void {
    try port.write(msg);

    // Print hex representation to see actual bytes. A successful write() now
    // always means the whole message went out -- see its own doc -- so the
    // count is just msg.len, not something read back from the write itself.
    dbg.print(.serial, "Sent {d} bytes to address {d}: ", .{ msg.len, address });

    for (msg) |byte| {
        dbg.print(.serial, "{X:0>2} ", .{byte});
    }
    dbg.print(.serial, "\n", .{});

    // Also print string with escaped characters shown
    const escaped_msg = try formatWithControlChars(allocator, msg);
    defer allocator.free(escaped_msg);
    dbg.print(.serial, "Message: {s}\n", .{escaped_msg});

    var buffer: [128]u8 = undefined;
    const received = port.readWithTimeout(&buffer, timeout_ms) catch |err| switch (err) {
        error.PollError => {
            std.debug.print("Error polling for data.\n", .{});
            return;
        },
    };

    if (received > 0) {
        const recvbuf = try formatWithControlChars(allocator, buffer[0..received]);
        dbg.print(.serial, "Received {d} bytes: {s}\n", .{ received, recvbuf });
    } else {
        const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        dbg.print(.serial, "No response (timeout after {d:.3} seconds).\n", .{timeout_seconds});
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

/// Append only the columns that actually differ between `prev` and `next`.
///
/// A full 20-column line is about 35 bytes on the wire once framed, or 18 ms at
/// 19200 baud; a one-character correction is about 17 bytes, or 9 ms. Nothing
/// renders until the CRC terminating the frame arrives, so that difference is
/// latency between the moment a clock ticks and the moment the panel shows it
/// -- and, worse, latency that *varies* with how much of the line happened to
/// change. A ticking clock usually alters one or two digits, so redrawing the
/// whole line to move a seconds digit is both slower and less even than it
/// needs to be. `clocks.zig` has always rewritten just the seconds digit for
/// this reason (`unitUpdateChar`); this is the same idea, worked out from the
/// content rather than from hardcoded column numbers, so it also covers the
/// playback clock, a minute or hour rollover, and a changed transport glyph
/// without any of them being special-cased.
///
/// One escape and one contiguous span, from the first differing column to the
/// last, rather than a separate escape per differing run: two escapes cost more
/// than the handful of unchanged columns between two nearby edits, and the
/// common case (a clock tick) is a single run anyway.
///
/// Columns, not bytes, throughout -- a DLE-escaped glyph is two bytes in one
/// column, so the column a `C` escape names and the byte offset of its text are
/// different numbers whenever the line holds one.
///
/// Falls back to a whole-line write when the two differ in width, since there
/// is then no column-for-column correspondence to diff. Appends nothing at all
/// when they are identical.
pub fn appendChangedColsToCmdList(
    allocator: std.mem.Allocator,
    cmd_parts: *std.ArrayList(u8),
    line: u8,
    prev: []const u8,
    next: []const u8,
) !void {
    const prev_cols = (str_utils.strlensz(prev) catch unreachable)[0];
    const next_cols = (str_utils.strlensz(next) catch unreachable)[0];
    if (prev_cols != next_cols) {
        return appendStrToCmdList(allocator, cmd_parts, line, 1, next);
    }

    var first: ?usize = null;
    var last: usize = 0;
    var col: usize = 0;
    while (col < next_cols) : (col += 1) {
        const pa = str_utils.idxChar2Str(prev, col) catch unreachable;
        const pb = str_utils.idxChar2Str(prev, col + 1) catch unreachable;
        const na = str_utils.idxChar2Str(next, col) catch unreachable;
        const nb = str_utils.idxChar2Str(next, col + 1) catch unreachable;
        if (!std.mem.eql(u8, prev[pa..pb], next[na..nb])) {
            if (first == null) first = col;
            last = col;
        }
    }

    const from = first orelse return;
    const start = str_utils.idxChar2Str(next, from) catch unreachable;
    const end = str_utils.idxChar2Str(next, last + 1) catch unreachable;
    // Columns are 1-based in the escape sequence.
    try appendStrToCmdList(allocator, cmd_parts, line, @intCast(from + 1), next[start..end]);
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

test "appendChangedColsToCmdList sends only the digits a clock tick moved" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    // The overwhelmingly common case: one seconds digit. Redrawing the line
    // would be 20 columns of payload; this is one.
    try appendChangedColsToCmdList(testing.allocator, &parts, 1, "20:37:13", "20:37:14");
    try testing.expectEqualStrings(ESC ++ "1;8C4", parts.items);
}

test "appendChangedColsToCmdList spans from the first change to the last" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    // A minute rollover moves several digits at once, and the span covers them
    // in one escape rather than one escape per run.
    try appendChangedColsToCmdList(testing.allocator, &parts, 1, "20:37:59", "20:38:00");
    try testing.expectEqualStrings(ESC ++ "1;5C8:00", parts.items);
}

test "appendChangedColsToCmdList appends nothing when the line is unchanged" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    try appendChangedColsToCmdList(testing.allocator, &parts, 1, "20:37:13", "20:37:13");
    try testing.expectEqual(@as(usize, 0), parts.items.len);
}

test "appendChangedColsToCmdList redraws the whole line when the width changes" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    // No column-for-column correspondence to diff against, so this must not
    // try to compute a span.
    try appendChangedColsToCmdList(testing.allocator, &parts, 2, "59:59", "1:00:00");
    try testing.expectEqualStrings(ESC ++ "2;1C1:00:00", parts.items);
}

test "appendChangedColsToCmdList counts a DLE pair as one column" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    // "\x10P" and "\x10Q" are one column each (the transport glyph, as line 1
    // carries at its right-hand end). The change is in the last column, column
    // 3 -- not column 4, which is where a byte count would put it, and not a
    // slice that splits the pair.
    try appendChangedColsToCmdList(testing.allocator, &parts, 1, "AB\x10P", "AB\x10Q");
    try testing.expectEqualStrings(ESC ++ "1;3C\x10Q", parts.items);
}

test "appendChangedColsToCmdList offsets correctly past an earlier DLE pair" {
    const testing = std.testing;
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(testing.allocator);

    // The DLE pair sits in column 1, so the changed 'C' is column 3 even
    // though it is byte 3 -- and the payload must not re-send the pair.
    try appendChangedColsToCmdList(testing.allocator, &parts, 1, "\x10PBC", "\x10PBD");
    try testing.expectEqualStrings(ESC ++ "1;3CD", parts.items);
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
