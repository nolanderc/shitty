const std = @import("std");

const enabled = @import("options").enabled;
const c = @import("TracyC.h");

pub const Zone = struct {
    ctx: if (enabled) c.TracyCZoneCtx else void,

    pub inline fn end(z: Zone) void {
        if (!enabled) return;
        c.___tracy_emit_zone_end(z.ctx);
    }

    pub inline fn setColor(z: Zone, color: u32) void {
        if (!enabled) return;
        c.___tracy_emit_zone_color(z.ctx, color);
    }
};

pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: [*:0]const u8) Zone {
    if (!enabled) return .{ .ctx = {} };

    const S = struct {
        var location = c.___tracy_source_location_data{
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
        };
    };
    return .{ .ctx = c.___tracy_emit_zone_begin(&S.location, 1) };
}
