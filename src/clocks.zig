const std = @import("std");
const protocol = @import("protocol.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const process_mgmt = @import("process_mgmt.zig");

pub fn runClocks(allocator: std.mem.Allocator, port: anytype) !void {
    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8){};
    defer cmd_parts.deinit(allocator);

    var last_full_update_utc: i64 = 0;
    var zi = time.getTimezoneInfo();
    var line1_buf: [20]u8 = undefined;
    var line2_buf: [20]u8 = undefined;
    var msg1_buf: [128]u8 = undefined;
    var msg2_buf: [128]u8 = undefined;
    var line2_config: ?config.CountdownConfig = null;
    while (true) {
        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Clock display received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        line1_buf = undefined;
        line2_buf = undefined;
        msg1_buf = undefined;
        msg2_buf = undefined;
        cmd_parts.clearAndFree(allocator);

        // Get current local timestamp
        const utc_timestamp = std.time.timestamp();
        const timestamp = utc_timestamp + zi.offset_sec;
        const seconds = @mod(timestamp, 60);

        // Check if we need a full update (every 10 seconds, first time, or timestamp changed)
        if (last_full_update_utc == 0 or (@mod(seconds, 10) == 0 and utc_timestamp != last_full_update_utc)) {
            const display_str = time.formatRandyTimestamp(timestamp, &line1_buf, &zi) catch unreachable;
            const time_cmd_str = std.fmt.bufPrint(&msg1_buf, "{s}{s}", .{ protocol.ESC ++ "C", display_str }) catch unreachable;
            try cmd_parts.appendSlice(allocator, time_cmd_str);
            zi = time.getTimezoneInfo();
            last_full_update_utc = utc_timestamp;

            // Load countdown configuration from JSON
            line2_config = config.loadCountdownConfig(allocator);
        } else {
            // Just update the ones place of seconds (column 19, assuming format "25Au06W200/20:37:13D")
            const ones_digit = @as(u8, @intCast(@mod(seconds, 10))) + '0';
            const ones_digit_cmd = try protocol.unitUpdateChar(&line1_buf, 1, 16, ones_digit);
            try cmd_parts.appendSlice(allocator, ones_digit_cmd);
        }

        // Create a 20-character line with left-justified label and right-justified dhms_str
        // If they overlap, dhms_str takes precedence
        var line2_display: [20]u8 = [_]u8{' '} ** 20; // Fill with spaces

        if (line2_config) |cfg| {
            // line 2: always full draw
            const delta_sec = utc_timestamp - time.ymdhmsToTimestamp(cfg.target_date);
            const dhms = time.timedeltaToDhms(delta_sec);
            const dhms_str = time.formatDhms(dhms, &line2_buf) catch unreachable;

            // Find the actual length of the label (stop at first null byte)
            const label_len = std.mem.indexOfScalar(u8, &cfg.label, 0) orelse cfg.label.len;

            // Calculate how much space we have for the label
            const max_label_len = if (dhms_str.len >= 20) 0 else 20 - dhms_str.len;
            const actual_label_len = @min(label_len, max_label_len);

            // Copy label to the left side
            if (actual_label_len > 0) {
                @memcpy(line2_display[0..actual_label_len], cfg.label[0..actual_label_len]);
            }

            // Copy dhms_str to the right side
            const dhms_start_pos = if (dhms_str.len >= 20) 0 else 20 - dhms_str.len;
            const dhms_copy_len = @min(dhms_str.len, 20);
            @memcpy(line2_display[dhms_start_pos .. dhms_start_pos + dhms_copy_len], dhms_str[0..dhms_copy_len]);
        }

        const msg2_str = try std.fmt.bufPrint(&msg2_buf, "{s}{s}", .{ protocol.ESC ++ "2;C", line2_display });
        try cmd_parts.appendSlice(allocator, msg2_str);

        const cmd_slice = try cmd_parts.toOwnedSlice(allocator);
        protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_slice) catch |err| return err;

        // Sleep until next second
        std.Thread.sleep(0.5 * std.time.ns_per_s);
    }
}
