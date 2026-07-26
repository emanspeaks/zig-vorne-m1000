const std = @import("std");
const Io = std.Io;

const PID_FILE_PATH = "/tmp/zig_vorne_m1000.pid";

var should_shutdown = std.atomic.Value(bool).init(false);

/// Signal handler for graceful shutdown
fn signalHandler(sig: std.os.linux.SIG) callconv(.c) void {
    _ = sig;
    std.debug.print("\nReceived shutdown signal, terminating gracefully...\n", .{});
    requestShutdown();
}

/// Manual shutdown trigger (can be called by signal handlers or other mechanisms)
pub fn requestShutdown() void {
    should_shutdown.store(true, .release);
}

/// Check if we should shutdown (called from main loops)
pub fn shouldShutdown() bool {
    return should_shutdown.load(.acquire);
}

/// Write current process PID to file
fn writePidFile(io: Io) !void {
    const pid = std.os.linux.getpid();

    var buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = PID_FILE_PATH, .data = pid_str });
}

/// Read PID from file, return null if file doesn't exist or invalid
fn readPidFile(io: Io, allocator: std.mem.Allocator) ?std.process.Child.Id {
    const content = Io.Dir.cwd().readFileAlloc(io, PID_FILE_PATH, allocator, .limited(1024)) catch return null;
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    return std.fmt.parseInt(std.process.Child.Id, trimmed, 10) catch null;
}

/// Check if process with given PID is still running
fn isProcessRunning(pid: std.process.Child.Id) bool {
    // Try to send signal 0 to check if process exists without actually sending a signal.
    // `SIG` is a non-exhaustive enum with no name for 0, so build it from the integer.
    const result = std.os.linux.kill(@intCast(pid), @enumFromInt(0));
    return result == 0;
}

/// Remove PID file
fn removePidFile(io: Io) void {
    Io.Dir.cwd().deleteFile(io, PID_FILE_PATH) catch {};
}

/// Setup signal handlers for instance management
pub fn setup() !void {
    // Install signal handlers using sigaction
    var sa = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };

    _ = std.os.linux.sigaction(.TERM, &sa, null);
    _ = std.os.linux.sigaction(.INT, &sa, null);
}

/// Check for existing instance and handle it
pub fn checkExistingInstance(io: Io, allocator: std.mem.Allocator) !void {
    if (readPidFile(io, allocator)) |existing_pid| {
        if (isProcessRunning(existing_pid)) {
            std.debug.print("Found existing instance (PID: {d}), sending termination signal...\n", .{existing_pid});

            // Send SIGTERM to existing process
            const term_result = std.os.linux.kill(@intCast(existing_pid), .TERM);
            if (term_result != 0) {
                std.debug.print("Failed to send signal to existing instance\n", .{});
                return;
            }

            // Wait up to 5 seconds for the process to terminate
            var attempts: u8 = 0;
            while (attempts < 50) : (attempts += 1) {
                try io.sleep(.fromMilliseconds(100), .awake);
                if (!isProcessRunning(existing_pid)) {
                    std.debug.print("Existing instance terminated successfully.\n", .{});
                    break;
                }
            }

            if (isProcessRunning(existing_pid)) {
                std.debug.print("Existing instance did not terminate, sending SIGKILL...\n", .{});
                _ = std.os.linux.kill(@intCast(existing_pid), .KILL);
                try io.sleep(.fromMilliseconds(500), .awake);
            }
        } else {
            std.debug.print("Stale PID file found, removing...\n", .{});
        }
        removePidFile(io);
    }

    // Write our PID to file
    try writePidFile(io);
}

/// Cleanup on exit
pub fn cleanup(io: Io) void {
    removePidFile(io);
}
