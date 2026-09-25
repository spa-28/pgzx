CREATE FUNCTION pgzx_test_fmgr_mixed(integer, boolean, text)
RETURNS text
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_mixed'
LANGUAGE C;

CREATE FUNCTION pgzx_test_fmgr_required(integer)
RETURNS integer
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_required'
LANGUAGE C;

CREATE FUNCTION pgzx_test_fmgr_char_round_trip("char")
RETURNS "char"
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_char_round_trip'
LANGUAGE C;

CREATE FUNCTION pgzx_test_fmgr_name_round_trip(name)
RETURNS name
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_name_round_trip'
LANGUAGE C;

CREATE FUNCTION pgzx_test_fmgr_missing(integer)
RETURNS text
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_mixed'
LANGUAGE C;

SELECT pgzx_test_fmgr_mixed(42, true, 'zig') AS mixed;
SELECT pgzx_test_fmgr_mixed(7, true, NULL) AS optional_null;
SELECT pgzx_test_fmgr_mixed(1, false, 'ignored') IS NULL AS nullable_return;
SELECT pgzx_test_fmgr_required(-42) AS required;
SELECT pgzx_test_fmgr_char_round_trip('Z'::"char") AS char_round_trip;
SELECT pgzx_test_fmgr_name_round_trip('zig_name'::name) AS name_round_trip;

DO $$
BEGIN
    PERFORM pgzx_test_fmgr_required(NULL);
    RAISE EXCEPTION 'expected non-optional NULL to fail' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN SQLSTATE 'XX000' THEN NULL;
END
$$;

DO $$
BEGIN
    PERFORM pgzx_test_fmgr_missing(1);
    RAISE EXCEPTION 'expected missing argument to fail' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN SQLSTATE 'XX000' THEN NULL;
END
$$;

DROP FUNCTION pgzx_test_fmgr_mixed(integer, boolean, text);
DROP FUNCTION pgzx_test_fmgr_required(integer);
DROP FUNCTION pgzx_test_fmgr_char_round_trip("char");
DROP FUNCTION pgzx_test_fmgr_name_round_trip(name);
DROP FUNCTION pgzx_test_fmgr_missing(integer);
