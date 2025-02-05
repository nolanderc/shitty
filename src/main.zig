const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub fn main() !void {
    std.log.info("hello", .{});

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("shitty", 800, 600, c.SDL_WINDOW_RESIZABLE) orelse return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    if (!c.SDL_StartTextInput(window)) return error.SdlTextInput;

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (running and c.SDL_WaitEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
                c.SDL_EVENT_TEXT_INPUT => {
                    std.log.info("text: {s}", .{event.text.text});
                },
                else => continue,
            }
        }
    }
}
