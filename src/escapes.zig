const std = @import("std");

pub const Command = union(enum) {
    // the extra value gives the minimum number of bytes required
    incomplete,
    invalid,
    ignore,

    codepoint: u21,

    tab,
    retline,
    newline,
    backspace,
    delete,
    alert,

    csi: ControlSequenceInducer,
    osc: OperatingSystemControl,
    set_character_set,
};

const ParseResult = struct {
    /// Usually, this is the number of bytes consumed by the command.
    u32,

    /// The parsed command structure.
    Command,
};

pub const Context = struct {
    const capacity = 32;

    args: [capacity]u32,
    args_count: u8,
    args_set: std.bit_set.IntegerBitSet(capacity),

    fn clear(context: *Context) void {
        context.args_count = 0;
        context.args_set = .{ .mask = 0 };
    }

    fn push(context: *Context, value: ?u32) void {
        if (context.args_count >= context.args.len) {
            std.log.warn("too many parameters in escape sequence", .{});
            return;
        }

        if (value) |x| {
            context.args[context.args_count] = x;
            context.args_set.set(context.args_count);
        }
        context.args_count += 1;
    }

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

const ESC = std.ascii.control_code.esc;

pub fn parse(bytes: []const u8, context: *Context) ParseResult {
    switch (bytes[0]) {
        0 => return .{ 1, .ignore },

        std.ascii.control_code.bel => return .{ 1, .alert },
        std.ascii.control_code.bs => return .{ 1, .backspace },
        std.ascii.control_code.del => return .{ 1, .delete },

        '\r' => return .{ 1, .retline },
        '\n' => return .{ 1, .newline },
        '\t' => return .{ 1, .tab },

        ESC => {
            if (bytes.len < 2) return .{ 2, .incomplete };
            switch (bytes[1]) {
                '[' => return parseCSI(bytes, context),
                ']' => return parseOSC(bytes, context),
                0x20...0x2f => {
                    context.clear();
                    context.push(bytes[1]);
                    var i: u32 = 2;
                    while (i < bytes.len) {
                        defer i += 1;
                        switch (bytes[i]) {
                            0x20...0x2f => |arg| context.push(arg),
                            0x30...0x7e => |arg| {
                                context.push(arg);
                                break;
                            },
                            else => return .{ i, .invalid },
                        }
                    } else {
                        return .{ i + 1, .incomplete };
                    }
                    return .{ i, .set_character_set };
                },
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
    if (!complete) return .{ i + 1, .incomplete };

    if (i >= bytes.len) return .{ i + 1, .incomplete };
    csi.final = bytes[i];
    i += 1;

    return .{ i, .{ .csi = csi } };
}

pub const OperatingSystemControl = struct {
    /// This argument at this index gives the start offset into the sequence.
    arg_min: u8,
    /// This argument at this index gives the end offset into the sequence.
    arg_max: u8,
};

pub fn parseOSC(bytes: []const u8, context: *Context) ParseResult {
    std.debug.assert(bytes[0] == ESC and bytes[1] == ']');

    context.args_count = 0;
    context.args_set = .{ .mask = 0 };

    var i: u32 = 2;
    const len, const complete = parseParameterList(bytes[i..], context);
    i += len;
    if (!complete) return .{ i + 1, .incomplete };

    const arg_min = context.args_count;
    context.push(i);

    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            std.ascii.control_code.stx, std.ascii.control_code.bel => break,
            else => continue,
        }
    } else {
        return .{ i + 1, .incomplete };
    }

    const arg_max = context.args_count;
    context.push(i);
    i += 1;

    return .{ i, .{ .osc = .{ .arg_min = arg_min, .arg_max = arg_max } } };
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
                context.push(if (has_digits) argument else null);
                has_digits = false;
                argument = 0;
            },

            else => break,
        }
    } else {
        return .{ i, false };
    }

    if (has_digits) context.push(argument);

    return .{ i, true };
}
