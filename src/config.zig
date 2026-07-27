const std = @import("std");
const dbg = @import("debug_log.zig");
const jsonc = @import("jsonc.zig");
const vorne_config = @import("vorne_config.zig");
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
const countdown_cfg_default_path = "/home/emanspeaks/line2_config.jsonc";

/// Where `line2_config.jsonc` lives.
///
/// Only its *location* is configurable from vorne_config.jsonc. The file
/// itself stays separate and keeps being re-read while running: its contents
/// are display copy meant to be edited live, unlike the wiring settings, which
/// are read once at startup.
fn countdownCfgPath() []const u8 {
    return vorne_config.line2ConfigPath() orelse countdown_cfg_default_path;
}

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
            std.log.warn("Error reading Blu-ray key file: {}, skipping\n", .{err});
            return null;
        },
    };

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != bluray_key_len) {
        std.log.warn(
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

/// The player's IP address, or null when none is configured.
///
/// `bluray_ip` in vorne_config.jsonc is the setting; `bluray_ip.txt` is still
/// honoured when that key is absent, so an existing deployment keeps polling
/// across the upgrade rather than silently losing its player. Caller owns the
/// returned buffer either way.
pub fn loadBlurayIp(io: Io, allocator: std.mem.Allocator) ?[]const u8 {
    if (vorne_config.blurayIp()) |configured| {
        return allocator.dupe(u8, configured) catch null;
    }
    return Io.Dir.readFileAlloc(.cwd(), io, bluray_ip_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            dbg.print(.config, "No bluray_ip configured (no \"bluray_ip\" in {s}, no {s})\n", .{ vorne_config.path, bluray_ip_path });
            return null;
        },
        else => {
            std.log.warn("Error reading IP file: {}, skipping\n", .{err});
            return null;
        },
    };
}

pub fn loadBlurayConfig(io: Io, allocator: std.mem.Allocator) ?BlurayConfig {
    // Try to read the JSON file
    const contents = Io.Dir.readFileAlloc(.cwd(), io, bluray_cfg_path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            dbg.print(.config, "bluray_config.jsonc not found, skipping\n", .{});
            return null;
        },
        else => {
            std.log.warn("Error reading JSON file: {}, skipping\n", .{err});
            return null;
        },
    };
    defer allocator.free(contents);

    var cleaned_contents = jsonc.strip(allocator, contents) catch |err| {
        std.log.warn("Error cleaning JSONC content: {}, skipping\n", .{err});
        return null;
    };
    defer cleaned_contents.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, cleaned_contents.items, .{}) catch |err| {
        std.log.warn("Error parsing JSONC: {}, skipping\n", .{err});
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
    std.log.warn("Invalid JSONC format, skipping\n", .{});
    return null;
}

pub fn loadCountdownConfig(io: Io, allocator: std.mem.Allocator) ?CountdownConfig {
    // Try to read the JSON file
    const contents = Io.Dir.readFileAlloc(.cwd(), io, countdownCfgPath(), allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            dbg.print(.config, "line2_config.jsonc not found, skipping\n", .{});
            return null;
        },
        else => {
            std.log.warn("Error reading JSON file: {}, skipping\n", .{err});
            return null;
        },
    };
    defer allocator.free(contents);

    var cleaned_contents = jsonc.strip(allocator, contents) catch |err| {
        std.log.warn("Error cleaning JSONC content: {}, skipping\n", .{err});
        return null;
    };
    defer cleaned_contents.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, cleaned_contents.items, .{}) catch |err| {
        std.log.warn("Error parsing JSONC: {}, skipping\n", .{err});
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
    std.log.warn("Invalid JSONC format, skipping\n", .{});
    return null;
}
