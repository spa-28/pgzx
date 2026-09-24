const std = @import("std");
const pg = @import("pgzx_pgsys");

const meta = @import("meta.zig");
const mem = @import("mem.zig");
const err = @import("err.zig");
const datum = @import("datum.zig");

pub fn connect() err.PGError!void {
    const status = pg.SPI_connect();
    if (status == pg.SPI_ERROR_CONNECT) {
        return err.PGError.SPIConnectFailed;
    }
}

pub fn connectNonAtomic() err.PGError!void {
    const status = pg.SPI_connect_ext(pg.SPI_OPT_NONATOMIC);
    try checkStatus(status);
}

pub fn finish() void {
    _ = pg.SPI_finish();
}

pub const Args = struct {
    types: []const pg.Oid,
    values: []const pg.NullableDatum,

    pub fn has_nulls(self: *const Args) bool {
        for (self.values) |value| {
            if (value.isnull) {
                return true;
            }
        }
        return false;
    }
};

pub const ExecOptions = struct {
    read_only: bool = false,
    limit: c_long = 0,
    args: ?Args = null,
};

pub const SPIError = err.PGError || std.mem.Allocator.Error;

pub fn exec(sql: [:0]const u8, options: ExecOptions) SPIError!isize {
    const ret = try execImpl(sql, options);
    var rows = Rows.init();
    defer rows.deinit();
    return @intCast(ret);
}

pub fn query(sql: [:0]const u8, options: ExecOptions) SPIError!Rows {
    _ = try execImpl(sql, options);
    return Rows.init();
}

pub fn queryTyped(comptime T: type, sql: [:0]const u8, options: ExecOptions) SPIError!RowsOf(T) {
    const rows = try query(sql, options);
    return rows.typed(T);
}

fn execImpl(sql: [:0]const u8, options: ExecOptions) SPIError!c_int {
    if (options.args) |args| {
        if (args.types.len != args.values.len) {
            return err.PGError.SPIArgument;
        }

        var arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const n = args.types.len;
        const nulls: [*c]const u8 = blk: {
            if (args.has_nulls()) {
                var buf = try allocator.alloc(u8, n);
                for (args.values, 0..) |value, i| {
                    buf[i] = if (value.isnull) 'n' else ' ';
                }
                break :blk buf.ptr;
            } else {
                break :blk null;
            }
        };

        const values: [*c]pg.Datum = blk: {
            var buf = try allocator.alloc(pg.Datum, n);
            for (args.values, 0..) |arg, i| {
                buf[i] = arg.value;
            }
            break :blk buf.ptr;
        };

        const status = pg.SPI_execute_with_args(
            sql.ptr,
            @intCast(n),
            @constCast(args.types.ptr),
            values,
            nulls,
            options.read_only,
            options.limit,
        );
        try checkStatus(status);
        return status;
    } else {
        const status = pg.SPI_execute(sql.ptr, options.read_only, options.limit);
        try checkStatus(status);
        return status;
    }
}

fn scanProcessed(row: usize, values: anytype) !void {
    scanProcessedFrame(SPIFrame.get(), row, values);
}

inline fn scanProcessedFrame(frame: SPIFrame, row: usize, values: anytype) !void {
    var column: c_int = 1;
    inline for (std.meta.fields(@TypeOf(values)), 0..) |field, i| {
        column = try scanField(field.type, frame, values[i], row, column);
    }
}

fn scanField(
    comptime fieldType: type,
    frame: SPIFrame,
    to: anytype,
    row: usize,
    column: c_int,
) !c_int {
    if (!meta.isPointer(fieldType)) {
        @compileError("scanField requires a pointer");
    }

    const child_type = meta.pointerElemType(fieldType);
    if (@typeInfo(child_type) == .@"struct") {
        var struct_column = column;
        inline for (std.meta.fields(child_type)) |field| {
            const child_ptr = &@field(to.*, field.name);
            struct_column = try scanField(@TypeOf(child_ptr), frame, child_ptr, row, struct_column);
        }
        return struct_column;
    } else {
        const value = try convBinValue(child_type, frame, row, column);
        to.* = value;
        return column + 1;
    }
}

pub fn OwnedSPIFrameRows(comptime R: type) type {
    return struct {
        rows: R,

        const Self = @This();

        pub inline fn init(r: R) Self {
            return .{ .rows = r };
        }

        pub inline fn deinit(self: *Self) void {
            self.rows.deinit();
            finish();
        }

        pub fn next(self: *Self) meta.fnReturnType(@TypeOf(R.next)) {
            return self.rows.next();
        }

        pub fn scan(self: *Self, values: anytype) !void {
            if (comptime !@hasDecl(R, "scan"))
                @compileError("no scan method available");
            return self.rows.scan(values);
        }
    };
}

