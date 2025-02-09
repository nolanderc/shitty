const std = @import("std");
const c = @import("c").includes;
const FontManager = @import("FontManager.zig");

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

    var font_manager = try FontManager.init(alloc, "Comic Code", 14.0);
    defer font_manager.deinit();

    var app = App{
        .alloc = alloc,
        .window = window,
        .surface = surface,
        .font_manager = &font_manager,
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

const App = struct {
    running: bool = true,

    alloc: std.mem.Allocator,

    window: *c.SDL_Window,
    surface: *c.SDL_Surface,
    needs_redraw: bool = true,

    text: std.ArrayListUnmanaged(u8) = .{},
    font_manager: *FontManager,

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
                const alt = (c.SDL_KMOD_ALT & event.key.mod) != 0;
                _ = alt; // autofix

                switch (event.key.key) {
                    c.SDLK_ESCAPE => {
                        if (shift) app.running = false;
                    },
                    c.SDLK_TAB => try app.pushText("😀🎉🌟🍕🚀"),
                    c.SDLK_RETURN => try app.pushText("\n"),
                    c.SDLK_1 => {
                        if (ctrl) {
                            try app.font_manager.setSize(app.font_manager.ptsize / 1.1);
                            app.needs_redraw = true;
                        }
                    },
                    c.SDLK_2 => {
                        if (ctrl) {
                            try app.font_manager.setSize(app.font_manager.ptsize * 1.1);
                            app.needs_redraw = true;
                        }
                    },
                    else => {},
                }

                if (event.key.key == c.SDLK_RETURN) {
                    try app.pushText("\n");
                    return;
                }
                if (event.key.key == c.SDLK_TAB) {
                    return;
                }
            },

            c.SDL_EVENT_WINDOW_RESIZED => {
                app.surface = c.SDL_GetWindowSurface(app.window) orelse return error.SdlWindowSurface;
            },

            c.SDL_EVENT_WINDOW_EXPOSED => app.needs_redraw = true,

            else => {},
        }
    }

    fn pushText(app: *App, text: []const u8) !void {
        std.log.debug("pushText({})", .{std.json.fmt(text, .{})});
        try app.text.appendSlice(app.alloc, text);
        app.needs_redraw = true;
    }

    pub fn redraw(app: *App) !void {
        if (!c.SDL_ClearSurface(app.surface, 0.0, 0.0, 0.0, 1.0)) return error.SdlClearSurface;

        try app.font_manager.draw(app.surface, app.text.items, .regular);

        if (!c.SDL_UpdateWindowSurface(app.window)) return error.SdlUpdateWindowSurface;
    }
};
