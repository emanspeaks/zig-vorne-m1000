const std = @import("std");
const dbg = @import("debug_log.zig");
const Io = std.Io;

// 0.16 removed `std.time.timestamp` and friends; wall-clock readings now come
// from the `Io` implementation via the `.real` clock. These wrappers keep the
// old call shape, just with an `io` argument.

/// Seconds since the Unix epoch.
pub fn nowSeconds(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// Milliseconds since the Unix epoch.
pub fn nowMillis(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Nanoseconds since the Unix epoch.
pub fn nowNanos(io: Io) i128 {
    return Io.Timestamp.now(io, .real).nanoseconds;
}

pub const zoneinfo = struct {
    offset_sec: i32,
    is_dst: u8,
};

pub const Ymdhms = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Dhms = struct {
    sign: i8,
    day: u16,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Hms = struct {
    sign: i8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const HmsMs = struct {
    sign: i8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};

/// Get the local timezone offset in seconds from UTC
pub fn getTimezoneInfo(io: Io) zoneinfo {
    // Read timezone info from /etc/localtime symlink
    if (Io.Dir.cwd().openFile(io, "/etc/localtime", .{})) |file| {
        defer file.close(io);

        // Try to parse the TZif file for accurate DST information
        if (parseTZifFile(io, file)) |zi| {
            return zi;
        } else {
            // Fallback to hardcoded mapping if TZif parsing fails
            std.log.warn("TZif parsing failed, using UTC\n", .{});
        }
    } else |err| {
        std.log.warn("Failed to open /etc/localtime: {}, using UTC\n", .{err});
    }

    return zoneinfo{ .offset_sec = 0, .is_dst = 0 };
}

/// Parse TZif file to get current timezone offset
fn parseTZifFile(io: Io, file: Io.File) ?zoneinfo {
    var buf: [1024]u8 = undefined;
    const utc_timestamp = nowSeconds(io);

    // Now read and parse the TZif file to get actual DST status
    var file_reader = file.reader(io, &.{});
    if (file_reader.seekTo(0)) |_| {
        if (file_reader.interface.readSliceShort(&buf)) |bytes_read| {
            // std.debug.print("Read {} bytes from timezone file\n", .{bytes_read});

            // Parse TZif file format
            if (bytes_read >= 44 and std.mem.eql(u8, buf[0..4], "TZif")) {
                // std.debug.print("Valid TZif file found\n", .{});

                // TZif header structure (simplified):
                // 0-3: "TZif" magic
                // 4: version
                // 5-19: reserved

                // isutcnt:  A four-octet unsigned integer specifying the number of UT/
                //     local indicators contained in the data block -- MUST either be
                //     zero or equal to "typecnt".

                // isstdcnt:  A four-octet unsigned integer specifying the number of
                //     standard/wall indicators contained in the data block -- MUST
                //     either be zero or equal to "typecnt".

                // leapcnt:  A four-octet unsigned integer specifying the number of
                //     leap-second records contained in the data block.

                // timecnt:  A four-octet unsigned integer specifying the number of
                //     transition times contained in the data block.

                // typecnt:  A four-octet unsigned integer specifying the number of
                //     local time type records contained in the data block -- MUST NOT be
                //     zero.  (Although local time type records convey no useful
                //     information in files that have nonempty TZ strings but no
                //     transitions, at least one such record is nevertheless required
                //     because many TZif readers reject files that have zero time types.)

                // charcnt:  A four-octet unsigned integer specifying the total number
                //     of octets used by the set of time zone designations contained in
                //     the data block - MUST NOT be zero.  The count includes the
                //     trailing NUL (0x00) octet at the end of the last time zone
                //     designation.

                // 20-23: isutcnt (big-endian)
                // 24-27: isstdcnt (big-endian)
                // 28-31: leapcnt (big-endian)
                // 32-35: timecnt (big-endian)
                // 36-39: typecnt (big-endian)
                // 40-43: charcnt (big-endian)

                const transition_count = std.mem.readInt(u32, buf[32..][0..4], .big);
                const type_count = std.mem.readInt(u32, buf[36..][0..4], .big);
                // std.debug.print("Transitions: {}, Types: {}\n", .{ transition_count, type_count });

                if (transition_count > 0 and type_count > 0 and type_count < 256) {
                    // Transition times start at offset 44, each is 4 bytes (big-endian)
                    // Local time types start after transition times
                    const transitions_size = transition_count * 4;
                    const types_offset = 44 + transitions_size + transition_count; // +transition_count for type indices
                    const buf_offset = @max(0, types_offset + (type_count * 6) - 1024);

                    file_reader.seekTo(buf_offset) catch |err| {
                        std.log.warn("Failed to seek to data: {}\n", .{err});
                        return null;
                    };
                    _ = file_reader.interface.readSliceShort(&buf) catch |err| {
                        std.log.warn("Failed to read data: {}\n", .{err});
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
                        const is_dst = buf[type_info_offset + 4 - buf_offset] != 0;

                        // Sanity check: timezone offsets should be reasonable (-12 to +14 hours)
                        if (offset_seconds >= -12 * 3600 and offset_seconds <= 14 * 3600) {
                            // std.debug.print("Current timezone offset: {} seconds ({}h), DST: {}\n", .{ offset_seconds, @divFloor(offset_seconds, 3600), is_dst });
                            // return offset_seconds;
                            return zoneinfo{ .offset_sec = offset_seconds, .is_dst = if (is_dst) 1 else 0 };
                        } else {
                            std.log.warn("Invalid offset {} seconds, using UTC\n", .{offset_seconds});
                        }
                    } else {
                        std.log.warn("Invalid type_idx {}, using UTC\n", .{current_type_idx});
                    }
                }
            } else {
                std.log.warn("Not a valid TZif file, using UTC\n", .{});
            }
        } else |err| {
            std.log.warn("Failed to read timezone file: {}\n", .{err});
        }
    } else |err| {
        std.log.warn("Failed to seek timezone file: {}\n", .{err});
    }

    return null;
}

/// A timezone offset shared between a background refresher and a loop that
/// cannot afford to go and work it out itself.
///
/// `getTimezoneInfo` opens and parses `/etc/localtime`. That is file I/O, and a
/// render loop with frame deadlines has no business doing it -- but the offset
/// still has to be re-read periodically or a DST change needs a restart. So a
/// background thread refreshes this and the render loop only ever does one
/// atomic load.
///
/// Both fields live in a single atomic word so a reader can never see the
/// offset from one reading paired with the DST flag from another.
pub const SharedZone = struct {
    packed_value: std.atomic.Value(u64),

    /// How often the refreshing thread should call `store`.
    pub const refresh_interval_ms: i64 = 10_000;

    pub fn init(zi: zoneinfo) SharedZone {
        return .{ .packed_value = .init(pack(zi)) };
    }

    pub fn load(self: *const SharedZone) zoneinfo {
        return unpack(self.packed_value.load(.acquire));
    }

    pub fn store(self: *SharedZone, zi: zoneinfo) void {
        self.packed_value.store(pack(zi), .release);
    }

    fn pack(zi: zoneinfo) u64 {
        return @as(u64, @as(u32, @bitCast(zi.offset_sec))) | (@as(u64, zi.is_dst) << 32);
    }

    fn unpack(value: u64) zoneinfo {
        return .{
            .offset_sec = @bitCast(@as(u32, @truncate(value))),
            .is_dst = @truncate(value >> 32),
        };
    }
};

/// Local wall clock, with the zone offset cached.
///
/// `getTimezoneInfo` re-parses `/etc/localtime` on every call, which is far too
/// expensive to run per frame, but the offset still has to be re-read
/// occasionally so a DST transition is picked up without a restart. Every mode
/// that puts the time of day on the display needs that same caching, so it
/// lives here rather than in any one mode.
pub const LocalClock = struct {
    zi: zoneinfo,
    next_refresh_utc: i64,

    /// How often the zone offset is re-read.
    pub const refresh_interval_sec: i64 = 10;

    /// A clock reading, kept together so callers needing both UTC and local do
    /// not sample twice and risk straddling a second boundary.
    pub const Reading = struct {
        utc: i64,
        /// Seconds since the epoch shifted into the local zone, i.e. what the
        /// `timestampTo*`/`format*` helpers want for wall-clock output.
        local: i64,
    };

    pub fn init(io: Io) LocalClock {
        return .{
            .zi = getTimezoneInfo(io),
            .next_refresh_utc = nowSeconds(io) + refresh_interval_sec,
        };
    }

    pub fn read(self: *LocalClock, io: Io) Reading {
        const utc = nowSeconds(io);
        if (utc >= self.next_refresh_utc) {
            self.zi = getTimezoneInfo(io);
            self.next_refresh_utc = utc + refresh_interval_sec;
        }
        return .{ .utc = utc, .local = utc + self.zi.offset_sec };
    }

    /// Current local time as "HH:MM:SS".
    pub fn formatNow(self: *LocalClock, io: Io, buf: []u8) ![]const u8 {
        return formatClock(self.read(io).local, buf);
    }
};

/// Format a timestamp as "HH:MM:SS": time of day only, no date.
pub fn formatClock(timestamp: i64, buf: []u8) ![]const u8 {
    const ymdhms = timestampToYmdhms(timestamp);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ ymdhms.hour, ymdhms.minute, ymdhms.second });
}

/// Format a timestamp as "YYYY-MM-DD HH:MM:SS"
pub fn formatIsoTimestamp(timestamp: i64, buf: []u8) ![]const u8 {
    return formatYmdhms(timestampToYmdhms(timestamp), buf);
}

pub fn formatYmdhms(ymdhms: Ymdhms, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ ymdhms.year, ymdhms.month, ymdhms.day, ymdhms.hour, ymdhms.minute, ymdhms.second });
}

