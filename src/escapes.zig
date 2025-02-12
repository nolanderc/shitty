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
    osc: OperatingSystemControl,
};

const ParseResult = struct {
    /// Usually, this is the number of bytes consumed by the command.
    u32,

    /// The parsed command structure.
    Command,
};

pub const Context = struct {
    const capacity = 16;

    args: [capacity]u32,
    args_count: u32,
    args_set: std.bit_set.IntegerBitSet(capacity),

    pub fn get(context: *const Context, index: usize, default: u32) u32 {
        if (index < context.args_count and context.args_set.isSet(index)) {
            return context.args[index];
        } else {
            return default;
        }
    }

    pub fn fmtArgs(context: *const Context) FormatterArgs {
        return .{ .context = context };
    }

    const FormatterArgs = struct {
        context: *const Context,

        pub fn format(fmt: FormatterArgs, _: anytype, _: anytype, writer: anytype) !void {
            for (0.., fmt.context.args[0..fmt.context.args_count]) |index, arg| {
                if (index != 0) try writer.writeAll(";");
                if (fmt.context.args_set.isSet(index)) {
                    try writer.print("{d}", .{arg});
                }
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
                ']' => return parseOSC(bytes, context),
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

pub const ControlSequenceInducer = struct {
    intermediate: u8,
    final: u8,
};

pub fn parseCSI(bytes: []const u8, context: *Context) ParseResult {
    std.debug.assert(bytes[0] == ESC and bytes[1] == '[');

    context.args_count = 0;
    context.args_set = .{ .mask = 0 };

    var csi = std.mem.zeroes(ControlSequenceInducer);

    var i: u32 = 2;
    if (i < bytes.len and bytes[i] == '?') {
        csi.intermediate = bytes[i];
        i += 1;
    }

    const len, const complete = parseParameterList(bytes[i..], context);
    i += len;
    if (!complete) return .{ i, .incomplete };

    if (i >= bytes.len) return .{ i + 1, .incomplete };
    csi.final = bytes[i];
    i += 1;

    return .{ i, .{ .csi = csi } };
}

pub const OperatingSystemControl = void;

pub fn parseOSC(bytes: []const u8, context: *Context) ParseResult {
    std.debug.assert(bytes[0] == ESC and bytes[1] == ']');

    context.args_count = 0;
    context.args_set = .{ .mask = 0 };

    var i: u32 = 2;
    const len, const complete = parseParameterList(bytes[i..], context);
    i += len;

    if (!complete) return .{ i, .incomplete };

    return .{ i, .osc };
}

fn parseParameterList(bytes: []const u8, context: *Context) struct { u32, bool } {
    var i: u32 = 0;
    var argument: u32 = 0;
    var has_digits = false;

    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '0'...'9' => |digit| {
                has_digits = true;
                argument *|= 10;
                argument +|= digit - '0';
            },

            ';' => {
                if (has_digits and context.args_count < context.args.len) {
                    context.args[context.args_count] = argument;
                    context.args_set.set(context.args_count);
                }
                context.args_count +|= 1;
                has_digits = false;
                argument = 0;
            },

            else => break,
        }
    } else {
        return .{ i + 1, false };
    }

    if (has_digits and context.args_count < context.args.len) {
        context.args[context.args_count] = argument;
        context.args_set.set(context.args_count);
        context.args_count +|= 1;
    }

    return .{ i, true };
}
