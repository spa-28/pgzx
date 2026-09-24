const std = @import("std");

const pg = @import("pgzx_pgsys");

const intr = @import("interrupts.zig");
const elog = @import("elog.zig");
const err = @import("err.zig");

pub const conv = @import("pq/conv.zig");

pub const Error = error{
    ConnectionFailure,
    QueryFailure,
    OperationFailed,
    PGErrorStack,
    SendFailed,
    PostmasterDied,
    EmptyQueue,
};

pub const ConnParams = std.StringHashMap([]const u8);

pub const ConnStatus = pg.ConnStatusType;
pub const PollingStatus = pg.PostgresPollingStatusType;
pub const TransactionStatus = pg.PGTransactionStatusType;

pub const FormatCode = enum(isize) { Text = 0, Binary = 1 };

// libpqsrv wrappers and extensions.
const pqsrv = struct {
    // custom waitevent types retrieved from shared memory.

    var wait_event_connect: u32 = 0;
    var wait_event_command: u32 = 0;

    pub fn connectAsync(conninfo: [:0]const u8) Error!*pg.PGconn {
        try err.wrap(pg.pqsrv_connect_prepare, .{});
        return connOrErr(pg.PQconnectStart(conninfo.ptr));
    }

    pub fn connect(conninfo: [:0]const u8) Error!*pg.PGconn {
        const maybeConn: ?*pg.PGconn = try err.wrap(pg.pqsrv_connect, .{ conninfo.ptr, try get_wait_event_connect() });
        return connOrErr(maybeConn);
    }

    pub fn connectParamsAsync(
        keys: [*]const [*c]const u8,
        values: [*c]const [*c]const u8,
        expand_dbname: c_int,
    ) Error!*pg.PGconn {
        try err.wrap(pg.pqsrv_connect_prepare, .{});
        return connOrErr(pg.PQconnectStartParams(keys, values, expand_dbname));
    }

    pub fn connectParams(
        keys: [*]const [*c]const u8,
        values: [*c]const [*c]const u8,
        expand_dbname: c_int,
    ) Error!*pg.PGconn {
        const maybeConn = try err.wrap(pg.pqsrv_connect_params, .{ keys, values, expand_dbname, try get_wait_event_connect() });
        return connOrErr(@ptrCast(maybeConn));
    }

    pub fn waitConnected(conn: *pg.PGconn) !void {
        try err.wrap(pg.pqsrv_wait_connected, .{ conn, try get_wait_event_connect() });
    }

    inline fn get_wait_event_connect() Error!u32 {
        return pg.PG_WAIT_EXTENSION;
        // if (wait_event_connect == 0) {
        //     wait_event_connect = try err.wrap(c.WaitEventExtensionNew, .{"pq_connect"});
        // }
        // return wait_event_connect;
    }

    inline fn get_wait_event_command() Error!u32 {
        return pg.PG_WAIT_EXTENSION;
        // if (wait_event_command == 0) {
        //     wait_event_command = try err.wrap(c.WaitEventExtensionNew, .{"pq_command"});
        // }
        // return wait_event_command;
    }

    fn connOrErr(maybe_conn: ?*pg.PGconn) Error!*pg.PGconn {
        if (maybe_conn) |conn| {
            return conn;
        }
        return error.ConnectionFailure;
    }
};