pub fn formatDhms(dhms: Dhms, buf: []u8) ![]const u8 {
    const sign_char = if (dhms.sign < 0) "-" else "";
    return std.fmt.bufPrint(buf, "{s}{d}/{d:0>2}:{d:0>2}:{d:0>2}", .{ sign_char, dhms.day, dhms.hour, dhms.minute, dhms.second });
}

pub fn formatHms(hms: Hms, buf: []u8) ![]const u8 {
    const sign_char = if (hms.sign < 0) "-" else "";
    return std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}", .{ sign_char, hms.hour, hms.minute, hms.second });
}

pub fn formatHmsMs(hmsms: HmsMs, buf: []u8) ![]const u8 {
    const sign_char = if (hmsms.sign < 0) "-" else "";
    return std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{ sign_char, hmsms.hour, hmsms.minute, hmsms.second, hmsms.millisecond });
}

/// Format a timestamp as "25Au06W200/20:37:13D"
pub fn formatRandyTimestamp(timestamp: i64, buf: []u8, zi: ?*const zoneinfo) ![]const u8 {
    const ymdhms = timestampToYmdhms(timestamp);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    // const year_day = epoch_day.calculateYearDay();
    const weekday_idx: usize = @as(u4, @intCast(@mod(epoch_day.day + 4, 7))); // Jan 1, 1970 was a Thursday (index 4)
    const zone_idx = if (zi == null or zi.?.offset_sec == 0) 2 else zi.?.is_dst;

    // return std.fmt.bufPrint(buf, "{d:0>2}{s}{d:0>2}{s}{d:0>3}/{d:0>2}:{d:0>2}:{d:0>2}{s}", .{
    //     @mod(ymdhms.year, 100),
    //     month_2[ymdhms.month - 1],
    //     ymdhms.day,
    //     weekday_char[weekday_idx],
    //     year_day.day + 1,
    //     ymdhms.hour,
    //     ymdhms.minute,
    //     ymdhms.second,
    //     clock_char[zone_idx],
    // });

    return std.fmt.bufPrint(buf, "{d:0>2}{s}{d:0>2}{s} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        @mod(ymdhms.year, 100),
        month_2[ymdhms.month - 1],
        ymdhms.day,
        weekday_char[weekday_idx],
        // year_day.day + 1,
        ymdhms.hour,
        ymdhms.minute,
        ymdhms.second,
        clock_name[zone_idx],
    });
}

