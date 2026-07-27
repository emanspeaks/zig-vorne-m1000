const std = @import("std");
const Io = std.Io;
const http = std.http;
const protocol = @import("protocol.zig");
const serial = @import("serial.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const clocks = @import("clocks.zig");
const bluray = @import("bluray.zig");
const vlc = @import("vlc.zig");
const process_mgmt = @import("process_mgmt.zig");
const cues = @import("cues.zig");
const dbg = @import("debug_log.zig");
const vorne_config = @import("vorne_config.zig");
// Named to avoid shadowing the `mode` atomic that the loops below pass around.
const mode_mod = @import("mode.zig");
const Mode = mode_mod.Mode;


/// In 0.16 the runtime hands `main` a `std.process.Init`, which carries the
/// `Io` implementation that all blocking I/O (files, sockets, sleeping) now
/// goes through, along with the command-line arguments.
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;

    // The one config file: which diagnostic categories are on, plus the cue
    // directory, player IP and line2_config location. First thing, so that
    // everything below can log through it, and well before any thread exists
    // -- these are read once and thereafter immutable, which is what lets the
    // rest of the program read them with no synchronization.
    vorne_config.load(io, allocator);

    // Make the environment available for the DEBUG_VLC check
    vlc.setEnviron(init.minimal.environ);

    // Setup signal handlers and check for existing instances
    try process_mgmt.setup();
    try process_mgmt.checkExistingInstance(io, allocator);
    defer process_mgmt.cleanup(io);

    // Parse command-line arguments for optional modes
    var bluray_flag = false;
    var vlc_flag = false;
    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bluray")) {
            bluray_flag = true;
        } else if (std.mem.eql(u8, arg, "--vlc")) {
            vlc_flag = true;
        }
    }

    const ttydev = "/dev/ttyUSB0";
    std.debug.print("Opening {s}...\n", .{ttydev});
    const port = serial.SerialPort.open(io, ttydev, allocator) catch |err| return err;
    defer port.close(allocator);
    std.debug.print("Serial port opened and configured successfully.\n", .{});

    protocol.sendUnitFlushCmd(allocator, port, 1) catch |err| return err;
    protocol.sendUnitDisplayCmd(allocator, port, 1, protocol.ESC ++ "E") catch |err| return err;
    try io.sleep(.fromSeconds(1), .awake);

    var mode = std.atomic.Value(Mode).init(.Clocks);
    if (bluray_flag) {
        mode.store(.Bluray, .release);
    } else if (vlc_flag) {
        mode.store(.Vlc, .release);
    }

    // Shared mode state

    // Resolve which directory holds cue files, and any hand-tuned display lead
    // compensation, before any thread that reads them starts. There is no
    // synchronization on either afterward, by design -- both are meant to be
    // set once, here, while still single-threaded.
    cues.configureDirPath(io);
    bluray.configureDisplayLead(io);

    // Which cue file line 2 shows in Blu-ray mode, and whether it is armed.
    // Written by the HTTP thread, read by the Blu-ray display loop.
    var cue_state: cues.State = .{};

    // One-shot "force a PLL resync now" signal from the web page, consumed by
    // `pollLoop`. `swap`-based, so a request cannot be lost or double-fired.
    var resync_requested = std.atomic.Value(bool).init(false);

    // Start HTTP server in a separate thread
    const server_thread = try std.Thread.spawn(.{}, startHttpServer, .{ io, allocator, &mode, &cue_state, &resync_requested });
    server_thread.detach();

    // Main display loop
    while (true) {
        // Check for shutdown signal
        if (process_mgmt.shouldShutdown()) {
            std.debug.print("Main loop received shutdown signal, exiting gracefully...\n", .{});
            return;
        }

        const current_mode = mode.load(.acquire);

        // Clear any pending re-init request here, where it is about to be
        // serviced by the init below. Consuming it with `swap` means one click
        // cannot be serviced twice, and -- since the flag is what made the
        // mode loop return -- leaving it set would spin this loop.
        if (mode_mod.takeReinitRequest()) {
            std.debug.print("Re-initializing display\n", .{});
        }

        // Put the panel into a known state on every mode entry: geometry,
        // attributes and a clear. Each mode addresses the display differently
        // (Blu-ray mode writes `ESC <line>;<col>C` spans, clocks mode uses
        // `ESC C` / `ESC 2;C`), so whatever the outgoing mode left behind is
        // not a safe starting point for the incoming one.
        //
        // This runs here, on the display thread, rather than in the HTTP
        // handler that requested the switch: only one thread may write to the
        // port, and by this point the outgoing mode's loop has returned. It is
        // also the one place that covers every mode, including the `--bluray`
        // and `--vlc` command-line starts, which never go through HTTP at all.
        //
        // Logged, not propagated: failing to init is not a reason to take the
        // service down, and the next mode change gets another attempt.
        protocol.sendUnitDefaultInitCmd(allocator, port, 1) catch |err| {
            std.debug.print("Failed to initialize display on mode entry: {}\n", .{err});
        };

        // No explicit wait here for the mode's first frame to be safe to send:
        // `sendUnitDefaultInitCmd` above already went through `protocol.send`,
        // which blocks for the panel's reply (or `protocol.timeout_ms`) before
        // returning -- see its doc. By the time this line is reached the init
        // has therefore actually landed (or the wait has already been paid),
        // so the mode loop's first send below, which is a full redraw, is safe
        // to fire immediately rather than needing a guessed settle delay of
        // its own.

        if (current_mode == .Clocks) {
            try clocks.runClocks(io, allocator, port, &mode);
        } else if (current_mode == .Bluray) {
            try bluray.runBlurayClocks(io, allocator, port, &mode, &cue_state, &resync_requested);
        } else if (current_mode == .Vlc) {
            try vlc.runVlcClocks(io, allocator, port, &mode);
        }
    }
}

