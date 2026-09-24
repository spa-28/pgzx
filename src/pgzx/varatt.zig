//! varatt replaces the VA<...> macros from utils/varattr.h that Zig didn't
//! compile correctly.

const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pgzx_pgsys");

const native_endian = builtin.cpu.arch.endian();

// WARNING:
// Taken from translated C code and mostly untested.
// The zig compiler will not complain about errors if inline functions are not used.
//
// TODO:
// We do not want to expose these directly, but we must make sure that we test
// all variable conversions to make sure that code actually compiles.

pub const VARHDRSZ = pg.VARHDRSZ;
pub const VARHDRSZ_SHORT = @sizeOf(varattrib_1b);
pub const VARHDRSZ_EXTERNAL = @sizeOf(varattrib_1b_e);

pub const VARLENA_EXTSIZE_BITS = pg.VARLENA_EXTSIZE_BITS;

pub const VARTAG_EXPANDED_RO = pg.VARTAG_EXPANDED_RO;
pub const VARTAG_EXPANDED_RW = pg.VARTAG_EXPANDED_RW;
pub const VARTAG_INDIRECT = pg.VARTAG_INDIRECT;
pub const VARTAG_ONDISK = pg.VARTAG_ONDISK;

pub inline fn SET_VARSIZE_4B(PTR: anytype, len: anytype) void {
    const ptr: [*c]varattrib_4b = @ptrCast(@alignCast(PTR));
    const value: pg.uint32 = @intCast(len);
    ptr.*.va_4byte.va_header = if (native_endian == .big)
        value & 0x3FFFFFFF
    else
        value << 2;
}

pub inline fn SET_VARSIZE_1B(PTR: anytype, len: anytype) void {
    const ptr: [*c]varattrib_1b = @ptrCast(@alignCast(PTR));
    const value: pg.uint8 = @intCast(len);
    ptr.*.va_header = if (native_endian == .big)
        value | 0x80
    else
        (value << 1) | 0x01;
}

pub inline fn SET_VARSIZE_4B_C(PTR: anytype, len: anytype) void {
    const ptr: [*c]varattrib_4b = @ptrCast(@alignCast(PTR));
    const value: pg.uint32 = @intCast(len);
    ptr.*.va_compressed.va_header = if (native_endian == .big)
        (value & 0x3FFFFFFF) | 0x40000000
    else
        (value << 2) | 0x02;
}

pub inline fn SET_VARTAG_1B_E(PTR: anytype, tag: anytype) void {
    const ptr: [*c]varattrib_1b_e = @ptrCast(@alignCast(PTR));
    ptr.*.va_header = if (native_endian == .big) 0x80 else 0x01;
    ptr.*.va_tag = @intCast(tag);
}

pub const varatt_indirect = pg.varatt_indirect;
pub const varatt_expanded = pg.varatt_expanded;
pub const varatt_external = pg.varatt_external;
pub const varattrib_1b = pg.varattrib_1b;
pub const varattrib_4b = pg.varattrib_4b;
pub const varattrib_1b_e = pg.varattrib_1b_e;

pub const VARLENA_EXTSIZE_MASK = (@as(c_uint, 1) << VARLENA_EXTSIZE_BITS) - @as(c_int, 1);

pub const @"true" = @as(c_int, 1);
pub const @"false" = @as(c_int, 0);

pub inline fn VARTAG_IS_EXPANDED(tag: anytype) @TypeOf((tag & ~@as(c_int, 1)) == VARTAG_EXPANDED_RO) {
    return (tag & ~@as(c_int, 1)) == VARTAG_EXPANDED_RO;
}

pub inline fn VARTAG_SIZE(tag: anytype) usize {
    return if (tag == VARTAG_INDIRECT)
        @sizeOf(varatt_indirect)
    else if (VARTAG_IS_EXPANDED(tag))
        @sizeOf(varatt_expanded)
    else if (tag == VARTAG_ONDISK)
        @sizeOf(varatt_external)
    else
        0;
}

pub inline fn VARATT_IS_4B(PTR: anytype) bool {
    const header = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return if (native_endian == .big)
        (header & 0x80) == 0x00
    else
        (header & 0x01) == 0x00;
}

