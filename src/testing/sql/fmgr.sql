CREATE FUNCTION pgzx_test_fmgr_mixed(integer, boolean, text)
RETURNS text
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_mixed'
LANGUAGE C;

CREATE FUNCTION pgzx_test_fmgr_required(integer)
RETURNS integer
AS '$libdir/pgzx_unit', 'pgzx_test_fmgr_required'
LANGUAGE C;

SELECT pgzx_test_fmgr_mixed(42, true, 'zig') AS mixed;
SELECT pgzx_test_fmgr_mixed(7, true, NULL) AS optional_null;
SELECT pgzx_test_fmgr_mixed(1, false, 'ignored') IS NULL AS nullable_return;
SELECT pgzx_test_fmgr_required(-42) AS required;

DO $$
BEGIN
    PERFORM pgzx_test_fmgr_required(NULL);
    RAISE EXCEPTION 'expected non-optional NULL to fail' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN SQLSTATE 'XX000' THEN NULL;
END
$$;

DROP FUNCTION pgzx_test_fmgr_mixed(integer, boolean, text);
DROP FUNCTION pgzx_test_fmgr_required(integer);
