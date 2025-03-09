const std = @import("std");
const c = @import("c").includes;
const FontManager = @import("FontManager.zig");
const Buffer = @import("Buffer.zig");
const pty = @import("pty.zig");
const escapes = @import("escapes.zig");
const tracy = @import("tracy");
const platform = @import("platform.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();

    run(gpa.allocator()) catch |err| {
        std.log.err("unexpected error: {}", .{err});
        if (@errorReturnTrace()) |error_trace| {
            std.debug.dumpStackTrace(error_trace.*);
        }
    };
}

fn run(alloc: std.mem.Allocator) !void {
    var x11 = try platform.x11.init(alloc);
    defer x11.deinit();

    const scale = x11.getDisplayScale() catch 1.0;
    var font_manager = try FontManager.init(alloc, "Comic Code", scale * 14.0);
    defer font_manager.deinit();

    const window_size = try x11.getWindowSize();
    const initial_buffer_size = try computeBufferSize(window_size, &font_manager, 1e3);
    var buffer = try Buffer.init(alloc, initial_buffer_size);
    defer buffer.deinit(alloc);

    var shell = shell: {
        var terminal = try pty.open(.{
            .cols = std.math.lossyCast(u16, buffer.size.cols),
            .rows = std.math.lossyCast(u16, buffer.size.rows),
            .pixels_x = std.math.lossyCast(u16, window_size[0]),
            .pixels_y = std.math.lossyCast(u16, window_size[1]),
        });
        errdefer terminal.deinit();
        break :shell try terminal.exec();
    };
    defer shell.deinit();

    var app = App{
        .alloc = alloc,
        .shell = &shell,
        .x11 = &x11,
        .font_manager = &font_manager,
        .buffer = &buffer,
        .input_buffer = App.FifoBuffer.init(alloc),
        .output_buffer = App.FifoBuffer.init(alloc),
    };
    defer app.deinit();
    try app.redraw();

    try runEventLoop(&app);
}

fn runEventLoop(app: *App) !void {
    const display_file = app.x11.file();

    _ = try std.posix.fcntl(
        app.shell.io.handle,
        std.posix.F.SETFD,
        @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })),
    );

    const POLL = std.posix.POLL;

    var largest_seen_input_size: usize = std.heap.pageSize();
    var last_redraw = try std.time.Instant.now();
    var poll_timeout: ?u64 = null;

    // We keep track of the number of times a call to `poll` has completed
    // almost immediately, indicating that there is a lot of IO going on. If
    // this number gets above some thresheld, we start throttling the drawing,
    // sacrificing some latency for higher IO throughput.
    var high_frequency_poll_count: u32 = 0;
    const max_redraw_delay = 40 * std.time.ns_per_ms;

    while (!app.x11.should_close) {
        var poll_fds = [_]std.posix.pollfd{
            // wait for new window events.
            .{ .fd = display_file.handle, .events = POLL.IN, .revents = 0 },
            // Wait for new input from the shell.
            .{ .fd = app.shell.io.handle, .events = POLL.IN, .revents = 0 },
        };

        const poll_display = &poll_fds[0];
        const poll_shell = &poll_fds[1];

        if (app.x11.hasPendingEvent()) {
            poll_display.revents = POLL.IN;
        } else {
            if (app.output_buffer.count != 0) {
                // wait until we can write to the shell
                poll_shell.events |= POLL.OUT;
            }

            const timeout_ms: i32 = if (poll_timeout) |timeout|
                std.math.lossyCast(i32, timeout / std.time.ns_per_ms)
            else
                -1;
            poll_timeout = null;

            var poll_timer = try std.time.Timer.start();
            {
                const zone = tracy.zone(@src(), "poll");
                defer zone.end();
                zone.setColor(0xAA3333);
                _ = try std.posix.poll(&poll_fds, timeout_ms);
            }
            const poll_duration = poll_timer.read();

            if (poll_duration < 1 * std.time.ns_per_ms) {
                high_frequency_poll_count +|= 1;
            } else {
                high_frequency_poll_count = 0;
            }

            for (poll_fds) |fd| {
                if (fd.revents & POLL.NVAL != 0) {
                    std.log.err("file descriptor unexpectedly closed", .{});
                    return error.PollInvalid;
                }
            }
        }

        if (poll_shell.revents & POLL.HUP != 0) {
            std.log.info("shell exited", .{});
            break;
        }

        if (poll_display.revents & POLL.IN != 0) {
            try app.x11.pollEvent(app);
        }

        while (app.output_buffer.count != 0) {
            const buffer = app.output_buffer.readableSlice(0);
            const count = app.shell.io.write(buffer) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (count == 0) break;
            app.output_buffer.discard(count);
        }

        if (poll_shell.revents & POLL.IN != 0) {
            const buffer = try app.input_buffer.writableWithSize(@min(2 * largest_seen_input_size, 4 << 20));
            const count = app.shell.io.read(buffer) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (count > 0) {
                app.input_buffer.update(count);
                largest_seen_input_size = @max(largest_seen_input_size, app.input_buffer.count);
                try app.processInput();
            }
        }

        if (app.x11.needs_redraw) {
            if (high_frequency_poll_count > 10) {
                // there is a lot of IO currently, so unless we are hitting our
                // deadline for delivering the next frame, we delay redrawing
                // so that we can prioritize IO throughput.
                // std.log.info("high frequency polling", .{});
                const now = try std.time.Instant.now();
                const time_since_redraw = now.since(last_redraw);
                if (time_since_redraw < max_redraw_delay) {
                    poll_timeout = max_redraw_delay - time_since_redraw;
                    continue;
                }
            }

            var redraw_start = try std.time.Timer.start();
            app.redraw() catch |err| {
                std.log.err("could not redraw screen: {}", .{err});
                if (@errorReturnTrace()) |error_trace| {
                    std.debug.dumpStackTrace(error_trace.*);
                }
            };
            const redraw_duration = redraw_start.read();
            std.log.info("redraw_duration: {d:8.3} ms", .{std.math.lossyCast(f32, redraw_duration) / 1e6});

            last_redraw = try std.time.Instant.now();
        }
    }
}

