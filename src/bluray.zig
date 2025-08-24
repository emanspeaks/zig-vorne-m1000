const std = @import("std");
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const process_mgmt = @import("process_mgmt.zig");
const str_utils = @import("str_utils.zig");

// Placeholder for future Blu-ray mode implementation.
// Keeps the same signature as runClocks so it can share setup.
pub fn runBluray(allocator: std.mem.Allocator, port: anytype) !void {
    // Build the command string dynamically
    var cmd_parts = std.ArrayList(u8){};
    defer cmd_parts.deinit(allocator);

    var trt_buf: [20]u8 = undefined;
    var linebuf: [20]u8 = undefined;
    var last_full_update_utc: i64 = 0;
    var trt: u16 = 0;

    // Real-time frame timing variables
    const target_fps: f64 = 5.0; // Target frame rate
    const target_frame_duration_ns: u64 = @intFromFloat(std.time.ns_per_s / target_fps);
    const max_frame_overrun_ns: u64 = target_frame_duration_ns / 2; // Allow 50% overrun before warnings
    var frame_start_time: i128 = std.time.nanoTimestamp();
    var frame_count: u32 = 0;
    var overrun_count: u32 = 0;
    var max_overrun_ns: u64 = 0;

    // Load configuration from JSON
    var bluray_config: ?config.BlurayConfig = null;
    bluray_config = config.loadBlurayConfig(allocator);

    while (true) {
        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Blu-ray display received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        trt_buf = undefined;
        cmd_parts.clearAndFree(allocator);
        try str_utils.clearVorneLineBuf(&linebuf);

        // Get current local timestamp
        const utc_timestamp = std.time.timestamp();
        const seconds = @mod(utc_timestamp, 60);
        trt += 1;

        if (bluray_config) |cfg| {
            _ = cfg;
        }

        // Check if we need a full update (every 10 seconds, first time, or timestamp changed)
        if (last_full_update_utc == 0 or (@mod(seconds, 10) == 0 and utc_timestamp != last_full_update_utc)) {
            try protocol.appendStrToCmdList(allocator, &cmd_parts, 1, 1, "Blu-Ray mode");

            // calculate total running time
            const trt_hms = time.timedeltaToHms(trt);
            const trt_str = time.formatHms(trt_hms, &trt_buf) catch unreachable;

            if (bluray_config != null) {
                try str_utils.copyLeftJustify(&linebuf, &bluray_config.?.label, 20 - trt_str.len, null);
            }
            try str_utils.copyRightJustify(&linebuf, trt_str, @min(trt_str.len, 20), 1);
            try protocol.appendStrToCmdList(allocator, &cmd_parts, 2, 1, &linebuf);

            // last_full_update_utc = utc_timestamp;
            last_full_update_utc = 0;
        } else {
            // // Just update the ones place of seconds (column 19, assuming format "25Au06W200/20:37:13D")
            // const ones_digit = @as(u8, @intCast(@mod(seconds, 10))) + '0';
            // const ones_digit_cmd = try protocol.unitUpdateChar(&line1_buf, 1, 16, ones_digit);
            // try cmd_parts.appendSlice(ones_digit_cmd);
        }

        const cmd_slice = try cmd_parts.toOwnedSlice(allocator);
        if (cmd_slice.len > 0) {
            protocol.sendUnitDisplayCmd(allocator, port, 1, cmd_slice) catch |err| return err;
        }

        // Real-time frame deadline management
        const frame_end_time = std.time.nanoTimestamp();
        const frame_duration = frame_end_time - frame_start_time;
        const target_duration_i128: i128 = @intCast(target_frame_duration_ns);

        frame_count += 1;

        if (frame_duration < target_duration_i128) {
            // Frame finished early - sleep for remaining time
            const sleep_duration: u64 = @intCast(target_duration_i128 - frame_duration);
            std.Thread.sleep(sleep_duration);
        } else {
            // Frame overrun detected
            const overrun_ns: u64 = @intCast(frame_duration - target_duration_i128);
            overrun_count += 1;
            max_overrun_ns = @max(max_overrun_ns, overrun_ns);

            // Log severe overruns (> 50% of frame time)
            if (overrun_ns > max_frame_overrun_ns) {
                const overrun_ms: f64 = @as(f64, @floatFromInt(overrun_ns)) / 1_000_000.0;
                const target_ms: f64 = @as(f64, @floatFromInt(target_frame_duration_ns)) / 1_000_000.0;
                std.debug.print("Frame overrun: {d:.1}ms (target: {d:.1}ms) - frame {}\n", .{ overrun_ms, target_ms, frame_count });
            }

            // Skip sleep - start next frame immediately to prevent cascade delays
        }

        // Periodic timing statistics (every 100 frames)
        if (frame_count % 100 == 0 and overrun_count > 0) {
            const overrun_rate: f64 = @as(f64, @floatFromInt(overrun_count)) / @as(f64, @floatFromInt(frame_count)) * 100.0;
            const max_overrun_ms: f64 = @as(f64, @floatFromInt(max_overrun_ns)) / 1_000_000.0;
            std.debug.print("Frame stats: {}/{} overruns ({d:.1}%), max: {d:.1}ms\n", .{ overrun_count, frame_count, overrun_rate, max_overrun_ms });
        }

        // Update frame start time for next iteration
        frame_start_time = std.time.nanoTimestamp();
    }
}
