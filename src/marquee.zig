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
//! Positions are byte offsets. Cue text is expected to be plain ASCII -- the
//! panel is not a UTF-8 device -- so bytes and columns are the same thing.

const std = @import("std");

pub const Marquee = struct {
    /// How long each one-character step takes.
    step_ms: i64 = 250,
    /// How long to pause at each end, so the ends can actually be read.
    hold_ms: i64 = 1500,

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

        if (text.len <= width) return text;

        const overflow: i64 = @intCast(text.len - width);
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

        const start: usize = @intCast(std.math.clamp(offset, 0, overflow));
        return text[start .. start + width];
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
    const overflow = long_text.len - cols; // 12

    // Holds at the left first, so the start is readable.
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, 0));
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, 1_400));

    // Then steps right, one column per step_ms.
    try testing.expectEqualStrings(long_text[1..][0..cols], m.window(long_text, cols, 1_500 + 250));
    try testing.expectEqualStrings(long_text[5..][0..cols], m.window(long_text, cols, 1_500 + 5 * 250));

    // Reaches the end, showing the tail of the text.
    const at_end = 1_500 + overflow * 250;
    try testing.expectEqualStrings(long_text[overflow..], m.window(long_text, cols, at_end));
    try testing.expectEqualStrings("Stop The Fight", long_text[overflow + 6 ..]);

    // Holds there, then slides back.
    try testing.expectEqualStrings(long_text[overflow..], m.window(long_text, cols, at_end + 1_400));
    const returning = at_end + 1_500 + 3 * 250;
    try testing.expectEqualStrings(long_text[overflow - 3 ..][0..cols], m.window(long_text, cols, returning));
}

test "the sweep repeats instead of stopping at one end" {
    var m: Marquee = .{};
    const overflow: i64 = long_text.len - cols;
    const cycle = 2 * (1_500 + overflow * 250);

    // The same instant in any later cycle shows the same window.
    for ([_]i64{ 0, 1, 2, 7 }) |n| {
        try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, n * cycle));
        try testing.expectEqualStrings(
            long_text[5..][0..cols],
            m.window(long_text, cols, n * cycle + 1_500 + 5 * 250),
        );
    }
}

test "a new message restarts the sweep from the left" {
    var m: Marquee = .{};
    const other = "3m17 Charming The Pziiffelback";

    // Scroll the first message well into its sweep.
    _ = m.window(long_text, cols, 0);
    const mid = m.window(long_text, cols, 1_500 + 6 * 250);
    try testing.expectEqualStrings(long_text[6..][0..cols], mid);

    // A different message must not inherit that offset.
    try testing.expectEqualStrings(other[0..cols], m.window(other, cols, 1_500 + 6 * 250));

    // Returning to the original text also restarts it, rather than resuming.
    try testing.expectEqualStrings(long_text[0..cols], m.window(long_text, cols, 1_500 + 6 * 250));
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

test "text only one column too wide still scrolls" {
    var m: Marquee = .{};
    const text = "123456789012345678901"; // one wider than the display
    try testing.expectEqualStrings(text[0..cols], m.window(text, cols, 0));
    try testing.expectEqualStrings(text[1..], m.window(text, cols, 1_500 + 250));
}
