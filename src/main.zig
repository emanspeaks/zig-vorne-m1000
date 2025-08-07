const std = @import("std");
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");
const time = @import("time.zig");
const countdown_config = @import("config.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const ttydev = "/dev/ttyUSB0";

    std.debug.print("Opening {s}...\n", .{ttydev});
    const port = serial.SerialPort.open(ttydev, allocator) catch |err| return err;
    defer port.close(allocator);
    std.debug.print("Serial port opened and configured successfully.\n", .{});

    protocol.sendUnitFlushCmd(allocator, port, 1) catch |err| return err;
    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Clock display loop

    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8).init(allocator);
    defer cmd_parts.deinit();

    var last_full_update_utc: i64 = 0;
    var zi = time.getTimezoneInfo();
    var line1_buf: [20]u8 = undefined;
    var line2_buf: [20]u8 = undefined;
    var msg1_buf: [128]u8 = undefined;
    var msg2_buf: [128]u8 = undefined;
    var line2_config: ?countdown_config.CountdownConfig = null;
    while (true) {
        line1_buf = undefined;
        line2_buf = undefined;
        msg1_buf = undefined;
        msg2_buf = undefined;
        cmd_parts.clearAndFree();

        // Get current local timestamp
        const utc_timestamp = std.time.timestamp();
        const timestamp = utc_timestamp + zi.offset_sec;
        const seconds = @mod(timestamp, 60);

        // Check if we need a full update (every 10 seconds, first time, or timestamp changed)
        if (last_full_update_utc == 0 or (@mod(seconds, 10) == 0 and utc_timestamp != last_full_update_utc)) {
            const display_str = time.formatRandyTimestamp(timestamp, &line1_buf, &zi) catch unreachable;
            const time_cmd_str = std.fmt.bufPrint(&msg1_buf, "{s}{s}", .{ protocol.ESC ++ "C", display_str }) catch unreachable;
            try cmd_parts.appendSlice(time_cmd_str);
            // protocol.sendUnitDisplayCmd(allocator, port, 1, time_str) catch |err| return err;
            zi = time.getTimezoneInfo();
            last_full_update_utc = utc_timestamp;

            // Load countdown configuration from JSON
            line2_config = countdown_config.loadCountdownConfig(allocator);
        } else {
            // Just update the ones place of seconds (column 19, assuming format "25Au06W200/20:37:13D")
            const ones_digit = @as(u8, @intCast(@mod(seconds, 10))) + '0';
            // protocol.sendUnitUpdateChar(allocator, port, 1, 1, 19, ones_digit) catch |err| return err;
            const ones_digit_cmd = try protocol.unitUpdateChar(&line1_buf, 1, 16, ones_digit);
            try cmd_parts.appendSlice(ones_digit_cmd);
        }

        // Create a 20-character line with left-justified label and right-justified dhms_str
        // If they overlap, dhms_str takes precedence
        var line2_display: [20]u8 = [_]u8{' '} ** 20; // Fill with spaces

        if (line2_config) |config| {
            // line 2: always full draw
            const delta_sec = utc_timestamp - time.ymdhmsToTimestamp(config.target_date);
            // std.debug.print("Delta seconds: {}\n", .{delta_sec});
            const dhms = time.timedeltaToDhms(delta_sec);
            const dhms_str = time.formatDhms(dhms, &line2_buf) catch unreachable;

            // Find the actual length of the label (stop at first null byte)
            const label_len = std.mem.indexOfScalar(u8, &config.label, 0) orelse config.label.len;

            // Calculate how much space we have for the label
            const max_label_len = if (dhms_str.len >= 20) 0 else 20 - dhms_str.len;
            const actual_label_len = @min(label_len, max_label_len);

            // Copy label to the left side
            if (actual_label_len > 0) {
                @memcpy(line2_display[0..actual_label_len], config.label[0..actual_label_len]);
            }

            // Copy dhms_str to the right side
            const dhms_start_pos = if (dhms_str.len >= 20) 0 else 20 - dhms_str.len;
            const dhms_copy_len = @min(dhms_str.len, 20);
            @memcpy(line2_display[dhms_start_pos .. dhms_start_pos + dhms_copy_len], dhms_str[0..dhms_copy_len]);
        }

        const msg2_str = try std.fmt.bufPrint(&msg2_buf, "{s}{s}", .{ protocol.ESC ++ "2;C", line2_display });
        try cmd_parts.appendSlice(msg2_str);

        const cmd_slice = try cmd_parts.toOwnedSlice();
        protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_slice) catch |err| return err;

        // Sleep until next second
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
