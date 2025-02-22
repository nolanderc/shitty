const std = @import("std");
const c = @import("c").includes;
const tracy = @import("tracy");

const Buffer = @import("Buffer.zig");

const FontManager = @This();

const logFC = std.log.scoped(.FontConfig);
const logFT = std.log.scoped(.FreeType);
const logHB = std.log.scoped(.HarfBuzz);

alloc: std.mem.Allocator,
finder: FontFinder,
freetype: FreeType,
faces: std.ArrayListUnmanaged(Face) = .{},
styles: [4]FallbackChain = [1]FallbackChain{.{}} ** 4,
glyph_cache: std.AutoHashMapUnmanaged(GlyphKey, GlyphRaster) = .{},
ptsize: f32,
metrics: Metrics,

unmappable_codepoints: std.AutoHashMapUnmanaged(u21, void) = .{},

pub const Style = packed struct(u2) {
    bold: bool = false,
    italic: bool = false,
};

pub const FallbackChain = struct { faces: []FaceIndex = &.{} };

pub const FaceIndex = enum(u32) { _ };

pub const GlyphKey = struct {
    face: FaceIndex,
    index: u16,
};

pub const GlyphRaster = struct {
    left: i32,
    top: i32,
    advance: f32,
    flags: Flags,
    bitmap: Bitmap,

    const Flags = packed struct(u32) {
        /// Some glyphs may already have their own color (eg., emojis) in which
        /// case we shouldn't modulate their color.
        is_color: bool,
        _: u31 = 0,
    };

    pub fn deinit(raster: GlyphRaster, alloc: std.mem.Allocator) void {
        raster.bitmap.deinit(alloc);
    }
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    buffer: []Pixel,

    const Pixel = [4]u8;

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        const buffer = try alloc.alloc(Pixel, @as(usize, width) * height);
        return .{ .width = width, .height = height, .buffer = buffer };
    }

    pub fn deinit(bitmap: Bitmap, alloc: std.mem.Allocator) void {
        alloc.free(bitmap.buffer);
    }

    pub fn getBGRA(bitmap: Bitmap) []u8 {
        const size = @as(usize, bitmap.width) * bitmap.height;
        return std.mem.sliceAsBytes(bitmap.buffer[0..size]);
    }

    pub fn dump(bitmap: Bitmap) void {
        for (0..@intCast(bitmap.height)) |row| {
            for (0..@intCast(bitmap.width)) |col| {
                const index = col + row * bitmap.width;
                const b, const g, const r, const a = bitmap.buffer[index];
                const fg: u8 = if (@max(r, g, b) > 0x7f) 0x00 else 0xff;
                std.debug.print("\x1b[38;2;{};{};{}m\x1b[48;2;{};{};{}m{x:02}", .{ fg, fg, fg, r, g, b, a });
            }
            std.debug.print("\x1b[m\n", .{});
        }
    }

    pub fn scaleToFitHeight(bitmap: *Bitmap, alloc: std.mem.Allocator, target_height: u32) void {
        if (bitmap.height <= target_height) return;
        if (target_height == 0) {
            bitmap.deinit(alloc);
            bitmap.* = .{ .width = 0, .height = 0, .buffer = &.{} };
            return;
        }

        const target_width = target_height * bitmap.width / bitmap.height;

        // First we try to do as many pixel-perfect downscales as possible.
        // These shoud be much faster than fractional scaling.
        while (bitmap.height / 2 >= target_height) {
            const width = bitmap.width;
            const height = bitmap.height;

            const new_width = (width / 2) + (width & 1);
            const new_height = (height / 2) + (height & 1);

            for (0..new_height) |row| {
                const row0 = @min(height - 1, 2 * row);
                const row1 = @min(height - 1, 2 * row + 1);

                for (0..new_width) |col| {
                    const col0 = @min(width - 1, 2 * col);
                    const col1 = @min(width - 1, 2 * col + 1);

                    const px00 = bitmap.buffer[col0 + row0 * width];
                    const px10 = bitmap.buffer[col1 + row0 * width];
                    const px01 = bitmap.buffer[col0 + row1 * width];
                    const px11 = bitmap.buffer[col1 + row1 * width];

                    var out: Pixel = undefined;
                    inline for (&out, px00, px10, px01, px11) |*res, px0, px1, px2, px3| {
                        const sum = @as(u16, px0) + @as(u16, px1) + @as(u16, px2) + @as(u16, px3);
                        res.* = @truncate(sum / 4);
                    }
                    bitmap.buffer[col + row * new_width] = out;
                }
            }

            bitmap.width = new_width;
            bitmap.height = new_height;
        }

        if (bitmap.height > target_height) {
            // Finally, we perform a fractional scaling step down to the target resolution.
            // ... TODO ...
            logFT.warn(
                "TODO: fractional scaling of bitmap glyph {}x{} -> {}x{}",
                .{ bitmap.width, bitmap.height, target_width, target_height },
            );
        }

        // try to shrink the buffer (if possible)
        const new_size = @as(usize, bitmap.width) * bitmap.height;
        if (alloc.resize(bitmap.buffer, new_size)) {
            bitmap.buffer.len = new_size;
        }
    }
};

