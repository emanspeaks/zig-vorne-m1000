const std = @import("std");
const Io = std.Io;
const time = @import("time.zig");
const str_utils = @import("str_utils.zig");

/// Upper bound for the config/IP files read below.
const max_config_bytes: Io.Limit = .limited(1 << 20);

const maxbufsz = str_utils.maxbufsz;

pub const CountdownConfig = struct {
    label: [maxbufsz]u8,
    target_date: time.Ymdhms,
};

pub const BlurayConfig = struct {
    label: [maxbufsz]u8,
    target_date: time.Ymdhms,
};

const bluray_cfg_path = "/home/emanspeaks/bluray_config.jsonc";
const bluray_ip_path = "/home/emanspeaks/bluray_ip.txt";
const bluray_key_path = "/home/emanspeaks/bluray_key.txt";
const countdown_cfg_path = "/home/emanspeaks/line2_config.jsonc";

/// Length of the Panasonic control-API secret key.
pub const bluray_key_len = 32;

/// Load the 32-character secret key used to authenticate control commands.
///
/// Optional: status polling (`cCMD_PST`) does not need it, so its absence is
/// not an error — only control commands and `cCMD_REVIEW` are unavailable
/// without it. Caller owns the returned buffer.
pub fn loadBlurayKey(io: Io, allocator: std.mem.Allocator) ?[]const u8 {
    const raw = Io.Dir.readFileAlloc(.cwd(), io, bluray_key_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => return null, // Expected when running unauthenticated
        else => {
            std.debug.print("Error reading Blu-ray key file: {}, skipping\n", .{err});
            return null;
        },
    };

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != bluray_key_len) {
        std.debug.print(
            "Blu-ray key must be {d} characters, got {d}; ignoring\n",
            .{ bluray_key_len, trimmed.len },
        );
        allocator.free(raw);
        return null;
    }

    // Re-own the trimmed span so the caller can free exactly what it holds.
    const key = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return key;
}

pub fn loadBlurayIp(io: Io, allocator: std.mem.Allocator) ?[]const u8 {
    // Try to read the IP address from the text file
    // Caller owns the returned buffer.
    return Io.Dir.readFileAlloc(.cwd(), io, bluray_ip_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("bluray_ip.txt not found, skipping\n", .{});
            return null;
        },
        else => {
            std.debug.print("Error reading IP file: {}, skipping\n", .{err});
            return null;
        },
    };
}

pub fn loadBlurayConfig(io: Io, allocator: std.mem.Allocator) ?BlurayConfig {
    // Try to read the JSON file
    const contents = Io.Dir.readFileAlloc(.cwd(), io, bluray_cfg_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("bluray_config.jsonc not found, skipping\n", .{});
            return null;
        },
        else => {
            std.debug.print("Error reading JSON file: {}, skipping\n", .{err});
            return null;
        },
    };
    defer allocator.free(contents);

    // Preprocess JSONC content to remove comments first, then trailing commas
    var comment_free = std.ArrayList(u8).empty;
    defer comment_free.deinit(allocator);

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

        comment_free.append(allocator, char) catch |err| {
            std.debug.print("Error cleaning JSONC content: {}, skipping\n", .{err});
            return null;
        };
        i += 1;
    }

    // Second pass: remove trailing commas
    var cleaned_contents = std.ArrayList(u8).empty;
    defer cleaned_contents.deinit(allocator);

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

        cleaned_contents.append(allocator, char) catch |err| {
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
            _ = label;
            // const date_array = entry.value_ptr.*.array;

            // if (date_array.items.len >= 6) {
            //     const year = @as(u16, @intCast(date_array.items[0].integer));
            //     const month = @as(u8, @intCast(date_array.items[1].integer));
            //     const day = @as(u8, @intCast(date_array.items[2].integer));
            //     const hour = @as(u8, @intCast(date_array.items[3].integer));
            //     const minute = @as(u8, @intCast(date_array.items[4].integer));
            //     const second = @as(u8, @intCast(date_array.items[5].integer));

            //     // Create a label buffer and copy the string
            //     var label_buf: [maxbufsz]u8 = [_]u8{0} ** maxbufsz;
            //     const copy_len = @min(label.len, maxbufsz);
            //     @memcpy(label_buf[0..copy_len], label[0..copy_len]);

            //     // std.debug.print("Loaded countdown: {s} -> {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{ label_buf[0..copy_len], year, month, day, hour, minute, second });

            //     return CountdownConfig{
            //         .label = label_buf,
            //         .target_date = time.Ymdhms{
            //             .year = year,
            //             .month = month,
            //             .day = day,
            //             .hour = hour,
            //             .minute = minute,
            //             .second = second,
            //         },
            //     };
            // }
        }
    }

    // Fallback if JSONC is malformed
    std.debug.print("Invalid JSONC format, skipping\n", .{});
    return null;
}

pub fn loadCountdownConfig(io: Io, allocator: std.mem.Allocator) ?CountdownConfig {
    // Try to read the JSON file
    const contents = Io.Dir.readFileAlloc(.cwd(), io, countdown_cfg_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("line2_config.jsonc not found, skipping\n", .{});
            return null;
        },
        else => {
            std.debug.print("Error reading JSON file: {}, skipping\n", .{err});
            return null;
        },
    };
    defer allocator.free(contents);

    // Preprocess JSONC content to remove comments first, then trailing commas
    var comment_free = std.ArrayList(u8).empty;
    defer comment_free.deinit(allocator);

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

        comment_free.append(allocator, char) catch |err| {
            std.debug.print("Error cleaning JSONC content: {}, skipping\n", .{err});
            return null;
        };
        i += 1;
    }

    // Second pass: remove trailing commas
    var cleaned_contents = std.ArrayList(u8).empty;
    defer cleaned_contents.deinit(allocator);

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

        cleaned_contents.append(allocator, char) catch |err| {
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
                var label_buf: [maxbufsz]u8 = [_]u8{0} ** maxbufsz;
                const copy_len = @min(label.len, maxbufsz);
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
