//! Cue-file selection for the Blu-ray second line.
//!
//! Which file is showing, and whether its cues are being displayed at all, are
//! chosen from the web page but consumed by the display loop, so the state
//! lives here and is shared between those two threads.
//!
//! Arming is deliberately manual. The player is a Panasonic UB-series deck,
//! which reports elapsed play time and nothing else -- no title, no chapter, no
//! total runtime -- so there is no reliable signal that says "the feature is
//! playing now" rather than a menu loop or a trailer. Rather than guess and be
//! wrong in a way nobody can correct, cues start when told to.

const std = @import("std");
const Io = std.Io;
const webvtt = @import("webvtt.zig");

/// Directory scanned for cue files, unless overridden by
/// `dir_path_config_path`. Every `*.vtt` in it appears in the web page's
/// drop-down.
pub const default_dir_path = "/home/emanspeaks/bluray_cues";

/// Optional text file naming a different cue directory, one line, trimmed --
/// the same shape as `bluray_ip.txt`/`bluray_key.txt` in `config.zig`.
///
/// Exists because a hardcoded path here is a silent footgun: point it at a
/// directory that does not match wherever the real cue files actually live
/// (they need not be checked into this repository at all, and commonly will
/// not be) and the symptom is not an error anywhere -- it is an empty dropdown
/// on the web page and line 2 permanently showing the "nothing selected"
/// fallback text, which looks exactly like a code regression even though
/// nothing is broken. Overriding the directory here, rather than requiring a
/// symlink at the hardcoded path, makes the mismatch fixable without touching
/// the filesystem layout the rest of the system expects.
pub const dir_path_config_path = "/home/emanspeaks/bluray_cues_dir.txt";

/// Upper bound on a configured directory path. Generous, and independent of
/// `default_dir_path`'s own length, since it sizes the fixed buffers
/// `buildPath` writes into -- a configured path longer than this is rejected
/// rather than silently truncated or overflowing.
pub const max_dir_path_len: usize = 200;

var active_dir_path_buf: [max_dir_path_len]u8 = undefined;
var active_dir_path: []const u8 = default_dir_path;

/// The directory currently in use: `default_dir_path` until `configureDirPath`
/// overrides it.
pub fn dirPath() []const u8 {
    return active_dir_path;
}

/// Trim and validate a candidate path read from `dir_path_config_path`.
/// Returns null for anything empty or too long to fit the fixed buffer -- pure
/// and I/O-free so the validation itself is directly testable.
fn parseDirPathConfig(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_dir_path_len) return null;
    return trimmed;
}

/// Read `dir_path_config_path` and, if it names a usable directory, use it in
/// place of `default_dir_path` for the rest of the process.
///
/// Call once, early in `main`, before any thread reads `dirPath()` -- there is
/// no synchronization on `active_dir_path`, by design: this is meant to run
/// once while still single-threaded, not to be re-read live.
pub fn configureDirPath(io: Io) void {
    const raw = Io.Dir.readFileAlloc(
        .cwd(),
        io,
        dir_path_config_path,
        std.heap.page_allocator,
        .limited(max_dir_path_len + 16),
    ) catch |err| switch (err) {
        error.FileNotFound => return, // Expected: use the built-in default.
        else => {
            std.debug.print("Error reading {s}: {}, using default cue directory\n", .{ dir_path_config_path, err });
            return;
        },
    };
    defer std.heap.page_allocator.free(raw);

    const trimmed = parseDirPathConfig(raw) orelse {
        std.debug.print(
            "{s} is empty or too long (max {d}), using default cue directory\n",
            .{ dir_path_config_path, max_dir_path_len },
        );
        return;
    };

    @memcpy(active_dir_path_buf[0..trimmed.len], trimmed);
    active_dir_path = active_dir_path_buf[0..trimmed.len];
    std.debug.print("Using cue directory: {s}\n", .{active_dir_path});
}

pub const extension = ".vtt";

/// Longest file name accepted, so a selection fits in a fixed buffer and can be
/// copied out under the lock without allocating.
pub const max_name_len = 96;

/// Upper bound on a cue file. A feature-length file of 20-column messages is a
/// few kilobytes; this is generous.
const max_cue_bytes: Io.Limit = .limited(1 << 20);

