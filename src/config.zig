const std = @import("std");
const time = @import("time.zig");

pub const CountdownConfig = struct {
    label: [20]u8,
    target_date: time.Ymdhms,
};

pub fn loadCountdownConfig(allocator: std.mem.Allocator) ?CountdownConfig {
    // Try to read the JSON file
    const file = std.fs.openFileAbsolute("/home/emanspeaks/line2_config.jsonc", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("line2_config.jsonc not found, skipping\n", .{});
            return null;
        },
        else => {
            std.debug.print("Error opening JSON file: {}, skipping\n", .{err});
            return null;
        },
    };
    defer file.close();

    const file_size = file.getEndPos() catch |err| {
        std.debug.print("Error getting file size: {}, skipping\n", .{err});
        return null;
    };
    const contents = allocator.alloc(u8, @intCast(file_size)) catch |err| {
        std.debug.print("Error allocating memory: {}, skipping\n", .{err});
        return null;
    };
    defer allocator.free(contents);
    _ = file.readAll(contents) catch |err| {
        std.debug.print("Error reading file: {}, skipping\n", .{err});
        return null;
    };

    // Preprocess JSONC content to remove comments first, then trailing commas
    var comment_free = std.ArrayList(u8).init(allocator);
    defer comment_free.deinit();

    // First pass: remove comments
    var i: usize = 0;
    while (i < contents.len) {
        const char = contents[i];

        // Handle comments
        if (char == '/') {
            if (i + 1 < contents.len) {
                if (contents[i + 1] == '/') {
                    // Line comment - skip until end of line
                    i += 2;
                    while (i < contents.len and contents[i] != '\n' and contents[i] != '\r') {
                        i += 1;
                    }
                    continue;
                } else if (contents[i + 1] == '*') {
                    // Block comment - skip until */
                    i += 2;
                    while (i + 1 < contents.len) {
                        if (contents[i] == '*' and contents[i + 1] == '/') {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                    continue;
                }
            }
        }

        comment_free.append(char) catch |err| {
            std.debug.print("Error cleaning JSONC content: {}, skipping\n", .{err});
            return null;
        };
        i += 1;
    }

    // Second pass: remove trailing commas
    var cleaned_contents = std.ArrayList(u8).init(allocator);
    defer cleaned_contents.deinit();

    i = 0;
    while (i < comment_free.items.len) {
        const char = comment_free.items[i];

        // Handle trailing commas
        if (char == ',') {
            // Look ahead to see if this is a trailing comma
            var j = i + 1;

            // Skip whitespace
            while (j < comment_free.items.len and (comment_free.items[j] == ' ' or comment_free.items[j] == '\t' or comment_free.items[j] == '\n' or comment_free.items[j] == '\r')) {
                j += 1;
            }

            // If we find a closing brace or bracket, it's a trailing comma
            if (j < comment_free.items.len and (comment_free.items[j] == '}' or comment_free.items[j] == ']')) {
                // Skip the trailing comma
                i += 1;
                continue;
            }
        }

        cleaned_contents.append(char) catch |err| {
            std.debug.print("Error cleaning JSONC content: {}, skipping\n", .{err});
            return null;
        };
        i += 1;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, cleaned_contents.items, .{}) catch |err| {
        std.debug.print("Error parsing JSONC: {}, skipping\n", .{err});
        return null;
    };
    defer parsed.deinit();

    // Use the first key-value pair found
    if (parsed.value.object.count() > 0) {
        var iterator = parsed.value.object.iterator();
        if (iterator.next()) |entry| {
            const label = entry.key_ptr.*;
            const date_array = entry.value_ptr.*.array;

            if (date_array.items.len >= 6) {
                const year = @as(u16, @intCast(date_array.items[0].integer));
                const month = @as(u8, @intCast(date_array.items[1].integer));
                const day = @as(u8, @intCast(date_array.items[2].integer));
                const hour = @as(u8, @intCast(date_array.items[3].integer));
                const minute = @as(u8, @intCast(date_array.items[4].integer));
                const second = @as(u8, @intCast(date_array.items[5].integer));

                // Create a label buffer and copy the string
                var label_buf: [20]u8 = [_]u8{0} ** 20;
                const copy_len = @min(label.len, 20);
                @memcpy(label_buf[0..copy_len], label[0..copy_len]);

                // std.debug.print("Loaded countdown: {s} -> {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{ label_buf[0..copy_len], year, month, day, hour, minute, second });

                return CountdownConfig{
                    .label = label_buf,
                    .target_date = time.Ymdhms{
                        .year = year,
                        .month = month,
                        .day = day,
                        .hour = hour,
                        .minute = minute,
                        .second = second,
                    },
                };
            }
        }
    }

    // Fallback if JSONC is malformed
    std.debug.print("Invalid JSONC format, skipping\n", .{});
    return null;
}
