const std = @import("std");
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");
const time = @import("time.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const ttydev = "/dev/ttyUSB0";

    std.debug.print("Opening {s}...\n", .{ttydev});
    const port = serial.SerialPort.open(ttydev, allocator) catch |err| return err;
    defer port.close(allocator);
    std.debug.print("Serial port opened and configured successfully.\n", .{});

    protocol.sendUnitFlushCmd(allocator, port, 1) catch |err| return err;
    // protocol.sendUnitDefaultInitCmd(allocator, port, 1) catch |err| return err;
    // protocol.sendUnitDisplayCmd(allocator, port, 1, "Test from Randy") catch |err| return err;
    // protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "25;-B" ++ protocol.ESC ++ "25;-b" ++ protocol.ESC ++ "2s" ++ protocol.ESC ++ "0;0;119;15w" ++ protocol.ESC ++ "@" ++ protocol.ESC ++ "0;0c" ++ protocol.ESC ++ "0;3H" ++ protocol.ESC ++ "2FTest from randy" ++ protocol.ESC ++ "8;60c" ++ protocol.ESC ++ "20W" ++ protocol.ESC ++ "1W" ++ protocol.ESC ++ "E" ++ protocol.ESC ++ "1G") catch |err| return err;

    // protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;
    // protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "0;0;119;15w" ++ "Test from randy 1" ++ protocol.ESC ++ "8;60c") catch |err| return err;
    // std.Thread.sleep(1 * std.time.ns_per_s);
    // protocol.unitUpdateChar(allocator, port, 1, 1, 17, '2') catch |err| return err;
    // std.Thread.sleep(1 * std.time.ns_per_s);
    // protocol.unitUpdateChar(allocator, port, 1, 1, 17, '3') catch |err| return err;

    // std.Thread.sleep(1 * std.time.ns_per_s);
    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;

    // Clock display loop
    var last_full_update: i64 = 0;
    var tz_offset = time.getTimezoneOffset();
    var time_buf: [64]u8 = undefined;
    var display_buf: [64]u8 = undefined;
    while (true) {
        // Get current local timestamp
        const utc_timestamp = std.time.timestamp();
        const timestamp = utc_timestamp + tz_offset;
        const seconds = @mod(timestamp, 60);

        // Check if we need a full update (every 10 seconds, first time, or timestamp changed)
        if (last_full_update == 0 or (@mod(seconds, 10) == 0 and utc_timestamp != last_full_update)) {
            // Format full date/time string (ISO format without T)
            const time_str_formatted = time.formatTimestamp(timestamp, &time_buf) catch unreachable;
            // std.debug.print("Full update (local): {s}\n", .{time_str_formatted});
            const time_str = std.fmt.bufPrint(&display_buf, "{s}{s}", .{ protocol.ESC ++ "C", time_str_formatted }) catch unreachable;
            protocol.sendUnitDisplayCmd(allocator, port, 1, time_str) catch |err| return err;
            tz_offset = time.getTimezoneOffset();
            last_full_update = utc_timestamp;
        } else {
            // Just update the ones place of seconds (column 19, assuming format "YYYY-MM-DD HH:MM:SS")
            const ones_digit = @as(u8, @intCast(@mod(seconds, 10))) + '0';
            protocol.unitUpdateChar(allocator, port, 1, 1, 19, ones_digit) catch |err| return err;
        }

        // Sleep until next second
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
