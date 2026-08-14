-- Successful conversions across the type surface.  Highest-weight script: the
-- steady-state workload that failures are interleaved into.
SELECT nextval('pljs_mm_calls');
SELECT mm_int8(:v);
SELECT mm_numeric((:v)::numeric / 7);
SELECT mm_text('row' || :v);
SELECT mm_bytea(decode(md5((:v)::text), 'hex'));
SELECT mm_jsonb(jsonb_build_object('v', :v, 'nested', jsonb_build_array(1, null, 3)));
SELECT mm_int_array();
SELECT mm_text_array();
SELECT mm_jsonb_array();
SELECT mm_array_null();
SELECT mm_comp();
SELECT count(*) FROM mm_srf_multi();
SELECT count(*) FROM mm_srf_single();
SELECT count(*) FROM mm_srf_null_row();
SELECT mm_timestamp('infinity'::timestamptz);
SELECT mm_timestamp(now());
SELECT mm_spi(3);
SELECT mm_spi_unfreed();
SELECT mm_cursor(8);
