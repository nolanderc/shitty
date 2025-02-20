const std = @import("std");

const c = @import("c").includes;
const tracy = @import("tracy");

const FontManager = @import("../FontManager.zig");
const Buffer = @import("../Buffer.zig");
const App = @import("root").App;
const Modifiers = @import("../platform.zig").Modifiers;
const Key = @import("../platform.zig").Key;

const log = std.log.scoped(.X11);

pub fn init(alloc: std.mem.Allocator) !X11 {
    const zone = tracy.zone(@src(), "init X11");
    defer zone.end();

    const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
    const render = try Render.init(display);

    const window = try createWindow(display, 800, 600);
    _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

    var wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", 0);
    _ = c.XSetWMProtocols(display, window, &wm_delete, 1);

    const input_method = c.XOpenIM(display, null, null, null) orelse return error.CannotOpenInputMethod;
    const input_context = c.XCreateIC(
        input_method,

        c.XNInputStyle,
        c.XIMPreeditNothing | c.XIMStatusNothing,

        c.XNClientWindow,
        window,

        c.XNFocusWindow,
        window,

        @as(usize, 0),
    ) orelse return error.CannotCreateInputContext;

    const glyphset = c.XRenderCreateGlyphSet(display, render.formats.argb32);
    const graphics_context = c.XCreateGC(display, window, 0, null);

    _ = c.XMapWindow(display, window);
    _ = c.XFlush(display);

    const window_surface = try Surface.initWindow(display, window);

    return .{
        .alloc = alloc,
        .display = display,
        .render = render,
        .window = window,
        .window_surface = window_surface,
        .graphics_context = graphics_context,
        .input_method = input_method,
        .input_context = input_context,
        .atoms = .{ .wm_delete = wm_delete },
        .glyphset = glyphset,
    };
}

