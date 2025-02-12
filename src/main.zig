const std = @import("std");
const c = @import("c").includes;
const FontManager = @import("FontManager.zig");
const Buffer = @import("Buffer.zig");
const pty = @import("pty.zig");
const escapes = @import("escapes.zig");

const logSDL = std.log.scoped(.SDL);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();

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
    _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
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

        _ = try std.posix.poll(&poll_fds, -1);
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
            const buffer = try app.input_buffer.writableWithSize(std.mem.page_size);
            const count = shell.io.read(buffer) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (count > 0) {
                app.input_buffer.update(count);
                try app.processInput();
            }
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                logSDL.err("could not redraw screen: {}", .{err});
                if (@errorReturnTrace()) |error_trace| {
                    std.debug.dumpStackTrace(error_trace.*);
                }
            };
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
        .rows = @max(1, @as(u32, @intFromFloat(@floor(std.math.lossyCast(f32, window_size[1]) / metrics.cell_height)))),
        .cols = @max(1, @as(u32, @intFromFloat(@floor(std.math.lossyCast(f32, window_size[0]) / metrics.cell_width)))),
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
        try app.font_manager.setSize(app.font_manager.ptsize * multiplier);
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

        while (app.input_buffer.count != 0) {
            const bytes = @constCast(app.input_buffer.readableSlice(0));
            const len, const command = escapes.parse(bytes, &context);
            const fmtSequence = std.json.fmt(bytes[0..len], .{});

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
                var i: usize = 0;
                while (i < @max(1, context.args_count)) : (i += 1) {
                    switch (context.get(i, 0)) {
                        0 => brush.* = .{},

                        1 => brush.flags.bold = true,
                        22 => brush.flags.bold = false,

                        3 => brush.flags.italics = true,
                        23 => brush.flags.italics = false,

                        4 => brush.flags.underline = true,
                        24 => brush.flags.underline = false,

                        inline 30...37 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromIndex((arg - 30) & 7);
                        },
                        39 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromIndex(15);
                        },

                        inline 40...47 => |arg| {
                            brush.flags.truecolor_background = false;
                            brush.background = Buffer.Cell.Style.Color.fromIndex((arg - 40) & 7);
                        },
                        49 => {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromIndex(0);
                        },

                        inline 90...97 => |arg| {
                            brush.flags.truecolor_foreground = false;
                            brush.foreground = Buffer.Cell.Style.Color.fromIndex(8 + (arg - 90) & 7);
                        },
                        inline 100...107 => |arg| {
                            brush.flags.truecolor_background = false;
                            brush.background = Buffer.Cell.Style.Color.fromIndex(8 + (arg - 100) & 7);
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

    pub fn redraw(app: *App) !void {
        app.needs_redraw = false;

        if (!c.SDL_ClearSurface(app.surface, 0.0, 0.0, 0.0, 1.0)) return error.SdlClearSurface;

        try app.drawBuffer();

        if (!c.SDL_UpdateWindowSurface(app.window)) return error.SdlUpdateWindowSurface;
    }

    fn drawBuffer(app: *App) !void {
        const buffer = app.buffer;
        const manager = app.font_manager;
        const surface = app.surface;

        const grid_width = std.math.lossyCast(f32, buffer.size.cols) * manager.metrics.cell_width;
        const grid_height = std.math.lossyCast(f32, buffer.size.rows) * manager.metrics.cell_height;

        const padding_x = 0.5 * (std.math.lossyCast(f32, surface.w) - grid_width);
        const padding_y = 0.5 * (std.math.lossyCast(f32, surface.h) - grid_height);

        var row: i32 = 0;
        var baseline: f32 = manager.metrics.baseline + padding_y;
        while (row < buffer.size.rows) : (row += 1) {
            const cells = buffer.getRow(row);

            var advance: f32 = padding_x;
            for (cells) |cell| {
                const style: FontManager.Style = if (cell.style.flags.bold)
                    (if (cell.style.flags.italics) .bold_italic else .bold)
                else
                    (if (cell.style.flags.italics) .italic else .regular);

                const glyph = manager.mapCodepoint(cell.codepoint, style) orelse continue;
                const raster = try manager.getGlyphRaster(glyph);

                _ = c.SDL_BlitSurface(raster.surface, null, surface, &c.SDL_Rect{
                    .x = @intFromFloat(@floor(advance + raster.left)),
                    .y = @intFromFloat(@floor(baseline - raster.top)),
                    .w = raster.surface.w,
                    .h = raster.surface.h,
                });

                advance += manager.metrics.cell_width;
            }

            baseline += manager.metrics.cell_height;
        }
    }
};

pub const PrivateModes = enum(u16) {
    bracketed_paste = 2004,
};
