-- DISPOSABLE LOCAL/STAGING ONLY after 202610300001_private_club_catalog_import.sql.
-- Synthetic records only; no provider/network, real directory, secrets or production.
-- Run as postgres with stop-on-error. All fixtures and active pointer roll back.
begin;
set local plpgsql.check_asserts = on;
select pg_catalog.set_config('request.jwt.claim.role','service_role',true);
select pg_catalog.set_config('request.jwt.claims','{"role":"service_role"}',true);

do $$
declare
    v_import_id constant text := pg_catalog.repeat('b',64);
    source_hash constant text := pg_catalog.repeat('a',64);
    chunk_hash constant text := pg_catalog.repeat('c',64);
    result jsonb;
begin
    assert not pg_catalog.has_schema_privilege('anon','pintheory_catalog','USAGE');
    assert not pg_catalog.has_schema_privilege('authenticated','pintheory_catalog','USAGE');
    assert not pg_catalog.has_schema_privilege('service_role','pintheory_catalog','USAGE');
    assert not pg_catalog.has_table_privilege('service_role','pintheory_catalog.chunks','SELECT,INSERT,UPDATE,DELETE');
    assert pg_catalog.has_function_privilege('service_role',
        'public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer)','EXECUTE');
    assert not pg_catalog.has_function_privilege('anon',
        'public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer)','EXECUTE');
    assert not pg_catalog.has_function_privilege('authenticated',
        'public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer)','EXECUTE');

    result := public.pintheory_catalog_import_begin(v_import_id,source_hash,'fixture-v1',2,2,2);
    assert result->>'status'='staging';
    result := public.pintheory_catalog_import_chunk(v_import_id,1,chunk_hash,
        '[{"clubID":"club-1","clubName":"Fixture One","country":"Sweden","courses":[{"courseID":"course-1","courseName":"First"}]}]'::jsonb,1);
    assert result->>'status'='received';
    result := public.pintheory_catalog_import_chunk(v_import_id,1,chunk_hash,
        '[{"clubID":"club-1","clubName":"Fixture One","country":"Sweden","courses":[{"courseID":"course-1","courseName":"First"}]}]'::jsonb,1);
    assert result->>'status'='already_received';
    begin
        perform public.pintheory_catalog_import_chunk(v_import_id,1,pg_catalog.repeat('d',64),
            '[{"clubID":"club-X","clubName":"Conflict","courses":[]}]'::jsonb,0);
        raise exception 'conflicting replay unexpectedly accepted';
    exception when sqlstate '22023' then
        assert sqlerrm='catalog_chunk_replay_conflict';
    end;
    begin
        perform public.pintheory_catalog_import_finalize(v_import_id);
        raise exception 'incomplete import unexpectedly finalized';
    exception when sqlstate '22023' then
        assert sqlerrm='catalog_import_incomplete';
    end;
    assert not exists(select 1 from pintheory_catalog.active_import where singleton);

    perform public.pintheory_catalog_import_chunk(v_import_id,2,pg_catalog.repeat('e',64),
        '[{"clubID":"club-2","clubName":"Fixture Two","country":"Sweden","courses":[{"courseID":"course-2","courseName":"Second"}]}]'::jsonb,1);
    result := public.pintheory_catalog_import_finalize(v_import_id);
    assert result='{"status":"complete","clubs":2,"courses":2,"chunks":2,"privateOnly":true}'::jsonb;
    assert (select active_import.import_id=v_import_id from pintheory_catalog.active_import);
    result := public.pintheory_catalog_import_chunk(v_import_id,1,chunk_hash,
        '[{"clubID":"club-1","clubName":"Fixture One","country":"Sweden","courses":[{"courseID":"course-1","courseName":"First"}]}]'::jsonb,1);
    assert result->>'status'='already_received';
    assert public.pintheory_catalog_import_finalize(v_import_id)->>'status'='complete';
end;
$$;

-- ACL denies even if a caller can spoof claim GUCs.
select pg_catalog.set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ begin
    begin
        perform public.pintheory_catalog_import_begin(pg_catalog.repeat('f',64),pg_catalog.repeat('f',64),'x',1,0,1);
        raise exception 'anon import RPC was executable';
    exception when insufficient_privilege then null; end;
end; $$;
reset role;
rollback;
