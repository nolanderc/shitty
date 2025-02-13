const std = @import("std");
const c = @import("c").includes;
const FontManager = @import("FontManager.zig");
const Buffer = @import("Buffer.zig");
const pty = @import("pty.zig");
const escapes = @import("escapes.zig");
const tracy = @import("tracy");

const logSDL = std.log.scoped(.SDL);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();

    const zone = tracy.zone(@src(), "program");
    defer zone.end();

    run(gpa.allocator()) catch |err| {
        const sdl_error = c.SDL_GetError();
        if (sdl_error != null and sdl_error[0] != 0) {
            logSDL.err("{s}", .{sdl_error});
        }

        std.log.err("unexpected error: {}", .{err});
        if (@errorReturnTrace()) |error_trace| {
            std.debug.dumpStackTrace(error_trace.*);
        }
    };
}

fn run(alloc: std.mem.Allocator) !void {
    // _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    _ = c.SDL_SetHint(c.SDL_HINT_NO_SIGNAL_HANDLERS, "1");

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "shitty",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    const surface = c.SDL_GetWindowSurface(window) orelse return error.SdlWindowSurface;

    if (!c.SDL_StartTextInput(window)) return error.SdlTextInput;

    const scale = c.SDL_GetWindowDisplayScale(window);
    var font_manager = try FontManager.init(alloc, "Comic Code", scale * 14.0);
    defer font_manager.deinit();

    const window_size = try getWindowSize(window);

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
        .window = window,
        .surface = surface,
        .font_manager = &font_manager,
        .buffer = &buffer,
        .input_buffer = App.FifoBuffer.init(alloc),
        .output_buffer = App.FifoBuffer.init(alloc),
    };
    defer app.deinit();
    try app.redraw();

    try runEventLoop(&app, &shell);
}

fn runEventLoop(app: *App, shell: *pty.Shell) !void {
    const display_fd = sdlFileDescriptor(app.window) orelse return error.MissingDisplayFileDescriptor;
    std.log.info("Display FD: {}", .{display_fd});

    _ = try std.posix.fcntl(
        shell.io.handle,
        std.posix.F.SETFD,
        @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })),
    );

    const POLL = std.posix.POLL;

    var largest_seen_input_size: usize = std.mem.page_size;
    var last_redraw = try std.time.Instant.now();
    var poll_timeout: ?u64 = null;

    // We keep track of the number of times a call to `poll` has completed
    // almost immediately, indicating that there is a lot of IO going on. If
    // this number gets above some thresheld, we start throttling the drawing,
    // sacrificing some latency for higher IO throughput.
    var high_frequency_poll_count: u32 = 0;
    const max_redraw_delay = 40 * std.time.ns_per_ms;

    while (app.running) {
        var poll_fds = [_]std.posix.pollfd{
            // wait for new SDL events.
            .{ .fd = display_fd, .events = POLL.IN, .revents = 0 },
            // Wait for new input from the shell.
            .{ .fd = shell.io.handle, .events = POLL.IN, .revents = 0 },
        };

        const poll_display = &poll_fds[0];
        const poll_shell = &poll_fds[1];

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

        if (poll_shell.revents & POLL.HUP != 0) {
            std.log.info("shell exited", .{});
            break;
        }

        if (poll_display.revents & POLL.IN != 0) {
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event)) {
                try app.handleEvent(event);
            }
        }

        while (app.output_buffer.count != 0) {
            const buffer = app.output_buffer.readableSlice(0);
            const count = shell.io.write(buffer) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (count == 0) break;
            app.output_buffer.discard(count);
        }

        if (poll_shell.revents & POLL.IN != 0) {
            const buffer = try app.input_buffer.writableWithSize(@min(2 * largest_seen_input_size, 4 << 20));
            const count = shell.io.read(buffer) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (count > 0) {
                app.input_buffer.update(count);
                largest_seen_input_size = @max(largest_seen_input_size, app.input_buffer.count);
                try app.processInput();
            }
        }

        if (app.needs_redraw) {
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
                logSDL.err("could not redraw screen: {}", .{err});
                if (@errorReturnTrace()) |error_trace| {
                    std.debug.dumpStackTrace(error_trace.*);
                }
            };
            const redraw_duration = redraw_start.read();
            std.log.info("redraw_duration: {d}", .{std.math.lossyCast(f32, redraw_duration) / 1e6});

            last_redraw = try std.time.Instant.now();
        }
    }
}

