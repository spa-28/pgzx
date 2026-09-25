const std = @import("std");
const mem = @import("mem.zig");

pub const CString = [:0]const u8;
pub const CStringPtr = [*c]const u8;

/// Return a formatted string or error.
///
/// The string will be allocated on the current PostgreSQL memory context.
pub fn format(
    comptime fmt: []const u8,
    args: anytype,
) !CString {
    return try std.fmt.allocPrintSentinel(mem.PGCurrentContextAllocator, fmt, args, 0);
}

/// Return a formatted string or error.
/// The memory for the message is allocated from the given allocator (or
/// mem.PGCurrentContextAllocator if null).
pub fn formatMemCtx(
    alloc: ?*mem.MemoryContextAllocator,
    comptime fmt: []const u8,
    args: anytype,
) !CString {
    const use_alloc = if (alloc) |a| a.allocator() else mem.PGCurrentContextAllocator;
    return try std.fmt.allocPrintSentinel(use_alloc, fmt, args, 0);
}

pub const TestSuite_Str = struct {
    pub fn testFormat() !void {
        const value = try format("{s}-{d}", .{ "zig", 16 });
        try std.testing.expectEqualStrings("zig-16", value);
        try std.testing.expectEqual(@as(u8, 0), value.ptr[value.len]);

        const empty = try format("", .{});
        try std.testing.expectEqualStrings("", empty);
        try std.testing.expectEqual(@as(u8, 0), empty.ptr[empty.len]);
    }

    pub fn testFormatMemCtx() !void {
        var temp = try mem.createTempAllocSet("str_test_context", .{});
        defer temp.deinit();

        const value = try formatMemCtx(&temp.current, "value={d}", .{42});
        try std.testing.expectEqualStrings("value=42", value);
        try std.testing.expectEqual(@as(u8, 0), value.ptr[value.len]);

        const fallback = try formatMemCtx(null, "fallback", .{});
        try std.testing.expectEqualStrings("fallback", fallback);
    }
};
