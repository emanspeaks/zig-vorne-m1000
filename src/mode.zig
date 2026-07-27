const std = @import("std");

pub const Mode = enum(u8) {
    Clocks = 0,
    Bluray = 1,
    Vlc = 2,
};

/// One-shot request to re-initialise the panel and repaint from scratch.
///
/// Set by the web page's "Init" button, consumed by `main`'s mode-dispatch
/// loop. It exists because **only the display thread may write to the serial
/// port** (see CLAUDE.md): there is no lock on that fd, so a write issued from
/// the HTTP handler interleaves its bytes with whatever frame the render loop
/// is emitting at that instant. The spliced frame then fails its CRC and is
/// dropped -- or, worse, is accepted as a different command. The init sequence
/// carries a window-geometry command, and a mangled one leaves later writes
/// addressing somewhere off-screen, so the panel goes blank and stays blank:
/// a redraw repaints content but never re-sends the geometry.
///
/// So the button sets this instead of touching the port. The running mode loop
/// notices it and returns; the dispatch loop consumes it, sends the init on the
/// display thread, and re-enters the same mode, which repaints from scratch
/// because its "what is on the panel" records start empty.
///
/// A module-level atomic rather than a parameter threaded through every mode
/// loop, since all three already import this module and none of them needs to
/// do anything with it beyond noticing.
var reinit_requested = std.atomic.Value(bool).init(false);

/// Ask for a re-init. Safe to call from any thread.
pub fn requestReinit() void {
    reinit_requested.store(true, .release);
}

/// Whether a re-init is pending, without consuming it.
///
/// This is what a mode loop checks alongside its mode-change test. It
/// deliberately does not consume: the loop only needs to stop, and the
/// dispatch loop that actually performs the init is what clears the flag.
pub fn reinitPending() bool {
    return reinit_requested.load(.acquire);
}

/// Consume a pending re-init request, reporting whether there was one.
///
/// `swap` rather than load-then-store so a request arriving between the two
/// cannot be lost, and so a single click cannot be serviced twice.
pub fn takeReinitRequest() bool {
    return reinit_requested.swap(false, .acq_rel);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a reinit request is visible until taken, then gone" {
    _ = takeReinitRequest(); // start from a known state

    try testing.expect(!reinitPending());
    try testing.expect(!takeReinitRequest());

    requestReinit();
    // Pending is non-destructive: a mode loop may check it repeatedly while
    // winding down without stealing the request from the dispatch loop.
    try testing.expect(reinitPending());
    try testing.expect(reinitPending());

    try testing.expect(takeReinitRequest());
    // ...and exactly once, so one click cannot cause two re-inits.
    try testing.expect(!takeReinitRequest());
    try testing.expect(!reinitPending());
}

test "repeated requests before a take collapse into one" {
    _ = takeReinitRequest();

    requestReinit();
    requestReinit();
    requestReinit();
    try testing.expect(takeReinitRequest());
    try testing.expect(!takeReinitRequest());
}
