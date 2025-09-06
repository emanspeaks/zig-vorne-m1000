const std = @import("std");
const http = std.http;
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const clocks = @import("clocks.zig");
const bluray = @import("bluray.zig");
const vlc = @import("vlc.zig");
const process_mgmt = @import("process_mgmt.zig");
const Mode = @import("mode.zig").Mode;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Setup signal handlers and check for existing instances
    try process_mgmt.setup();
    try process_mgmt.checkExistingInstance(allocator);
    defer process_mgmt.cleanup();

    // Parse command-line arguments for optional modes
    var bluray_flag = false;
    var vlc_flag = false;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--bluray")) {
                bluray_flag = true;
            } else if (std.mem.eql(u8, arg, "--vlc")) {
                vlc_flag = true;
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

    var mode = std.atomic.Value(Mode).init(.Clocks);
    if (bluray_flag) {
        mode.store(.Bluray, .release);
    } else if (vlc_flag) {
        mode.store(.Vlc, .release);
    }

    // Shared mode state

    // Start HTTP server in a separate thread
    const server_thread = try std.Thread.spawn(.{}, startHttpServer, .{ allocator, port, &mode });
    server_thread.detach();

    // Main display loop
    while (true) {
        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Main loop received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        const current_mode = mode.load(.acquire);
        if (current_mode == .Clocks) {
            try clocks.runClocks(allocator, port, &mode);
        } else if (current_mode == .Bluray) {
            try bluray.runBlurayClocks(allocator, port, &mode);
        } else if (current_mode == .Vlc) {
            try vlc.runVlcClocks(allocator, port, &mode);
        }
    }
}

fn startHttpServer(allocator: std.mem.Allocator, port: *serial.SerialPort, mode: *std.atomic.Value(Mode)) !void {
    const address = std.net.Address.parseIp("0.0.0.0", 8080) catch unreachable;
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    std.debug.print("HTTP server listening on port 8080\n", .{});

    while (true) {
        const conn = try listener.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ allocator, conn, port, mode });
        thread.detach();
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection, serial_port: *serial.SerialPort, mode: *std.atomic.Value(Mode)) !void {
    defer conn.stream.close();

    var buffer: [1024]u8 = undefined;
    const n = try conn.stream.read(&buffer);
    const request = buffer[0..n];

    // Simple HTTP request parsing
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    const request_line = lines.next() orelse return;
    var parts = std.mem.splitSequence(u8, request_line, " ");
    const method = parts.next() orelse return;
    const path = parts.next() orelse return;

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) {
        const current_mode = mode.load(.acquire);
        const mode_str = switch (current_mode) {
            .Clocks => "Clocks",
            .Bluray => "Blu-Ray",
            .Vlc => "VLC",
        };
        const html_body = std.fmt.allocPrint(allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\<title>Serial Display Control</title>
            \\</head>
            \\<body>
            \\<h1>Serial Display Control</h1>
            \\<p>Current Mode: {s}</p>
            \\<form action="/mode" method="post">
            \\<button type="submit" name="mode" value="clocks">Switch to Clocks</button>
            \\<button type="submit" name="mode" value="bluray">Switch to Blu-Ray</button>
            \\<button type="submit" name="mode" value="vlc">Switch to VLC</button>
            \\</form>
            // \\<form action="/control" method="post">
            // \\<label for="text">Display Text:</label>
            // \\<input type="text" id="text" name="text" maxlength="100">
            // \\<button type="submit" name="action" value="display">Display</button>
            // \\</form>
            \\<form action="/control" method="post">
            // \\<button type="submit" name="action" value="flush">Flush</button>
            \\<button type="submit" name="action" value="init">Init</button>
            \\</form>
            \\</body>
            \\</html>
        , .{mode_str}) catch return;
        defer allocator.free(html_body);
        const headers = std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\n\r\n", .{html_body.len}) catch return;
        defer allocator.free(headers);
        _ = try conn.stream.write(headers);
        _ = try conn.stream.write(html_body);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/control")) {
        // Find the body
        var body_start: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                body_start = @intFromPtr(line.ptr) - @intFromPtr(request.ptr) + line.len + 2;
                break;
            }
        }
        const body = request[body_start..];

        var action: []const u8 = "";
        var text: []const u8 = "";

        // Simple form parsing
        var iter = std.mem.splitSequence(u8, body, "&");
        while (iter.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "action=")) {
                action = pair[7..];
            } else if (std.mem.startsWith(u8, pair, "text=")) {
                text = pair[5..];
                // URL decode
                text = std.mem.replaceOwned(u8, allocator, text, "+", " ") catch text;
            }
        }

        if (std.mem.eql(u8, action, "display")) {
            protocol.sendUnitDisplayCmd(allocator, serial_port, 1, text) catch |err| {
                std.debug.print("Error sending display command: {}\n", .{err});
            };
            // } else if (std.mem.eql(u8, action, "flush")) {
            //     protocol.sendUnitFlushCmd(allocator, serial_port, 1) catch |err| {
            //         std.debug.print("Error sending flush command: {}\n", .{err});
            //     };
        } else if (std.mem.eql(u8, action, "init")) {
            protocol.sendUnitDefaultInitCmd(allocator, serial_port, 1) catch |err| {
                std.debug.print("Error sending init command: {}\n", .{err});
            };
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        _ = try conn.stream.write(response);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/mode")) {
        // Find the body
        var body_start: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                body_start = @intFromPtr(line.ptr) - @intFromPtr(request.ptr) + line.len + 2;
                break;
            }
        }
        const body = request[body_start..];

        var new_mode: []const u8 = "";

        // Simple form parsing
        var iter = std.mem.splitSequence(u8, body, "&");
        while (iter.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "mode=")) {
                new_mode = pair[5..];
            }
        }

        try protocol.sendUnitDefaultInitCmd(allocator, serial_port, 1);
        if (std.mem.eql(u8, new_mode, "clocks")) {
            mode.store(.Clocks, .release);
        } else if (std.mem.eql(u8, new_mode, "bluray")) {
            mode.store(.Bluray, .release);
        } else if (std.mem.eql(u8, new_mode, "vlc")) {
            mode.store(.Vlc, .release);
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        _ = try conn.stream.write(response);
    } else {
        const response = "HTTP/1.1 404 Not Found\r\n\r\n";
        _ = try conn.stream.write(response);
    }
}
