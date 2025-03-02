const std = @import("std");
const c = @import("c").includes;
const tracy = @import("tracy");

const Buffer = @This();

pub const Size = struct {
    /// Number of columns.
    cols: u31,
    /// Number of rows (in view).
    rows: u31,
    /// Number of rows (in scrollback).
    scrollback_rows: u32,

    pub fn rowsTotal(size: Size) u32 {
        return size.rows + size.scrollback_rows;
    }
};

size: Size,

scrollback_row_count: u32 = 0,
row_start: u32 = 0,
cursor: Cursor = .{},
cells: []Cell,
private_modes: std.EnumSet(PrivateModes) = std.EnumSet(PrivateModes).init(.{
    .cursor_visible = true,
}),

scroll_margins: struct {
    top: u31 = 0,
    bot: u31 = std.math.maxInt(u31),
} = .{},

pub const PrivateModes = enum(u16) {
    cursor_visible = 25,
    alternative_screen_buffer = 1049,
    bracketed_paste = 2004,
};

pub fn deinit(buffer: Buffer, alloc: std.mem.Allocator) void {
    alloc.free(buffer.cells);
}

pub fn init(alloc: std.mem.Allocator, size: Size) !Buffer {
    const cell_count = size.cols * size.rowsTotal();
    const cells = try alloc.alloc(Cell, cell_count);
    @memset(cells, Cell.empty);

    return .{ .size = size, .cells = cells };
}

pub fn getRow(buffer: Buffer, relative: i32) []Cell {
    if (relative < 0) {
        if (-relative > buffer.scrollback_row_count) std.debug.panic(
            "access past first row ({} < -{})",
            .{ relative, buffer.scrollback_row_count },
        );
    } else {
        if (relative >= buffer.size.rows) std.debug.panic(
            "access past last row ({} >= {})",
            .{ relative, buffer.size.rows },
        );
    }
    return buffer.getRowAbs(buffer.getRowAbsIndex(relative));
}

fn getRowAbsIndex(buffer: Buffer, relative: i32) u32 {
    return buffer.row_start +% @as(u32, @bitCast(relative));
}

fn getRowAbs(buffer: Buffer, row_abs: usize) []Cell {
    const row_rel = row_abs % buffer.size.rowsTotal();
    return buffer.cells[row_rel * buffer.size.cols ..][0..buffer.size.cols];
}

pub fn write(buffer: *Buffer, codepoint: u21) void {
    const charwidth = c.utf8proc_charwidth(codepoint);
    const cell_width: u32 = @max(1, charwidth);

    if (buffer.cursor.col + cell_width > buffer.size.cols) {
        const row = buffer.getRow(buffer.cursor.row);
        @memset(row[buffer.cursor.col..], .{
            .codepoint = 0,
            .style = buffer.cursor.brush,
            .flags = .{ .line_continuation = buffer.cursor.anchored },
        });
        buffer.cursor.col = 0;
        buffer.cursor.row +%= 1;
        buffer.wrapCursor();
    }

    var cell = Cell{
        .codepoint = codepoint,
        .style = buffer.cursor.brush,
        .flags = .{ .line_continuation = buffer.cursor.anchored },
    };

    for (0..cell_width) |_| {
        const row = buffer.getRow(buffer.cursor.row);
        row[buffer.cursor.col] = cell;
        defer {
            cell.codepoint = 0;
            cell.flags = .{ .inherit_style = true, .line_continuation = true };
        }

        buffer.cursor.col += 1;
        buffer.cursor.anchored = true;
    }
}

fn wrapCursor(buffer: *Buffer) void {
    if (buffer.cursor.col >= buffer.size.cols) {
        buffer.cursor.col = 0;
        buffer.cursor.row +%= 1;
    }
    if (buffer.cursor.row >= buffer.size.rows) {
        const overflow = buffer.cursor.row - buffer.size.rows +| 1;

        buffer.cursor.row -%= overflow;
        buffer.row_start = buffer.size.rowsTotal() +
            (buffer.row_start + overflow) % buffer.size.rowsTotal();

        buffer.scrollback_row_count +|= overflow;
        if (buffer.scrollback_row_count > buffer.size.scrollback_rows) {
            buffer.scrollback_row_count = buffer.size.scrollback_rows;
        }

        const cells = buffer.getRow(buffer.cursor.row);
        @memset(cells, Cell.empty);
    }
}