pub inline fn VARATT_IS_4B_U(PTR: anytype) bool {
    const header = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return if (native_endian == .big)
        (header & 0xC0) == 0x00
    else
        (header & 0x03) == 0x00;
}

pub inline fn VARATT_IS_4B_C(PTR: anytype) bool {
    const header = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return if (native_endian == .big)
        (header & 0xC0) == 0x40
    else
        (header & 0x03) == 0x02;
}

pub inline fn VARATT_IS_1B(PTR: anytype) bool {
    const header = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return if (native_endian == .big)
        (header & 0x80) == 0x80
    else
        (header & 0x01) == 0x01;
}

pub inline fn VARATT_IS_1B_E(PTR: anytype) bool {
    const header = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return header == if (native_endian == .big) 0x80 else 0x01;
}

pub inline fn VARATT_NOT_PAD_BYTE(PTR: anytype) @TypeOf(@as([*c]pg.uint8, @ptrCast(@alignCast(PTR))).* != @as(c_int, 0)) {
    return @as([*c]pg.uint8, @ptrCast(@alignCast(PTR))).* != @as(c_int, 0);
}

pub inline fn VARSIZE_4B(PTR: anytype) pg.uint32 {
    const header = @as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_4byte.va_header;
    return if (native_endian == .big)
        header & 0x3FFFFFFF
    else
        (header >> 2) & 0x3FFFFFFF;
}

pub inline fn VARSIZE_1B(PTR: anytype) pg.uint32 {
    const header: pg.uint32 = @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_header;
    return if (native_endian == .big)
        header & 0x7F
    else
        (header >> 1) & 0x7F;
}

pub inline fn VARTAG_1B_E(PTR: anytype) @TypeOf(@as([*c]varattrib_1b_e, @ptrCast(@alignCast(PTR))).*.va_tag) {
    return @as([*c]varattrib_1b_e, @ptrCast(@alignCast(PTR))).*.va_tag;
}

pub inline fn VARDATA_4B(PTR: anytype) @TypeOf(@as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_4byte.va_data()) {
    return @as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_4byte.va_data();
}

pub inline fn VARDATA_4B_C(PTR: anytype) @TypeOf(@as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_data()) {
    return @as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_data();
}

pub inline fn VARDATA_1B(PTR: anytype) @TypeOf(@as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_data()) {
    return @as([*c]varattrib_1b, @ptrCast(@alignCast(PTR))).*.va_data();
}

pub inline fn VARDATA_1B_E(PTR: anytype) @TypeOf(@as([*c]varattrib_1b_e, @ptrCast(@alignCast(PTR))).*.va_data()) {
    return @as([*c]varattrib_1b_e, @ptrCast(@alignCast(PTR))).*.va_data();
}

pub const VARATT_SHORT_MAX = @as(c_int, 0x7F);

pub inline fn VARATT_CAN_MAKE_SHORT(PTR: anytype) bool {
    return VARATT_IS_4B_U(PTR) and (((VARSIZE(PTR) - VARHDRSZ) + VARHDRSZ_SHORT) <= VARATT_SHORT_MAX);
}

pub inline fn VARATT_CONVERTED_SHORT_SIZE(PTR: anytype) @TypeOf((VARSIZE(PTR) - VARHDRSZ) + VARHDRSZ_SHORT) {
    return (VARSIZE(PTR) - VARHDRSZ) + VARHDRSZ_SHORT;
}

pub inline fn VARDATA(PTR: anytype) @TypeOf(VARDATA_4B(PTR)) {
    return VARDATA_4B(PTR);
}

pub inline fn VARSIZE(PTR: anytype) @TypeOf(VARSIZE_4B(PTR)) {
    return VARSIZE_4B(PTR);
}

pub inline fn VARSIZE_SHORT(PTR: anytype) @TypeOf(VARSIZE_1B(PTR)) {
    return VARSIZE_1B(PTR);
}

pub inline fn VARDATA_SHORT(PTR: anytype) @TypeOf(VARDATA_1B(PTR)) {
    return VARDATA_1B(PTR);
}

