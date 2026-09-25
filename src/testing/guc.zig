const std = @import("std");

const pgzx = @import("../pgzx.zig");
const pg = pgzx.pg;

const bool_name: [:0]const u8 = "pgzx_test.bool";
const int_name: [:0]const u8 = "pgzx_test.int";
const string_name: [:0]const u8 = "pgzx_test.string";

var bool_variable: pgzx.guc.CustomBoolVariable = .{ .value = false };
var int_variable: pgzx.guc.CustomIntVariable = .{ .value = 42 };
var string_variable: pgzx.guc.CustomStringVariable = .{};
var registered = false;

const StringState = enum {
    initial,
    next,
    empty,
    spaced,
};

var string_state: StringState = .initial;

fn checkString(
    newval: [*c][*c]u8,
    extra: [*c]?*anyopaque,
    source: pg.GucSource,
) callconv(.c) bool {
    _ = extra;
    _ = source;
    if (newval == null or newval.* == null) return false;

    const value = std.mem.span(newval.*);
    return std.mem.eql(u8, value, "initial") or
        std.mem.eql(u8, value, "next") or
        std.mem.eql(u8, value, "") or
        std.mem.eql(u8, value, " spaced value ");
}

fn assignString(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    if (newval == null) return;

    const value = std.mem.span(newval);
    string_state = if (std.mem.eql(u8, value, "initial"))
        .initial
    else if (std.mem.eql(u8, value, "next"))
        .next
    else if (value.len == 0)
        .empty
    else
        .spaced;
}

fn showString() callconv(.c) [*c]const u8 {
    return switch (string_state) {
        .initial => "shown-initial",
        .next => "shown-next",
        .empty => "shown-empty",
        .spaced => "shown-spaced",
    };
}

pub fn register() void {
    if (registered) return;

    bool_variable.register(.{
        .name = bool_name,
        .initial_value = false,
    });
    int_variable.register(.{
        .name = int_name,
        .initial_value = 42,
        .min_value = -10,
        .max_value = 100,
    });
    string_variable.register(.{
        .name = string_name,
        .initial_value = "initial",
        .check_hook = checkString,
        .assign_hook = assignString,
        .show_hook = showString,
    });

    registered = true;
}

fn set(name: [:0]const u8, value: [:0]const u8) void {
    pg.SetConfigOption(name.ptr, value.ptr, pg.PGC_USERSET, pg.PGC_S_SESSION);
}

pub const TestSuite_Guc = struct {
    pub fn testRegisterIsIdempotent() !void {
        register();
    }

    pub fn testBoolVariable() !void {
        const original = bool_variable.value;
        {
            const level = pg.NewGUCNestLevel();
            defer pg.AtEOXact_GUC(false, level);

            set(bool_name, "off");
            try std.testing.expect(!bool_variable.value);
            set(bool_name, "on");
            try std.testing.expect(bool_variable.value);
        }
        try std.testing.expectEqual(original, bool_variable.value);
    }

    pub fn testIntVariable() !void {
        const original = int_variable.value;
        {
            const level = pg.NewGUCNestLevel();
            defer pg.AtEOXact_GUC(false, level);

            set(int_name, "42");
            try std.testing.expectEqual(@as(c_int, 42), int_variable.value);
            set(int_name, "-10");
            try std.testing.expectEqual(@as(c_int, -10), int_variable.value);
            set(int_name, "100");
            try std.testing.expectEqual(@as(c_int, 100), int_variable.value);
        }
        try std.testing.expectEqual(original, int_variable.value);
    }

    pub fn testStringHooks() !void {
        const original = try pgzx.mem.PGCurrentContextAllocator.dupe(u8, string_variable.value());
        const original_state = string_state;
        {
            const level = pg.NewGUCNestLevel();
            defer pg.AtEOXact_GUC(false, level);

            set(string_name, "initial");
            try std.testing.expectEqualStrings("initial", string_variable.value());
            try std.testing.expectEqual(StringState.initial, string_state);

            set(string_name, "next");
            try std.testing.expectEqualStrings("next", string_variable.value());
            try std.testing.expectEqual(StringState.next, string_state);
            try std.testing.expectEqualStrings(
                "shown-next",
                std.mem.span(pg.GetConfigOptionByName(string_name.ptr, null, false)),
            );
        }
        try std.testing.expectEqualStrings(original, string_variable.value());
        try std.testing.expectEqual(original_state, string_state);
    }
};
