-- DISPOSABLE LOCAL/STAGING ONLY after 202610300002_catalog_search.sql.
-- Synthetic rows only; no provider/network, real directory, secrets or production.
-- Run as postgres with stop-on-error. Fixtures and rate counters roll back.
begin;
set local plpgsql.check_asserts = on;
select pg_catalog.set_config('request.jwt.claim.role','service_role',true);
select pg_catalog.set_config('request.jwt.claims','{"role":"service_role"}',true);

insert into auth.users(id,email,is_anonymous,deleted_at,banned_until)
values ('26000002-0000-4000-8000-000000000001','catalog-search@example.invalid',false,null,null);

insert into pintheory_catalog.imports(import_id,source_sha256,dataset_version,
    expected_clubs,expected_courses,expected_chunks,status,completed_at)
values (pg_catalog.repeat('1',64),pg_catalog.repeat('2',64),'catalog-test-v1',2,3,1,'complete',now());
insert into pintheory_catalog.chunks(import_id,chunk_no,chunk_sha256,clubs,club_count,course_count)
values (pg_catalog.repeat('1',64),1,pg_catalog.repeat('3',64),
    '[{"clubID":"fixture-1","clubName":"Åre Links Club","country":"Sweden","state":"Jämtland","courses":[{"courseID":"course-1","courseName":"North Course","numHoles":18,"hasGPS":1},{"courseID":"course-2","courseName":"South Course","numHoles":9,"hasGPS":0}]},{"clubID":"fixture-2","clubName":"Lakeside Club","country":"Sweden","state":"Skåne","courses":[{"courseID":"course-3","courseName":"Åre Lakeside","numHoles":18,"hasGPS":1}]}]'::jsonb,2,3);
insert into pintheory_catalog.active_import(singleton,import_id) values(true,pg_catalog.repeat('1',64));

do $$
declare
    uid constant uuid := '26000002-0000-4000-8000-000000000001';
    result jsonb;
begin
    assert pg_catalog.has_function_privilege('service_role',
        'public.pintheory_catalog_search(uuid,text,text,text,integer,integer)','EXECUTE');
    assert not pg_catalog.has_function_privilege('anon',
        'public.pintheory_catalog_search(uuid,text,text,text,integer,integer)','EXECUTE');
    assert not pg_catalog.has_function_privilege('authenticated',
        'public.pintheory_catalog_search(uuid,text,text,text,integer,integer)','EXECUTE');
    assert not pg_catalog.has_schema_privilege('authenticated','pintheory_catalog','USAGE');
    assert not pg_catalog.has_table_privilege('authenticated','pintheory_catalog.chunks','SELECT');

    result := public.pintheory_catalog_search(uid,'Åre','Sweden','',1,1);
    assert result->>'datasetVersion'='catalog-test-v1';
    assert result->>'numAllClubs'='2';
    assert result->>'numClubs'='1';
    assert result->>'hasMore'='true';
    assert result#>>'{clubs,0,clubID}'='fixture-1';
    assert pg_catalog.jsonb_array_length(result#>'{clubs,0,courses}')=2,
        'course-name match returns all summaries for its matching club';

    result := public.pintheory_catalog_search(uid,'','Sweden','Skåne',1,50);
    assert result->>'numAllClubs'='1' and result#>>'{clubs,0,clubID}'='fixture-2';
    result := public.pintheory_catalog_search(uid,'North','Sweden','Jämtland',1,50);
    assert result->>'numAllClubs'='1' and result#>>'{clubs,0,clubID}'='fixture-1';
    result := public.pintheory_catalog_search(uid,'not-found','Sweden','',1,50);
    assert result->>'numAllClubs'='0' and result->>'numClubs'='0';
    result := public.pintheory_catalog_search(uid,pg_catalog.repeat('🏌',200),'Sweden','',1,50);
    assert result->>'numAllClubs'='0', '200 four-byte characters are accepted';
    begin
        perform public.pintheory_catalog_search(uid,pg_catalog.repeat('🏌',201),'Sweden','',1,50);
        raise exception 'query over 200 Unicode characters was accepted';
    exception when sqlstate '22023' then
        assert sqlerrm='invalid_catalog_search';
    end;
    begin
        perform public.pintheory_catalog_search(uid,'','','',1,50);
        raise exception 'empty unbounded query was accepted';
    exception when sqlstate '22023' then
        assert sqlerrm='invalid_catalog_search';
    end;
end;
$$;

select pg_catalog.set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ begin
    begin
        perform public.pintheory_catalog_search('26000002-0000-4000-8000-000000000001','','Sweden','',1,50);
        raise exception 'anon search RPC was executable';
    exception when insufficient_privilege then null; end;
end; $$;
reset role;
rollback;
