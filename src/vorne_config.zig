//! The one configuration file: `/home/emanspeaks/vorne_config.jsonc`.
//!
//! Settings that used to live in a scatter of single-line text files
//! (`bluray_cues_dir.txt`, `bluray_ip.txt`) are keys in here instead. One file
//! is easier to find, easier to comment, and -- since a missing or misspelled
//! setting is reported once, in one place -- much easier to get wrong loudly
//! rather than quietly.
//!
//! **Read exactly once, at startup, and never watched.** This is deliberate
//! and differs from `line2_config.jsonc`, which *is* re-read while running.
//! The difference is what the settings do: a countdown label is display
//! content, meant to be edited during a run, whereas everything here selects
//! what the process wires up (a serial device, a poll target, a directory to
//! scan). Re-reading those mid-run would mean tearing down and rebuilding
//! live state to no real benefit, so they are read while still
//! single-threaded, stored in fixed buffers, and thereafter immutable -- which
//! is also why nothing here needs synchronization.
//!
//! Every setting is optional. Absent means "use the built-in default", and for
//! the two migrated from text files it means "fall back to the old file", so
//! an existing deployment keeps working until it is migrated.

const std = @import("std");
const Io = std.Io;
const jsonc = @import("jsonc.zig");
const dbg = @import("debug_log.zig");

pub const path = "/home/emanspeaks/vorne_config.jsonc";

const max_config_bytes: Io.Limit = .limited(1 << 20);

/// Generous: these are filesystem paths and an IP address.
const max_value_len = 512;

const Setting = struct {
    buf: [max_value_len]u8 = undefined,
    len: usize = 0,

    fn get(self: *const Setting) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    /// Store a trimmed copy. Over-long values are rejected rather than
    /// truncated: a silently shortened path would fail later as a confusing
    /// "not found" against a path nobody wrote.
    fn set(self: *Setting, key: []const u8, raw: []const u8) void {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed.len > max_value_len) {
            std.debug.print(
                "Config \"{s}\" is longer than {d} characters, ignoring\n",
                .{ key, max_value_len },
            );
            return;
        }
        @memcpy(self.buf[0..trimmed.len], trimmed);
        self.len = trimmed.len;
    }
};

var cues_dir_setting: Setting = .{};
var bluray_ip_setting: Setting = .{};
var line2_config_setting: Setting = .{};

/// Directory scanned for `*.vtt` cue files. Null to use the built-in default.
pub fn cuesDir() ?[]const u8 {
    return cues_dir_setting.get();
}

/// IP address of the Panasonic player. Null to fall back to `bluray_ip.txt`.
pub fn blurayIp() ?[]const u8 {
    return bluray_ip_setting.get();
}

/// Path to `line2_config.jsonc`. Null to use the built-in default.
///
/// Only the *location* is configured here. That file stays separate and stays
/// watched, because its contents are display copy meant to be edited live.
pub fn line2ConfigPath() ?[]const u8 {
    return line2_config_setting.get();
}

/// Read and apply the file. Call once from `main`, before starting any thread.
///
/// A missing or malformed file is reported and then ignored: every setting has
/// a working default, so bad configuration must degrade to default behaviour
/// rather than stop the display from running.
pub fn load(io: Io, allocator: std.mem.Allocator) void {
    // Do this first and unconditionally, so that diagnostics emitted while
    // parsing this very file can still be timestamped.
    dbg.setClockIo(io);

    const contents = Io.Dir.readFileAlloc(.cwd(), io, path, allocator, max_config_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No {s}; using defaults, debug logging off\n", .{path});
            return;
        },
        else => {
            std.debug.print("Error reading {s}: {}; using defaults\n", .{ path, err });
            return;
        },
    };
    defer allocator.free(contents);

    var cleaned = jsonc.strip(allocator, contents) catch |err| {
        std.debug.print("Error cleaning {s}: {}; using defaults\n", .{ path, err });
        return;
    };
    defer cleaned.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, cleaned.items, .{}) catch |err| {
        std.debug.print("Error parsing {s}: {}; using defaults\n", .{ path, err });
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("{s} is not a JSON object; using defaults\n", .{path});
        return;
    }
    const root = parsed.value.object;

    applyString(root, "cues_dir", &cues_dir_setting);
    applyString(root, "bluray_ip", &bluray_ip_setting);
    applyString(root, "line2_config", &line2_config_setting);

    if (root.get("debug")) |debug_value| {
        if (debug_value == .object) {
            dbg.setMask(dbg.maskFrom(debug_value.object));
        } else {
            std.debug.print("\"debug\" in {s} is not an object; debug logging off\n", .{path});
        }
    } else {
        std.debug.print("No \"debug\" object in {s}; debug logging off\n", .{path});
    }
    dbg.reportEnabled();

    reportPaths();
}

fn applyString(root: std.json.ObjectMap, key: []const u8, setting: *Setting) void {
    const value = root.get(key) orelse return;
    if (value != .string) {
        std.debug.print("Config \"{s}\" must be a string, ignoring\n", .{key});
        return;
    }
    setting.set(key, value.string);
}

fn reportPaths() void {
    // Unconditional, and worth it: a wrong directory here produces an empty
    // dropdown and a fallback line 2, which looks exactly like a bug. Saying
    // what was actually read costs three lines at startup and removes the
    // single most common false alarm.
    if (cuesDir()) |v| std.debug.print("Config: cues_dir = {s}\n", .{v});
    if (blurayIp()) |v| std.debug.print("Config: bluray_ip = {s}\n", .{v});
    if (line2ConfigPath()) |v| std.debug.print("Config: line2_config = {s}\n", .{v});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a setting stores a trimmed value and reports null when unset" {
    var s: Setting = .{};
    try testing.expectEqual(@as(?[]const u8, null), s.get());
    s.set("k", "  /home/x/cues \n");
    try testing.expectEqualStrings("/home/x/cues", s.get().?);
}

test "an over-long setting is rejected rather than truncated" {
    // Truncation would produce a path nobody wrote, failing later as a
    // baffling "not found"; refusing it keeps the default, which at least
    // behaves predictably.
    var s: Setting = .{};
    const too_long = "/" ++ ("x" ** max_value_len);
    s.set("k", too_long);
    try testing.expectEqual(@as(?[]const u8, null), s.get());
}

test "an all-whitespace setting is treated as unset" {
    var s: Setting = .{};
    s.set("k", "   \n\t ");
    try testing.expectEqual(@as(?[]const u8, null), s.get());
}

test "applyString takes strings and refuses other JSON types" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{ "cues_dir": "/srv/cues", "bluray_ip": 42 }
    ,
        .{},
    );
    defer parsed.deinit();

    var dir: Setting = .{};
    var ip: Setting = .{};
    applyString(parsed.value.object, "cues_dir", &dir);
    applyString(parsed.value.object, "bluray_ip", &ip);
    applyString(parsed.value.object, "line2_config", &ip);

    try testing.expectEqualStrings("/srv/cues", dir.get().?);
    // A number is not a path; the setting stays unset so the default applies.
    try testing.expectEqual(@as(?[]const u8, null), ip.get());
}