pub const Platform = X11;
pub const X11 = struct {
    alloc: std.mem.Allocator,

    display: *c.Display,
    render: Render,

    window: c.Window,
    should_close: bool = false,
    needs_redraw: bool = true,

    window_surface: Surface,
    graphics_context: c.GC,

    input_method: c.XIM,
    input_context: c.XIC,

    atoms: struct {
        wm_delete: c.Atom,
    },

    glyphset: c.GlyphSet,
    mapped_codepoints: std.DynamicBitSetUnmanaged = .{},

    pub fn deinit(x11: *X11) void {
        _ = c.XCloseDisplay(x11.display);
        x11.mapped_codepoints.deinit(x11.alloc);
    }

    pub fn invalidateCaches(x11: *X11) void {
        x11.mapped_codepoints.unsetAll();

        c.XRenderFreeGlyphSet(x11.display, x11.glyphset);
        x11.glyphset = c.XRenderCreateGlyphSet(x11.display, x11.render.formats.argb32);
    }

    pub fn file(x11: *X11) std.fs.File {
        return .{ .handle = c.XConnectionNumber(x11.display) };
    }

    pub fn getWindowSize(x11: *X11) ![2]u32 {
        return getWindowGeometry(x11.display, x11.window);
    }

    pub fn getDisplayScale(x11: *X11) !f32 {
        _ = x11; // autofix
        // TODO: determine properly
        return 1.0;
    }

    pub fn setWindowTitle(x11: *X11, title: [:0]const u8) void {
        _ = c.XStoreName(x11.display, x11.window, title.ptr);
    }

    pub fn pollEvent(x11: *X11, app: *App) !void {
        const display = x11.display;
        var event: c.XEvent = undefined;
        while (c.XPending(display) != 0) {
            _ = c.XNextEvent(display, &event);

            switch (event.type) {
                c.DestroyNotify => x11.should_close = true,
                c.ClientMessage => {
                    if (event.xclient.data.l[0] == x11.atoms.wm_delete) x11.should_close = true;
                },

                c.Expose => x11.needs_redraw = true,

                c.ConfigureNotify => {
                    const conf = &event.xconfigure;
                    log.info("resized: {}x{}", .{ conf.width, conf.height });

                    x11.window_surface.deinit(display);
                    const new_surface = try Surface.initWindow(display, x11.window);
                    x11.window_surface = new_surface;

                    try app.updateBufferSize();

                    x11.needs_redraw = true;
                },

                c.KeyPress => {
                    var keysym: c.KeySym = undefined;
                    var status: c.Status = undefined;

                    var buffer: [512]u8 = undefined;
                    const len = c.Xutf8LookupString(x11.input_context, &event.xkey, &buffer, buffer.len, &keysym, &status);
                    const text = buffer[0..@max(0, len)];

                    var has_text = false;
                    var has_keysym = false;
                    switch (status) {
                        c.XBufferOverflow => return error.BufferOverflow, // TODO: allocate more memory if needed
                        c.XLookupNone => {},
                        c.XLookupChars => {
                            has_text = true;
                        },
                        c.XLookupKeySym => {
                            has_keysym = true;
                        },
                        c.XLookupBoth => {
                            has_text = true;
                            has_keysym = true;
                        },
                        else => {
                            log.warn("unexpected status from Xutf8LookupString: {}", .{status});
                            continue;
                        },
                    }

                    if (has_keysym) {
                        const mods = Modifiers{
                            .ctrl = event.xkey.state & c.ControlMask != 0,
                            .alt = event.xkey.state & c.Mod1Mask != 0,
                            .shift = event.xkey.state & c.ShiftMask != 0,
                        };
                        if (mapKey(keysym)) |key| {
                            if (try app.handleShortcut(mods, key)) {
                                continue;
                            }
                        }
                    }

                    if (has_text) {
                        try app.output_buffer.write(text);
                    }
                },

                c.KeyRelease,
                c.ReparentNotify,
                c.MapNotify,
                => {},

                else => log.debug("unknown event: {}", .{event.type}),
            }
        }
    }

    fn mapKey(keysym: c.KeySym) ?Key {
        return switch (keysym) {
            c.XK_0 => .@"0",
            c.XK_1 => .@"1",
            c.XK_2 => .@"2",
            c.XK_3 => .@"3",
            c.XK_4 => .@"4",
            c.XK_5 => .@"5",
            c.XK_6 => .@"6",
            c.XK_7 => .@"7",
            c.XK_8 => .@"8",
            c.XK_9 => .@"9",

            c.XK_Escape => .escape,

            else => return null,
        };
    }

    pub fn redraw(x11: *X11, manager: *FontManager, buffer: *Buffer) !void {
        x11.needs_redraw = false;

        const alloc = x11.alloc;
        const display = x11.display;
        const size = buffer.size;
        const surface = x11.window_surface;
        const picture = surface.picture;

        const grid_width = size.cols * manager.metrics.cell_width;
        const grid_height = size.rows * manager.metrics.cell_height;

        const padding_x = (std.math.lossyCast(i32, surface.width) -| std.math.lossyCast(i32, grid_width)) >> 1;
        const padding_y = (std.math.lossyCast(i32, surface.height) -| std.math.lossyCast(i32, grid_height)) >> 1;

        {
            const zone_missing_codepoints = tracy.zone(@src(), "detect unmapped codepoints");
            defer zone_missing_codepoints.end();

            var glyphs = std.MultiArrayList(struct { id: c.Glyph, info: c.XGlyphInfo }){};
            defer glyphs.deinit(alloc);

            var image_data = std.ArrayListUnmanaged(u8){};
            defer image_data.deinit(alloc);

            var row: i32 = 0;
            while (row < size.rows) : (row += 1) {
                const cells = buffer.getRow(row);
                for (cells) |cell| {
                    const codepoint = cell.codepoint;

                    if (codepoint >= x11.mapped_codepoints.bit_length) {
                        const len_required = codepoint + 1;
                        const len_desired = @max(128, 2 * x11.mapped_codepoints.bit_length);
                        const len_maximum = 1 << 21;
                        try x11.mapped_codepoints.resize(alloc, @min(len_maximum, @max(len_desired, len_required)), false);
                    }
                    if (x11.mapped_codepoints.isSet(codepoint)) continue;

                    const zone_raster = tracy.zone(@src(), "get glyph");
                    defer zone_raster.end();

                    const glyph = manager.mapCodepoint(codepoint, .regular) orelse continue;
                    const raster = try manager.getGlyphRaster(glyph);

                    try glyphs.append(alloc, .{
                        .id = codepoint,
                        .info = .{
                            .width = @intCast(raster.bitmap.width),
                            .height = @intCast(raster.bitmap.height),
                            .x = @intCast(-raster.left),
                            .y = @intCast(raster.top - manager.metrics.baseline),
                            .xOff = @intCast(manager.metrics.cell_width),
                            .yOff = 0,
                        },
                    });
                    try image_data.appendSlice(alloc, raster.bitmap.getBGRA());

                    x11.mapped_codepoints.set(codepoint);
                }
            }

            const zone_upload = tracy.zone(@src(), "upload glyphs");
            defer zone_upload.end();

            c.XRenderAddGlyphs(
                display,
                x11.glyphset,
                glyphs.items(.id).ptr,
                glyphs.items(.info).ptr,
                @intCast(glyphs.len),
                image_data.items.ptr,
                @intCast(image_data.items.len),
            );
        }

        {
            var codepoints = try std.ArrayListUnmanaged(c_uint).initCapacity(alloc, @as(usize, size.rows) * size.cols);
            defer codepoints.deinit(alloc);

            var glyph_runs = try std.ArrayListUnmanaged(c.XGlyphElt32).initCapacity(alloc, size.rows);
            defer glyph_runs.deinit(alloc);

            const background_colors = try alloc.alloc(Pixel, size.cols * size.rows);
            defer alloc.free(background_colors);

            const foreground_colors = try alloc.alloc(Pixel, size.cols * size.rows);
            defer alloc.free(foreground_colors);

            const bg_default = Buffer.Cell.Style.Color.xterm_256color_palette[0];
            const fg_default = Buffer.Cell.Style.Color.xterm_256color_palette[15];

            {
                const zone_collect_glyphs = tracy.zone(@src(), "collect glyphs");
                defer zone_collect_glyphs.end();

                var row: i32 = 0;
                var row_index: usize = 0;
                while (row < size.rows) : ({
                    row += 1;
                    row_index += 1;
                }) {
                    const cells = buffer.getRow(row);

                    const row_start = codepoints.items.ptr + codepoints.items.len;

                    for (cells, 0..) |cell, col| {
                        const codepoint = cell.codepoint;
                        codepoints.appendAssumeCapacity(codepoint);

                        const flags = cell.style.flags;
                        const bg = cell.style.background;
                        const fg = cell.style.foreground;

                        const background = if (flags.truecolor_background) bg.rgb else bg.palette.getRGB(bg_default);
                        const foreground = if (flags.truecolor_foreground) fg.rgb else fg.palette.getRGB(fg_default);

                        background_colors[col + row_index * size.cols] = .{
                            .r = background.r,
                            .g = background.g,
                            .b = background.b,
                            .a = 0xFF,
                        };

                        foreground_colors[col + row_index * size.cols] = .{
                            .r = foreground.r,
                            .g = foreground.g,
                            .b = foreground.b,
                            .a = 0xFF,
                        };
                    }

                    glyph_runs.appendAssumeCapacity(.{
                        .glyphset = x11.glyphset,
                        .chars = row_start,
                        .nchars = @intCast(size.cols),
                        .xOff = if (row_index == 0) padding_x else -@as(i32, @intCast(size.cols * manager.metrics.cell_width)),
                        .yOff = if (row_index == 0) padding_y else @intCast(manager.metrics.cell_height),
                    });
                }
            }

            const cursor_index = buffer.cursor.col + buffer.cursor.row * size.cols;
            std.mem.swap(Pixel, &background_colors[cursor_index], &foreground_colors[cursor_index]);

            const zone_composit = tracy.zone(@src(), "composit frame");
            defer zone_composit.end();

            // clear screen
            c.XRenderFillRectangle(display, c.PictOpClear, picture, &.{}, 0, 0, surface.width, surface.height);

            const background_small = try Surface.init(display, x11.render.formats.rgb24, size.cols, size.rows);
            defer background_small.deinit(display);
            background_small.fill(display, x11.graphics_context, background_colors);
            background_small.blitScaled(
                display,
                picture,
                .{ .x = padding_x, .y = padding_y, .width = grid_width, .height = grid_height },
            );

            const foreground_small = try Surface.init(display, x11.render.formats.rgb24, size.cols, size.rows);
            defer foreground_small.deinit(display);
            foreground_small.fill(display, x11.graphics_context, foreground_colors);

            const foreground = try Surface.init(display, x11.render.formats.rgb24, surface.width, surface.height);
            defer foreground.deinit(display);
            foreground_small.blitScaled(
                display,
                foreground.picture,
                .{ .x = padding_x, .y = padding_y, .width = grid_width, .height = grid_height },
            );

            // var transform = c.XTransform{ .matrix = .{
            //     .{ 1 << 16, 0 << 16, padding_x << 16 },
            //     .{ 0 << 16, 1 << 16, padding_y << 16 },
            //     .{ 0 << 16, 0 << 16, 1 << 16 },
            // } };
            // c.XRenderSetPictureTransform(display, foreground.picture, &transform);

            c.XRenderCompositeText32(
                display,
                c.PictOpOver,
                foreground.picture,
                picture,
                null,
                0,
                0,
                0,
                0,
                glyph_runs.items.ptr,
                @intCast(glyph_runs.items.len),
            );
        }

        {
            const zone_flush = tracy.zone(@src(), "flush");
            defer zone_flush.end();
            _ = c.XFlush(display);
        }
    }
};