pub const month_2 = [_][]const u8{
    "Ja",
    "Fe",
    "Mr",
    "Ap",
    "My",
    "Jn",
    "Jl",
    "Au",
    "Se",
    "Oc",
    "Nv",
    "De",
};

pub const weekday_char = [_][]const u8{
    "N",
    "M",
    "T",
    "W",
    "R",
    "F",
    "S",
};

pub const clock_char = [_][]const u8{
    "S", // cst, abs
    "D", // cdt, abs
    "Z", // utc, abs
    "M", // met, rel
    "P", // pet, rel
    "L", // launch, rel
    "T", // timer, rel
};

pub const clock_name = [_][]const u8{
    "CST", // cst, abs
    "CDT", // cdt, abs
    "UTC", // utc, abs
    "MET", // met, rel
    "P", // pet, rel
    "L", // launch, rel
    "T", // timer, rel
};

pub fn ymdhmsToTimestamp(ymdhms: Ymdhms) i64 {
    const unix_epoch = 2440588; // actually 2440587.5, which is Jan 1, 1970 00:00:00 UTC
    const j2k = 2451545; // for Jan 1 2000 12:00:00 UTC
    const j2k_wrt_unix = comptime (j2k - unix_epoch); // Days from Unix epoch to J2000 epoch

    // Muller-Wimberly formula from SPICE
    const y: i64 = @intCast(ymdhms.year);
    const mo: i64 = @intCast(ymdhms.month);
    const d: i64 = @intCast(ymdhms.day);
    const h: i64 = @intCast(ymdhms.hour);
    const m: i64 = @intCast(ymdhms.minute);
    const s: i64 = @intCast(ymdhms.second);
    const days_since_j2k: i64 = y * 367 - @divTrunc((y + @divTrunc(mo + 9, 12)) * 7, 4) - @divTrunc((@divTrunc(y + @divTrunc(mo - 9, 7), 100) + 1) * 3, 4) + @divTrunc(mo * 275, 9) + d - 730516;
    // SPICE subtracts 0.5 from this to compute seconds past J2K, but we need to
    // add 0.5 to account for unix epoch being midnight relative to our j2k_wrt_unix,
    // so everything should even out and no corrections are needed.
    return (days_since_j2k + j2k_wrt_unix) * 86400 + h * 3600 + m * 60 + s;
}

