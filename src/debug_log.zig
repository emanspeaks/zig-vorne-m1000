//! Category-gated debug output, configured from `/home/emanspeaks/vorne_config.jsonc`.
//!
//! This program's diagnostics are its main debugging tool -- there is no
//! debugger attached to a Pi driving a VFD panel in a rack -- but they are also
//! voluminous and mutually drowning: the per-poll PLL lines alone are one or
//! two a second, which buries a once-a-minute cue transition completely. So
//! every diagnostic belongs to a `Category` that can be switched on or off
//! independently, and chasing a problem starts by turning on the one area
//! involved and leaving the rest quiet.
//!
//! **Absent configuration means silence.** A missing file, a missing `debug`
//! object, or a category not listed all leave that category off. Only genuine
//! operational logging -- startup and shutdown, errors, rejected input --
//! prints unconditionally, via plain `std.debug.print`; those are the lines
//! that must survive whatever the config says, so they deliberately do not go
//! through here at all.
//!
//! Read once at startup, before any thread that logs exists, so the mask is
//! effectively immutable in practice. It is still an atomic, both because
//! `main`'s HTTP handler thread could reasonably reload it later and because
//! the cost of an atomic load on a path that is usually about to do serial I/O
//! is not worth reasoning about.

const std = @import("std");
const Io = std.Io;
const jsonc = @import("jsonc.zig");

/// Production location. The repository holds an example copy at its root.
pub const config_path = "/home/emanspeaks/vorne_config.jsonc";

const max_config_bytes: Io.Limit = .limited(1 << 20);

/// A switchable area of diagnostic output.
///
/// The name here is exactly the key used in the config file's `debug` object,
/// via `@tagName`, so adding a category needs no parallel table -- and cannot
/// drift out of step with one.
pub const Category = enum {
    /// Phase-lock estimation and per-poll timing: `pll:` and `phase_lock:`.
    /// The highest-volume category by far, one or two lines per second.
    pll,
    /// Serial frames: what was written to the panel and whether it succeeded.
    serial,
    /// Cue file lifecycle -- selection, loading, parsing, which cue is due.
    cues,
    /// Render-loop decisions: why line 2 holds what it holds, missed deadlines.
    display,
    /// Blu-ray player status polling and the display-lead setting.
    bluray,
    /// VLC multicast receiver.
    vlc,
    /// Config file loading.
    config,
    /// PID file and signal handling.
    process,
    /// `/etc/localtime` parsing and offset selection.
    timezone,
};

comptime {
    // The mask below is a u32.
    std.debug.assert(@typeInfo(Category).@"enum".fields.len <= 32);
}

var enabled_mask: std.atomic.Value(u32) = .init(0);

fn bit(cat: Category) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(cat));
}

/// Whether `cat` is switched on.
///
/// Worth calling directly when producing the message costs something -- an
/// allocation, a decode, a formatting pass -- since `print` only skips the
/// *writing*, and its arguments have already been evaluated by then.
pub fn enabled(cat: Category) bool {
    return enabled_mask.load(.acquire) & bit(cat) != 0;
}

/// Print, if `cat` is switched on. Same formatting as `std.debug.print`,
/// prefixed with a timestamp and the category.
///
/// The timestamp is what makes these lines usable for the thing they exist
/// for: nearly every question asked of this log is about *when* relative to
/// something else -- did the cue text go out before or after the panel should
/// have shown it, how long did the lock take to converge, did that late frame
/// coincide with a poll. Without one, a copied-out excerpt loses all of that.
///
/// Wall-clock local time is deliberately not used: it needs the timezone
/// offset, which lives behind `time.SharedZone` and would make this depend on
/// the display's threading. Milliseconds since process start are both cheaper
/// and more useful here, since every interesting interval is a difference
/// between two of these lines rather than an absolute moment.
pub fn print(comptime cat: Category, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(cat)) return;
    printStamp(cat);
    std.debug.print(fmt, args);
}

/// The `Io` used to read the clock, captured by `configure`.
///
/// In 0.16 `std.time` carries only constants -- every clock read goes through
/// an `Io` -- but threading one into `print` would mean touching all ~50 call
/// sites and giving every module that logs an `Io` it otherwise has no use
/// for. It is written once at startup, before any thread that logs exists.
var clock_io: ?Io = null;