fn startHttpServer(
    io: Io,
    allocator: std.mem.Allocator,
    mode: *std.atomic.Value(Mode),
    cue_state: *cues.State,
    resync_requested: *std.atomic.Value(bool),
) !void {
    const address: Io.net.IpAddress = Io.net.IpAddress.parse("0.0.0.0", 8080) catch unreachable;
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("HTTP server listening on port 8080\n", .{});

    while (true) {
        const stream = try listener.accept(io);
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ io, allocator, stream, mode, cue_state, resync_requested });
        thread.detach();
    }
}

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    mode: *std.atomic.Value(Mode),
    cue_state: *cues.State,
    resync_requested: *std.atomic.Value(bool),
) !void {
    defer stream.close(io);

    var read_buffer: [1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    const out = &stream_writer.interface;
    defer out.flush() catch {};

    // Wait for the first chunk of the request and take whatever arrived. Do not
    // use `readSliceShort` here: it blocks until the buffer is full, which never
    // happens for a request smaller than `read_buffer`.
    const request = stream_reader.interface.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };

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
        var body: Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        const w = &body.writer;

        w.print(
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
            \\<form action="/control" method="post">
            \\<button type="submit" name="action" value="init">Init</button>
            \\</form>
            \\
        , .{mode_str}) catch return;

        writeCuesSection(io, allocator, w, cue_state) catch return;
        writeDisplayLeadSection(w) catch return;

        w.writeAll(
            \\<h2>Blu-Ray Sync</h2>
            \\<p>Re-hunts the phase lock immediately instead of waiting for its
            \\own periodic re-sync. The clock keeps running while it re-locks.</p>
            \\<form action="/resync" method="post">
            \\<button type="submit">Force PLL Resync</button>
            \\</form>
            \\
        ) catch return;

        w.writeAll(
            \\</body>
            \\</html>
        ) catch return;

        const html_body = body.written();
        const headers = std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n\r\n", .{html_body.len}) catch return;
        defer allocator.free(headers);
        try out.writeAll(headers);
        try out.writeAll(html_body);
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

        // Simple form parsing
        var iter = std.mem.splitSequence(u8, body, "&");
        while (iter.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "action=")) {
                action = pair[7..];
            }
        }

        // There was an `action=display` branch here that wrote `text`
        // straight to the panel. Removed: no form on the page ever posted it
        // (there is no `text` input), and it was the last place outside the
        // display thread that touched the serial port -- letting any POST
        // splice arbitrary bytes, escape sequences included, into whatever
        // frame the render loop was mid-way through emitting.
        if (std.mem.eql(u8, action, "init")) {
            // Deliberately does not touch the port: only the display thread
            // may write to it (see `mode.requestReinit`). This hands the job
            // to the running mode loop, which stops so the dispatch loop can
            // init and repaint on the display thread.
            mode_mod.requestReinit();
            std.debug.print("Display re-init requested from the web page\n", .{});
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        try out.writeAll(response);
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

        // Deliberately does NOT touch the serial port. Re-initialising the
        // panel used to happen here, on the HTTP thread -- but the outgoing
        // mode's render loop is still running and still writing to the same
        // fd at this moment, and nothing serializes the two. The interleaved
        // bytes corrupt whichever frame they land in, and
        // `unitDefaultInitCmd` carries a window-geometry command
        // (`ESC 0;0;119;15w`): a mangled one leaves later writes addressing
        // somewhere off-screen, so the panel goes blank and *stays* blank,
        // since a redraw repaints content but never re-sends the geometry.
        // The mode dispatch loop in `main` now does the init instead, on the
        // display thread, after the switch has taken effect.
        if (std.mem.eql(u8, new_mode, "clocks")) {
            mode.store(.Clocks, .release);
        } else if (std.mem.eql(u8, new_mode, "bluray")) {
            mode.store(.Bluray, .release);
        } else if (std.mem.eql(u8, new_mode, "vlc")) {
            mode.store(.Vlc, .release);
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        try out.writeAll(response);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/cues")) {
        // Find the body
        var body_start: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                body_start = @intFromPtr(line.ptr) - @intFromPtr(request.ptr) + line.len + 2;
                break;
            }
        }
        const body = request[body_start..];

        var iter = std.mem.splitSequence(u8, body, "&");
        while (iter.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            // File names routinely contain spaces and parentheses, so the value
            // has to be properly form-decoded rather than just un-plussed.
            const value = formDecode(allocator, pair[eq + 1 ..]) catch continue;
            defer allocator.free(value);

            if (std.mem.eql(u8, key, "file")) {
                if (value.len == 0) {
                    cue_state.clear();
                } else if (!cue_state.select(value)) {
                    std.debug.print("Rejected cue file selection: {s}\n", .{value});
                }
            } else if (std.mem.eql(u8, key, "arm")) {
                cue_state.setArmed(std.mem.eql(u8, value, "on"));
            }
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        try out.writeAll(response);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/display-lead")) {
        // Find the body
        var body_start: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                body_start = @intFromPtr(line.ptr) - @intFromPtr(request.ptr) + line.len + 2;
                break;
            }
        }
        const body = request[body_start..];

        var iter = std.mem.splitSequence(u8, body, "&");
        while (iter.next()) |pair| {
            if (!std.mem.startsWith(u8, pair, "lead=")) continue;
            const raw_value = formDecode(allocator, pair[5..]) catch continue;
            defer allocator.free(raw_value);

            if (bluray.parseDisplayLeadConfig(raw_value)) |value| {
                // Applies to the running process immediately and persists to
                // bluray_display_lead_ms.txt so it survives a restart too.
                bluray.setDisplayLead(io, value);
            } else {
                std.debug.print("Rejected display lead value: {s}\n", .{raw_value});
            }
        }

        // Redirect back to main page
        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        try out.writeAll(response);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/resync")) {
        // No body to parse: this is a single one-shot signal, picked up by
        // `pollLoop` and consumed via `swap` so a request can never be lost or
        // fire twice. Setting it while not in Blu-ray mode is harmless -- the
        // next time that mode starts, a freshly initialized phase lock has
        // nothing to resync anyway.
        resync_requested.store(true, .release);

        const response = "HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n";
        try out.writeAll(response);
    } else {
        const response = "HTTP/1.1 404 Not Found\r\n\r\n";
        try out.writeAll(response);
    }
}