pub const CoordinateUpdate = union(enum) {
    abs: u31,
    rel: i32,

    pub fn apply(update: CoordinateUpdate, coord: u31) u31 {
        switch (update) {
            .abs => |abs| return abs,
            .rel => |rel| return std.math.lossyCast(u31, @as(i32, coord) + rel),
        }
    }
};

pub fn setCursorPosition(
    buffer: *Buffer,
    update: struct {
        row: CoordinateUpdate = .{ .rel = 0 },
        col: CoordinateUpdate = .{ .rel = 0 },
    },
) void {
    buffer.cursor.col = update.col.apply(buffer.cursor.col);
    buffer.cursor.row = update.row.apply(buffer.cursor.row);
    buffer.cursor.anchored = false;
    buffer.wrapCursor();
}

pub fn reflowInto(source: *const Buffer, target: *Buffer) void {
    const zone = tracy.zone(@src(), "reflow");
    defer zone.end();

    var source_row = source.row_start - source.scrollback_row_count;

    for (0..source.scrollback_row_count + source.cursor.row + 1) |_| {
        defer source_row +%= 1;

        var source_cells = source.getRowAbs(source_row);
        while (source_cells.len != 0 and source_cells[source_cells.len - 1].codepoint == 0) {
            source_cells.len -= 1;
        }

        for (source_cells, 0..) |cell, col| {
            if (col == 0 and !cell.flags.line_continuation) {
                target.setCursorPosition(.{ .row = .{ .rel = 1 }, .col = .{ .abs = 0 } });
            }

            target.cursor.brush = cell.style;
            target.cursor.anchored = cell.flags.line_continuation;
            target.write(cell.codepoint);
        }
    }
}

pub const Cursor = struct {
    col: u31 = 0,
    row: u31 = 0,
    brush: Style = .{},
    anchored: bool = false,
};

pub const Cell = struct {
    pub const empty = std.mem.zeroes(Cell);

    codepoint: u21 = 0,
    flags: Flags = .{},
    style: Style = .{},

    pub const Flags = packed struct(u2) {
        /// If `true`, during terminal reflowing, this cell should be on the same
        /// line as the previous cell.
        line_continuation: bool = false,

        /// If `true`, this cell should always have the same color/attributes
        /// as the previous cell. This is intended to be used for multi-column
        /// glyphs.
        inherit_style: bool = false,
    };
};

pub const Style = struct {
    comptime {
        std.debug.assert(@sizeOf(Style) <= 8);
    }

    flags: Flags = .{},
    foreground: Color = Color.default,
    background: Color = Color.default,

    pub const Flags = packed struct(u16) {
        /// If set, the foreground is the `rgb` variant.
        truecolor_foreground: bool = false,
        /// If set, the background is the `rgb` variant.
        truecolor_background: bool = false,

        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        inverse: bool = false,

        _: u10 = 0,
    };

    pub const Color = extern union {
        comptime {
            std.debug.assert(@sizeOf(Color) == 3);
        }

        palette: Palette,
        rgb: RGB,

        pub const RGB = extern struct {
            r: u8,
            g: u8,
            b: u8,

            pub fn gray(value: u8) RGB {
                return .{ .r = value, .g = value, .b = value };
            }
        };

        pub const Palette = extern struct {
            const Kind = enum(u8) {
                /// The default color. Exact value depends on if this is the foreground or background.
                default = 0,
                /// Uses the `index` field to pick a color from the `xterm-256color` palette.
                xterm256color,
            };

            kind: Kind,
            index: u8,

            pub fn getRGB(palette: Palette, default_color: RGB) RGB {
                if (palette.kind == .default) return default_color;
                return xterm_256color_palette[palette.index];
            }
        };

        pub const default: Color = std.mem.zeroes(Color);

        pub fn fromXterm256(index: u8) Color {
            return .{ .palette = .{ .kind = .xterm256color, .index = index } };
        }

        pub fn fromRGB(r: u8, g: u8, b: 8) Color {
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        }

        pub const xterm_256color_palette: [256]RGB = blk: {
            var palette: [256]RGB = undefined;

            const BitsRgb = packed struct(u3) { r: bool, g: bool, b: bool };

            palette[0] = .{ .r = 0, .g = 0, .b = 0 };
            for (palette[1..8], 1..) |*rgb, index| {
                const bits: BitsRgb = @bitCast(@as(u3, @truncate(index)));
                rgb.r = if (bits.r) 205 else 80;
                rgb.g = if (bits.g) 205 else 80;
                rgb.b = if (bits.b) 225 else 80;
            }

            for (palette[8..16], 0..) |*rgb, index| {
                const bits: BitsRgb = @bitCast(@as(u3, @truncate(index)));
                rgb.r = if (bits.r) 255 else 100;
                rgb.g = if (bits.g) 255 else 100;
                rgb.b = if (bits.b) 255 else 100;
            }

            for (palette[16..232], 0..) |*rgb, index| {
                const b: u8 = (index / 1) % 6;
                const g: u8 = (index / 6) % 6;
                const r: u8 = (index / 36) % 6;
                rgb.r = 51 * r;
                rgb.g = 51 * g;
                rgb.b = 51 * b;
            }

            for (palette[232..256], 1..) |*rgb, index| {
                const gray: u8 = @truncate(255 * index / 25);
                rgb.* = RGB.gray(gray);
            }

            break :blk palette;
        };
    };
};

