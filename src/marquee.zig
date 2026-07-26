//! Ping-pong scrolling for text wider than the display.
//!
//! A 20 column line cannot show a cue like "4m27-28 Kill Ring/Stop The Fight",
//! so the visible window slides right until the end of the text is showing,
//! then slides back to the start, pausing at each end long enough to read.
//!
//! The window position is a pure function of the time elapsed since the sweep
//! began, not something advanced per frame. That means it cannot accumulate
//! drift however the render loop happens to be scheduled, and a frame that
//! arrives late lands where it should rather than one step behind.
//!
//! Positions are *display columns*, not byte offsets -- deliberately not the
//! same thing. Cue text has already been transcoded into the panel's own
//! character set by the time it reaches here (`vorne_charset.encodeUtf8`, at
//! parse time), and most of that set is one byte per column, but the graphic
//! characters below the space (`vorne_charset.control_chars`) are a `DLE`
//! escape: two bytes for one column. Treating `text.len` as the column count
//! -- an earlier version of this file did -- overcounts by one for every such
//! glyph, which shows up as the sweep stopping short of the true end and
//! never fully reaching it, silently, for any cue containing one. `str_utils`
//! already has to solve this same byte-vs-column distinction for the fixed
//! display buffers, so this reuses `strlensz`/`idxChar2Str` rather than
//! re-deriving it.

const std = @import("std");
const str_utils = @import("str_utils.zig");

pub const Marquee = struct {
    /// How long each one-character step takes.
    step_ms: i64 = 400,
    /// How long to pause at each end, so the ends can actually be read.
    hold_ms: i64 = 2000,

    /// When the current sweep began.
    started_ms: i64 = 0,
    /// Identifies the text being scrolled, so a new message restarts from the
    /// left instead of picking up wherever the previous one had slid to.
    text_id: u64 = 0,
    started: bool = false,

    /// The `width`-column window of `text` to show at `now_ms`.
    ///
    /// Returns `text` unchanged when it already fits.
    pub fn window(self: *Marquee, text: []const u8, width: usize, now_ms: i64) []const u8 {
        const id = std.hash.Wyhash.hash(0, text);
        if (!self.started or id != self.text_id) {
            self.text_id = id;
            self.started_ms = now_ms;
            self.started = true;
        }

        const chars = (str_utils.strlensz(text) catch unreachable)[0];
        if (chars <= width) return text;

        const overflow: i64 = @intCast(chars - width);
        const travel_ms = overflow * self.step_ms;
        const cycle_ms = 2 * (self.hold_ms + travel_ms);
        const t = @mod(now_ms - self.started_ms, cycle_ms);

        const offset: i64 = if (t < self.hold_ms)
            0 // holding at the start
        else if (t < self.hold_ms + travel_ms)
            @divFloor(t - self.hold_ms, self.step_ms) // sliding right
        else if (t < 2 * self.hold_ms + travel_ms)
            overflow // holding at the end
        else
            overflow - @divFloor(t - 2 * self.hold_ms - travel_ms, self.step_ms); // sliding back

        const start_char: usize = @intCast(std.math.clamp(offset, 0, overflow));
        // Byte offsets, not column offsets: a DLE-escaped glyph anywhere
        // before the window shifts every later byte position relative to its
        // column position, so the slice bounds have to be looked up rather
        // than computed by arithmetic on `start_char`/`width` directly.
        const start_byte = str_utils.idxChar2Str(text, start_char) catch unreachable;
        const end_byte = str_utils.idxChar2Str(text, start_char + width) catch unreachable;
        return text[start_byte..end_byte];
    }

    /// When the window next changes, so the caller can sleep until exactly then.
    ///
    /// Null when the text fits and nothing will ever move. Call after `window`,
    /// which is what establishes the sweep's start time.
    ///
    /// Waking on a fixed slice instead lands each step somewhere inside that
    /// slice at random, so the gaps between steps vary by the slice width. On a
    /// character display every step is a visible jump, and unevenly spaced
    /// jumps read as stutter -- the scroll only looks smooth if the timing is
    /// even, which means being woken for it rather than noticing it late.
    pub fn nextStepMs(self: *const Marquee, text: []const u8, width: usize, now_ms: i64) ?i64 {
        if (!self.started) return null;
        const chars = (str_utils.strlensz(text) catch unreachable)[0];
        if (chars <= width) return null;

        const overflow: i64 = @intCast(chars - width);
        const travel_ms = overflow * self.step_ms;
        const cycle_ms = 2 * (self.hold_ms + travel_ms);
        const t = @mod(now_ms - self.started_ms, cycle_ms);
        const cycle_start_ms = now_ms - t;

        // Mirrors the phases in `window`: the offset only moves during the two
        // sliding phases, so a hold ends at its first step rather than at the
        // phase boundary, where the offset is still what it was.
        const next_t: i64 = if (t < self.hold_ms)
            self.hold_ms + self.step_ms
        else if (t < self.hold_ms + travel_ms)
            self.hold_ms + (@divFloor(t - self.hold_ms, self.step_ms) + 1) * self.step_ms
        else if (t < 2 * self.hold_ms + travel_ms)
            2 * self.hold_ms + travel_ms + self.step_ms
        else
            2 * self.hold_ms + travel_ms +
                (@divFloor(t - 2 * self.hold_ms - travel_ms, self.step_ms) + 1) * self.step_ms;

        return cycle_start_ms + next_t;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 32 characters, from the real soundtrack cue list.
const long_text = "4m27-28 Kill Ring/Stop The Fight";
const cols = 20;

test "text that fits is returned untouched and never scrolls" {
    var m: Marquee = .{};
    const short = "1m2 This Is Berk";
    try testing.expectEqualStrings(short, m.window(short, cols, 0));
    // Still the same much later: a fitting line must be perfectly static, or
    // the display would rewrite itself for nothing.
    try testing.expectEqualStrings(short, m.window(short, cols, 60_000));
    // Exactly full width is not overflow.
    const exact = "12345678901234567890";
    try testing.expectEqualStrings(exact, m.window(exact, cols, 30_000));
}

test "a sweep starts at the left, reaches the end, and comes back" {
    var m: Marquee = .{};
    const step = m.step_ms;
    const hold = m.hold_ms;
    const overflow = long_text.len - cols; // 12

    // Holds at the left first, so the start is readable.
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, 0));
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, hold - 1));

    // Then steps right, one column per step_ms.
    try testing.expectEqualStrings(long_text[1..][0..cols], m.window(long_text, cols, hold + step));
    try testing.expectEqualStrings(long_text[5..][0..cols], m.window(long_text, cols, hold + 5 * step));

    // Reaches the end, showing the tail of the text.
    const at_end = hold + @as(i64, @intCast(overflow)) * step;
    try testing.expectEqualStrings(long_text[overflow..], m.window(long_text, cols, at_end));
    try testing.expectEqualStrings("Stop The Fight", long_text[overflow + 6 ..]);

    // Holds there, then slides back.
    try testing.expectEqualStrings(long_text[overflow..], m.window(long_text, cols, at_end + hold - 1));
    const returning = at_end + hold + 3 * step;
    try testing.expectEqualStrings(long_text[overflow - 3 ..][0..cols], m.window(long_text, cols, returning));
}

