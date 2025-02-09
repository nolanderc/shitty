pub const includes = @cImport({
    @cInclude("SDL3/SDL_init.h");
    @cInclude("SDL3/SDL_video.h");
    @cInclude("SDL3/SDL_hints.h");

    @cInclude("fontconfig/fontconfig.h");
    @cInclude("freetype/freetype.h");
    @cInclude("harfbuzz/hb.h");
    @cInclude("harfbuzz/hb-ft.h");

    @cInclude("utf8proc.h");
});
