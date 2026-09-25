LOAD '$libdir/pgzx_unit';

SELECT current_setting('pgzx_test.bool') AS bool_default;
SET pgzx_test.bool = on;
SELECT current_setting('pgzx_test.bool') AS bool_set;
RESET pgzx_test.bool;
SELECT current_setting('pgzx_test.bool') AS bool_reset;

SELECT current_setting('pgzx_test.int') AS int_default;
SET pgzx_test.int = -10;
SELECT current_setting('pgzx_test.int') AS int_min;
SET pgzx_test.int = 100;
SELECT current_setting('pgzx_test.int') AS int_max;
RESET pgzx_test.int;
SELECT current_setting('pgzx_test.int') AS int_reset;

SELECT current_setting('pgzx_test.string') AS string_default;
SET pgzx_test.string = 'next';
SELECT current_setting('pgzx_test.string') AS string_next;
SET pgzx_test.string = '';
SELECT current_setting('pgzx_test.string') AS string_empty;
SET pgzx_test.string = ' spaced value ';
SELECT current_setting('pgzx_test.string') AS string_spaced;
SET pgzx_test.string = 'next';

DO $$
BEGIN
    SET pgzx_test.bool = 'not-a-bool';
    RAISE EXCEPTION 'expected invalid bool' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
END
$$;

DO $$
BEGIN
    SET pgzx_test.int = 'not-an-int';
    RAISE EXCEPTION 'expected invalid integer' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
END
$$;

DO $$
BEGIN
    SET pgzx_test.int = 101;
    RAISE EXCEPTION 'expected out-of-range integer' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
END
$$;

DO $$
BEGIN
    SET pgzx_test.string = 'rejected';
    RAISE EXCEPTION 'expected rejected string' USING ERRCODE = 'P0001';
EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
END
$$;

SELECT current_setting('pgzx_test.bool') AS bool_after_error;
SELECT current_setting('pgzx_test.int') AS int_after_error;
SELECT current_setting('pgzx_test.string') AS string_after_error;

RESET pgzx_test.string;
SELECT current_setting('pgzx_test.string') AS string_reset;