pub const Conn = struct {
    const Self = @This();

    conn: *pg.PGconn,
    allocator: std.mem.Allocator,

    const Options = struct {
        wait: bool = false,
        check: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, conn: *pg.PGconn) Self {
        return Self{ .conn = conn, .allocator = allocator };
    }

    pub fn connect(allocator: std.mem.Allocator, conninfo: [:0]const u8, options: Options) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const local_allocator = arena.allocator();

        const conninfoZ = try local_allocator.dupeZ(u8, conninfo);
        const connector = if (options.wait) &pqsrv.connect else &pqsrv.connectAsync;
        const conn = Self.init(allocator, try connector(conninfoZ));
        conn.checkConnSuccess(options) catch |e| {
            conn.finish();
            return e;
        };
        return conn;
    }

    pub fn connectParams(allocator: std.mem.Allocator, params: ConnParams, options: Options) !Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const local_allocator = arena.allocator();

        const c_params = try PGConnParams.init(local_allocator, params);
        const connector = if (options.wait) &pqsrv.connectParams else &pqsrv.connectParamsAsync;
        const conn = Self.init(allocator, try connector(c_params.keys, c_params.values, 0));
        conn.checkConnSuccess(options) catch |e| {
            conn.finish();
            return e;
        };
        return conn;
    }

    fn waitConnected(self: *const Self) !void {
        return pqsrv.waitConnected(self.conn);
    }

    inline fn checkConnSuccess(self: *const Self, options: Options) !void {
        if (!options.wait or !options.check) {
            return;
        }

        if (self.status() != pg.CONNECTION_OK) {
            if (self.errorMessage()) |msg| {
                std.log.err("Connection error: {s}", .{msg});
            }
            return error.ConnectionFailure;
        }
    }

    pub fn connectPoll(self: *const Self) PollingStatus {
        return pg.PQconnectPoll(self.conn);
    }

    pub fn reset(self: *const Self) bool {
        return pg.PQresetStart(self.conn) != 0;
    }

    pub fn resetWait(self: *const Self) !void {
        if (!self.reset()) {
            return error.OperationFailed;
        }
        try self.waitConnected();
    }

    pub fn resetPoll(self: *const Self) PollingStatus {
        return pg.PQresetPoll(self.conn);
    }

    pub fn setNonBlocking(self: *const Self, arg: bool) !void {
        const rs = pg.PQsetnonblocking(self.conn, if (arg) 1 else 0);
        if (rs < 0) {
            return error.OperationFailed;
        }
    }

    pub fn exec(self: *const Self, stmt: [:0]const u8, args: anytype) !Result {
        if (args.len == 0) {
            const rc = pg.PQsendQuery(self.conn, stmt);
            if (rc == 0) {
                pqError(@src(), self.conn) catch |e| return e;
                return Error.SendFailed;
            }
            const res = try self.getRawResultLast();
            return try Self.initExecResult(self.conn, res);
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const local_allocator = arena.allocator();

        var buffer = std.ArrayList(u8).empty;
        return self.execParams(stmt, try buildParams(local_allocator, &buffer, args));
    }

    pub fn execCommand(self: *const Self, command: [:0]const u8, args: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const local_allocator = arena.allocator();

        var buffer = std.ArrayList(u8).empty;
        var res = try self.execParams(
            command,
            try buildParams(local_allocator, &buffer, args),
        );
        res.deinit();
    }

    pub fn execParams(self: *const Self, command: [:0]const u8, params: PGQueryParams) !Result {
        const rc = pg.PQsendQueryParams(
            self.conn,
            command,
            @as(c_int, @intCast(params.values.len)),
            if (params.types) |t| t.ptr else null,
            params.values.ptr,
            if (params.lengths) |l| l.ptr else null,
            if (params.formats) |f| f.ptr else null,
            params.result_format,
        );
        if (rc == 0) {
            pqError(@src(), self.conn) catch |e| return e;
            return Error.SendFailed;
        }
        return try self.getResultLast();
    }

    pub fn query(self: *const Self, stmt: [:0]const u8, args: anytype) !Rows {
        const res = try self.exec(stmt, args);
        return Rows.init(res);
    }

    pub fn queryParams(self: *const Self, stmt: [:0]const u8, params: PGQueryParams) !Rows {
        const res = try self.execParams(stmt, params);
        return Rows.init(res);
    }

    pub fn getResultLast(self: *const Self) !Result {
        const res = try self.getRawResultLast();
        return try Self.initExecResult(self.conn, res);
    }

    fn initExecResult(conn: ?*pg.PGconn, pgres: ?*pg.PGresult) !Result {
        if (responseCodeFatal(pg.PQresultStatus(pgres))) {
            defer pg.PQclear(pgres);
            const raw_error = pg.PQresultErrorMessage(pgres);
            if (raw_error) |msg| {
                return elog.Error(@src(), "{s}", .{std.mem.span(msg)});
            }
            return error.QueryFailure;
        }
        if (pgres) |r| {
            var res = Result.init(r);
            errdefer res.deinit();
            if (res.isError()) {
                if (res.errorMessage()) |msg| {
                    return elog.Error(@src(), "{s}", .{msg});
                }
                return error.QueryFailure;
            }
            return res;
        } else {
            pqError(@src(), conn) catch |e| return e;
            return error.QueryFailure;
        }
    }

    pub fn sendCommand(self: *const Self, command: [:0]const u8, args: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const local_allocator = arena.allocator();

        var buffer = std.ArrayList(u8).empty;
        try self.sendQueryParams(
            command,
            try buildParams(local_allocator, &buffer, args),
        );
    }

    /// Send a query with parameters. We assume that the values are encoded in
    /// text format.
    pub fn sendQueryParams(self: *const Self, stmt: [:0]const u8, params: PGQueryParams) !void {
        std.log.info("conn '{*}' sendQueryParams: {s}", .{ self.conn, stmt });

        const n = params.values.len;
        if (params.types) |t| {
            if (n != t.len) {
                @panic("number of types must match number of values");
            }
        }
        if (params.lengths) |l| {
            if (n != l.len) {
                @panic("number of lengths must match number of values");
            }
        }
        if (params.formats) |f| {
            if (n != f.len) {
                @panic("number of formats must match number of values");
            }
        }

        const rc = pg.PQsendQueryParams(
            self.conn,
            stmt,
            @intCast(n),
            if (params.types) |t| t.ptr else null,
            params.values.ptr,
            if (params.lengths) |l| l.ptr else null,
            if (params.formats) |f| f.ptr else null,
            params.result_format,
        );
        if (rc == 0) {
            pqError(@src(), self.conn) catch |e| return e;
            return Error.SendFailed;
        }
    }

    pub fn sendQuery(self: *const Self, stmt: []const u8) !void {
        const rc = pg.PQsendQuery(self.conn, stmt);
        if (rc == 0) {
            pqError(@src()) catch |e| return e;
            return Error.SendFailed;
        }
    }

    pub fn waitCommandComplete(self: *const Self) !void {
        const ok = try self.getCommandOk();
        if (!ok) {
            return Error.OperationFailed;
        }
    }

    pub fn waitLastCommandComplete(self: *const Self) !void {
        while (try self.tryGetCommandOk()) |ok| {
            if (!ok) {
                return Error.OperationFailed;
            }
        }
    }

    // Consumes the next result and returns true if the result was not null and
    // and the status is PGRES_COMMAND_OK.
    // The result struct is cleared right away.
    pub fn getCommandOk(self: *const Self) !bool {
        return if (try self.tryGetCommandOk()) |r| r else error.EmptyQueue;
    }

    pub fn tryGetCommandOk(self: *const Self) !?bool {
        while (true) {
            if (try self.getResult()) |r| {
                if (r.isError()) {
                    if (r.errorMessage()) |msg| {
                        elog.Warning(@src(), "libpq error message: {s}", .{msg});
                    }
                    return false;
                }
                if (r.status() == pg.PGRES_NONFATAL_ERROR) { // ignore NOTICE or WARNING
                    continue;
                }

                return switch (r.status()) {
                    pg.PGRES_COMMAND_OK,
                    pg.PGRES_TUPLES_OK,
                    pg.PGRES_SINGLE_TUPLE,
                    => true,
                    else => false,
                };
            } else {
                return null;
            }
        }
    }

    pub fn getResult(self: *const Self) !?Result {
        const res = try self.getRawResult();
        return if (res) |r| Result.init(r) else null;
    }

    pub fn getRawResult(self: *const Self) !?*pg.PGresult {
        try self.waitReady();
        return pg.PQgetResult(self.conn);
    }

    pub fn getRawResultLast(self: *const Self) !?*pg.PGresult {
        var last: ?*pg.PGresult = null;
        errdefer {
            if (last) |r| pg.PQclear(r);
        }

        while (true) {
            const res = try self.getRawResult();
            if (res == null) break;

            if (last) |r| pg.PQclear(r);
            last = res;

            const stopLoop = switch (pg.PQresultStatus(res)) {
                pg.PGRES_COPY_IN,
                pg.PGRES_COPY_OUT,
                pg.PGRES_COPY_BOTH,
                => true,
                else => false,
            };
            if (stopLoop) {
                break;
            }
        }
        return last;
    }

    // Flush pending messages in the send queue and wait for the socket to
    // receive a result that can be read in a non-blocking manner.
    //
    // `waitReady` handles signals and will return an error if the postmaster
    // or CheckForInterrupts indicates that we should shutdown.
    pub fn waitReady(self: *const Self) !void {
        try intr.CheckForInterrupts();
        while (true) {
            var wait_flag: c_int = 0;

            // In case the send queue is not empty we want to be woken up when
            // the socket is writable. This ensures that the loop can continue
            // sending pending messages that are still enqueued in memory only.
            const send_queue_empty = try self.flush();
            if (!send_queue_empty) {
                wait_flag = pg.WL_SOCKET_WRITEABLE;
            }

            try self.consumeInput();
            if (self.isBusy()) {
                wait_flag |= pg.WL_SOCKET_READABLE;
            }

            if (wait_flag == 0) {
                break;
            }

            const rc = pg.WaitLatchOrSocket(pg.MyLatch, wait_flag, self.socket(), 0, pg.PG_WAIT_EXTENSION);
            if (checkFlag(pg.WL_POSTMASTER_DEATH, rc)) {
                return Error.PostmasterDied;
            }
            if (checkFlag(pg.WL_LATCH_SET, rc)) {
                pg.ResetLatch(pg.MyLatch);
                try intr.CheckForInterrupts();
            }
        }
    }

    // Flush the send queue. Returns true if the all data has been sent or if the queue is empty.
    // Return false is the send queue is not send completely.
    pub fn flush(self: *const Self) !bool {
        const rc = pg.PQflush(self.conn);
        if (rc < 0) {
            pqError(@src(), self.conn) catch |e| return e;
            return error.OperationFailed;
        }
        return rc == 0;
    }

    pub fn consumeInput(self: *const Self) !void {
        const rc = pg.PQconsumeInput(self.conn);
        if (rc == 0) {
            pqError(@src(), self.conn) catch |e| return e;
            return error.OperationFailed;
        }
    }

    pub fn finish(self: *const Self) void {
        pg.pqsrv_disconnect(self.conn);
    }

    pub fn status(self: *const Self) ConnStatus {
        return pg.PQstatus(self.conn);
    }

    pub fn transactionStatus(self: *const Self) TransactionStatus {
        return pg.PQtransactionStatus(self.conn);
    }

    pub fn serverVersion(self: *const Self) c_int {
        return pg.PQserverVersion(self.conn);
    }

    pub fn errorMessage(self: *const Self) ?[:0]const u8 {
        if (pg.PQerrorMessage(self.conn)) |msg| {
            return std.mem.span(msg);
        }
        return null;
    }

    pub fn socket(self: *const Self) c_int {
        return pg.PQsocket(self.conn);
    }

    pub fn backendPID(self: *const Self) c_int {
        return pg.PQbackendPID(self.conn);
    }

    pub fn host(self: *const Self) [:0]const u8 {
        return std.mem.span(pg.PQhost(self.conn));
    }

    pub fn port(self: *const Self) [:0]const u8 {
        return std.mem.span(pg.PQport(self.conn));
    }

    pub fn dbname(self: *const Self) [:0]const u8 {
        return std.mem.span(pg.PQdb(self.conn));
    }

    pub fn isBusy(self: *const Self) bool {
        return pg.PQisBusy(self.conn) != 0;
    }
};

