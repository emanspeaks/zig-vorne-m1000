//! Phase lock onto a remote 1 Hz counter that can only be sampled at
//! whole-second resolution.
//!
//! The player reports elapsed play time in whole seconds, and every sample
//! costs a network round trip, so the raw value is always stale. Resolution
//! cannot be improved, but the *phase* of the counter's 1 Hz tick can be
//! recovered, after which the value between polls is computed from the local
//! clock instead of being polled for.
//!
//! ## One estimator, not several
//!
//! A sample that reads value `N` at instant `t` says exactly one thing: the
//! counter reached `N` somewhere in `(t - 1s, t]`. Measured against the
//! current model (the anchor), that statement becomes an interval of possible
//! model errors:
//!
//!     err  in  [drift*1000 - into,  drift*1000 + 1000 - into)   (ms)
//!
//! where `drift` is reported-minus-predicted in whole seconds and `into` is
//! how far into the modelled second the sample landed. Every sample yields
//! such an interval; consistent samples *intersect* to something narrower.
//! As long as the poll cadence is not a multiple of a second (see "No
//! scheduling here" below for where that comes from now), the sample instants
//! sweep across the counter's second like a vernier scale, and a handful of
//! samples pin the tick edge to a few tens of milliseconds -- **regardless of
//! the round trip**. Two samples 60 ms apart straddling an edge is merely the
//! lucky special case of the same arithmetic.
//!
//! That round-trip independence is the entire reason this file looks the way
//! it does. The real player was measured answering `cCMD_PST` in ~1000 ms
//! while a disc plays. An earlier design here needed two samples close
//! together in time (edge *bracketing*, then pre/post-edge *straddles* to
//! re-verify) and could never, even in principle, lock at that round trip:
//! it hunted forever on an anchor set by luck, tolerating a permanent error
//! of up to a full second -- the exact off-by-one the display showed. The
//! interval intersection does not care how far apart samples are: the
//! information is in where each sample lands *within* the second, never in
//! how close two samples are to each other.
//!
//! The same intersection also does the *value* checking that used to be a
//! separate mid-second poll kind. A pause or seek of a whole number of
//! seconds leaves the tick phase intact but shifts the value; its samples
//! produce intervals centered near a multiple of 1000 ms, which first
//! contradict the accumulated evidence (restarting the collection) and then
//! re-tighten around the shifted center, getting applied as a whole-second
//! anchor correction. Sub-second pauses re-center the same way. Jumps of
//! more than a second (|drift| > 1) skip the estimator and `rebase` directly,
//! so seeks and sustained trick play track within about a second.
//!
//! The lock free-wheels: losing confidence in the phase never discards the
//! anchor (`have_anchor` is separate from `phase`), so the display keeps
//! running during re-acquisition. Only a genuine stop discards it -- nothing
//! is counting, so there is nothing to extrapolate from.
//!
//! ## No scheduling here
//!
//! This module used to also decide *when* to poll -- fast while searching,
//! throttled once locked, staggered to guarantee phase diversity. That is
//! gone: `bluray.zig` now runs a small pool of poller threads on a fixed,
//! staggered cadence of its own (see `bluray.poll_workers` /
//! `bluray.frame_interval_ms`), dispatching continuously rather than reacting
//! to an estimate of when a poll is "due". The phase diversity the old
//! staggered schedule existed to guarantee falls out of that pool for free --
//! `poll_workers * frame_interval_ms` is not a multiple of 1000 ms, so
//! successive samples from any one worker sweep the counter's second on their
//! own. This module is left with exactly the job its own doc above describes:
//! fold a timestamped sample into the running interval, and predict.
//!
//! This module is deliberately free of I/O so the state machine can be tested
//! deterministically.

const std = @import("std");

/// Whether the model error interval has been narrowed enough to trust.
pub const Phase = enum { searching, locked };