pub inline fn VARTAG_EXTERNAL(PTR: anytype) @TypeOf(VARTAG_1B_E(PTR)) {
    return VARTAG_1B_E(PTR);
}

pub inline fn VARSIZE_EXTERNAL(PTR: anytype) @TypeOf(VARHDRSZ_EXTERNAL + VARTAG_SIZE(VARTAG_EXTERNAL(PTR))) {
    return VARHDRSZ_EXTERNAL + VARTAG_SIZE(VARTAG_EXTERNAL(PTR));
}

pub inline fn VARDATA_EXTERNAL(PTR: anytype) @TypeOf(VARDATA_1B_E(PTR)) {
    return VARDATA_1B_E(PTR);
}

pub inline fn VARATT_IS_COMPRESSED(PTR: anytype) @TypeOf(VARATT_IS_4B_C(PTR)) {
    return VARATT_IS_4B_C(PTR);
}

pub inline fn VARATT_IS_EXTERNAL(PTR: anytype) @TypeOf(VARATT_IS_1B_E(PTR)) {
    return VARATT_IS_1B_E(PTR);
}

pub inline fn VARATT_IS_EXTERNAL_ONDISK(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and VARTAG_EXTERNAL(PTR) == VARTAG_ONDISK;
}

pub inline fn VARATT_IS_EXTERNAL_INDIRECT(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and VARTAG_EXTERNAL(PTR) == VARTAG_INDIRECT;
}

pub inline fn VARATT_IS_EXTERNAL_EXPANDED_RO(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and VARTAG_EXTERNAL(PTR) == VARTAG_EXPANDED_RO;
}

pub inline fn VARATT_IS_EXTERNAL_EXPANDED_RW(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and VARTAG_EXTERNAL(PTR) == VARTAG_EXPANDED_RW;
}

pub inline fn VARATT_IS_EXTERNAL_EXPANDED(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and VARTAG_IS_EXPANDED(VARTAG_EXTERNAL(PTR));
}

pub inline fn VARATT_IS_EXTERNAL_NON_EXPANDED(PTR: anytype) bool {
    return VARATT_IS_EXTERNAL(PTR) and !VARTAG_IS_EXPANDED(VARTAG_EXTERNAL(PTR));
}

pub inline fn VARATT_IS_SHORT(PTR: anytype) @TypeOf(VARATT_IS_1B(PTR)) {
    return VARATT_IS_1B(PTR);
}

pub inline fn VARATT_IS_EXTENDED(PTR: anytype) bool {
    return !VARATT_IS_4B_U(PTR);
}

pub inline fn SET_VARSIZE(PTR: anytype, len: anytype) @TypeOf(SET_VARSIZE_4B(PTR, len)) {
    return SET_VARSIZE_4B(PTR, len);
}

pub inline fn SET_VARSIZE_SHORT(PTR: anytype, len: anytype) @TypeOf(SET_VARSIZE_1B(PTR, len)) {
    return SET_VARSIZE_1B(PTR, len);
}

pub inline fn SET_VARSIZE_COMPRESSED(PTR: anytype, len: anytype) @TypeOf(SET_VARSIZE_4B_C(PTR, len)) {
    return SET_VARSIZE_4B_C(PTR, len);
}

pub inline fn SET_VARTAG_EXTERNAL(PTR: anytype, tag: anytype) @TypeOf(SET_VARTAG_1B_E(PTR, tag)) {
    return SET_VARTAG_1B_E(PTR, tag);
}

pub inline fn VARSIZE_ANY(PTR: anytype) @TypeOf(if (VARATT_IS_1B_E(PTR)) VARSIZE_EXTERNAL(PTR) else if (VARATT_IS_1B(PTR)) VARSIZE_1B(PTR) else VARSIZE_4B(PTR)) {
    return if (VARATT_IS_1B_E(PTR)) VARSIZE_EXTERNAL(PTR) else if (VARATT_IS_1B(PTR)) VARSIZE_1B(PTR) else VARSIZE_4B(PTR);
}