/// The selected cue file and whether its cues are being shown.
///
/// The web handler writes and the display loop reads every frame, so the name
/// needs mutual exclusion. `generation` is bumped on every change, letting the
/// display loop notice a new selection with a single atomic load rather than
/// taking the lock -- or re-reading the file -- on every frame.
pub const State = struct {
    /// A spin lock rather than a full mutex: every critical section here is a
    /// copy of at most `max_name_len` bytes, entered either once per web click
    /// or once per changed selection, so there is never anything worth sleeping
    /// on and contention is effectively zero.
    lock: std.atomic.Value(bool) = .init(false),
    name_buf: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    generation: std.atomic.Value(u64) = .init(1),
    armed: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *State) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *State) void {
        self.lock.store(false, .release);
    }

    pub fn isArmed(self: *const State) bool {
        return self.armed.load(.acquire);
    }

    pub fn setArmed(self: *State, on: bool) void {
        self.armed.store(on, .release);
    }

    /// Replace the selection. Returns false for a name that is not a plain
    /// `*.vtt` file name, so a crafted request cannot reach outside the cue
    /// directory.
    pub fn select(self: *State, name: []const u8) bool {
        if (!isValidName(name)) return false;
        self.acquire();
        defer self.release();
        @memcpy(self.name_buf[0..name.len], name);
        self.name_len = name.len;
        _ = self.generation.fetchAdd(1, .release);
        return true;
    }

    /// Clear the selection, which also blanks the line.
    pub fn clear(self: *State) void {
        self.acquire();
        defer self.release();
        self.name_len = 0;
        _ = self.generation.fetchAdd(1, .release);
    }

    /// Copy the current selection into `buf`, returning it, or null when
    /// nothing is selected.
    pub fn currentName(self: *State, buf: *[max_name_len]u8) ?[]const u8 {
        self.acquire();
        defer self.release();
        if (self.name_len == 0) return null;
        @memcpy(buf[0..self.name_len], self.name_buf[0..self.name_len]);
        return buf[0..self.name_len];
    }
};

/// A name is accepted only if it is a bare `*.vtt` file name: no path
/// separators, no parent-directory hops, nothing that could escape the cue
/// directory.
pub fn isValidName(name: []const u8) bool {
    if (name.len <= extension.len or name.len > max_name_len) return false;
    if (!std.mem.endsWith(u8, name, extension)) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

/// The name with `.vtt` removed, for display.
pub fn baseName(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, extension))
        name[0 .. name.len - extension.len]
    else
        name;
}

/// Sorted names of the cue files in `dirPath()`.
///
/// A missing directory yields an empty list rather than an error: not having
/// set any cue files up yet is a normal state, not a fault. Note that this
/// makes a directory-path mismatch indistinguishable, from the web page alone,
/// from having no cue files at all -- if the dropdown is unexpectedly empty,
/// check `dirPath()`/`dir_path_config_path` before assuming the files are gone.
/// Caller owns the result; release it with `freeNames`.
pub fn listNames(io: Io, allocator: std.mem.Allocator) ![][]const u8 {
    var dir = Io.Dir.cwd().openDir(io, dirPath(), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!isValidName(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, lessThanName);
    return names.toOwnedSlice(allocator);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn freeNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

/// Sized for the worst case a configured directory path can reach
/// (`max_dir_path_len`), not for whatever `default_dir_path` happens to be.
const PathBuf = [max_dir_path_len + 1 + max_name_len]u8;

fn buildPath(buf: *PathBuf, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dirPath(), name }) catch unreachable;
}

/// Enough of a cue file's metadata to tell whether it has been edited.
///
/// Size is compared alongside modification time because some editors write
/// through and some rename a temporary file into place; between them, a change
/// that leaves both identical is not worth worrying about.
pub const Fingerprint = struct {
    mtime_ns: i128,
    size: u64,

    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return self.mtime_ns == other.mtime_ns and self.size == other.size;
    }
};

/// Fingerprint of a cue file, or null if it cannot be stat'ed -- deleted or
/// renamed mid-session, most likely.
pub fn fingerprint(io: Io, name: []const u8) ?Fingerprint {
    if (!isValidName(name)) return null;

    var path_buf: PathBuf = undefined;
    const stat = Io.Dir.cwd().statFile(io, buildPath(&path_buf, name), .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
}

/// Read and parse one cue file from `dirPath()`.
pub fn load(io: Io, allocator: std.mem.Allocator, name: []const u8) !webvtt.CueList {
    if (!isValidName(name)) return error.InvalidCueFileName;

    var path_buf: PathBuf = undefined;
    const source = try Io.Dir.readFileAlloc(.cwd(), io, buildPath(&path_buf, name), allocator, max_cue_bytes);
    defer allocator.free(source);

    return webvtt.parse(allocator, source);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isValidName rejects anything that could escape the cue directory" {
    try testing.expect(isValidName("blade-runner.vtt"));
    try testing.expect(isValidName("The Thing (1982).vtt"));

    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName(".vtt")); // no stem
    try testing.expect(!isValidName("notes.txt"));
    try testing.expect(!isValidName("../../etc/passwd.vtt"));
    try testing.expect(!isValidName("sub/dir.vtt"));
    try testing.expect(!isValidName("sub\\dir.vtt"));
    var too_long: [max_name_len + 1]u8 = undefined;
    @memset(&too_long, 'a');
    @memcpy(too_long[too_long.len - extension.len ..], extension);
    try testing.expect(!isValidName(&too_long));
}