// Rows iterates over SPI_tuptable from the last executed SPI query.
// When initializing a Rows iterator we capture the current SPI_tuptable from
// the active SPI frame.
//
// Safety:
// =======
//
// The underlying tuple table is released when the current frame is released
// via `finish`. The iterator must not be used after. We have no way to check
// if the current frame was released or not. Accessing the tuple table after a
// release will result in undefined behavior.
//
// Due to SPI managing a stack of SPI frames it is safe to use `connect` to
// create a child frame to run queries while iterating over the rows.
//
pub const Rows = struct {
    row: isize,
    spi_frame: SPIFrame,

    fn init() Rows {
        return .{
            .row = -1,
            .spi_frame = SPIFrame.get(),
        };
    }

    fn typed(self: Rows, comptime T: type) RowsOf(T) {
        return RowsOf(T).init(self);
    }

    fn ownedSPIFrame(self: Rows) OwnedSPIFrameRows(Rows) {
        return OwnedSPIFrameRows(Rows).init(self);
    }

    pub fn deinit(self: *Rows) void {
        if (self.spi_frame.tuptable) |tt| {
            pg.SPI_freetuptable(tt);
        }
        self.row = -1;
    }

    pub fn next(self: *Rows) bool {
        const next_idx = self.row + 1;
        if (self.spi_frame.tuptable == null or next_idx >= self.spi_frame.processed) {
            return false;
        }
        self.row = next_idx;
        return true;
    }

    pub fn scan(self: *Rows, values: anytype) !void {
        if (self.row < 0) {
            return err.PGError.SPIInvalidRowIndex;
        }
        try scanProcessedFrame(self.spi_frame, @intCast(self.row), values);
    }
};

pub fn RowsOf(comptime T: type) type {
    return struct {
        rows: Rows,

        const Self = @This();
        pub const Owned = OwnedSPIFrameRows(Self);

        pub fn init(rows: Rows) Self {
            return .{ .rows = rows };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit();
        }

        pub fn ownedSPIFrame(self: Self) Self.Owned {
            return OwnedSPIFrameRows(Self).init(self);
        }

        pub fn next(self: *Self) !?T {
            if (!self.rows.next()) {
                return null;
            }
            var value: T = undefined;
            try self.rows.scan(.{&value});
            return value;
        }
    };
}

// The SPI interface uses a
const SPIFrame = struct {
    processed: u64,
    tuptable: ?*pg.SPITupleTable,

    inline fn get() SPIFrame {
        return .{
            .processed = pg.SPI_processed,
            .tuptable = pg.SPI_tuptable,
        };
    }
};

pub fn convProcessed(comptime T: type, row: c_int, col: c_int) !T {
    if (row < 0) return err.PGError.SPIInvalidRowIndex;
    return convBinValue(T, SPIFrame.get(), @intCast(row), col);
}

pub fn convBinValue(comptime T: type, frame: SPIFrame, row: usize, col: c_int) !T {
    const table = frame.tuptable orelse return err.PGError.SPIInvalidRowIndex;
    if (row >= frame.processed) return err.PGError.SPIInvalidRowIndex;

    var nd: pg.NullableDatum = undefined;
    const desc = table.*.tupdesc;
    nd.value = pg.SPI_getbinval(table.*.vals[row], desc, col, @ptrCast(&nd.isnull));
    try checkStatus(pg.SPI_result);
    // SPI_gettypeid instead of poking TupleDescData.attrs: PG18 moved to
    // compact attributes and the translated TupleDescAttr helper is broken.
    const oid = pg.SPI_gettypeid(desc, col);
    return try datum.fromNullableDatumWithOID(T, nd, oid);
}

fn checkStatus(st: c_int) err.PGError!void {
    switch (st) {
        pg.SPI_ERROR_CONNECT => return err.PGError.SPIConnectFailed,
        pg.SPI_ERROR_ARGUMENT => return err.PGError.SPIArgument,
        pg.SPI_ERROR_COPY => return err.PGError.SPICopy,
        pg.SPI_ERROR_TRANSACTION => return err.PGError.SPITransaction,
        pg.SPI_ERROR_OPUNKNOWN => return err.PGError.SPIOpUnknown,
        pg.SPI_ERROR_UNCONNECTED => return err.PGError.SPIUnconnected,
        pg.SPI_ERROR_NOATTRIBUTE => return err.PGError.SPINoAttribute,
        else => {
            if (st < 0) {
                return err.PGError.SPIError;
            }
        },
    }
}