const PGConnParams = struct {
    keys: [*]const [*c]const u8,
    values: [*c]const [*c]const u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, in: std.StringHashMap([]const u8)) !PGConnParams {
        const n = in.count();
        var keys = try alloc.alloc([*c]const u8, n + 1);
        var values = try alloc.alloc([*c]const u8, n + 1);

        var i: usize = 0;
        var it = in.iterator();
        while (it.next()) |entry| {
            keys[i] = try alloc.dupeZ(u8, entry.key_ptr.*);
            values[i] = try alloc.dupeZ(u8, entry.value_ptr.*);
            i += 1;
        }
        keys[i] = null;
        values[i] = null;

        return PGConnParams{ .keys = keys.ptr, .values = values.ptr, .allocator = alloc };
    }

    pub fn deinit(self: *PGConnParams) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
    }
};

pub const StartupStatus = enum {
    CONNECTING,
    CONNECTED,
    ERROR,
};

pub const PollStartState = struct {
    polltype: pg.PostgresPollingStatusType,
    status: StartupStatus = StartupStatus.CONNECTING,

    const Self = @This();

    pub fn new(conn: *const Conn) Self {
        var self: Self = undefined;
        self.init();
        _ = self.update(conn);
        return self;
    }

    pub fn init(self: *Self) void {
        self.* = .{ .polltype = 0 };
    }

    pub fn update(self: *Self, conn: *const Conn) bool {
        const pq_status = conn.status();
        var status_update = switch (pq_status) {
            pg.CONNECTION_OK => StartupStatus.CONNECTED,
            pg.CONNECTION_BAD => StartupStatus.ERROR,
            else => StartupStatus.CONNECTING,
        };

        if (status_update != StartupStatus.CONNECTING) {
            const changed = self.status != status_update;
            self.status = status_update;
            return changed;
        }

        // still connecting
        self.polltype = conn.connectPoll();
        status_update = switch (self.polltype) {
            pg.PGRES_POLLING_FAILED => StartupStatus.ERROR,
            pg.PGRES_POLLING_OK => StartupStatus.CONNECTED,
            else => StartupStatus.CONNECTING,
        };
        const changed = self.status != status_update;
        self.status = status_update;
        return changed;
    }

    pub fn getEventMask(self: *const Self) u32 {
        if (self.status == StartupStatus.CONNECTING) {
            return switch (self.polltype) {
                pg.PGRES_POLLING_READING => pg.WL_SOCKET_READABLE,
                else => pg.WL_SOCKET_WRITEABLE,
            };
        }
        return 0;
    }
};

