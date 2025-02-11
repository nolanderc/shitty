const std = @import("std");

pub const Command = union(enum) {
    // the extra value gives the minimum number of bytes required
    incomplete,
    invalid,
    ignore,

    codepoint: u21,

    retline,
    newline,
    backspace,
    delete,
    alert,

    csi: ControlSequenceInducer,
};

const ParseResult = struct {
    /// Usually, this is the number of bytes consumed by the command.
    u32,

    /// The parsed command structure.
    Command,
};

pub const Context = struct {
    args: [16]u32,

    pub fn fmtArgs(context: *const Context, count: u32) FormatterArgs {
        return .{ .context = context, .count = count };
    }

    const FormatterArgs = struct {
        context: *const Context,
        count: u32,

        pub fn format(fmt: FormatterArgs, _: anytype, _: anytype, writer: anytype) !void {
            for (0.., fmt.context.args[0..fmt.count]) |index, arg| {
                if (index != 0) try writer.writeAll(";");
                try writer.print("{d}", .{arg});
            }
        }
    };
};

const ESC = 0x1b;

pub fn parse(bytes: []const u8, context: *Context) ParseResult {
    switch (bytes[0]) {
        0 => return .{ 1, .ignore },

        '\x07' => return .{ 1, .alert },
        '\x08' => return .{ 1, .backspace },
        '\x7f' => return .{ 1, .delete },

        '\r' => return .{ 1, .retline },
        '\n' => return .{ 1, .newline },

        ESC => {
            if (bytes.len < 2) return .{ 2, .incomplete };
            switch (bytes[1]) {
                '[' => return parseCSI(bytes, context),
                else => return .{ 2, .invalid },
            }
        },

        0b0010_0000...0b0111_1110 => return .{ 1, .{ .codepoint = bytes[0] } },
        0b1100_0000...0b1101_1111 => {
            if (bytes.len < 2) return .{ 2, .incomplete };
            const codepoint = std.unicode.utf8Decode2(bytes[0..2].*) catch return .{ 2, .invalid };
            return .{ 2, .{ .codepoint = codepoint } };
        },
        0b1110_0000...0b1110_1111 => {
            if (bytes.len < 3) return .{ 3, .incomplete };
            const codepoint = std.unicode.utf8Decode3(bytes[0..3].*) catch return .{ 3, .invalid };
            return .{ 3, .{ .codepoint = codepoint } };
        },
        0b1111_0000...0b1111_0111 => {
            if (bytes.len < 4) return .{ 4, .incomplete };
            const codepoint = std.unicode.utf8Decode4(bytes[0..4].*) catch return .{ 4, .invalid };
            return .{ 4, .{ .codepoint = codepoint } };
        },

        else => return .{ 1, .invalid },
    }
}

const ControlSequenceInducer = struct {
    /// Number of arguments.
    arg_count: u8,
    intermediate: u8,
    final: u8,
};

pub fn parseCSI(bytes: []const u8, context: *Context) ParseResult {
    std.debug.assert(bytes[0] == ESC and bytes[1] == '[');

    @memset(&context.args, 0);

    var i: u32 = 2;
    var digits: u32 = 0;
    var csi = std.mem.zeroes(ControlSequenceInducer);

    while (i < bytes.len) {
        defer i += 1;
        switch (bytes[i]) {
            '0'...'9' => |digit| {
                digits += 1;
                if (csi.arg_count < context.args.len) {
                    context.args[csi.arg_count] *|= 10;
                    context.args[csi.arg_count] +|= digit - '0';
                }
            },

            ';', ':' => {
                csi.arg_count +|= 1;
                digits = 0;
            },

            else => |char| switch (char) {
                '#', '?' => csi.intermediate = char,
                else => {
                    csi.final = char;
                    break;
                },
            },
        }
    }

    if (digits != 0) csi.arg_count += 1;

    if (csi.arg_count >= context.args.len) {
        std.log.warn("CSI contains too many arguments: {}", .{std.json.fmt(bytes[0..i], .{})});
    }

    return .{ i, .{ .csi = csi } };
}