pub inline fn VARSIZE_ANY_EXHDR(PTR: anytype) @TypeOf(if (VARATT_IS_1B_E(PTR)) @as(usize, @intCast(VARSIZE_EXTERNAL(PTR) - VARHDRSZ_EXTERNAL)) else if (VARATT_IS_1B(PTR)) @as(usize, @intCast(VARSIZE_1B(PTR) - VARHDRSZ_SHORT)) else @as(usize, @intCast(VARSIZE_4B(PTR) - VARHDRSZ))) {
    _ = &PTR;
    return if (VARATT_IS_1B_E(PTR)) @as(usize, @intCast(VARSIZE_EXTERNAL(PTR) - VARHDRSZ_EXTERNAL)) else if (VARATT_IS_1B(PTR)) @as(usize, @intCast(VARSIZE_1B(PTR) - VARHDRSZ_SHORT)) else @as(usize, @intCast(VARSIZE_4B(PTR) - VARHDRSZ));
}

// pub inline fn VARSIZE_ANY_EXHDR(PTR: anytype) @TypeOf(if (VARATT_IS_1B_E(PTR)) VARSIZE_EXTERNAL(PTR) - VARHDRSZ_EXTERNAL else if (VARATT_IS_1B(PTR)) VARSIZE_1B(PTR) - VARHDRSZ_SHORT else VARSIZE_4B(PTR) - VARHDRSZ) {
//     return if (VARATT_IS_1B_E(PTR)) VARSIZE_EXTERNAL(PTR) - VARHDRSZ_EXTERNAL else if (VARATT_IS_1B(PTR)) VARSIZE_1B(PTR) - VARHDRSZ_SHORT else VARSIZE_4B(PTR) - VARHDRSZ;
// }

pub inline fn VARDATA_ANY(PTR: anytype) @TypeOf(if (VARATT_IS_1B(PTR)) VARDATA_1B(PTR) else VARDATA_4B(PTR)) {
    return if (VARATT_IS_1B(PTR)) VARDATA_1B(PTR) else VARDATA_4B(PTR);
}

pub inline fn VARDATA_COMPRESSED_GET_EXTSIZE(PTR: anytype) @TypeOf(@as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_tcinfo & VARLENA_EXTSIZE_MASK) {
    return @as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_tcinfo & VARLENA_EXTSIZE_MASK;
}

pub inline fn VARDATA_COMPRESSED_GET_COMPRESS_METHOD(PTR: anytype) @TypeOf(@as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_tcinfo >> VARLENA_EXTSIZE_BITS) {
    return @as([*c]varattrib_4b, @ptrCast(@alignCast(PTR))).*.va_compressed.va_tcinfo >> VARLENA_EXTSIZE_BITS;
}

pub inline fn VARATT_EXTERNAL_GET_EXTSIZE(toast_pointer: anytype) @TypeOf(toast_pointer.va_extinfo & VARLENA_EXTSIZE_MASK) {
    return toast_pointer.va_extinfo & VARLENA_EXTSIZE_MASK;
}

pub inline fn VARATT_EXTERNAL_GET_COMPRESS_METHOD(toast_pointer: anytype) @TypeOf(toast_pointer.va_extinfo >> VARLENA_EXTSIZE_BITS) {
    return toast_pointer.va_extinfo >> VARLENA_EXTSIZE_BITS;
}

pub inline fn VARATT_EXTERNAL_IS_COMPRESSED(toast_pointer: anytype) @TypeOf(VARATT_EXTERNAL_GET_EXTSIZE(toast_pointer) < (toast_pointer.va_rawsize - VARHDRSZ)) {
    return VARATT_EXTERNAL_GET_EXTSIZE(toast_pointer) < (toast_pointer.va_rawsize - VARHDRSZ);
}