fn responseCodeFatal(response_code: pg.ExecStatusType) bool {
    return switch (response_code) {
        pg.PGRES_COMMAND_OK => false,
        pg.PGRES_TUPLES_OK => false,
        pg.PGRES_SINGLE_TUPLE => false,
        pg.PGRES_NONFATAL_ERROR => false,
        else => response_code > 0,
    };
}

pub const PGQueryParams = struct {
    values: []const [*c]const u8,

    // Optional OID types of the values. Required for binary encodings.
    // In case of text encoding optional.
    types: ?[]const pg.Oid = null,

    // byte length per value in case values are binary encoded.
    lengths: ?[]const c_int = null,

    // Optional array to indicate the value encoding per value.
    // If null all values are encoded in text format. Only required in case
    // parameters use the binary encoding.
    formats: ?[]const c_int = null,

    // Encoding format postgres should respond with. 0 for text, 1 for binary.
    result_format: c_int = 0,
};

// Build a set of parameters from Zig values to be used with execParams and
// sendQueryParams variants.
//
// The values and types arrays are allocated in the given allocator.
//
// WARNING:
// Do not deallocate the buffer while the PGQueryParams is still in use.
// Values are encoded into the given buffer. The values array will hold
// pointers into the buffer for each value.
pub fn buildParams(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    args: anytype,
) !PGQueryParams {
    const argsType = @TypeOf(args);
    const argsInfo = @typeInfo(argsType);
    if (argsInfo != .@"struct" or !argsInfo.@"struct".is_tuple) {
        return std.debug.panic("params must be a tuple");
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var local_allocator = arena.allocator();

    // The buffer might grow and pointers might get invalidated.
    // Let's collect the positions of the values in the buffer so we can
    // collect the pointers after the encoding buffer has been fully written.
    var value_indices = try local_allocator.alloc(i32, argsInfo.@"struct".fields.len);

    var types = try allocator.alloc(pg.Oid, argsInfo.@"struct".fields.len);
    errdefer allocator.free(types);

    {
        var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, buffer);
        errdefer buffer.* = writer.toArrayList();

        inline for (argsInfo.@"struct".fields, 0..) |field, idx| {
            const codec = conv.find(field.type);
            types[idx] = codec.OID;

            const initPos = writer.written().len;
            try codec.write(&writer.writer, @field(args, field.name));
            const pos = writer.written().len;
            if (initPos == pos) {
                value_indices[idx] = -1;
            } else {
                value_indices[idx] = @intCast(initPos);
            }
        }
        buffer.* = writer.toArrayList();
    }

    var values = try allocator.alloc([*c]const u8, value_indices.len);
    for (value_indices, 0..) |pos, idx| {
        if (pos == -1) {
            values[idx] = null;
        } else {
            values[idx] = buffer.items[@intCast(pos)..].ptr;
        }
    }

    return PGQueryParams{
        .types = types,
        .values = values,
    };
}