fn printStamp(cat: Category) void {
    const io = clock_io orelse {
        // Before `configure` ran, so there is no clock to read. Still label
        // the line, rather than dropping the prefix and producing a log whose
        // columns do not line up.
        std.debug.print("[--:--:--.--- {s}] ", .{@tagName(cat)});
        return;
    };
    const ms: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const total_s = @divFloor(ms, std.time.ms_per_s);
    // UTC, deliberately. Local time needs the offset held behind
    // `time.SharedZone`, which would make this depend on the display's
    // threading and on `time.zig` -- which imports this module.
    std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}] ", .{
        @mod(@divFloor(total_s, 3600), 24),
        @mod(@divFloor(total_s, 60), 60),
        @mod(total_s, 60),
        @mod(ms, std.time.ms_per_s),
        @tagName(cat),
    });
}

/// Provide the clock used to timestamp lines. Called by `vorne_config.load`.
pub fn setClockIo(io: Io) void {
    clock_io = io;
}

/// Build the mask from a parsed `debug` object.
///
/// Split out from `configure` so the mapping itself -- which is the part with
/// rules worth pinning down -- is testable without a filesystem.
pub fn maskFrom(obj: std.json.ObjectMap) u32 {
    var mask: u32 = 0;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cat = std.meta.stringToEnum(Category, key) orelse {
            // Worth saying out loud: a typo here is otherwise indistinguishable
            // from the category simply having nothing to report.
            std.debug.print("Unknown debug category \"{s}\" in {s}, ignoring\n", .{ key, config_path });
            continue;
        };
        // Anything that is not `true` leaves it off, including a non-boolean.
        if (entry.value_ptr.* == .bool and entry.value_ptr.*.bool) {
            mask |= bit(cat);
        }
    }
    return mask;
}

pub fn reportEnabled() void {
    const mask = enabled_mask.load(.acquire);
    if (mask == 0) {
        std.debug.print("Debug logging: all categories off\n", .{});
        return;
    }
    std.debug.print("Debug logging on for:", .{});
    for (std.enums.values(Category)) |cat| {
        if (mask & bit(cat) != 0) std.debug.print(" {s}", .{@tagName(cat)});
    }
    std.debug.print("\n", .{});
}

/// Set the mask directly. For tests and for any future live reload.
pub fn setMask(mask: u32) void {
    enabled_mask.store(mask, .release);
}

pub fn currentMask() u32 {
    return enabled_mask.load(.acquire);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn maskOfJson(src: []const u8) !u32 {
    var cleaned = try jsonc.strip(testing.allocator, src);
    defer cleaned.deinit(testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cleaned.items, .{});
    defer parsed.deinit();
    return maskFrom(parsed.value.object.get("debug").?.object);
}

test "only categories listed as true are enabled" {
    const mask = try maskOfJson(
        \\{ "debug": { "pll": true, "serial": false } }
    );
    try testing.expect(mask & bit(.pll) != 0);
    try testing.expect(mask & bit(.serial) == 0);
    // Everything not mentioned stays off -- the documented default.
    try testing.expect(mask & bit(.cues) == 0);
    try testing.expect(mask & bit(.display) == 0);
}

test "an empty debug object enables nothing" {
    try testing.expectEqual(@as(u32, 0), try maskOfJson(
        \\{ "debug": {} }
    ));
}

test "every category can be switched on by its own name" {
    // Guards the `@tagName`/`stringToEnum` round trip: the config keys are the
    // enum names, so a renamed category silently stops matching its old key.
    inline for (std.enums.values(Category)) |cat| {
        const src = "{ \"debug\": { \"" ++ @tagName(cat) ++ "\": true } }";
        try testing.expectEqual(bit(cat), try maskOfJson(src));
    }
}

test "unknown and non-boolean entries are ignored, not fatal" {
    const mask = try maskOfJson(
        \\{ "debug": { "nonsense": true, "pll": "yes", "cues": true } }
    );
    // "nonsense" is not a category, "yes" is not a boolean; neither stops
    // `cues` from being applied.
    try testing.expectEqual(bit(.cues), mask);
}

test "comments and trailing commas in the real file shape are accepted" {
    const mask = try maskOfJson(
        \\{
        \\  // things to watch
        \\  "debug": {
        \\    "pll": false,     // very noisy
        \\    "serial": true,
        \\  },
        \\}
    );
    try testing.expectEqual(bit(.serial), mask);
}