/// Render the Blu-ray cue controls: which file line 2 draws from, and whether
/// its cues are being shown.
fn writeCuesSection(
    io: Io,
    allocator: std.mem.Allocator,
    w: *Io.Writer,
    cue_state: *cues.State,
) !void {
    var name_buf: [cues.max_name_len]u8 = undefined;
    const selected = cue_state.currentName(&name_buf);
    const armed = cue_state.isArmed();

    try w.writeAll("<h2>Blu-Ray Line 2 Cues</h2>\n");

    const names = cues.listNames(io, allocator) catch |err| {
        try w.print("<p>Cannot read {s}: {}</p>\n", .{ cues.dirPath(), err });
        return;
    };
    defer cues.freeNames(allocator, names);

    if (names.len == 0) {
        try w.print("<p>No <code>*.vtt</code> files in <code>{s}</code>.</p>\n", .{cues.dirPath()});
        return;
    }

    try w.writeAll(
        \\<form action="/cues" method="post">
        \\<select name="file">
        \\<option value="">(none)</option>
        \\
    );
    for (names) |name| {
        const is_selected = if (selected) |s| std.mem.eql(u8, s, name) else false;
        try w.writeAll("<option value=\"");
        try writeHtmlEscaped(w, name);
        try w.writeAll(if (is_selected) "\" selected>" else "\">");
        try writeHtmlEscaped(w, cues.baseName(name));
        try w.writeAll("</option>\n");
    }
    try w.writeAll(
        \\</select>
        \\<button type="submit">Select</button>
        \\</form>
        \\
    );

    // Arming is manual: the player reports elapsed time and nothing else, so
    // nothing here can tell the feature apart from a menu loop or a trailer.
    try w.print(
        \\<form action="/cues" method="post">
        \\<p>Cues are <b>{s}</b>.</p>
        \\<button type="submit" name="arm" value="on">Start cues</button>
        \\<button type="submit" name="arm" value="off">Stop cues</button>
        \\</form>
        \\
    , .{if (armed) "running" else "stopped"});
}