const Result = struct {
    result: *pg.PGresult,

    const Self = @This();

    fn init(result: *pg.PGresult) Self {
        return Result{ .result = result };
    }

    pub fn deinit(self: Self) void {
        pg.PQclear(self.result);
    }

    pub fn status(self: Self) pg.ExecStatusType {
        return pg.PQresultStatus(self.result);
    }

    pub fn isError(self: Self) bool {
        return switch (self.status()) {
            pg.PGRES_EMPTY_QUERY,
            pg.PGRES_COMMAND_OK,
            pg.PGRES_TUPLES_OK,
            pg.PGRES_COPY_OUT,
            pg.PGRES_COPY_IN,
            pg.PGRES_COPY_BOTH,
            pg.PGRES_SINGLE_TUPLE,
            pg.PGRES_NONFATAL_ERROR, // warning or notice, but no error
            => false,
            else => true,
        };
    }

    pub fn errorMessage(self: Self) ?[:0]const u8 {
        if (pg.PQresultErrorMessage(self.result)) |msg| {
            return std.mem.span(msg);
        }
        return null;
    }

    pub fn numRows(self: Self) usize {
        return @intCast(pg.PQntuples(self.result));
    }

    pub fn rowDescription(self: Self) RowDescription {
        return .{ .result = self };
    }
};