/// Target half-width of the error interval: reaching it means `locked`.
pub const edge_guard_ms: i64 = 75;
/// Half-width of slack added to every per-sample interval, absorbing
/// timestamp jitter so honest samples cannot produce a spuriously empty
/// intersection. Also the floor the interval converges toward.
pub const strobe_margin_ms: i64 = 30;
/// Ignore interval midpoints smaller than this when re-centering a locked
/// anchor. Sub-jitter nudges would move the anchor a few ms every second,
/// each one a logged "anchor changed" event, for no visible benefit.
pub const recenter_deadband_ms: i64 = 8;

const eps_unset: i64 = 1_000_000;

pub const PhaseLock = struct {
    phase: Phase,
    /// Wall-clock ms at which the counter became `anchor_sec`.
    anchor_ms: i64,
    anchor_sec: u32,
    /// Half-width of the error interval when the anchor was last applied: how
    /// uncertain the anchor is.
    anchor_err_ms: i64,
    /// When the anchor last changed, for the logs.
    locked_at_ms: i64,
    /// Whether an anchor exists at all, independent of whether its phase is
    /// currently trusted.
    ///
    /// Once anchored even roughly, the model keeps running from that anchor
    /// -- free-wheeling -- through re-acquisition and network trouble. Only a
    /// real discontinuity throws it away. Without this, a lost lock sent the
    /// display back to the last raw sample, which changes only when a poll
    /// lands: the clock visibly stalled and then jumped.
    have_anchor: bool,
    /// The running intersection of per-sample error intervals, in ms of model
    /// error relative to the current anchor (positive = the player is ahead
    /// of the model). Valid only while `have_anchor`.
    eps_lo_ms: i64,
    eps_hi_ms: i64,

    pub const init: PhaseLock = .{
        .phase = .searching,
        .anchor_ms = 0,
        .anchor_sec = 0,
        .anchor_err_ms = 0,
        .locked_at_ms = 0,
        .have_anchor = false,
        .eps_lo_ms = -eps_unset,
        .eps_hi_ms = eps_unset,
    };

    pub fn isLocked(self: *const PhaseLock) bool {
        return self.phase == .locked;
    }

    /// Whether `predict` has anything to extrapolate from.
    pub fn hasAnchor(self: *const PhaseLock) bool {
        return self.have_anchor;
    }

    fn strobeReset(self: *PhaseLock) void {
        self.eps_lo_ms = -eps_unset;
        self.eps_hi_ms = eps_unset;
    }

    /// Stop trusting the phase and start narrowing a fresh error interval,
    /// while the existing anchor carries on driving the display.
    ///
    /// Losing the phase does not mean the counter stopped counting, so the
    /// best available estimate is still the old anchor run forward.
    /// Discarding it here would stall the display for the length of the
    /// re-acquisition.
    pub fn drop(self: *PhaseLock) void {
        self.phase = .searching;
        self.strobeReset();
    }

    /// Throw the anchor away entirely.
    ///
    /// Only for a genuine discontinuity -- the counter stopped -- where
    /// nothing about the old model applies any more and free-wheeling from it
    /// would confidently display a time that is simply wrong.
    pub fn reset(self: *PhaseLock) void {
        self.drop();
        self.have_anchor = false;
        self.anchor_err_ms = 0;
    }

    /// Re-point the anchor at a fresh sample without claiming to know the
    /// phase.
    ///
    /// For a seek or any jump of more than a second: the counter is still
    /// running, but the old anchor's *value* is now wrong, so free-wheeling
    /// from it would show the wrong time. The counter reached `value_sec` at
    /// some point in the second before the sample, uniformly distributed, so
    /// the expected edge is half a second back; anchoring there is correct to
    /// within +-500 ms immediately, and the estimator tightens it from there
    /// -- far better than stalling the display until re-acquisition finishes.
    fn rebase(self: *PhaseLock, sample_ms: i64, value_sec: u32) void {
        self.drop();
        self.anchor_ms = sample_ms - 500;
        self.anchor_sec = value_sec;
        self.anchor_err_ms = 500;
        self.have_anchor = true;
        self.locked_at_ms = sample_ms;
    }

    /// Anchor immediately on the first sample taken after playback resumes.
    ///
    /// The counter restarts at an unrelated phase and often an unrelated
    /// position, so the old anchor was rightly discarded by `reset` -- but
    /// the display must not sit frozen waiting for a full re-acquisition at
    /// exactly the moment someone just pressed play. Same operation as
    /// `rebase`; named separately because the caller reasons about it
    /// differently, and conflating them once obscured that stalling here was
    /// ever a choice.
    pub fn resumed(self: *PhaseLock, sample_ms: i64, value_sec: u32) void {
        self.rebase(sample_ms, value_sec);
    }

    /// Predicted counter value at `at_ms`, or `fallback` when there is no
    /// anchor to extrapolate from.
    pub fn predict(self: *const PhaseLock, at_ms: i64, fallback: u32) u32 {
        if (!self.have_anchor) return fallback;
        const elapsed_ms = at_ms - self.anchor_ms;
        if (elapsed_ms < 0) return self.anchor_sec;
        return self.anchor_sec +| @as(u32, @intCast(@divFloor(elapsed_ms, 1000)));
    }

    /// Record that the source is not running. Nothing is counting, and
    /// resuming restarts the tick at an unrelated phase, so the anchor is
    /// void rather than merely untrusted -- there is nothing to free-wheel.
    pub fn sampleStopped(self: *PhaseLock) void {
        self.reset();
    }

    /// Fold one sample taken while the source is running into the estimate.
    ///
    /// `sample_ms` is the best estimate of when the source read its own
    /// clock; for a request/response exchange that is the midpoint of the
    /// two. Every running sample carries the same kind of evidence and is
    /// treated identically regardless of which poller produced it.
    pub fn sampleRunning(self: *PhaseLock, sample_ms: i64, value_sec: u32) void {
        // The very first running sample seeds the anchor outright. Waiting
        // for the estimate to tighten first would leave the display stalled
        // on a cold start; +-500 ms immediately beats perfect eventually.
        if (!self.have_anchor) {
            self.rebase(sample_ms, value_sec);
            return;
        }

        const drift = @as(i64, value_sec) - @as(i64, self.predict(sample_ms, value_sec));
        if (drift < -1 or drift > 1) {
            // A jump to somewhere else entirely: seek, chapter skip, trick
            // play. The anchor's value is wrong, not just its phase, so
            // re-point it at this sample rather than letting the estimator
            // try to express a multi-second shift as an interval.
            self.rebase(sample_ms, value_sec);
            return;
        }

        // The sample's statement about the model error, as an interval:
        // the counter reached `value_sec` within the second before the
        // sample, so the model is off by between (drift-1) and drift seconds,
        // narrowed by where in the modelled second the sample landed.
        const into = @mod(sample_ms - self.anchor_ms, 1000);
        const lo = drift * 1000 - into - strobe_margin_ms;
        const hi = drift * 1000 + 1000 - into + strobe_margin_ms;

        const new_lo = @max(self.eps_lo_ms, lo);
        const new_hi = @min(self.eps_hi_ms, hi);
        if (new_hi < new_lo) {
            // Inconsistent with the accumulated evidence: the phase moved
            // under us -- a sub-second pause, a tiny seek, or enough clock
            // drift to have accumulated past the margin. The anchor keeps
            // free-wheeling the display; the evidence restarts from this
            // sample alone and re-tightens around the new phase.
            self.phase = .searching;
            self.eps_lo_ms = lo;
            self.eps_hi_ms = hi;
            return;
        }
        self.eps_lo_ms = new_lo;
        self.eps_hi_ms = new_hi;

        const width = new_hi - new_lo;
        if (width <= 2 * edge_guard_ms) {
            // Tight enough to act on. Re-centre the anchor on the interval's
            // midpoint and shift the interval into the new coordinates, so
            // evidence keeps accumulating across the correction instead of
            // starting over.
            const mid = @divFloor(new_lo + new_hi, 2);
            if (@abs(mid) >= recenter_deadband_ms or self.phase != .locked) {
                self.anchor_ms -= mid;
                self.eps_lo_ms = new_lo - mid;
                self.eps_hi_ms = new_hi - mid;
                self.locked_at_ms = sample_ms;
            }
            self.anchor_err_ms = @max(@divFloor(width, 2), 10);
            self.phase = .locked;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: a simulated player driving the state machine deterministically.
// ---------------------------------------------------------------------------

/// Mirrors `bluray.poll_workers` / `bluray.frame_interval_ms`: these tests
/// exercise the phase diversity that pool actually produces, not an idealized
/// stand-in for it.
const sim_workers: usize = 5;
const sim_frame_interval_ms: i64 = 250;
/// Mirrors `bluray.poll_stagger_step_ms` / `poll_stagger_cycle`.
///
/// 250 ms divides 1000 ms evenly, so a worker cycling at an exact multiple of
/// it -- `sim_workers * sim_frame_interval_ms` -- would have every one of its
/// own samples land at one of only 4 fixed points in the counter's second,
/// forever. The best intersection those 4 points can ever produce is wider
/// than `edge_guard_ms` (worked out by hand: a 250 ms-spaced, evenly-covering
/// set leaves a 250 ms gap plus the margin on each side), so without this the
/// lock would never acquire at all in a jitter-free simulation -- the exact
/// failure mode "the estimator survives a round trip that divides the second
/// exactly" exists to catch. A small varying jitter added to each cycle
/// breaks the alignment, the same way the old design's per-poll stagger did.
const sim_stagger_step_ms: i64 = 17;
const sim_stagger_cycle: u32 = 5;

const WorkerState = enum { idle, in_flight };

/// A source whose counter advances only while running, sampled by
/// `sim_workers` independent pollers each looping on its own
/// `sim_workers * sim_frame_interval_ms` cycle, staggered from each other by
/// `sim_frame_interval_ms` -- i.e. the same ring `bluray.zig` actually runs,
/// not a single sequential poller.
///
/// Requests genuinely overlap: a worker's dispatch and its completion are
/// separate events, and other workers can dispatch (or complete) in between.
/// This matters whenever `rtt_ms` exceeds the stagger spacing -- the real
/// measured hardware case -- because processing one worker's exchange fully
/// before considering the next would silently serialize the pool, collapsing
/// every worker onto the same phase and defeating the whole point of running
/// more than one.
const Sim = struct {
    now_ms: i64 = 0,
    /// Content time in ms; the reported value is this truncated to seconds.
    content_ms: i64 = 0,
    running: bool = true,
    /// Simulated round-trip time; the sample instant is the midpoint.
    rtt_ms: i64 = 20,
    /// Content-time rate relative to wall-clock time, in thousandths: `1000`
    /// is normal 1x forward playback, `-3000` is a 3x reverse scan. Trick
    /// play still reports "playing" on the real device, so it is a property
    /// of how `content_ms` moves, not of `running`.
    content_rate_permille: i64 = 1000,

    /// Each worker's next event instant: a dispatch time while `.idle`, a
    /// completion time while `.in_flight`. Lazily staggered on first use
    /// rather than in a default field value, since the stagger is relative to
    /// wherever `now_ms` starts.
    next_event_ms: [sim_workers]i64 = undefined,
    worker_state: [sim_workers]WorkerState = .{.idle} ** sim_workers,
    /// Snapshot taken at dispatch, so a completion can compute its sample's
    /// value at the midpoint without rewinding `content_ms`, which -- like
    /// the real clock it stands in for -- only ever moves forward.
    dispatch_ms: [sim_workers]i64 = undefined,
    content_at_dispatch: [sim_workers]i64 = undefined,
    running_at_dispatch: [sim_workers]bool = undefined,
    rate_at_dispatch: [sim_workers]i64 = undefined,
    started: bool = false,
    /// Shared across every worker: see `sim_stagger_step_ms`.
    stagger: u32 = 0,

    fn reported(self: Sim) u32 {
        return @intCast(@divFloor(self.content_ms, 1000));
    }

    fn advance(self: *Sim, dt_ms: i64) void {
        self.now_ms += dt_ms;
        if (self.running) {
            self.content_ms += @divTrunc(dt_ms * self.content_rate_permille, 1000);
        }
    }

    /// Advance the pool by exactly one folded sample. Internally this may
    /// process several events -- other workers dispatching while one is
    /// still in flight -- but always returns as soon as one completion has
    /// been folded in, so callers see the same "one step, one sample"
    /// contract as before.
    fn step(self: *Sim, lock: *PhaseLock) void {
        if (!self.started) {
            self.started = true;
            for (&self.next_event_ms, 0..) |*t, i| {
                t.* = self.now_ms + @as(i64, @intCast(i)) * sim_frame_interval_ms;
            }
        }

        while (true) {
            var idx: usize = 0;
            for (self.next_event_ms[1..], 1..) |t, i| {
                if (t < self.next_event_ms[idx]) idx = i;
            }

            const wait = self.next_event_ms[idx] - self.now_ms;
            if (wait > 0) self.advance(wait);

            switch (self.worker_state[idx]) {
                .idle => {
                    self.dispatch_ms[idx] = self.now_ms;
                    self.content_at_dispatch[idx] = self.content_ms;
                    self.running_at_dispatch[idx] = self.running;
                    self.rate_at_dispatch[idx] = self.content_rate_permille;
                    self.worker_state[idx] = .in_flight;
                    self.next_event_ms[idx] = self.now_ms + self.rtt_ms;
                },
                .in_flight => {
                    const half = @divFloor(self.rtt_ms, 2);
                    const sample_ms = self.dispatch_ms[idx] + half;
                    const running = self.running_at_dispatch[idx];
                    const content_at_sample = self.content_at_dispatch[idx] +
                        (if (running) @divTrunc(half * self.rate_at_dispatch[idx], 1000) else 0);
                    const value: u32 = @intCast(@divFloor(content_at_sample, 1000));

                    self.worker_state[idx] = .idle;
                    // Back on cycle if the round trip left slack, immediately
                    // if it ran long -- mirrors `bluray.pollWorker`'s own
                    // catch-up behavior. The jitter keeps the cycle from ever
                    // being an exact, repeating multiple of
                    // `sim_frame_interval_ms`; see `sim_stagger_step_ms`.
                    const jitter = sim_stagger_step_ms * @as(i64, @intCast(self.stagger % sim_stagger_cycle));
                    self.stagger +%= 1;
                    const cycle_ms = @as(i64, @intCast(sim_workers)) * sim_frame_interval_ms + jitter;
                    self.next_event_ms[idx] = @max(self.dispatch_ms[idx] + cycle_ms, self.now_ms);

                    if (running) {
                        lock.sampleRunning(sample_ms, value);
                    } else {
                        lock.sampleStopped();
                    }
                    return;
                },
            }
        }
    }

    fn stepN(self: *Sim, lock: *PhaseLock, n: usize) void {
        for (0..n) |_| self.step(lock);
    }
};

/// Signed difference, in ms, between the model's tick edges and the real
/// ones, wrapped to (-500, 500]. This is the quantity that actually matters:
/// it is how early or late the displayed second flips.
fn phaseErrorMs(sim: *const Sim, lock: *const PhaseLock) i64 {
    // Most recent real edge at or before now.
    const real_edge = sim.now_ms - @mod(sim.content_ms, 1000);
    // Most recent modelled edge at or before now.
    const model_edge = lock.anchor_ms + @divFloor(sim.now_ms - lock.anchor_ms, 1000) * 1000;
    return @mod(model_edge - real_edge + 500, 1000) - 500;
}

/// The lock must be held, its edges must line up with the real ones, and --
/// the part that actually reaches the display -- the predicted second must be
/// the real one, not a whole second out.
fn expectInSync(sim: *const Sim, lock: *const PhaseLock) !void {
    try std.testing.expect(lock.isLocked());
    const err_ms = phaseErrorMs(sim, lock);
    if (@abs(err_ms) > edge_guard_ms) {
        std.debug.print("phase error {d} ms exceeds guard {d} ms\n", .{ err_ms, edge_guard_ms });
        return error.PhaseErrorTooLarge;
    }
    // Away from an edge the predicted second must match exactly.
    const into_second = @mod(sim.content_ms, 1000);
    if (into_second > 200 and into_second < 800) {
        try std.testing.expectEqual(sim.reported(), lock.predict(sim.now_ms, 0));
    }
}

test "acquires lock quickly from cold start" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 12_345 };

    // A few dozen staggered samples from the poll-worker pool narrows the
    // interval well past the guard.
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
    try std.testing.expect(lock.anchor_err_ms <= edge_guard_ms);
}

test "the first sample seeds the anchor so a cold start never stalls" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 500_000 + 321 };

    sim.step(&lock);
    // One sample in: not locked yet, but the display already has a value
    // correct to within a second, and it advances from here.
    try std.testing.expect(lock.hasAnchor());
    const shown = lock.predict(sim.now_ms, 0);
    try std.testing.expect(@abs(@as(i64, shown) - @as(i64, sim.reported())) <= 1);
}

