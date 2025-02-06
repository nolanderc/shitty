const std = @import("std");
const c = @import("c").includes;

const FontManager = @This();

const logFC = std.log.scoped(.FontConfig);

alloc: std.mem.Allocator,
finder: FontFinder,
font: Font,
engine: *c.TTF_TextEngine,

pub fn init(alloc: std.mem.Allocator, family: [*:0]const u8, ptsize: f32) !FontManager {
    const finder = try FontFinder.init();
    errdefer finder.deinit();

    const font = try Font.load(alloc, finder, family, ptsize);
    errdefer font.deinit(alloc);

    const engine = c.TTF_CreateSurfaceTextEngine() orelse return error.TextEngine;
    errdefer c.TTF_DestroySurfaceTextEngine(engine);

    return .{ .alloc = alloc, .finder = finder, .font = font, .engine = engine };
}

pub fn deinit(manager: FontManager) void {
    c.TTF_DestroySurfaceTextEngine(manager.engine);
    manager.font.deinit(manager.alloc);
    manager.finder.deinit();
}

pub fn draw(manager: FontManager, surface: *c.SDL_Surface, string: []const u8, style: Font.Style) !void {
    if (string.len == 0) return;

    const face = manager.font.styles.get(style);
    const text = c.TTF_CreateText(manager.engine, face.ttf, string.ptr, string.len) orelse return error.TextLayout;
    defer c.TTF_DestroyText(text);

    if (!c.TTF_DrawSurfaceText(text, 0, 0, surface)) return error.DrawText;
}

pub const FontFinder = struct {
    fontconfig: *c.FcConfig,

    pub fn init() !FontFinder {
        const fontconfig = c.FcInitLoadConfigAndFonts() orelse return error.LoadFontConfig;
        return .{ .fontconfig = fontconfig };
    }

    pub fn deinit(finder: FontFinder) void {
        c.FcConfigDestroy(finder.fontconfig);
    }

    pub fn find(finder: FontFinder, family: [*:0]const u8, style: Font.Style) !Iterator {
        const pattern = c.FcPatternCreate() orelse return error.CreatePattern;
        defer c.FcPatternDestroy(pattern);

        _ = c.FcPatternAddString(pattern, c.FC_FAMILY, family);

        _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, switch (style) {
            .bold, .bold_italic => c.FC_WEIGHT_BOLD,
            else => c.FC_WEIGHT_REGULAR,
        });

        _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, switch (style) {
            .italic, .bold_italic => c.FC_SLANT_ITALIC,
            else => c.FC_SLANT_ROMAN,
        });

        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const set = c.FcFontSort(finder.fontconfig, pattern, c.FcTrue, null, &result);
        errdefer if (set != null) c.FcFontSetDestroy(set);
        try check(result);

        if (set == null or set.*.nfont <= 0 or set.*.fonts == null) return error.NotFound;

        return Iterator{ .set = set };
    }

    pub const Iterator = struct {
        set: *c.FcFontSet,
        index: usize = 0,

        pub fn deinit(iter: Iterator) void {
            c.FcFontSetDestroy(iter.set);
        }

        pub fn next(iter: *Iterator) ?[*:0]const u8 {
            while (iter.index < iter.set.nfont) {
                const font = iter.set.fonts[iter.index];
                defer iter.index += 1;

                var path: [*c]u8 = null;
                check(c.FcPatternGetString(font, c.FC_FILE, 0, &path)) catch |err| {
                    logFC.warn("could not get font path: {}", .{err});
                    continue;
                };

                return path;
            } else {
                return null;
            }
        }
    };

    fn check(result: c.FcResult) !void {
        switch (result) {
            c.FcResultMatch => {},
            c.FcResultNoMatch => return error.NoMatch,
            c.FcResultTypeMismatch => return error.TypeMismatch,
            c.FcResultNoId => return error.NoId,
            c.FcResultOutOfMemory => return error.OutOfMemory,
            else => return error.Unknown,
        }
    }
};

pub const Font = struct {
    styles: std.EnumArray(Style, Face),

    pub const Style = enum {
        regular,
        bold,
        italic,
        bold_italic,
    };

    pub const Face = struct {
        ttf: *c.TTF_Font,
        fallbacks: std.ArrayListUnmanaged(*c.TTF_Font) = .{},

        pub fn open(path: [*:0]const u8, ptsize: f32) !Face {
            var face = Face{ .ttf = undefined };
            face.ttf = c.TTF_OpenFont(path, ptsize) orelse return error.LoadFontFace;
            return face;
        }

        pub fn addFallback(face: *Face, alloc: std.mem.Allocator, path: [*:0]const u8) !void {
            const ptsize = c.TTF_GetFontSize(face.ttf);
            var new = try Face.open(path, ptsize);
            errdefer new.deinit(alloc);
            if (!c.TTF_AddFallbackFont(face.ttf, new.ttf)) return error.OutOfMemory;
            try face.fallbacks.append(alloc, new.ttf);
        }

        pub fn deinit(face: Face, alloc: std.mem.Allocator) void {
            c.TTF_CloseFont(face.ttf);
            for (face.fallbacks.items) |ttf| c.TTF_CloseFont(ttf);
            var fallbacks = face.fallbacks;
            fallbacks.deinit(alloc);
        }
    };

    pub fn load(alloc: std.mem.Allocator, finder: FontFinder, family: [*:0]const u8, ptsize: f32) !Font {
        var styles: std.EnumArray(Style, Face) = undefined;

        for (std.meta.tags(Style)) |style| {
            var font_iterator = try finder.find(family, style);
            defer font_iterator.deinit();

            const base_path = font_iterator.next() orelse return error.NotFound;
            var base = try Face.open(base_path, ptsize);
            errdefer base.deinit(alloc);

            while (font_iterator.next()) |path| try base.addFallback(alloc, path);

            styles.set(style, base);
        }

        return .{ .styles = styles };
    }

    pub fn deinit(font: Font, alloc: std.mem.Allocator) void {
        for (font.styles.values) |face| face.deinit(alloc);
    }
};
