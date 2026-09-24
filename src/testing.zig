const pgzx = @import("pgzx.zig");
const fmgr_tests = @import("testing/fmgr.zig");
const guc_tests = @import("testing/guc.zig");
const varatt = @import("pgzx/varatt.zig");

pub export fn _PG_init() void {
    guc_tests.register();
}

comptime {
    pgzx.PG_MODULE_MAGIC();
    pgzx.PG_FUNCTION_V1("pgzx_test_fmgr_mixed", fmgr_tests.mixed);
    pgzx.PG_FUNCTION_V1("pgzx_test_fmgr_required", fmgr_tests.required);

    pgzx.testing.registerTests(
        @import("build_options").testfn,
        .{
            pgzx.collections.list.TestSuite_PointerList,
            pgzx.collections.slist.TestSuite_SList,
            pgzx.collections.dlist.TestSuite_DList,
            pgzx.collections.htab.TestSuite_HTab,

            pgzx.meta.TestSuite_Meta,
            pgzx.mem.TestSuite_Mem,
            pgzx.node.TestSuite_Node,
            pgzx.datum.TestSuite_Datum,
            varatt.TestSuite_Varatt,
            pgzx.str.TestSuite_Str,
            pgzx.spi.TestSuite_SPI,
            pgzx.pq.TestSuite_PQ,
            pgzx.err.TestSuite_Err,
            pgzx.elog.TestSuite_Elog,
            guc_tests.TestSuite_Guc,
        },
    );
}
