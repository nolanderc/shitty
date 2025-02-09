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
    }
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
    col: u32 = 0,
    row: u31 = 0,
    brush: Cell.Style = .{},
};

pub const Cell = struct {
    pub const empty = std.mem.zeroes(Cell);

    codepoint: u21,
    style: Style,

    pub const Style = struct {
        flags: Flags = .{},
        foreground: Color = Color.fromIndex(0),
        background: Color = Color.fromIndex(15),

        pub const Flags = packed struct(u2) {
            truecolor_foreground: bool = false,
            truecolor_background: bool = false,
        };

        pub const Color = extern struct {
            r: u8 = 0,
            g: u8 = 0,
            b: u8 = 0,

            pub fn fromIndex(index: u8) Color {
                return .{ .r = index, .g = index, .b = index };
            }
        };
    };
};