/// Render the Blu-ray display-lead control: `bluray.display_lead_ms`, editable
/// and applied live (see `bluray.setDisplayLead`) without a rebuild.
fn writeDisplayLeadSection(w: *Io.Writer) !void {
    const current = bluray.display_lead_ms.load(.acquire);
    try w.print(
        \\<h2>Blu-Ray Display Lead</h2>
        \\<p>Compensates for latency downstream of an accurate lock (player
        \\decode/output buffering, TV processing delay) -- not for a stalled
        \\clock, which this cannot fix. Positive moves the panel further ahead;
        \\adjust in small steps while comparing the panel against the picture.</p>
        \\<form action="/display-lead" method="post">
        \\<label for="lead">Lead (ms):</label>
        \\<input type="number" id="lead" name="lead" step="10" value="{d}">
        \\<button type="submit">Set</button>
        \\</form>
        \\
    , .{current});
}

/// Escape text for interpolation into HTML. File names come from the
/// filesystem, so they are not guaranteed to be free of markup characters.
fn writeHtmlEscaped(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
}

/// Decode one `application/x-www-form-urlencoded` value. Caller owns the result.
fn formDecode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        switch (raw[i]) {
            '+' => {
                try out.append(allocator, ' ');
                i += 1;
            },
            '%' => {
                if (i + 3 <= raw.len) {
                    if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |byte| {
                        try out.append(allocator, byte);
                        i += 3;
                        continue;
                    } else |_| {}
                }
                // Not a valid escape, so treat it as a literal percent sign.
                try out.append(allocator, '%');
                i += 1;
            },
            else => |c| {
                try out.append(allocator, c);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "formDecode handles the escapes a file name can produce" {
    const cases = .{
        .{ "plain.vtt", "plain.vtt" },
        .{ "The+Thing+%281982%29.vtt", "The Thing (1982).vtt" },
        .{ "100%25.vtt", "100%.vtt" },
        // A truncated escape must not swallow the rest of the value.
        .{ "bad%2.vtt", "bad%2.vtt" },
        .{ "trailing%", "trailing%" },
    };
    inline for (cases) |case| {
        const got = try formDecode(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "writeHtmlEscaped neutralizes markup in file names" {
    var body: Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try writeHtmlEscaped(&body.writer, "a<b>&\"c\".vtt");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;c&quot;.vtt", body.written());
}

// Pull every module's `test` blocks into the test binary.
//
// `zig build test` builds a single test executable rooted at this file, and
// Zig only collects `test` blocks from files that are analyzed *in test
// mode*. Importing a module for its functions -- as the top of this file does
// -- is not enough: without the references below, the 100+ tests in these
// modules are silently never built or run, and `zig build test` reports
// success having executed almost nothing. That failure mode is particularly
// nasty because it looks exactly like a green suite.
test {
    _ = @import("bluray.zig");
    _ = @import("clocks.zig");
    _ = @import("config.zig");
    _ = @import("cues.zig");
    _ = @import("debug_log.zig");
    _ = @import("frame_timer.zig");
    _ = @import("jsonc.zig");
    _ = @import("marquee.zig");
    _ = @import("mode.zig");
    _ = @import("phase_lock.zig");
    _ = @import("process_mgmt.zig");
    _ = @import("protocol.zig");
    _ = @import("serial.zig");
    _ = @import("str_utils.zig");
    _ = @import("time.zig");
    _ = @import("vlc.zig");
    _ = @import("vorne_charset.zig");
    _ = @import("vorne_config.zig");
    _ = @import("webvtt.zig");
}