test "stays locked and in sync over a long run" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 1_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    for (0..300) |_| {
        sim.step(&lock);
        if (lock.isLocked()) try expectInSync(&sim, &lock);
    }
    try expectInSync(&sim, &lock);
}

test "re-locks after a pause that is never observed as paused status" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 5_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
    const anchor_before = lock.anchor_ms;

    // Paused ~400 ms between two polls: content falls behind the wall clock,
    // shifting the tick phase, but the status never read "paused". The next
    // samples contradict the accumulated interval, evidence restarts, and the
    // estimate re-centers on the shifted phase.
    sim.content_ms -= 400;

    sim.stepN(&lock, 40);
    try std.testing.expect(lock.anchor_ms != anchor_before);
    sim.stepN(&lock, 20);
    try expectInSync(&sim, &lock);
}

test "small phase shifts are caught, not silently tolerated" {
    // A whole-second drift tolerance would absorb every one of these and
    // leave the display permanently offset.
    for ([_]i64{ 120, 250, 400, 600, 900 }) |shift_ms| {
        var lock = PhaseLock.init;
        var sim: Sim = .{ .content_ms = 30_000 };
        sim.stepN(&lock, 40);
        try expectInSync(&sim, &lock);

        sim.content_ms -= shift_ms;
        sim.stepN(&lock, 50);
        try expectInSync(&sim, &lock);
    }
}

