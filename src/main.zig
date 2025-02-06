const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const logSDL = std.log.scoped(.SDL);

pub fn main() !void {
    run() catch |err| {
        const sdl_error = c.SDL_GetError();
        if (sdl_error != null) {
            logSDL.err("{s}", .{sdl_error});
        }

        std.log.err("unexpected error: {}", .{err});
        if (@errorReturnTrace()) |error_trace| {
            std.debug.dumpStackTrace(error_trace.*);
        }
    };
}

fn run() !void {
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

    var app = App{ .window = window, .surface = surface };
    while (app.running) {
        var event: c.SDL_Event = undefined;

        if (!c.SDL_WaitEvent(&event)) break;
        try app.handleEvent(event);

        while (c.SDL_PollEvent(&event)) {
            try app.handleEvent(event);
        }

        app.redraw() catch |err| {
            logSDL.err("could not redraw screen: {}", .{err});
            if (@errorReturnTrace()) |error_trace| {
                std.debug.dumpStackTrace(error_trace.*);
            }
        };
    }
}

const App = struct {
    running: bool = true,
    window: *c.SDL_Window,
    surface: *c.SDL_Surface,
    offset: i32 = 0,

    pub fn handleEvent(app: *App, event: c.SDL_Event) !void {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                app.running = false;
            },

            c.SDL_EVENT_TEXT_INPUT => {
                std.log.info("text: {s}", .{event.text.text});
                app.offset += 16;
            },

            c.SDL_EVENT_KEY_DOWN => {
                const shift = (c.SDL_KMOD_SHIFT & event.key.mod) != 0;
                if (shift and event.key.key == c.SDLK_ESCAPE) {
                    app.running = false;
                }
            },

            c.SDL_EVENT_WINDOW_RESIZED => {
                app.surface = c.SDL_GetWindowSurface(app.window) orelse return error.SdlWindowSurface;
            },

            else => {},
        }
    }

    pub fn redraw(app: *App) !void {
        if (!c.SDL_ClearSurface(app.surface, 1.0, 1.0, 1.0, 1.0)) return error.SdlClearSurface;

        const rect = c.SDL_Rect{ .x = app.offset, .y = 0, .w = 16, .h = 32 };
        _ = c.SDL_FillSurfaceRect(app.surface, &rect, 0xFF000000);

        if (!c.SDL_UpdateWindowSurface(app.window)) return error.SdlUpdateWindowSurface;
    }
};