fn sdlFileDescriptor(window: *c.SDL_Window) ?std.posix.fd_t {
    const Platforms = struct {
        fn getX11(props: u32) ?std.posix.fd_t {
            const prop_name = c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER;
            const display = c.SDL_GetPointerProperty(props, prop_name, null) orelse return null;

            const lib = c.SDL_LoadObject("libX11.so") orelse return null;
            defer c.SDL_UnloadObject(lib);
            const sym = c.SDL_LoadFunction(lib, "XConnectionNumber") orelse return null;

            const XConnectionNumber: *const fn (*anyopaque) callconv(.C) std.posix.fd_t = @ptrCast(sym);
            return XConnectionNumber(@ptrCast(display));
        }

        fn getWayland(props: u32) ?std.posix.fd_t {
            const prop_name = c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER;
            const display = c.SDL_GetPointerProperty(props, prop_name, null) orelse return null;

            const lib = c.SDL_LoadObject("libwayland-client.so") orelse return null;
            defer c.SDL_UnloadObject(lib);
            const sym = c.SDL_LoadFunction(lib, "wl_display_get_fd") orelse return null;

            const wl_display_get_fd: *const fn (*anyopaque) std.posix.fd_t = @ptrCast(sym);
            return wl_display_get_fd(display);
        }
    };

    const props = c.SDL_GetWindowProperties(window);

    std.log.info("testing X11", .{});
    if (Platforms.getX11(props)) |fd| return fd;

    std.log.info("testing Wayland", .{});
    if (Platforms.getWayland(props)) |fd| return fd;

    return null;
}

fn getWindowSize(window: *c.SDL_Window) ![2]u32 {
    var width: c_int = undefined;
    var height: c_int = undefined;
    if (!c.SDL_GetWindowSize(window, &width, &height)) return error.MissingWindowSize;
    return .{ @abs(width), @abs(height) };
}

fn computeBufferSize(window_size: [2]u32, font: *const FontManager, scrollback: u32) !Buffer.Size {
    const metrics = font.metrics;
    return .{
        .rows = @max(1, window_size[1] / metrics.cell_height),
        .cols = @max(1, window_size[0] / metrics.cell_width),
        .scrollback_rows = scrollback,
    };
}

