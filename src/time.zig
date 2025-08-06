const std = @import("std");

/// Get the local timezone offset in seconds from UTC
pub fn getTimezoneOffset() i64 {
    // Read timezone info from /etc/localtime symlink
    if (std.fs.cwd().openFile("/etc/localtime", .{})) |file| {
        defer file.close();

        // Try to parse the TZif file for accurate DST information
        if (parseTZifFile(file)) |offset| {
            return offset;
        } else {
            // Fallback to hardcoded mapping if TZif parsing fails
            std.debug.print("TZif parsing failed, using UTC\n", .{});
        }
    } else |err| {
        std.debug.print("Failed to open /etc/localtime: {}, using UTC\n", .{err});
    }

    return 0;
}

/// Parse TZif file to get current timezone offset
fn parseTZifFile(file: std.fs.File) ?i64 {
    var buf: [1024]u8 = undefined;
    const utc_timestamp = std.time.timestamp();

    // Now read and parse the TZif file to get actual DST status
    if (file.seekTo(0)) |_| {
        if (file.read(&buf)) |bytes_read| {
            // std.debug.print("Read {} bytes from timezone file\n", .{bytes_read});

            // Parse TZif file format
            if (bytes_read >= 44 and std.mem.eql(u8, buf[0..4], "TZif")) {
                // std.debug.print("Valid TZif file found\n", .{});

                // TZif header structure (simplified):
                // 0-3: "TZif" magic
                // 4: version
                // 5-19: reserved
                // 20-23: number of transition times (big-endian)
                // 24-27: number of local time types (big-endian)
                // 28-31: number of leap seconds (big-endian)
                // 32-35: number of transition times again (big-endian)
                // 36-39: number of local time types again (big-endian)
                // 40-43: number of abbreviation characters (big-endian)

                const transition_count = std.mem.readInt(u32, buf[32..][0..4], .big);
                const type_count = std.mem.readInt(u32, buf[36..][0..4], .big);
                // std.debug.print("Transitions: {}, Types: {}\n", .{ transition_count, type_count });

                if (transition_count > 0 and type_count > 0 and type_count < 256) {
                    // Transition times start at offset 44, each is 4 bytes (big-endian)
                    // Local time types start after transition times
                    const transitions_size = transition_count * 4;
                    const types_offset = 44 + transitions_size + transition_count; // +transition_count for type indices
                    const buf_offset = @max(0, types_offset + (type_count * 6) - 1024);

                    file.seekTo(buf_offset) catch |err| {
                        std.debug.print("Failed to seek to data: {}\n", .{err});
                        return null;
                    };
                    _ = file.read(&buf) catch |err| {
                        std.debug.print("Failed to read data: {}\n", .{err});
                        return null;
                    };

                    // Find the current transition - start from the last type as default
                    var current_type_idx: u8 = 0;

                    // Find the most recent transition that has passed
                    var i: u32 = transition_count - 1;
                    while (i >= 0) : (i -= 1) {
                        const transition_time = std.mem.readInt(i32, buf[44 + i * 4 - buf_offset ..][0..4], .big);
                        // std.debug.print("Transition {}: time={}, current_utc={}\n", .{ i, transition_time, utc_timestamp });
                        if (utc_timestamp >= transition_time) {
                            current_type_idx = buf[44 + transitions_size + i - buf_offset];
                            // std.debug.print("Using transition {} with type_idx {}\n", .{ i, current_type_idx });
                            break;
                        }
                    }

                    // Read the current type info (6 bytes per type)
                    // Offset (4 bytes) + DST flag (1 byte) + Abbreviation index (1 byte)
                    if (current_type_idx < type_count) {
                        const type_info_offset = types_offset + current_type_idx * 6;
                        const offset_seconds = std.mem.readInt(i32, buf[type_info_offset - buf_offset ..][0..4], .big);
                        // const is_dst = buf[type_info_offset + 4 - buf_offset] != 0;

                        // Sanity check: timezone offsets should be reasonable (-12 to +14 hours)
                        if (offset_seconds >= -12 * 3600 and offset_seconds <= 14 * 3600) {
                            // std.debug.print("Current timezone offset: {} seconds ({}h), DST: {}\n", .{ offset_seconds, @divFloor(offset_seconds, 3600), is_dst });
                            return offset_seconds;
                        } else {
                            std.debug.print("Invalid offset {} seconds, using fallback\n", .{offset_seconds});
                            return null;
                        }
                    } else {
                        std.debug.print("Invalid type_idx {}, using fallback\n", .{current_type_idx});
                        return null;
                    }
                }
            } else {
                std.debug.print("Not a valid TZif file, using fallback\n", .{});
                return null;
            }
        } else |err| {
            std.debug.print("Failed to read timezone file: {}\n", .{err});
            return null;
        }
    } else |err| {
        std.debug.print("Failed to seek timezone file: {}\n", .{err});
        return null;
    }

    return null;
}

/// Format a timestamp as "YYYY-MM-DD HH:MM:SS"
pub fn formatTimestamp(timestamp: i64, buf: []u8) ![]const u8 {
    const epoch_seconds = @as(u64, @intCast(timestamp));
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_seconds, std.time.s_per_day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds = @mod(epoch_seconds, std.time.s_per_day);
    const hours = @divFloor(day_seconds, std.time.s_per_hour);
    const minutes = @divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min);
    const secs = @mod(day_seconds, std.time.s_per_min);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1, hours, minutes, secs });
}