pub fn timestampToYmdhms(timestamp: i64) Ymdhms {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds = @mod(timestamp, std.time.s_per_day);
    const hours = @divFloor(day_seconds, std.time.s_per_hour);
    const minutes = @divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min);
    const secs = @mod(day_seconds, std.time.s_per_min);

    return Ymdhms{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = @intCast(hours),
        .minute = @intCast(minutes),
        .second = @intCast(secs),
    };
}

test "SharedZone round-trips both fields in one atomic word" {
    // Packing exists so a reader cannot pair the offset from one reading with
    // the DST flag from another; the round trip has to be exact for that to be
    // worth anything, negative offsets included.
    for ([_]zoneinfo{
        .{ .offset_sec = 0, .is_dst = 0 },
        .{ .offset_sec = -6 * 3600, .is_dst = 0 }, // CST
        .{ .offset_sec = -5 * 3600, .is_dst = 1 }, // CDT
        .{ .offset_sec = 14 * 3600, .is_dst = 0 }, // the far end of the range
        .{ .offset_sec = -12 * 3600, .is_dst = 1 },
    }) |zi| {
        var shared: SharedZone = .init(zi);
        const got = shared.load();
        try std.testing.expectEqual(zi.offset_sec, got.offset_sec);
        try std.testing.expectEqual(zi.is_dst, got.is_dst);

        // And again after a store, which is the path the refresher uses.
        shared.store(.{ .offset_sec = 3600, .is_dst = 1 });
        const after = shared.load();
        try std.testing.expectEqual(@as(i32, 3600), after.offset_sec);
        try std.testing.expectEqual(@as(u8, 1), after.is_dst);
    }
}