pub const Metrics = struct {
    cell_height: u32,
    cell_width: u32,
    baseline: i32,
    descender: i32,
};

pub fn deinit(manager: *FontManager) void {
    manager.clearGlyphCache();
    manager.glyph_cache.deinit(manager.alloc);

    for (manager.styles) |chain| manager.alloc.free(chain.faces);
    for (manager.faces.items) |face| face.deinit();

    manager.faces.deinit(manager.alloc);
    manager.freetype.deinit();
    manager.finder.deinit();
}

fn clearGlyphCache(manager: *FontManager) void {
    var glyphs = manager.glyph_cache.valueIterator();
    while (glyphs.next()) |raster| raster.deinit(manager.alloc);
    manager.glyph_cache.clearRetainingCapacity();
    manager.unmappable_codepoints.clearAndFree(manager.alloc);
}

pub fn init(alloc: std.mem.Allocator, family: [*:0]const u8, ptsize: f32) !FontManager {
    var manager = blk: {
        const finder = try FontFinder.init();
        errdefer finder.deinit();
        const freetype = try FreeType.init();
        break :blk FontManager{
            .alloc = alloc,
            .finder = finder,
            .freetype = freetype,
            .ptsize = ptsize,
            .metrics = undefined,
        };
    };
    errdefer manager.deinit();

    for (0..4) |style_index| {
        const style: Style = @bitCast(@as(u2, @truncate(style_index)));

        var iterator = try manager.finder.find(family, style);
        defer iterator.deinit();

        const chain_size = iterator.count();
        if (chain_size == 0 and !style.bold and !style.italic) return error.NotFound;

        const chain = try alloc.alloc(FaceIndex, chain_size);
        errdefer alloc.free(chain);

        while (iterator.next()) |path| {
            errdefer logFT.err("could not load font: {s}", .{path});
            const face = try Face.load(manager.freetype, path, ptsize);
            errdefer face.deinit();
            chain[iterator.index - 1] = @enumFromInt(manager.faces.items.len);
            try manager.faces.append(alloc, face);
        }

        manager.styles[style_index] = .{ .faces = chain };
    }

    manager.metrics = manager.computeMetrics();

    return manager;
}

pub fn setSize(manager: *FontManager, ptsize: f32) !void {
    manager.clearGlyphCache();
    for (manager.faces.items) |face| try face.setSize(ptsize);
    manager.ptsize = ptsize;
    manager.metrics = manager.computeMetrics();
}

fn computeMetrics(manager: *FontManager) Metrics {
    const primary_index = manager.styles[0].faces[0];
    const primary: *c.FT_FaceRec = manager.faces.items[@intFromEnum(primary_index)].ft;
    const pt_scale = manager.ptsize / std.math.lossyCast(f32, primary.units_per_EM);

    const line_height = pt_scale * std.math.lossyCast(f32, primary.height);
    const advance = pt_scale * std.math.lossyCast(f32, primary.max_advance_width);
    const descender = pt_scale * std.math.lossyCast(f32, primary.descender);

    const cell_width = @ceil(advance);
    const cell_height = @ceil(line_height);

    return .{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .baseline = @intFromFloat(@round(cell_height + descender)),
        .descender = @intFromFloat(@round(descender)),
    };
}