pub const TestSuite_Varatt = struct {
    pub fn testFourByteValue() !void {
        var buffer: [VARHDRSZ + 3]u8 align(@alignOf(varattrib_4b)) = undefined;
        @memset(&buffer, 0);
        SET_VARSIZE_4B(&buffer, buffer.len);
        std.mem.copyForwards(u8, VARDATA_4B(&buffer)[0..3], "zig");

        const header = @as([*c]varattrib_4b, @ptrCast(&buffer)).*.va_4byte.va_header;
        try std.testing.expectEqual(
            if (native_endian == .big) @as(pg.uint32, buffer.len) else @as(pg.uint32, buffer.len) << 2,
            header,
        );
        try std.testing.expect(VARATT_IS_4B(&buffer));
        try std.testing.expect(VARATT_IS_4B_U(&buffer));
        try std.testing.expect(!VARATT_IS_4B_C(&buffer));
        try std.testing.expectEqual(@as(pg.uint32, buffer.len), VARSIZE(&buffer));
        try std.testing.expectEqual(@as(usize, 3), VARSIZE_ANY_EXHDR(&buffer));
        try std.testing.expectEqualStrings("zig", VARDATA_ANY(&buffer)[0..3]);
    }

    pub fn testShortValue() !void {
        var buffer: [VARHDRSZ_SHORT + 3]u8 = undefined;
        @memset(&buffer, 0);
        SET_VARSIZE_1B(&buffer, buffer.len);
        std.mem.copyForwards(u8, VARDATA_1B(&buffer)[0..3], "zig");

        try std.testing.expectEqual(
            if (native_endian == .big) @as(u8, buffer.len) | 0x80 else @as(u8, buffer.len) << 1 | 0x01,
            buffer[0],
        );
        try std.testing.expect(VARATT_IS_1B(&buffer));
        try std.testing.expect(!VARATT_IS_1B_E(&buffer));
        try std.testing.expect(VARATT_IS_SHORT(&buffer));
        try std.testing.expect(VARATT_IS_EXTENDED(&buffer));
        try std.testing.expectEqual(@as(pg.uint32, buffer.len), VARSIZE_SHORT(&buffer));
        try std.testing.expectEqual(@as(usize, 3), VARSIZE_ANY_EXHDR(&buffer));
        try std.testing.expectEqualStrings("zig", VARDATA_SHORT(&buffer)[0..3]);
    }

    pub fn testCompressedValue() !void {
        const header_size = @sizeOf(pg.uint32) * 2;
        var buffer: [header_size + 3]u8 align(@alignOf(varattrib_4b)) = undefined;
        @memset(&buffer, 0);
        SET_VARSIZE_4B_C(&buffer, buffer.len);
        std.mem.copyForwards(u8, VARDATA_4B_C(&buffer)[0..3], "zig");

        const header = @as([*c]varattrib_4b, @ptrCast(&buffer)).*.va_compressed.va_header;
        try std.testing.expectEqual(
            if (native_endian == .big)
                @as(pg.uint32, buffer.len) | 0x40000000
            else
                @as(pg.uint32, buffer.len) << 2 | 0x02,
            header,
        );
        try std.testing.expect(VARATT_IS_4B(&buffer));
        try std.testing.expect(VARATT_IS_COMPRESSED(&buffer));
        try std.testing.expectEqual(@as(pg.uint32, buffer.len), VARSIZE_4B(&buffer));
        try std.testing.expectEqualStrings("zig", VARDATA_4B_C(&buffer)[0..3]);
    }

    pub fn testExternalValue() !void {
        var buffer: [VARHDRSZ_EXTERNAL + @sizeOf(varatt_indirect)]u8 align(@alignOf(varattrib_1b_e)) = undefined;
        @memset(&buffer, 0);
        SET_VARTAG_1B_E(&buffer, VARTAG_INDIRECT);

        try std.testing.expectEqual(if (native_endian == .big) @as(u8, 0x80) else 0x01, buffer[0]);
        try std.testing.expect(VARATT_IS_1B(&buffer));
        try std.testing.expect(VARATT_IS_EXTERNAL(&buffer));
        try std.testing.expect(VARATT_IS_EXTERNAL_INDIRECT(&buffer));
        try std.testing.expectEqual(@as(pg.uint8, @intCast(VARTAG_INDIRECT)), VARTAG_EXTERNAL(&buffer));
        try std.testing.expectEqual(@as(usize, buffer.len), VARSIZE_EXTERNAL(&buffer));
        try std.testing.expectEqual(
            @intFromPtr(&buffer) + VARHDRSZ_EXTERNAL,
            @intFromPtr(VARDATA_EXTERNAL(&buffer)),
        );
    }
};