test "ymdhmsToTimestamp" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const utc_timestamp = nowSeconds(threaded.io());
    dbg.print(.timezone, "Current UTC timestamp: {}\n", .{utc_timestamp});
    const ymdhms = timestampToYmdhms(utc_timestamp);
    var buf: [20]u8 = undefined;
    const formatted = try formatYmdhms(ymdhms, &buf);
    dbg.print(.timezone, "Formatted: {s}\n", .{formatted});
    const new_timestamp = ymdhmsToTimestamp(ymdhms);
    dbg.print(.timezone, "Converted timestamp: {}\n", .{new_timestamp});
    try std.testing.expectEqual(utc_timestamp, new_timestamp);
}

pub fn timedeltaToDhms(delta_sec: i64) Dhms {
    const sign: i64 = if (delta_sec < 0) -1 else 1;
    const abs_delta_sec = @abs(delta_sec);
    const days = @as(i64, @intCast(@divFloor(abs_delta_sec, 86400)));
    const hours = @divFloor(@mod(abs_delta_sec, 86400), 3600);
    const minutes = @divFloor(@mod(abs_delta_sec, 3600), 60);
    const seconds = @mod(abs_delta_sec, 60);
    return Dhms{
        .sign = @as(i8, @intCast(sign)),
        .day = @intCast(days),
        .hour = @intCast(hours),
        .minute = @intCast(minutes),
        .second = @intCast(seconds),
    };
}

pub fn dhmsToTimedelta(dhms: Dhms) i64 {
    const sign: i64 = @intCast(dhms.sign);
    const d: i64 = @intCast(dhms.day);
    const h: i64 = @intCast(dhms.hour);
    const m: i64 = @intCast(dhms.minute);
    const s: i64 = @intCast(dhms.second);
    return sign * (d * 86400 + h * 3600 + m * 60 + s);
}

pub fn timedeltaToHms(delta_sec: i64) Hms {
    const sign: i64 = if (delta_sec < 0) -1 else 1;
    const abs_delta_sec = @abs(delta_sec);
    const hours = @as(i64, @intCast(@divFloor(abs_delta_sec, 3600)));
    const minutes = @divFloor(@mod(abs_delta_sec, 3600), 60);
    const seconds = @mod(abs_delta_sec, 60);
    return Hms{
        .sign = @as(i8, @intCast(sign)),
        .hour = @intCast(hours),
        .minute = @intCast(minutes),
        .second = @intCast(seconds),
    };
}

pub fn timedeltaMsToHmsMs(delta_ms: i64) HmsMs {
    const sign: i64 = if (delta_ms < 0) -1 else 1;
    const abs_delta_ms = @abs(delta_ms);
    const total_seconds = @divFloor(abs_delta_ms, 1000);
    const hours = @as(i64, @intCast(@divFloor(total_seconds, 3600)));
    const minutes = @divFloor(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);
    const milliseconds = @mod(abs_delta_ms, 1000);
    return HmsMs{
        .sign = @as(i8, @intCast(sign)),
        .hour = @intCast(hours),
        .minute = @intCast(minutes),
        .second = @intCast(seconds),
        .millisecond = @intCast(milliseconds),
    };
}

pub fn hmsToTimedelta(hms: Hms) i64 {
    const sign: i64 = @intCast(hms.sign);
    const h: i64 = @intCast(hms.hour);
    const m: i64 = @intCast(hms.minute);
    const s: i64 = @intCast(hms.second);
    return sign * (h * 3600 + m * 60 + s);
}