pub const TestSuite_SPI = struct {
    const TypedRow = struct {
        number: i32,
        flag: bool,
        text: [:0]const u8,
        nullable: ?i32,
    };

    pub fn testUnconnectedAndArgumentGuards() !void {
        try std.testing.expectError(err.PGError.SPIUnconnected, exec("SELECT 1", .{}));

        const non_null = Args{
            .types = &.{pg.INT4OID},
            .values = &.{.{ .value = 0, .isnull = false }},
        };
        try std.testing.expect(!non_null.has_nulls());

        const with_null = Args{
            .types = &.{pg.INT4OID},
            .values = &.{.{ .value = 0, .isnull = true }},
        };
        try std.testing.expect(with_null.has_nulls());

        const mismatched = Args{
            .types = &.{pg.INT4OID},
            .values = &.{},
        };
        try std.testing.expectError(err.PGError.SPIArgument, query("SELECT 1", .{ .args = mismatched }));
    }

    pub fn testTypedArguments() !void {
        try connect();
        defer finish();

        const types = [_]pg.Oid{ pg.INT4OID, pg.TEXTOID, pg.INT4OID };
        const values = [_]pg.NullableDatum{
            try datum.toNullableDatum(@as(i32, -42)),
            try datum.toNullableDatumWithOID(@as([]const u8, ""), pg.TEXTOID),
            try datum.toNullableDatum(@as(?i32, null)),
        };
        var rows = try queryTyped(TypedRow, "SELECT $1, true, $2, $3", .{
            .args = .{ .types = &types, .values = &values },
        });
        defer rows.deinit();

        const row = (try rows.next()).?;
        try std.testing.expectEqual(@as(i32, -42), row.number);
        try std.testing.expect(row.flag);
        try std.testing.expectEqualStrings("", row.text);
        try std.testing.expectEqual(@as(?i32, null), row.nullable);
        try std.testing.expectEqual(@as(?TypedRow, null), try rows.next());
    }

    pub fn testScanAndProcessedGuards() !void {
        try connect();
        defer finish();

        var rows = try query("VALUES (1::int4, 'one'::text), (2::int4, 'two'::text)", .{});
        defer rows.deinit();

        var number: i32 = undefined;
        var text: [:0]const u8 = undefined;
        try std.testing.expectError(err.PGError.SPIInvalidRowIndex, rows.scan(.{ &number, &text }));
        try std.testing.expectError(err.PGError.SPIInvalidRowIndex, convProcessed(i32, 2, 1));

        try std.testing.expect(rows.next());
        try rows.scan(.{ &number, &text });
        try std.testing.expectEqual(@as(i32, 1), number);
        try std.testing.expectEqualStrings("one", text);

        try std.testing.expect(rows.next());
        try rows.scan(.{ &number, &text });
        try std.testing.expectEqual(@as(i32, 2), number);
        try std.testing.expectEqualStrings("two", text);
        try std.testing.expect(!rows.next());
        try std.testing.expect(!rows.next());
    }

    pub fn testStatusAndLimit() !void {
        try connect();
        defer finish();

        try std.testing.expectEqual(@as(isize, pg.SPI_OK_SELECT), try exec("SELECT 1", .{}));

        var rows = try queryTyped(i32, "SELECT generate_series(1, 5)", .{ .limit = 2 });
        defer rows.deinit();

        try std.testing.expectEqual(@as(?i32, 1), try rows.next());
        try std.testing.expectEqual(@as(?i32, 2), try rows.next());
        try std.testing.expectEqual(@as(?i32, null), try rows.next());
    }

    pub fn testProcessedWithoutTupleTable() !void {
        try connect();
        defer finish();

        _ = try exec("CREATE TEMP TABLE pgzx_spi_no_return (value integer) ON COMMIT DROP", .{});
        _ = try exec("INSERT INTO pgzx_spi_no_return VALUES (1)", .{});
        try std.testing.expectEqual(@as(u64, 1), pg.SPI_processed);
        try std.testing.expect(pg.SPI_tuptable == null);
        try std.testing.expectError(err.PGError.SPIInvalidRowIndex, convProcessed(i32, 0, 1));
    }

    pub fn testNestedFramesPreserveParentRows() !void {
        try connect();
        defer finish();

        var parent = try queryTyped(i32, "VALUES (1::int4), (2::int4)", .{});
        defer parent.deinit();
        try std.testing.expectEqual(@as(?i32, 1), try parent.next());

        {
            try connect();
            defer finish();

            var child = try queryTyped([:0]const u8, "SELECT 'child'::text", .{});
            defer child.deinit();
            try std.testing.expectEqualStrings("child", (try child.next()).?);
        }

        try std.testing.expectEqual(@as(?i32, 2), try parent.next());
        try std.testing.expectEqual(@as(?i32, null), try parent.next());
    }

    pub fn testOwnedFrameCleanup() !void {
        {
            try connect();
            var rows = (try queryTyped(i32, "SELECT 9::int4", .{})).ownedSPIFrame();
            defer rows.deinit();

            try std.testing.expectEqual(@as(?i32, 9), try rows.next());
            try std.testing.expectEqual(@as(?i32, null), try rows.next());
        }

        {
            try connect();
            var rows = (try query("SELECT 10::int4", .{})).ownedSPIFrame();
            defer rows.deinit();

            var value: i32 = undefined;
            try std.testing.expect(rows.next());
            try rows.scan(.{&value});
            try std.testing.expectEqual(@as(i32, 10), value);
        }

        try std.testing.expectError(err.PGError.SPIUnconnected, exec("SELECT 1", .{}));
    }
};