fn computeBufferSize(window_size: [2]u32, font: *const FontManager, scrollback: u32) !Buffer.Size {
    const metrics = font.metrics;
    return .{
        .rows = std.math.lossyCast(u31, @max(1, window_size[1] / metrics.cell_height)),
        .cols = std.math.lossyCast(u31, @max(1, window_size[0] / metrics.cell_width)),
        .scrollback_rows = scrollback,
    };
}

pub const App = struct {
    alloc: std.mem.Allocator,

    shell: *pty.Shell,
    x11: *platform.x11.X11,

    font_manager: *FontManager,
    buffer: *Buffer,
    needs_resize: bool = false,

    /// Bytes read from the shell, to be processed.
    input_buffer: FifoBuffer,
    /// Bytes that should be written to the shell at the next oppurtunity.
    output_buffer: FifoBuffer,

    const FifoBuffer = std.fifo.LinearFifo(u8, .Dynamic);

    pub fn deinit(app: *App) void {
        app.input_buffer.deinit();
        app.output_buffer.deinit();
    }

    /// Attempts to handle the shortcut combination, returning `true` if the
    /// shortcut was properly dispatched (preventing text input for the key) or
    /// `false` if the shortcut is unbound and should produce text.
    pub fn handleShortcut(app: *App, mods: platform.Modifiers, key: platform.Key) !bool {
        const Shortcut = struct {
            ctrl: bool = false,
            alt: bool = false,
            shift: bool = false,
            key: platform.Key,
        };

        const Action = union(enum) {
            close_window,
            decrease_font_size,
            increase_font_size,
            paste,
        };

        const Binding = struct {
            shortcut: Shortcut,
            action: Action,
        };

        const bindings = [_]Binding{
            .{ .shortcut = .{ .shift = true, .key = .escape }, .action = .close_window },
            .{ .shortcut = .{ .ctrl = true, .key = .@"1" }, .action = .decrease_font_size },
            .{ .shortcut = .{ .ctrl = true, .key = .@"2" }, .action = .increase_font_size },
            .{ .shortcut = .{ .ctrl = true, .shift = true, .key = .V }, .action = .paste },
        };

        const shortcut = Shortcut{
            .ctrl = mods.ctrl,
            .alt = mods.alt,
            .shift = mods.shift,
            .key = key,
        };

        const action = for (bindings) |binding| {
            if (std.meta.eql(binding.shortcut, shortcut)) {
                break binding.action;
            }
        } else {
            return false;
        };

        switch (action) {
            .close_window => app.x11.should_close = true,
            .decrease_font_size => try app.adjustFontSize(1.0 / 1.1),
            .increase_font_size => try app.adjustFontSize(1.1),
            .paste => {
                if (!try app.x11.requestPaste()) {
                    std.log.warn("clipboard empty", .{});
                }
            },
        }

        return true;
    }

    pub fn paste(app: *App, contents: []const u8) !void {
        std.log.warn("TODO: enable bracketed paste", .{});
        try app.output_buffer.write(contents);
    }

    fn adjustFontSize(app: *App, multiplier: f32) !void {
        const new_size = app.font_manager.ptsize * multiplier;
        if (new_size < 8) return;

        try app.font_manager.setSize(new_size);
        app.x11.invalidateCaches();

        try app.updateBufferSize();
        app.x11.needs_redraw = true;
    }

    pub fn updateBufferSize(app: *App) !void {
        const zone = tracy.zone(@src(), "updateBufferSize");
        defer zone.end();

        const window_size = try app.x11.getWindowSize();
        const new_buffer_size = try computeBufferSize(window_size, app.font_manager, app.buffer.size.scrollback_rows);

        if (std.meta.eql(app.buffer.size, new_buffer_size)) return;

        std.log.info("resize: {}x{}", .{ new_buffer_size.cols, new_buffer_size.rows });

        var new_buffer = try Buffer.init(app.alloc, new_buffer_size);
        app.buffer.reflowInto(&new_buffer);
        app.buffer.deinit(app.alloc);
        app.buffer.* = new_buffer;
        try app.shell.setSize(.{
            .cols = std.math.lossyCast(u16, app.buffer.size.cols),
            .rows = std.math.lossyCast(u16, app.buffer.size.rows),
            .pixels_x = std.math.lossyCast(u16, window_size[0]),
            .pixels_y = std.math.lossyCast(u16, window_size[1]),
        });

        app.needs_resize = false;
    }

    fn send(app: *App, bytes: []const u8) !void {
        try app.output_buffer.write(bytes);
    }

    fn processInput(app: *App) !void {
        const zone = tracy.zone(@src(), "processInput");
        defer zone.end();

        if (app.needs_resize) try app.updateBufferSize();

        var context: escapes.Context = undefined;

        if (app.input_buffer.count != 0) app.x11.needs_redraw = true;

        process: while (app.input_buffer.count != 0) {
            const bytes = @constCast(app.input_buffer.readableSlice(0));

            // fast path for plain ASCII characters.
            for (bytes, 0..) |byte, index| {
                if (std.ascii.isPrint(byte)) {
                    app.buffer.write(byte);
                } else {
                    if (index == 0) break;
                    app.input_buffer.discard(index);
                    continue :process;
                }
            } else {
                app.input_buffer.discard(bytes.len);
                continue :process;
            }

            const len, const command = escapes.parse(bytes, &context);
            const fmtSequence = std.json.fmt(bytes[0..@min(len, bytes.len)], .{});

            var advance = len;
            defer app.input_buffer.discard(advance);

            switch (command) {
                .incomplete => {
                    advance = 0;
                    const aligned = app.input_buffer.head == 0;
                    if (!aligned) app.input_buffer.realign();
                    if (len > app.input_buffer.count) break;
                    std.debug.assert(!aligned);
                },
                .invalid => {
                    std.log.warn("invalid input: {}", .{fmtSequence});
                    app.buffer.write(std.unicode.replacement_character);
                },
                .ignore => {},
                .codepoint => |codepoint| app.buffer.write(codepoint),
                .retline => app.buffer.setCursorPosition(.{ .col = .{ .abs = 0 } }),
                .newline => app.buffer.setCursorPosition(.{ .row = .{ .rel = 1 } }),

                .tab => {
                    while (true) {
                        app.buffer.write(' ');
                        if (app.buffer.cursor.col % 8 == 0) break;
                    }
                },

                .backspace => app.buffer.setCursorPosition(.{ .col = .{ .rel = -1 } }),

                .alert => {},

                .reverse_index => {
                    if (app.buffer.cursor.row == app.buffer.scroll_margins.top) {
                        app.buffer.insertLinesBlank(1, .top);
                    } else {
                        app.buffer.setCursorPosition(.{ .row = .{ .rel = -1 } });
                    }
                },

                .csi => |csi| {
                    app.handleCSI(csi, &context) catch |err| {
                        if (err == error.Unimplemented) {
                            std.log.warn("unimplemented CSI {}", .{fmtSequence});
                        }
                    };
                },

                .osc => |osc| {
                    const code = if (osc.arg_min != 0) context.get(0, 0) else {
                        std.log.warn("OSC missing code ({})", .{fmtSequence});
                        continue;
                    };

                    const min = context.get(osc.arg_min, 0);
                    const max = context.get(osc.arg_max, 0);

                    std.debug.assert(bytes[max] == std.ascii.control_code.stx or
                        bytes[max] == std.ascii.control_code.bel or
                        bytes[max] == std.ascii.control_code.esc);
                    bytes[max] = 0; // ensure null-termination (we don't need the final STX/BEL/ESC byte)

                    std.debug.assert(min <= max and max < len);
                    const text = bytes[min..max :0];

                    switch (code) {
                        0, 2 => _ = app.x11.setWindowTitle(text),
                        8 => {
                            // FIXME: handle links
                        },
                        else => {
                            std.log.warn("unknown OSC code: {} ({})", .{ code, fmtSequence });
                        },
                    }
                },

                .set_character_set => {
                    // FIXME: figure out how to handle these. For now we only
                    // support UTF-8.
                },

                else => std.log.warn("unimplemented escape: {} ({})", .{
                    std.json.fmt(command, .{}),
                    fmtSequence,
                }),
            }
        }
    }

    fn handleCSI(app: *App, csi: escapes.ControlSequenceInducer, context: *const escapes.Context) !void {
        const zone = tracy.zone(@src(), "handleCSI");
        defer zone.end();

        switch (csi.final) {
            'h' => {
                const value = context.get(0, 0);
                const mode = std.meta.intToEnum(Buffer.PrivateModes, value) catch return error.Unimplemented;
                app.buffer.private_modes.insert(mode);
            },
            'l' => {
                const value = context.get(0, 0);
                const mode = std.meta.intToEnum(Buffer.PrivateModes, value) catch return error.Unimplemented;
                app.buffer.private_modes.remove(mode);
            },

            'm' => {
                if (csi.intermediate != 0) return error.Unimplemented;

                const brush = &app.buffer.cursor.brush;
                var i: u32 = 0;
                while (i < @max(1, context.args_count)) {
                    const code = context.get(i, 0);
                    i += 1;
                    switch (code) {
                        0 => brush.* = .{},

                        1 => brush.flags.bold = true,
                        22 => brush.flags.bold = false,

                        3 => brush.flags.italic = true,
                        23 => brush.flags.italic = false,

                        4 => brush.flags.underline = true,
                        24 => brush.flags.underline = false,

                        7 => brush.flags.inverse = true,
                        27 => brush.flags.inverse = false,

                        inline 30...37 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            const index = (arg - 30) & 7;
                            brush.foreground = Buffer.Style.Color.fromXterm256(index);
                        },
                        38 => {
                            const result = handleTrueColor(context, &i) orelse break;
                            brush.flags.truecolor_foreground = result.truecolor;
                            brush.foreground = result.color;
                        },
                        39 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Style.Color.default;
                        },

                        inline 40...47 => |arg| {
                            brush.flags.truecolor_background = false;
                            const index = (arg - 40) & 7;
                            brush.background = Buffer.Style.Color.fromXterm256(index);
                        },
                        48 => {
                            const result = handleTrueColor(context, &i) orelse break;
                            brush.flags.truecolor_background = result.truecolor;
                            brush.background = result.color;
                        },
                        49 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Style.Color.default;
                        },

                        inline 90...97 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            const index = 8 + ((arg - 90) & 7);
                            brush.foreground = Buffer.Style.Color.fromXterm256(index);
                        },
                        inline 100...107 => |arg| {
                            brush.flags.truecolor_background = false;
                            const index = 8 + ((arg - 100) & 7);
                            brush.background = Buffer.Style.Color.fromXterm256(index);
                        },

                        else => |first| {
                            std.log.warn("unimplemented style: {}", .{first});
                            break;
                        },
                    }
                }
            },

            '@' => app.buffer.insertCharactersBlank(context.get(0, 1)),

            'A' => app.buffer.setCursorPosition(.{ .row = .{ .rel = -std.math.lossyCast(i32, context.get(0, 1)) } }),
            'B' => app.buffer.setCursorPosition(.{ .row = .{ .rel = std.math.lossyCast(i32, context.get(0, 1)) } }),
            'C' => app.buffer.setCursorPosition(.{ .col = .{ .rel = std.math.lossyCast(i32, context.get(0, 1)) } }),
            'D' => app.buffer.setCursorPosition(.{ .col = .{ .rel = -std.math.lossyCast(i32, context.get(0, 1)) } }),

            'H' => {
                const row: u31 = @min(context.get(0, 1) -| 1, app.buffer.size.rows);
                const col: u31 = @min(context.get(1, 1) -| 1, app.buffer.size.cols);
                app.buffer.setCursorPosition(.{
                    .row = .{ .abs = row },
                    .col = .{ .abs = col },
                });
            },

            'J' => switch (context.get(0, 0)) {
                0 => app.buffer.eraseInDisplay(.below),
                1 => app.buffer.eraseInDisplay(.above),
                2 => app.buffer.eraseInDisplay(.all),
                else => return error.Unimplemented,
            },

            'K' => switch (context.get(0, 0)) {
                0 => app.buffer.eraseInLine(.right),
                1 => app.buffer.eraseInLine(.left),
                2 => app.buffer.eraseInLine(.all),
                else => return error.Unimplemented,
            },

            'L' => app.buffer.insertLinesBlank(context.get(0, 1), .cursor),

            'M' => app.buffer.deleteLines(context.get(0, 1)),

            'P' => app.buffer.deleteCharacters(context.get(0, 1)),

            'X' => app.buffer.eraseCharacters(context.get(0, 1)),

            'q' => {
                if (csi.intermediate == ' ') {
                    const value = context.get(0, 0);
                    const shape = std.meta.intToEnum(Buffer.Cursor.Shape, value) catch .default;
                    app.buffer.cursor.shape = shape;
                    return;
                }

                return error.Unimplemented;
            },

            'r' => {
                const top = context.get(0, 1) -| 1;
                const bot = context.get(1, std.math.maxInt(u32));
                app.buffer.scroll_margins.top = std.math.lossyCast(u31, top);
                app.buffer.scroll_margins.bot = std.math.lossyCast(u31, bot);
            },

            'u' => {
                if (csi.intermediate == '=') {
                    std.log.warn("TODO: Kitty progressive enhancements", .{});
                    return;
                }
            },

            else => return error.Unimplemented,
        }
    }

    fn handleTrueColor(context: *const escapes.Context, index: *u32) ?struct {
        truecolor: bool,
        color: Buffer.Style.Color,
    } {
        const mode = context.get(index.*, 0);
        index.* += 1;
        switch (mode) {
            2 => {
                const r: u8 = @truncate(context.get(index.*, 0));
                index.* += 1;
                const g: u8 = @truncate(context.get(index.*, 0));
                index.* += 1;
                const b: u8 = @truncate(context.get(index.*, 0));
                index.* += 1;
                return .{ .truecolor = true, .color = .{ .rgb = .{ .r = r, .g = g, .b = b } } };
            },
            5 => {
                const color_index = context.get(index.*, 0);
                index.* += 1;
                return .{ .truecolor = false, .color = Buffer.Style.Color.fromXterm256(@truncate(color_index)) };
            },
            else => {
                std.log.warn("unrecognized color mode: {}", .{mode});
                return null;
            },
        }
    }

    pub fn redraw(app: *App) !void {
        if (app.needs_resize) try app.updateBufferSize();

        const zone = tracy.zone(@src(), "redraw");
        defer zone.end();

        try app.x11.redraw(app.font_manager, app.buffer);
    }
};
