const pgzx = @import("../pgzx.zig");

const pg = pgzx.pg;

pub fn mixed(fcinfo: pg.FunctionCallInfo, value: i32, enabled: bool, label: ?[:0]const u8) !?[:0]const u8 {
    if (fcinfo.*.nargs != 3) return error.UnexpectedArgumentCount;
    if (!enabled) return null;
    return try pgzx.str.format("{d}:{s}", .{ value, label orelse "<null>" });
}

pub fn required(value: i32) i32 {
    return value;
}

pub fn charRoundTrip(value: [:0]const u8) [:0]const u8 {
    return value;
}

pub fn nameRoundTrip(value: [:0]const u8) [:0]const u8 {
    return value;
}