test "whole-second shifts are caught, not hidden by an intact phase" {
    // A pause or rewind of close to a whole number of seconds leaves the tick
    // phase intact while every reported value moves -- the case that requires
    // value evidence, not just phase evidence. The interval expresses both.
    for ([_]i64{ 1000, 2000, 5000, 1005, 995, -1000, -3000 }) |shift_ms| {
        var lock = PhaseLock.init;
        var sim: Sim = .{ .content_ms = 90_000 };
        sim.stepN(&lock, 40);
        try expectInSync(&sim, &lock);

        sim.content_ms -= shift_ms;
        sim.stepN(&lock, 50);
        try expectInSync(&sim, &lock);
    }
}

test "a detected jump corrects the displayed value immediately" {
    // A jump of more than a second must not wait out a re-acquisition while
    // the display free-wheels from the stale anchor: the sample that caught
    // it is itself fresh ground truth, and rebase uses it on the spot.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 90_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    sim.content_ms -= 5_000;
    while (lock.isLocked()) sim.step(&lock);

    const shown = lock.predict(sim.now_ms, 0);
    const err = @abs(@as(i64, shown) - @as(i64, sim.reported()));
    try std.testing.expect(err <= 1);
}

test "recovers from an explicit pause and resume" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 8_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    // Pause: the anchor must be discarded, since nothing is counting.
    sim.running = false;
    sim.stepN(&lock, 3);
    try std.testing.expect(!lock.isLocked());
    try std.testing.expect(!lock.hasAnchor());

    // Resume at an arbitrary phase offset from the old one.
    sim.advance(1_337);
    sim.running = true;
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
}

