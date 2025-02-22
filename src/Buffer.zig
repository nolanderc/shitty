const std = @import("std");
const c = @import("c").includes;

const Buffer = @This();

pub const Size = struct {
    /// Number of columns.
    cols: u32,
    /// Number of rows (in view).
    rows: u32,
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

fn getRowAbs(buffer: Buffer, row_abs: u32) []Cell {
    const row_rel = row_abs % buffer.size.rowsTotal();
    return buffer.cells[row_rel * buffer.size.cols ..][0..buffer.size.cols];
}

pub fn write(buffer: *Buffer, codepoint: u21) void {
    const charwidth = c.utf8proc_charwidth(codepoint);
    const cell_width: u32 = @max(1, charwidth);

    if (buffer.cursor.col + cell_width > buffer.size.cols) {
        const row = buffer.getRow(buffer.cursor.row);
        @memset(row[buffer.cursor.col..], .{ .codepoint = 0, .style = buffer.cursor.brush });
        buffer.cursor.col = 0;
        buffer.cursor.row +%= 1;
        buffer.wrapCursor();
    }

    var cell = Cell{ .codepoint = codepoint, .style = buffer.cursor.brush };
    for (0..cell_width) |_| {
        const row = buffer.getRow(buffer.cursor.row);
        row[buffer.cursor.col] = cell;
        defer cell.codepoint = 0;

        buffer.cursor.col += 1;
        buffer.wrapCursor();
    }
}

fn wrapCursor(buffer: *Buffer) void {
    if (buffer.cursor.col >= buffer.size.cols) {
        buffer.cursor.col = 0;
        buffer.cursor.row +%= 1;
    }
    if (buffer.cursor.row >= buffer.size.rows) {
        buffer.cursor.row -%= 1;
        buffer.row_start +%= 1;
        buffer.scrollback_row_count += 1;
        if (buffer.scrollback_row_count > buffer.size.scrollback_rows) {
            buffer.scrollback_row_count -= 1;
        }

        const cells = buffer.getRow(buffer.cursor.row);
        @memset(cells, Cell.empty);
    }
}

pub const CoordinateUpdate = union(enum) {
    abs: u16,
    rel: i16,

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
    buffer.wrapCursor();
}

pub fn reflowInto(source: *const Buffer, target: *Buffer) void {
    std.log.warn("TODO: reflow lines", .{});

    var source_row = source.row_start -% source.scrollback_row_count;
    var target_row = target.row_start;

    for (0..source.scrollback_row_count + source.cursor.row + 1) |index| {
        if (index > 0) {
            target.cursor.row += 1;
            target.wrapCursor();
        }

        defer source_row +%= 1;
        defer target_row +%= 1;

        const source_cells = source.getRowAbs(source_row);
        const target_cells = target.getRowAbs(target_row);
        const count = @min(source_cells.len, target_cells.len);
        @memcpy(target_cells[0..count], source_cells[0..count]);

        if (source_row == source.getRowAbsIndex(source.cursor.row)) {
            target.cursor.col = source.cursor.col;
            target.wrapCursor();
        }
    }
}

pub const Cursor = struct {
    col: u31 = 0,
    row: u31 = 0,
    brush: Cell.Style = .{},
};

pub const Cell = struct {
    pub const empty = std.mem.zeroes(Cell);

    codepoint: u21,
    style: Style,

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

            _: u11 = 0,
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
};
