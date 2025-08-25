const std = @import("std");

pub const FrameTimer = struct {
    target_fps: f64,
    target_frame_duration_ns: u64,
    max_overrun_ns: u64,
    frame_start_time: i128,
    frame_count: u32,
    overrun_count: u32,
    max_overrun_ns_recorded: u64,
    stats_interval: u32,

    const Self = @This();

    /// Initialize a new frame timer with the specified target FPS
    pub fn init(target_fps: f64) Self {
        const target_frame_duration_ns: u64 = @intFromFloat(std.time.ns_per_s / target_fps);
        return Self{
            .target_fps = target_fps,
            .target_frame_duration_ns = target_frame_duration_ns,
            .max_overrun_ns = target_frame_duration_ns / 4, // 25% overrun threshold
            .frame_start_time = std.time.nanoTimestamp(),
            .frame_count = 0,
            .overrun_count = 0,
            .max_overrun_ns_recorded = 0,
            .stats_interval = 60, // Report stats every 60 frames
        };
    }

    /// Call at the beginning of each frame
    pub fn frameStart(self: *Self) void {
        self.frame_start_time = std.time.nanoTimestamp();
    }

    /// Call at the end of each frame - handles timing and sleep
    pub fn frameEnd(self: *Self) void {
        const frame_end_time = std.time.nanoTimestamp();
        const frame_duration = frame_end_time - self.frame_start_time;
        const target_duration_i128: i128 = @intCast(self.target_frame_duration_ns);

        self.frame_count += 1;

        if (frame_duration < target_duration_i128) {
            // Frame finished early - sleep for remaining time
            const sleep_duration: u64 = @intCast(target_duration_i128 - frame_duration);
            std.Thread.sleep(sleep_duration);
        } else {
            // Frame overrun detected
            const overrun_ns: u64 = @intCast(frame_duration - target_duration_i128);
            self.overrun_count += 1;
            self.max_overrun_ns_recorded = @max(self.max_overrun_ns_recorded, overrun_ns);

            // Log severe overruns
            if (overrun_ns > self.max_overrun_ns) {
                const overrun_ms: f64 = @as(f64, @floatFromInt(overrun_ns)) / 1_000_000.0;
                const target_ms: f64 = @as(f64, @floatFromInt(self.target_frame_duration_ns)) / 1_000_000.0;
                std.debug.print("Frame overrun: {d:.1}ms (target: {d:.1}ms) - frame {}\n", .{ overrun_ms, target_ms, self.frame_count });
            }

            // Skip sleep - start next frame immediately to prevent cascade delays
        }

        // Periodic timing statistics
        if (self.frame_count % self.stats_interval == 0 and self.overrun_count > 0) {
            self.printStats();
            // Clear stats after reporting to track only the last 60 frames
            self.clearStats();
        }
    }

    /// Clear frame statistics (keeps total frame count for reference)
    pub fn clearStats(self: *Self) void {
        self.overrun_count = 0;
        self.max_overrun_ns_recorded = 0;
    }

    /// Print timing statistics for the current interval
    pub fn printStats(self: *Self) void {
        const interval_frames = self.stats_interval;
        const overrun_rate: f64 = @as(f64, @floatFromInt(self.overrun_count)) / @as(f64, @floatFromInt(interval_frames)) * 100.0;
        const max_overrun_ms: f64 = @as(f64, @floatFromInt(self.max_overrun_ns_recorded)) / 1_000_000.0;
        std.debug.print("Frame stats (last {} frames): {}/{} overruns ({d:.1}%), max: {d:.1}ms\n", .{ interval_frames, self.overrun_count, interval_frames, overrun_rate, max_overrun_ms });
    }

    /// Get current frame rate performance info for the current interval
    pub fn getStats(self: *Self) FrameStats {
        const current_interval_frames = (self.frame_count % self.stats_interval);
        const interval_frames = if (current_interval_frames == 0) self.stats_interval else current_interval_frames;

        return FrameStats{
            .total_frames = interval_frames,
            .overrun_frames = self.overrun_count,
            .overrun_rate_percent = if (interval_frames > 0) @as(f64, @floatFromInt(self.overrun_count)) / @as(f64, @floatFromInt(interval_frames)) * 100.0 else 0.0,
            .max_overrun_ms = @as(f64, @floatFromInt(self.max_overrun_ns_recorded)) / 1_000_000.0,
            .target_fps = self.target_fps,
        };
    }

    /// Configure stats reporting interval (0 to disable)
    pub fn setStatsInterval(self: *Self, interval: u32) void {
        self.stats_interval = interval;
    }

    /// Configure overrun warning threshold (as fraction of frame time)
    pub fn setOverrunThreshold(self: *Self, threshold_fraction: f64) void {
        self.max_overrun_ns = @intFromFloat(@as(f64, @floatFromInt(self.target_frame_duration_ns)) * threshold_fraction);
    }
};

pub const FrameStats = struct {
    total_frames: u32,
    overrun_frames: u32,
    overrun_rate_percent: f64,
    max_overrun_ms: f64,
    target_fps: f64,
};