const Render = struct {
    base_event: c_int,
    base_error: c_int,
    version: struct { major: c_int, minor: c_int } = .{ .major = 0, .minor = 0 },
    formats: struct {
        argb32: *c.XRenderPictFormat,
        rgb24: *c.XRenderPictFormat,
        alpha8: *c.XRenderPictFormat,
    },

    pub fn init(display: *c.Display) !Render {
        const zone = tracy.zone(@src(), "init Xrender");
        defer zone.end();

        var render = Render{
            .base_event = undefined,
            .base_error = undefined,
            .formats = undefined,
        };

        if (c.XRenderQueryExtension(display, &render.base_event, &render.base_error) == 0) {
            return error.MissingXrender;
        }
        _ = c.XRenderQueryVersion(display, &render.version.major, &render.version.minor);
        log.info("Xrender: {}.{}", .{ render.version.major, render.version.minor });

        render.formats = .{
            .argb32 = c.XRenderFindStandardFormat(display, c.PictStandardARGB32) orelse return error.MissingFormat,
            .rgb24 = c.XRenderFindStandardFormat(display, c.PictStandardRGB24) orelse return error.MissingFormat,
            .alpha8 = c.XRenderFindStandardFormat(display, c.PictStandardA8) orelse return error.MissingFormat,
        };

        return render;
    }
};