test "recovers from a pause and resume that lands on the same phase" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 45_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    sim.running = false;
    sim.advance(4_000); // exactly four seconds, phase preserved
    sim.running = true;

    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
}

test "recovers from a seek while playing" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    sim.content_ms += 1_800_000 + 137;
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
}

test "recovers from a rewind of a whole number of seconds" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 600_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    sim.content_ms -= 30_000;
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
}

test "a chapter jump back reacquires the exact value, not off by one" {
    // A value error with correct phase is the failure mode that used to
    // survive; `expectInSync` asserts exact equality away from the edges,
    // where no rounding ambiguity can excuse an off-by-one.
    const jumps = [_]i64{ 600_000 - 411, 600_000, 123_456 };
    for (jumps) |jump_ms| {
        for (0..3) |pre_steps| {
            var lock = PhaseLock.init;
            var sim: Sim = .{ .content_ms = 3_000_000 };
            sim.stepN(&lock, 50);
            try expectInSync(&sim, &lock);
            sim.stepN(&lock, pre_steps);

            sim.content_ms -= jump_ms;
            sim.stepN(&lock, 50);
            try expectInSync(&sim, &lock);

            for (0..60) |_| {
                sim.step(&lock);
                try expectInSync(&sim, &lock);
            }
        }
    }
}