test "the sweep repeats instead of stopping at one end" {
    var m: Marquee = .{};
    const step = m.step_ms;
    const hold = m.hold_ms;
    const overflow: i64 = long_text.len - cols;
    const cycle = 2 * (hold + overflow * step);

    // The same instant in any later cycle shows the same window.
    for ([_]i64{ 0, 1, 2, 7 }) |n| {
        try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, n * cycle));
        try testing.expectEqualStrings(
            long_text[5..][0..cols],
            m.window(long_text, cols, n * cycle + hold + 5 * step),
        );
    }
}

test "a new message restarts the sweep from the left" {
    var m: Marquee = .{};
    const other = "3m17 Charming The Pziiffelback";

    const into_sweep = m.hold_ms + 6 * m.step_ms;

    // Scroll the first message well into its sweep.
    _ = m.window(long_text, cols, 0);
    try testing.expectEqualStrings(long_text[6..][0..cols], m.window(long_text, cols, into_sweep));

    // A different message must not inherit that offset.
    try testing.expectEqualStrings(other[0..cols], m.window(other, cols, into_sweep));

    // Returning to the original text also restarts it, rather than resuming.
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, into_sweep));
}

test "the window never runs off the end of the text" {
    var m: Marquee = .{};
    // Sweep densely across several cycles and check every window is in bounds
    // and full width -- an off-by-one here would be a panic on the display.
    var t: i64 = 0;
    while (t < 60_000) : (t += 17) {
        const w = m.window(long_text, cols, t);
        try testing.expectEqual(cols, w.len);
        const offset = @intFromPtr(w.ptr) - @intFromPtr(long_text.ptr);
        try testing.expect(offset + cols <= long_text.len);
    }
}

