const std = @import("std");
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const ttydev = "/dev/ttyUSB0";

    std.debug.print("Opening {s}...\n", .{ttydev});
    const port = serial.SerialPort.open(ttydev, allocator) catch |err| return err;
    defer port.close(allocator);
    std.debug.print("Serial port opened and configured successfully.\n", .{});

    protocol.sendUnitFlushCmd(allocator, port, 1) catch |err| return err;
    // protocol.sendUnitDefaultInitCmd(allocator, port, 1) catch |err| return err;
    // protocol.sendUnitDisplayCmd(allocator, port, 1, "Test from Randy") catch |err| return err;
    // protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "25;-B" ++ protocol.ESC ++ "25;-b" ++ protocol.ESC ++ "2s" ++ protocol.ESC ++ "0;0;119;15w" ++ protocol.ESC ++ "@" ++ protocol.ESC ++ "0;0c" ++ protocol.ESC ++ "0;3H" ++ protocol.ESC ++ "2FTest from randy" ++ protocol.ESC ++ "8;60c" ++ protocol.ESC ++ "20W" ++ protocol.ESC ++ "1W" ++ protocol.ESC ++ "E" ++ protocol.ESC ++ "1G") catch |err| return err;

    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;
    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "0;0;119;15w" ++ "Test from randy 1" ++ protocol.ESC ++ "8;60c") catch |err| return err;
    std.Thread.sleep(1 * std.time.ns_per_s);
    protocol.unitUpdateChar(allocator, port, 1, 1, 17, '2') catch |err| return err;
    std.Thread.sleep(1 * std.time.ns_per_s);
    protocol.unitUpdateChar(allocator, port, 1, 1, 17, '3') catch |err| return err;
}