test "reacquire through a transient stop during the jump lands on the exact value" {
    // A chapter jump can pass through a momentary Stopped report while the
    // player repositions. That path runs reset() and then the resumed() +
    // sampleRunning() pair that `bluray.recordSample` performs -- replicated
    // here literally, since that sequencing lives in bluray.zig outside Sim.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 3_000_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    sim.running = false;
    sim.stepN(&lock, 2);
    try std.testing.expect(!lock.hasAnchor());

    sim.content_ms -= 600_000 - 411;
    sim.running = true;

    sim.advance(10);
    const sample_ms = sim.now_ms;
    const value = sim.reported();
    sim.advance(10);
    lock.resumed(sample_ms, value);
    lock.sampleRunning(sample_ms, value);

    // Roughly right immediately (resumed's job)...
    const shown = lock.predict(sim.now_ms, 0);
    try std.testing.expect(@abs(@as(i64, shown) - @as(i64, sim.reported())) <= 1);

    // ...exactly right once reacquired, staying so.
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);
    for (0..60) |_| {
        sim.step(&lock);
        try expectInSync(&sim, &lock);
    }
}

test "a sustained rewind is tracked, not stuck extrapolating forward" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 60_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    // Rewind at 3x for several seconds. The content position falls 3 seconds
    // for every wall second; rebases on |drift| > 1 keep the shown value
    // chasing the true, falling position instead of running away from it.
    // Between two polls the model free-wheels forward (+1x) while truth runs
    // backward (-3x), so a transient error of 2 right before the next rebase
    // catches up is inherent to the sampling rate, not a tracking failure --
    // what must never happen is the old bug, where the error grew without
    // bound for the whole duration of the scan.
    sim.content_rate_permille = -3000;

    for (0..40) |_| {
        sim.step(&lock);
        if (lock.hasAnchor()) {
            const shown = lock.predict(sim.now_ms, sim.reported());
            const err = @abs(@as(i64, shown) - @as(i64, sim.reported()));
            try std.testing.expect(err <= 2);
        }
    }
}