test "nextStepMs predicts exactly when the window changes" {
    // The property that matters: driving the loop purely off `nextStepMs` must
    // land on every change and never on a non-change. If it fired early the
    // display would redraw for nothing; late, the step would be visibly delayed.
    var m: Marquee = .{};
    var now: i64 = 0;
    var previous = m.window(long_text, cols, now);

    var changes: usize = 0;
    for (0..60) |_| {
        const due = m.nextStepMs(long_text, cols, now).?;
        try testing.expect(due > now);

        // Just before the predicted moment nothing has moved yet...
        const before = m.window(long_text, cols, due - 1);
        try testing.expectEqualStrings(previous, before);

        // ...and exactly at it, the window has advanced by one column.
        const after = m.window(long_text, cols, due);
        try testing.expect(!std.mem.eql(u8, previous, after));

        previous = after;
        now = due;
        changes += 1;
    }
    try testing.expect(changes == 60);
}

test "steps are evenly spaced, including across the end holds" {
    var m: Marquee = .{};
    var now: i64 = 0;
    _ = m.window(long_text, cols, now);

    const overflow: i64 = long_text.len - cols;
    var gaps_at_step: usize = 0;
    var gaps_at_hold: usize = 0;

    for (0..40) |_| {
        const due = m.nextStepMs(long_text, cols, now).?;
        const gap = due - now;
        // Every gap is either one plain step, or a step plus one hold at an end.
        if (gap == m.step_ms) {
            gaps_at_step += 1;
        } else if (gap == m.step_ms + m.hold_ms) {
            gaps_at_hold += 1;
        } else {
            std.debug.print("unexpected gap {d} ms\n", .{gap});
            return error.UnevenStep;
        }
        now = due;
    }

    // Both kinds really occurred, so the test covers the hold boundaries too.
    try testing.expect(gaps_at_step > 0);
    try testing.expect(gaps_at_hold > 0);
    // Roughly one hold per traverse.
    try testing.expect(gaps_at_hold <= 40 / @as(usize, @intCast(overflow)) + 2);
}

test "nextStepMs is null when there is nothing to animate" {
    var m: Marquee = .{};
    // Before the first `window` call there is no sweep to schedule against.
    try testing.expectEqual(@as(?i64, null), m.nextStepMs(long_text, cols, 0));

    const short = "1m2 This Is Berk";
    _ = m.window(short, cols, 0);
    // A line that fits is perfectly static: waking for it would be pure waste.
    try testing.expectEqual(@as(?i64, null), m.nextStepMs(short, cols, 0));
}

test "text only one column too wide still scrolls" {
    var m: Marquee = .{};
    const text = "123456789012345678901"; // one wider than the display
    try testing.expectEqualStrings(text[0..cols], m.window(text, cols, 0));
    try testing.expectEqualStrings(text[1..], m.window(text, cols, m.hold_ms + m.step_ms));
}

test "a DLE-escaped glyph counts as one column, not two, so the sweep reaches the true end" {
    // "\x10P" is the same glyph as bluray.PLAYCHAR: one column, two bytes. 25
    // columns total (10 + 1 + 14), 26 bytes -- a version that used text.len as
    // the column count would compute overflow = 26 - 20 = 6 instead of the
    // true 5, and the window would either stop one column short of the real
    // end or slice straight through the DLE pair, depending on where the
    // extra byte happened to land.
    const text = "0123456789" ++ "\x10P" ++ "ABCDEFGHIJKLMN";
    var m: Marquee = .{};

    // Every window, at every point in the sweep, is exactly `cols` columns --
    // never `cols` bytes, which for this text would be one column short.
    const overflow = 5;
    const at_end = m.hold_ms + overflow * m.step_ms;
    var t: i64 = 0;
    while (t <= at_end) : (t += 137) {
        const w = m.window(text, cols, t);
        try testing.expectEqual(@as(usize, cols), (try str_utils.strlensz(w))[0]);
    }

    // Fully swept, the window ends on the text's true final column ('N'), not
    // one short of it -- and does not split the DLE pair it swept past.
    const final = m.window(text, cols, at_end);
    try testing.expectEqualStrings("56789" ++ "\x10P" ++ "ABCDEFGHIJKLMN", final);
}
