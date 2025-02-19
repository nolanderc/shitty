pub const includes = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xrender.h");

    @cInclude("fontconfig/fontconfig.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftmodapi.h");
    @cInclude("harfbuzz/hb.h");
    @cInclude("harfbuzz/hb-ft.h");

    @cInclude("utf8proc.h");
});
