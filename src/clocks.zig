const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const process_mgmt = @import("process_mgmt.zig");
const mode_mod = @import("mode.zig");
const Mode = mode_mod.Mode;

pub fn runClocks(io: Io, allocator: std.mem.Allocator, port: anytype, mode: *std.atomic.Value(Mode)) !void {
    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8).empty;
    defer cmd_parts.deinit(allocator);

    var last_full_update_utc: i64 = 0;
    var clock = time.LocalClock.init(io);
    var line1_buf: [20]u8 = undefined;
    var line2_buf: [20]u8 = undefined;
    var msg1_buf: [128]u8 = undefined;
    var msg2_buf: [128]u8 = undefined;
    var line2_config: ?config.CountdownConfig = null;

    last_full_update_utc = 0; // force full update on first run

    // Line 1 is only ever fully redrawn on the first pass and then again on a
    // 10-second boundary -- every pass in between sends just the seconds
    // digit. That is fine once the panel and this loop agree on what line 1
    // says, but a dropped frame is exactly how they stop agreeing. `protocol.send`
    // waits for the panel's reply before returning, which is a much stronger
    // guarantee than a fixed delay -- but it is still evidence of "the panel
    // answered something", not proof the frame it just received rendered
    // correctly. If the very first full frame is lost anyway, line 1 stayed
    // blank for up to 10 seconds, since nothing else was due to trigger a full
    // resend. Repeating the full draw for a few seconds right after entry,
    // instead of just once, means a single dropped frame self-heals on the
    // very next pass -- half a second later -- rather than on the next
    // 10-second boundary. Cheap insurance behind a real mechanism, not a
    // substitute for one.
    const entry_full_redraw_s: i64 = 3;
    var entry_utc_timestamp: ?i64 = null;
    while (true) {
        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Clock display received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        // Check for mode change
        if (mode.load(.acquire) != .Clocks) {
            std.debug.print("Mode changed, exiting clocks mode...\n", .{});
            return;
        }

        // A re-init was requested from the web page. Stop, and let
        // the dispatch loop in `main` service it: it owns the serial
        // port on this thread, and re-entering this function repaints
        // from scratch because the "what is on the panel" records
        // start empty. Checked without consuming -- `main` clears it.
        if (mode_mod.reinitPending()) {
            std.debug.print("Re-init requested, exiting clocks mode...\n", .{});
            return;
        }

        line1_buf = undefined;
        line2_buf = undefined;
        msg1_buf = undefined;
        msg2_buf = undefined;
        cmd_parts.clearAndFree(allocator);

        // Get current local timestamp
        const now = clock.read(io);
        const utc_timestamp = now.utc;
        const timestamp = now.local;
        const seconds = @mod(timestamp, 60);

        if (entry_utc_timestamp == null) entry_utc_timestamp = utc_timestamp;
        const in_entry_window = utc_timestamp - entry_utc_timestamp.? < entry_full_redraw_s;

        // Check if we need a full update (every 10 seconds, first time, still
        // within the just-entered-this-mode window, or timestamp changed)
        if (last_full_update_utc == 0 or in_entry_window or (@mod(seconds, 10) == 0 and utc_timestamp != last_full_update_utc)) {
            const display_str = time.formatRandyTimestamp(timestamp, &line1_buf, &clock.zi) catch unreachable;
            const time_cmd_str = std.fmt.bufPrint(&msg1_buf, "{s}{s}", .{ protocol.ESC ++ "C", display_str }) catch unreachable;
            try cmd_parts.appendSlice(allocator, time_cmd_str);
            last_full_update_utc = utc_timestamp;

            // Load countdown configuration from JSON
            line2_config = config.loadCountdownConfig(io, allocator);
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
        try io.sleep(.fromMilliseconds(500), .awake);
    }
}