test "the clock keeps running while the lock is being re-acquired" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 40_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    const anchor_before = lock.anchor_ms;
    lock.drop();
    try std.testing.expect(!lock.isLocked());
    try std.testing.expect(lock.hasAnchor());
    // The anchor itself is untouched by drop -- only confidence in the phase
    // is -- so the display does not stall or jump the instant this fires
    // (e.g. the "Force PLL Resync" button on the web page).
    try std.testing.expectEqual(anchor_before, lock.anchor_ms);

    var previous = lock.predict(sim.now_ms, 0);
    var advanced: usize = 0;
    for (0..40) |_| {
        sim.step(&lock);
        const shown = lock.predict(sim.now_ms, 0);
        try std.testing.expect(shown >= previous); // never stalls backwards
        if (shown > previous) advanced += 1;
        const truth = sim.reported();
        const err = @abs(@as(i64, shown) - @as(i64, truth));
        try std.testing.expect(err <= 1);
        previous = shown;
    }
    try std.testing.expect(advanced >= 2);
    try expectInSync(&sim, &lock);
}

test "resumed anchors immediately rather than stalling like a bare reset" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 10_000 };
    sim.stepN(&lock, 50);
    try expectInSync(&sim, &lock);

    lock.reset();
    try std.testing.expect(!lock.hasAnchor());

    const resume_sample_ms: i64 = sim.now_ms + 5_000;
    const resume_value: u32 = 500;
    lock.resumed(resume_sample_ms, resume_value);

    try std.testing.expect(lock.hasAnchor());
    try std.testing.expectEqual(resume_value, lock.predict(resume_sample_ms, 0));

    var advanced = false;
    var t = resume_sample_ms;
    while (t < resume_sample_ms + 3_000) : (t += 100) {
        if (lock.predict(t, 0) > resume_value) advanced = true;
    }
    try std.testing.expect(advanced);
}