fn createWindow(display: *c.Display, width: u32, height: u32) !c.Window {
    const screen = c.DefaultScreen(display);
    const parent = c.XDefaultRootWindow(display);
    const black = c.BlackPixel(display, screen);
    return c.XCreateSimpleWindow(display, parent, 0, 0, width, height, 0, black, black);
}

const Surface = struct {
    /// Handle to the image.
    picture: c.Picture,

    /// Backing data storage (the window surface uses the window's pixmap).
    pixmap: c.Pixmap = 0,

    /// Width of the image (in pixels).
    width: u32,
    /// Height of the image (in pixels).
    height: u32,

    pub fn initWindow(display: *c.Display, window: c.Window) !Surface {
        const zone = tracy.zone(@src(), "Surface.initWindow");
        defer zone.end();

        const width, const height = getWindowGeometry(display, window);

        var window_attributes: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(display, window, &window_attributes);
        const format = c.XRenderFindVisualFormat(display, window_attributes.visual);

        const picture = c.XRenderCreatePicture(display, window, format, 0, null);
        return .{ .picture = picture, .width = width, .height = height };
    }

    pub fn init(display: *c.Display, format: *const c.XRenderPictFormat, width: u32, height: u32) !Surface {
        const zone = tracy.zone(@src(), "Surface.init");
        defer zone.end();

        const root = c.XDefaultRootWindow(display);
        const pixmap = c.XCreatePixmap(display, root, width, height, @intCast(format.depth));
        const picture = c.XRenderCreatePicture(display, pixmap, format, 0, null);
        return .{ .picture = picture, .pixmap = pixmap, .width = width, .height = height };
    }

    pub fn blitScaled(
        surface: Surface,
        display: *c.Display,
        target: c.Picture,
        area: struct {
            x: i32 = 0,
            y: i32 = 0,
            width: u32,
            height: u32,
        },
    ) void {
        const zone = tracy.zone(@src(), "Surface.blitScaled");
        defer zone.end();

        var transform = c.XTransform{ .matrix = .{
            .{ @intCast((surface.width << 16) / area.width), 0 << 16, 0 << 16 },
            .{ 0 << 16, @intCast((surface.height << 16) / area.height), 0 << 16 },
            .{ 0 << 16, 0 << 16, 1 << 16 },
        } };
        c.XRenderSetPictureTransform(display, surface.picture, &transform);

        c.XRenderComposite(
            display,
            c.PictOpSrc,
            surface.picture,
            0, // mask
            target,
            0, // src.x
            0, // src.y
            0, // mask.x
            0, // mask.y
            area.x, // dst.x
            area.y, // dst.y
            area.width,
            area.height,
        );
    }

    pub fn fill(surface: Surface, display: *c.Display, graphics_context: c.GC, pixels: []const Pixel) void {
        const zone = tracy.zone(@src(), "Surface.fill");
        defer zone.end();

        std.debug.assert(pixels.len == surface.width * surface.height);

        const screen = c.DefaultScreen(display);
        const visual = c.DefaultVisual(display, screen);
        const image = c.XCreateImage(
            display,
            visual,
            24, // depth
            c.ZPixmap,
            0,
            @constCast(std.mem.sliceAsBytes(pixels).ptr),
            surface.width,
            surface.height,
            32,
            0,
        ) orelse std.debug.panic("could not create image", .{});
        defer std.c.free(image);

        _ = c.XPutImage(
            display,
            surface.pixmap,
            graphics_context,
            image,
            0,
            0,
            0,
            0,
            surface.width,
            surface.height,
        );
    }

    pub fn deinit(surface: Surface, display: *c.Display) void {
        c.XRenderFreePicture(display, surface.picture);
        if (surface.pixmap != 0) _ = c.XFreePixmap(display, surface.pixmap);
    }
};

const Pixel = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};

fn getWindowGeometry(display: *c.Display, window: c.Window) [2]u32 {
    var root = c.XDefaultRootWindow(display);
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_uint = 0;
    var h: c_uint = 0;
    var bw: c_uint = 0;
    var bh: c_uint = 0;
    _ = c.XGetGeometry(display, window, &root, &x, &y, &w, &h, &bw, &bh);
    return .{ w, h };
}