test "baseName strips the extension for display" {
    try testing.expectEqualStrings("blade-runner", baseName("blade-runner.vtt"));
    try testing.expectEqualStrings("odd", baseName("odd"));
}

test "selection is rejected rather than silently accepted when invalid" {
    var state: State = .{};
    var buf: [max_name_len]u8 = undefined;

    try testing.expectEqual(@as(?[]const u8, null), state.currentName(&buf));

    try testing.expect(state.select("movie.vtt"));
    try testing.expectEqualStrings("movie.vtt", state.currentName(&buf).?);

    const generation = state.generation.load(.acquire);
    try testing.expect(!state.select("../escape.vtt"));
    // A rejected selection must not disturb the current one.
    try testing.expectEqualStrings("movie.vtt", state.currentName(&buf).?);
    try testing.expectEqual(generation, state.generation.load(.acquire));

    state.clear();
    try testing.expectEqual(@as(?[]const u8, null), state.currentName(&buf));
    try testing.expect(generation != state.generation.load(.acquire));
}

test "a fingerprint changes when either mtime or size does" {
    const base: Fingerprint = .{ .mtime_ns = 1_000, .size = 42 };
    try testing.expect(base.eql(.{ .mtime_ns = 1_000, .size = 42 }));
    // An in-place edit that keeps the length still moves mtime.
    try testing.expect(!base.eql(.{ .mtime_ns = 1_001, .size = 42 }));
    // A rename-into-place can land on a coarse mtime; size still catches it.
    try testing.expect(!base.eql(.{ .mtime_ns = 1_000, .size = 43 }));
}

test "fingerprint declines names it would refuse to load" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Rejected by `isValidName`, so it never reaches the filesystem.
    try testing.expectEqual(@as(?Fingerprint, null), fingerprint(io, "../escape.vtt"));
    // Valid name, but no such file: a missing file must not be an error, so the
    // display keeps whatever it already has.
    try testing.expectEqual(@as(?Fingerprint, null), fingerprint(io, "definitely-not-here-9f3a.vtt"));
}

test "parseDirPathConfig trims whitespace and rejects unusable input" {
    try testing.expectEqualStrings("/mnt/nas/cues", parseDirPathConfig("/mnt/nas/cues\n").?);
    try testing.expectEqualStrings("/mnt/nas/cues", parseDirPathConfig("  /mnt/nas/cues  \r\n").?);
    try testing.expectEqual(@as(?[]const u8, null), parseDirPathConfig(""));
    try testing.expectEqual(@as(?[]const u8, null), parseDirPathConfig("   \n"));

    var too_long: [max_dir_path_len + 1]u8 = undefined;
    @memset(&too_long, 'a');
    try testing.expectEqual(@as(?[]const u8, null), parseDirPathConfig(&too_long));

    // Exactly at the limit is fine; only strictly over is rejected.
    var exactly_max: [max_dir_path_len]u8 = undefined;
    @memset(&exactly_max, 'a');
    try testing.expect(parseDirPathConfig(&exactly_max) != null);
}

test "dirPath defaults to default_dir_path until configured" {
    // Depends on no earlier test in this run having called configureDirPath
    // with something that actually overrides it -- true today, since the only
    // other test that calls it exercises exclusively the absent-file path.
    try testing.expectEqualStrings(default_dir_path, dirPath());
}

test "configureDirPath leaves the default in place when the config file is absent" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // No such file exists on any dev or CI machine, so this exercises exactly
    // the FileNotFound branch -- the common case for anyone who has not set up
    // an override.
    configureDirPath(threaded.io());
    try testing.expectEqualStrings(default_dir_path, dirPath());
}

test "arming defaults to off" {
    var state: State = .{};
    try testing.expect(!state.isArmed());
    state.setArmed(true);
    try testing.expect(state.isArmed());
    state.setArmed(false);
    try testing.expect(!state.isArmed());
}