pub const Rows = struct {
    result: Result,
    row: isize,
    numrows: isize,

    pub fn init(result: Result) Rows {
        return .{
            .result = result,
            .numrows = @intCast(result.numRows()),
            .row = -1,
        };
    }

    pub inline fn deinit(self: *Rows) void {
        self.result.deinit();
    }

    pub inline fn numRowsTotal(self: Rows) usize {
        return @intCast(pg.PQntuples(self.result.result));
    }

    pub inline fn numRowsLeft(self: Rows) usize {
        return self.numRowsTotal() - @as(usize, @intCast(self.row + 1));
    }

    pub inline fn rowDescription(self: Rows) RowDescription {
        return .{ .result = self.result };
    }

    pub fn next(self: *Rows) ?Tuple {
        const next_idx = self.row + 1;
        if (next_idx >= self.numrows) {
            return null;
        }
        self.row = next_idx;
        return self.tuple();
    }

    inline fn tuple(self: Rows) Tuple {
        return .{ .result = self.result, .idx = self.row };
    }
};

pub const Tuple = struct {
    result: Result,
    idx: isize,

    pub inline fn numFields(self: Tuple) usize {
        return @intCast(pg.PQnfields(self.result.result));
    }

    pub inline fn field(self: Tuple, f: usize) Field {
        return .{ .result = self.result, .row = self.idx, .col = f };
    }

    pub inline fn isNull(self: Tuple, f: usize) bool {
        return self.field(f).isNull();
    }

    pub inline fn len(self: Tuple, f: usize) usize {
        return self.field(f).len();
    }

    pub inline fn data(self: Tuple, f: usize) [*c]const u8 {
        return self.field(f).data();
    }
};

pub const Field = struct {
    result: Result,
    row: isize,
    col: usize,

    pub fn description(self: Field) FieldDescription {
        return .{ .result = self.result, .idx = self.col };
    }

    pub fn isNull(self: Field) bool {
        return pg.PQgetisnull(self.result.result, @intCast(self.row), @intCast(self.col)) == 1;
    }

    pub fn len(self: Field) usize {
        return @intCast(pg.PQgetlength(self.result.result, @intCast(self.row), @intCast(self.col)));
    }

    pub fn data(self: Field) [*c]const u8 {
        return pg.PQgetvalue(self.result.result, @intCast(self.row), @intCast(self.col));
    }
};

pub const RowDescription = struct {
    result: Result,

    pub fn len(self: RowDescription) usize {
        return @intCast(pg.PQnfields(self.result.result));
    }

    pub fn field(self: RowDescription, idx: usize) ?FieldDescription {
        return if (idx >= self.len()) null else .{
            .result = self.result,
            .idx = idx,
        };
    }
};

pub const FieldDescription = struct {
    result: Result,
    idx: usize,

    pub fn name(self: FieldDescription) ?[:0]const u8 {
        const c = pg.PQfname(self.result.result, @intCast(self.idx));
        return if (c != null) std.mem.span(c) else null;
    }

    pub fn format(self: FieldDescription) FormatCode {
        const c = pg.PQfformat(self.result.result, @intCast(self.idx));
        return @enumFromInt(c);
    }

    pub fn typeOID(self: FieldDescription) pg.Oid {
        return pg.PQftype(self.result.result, @intCast(self.idx));
    }

    pub fn modifier(self: FieldDescription) c_int {
        return pg.PQfmod(self.result.result, @intCast(self.idx));
    }

    pub fn size(self: FieldDescription) isize {
        return @intCast(pg.PQfsize(self.result.result, @intCast(self.idx)));
    }
};

fn checkFlag(comptime pattern: anytype, value: @TypeOf(pattern)) bool {
    return (value & pattern) == pattern;
}

fn pqError(src: std.builtin.SourceLocation, conn: ?*pg.PGconn) error{PGErrorStack}!void {
    const rawerr = pg.PQerrorMessage(conn);
    if (rawerr == null) {
        return;
    }

    return elog.Error(src, "{s}", .{std.mem.span(rawerr)});
}