test "a stop discards the anchor rather than free-wheeling past it" {
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 12_000 };
    sim.stepN(&lock, 40);
    try std.testing.expect(lock.hasAnchor());

    lock.sampleStopped();
    try std.testing.expect(!lock.hasAnchor());
    try std.testing.expectEqual(@as(u32, 99), lock.predict(sim.now_ms, 99));
}

test "a slow round trip still locks, with the same accuracy" {
    // (gap + rtt) / 2 = 130 ms here: the old edge-bracketing design could
    // only lock this after a long patience fallback, and then loosely. The
    // interval estimator does not care about sample spacing at all.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 3_000, .rtt_ms = 200 };

    sim.stepN(&lock, 60);
    try std.testing.expect(lock.isLocked());
    try std.testing.expect(lock.anchor_err_ms <= edge_guard_ms);
    try expectInSync(&sim, &lock);
}

test "a one-second round trip locks via interval intersection" {
    // The measured hardware reality that forced this design: the player
    // answers cCMD_PST in ~1000 ms while a disc plays. No two samples can
    // ever land close together in time, so nothing bracket-shaped can work;
    // the hardware log showed the old design hunting forever on a rebase-luck
    // anchor, tolerating a permanent error of up to a second. The interval
    // estimator locks anyway, because the staggered poll-worker pool sweeps
    // the sample instants across the counter's second regardless.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 2_216_350, .rtt_ms = 1000 };

    for (0..120) |_| sim.step(&lock);
    try std.testing.expect(lock.isLocked());

    // Locked and exactly right, and it stays that way.
    var locked_steps: usize = 0;
    for (0..60) |_| {
        sim.step(&lock);
        if (lock.isLocked()) {
            locked_steps += 1;
            try expectInSync(&sim, &lock);
        }
    }
    try std.testing.expect(locked_steps >= 55);
}

test "the estimator survives a round trip that divides the second exactly" {
    // rtt=2000 exceeds the pool's target cycle (sim_workers * frame_interval,
    // 1250 ms), so every worker overruns to a period of exactly its own rtt --
    // a whole number of seconds. Each worker's own successive samples would
    // then freeze at the same point of the counter's second forever; what
    // saves it is that the pool has more than one worker, each started
    // `sim_frame_interval_ms` apart, so their frozen offsets still differ from
    // each other. A single sequential poller has no such fallback, which is
    // exactly why one is no longer used.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 7_777, .rtt_ms = 2000 };

    for (0..120) |_| sim.step(&lock);
    try std.testing.expect(lock.isLocked());
    try expectInSync(&sim, &lock);
}

test "slow clock drift is followed without ever being visibly wrong" {
    // The Pi's clock and the player's clock tick at minutely different rates.
    // Accumulated drift eventually contradicts the interval, which restarts
    // the evidence and re-centers -- a few-ms correction, not a visible jump.
    var lock = PhaseLock.init;
    var sim: Sim = .{ .content_ms = 10_000, .content_rate_permille = 1001 };
    sim.stepN(&lock, 40);

    for (0..300) |_| {
        sim.step(&lock);
        if (lock.hasAnchor()) {
            try std.testing.expect(@abs(phaseErrorMs(&sim, &lock)) <= 150);
            const into_second = @mod(sim.content_ms, 1000);
            if (into_second > 250 and into_second < 750) {
                try std.testing.expectEqual(sim.reported(), lock.predict(sim.now_ms, 0));
            }
        }
    }
}

test "predict falls back only when there is no anchor at all" {
    var lock = PhaseLock.init;
    try std.testing.expectEqual(@as(u32, 42), lock.predict(1_000_000, 42));
}