const App = struct {
    running: bool = true,

    alloc: std.mem.Allocator,

    window: *c.SDL_Window,
    surface: *c.SDL_Surface,
    needs_redraw: bool = true,

    font_manager: *FontManager,
    buffer: *Buffer,

    /// Bytes read from the shell, to be processed.
    input_buffer: FifoBuffer,
    /// Bytes that should be written to the shell at the next oppurtunity.
    output_buffer: FifoBuffer,

    private_modes: std.EnumSet(PrivateModes) = .{},

    const FifoBuffer = std.fifo.LinearFifo(u8, .Dynamic);

    pub fn deinit(app: *App) void {
        app.input_buffer.deinit();
        app.output_buffer.deinit();
    }

    pub fn handleEvent(app: *App, event: c.SDL_Event) !void {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                app.running = false;
            },

            c.SDL_EVENT_TEXT_INPUT => {
                try app.send(std.mem.span(event.text.text));
            },

            c.SDL_EVENT_KEY_DOWN => {
                const shift = (c.SDL_KMOD_SHIFT & event.key.mod) != 0;
                const ctrl = (c.SDL_KMOD_CTRL & event.key.mod) != 0;

                switch (event.key.key) {
                    c.SDLK_TAB => try app.send("\t"),
                    c.SDLK_RETURN => try app.send("\r"),
                    c.SDLK_BACKSPACE => try app.send("\x7F"),
                    c.SDLK_DELETE => try app.send("\x7f"),

                    c.SDLK_A...c.SDLK_Z => |key| if (ctrl) try app.send(&.{@truncate(key - c.SDLK_A + 1)}),

                    c.SDLK_1 => {
                        if (ctrl) try app.adjustFontSize(1.0 / 1.1);
                    },

                    c.SDLK_2 => {
                        if (ctrl) try app.adjustFontSize(1.1);
                    },

                    c.SDLK_ESCAPE => {
                        if (shift) app.running = false;
                    },

                    else => {},
                }
            },

            c.SDL_EVENT_WINDOW_RESIZED => {
                app.surface = c.SDL_GetWindowSurface(app.window) orelse return error.SdlWindowSurface;
                try app.updateBufferSize();
            },

            c.SDL_EVENT_WINDOW_EXPOSED => app.needs_redraw = true,

            else => {},
        }
    }

    fn adjustFontSize(app: *App, multiplier: f32) !void {
        const new_size = app.font_manager.ptsize * multiplier;
        if (new_size < 8) return;

        try app.font_manager.setSize(new_size);
        try app.updateBufferSize();
        app.needs_redraw = true;
    }

    fn updateBufferSize(app: *App) !void {
        const window_size = try getWindowSize(app.window);
        const new_buffer_size = try computeBufferSize(window_size, app.font_manager, app.buffer.size.scrollback_rows);
        var new_buffer = try Buffer.init(app.alloc, new_buffer_size);
        app.buffer.reflowInto(&new_buffer);
        app.buffer.deinit(app.alloc);
        app.buffer.* = new_buffer;
    }

    fn send(app: *App, bytes: []const u8) !void {
        try app.output_buffer.write(bytes);
    }

    fn processInput(app: *App) !void {
        var context: escapes.Context = undefined;

        process: while (app.input_buffer.count != 0) {
            const bytes = @constCast(app.input_buffer.readableSlice(0));

            // fast path for plain ASCII characters.
            for (bytes, 0..) |byte, index| {
                if (std.ascii.isPrint(byte)) {
                    app.buffer.write(byte);
                } else {
                    app.input_buffer.discard(index);
                    if (index != 0) continue :process;
                    break;
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
                    std.log.debug("invalid input: {}", .{fmtSequence});
                    app.buffer.write(std.unicode.replacement_character);
                },
                .ignore => {},
                .codepoint => |codepoint| app.buffer.write(codepoint),
                .retline => app.buffer.setCursorPosition(.{ .col = .{ .abs = 0 } }),
                .newline => app.buffer.setCursorPosition(.{ .row = .{ .rel = 1 } }),

                .backspace => {
                    app.buffer.setCursorPosition(.{ .col = .{ .rel = -1 } });
                    app.buffer.write(0);
                    app.buffer.setCursorPosition(.{ .col = .{ .rel = -1 } });
                },

                .alert => {},

                .csi => |csi| app.handleCSI(csi, &context) catch |err| {
                    if (err == error.Unimplemented) {
                        std.log.warn("unimplemented CSI {} {c} ({})", .{
                            context.fmtArgs(),
                            csi.final,
                            fmtSequence,
                        });
                    }
                },

                .osc => |osc| {
                    const code = if (osc.arg_min != 0) context.get(0, 0) else {
                        std.log.warn("OSC missing code ({})", .{fmtSequence});
                        continue;
                    };

                    const min = context.get(osc.arg_min, 0);
                    const max = context.get(osc.arg_max, 0);

                    std.debug.assert(bytes[max] == std.ascii.control_code.stx or bytes[max] == std.ascii.control_code.bel);
                    bytes[max] = 0; // ensure null-termination (we don't need the final STX/BEL byte)

                    std.debug.assert(min <= max and max < len);
                    const text = bytes[min..max :0];

                    switch (code) {
                        0, 2 => _ = c.SDL_SetWindowTitle(app.window, text),
                        else => {
                            std.log.warn("unknown OSC code: {} ({})", .{ code, fmtSequence });
                        },
                    }
                },

                else => std.log.warn("unimplemented escape: {} ({})", .{
                    std.json.fmt(command, .{}),
                    fmtSequence,
                }),
            }
        }

        app.needs_redraw = true;
    }

    fn handleCSI(app: *App, csi: escapes.ControlSequenceInducer, context: *const escapes.Context) !void {
        switch (csi.final) {
            'h' => {
                const value = context.get(0, 0);
                const mode = std.meta.intToEnum(PrivateModes, value) catch return error.Unimplemented;
                app.private_modes.insert(mode);
            },
            'l' => {
                const value = context.get(0, 0);
                const mode = std.meta.intToEnum(PrivateModes, value) catch return error.Unimplemented;
                app.private_modes.remove(mode);
            },

            'm' => {
                const brush = &app.buffer.cursor.brush;
                var i: u32 = 0;
                while (i < @max(1, context.args_count)) {
                    const code = context.get(i, 0);
                    i += 1;
                    switch (code) {
                        0 => brush.* = .{},

                        1 => brush.flags.bold = true,
                        22 => brush.flags.bold = false,

                        3 => brush.flags.italics = true,
                        23 => brush.flags.italics = false,

                        4 => brush.flags.underline = true,
                        24 => brush.flags.underline = false,

                        inline 30...37 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromXterm256((arg - 30) & 7);
                        },
                        38 => {
                            const result = handleTrueColor(context, &i) orelse break;
                            brush.flags.truecolor_foreground = result.truecolor;
                            brush.foreground = result.color;
                        },
                        39 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromXterm256(15);
                        },

                        inline 40...47 => |arg| {
                            brush.flags.truecolor_background = false;
                            brush.background = Buffer.Cell.Style.Color.fromXterm256((arg - 40) & 7);
                        },
                        48 => {
                            const result = handleTrueColor(context, &i) orelse break;
                            brush.flags.truecolor_background = result.truecolor;
                            brush.background = result.color;
                        },
                        49 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromXterm256(0);
                        },

                        inline 90...97 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromXterm256(8 + (arg - 90) & 7);
                        },
                        inline 100...107 => |arg| {
                            brush.flags.truecolor_background = false;
                            brush.background = Buffer.Cell.Style.Color.fromXterm256(8 + (arg - 100) & 7);
                        },

                        else => |first| {
                            std.log.warn("unimplemented style: {}", .{first});
                            break;
                        },
                    }
                }
            },

            else => return error.Unimplemented,
        }
    }

    fn handleTrueColor(context: *const escapes.Context, index: *u32) ?struct {
        truecolor: bool,
        color: Buffer.Cell.Style.Color,
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
                return .{ .truecolor = false, .color = Buffer.Cell.Style.Color.fromXterm256(@truncate(color_index)) };
            },
            else => {
                std.log.warn("unrecognized color mode: {}", .{mode});
                return null;
            },
        }
    }

    pub fn redraw(app: *App) !void {
        const zone = tracy.zone(@src(), "redraw");
        defer zone.end();

        app.needs_redraw = false;
        try app.drawBuffer();
    }

    fn drawBuffer(app: *App) !void {
        {
            const zone_clear = tracy.zone(@src(), "clear");
            defer zone_clear.end();
            if (!c.SDL_UpdateWindowSurface(app.window)) {
                return error.SdlUpdateWindowSurface;
            }
            if (!c.SDL_ClearSurface(app.surface, 0.0, 0.0, 0.0, 1.0)) {
                return error.SdlClearSurface;
            }
        }

        const buffer = app.buffer;
        const manager = app.font_manager;
        const surface = app.surface;

        const metrics = manager.metrics;

        const grid_width: u32 = buffer.size.cols * metrics.cell_width;
        const grid_height: u32 = buffer.size.rows * metrics.cell_height;

        const padding_x: c_int = @divTrunc(surface.w - std.math.lossyCast(c_int, grid_width), 2);
        const padding_y: c_int = @divTrunc(surface.h - std.math.lossyCast(c_int, grid_height), 2);

        var row: i32 = 0;
        var baseline = manager.metrics.baseline + padding_y;
        while (row < buffer.size.rows) : (row += 1) {
            const cells = buffer.getRow(row);

            var advance = padding_x;
            for (cells, 0..) |cell, col| {
                const zone_cell = tracy.zone(@src(), "draw cell");
                defer zone_cell.end();

                const style = cell.style;
                const flags = style.flags;

                const font_style: FontManager.Style = if (flags.bold)
                    (if (flags.italics) .bold_italic else .bold)
                else
                    (if (flags.italics) .italic else .regular);

                const glyph = manager.mapCodepoint(cell.codepoint, font_style) orelse continue;
                const raster = try manager.getGlyphRaster(glyph);

                const Color = Buffer.Cell.Style.Color;
                var back = if (flags.truecolor_background) style.background.rgb else style.background.palette.getRGB(Color.RGB.gray(0));
                var fore = if (flags.truecolor_foreground) style.foreground.rgb else style.foreground.palette.getRGB(Color.RGB.gray(255));

                if (row == buffer.cursor.row and col == buffer.cursor.col) {
                    std.mem.swap(Color.RGB, &back, &fore);
                }

                {
                    const zone_back = tracy.zone(@src(), "draw background");
                    defer zone_back.end();

                    const back_color = c.SDL_MapSurfaceRGB(surface, back.r, back.g, back.b);
                    _ = c.SDL_FillSurfaceRect(surface, &c.SDL_Rect{
                        .x = advance,
                        .y = baseline - std.math.lossyCast(c_int, metrics.cell_height) - metrics.descender,
                        .w = std.math.lossyCast(c_int, metrics.cell_width),
                        .h = std.math.lossyCast(c_int, metrics.cell_height),
                    }, back_color);
                }

                if (raster.surface.w != 0 and raster.surface.h != 0) {
                    const zone_glyph = tracy.zone(@src(), "blit glyph");
                    defer zone_glyph.end();

                    if (!raster.is_color) {
                        _ = c.SDL_SetSurfaceColorMod(raster.surface, fore.r, fore.g, fore.b);
                    }

                    _ = c.SDL_BlitSurface(raster.surface, null, surface, &c.SDL_Rect{
                        .x = advance + raster.left,
                        .y = baseline - raster.top,
                        .w = raster.surface.w,
                        .h = raster.surface.h,
                    });
                }

                advance += std.math.lossyCast(c_int, manager.metrics.cell_width);
            }

            baseline += std.math.lossyCast(c_int, manager.metrics.cell_height);
        }

        {
            const zone_present = tracy.zone(@src(), "present");
            defer zone_present.end();
            if (!c.SDL_UpdateWindowSurface(app.window)) {
                return error.SdlUpdateWindowSurface;
            }
        }
    }
};

pub const PrivateModes = enum(u16) {
    bracketed_paste = 2004,
};