pub fn getGlyphRaster(manager: *FontManager, glyph: GlyphKey) !GlyphRaster {
    const zone = tracy.zone(@src(), "lookup glyph");
    defer zone.end();

    const entry = try manager.glyph_cache.getOrPut(manager.alloc, glyph);
    errdefer manager.glyph_cache.removeByPtr(entry.key_ptr);
    if (!entry.found_existing) entry.value_ptr.* = try manager.rasterizeGlyph(glyph);
    return entry.value_ptr.*;
}

fn rasterizeGlyph(manager: *FontManager, glyph: GlyphKey) !GlyphRaster {
    const zone = tracy.zone(@src(), "rasterizeGlyph");
    defer zone.end();

    const face = manager.faces.items[@intFromEnum(glyph.face)];

    try FreeType.check(c.FT_Load_Glyph(face.ft, glyph.index, c.FT_LOAD_COLOR));
    const slot: *c.FT_GlyphSlotRec = face.ft.*.glyph;
    const is_bitmap = slot.format == c.FT_GLYPH_FORMAT_BITMAP;

    try FreeType.check(c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL));

    const buffer = slot.bitmap.buffer;
    const width = slot.bitmap.width;
    const height = slot.bitmap.rows;
    const pixel_mode: FreeType.PixelMode = @enumFromInt(slot.bitmap.pixel_mode);

    var bitmap = try Bitmap.init(manager.alloc, width, height);
    const bitmap_pitch: usize = @abs(slot.bitmap.pitch);

    switch (pixel_mode) {
        .gray => {
            for (0..height) |row| {
                const row_bytes = buffer[row * bitmap_pitch ..][0..width];
                const surface_bgra = bitmap.buffer[row * width ..][0..width];
                for (row_bytes, surface_bgra) |gray, *bgra| bgra.* = [1]u8{gray} ** 4;
            }
        },
        .bgra => {
            for (0..height) |row| {
                const row_bytes = buffer[row * bitmap_pitch ..][0 .. width * 4];
                const surface_bgra = bitmap.buffer[row * width ..][0..width];
                @memcpy(std.mem.sliceAsBytes(surface_bgra), std.mem.sliceAsBytes(row_bytes));
            }
        },
        else => {
            logFT.warn("unsupported bitmap format: {}", .{pixel_mode});
            return error.UnsupportedBitmapFormat;
        },
    }

    var scale: f32 = 1.0;

    if (is_bitmap) {
        bitmap.scaleToFitHeight(manager.alloc, manager.metrics.cell_height);
        scale = @as(f32, @floatFromInt(manager.metrics.cell_height)) / @as(f32, @floatFromInt(height));
    }

    return .{
        .left = @intFromFloat(@floor(scale * @as(f32, @floatFromInt(slot.bitmap_left)))),
        .top = @intFromFloat(@floor(scale * @as(f32, @floatFromInt(slot.bitmap_top)))),
        .advance = scale * @as(f32, @floatFromInt(slot.advance.x)) / (1 << 6),
        .flags = .{ .is_color = pixel_mode == .bgra },
        .bitmap = bitmap,
    };
}

pub fn mapCodepoint(manager: *FontManager, codepoint: u21, style: Style) ?GlyphKey {
    const zone = tracy.zone(@src(), "mapCodepoint");
    defer zone.end();

    const chain = manager.styles[@as(u2, @bitCast(style))];
    var query = codepoint;
    while (true) {
        for (chain.faces) |face_index| {
            const face = manager.faces.items[@intFromEnum(face_index)];
            const glyph_index = c.FT_Get_Char_Index(face.ft, query);
            if (glyph_index == 0) continue;
            return .{ .face = face_index, .index = @intCast(glyph_index) };
        } else {
            if (manager.unmappable_codepoints.getOrPut(manager.alloc, query) catch null) |gop| {
                if (!gop.found_existing) {
                    logFT.warn("could not map codepoint: {} ({u})", .{ query, query });
                }
            }

            if (query == std.unicode.replacement_character) return null;
            query = std.unicode.replacement_character;
        }
    }
}

