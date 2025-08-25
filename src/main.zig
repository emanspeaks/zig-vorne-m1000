const std = @import("std");
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const clocks = @import("clocks.zig");
const bluray = @import("bluray.zig");
const process_mgmt = @import("process_mgmt.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Setup signal handlers and check for existing instances
    try process_mgmt.setup();
    try process_mgmt.checkExistingInstance(allocator);
    defer process_mgmt.cleanup();

    // Parse command-line arguments for optional modes
    var bluray_mode = false;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--bluray")) {
                bluray_mode = true;
            }
        }
    }

    const ttydev = "/dev/ttyUSB0";
    std.debug.print("Opening {s}...\n", .{ttydev});
    const port = serial.SerialPort.open(ttydev, allocator) catch |err| return err;
    defer port.close(allocator);
    std.debug.print("Serial port opened and configured successfully.\n", .{});

    protocol.sendUnitFlushCmd(allocator, port, 1) catch |err| return err;
    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;
    std.Thread.sleep(1 * std.time.ns_per_s);

    if (bluray_mode) {
        try bluray.runBlurayClocks(allocator, port);
    } else {
        try clocks.runClocks(allocator, port);
    }
}
