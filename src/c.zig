pub const includes = @cImport({
    @cInclude("SDL3/SDL_init.h");
    @cInclude("SDL3/SDL_video.h");
    @cInclude("SDL3/SDL_hints.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("fontconfig/fontconfig.h");
});