pub fn eraseInLine(buffer: *Buffer, what: enum { right, left, all }) void {
    const row = buffer.getRow(buffer.cursor.row);
    switch (what) {
        .left => @memset(row[0..buffer.cursor.col], Cell.empty),
        .right => @memset(row[buffer.cursor.col..], Cell.empty),
        .all => @memset(row, Cell.empty),
    }
}

pub fn eraseInDisplay(buffer: *Buffer, what: enum { below, above, all }) void {
    // TODO: move the erased rows into the scrollback buffer
    switch (what) {
        .above => for (0..buffer.cursor.row) |row| {
            @memset(buffer.getRow(@intCast(row)), Cell.empty);
        },
        .below => for (buffer.cursor.row..buffer.size.rows) |row| {
            @memset(buffer.getRow(@intCast(row)), Cell.empty);
        },
        .all => for (0..buffer.size.rows) |row| {
            @memset(buffer.getRow(@intCast(row)), Cell.empty);
        },
    }
}

pub fn deleteLines(buffer: *Buffer, count: u32) void {
    if (count == 0) return;

    const top = @min(buffer.scroll_margins.top, buffer.size.rows);
    const bot = @min(buffer.scroll_margins.bot, buffer.size.rows);

    var target = @max(buffer.cursor.row, top);
    var source = @min(target +| count, bot);

    while (source < bot) {
        defer target += 1;
        defer source += 1;

        const target_cells = buffer.getRow(target);
        const source_cells = buffer.getRow(source);
        @memcpy(target_cells, source_cells);
        @memset(source_cells, Cell.empty);
    }
}

pub fn insertLinesBlank(buffer: *Buffer, count: u32, where: enum { top, cursor }) void {
    if (count == 0) return;

    const top = @min(if (where == .top) buffer.scroll_margins.top else buffer.cursor.row, buffer.size.rows);
    const bot = @min(buffer.scroll_margins.bot, buffer.size.rows);

    var source = @max(top, @as(u31, @truncate(bot -| count)));
    var target = @max(top, bot);

    while (top < source) {
        source -= 1;
        target -= 1;
        const source_cells = buffer.getRow(source);
        const target_cells = buffer.getRow(target);
        @memcpy(target_cells, source_cells);
        @memset(source_cells, Cell.empty);
    }
}

pub fn eraseCharacters(buffer: *Buffer, count: u32) void {
    const row = buffer.getRow(buffer.cursor.row);
    const after = row[buffer.cursor.col..];
    @memset(after[0..@min(count, after.len)], Cell.empty);
}

pub fn deleteCharacters(buffer: *Buffer, count: u32) void {
    const row = buffer.getRow(buffer.cursor.row);
    const after = row[buffer.cursor.col..];
    std.mem.copyForwards(
        Cell,
        after[0 .. after.len - count],
        after[count..],
    );
    @memset(after[after.len - count ..], Cell.empty);
}

pub fn insertCharactersBlank(buffer: *Buffer, count: u32) void {
    const row = buffer.getRow(buffer.cursor.row);
    const after = row[buffer.cursor.col..];
    std.mem.copyBackwards(Cell, after[count..], after[0 .. after.len - count]);
    @memset(after[0..count], Cell.empty);
}
