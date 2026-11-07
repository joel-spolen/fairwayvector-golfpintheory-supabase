-- Disposable Supabase-like database only, after all migrations including 202611070001.
-- The fixture transaction is rolled back; never run against production data.
begin;
insert into auth.users(id, is_anonymous, deleted_at) values
    ('24000002-0000-4000-8000-000000000002', false, null);
set local request.jwt.claim.role = 'service_role';

do $$
declare
    v_user uuid := '24000002-0000-4000-8000-000000000002';
    v_first timestamptz := '2026-11-07 10:00:00+00';
    v_second timestamptz := '2026-11-07 11:00:00+00';
    v_rows jsonb;
    v_recovered timestamptz;
begin
    perform public.pintheory_osm_greens_import('test-only/green-staging', v_first,
        '[{"type":"way","id":991001,"minLat":10,"minLon":30,"maxLat":10.001,"maxLon":30.001,"ring":[[10,30],[10,30.001],[10.001,30.001],[10,30]]}]'::jsonb);
    perform public.pintheory_osm_greens_finish('test-only/green-staging', v_first, 1, 0, 0, 20, 40);

    perform public.pintheory_osm_greens_import('test-only/green-staging', v_second,
        '[{"type":"way","id":991002,"minLat":10,"minLon":30,"maxLat":10.001,"maxLon":30.001,"ring":[[10,30],[10,30.001],[10.001,30.001],[10,30]]}]'::jsonb);
    v_rows := public.pintheory_osm_greens(v_user, 9.99, 29.99, 10.01, 30.01)->'greens';
    assert pg_catalog.jsonb_array_length(v_rows) = 1, 'staged rows leaked before activation';

    perform public.pintheory_osm_greens_finish('test-only/green-staging', v_second, 1, 0, 0, 20, 40);
    v_rows := public.pintheory_osm_greens(v_user, 9.99, 29.99, 10.01, 30.01)->'greens';
    assert pg_catalog.jsonb_array_length(v_rows) = 1, 'new generation did not replace the old one';
    perform public.pintheory_osm_greens_cleanup('test-only/green-staging', 10000);
    v_rows := public.pintheory_osm_greens(v_user, 9.99, 29.99, 10.01, 30.01)->'greens';
    assert pg_catalog.jsonb_array_length(v_rows) = 1, 'cleanup removed the active generation';

    insert into pintheory_data.osm_greens(osm_type, osm_id, region, min_lat, min_lon, max_lat, max_lon, ring, imported_at)
        values ('way', 991010, 'test-only/legacy-recovery-final', 0, 120, 0.001, 120.001,
            '[[0,120],[0,120.001],[0.001,120.001],[0,120]]'::jsonb, '2026-11-05 10:00:00+00'),
           ('way', 991011, 'test-only/legacy-recovery-final', 10, 130, 10.001, 130.001,
            '[[10,130],[10,130.001],[10.001,130.001],[10,130]]'::jsonb, '2026-11-06 10:00:00+00');
    insert into pintheory_data.osm_green_regions(region, min_lat, min_lon, max_lat, max_lon, greens, imported_at)
        values ('test-only/legacy-recovery-final', -20, 100, 20, 150, 1, '2026-11-05 10:00:00+00');
        v_recovered := public.pintheory_osm_greens_recover('test-only/legacy-recovery-final', -20, 100, 20, 150);
    assert v_recovered = '2026-11-06 10:00:00+00'::timestamptz, 'recovery selected the wrong legacy run';
    v_rows := public.pintheory_osm_greens(v_user, 9.99, 129.99, 10.01, 130.01)->'greens';
    assert pg_catalog.jsonb_array_length(v_rows) = 1, 'recovered legacy generation is not visible';
end;
$$;
rollback;