pub const Utf8Iterator = struct {
    string: []const u8,

    pub fn init(string: []const u8) Utf8Iterator {
        return .{ .string = string };
    }

    pub fn next(iter: *Utf8Iterator) ?u21 {
        if (iter.string.len == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(iter.string[0]) catch {
            iter.string = iter.string[1..];
            return std.unicode.replacement_character;
        };
        defer iter.string = iter.string[len..];
        return std.unicode.utf8Decode(iter.string[0..len]) catch std.unicode.replacement_character;
    }
};

pub const FontFinder = struct {
    fontconfig: *c.FcConfig,

    pub fn init() !FontFinder {
        const fontconfig = c.FcInitLoadConfigAndFonts() orelse return error.LoadFontConfig;
        return .{ .fontconfig = fontconfig };
    }

    pub fn deinit(finder: FontFinder) void {
        c.FcConfigDestroy(finder.fontconfig);
    }

    pub fn find(finder: FontFinder, family: [*:0]const u8, style: Style) !Iterator {
        const pattern = c.FcPatternCreate() orelse return error.CreatePattern;
        defer c.FcPatternDestroy(pattern);

        _ = c.FcPatternAddString(pattern, c.FC_FAMILY, family);

        _ = c.FcPatternAddInteger(
            pattern,
            c.FC_WEIGHT,
            if (style.bold) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR,
        );

        _ = c.FcPatternAddInteger(
            pattern,
            c.FC_SLANT,
            if (style.italic) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN,
        );

        if (c.FcConfigSubstitute(finder.fontconfig, pattern, c.FcMatchPattern) != c.FcTrue) return error.Substitute;
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

        pub fn count(iter: Iterator) usize {
            return @intCast(iter.set.nfont);
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

pub const FreeType = struct {
    lib: c.FT_Library,

    pub fn init() !FreeType {
        var freetype: FreeType = undefined;
        try check(c.FT_Init_FreeType(&freetype.lib));

        return freetype;
    }

    pub fn deinit(freetype: FreeType) void {
        _ = c.FT_Done_FreeType(freetype.lib);
    }

    pub fn check(err: c.FT_Error) !void {
        switch (err) {
            c.FT_Err_Ok => {},
            c.FT_Err_Cannot_Open_Resource => return error.CannotOpenResource,
            c.FT_Err_Unknown_File_Format => return error.UnknownFileFormat,
            c.FT_Err_Invalid_File_Format => return error.InvalidFileFormat,
            c.FT_Err_Invalid_Version => return error.InvalidVersion,
            c.FT_Err_Lower_Module_Version => return error.LowerModuleVersion,
            c.FT_Err_Invalid_Argument => return error.InvalidArgument,
            c.FT_Err_Unimplemented_Feature => return error.UnimplementedFeature,
            c.FT_Err_Invalid_Table => return error.InvalidTable,
            c.FT_Err_Invalid_Offset => return error.InvalidOffset,
            c.FT_Err_Array_Too_Large => return error.ArrayTooLarge,
            c.FT_Err_Missing_Module => return error.MissingModule,
            c.FT_Err_Missing_Property => return error.MissingProperty,
            c.FT_Err_Invalid_Glyph_Index => return error.InvalidGlyphIndex,
            c.FT_Err_Invalid_Character_Code => return error.InvalidCharacterCode,
            c.FT_Err_Invalid_Glyph_Format => return error.InvalidGlyphFormat,
            c.FT_Err_Cannot_Render_Glyph => return error.CannotRenderGlyph,
            c.FT_Err_Invalid_Outline => return error.InvalidOutline,
            c.FT_Err_Invalid_Composite => return error.InvalidComposite,
            c.FT_Err_Too_Many_Hints => return error.TooManyHints,
            c.FT_Err_Invalid_Pixel_Size => return error.InvalidPixelSize,
            c.FT_Err_Invalid_SVG_Document => return error.InvalidSVGDocument,
            c.FT_Err_Invalid_Handle => return error.InvalidHandle,
            c.FT_Err_Invalid_Library_Handle => return error.InvalidLibraryHandle,
            c.FT_Err_Invalid_Driver_Handle => return error.InvalidDriverHandle,
            c.FT_Err_Invalid_Face_Handle => return error.InvalidFaceHandle,
            c.FT_Err_Invalid_Size_Handle => return error.InvalidSizeHandle,
            c.FT_Err_Invalid_Slot_Handle => return error.InvalidSlotHandle,
            c.FT_Err_Invalid_CharMap_Handle => return error.InvalidCharMapHandle,
            c.FT_Err_Invalid_Cache_Handle => return error.InvalidCacheHandle,
            c.FT_Err_Invalid_Stream_Handle => return error.InvalidStreamHandle,
            c.FT_Err_Too_Many_Drivers => return error.TooManyDrivers,
            c.FT_Err_Too_Many_Extensions => return error.TooManyExtensions,
            c.FT_Err_Out_Of_Memory => return error.OutOfMemory,
            c.FT_Err_Unlisted_Object => return error.UnlistedObject,
            c.FT_Err_Cannot_Open_Stream => return error.CannotOpenStream,
            c.FT_Err_Invalid_Stream_Seek => return error.InvalidStreamSeek,
            c.FT_Err_Invalid_Stream_Skip => return error.InvalidStreamSkip,
            c.FT_Err_Invalid_Stream_Read => return error.InvalidStreamRead,
            c.FT_Err_Invalid_Stream_Operation => return error.InvalidStreamOperation,
            c.FT_Err_Invalid_Frame_Operation => return error.InvalidFrameOperation,
            c.FT_Err_Nested_Frame_Access => return error.NestedFrameAccess,
            c.FT_Err_Invalid_Frame_Read => return error.InvalidFrameRead,
            c.FT_Err_Raster_Uninitialized => return error.RasterUninitialized,
            c.FT_Err_Raster_Corrupted => return error.RasterCorrupted,
            c.FT_Err_Raster_Overflow => return error.RasterOverflow,
            c.FT_Err_Raster_Negative_Height => return error.RasterNegativeHeight,
            c.FT_Err_Too_Many_Caches => return error.TooManyCaches,
            c.FT_Err_Invalid_Opcode => return error.InvalidOpcode,
            c.FT_Err_Too_Few_Arguments => return error.TooFewArguments,
            c.FT_Err_Stack_Overflow => return error.StackOverflow,
            c.FT_Err_Code_Overflow => return error.CodeOverflow,
            c.FT_Err_Bad_Argument => return error.BadArgument,
            c.FT_Err_Divide_By_Zero => return error.DivideByZero,
            c.FT_Err_Invalid_Reference => return error.InvalidReference,
            c.FT_Err_Debug_OpCode => return error.DebugOpCode,
            c.FT_Err_ENDF_In_Exec_Stream => return error.ENDFInExec_Stream,
            c.FT_Err_Nested_DEFS => return error.NestedDEFS,
            c.FT_Err_Invalid_CodeRange => return error.InvalidCodeRange,
            c.FT_Err_Execution_Too_Long => return error.ExecutionTooLong,
            c.FT_Err_Too_Many_Function_Defs => return error.TooManyFunctionDefs,
            c.FT_Err_Too_Many_Instruction_Defs => return error.TooManyInstructionDefs,
            c.FT_Err_Table_Missing => return error.TableMissing,
            c.FT_Err_Horiz_Header_Missing => return error.HorizHeaderMissing,
            c.FT_Err_Locations_Missing => return error.LocationsMissing,
            c.FT_Err_Name_Table_Missing => return error.NameTableMissing,
            c.FT_Err_CMap_Table_Missing => return error.CMapTableMissing,
            c.FT_Err_Hmtx_Table_Missing => return error.HmtxTableMissing,
            c.FT_Err_Post_Table_Missing => return error.PostTableMissing,
            c.FT_Err_Invalid_Horiz_Metrics => return error.InvalidHorizMetrics,
            c.FT_Err_Invalid_CharMap_Format => return error.InvalidCharMapFormat,
            c.FT_Err_Invalid_PPem => return error.InvalidPPem,
            c.FT_Err_Invalid_Vert_Metrics => return error.InvalidVertMetrics,
            c.FT_Err_Could_Not_Find_Context => return error.CouldNotFindContext,
            c.FT_Err_Invalid_Post_Table_Format => return error.InvalidPostTableFormat,
            c.FT_Err_Invalid_Post_Table => return error.InvalidPostTable,
            c.FT_Err_DEF_In_Glyf_Bytecode => return error.DEFInGlyf_Bytecode,
            c.FT_Err_Missing_Bitmap => return error.MissingBitmap,
            c.FT_Err_Missing_SVG_Hooks => return error.MissingSVGHooks,
            c.FT_Err_Syntax_Error => return error.SyntaxError,
            c.FT_Err_Stack_Underflow => return error.StackUnderflow,
            c.FT_Err_Ignore => return error.Ignore,
            c.FT_Err_No_Unicode_Glyph_Name => return error.NoUnicodeGlyph_Name,
            c.FT_Err_Glyph_Too_Big => return error.GlyphTooBig,
            c.FT_Err_Missing_Startfont_Field => return error.MissingStartfontField,
            c.FT_Err_Missing_Font_Field => return error.MissingFontField,
            c.FT_Err_Missing_Size_Field => return error.MissingSizeField,
            c.FT_Err_Missing_Fontboundingbox_Field => return error.MissingFontboundingboxField,
            c.FT_Err_Missing_Chars_Field => return error.MissingCharsField,
            c.FT_Err_Missing_Startchar_Field => return error.MissingStartcharField,
            c.FT_Err_Missing_Encoding_Field => return error.MissingEncodingField,
            c.FT_Err_Missing_Bbx_Field => return error.MissingBbxField,
            c.FT_Err_Bbx_Too_Big => return error.BbxTooBig,
            c.FT_Err_Corrupted_Font_Header => return error.CorruptedFontHeader,
            c.FT_Err_Corrupted_Font_Glyphs => return error.CorruptedFontGlyphs,
            else => {
                logFT.err("{s} (code={})", .{ c.FT_Error_String(err) orelse "???".ptr, err });
                return error.FreeTypeUnknown;
            },
        }
    }

    pub const PixelMode = enum(u8) {
        none = c.FT_PIXEL_MODE_NONE,
        mono = c.FT_PIXEL_MODE_MONO,
        gray = c.FT_PIXEL_MODE_GRAY,
        gray2 = c.FT_PIXEL_MODE_GRAY2,
        gray4 = c.FT_PIXEL_MODE_GRAY4,
        lcd = c.FT_PIXEL_MODE_LCD,
        lcd_v = c.FT_PIXEL_MODE_LCD_V,
        bgra = c.FT_PIXEL_MODE_BGRA,
        _,
    };

    fn f26dot6(value: f32) c.FT_F26Dot6 {
        return @intFromFloat(@round(value * (1 << 6)));
    }
};

pub const Face = struct {
    ft: c.FT_Face,
    hb: *c.hb_font_t,

    pub fn load(freetype: FreeType, path: [*:0]const u8, ptsize: f32) !Face {
        var face: c.FT_Face = undefined;
        try FreeType.check(c.FT_New_Face(freetype.lib, path, 0, &face));
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_HAS_FIXED_SIZES(face)) {
            try FreeType.check(c.FT_Select_Size(face, 0));
        } else {
            try FreeType.check(c.FT_Set_Char_Size(face, 0, FreeType.f26dot6(ptsize), 0, 0));
        }

        const font = c.hb_ft_font_create_referenced(face) orelse return error.HarfbuzzCreate;

        return .{ .ft = face, .hb = font };
    }

    pub fn deinit(font: Face) void {
        c.hb_font_destroy(font.hb);
        _ = c.FT_Done_Face(font.ft);
    }

    pub fn getName(face: Face) ?[*:0]const u8 {
        return @ptrCast(c.FT_Get_Postscript_Name(face.ft));
    }

    pub fn setSize(face: Face, ptsize: f32) !void {
        if (c.FT_HAS_FIXED_SIZES(face.ft)) return;
        try FreeType.check(c.FT_Set_Char_Size(face.ft, 0, FreeType.f26dot6(ptsize), 0, 0));
        c.hb_ft_font_changed(face.hb);
    }
};
