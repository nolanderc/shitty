const std = @import("std");
const c = @import("c").includes;
const FontManager = @import("FontManager.zig");
const Buffer = @import("Buffer.zig");

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
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "shitty",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    const surface = c.SDL_GetWindowSurface(window) orelse return error.SdlWindowSurface;

    if (!c.SDL_StartTextInput(window)) return error.SdlTextInput;

    var font_manager = try FontManager.init(alloc, "Comic Code", 16.0);
    defer font_manager.deinit();

    const initial_buffer_size = try computeBufferSize(window, &font_manager, 1e3);
    var buffer = try Buffer.init(alloc, initial_buffer_size);
    defer buffer.deinit(alloc);

    var app = App{
        .alloc = alloc,
        .window = window,
        .surface = surface,
        .font_manager = &font_manager,
        .buffer = &buffer,
    };
    defer app.deinit();

    try app.redraw();

    while (app.running) {
        var event: c.SDL_Event = undefined;

        if (!c.SDL_WaitEvent(&event)) break;
        try app.handleEvent(event);

        while (c.SDL_PollEvent(&event)) {
            try app.handleEvent(event);
        }

        if (app.needs_redraw) {
            app.needs_redraw = false;
            app.redraw() catch |err| {
                logSDL.err("could not redraw screen: {}", .{err});
                if (@errorReturnTrace()) |error_trace| {
                    std.debug.dumpStackTrace(error_trace.*);
                }
            };
        }
    }
}

fn computeBufferSize(window: *c.SDL_Window, font: *const FontManager, scrollback: u32) !Buffer.Size {
    var width: c_int = undefined;
    var height: c_int = undefined;
    if (!c.SDL_GetWindowSize(window, &width, &height)) return error.MissingWindowSize;

    const metrics = font.metrics;

    return .{
        .rows = @max(1, @as(u32, @intFromFloat(@floor(std.math.lossyCast(f32, height) / metrics.cell_height)))),
        .cols = @max(1, @as(u32, @intFromFloat(@floor(std.math.lossyCast(f32, width) / metrics.cell_width)))),
        .scrollback_rows = scrollback,
    };
}

const App = struct {
    running: bool = true,

    alloc: std.mem.Allocator,

    window: *c.SDL_Window,
    surface: *c.SDL_Surface,
    needs_redraw: bool = true,

    text: std.ArrayListUnmanaged(u8) = .{},
    font_manager: *FontManager,
    buffer: *Buffer,

    pub fn deinit(app: *App) void {
        app.text.deinit(app.alloc);
    }

    pub fn handleEvent(app: *App, event: c.SDL_Event) !void {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                app.running = false;
            },

            c.SDL_EVENT_TEXT_INPUT => {
                try app.pushText(std.mem.span(event.text.text));
            },

            c.SDL_EVENT_KEY_DOWN => {
                const shift = (c.SDL_KMOD_SHIFT & event.key.mod) != 0;
                const ctrl = (c.SDL_KMOD_CTRL & event.key.mod) != 0;

                switch (event.key.key) {
                    c.SDLK_ESCAPE => {
                        if (shift) app.running = false;
                    },
                    c.SDLK_TAB => try app.pushText("😀🎉🌟🍕🚀"),
                    c.SDLK_RETURN => {
                        try app.pushText("\n");
                    },
                    c.SDLK_1 => {
                        if (ctrl) try app.adjustFontSize(1.0 / 1.1);
                    },
                    c.SDLK_2 => {
                        if (ctrl) try app.adjustFontSize(1.1);
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
        const new_buffer_size = try computeBufferSize(app.window, app.font_manager, app.buffer.size.scrollback_rows);
        var new_buffer = try Buffer.init(app.alloc, new_buffer_size);
        app.buffer.reflowInto(&new_buffer);
        app.buffer.deinit(app.alloc);
        app.buffer.* = new_buffer;
    }

    fn pushText(app: *App, text: []const u8) !void {
        var remaining = text;
        while (remaining.len != 0) {
            const len = std.unicode.utf8ByteSequenceLength(remaining[0]) catch {
                app.buffer.write(std.unicode.replacement_character);
                remaining = remaining[1..];
                continue;
            };

            if (len > remaining.len) {
                std.log.warn("TODO: buffer incomplete codepoints: {}", .{std.json.fmt(remaining, .{})});
                break;
            }

            defer remaining = remaining[len..];

            const codepoint = std.unicode.utf8Decode(remaining[0..len]) catch std.unicode.replacement_character;
            app.buffer.write(codepoint);
        }

        app.needs_redraw = true;
    }

    pub fn redraw(app: *App) !void {
        if (!c.SDL_ClearSurface(app.surface, 0.0, 0.0, 0.0, 1.0)) return error.SdlClearSurface;

        try app.font_manager.draw(app.surface, app.buffer);

        if (!c.SDL_UpdateWindowSurface(app.window)) return error.SdlUpdateWindowSurface;
    }
};