pub const TestSuite_PQ = struct {
    const allocator = @import("mem.zig").PGCurrentContextAllocator;

    fn expectEncoded(comptime T: type, value: T, expected: []const u8) !void {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try conv.find(T).write(&writer.writer, value);
        try std.testing.expectEqualSlices(u8, expected, writer.written());
    }

    fn expectIntegerRoundTrip(comptime T: type, value: T, expected: [:0]const u8) !void {
        try expectEncoded(T, value, expected[0 .. expected.len + 1]);
        try std.testing.expectEqual(value, try conv.find(T).parse(expected));
    }

    fn expectFloatRoundTrip(comptime T: type, value: T) !void {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try conv.find(T).write(&writer.writer, value);
        const bytes = writer.written();
        const encoded: [:0]const u8 = bytes[0 .. bytes.len - 1 :0];
        try std.testing.expectApproxEqRel(value, try conv.find(T).parse(encoded), 0.00001);
    }

    pub fn testCodecOIDs() !void {
        inline for (.{
            .{ bool, pg.BOOLOID },
            .{ i8, pg.INT2OID },
            .{ i16, pg.INT2OID },
            .{ i32, pg.INT4OID },
            .{ i64, pg.INT8OID },
            .{ u8, pg.INT2OID },
            .{ u16, pg.INT4OID },
            .{ u32, pg.INT8OID },
            .{ f32, pg.FLOAT4OID },
            .{ f64, pg.FLOAT8OID },
            .{ []const u8, pg.TEXTOID },
            .{ [:0]const u8, pg.TEXTOID },
            .{ ?i32, pg.INT4OID },
        }) |entry| {
            try std.testing.expectEqual(@as(pg.Oid, entry[1]), conv.find(entry[0]).OID);
        }
    }

    pub fn testBoolCodec() !void {
        try expectEncoded(bool, true, "t\x00");
        try expectEncoded(bool, false, "f\x00");
        try std.testing.expect(try conv.find(bool).parse("t"));
        try std.testing.expect(!try conv.find(bool).parse("f"));
        try std.testing.expectError(conv.Error.InvalidBool, conv.find(bool).parse(""));
        try std.testing.expectError(conv.Error.InvalidBool, conv.find(bool).parse("true"));
        try std.testing.expectError(conv.Error.InvalidBool, conv.find(bool).parse("x"));
    }

    pub fn testIntegerCodecs() !void {
        try expectIntegerRoundTrip(i8, std.math.minInt(i8), "-128");
        try expectIntegerRoundTrip(i8, std.math.maxInt(i8), "127");
        try expectIntegerRoundTrip(i16, std.math.minInt(i16), "-32768");
        try expectIntegerRoundTrip(i16, std.math.maxInt(i16), "32767");
        try expectIntegerRoundTrip(i32, std.math.minInt(i32), "-2147483648");
        try expectIntegerRoundTrip(i32, std.math.maxInt(i32), "2147483647");
        try expectIntegerRoundTrip(i64, std.math.minInt(i64), "-9223372036854775808");
        try expectIntegerRoundTrip(i64, std.math.maxInt(i64), "9223372036854775807");
        try expectIntegerRoundTrip(u8, std.math.maxInt(u8), "255");
        try expectIntegerRoundTrip(u16, std.math.maxInt(u16), "65535");
        try expectIntegerRoundTrip(u32, std.math.maxInt(u32), "4294967295");

        try std.testing.expectError(error.InvalidCharacter, conv.find(i32).parse("not-a-number"));
        try std.testing.expectError(error.Overflow, conv.find(i8).parse("128"));
        try std.testing.expectError(error.Overflow, conv.find(u8).parse("256"));
    }

    pub fn testFloatAndTextCodecs() !void {
        try expectFloatRoundTrip(f32, -1.25);
        try expectFloatRoundTrip(f64, 42.5);
        try std.testing.expectError(error.InvalidCharacter, conv.find(f64).parse("not-a-float"));

        const text: []const u8 = "zig";
        try expectEncoded([]const u8, text, "zig\x00");
        try std.testing.expectEqualStrings(text, try conv.find([]const u8).parse("zig"));

        const text_z: [:0]const u8 = "sentinel";
        try expectEncoded([:0]const u8, text_z, "sentinel\x00");
        const parsed_z = try conv.find([:0]const u8).parse("sentinel");
        try std.testing.expectEqualStrings(text_z, parsed_z);
        try std.testing.expectEqual(@as(u8, 0), parsed_z.ptr[parsed_z.len]);

        try expectEncoded(?i32, null, "");
        try expectEncoded(?i32, 42, "42\x00");
        try expectEncoded([]const u8, "", "\x00");
    }

    pub fn testBuildParams() !void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        var long: [2048]u8 = undefined;
        @memset(&long, 'x');
        const params = try buildParams(allocator, &buffer, .{
            @as(i32, 42),
            @as(?bool, null),
            @as([]const u8, ""),
            @as([]const u8, &long),
            @as([:0]const u8, "tail"),
        });
        defer allocator.free(params.types.?);
        defer allocator.free(params.values);

        try std.testing.expectEqualSlices(pg.Oid, &.{ pg.INT4OID, pg.BOOLOID, pg.TEXTOID, pg.TEXTOID, pg.TEXTOID }, params.types.?);
        try std.testing.expectEqual(@as(usize, 2058), buffer.items.len);
        try std.testing.expectEqualSlices(u8, "42", buffer.items[0..2]);
        try std.testing.expectEqual(@as(u8, 0), buffer.items[2]);
        try std.testing.expectEqual(@as(u8, 0), buffer.items[3]);
        try std.testing.expectEqualSlices(u8, &long, buffer.items[4..2052]);
        try std.testing.expectEqual(@as(u8, 0), buffer.items[2052]);
        try std.testing.expectEqualSlices(u8, "tail", buffer.items[2053..2057]);
        try std.testing.expectEqual(@as(u8, 0), buffer.items[2057]);

        const offsets = [_]?usize{ 0, null, 3, 4, 2053 };
        for (params.values, offsets) |value, offset| {
            if (offset) |position| {
                try std.testing.expectEqual(
                    @intFromPtr(buffer.items.ptr + position),
                    @intFromPtr(value),
                );
            } else {
                try std.testing.expect(value == null);
            }
        }
    }

    pub fn testSyntheticRows() !void {
        const raw = pg.PQmakeEmptyPGresult(null, pg.PGRES_TUPLES_OK) orelse return error.OutOfMemory;
        errdefer pg.PQclear(raw);

        var attrs = [_]pg.PGresAttDesc{
            .{
                .name = @constCast("id".ptr),
                .tableid = 11,
                .columnid = 1,
                .format = 0,
                .typid = pg.INT4OID,
                .typlen = 4,
                .atttypmod = -1,
            },
            .{
                .name = @constCast("label".ptr),
                .tableid = 11,
                .columnid = 2,
                .format = 1,
                .typid = pg.TEXTOID,
                .typlen = -1,
                .atttypmod = 12,
            },
        };
        try std.testing.expectEqual(@as(c_int, 1), pg.PQsetResultAttrs(raw, attrs.len, &attrs));
        try std.testing.expectEqual(@as(c_int, 1), pg.PQsetvalue(raw, 0, 0, @constCast("1".ptr), 1));
        try std.testing.expectEqual(@as(c_int, 1), pg.PQsetvalue(raw, 0, 1, @constCast("alpha".ptr), 5));
        try std.testing.expectEqual(@as(c_int, 1), pg.PQsetvalue(raw, 1, 0, @constCast("22".ptr), 2));
        try std.testing.expectEqual(@as(c_int, 1), pg.PQsetvalue(raw, 1, 1, null, 0));

        var rows = Rows.init(Result.init(raw));
        defer rows.deinit();

        try std.testing.expectEqual(@as(usize, 2), rows.numRowsTotal());
        try std.testing.expectEqual(@as(usize, 2), rows.numRowsLeft());

        const description = rows.rowDescription();
        try std.testing.expectEqual(@as(usize, 2), description.len());
        const id = description.field(0).?;
        try std.testing.expectEqualStrings("id", id.name().?);
        try std.testing.expectEqual(@as(pg.Oid, pg.INT4OID), id.typeOID());
        try std.testing.expectEqual(FormatCode.Text, id.format());
        try std.testing.expectEqual(@as(isize, 4), id.size());
        try std.testing.expectEqual(@as(c_int, -1), id.modifier());
        const label = description.field(1).?;
        try std.testing.expectEqualStrings("label", label.name().?);
        try std.testing.expectEqual(@as(pg.Oid, pg.TEXTOID), label.typeOID());
        try std.testing.expectEqual(FormatCode.Binary, label.format());
        try std.testing.expectEqual(@as(isize, -1), label.size());
        try std.testing.expectEqual(@as(c_int, 12), label.modifier());
        try std.testing.expect(description.field(2) == null);

        const first = rows.next().?;
        try std.testing.expectEqual(@as(usize, 2), first.numFields());
        try std.testing.expect(!first.isNull(0));
        try std.testing.expectEqualSlices(u8, "1", first.data(0)[0..first.len(0)]);
        try std.testing.expectEqualSlices(u8, "alpha", first.data(1)[0..first.len(1)]);
        try std.testing.expectEqual(@as(usize, 1), rows.numRowsLeft());

        const second = rows.next().?;
        try std.testing.expectEqualSlices(u8, "22", second.data(0)[0..second.len(0)]);
        try std.testing.expect(second.isNull(1));
        try std.testing.expectEqual(@as(usize, 0), second.len(1));
        try std.testing.expectEqual(@as(usize, 0), rows.numRowsLeft());
        try std.testing.expect(rows.next() == null);
    }
};
