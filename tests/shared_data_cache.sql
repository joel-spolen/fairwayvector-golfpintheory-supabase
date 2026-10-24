-- DISPOSABLE LOCAL/STAGING ONLY, postgres, after 202610240002_shared_data_cache.
-- Run with psql -X -v ON_ERROR_STOP=1. Fixtures, role changes and counters roll back.
-- Locks/TRUNCATE intentionally isolate these tests: NEVER run on production.
-- Simulated JWT claims test SQL guards, not actual gateway/JWT verification.
begin;
set local plpgsql.check_asserts = on;
set local timezone = 'UTC';
lock table auth.users, pintheory_sync.accounts in share row exclusive mode;
truncate pintheory_data.elevation_courses, pintheory_data.responses, pintheory_data.jobs,
    pintheory_data.usage, pintheory_data.traffic, pintheory_data.per_user_usage;
update pintheory_data.settings set enabled = false, daily_limit = 100, cooldown_until = null;
update pintheory_data.meta set resolutions = 0, last_resolved_at = null, retention_day = null;
select pg_catalog.set_config('request.jwt.claim.role','',true);
select pg_catalog.set_config('request.jwt.claims','{"role":"service_role"}',true);

-- Catalog ACL/RLS tests include service_role (BYPASSRLS is NOT direct access).
do $$ declare r record; api_role text;
begin
    assert (select pg_catalog.count(*) = 8 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='pintheory_data' and c.relkind='r');
    for r in select c.* from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='pintheory_data' and c.relkind='r' loop
        assert r.relrowsecurity and pg_catalog.pg_get_userbyid(r.relowner)='postgres';
        assert not exists (select 1 from pg_catalog.pg_policy where polrelid=r.oid);
        foreach api_role in array array['anon','authenticated','service_role'] loop
            assert not pg_catalog.has_table_privilege(api_role,r.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
        end loop;
    end loop;
    foreach api_role in array array['anon','authenticated','service_role'] loop
        assert not pg_catalog.has_schema_privilege(api_role,'pintheory_data','USAGE,CREATE');
    end loop;
    for r in select p.*,n.nspname from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
        where n.nspname='pintheory_data' or (n.nspname='public' and p.proname like 'pintheory_data_%') loop
        assert r.prosecdef and pg_catalog.pg_get_userbyid(r.proowner)='postgres';
        assert r.proconfig @> array['search_path=pg_catalog'];
        assert not exists (select 1 from pg_catalog.aclexplode(r.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE');
        foreach api_role in array array['anon','authenticated','service_role'] loop
            assert pg_catalog.has_function_privilege(api_role,r.oid,'EXECUTE') =
                (api_role='service_role' and r.nspname='public');
        end loop;
    end loop;
    assert (select pg_catalog.count(*)=7 from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname like 'pintheory_data_%');
end $$;

-- ACL denial with spoofed service claims; guards with actual service SQL role
-- but missing/wrong Auth role. Every public RPC must enforce both boundaries.
create function pg_temp.check_denied()
returns void language plpgsql as $$
declare expression text;
begin
    foreach expression in array array[
        'public.pintheory_data_claim(null,''golf:v1:detail:A'',''golf'',true)',
        'public.pintheory_data_finish(''golf:v1:detail:A'',null,''{}'')',
        'public.pintheory_data_fail(''golf:v1:detail:A'',null)',
        'public.pintheory_data_tag(''missing'',''A'')',
        'public.pintheory_data_admin_assign(''missing'',''A'')',
        'public.pintheory_data_admin_resolve(''missing'',''ALLOW_PAID_RETRY'')',
        'public.pintheory_data_admin_overview()'
    ] loop
        begin
            execute 'select ' || expression;
            raise exception 'access unexpectedly allowed: %',expression;
        exception when insufficient_privilege then null; end;
    end loop;
end $$;
set local role anon;
select pg_temp.check_denied();
reset role;
set local role authenticated;
select pg_temp.check_denied();
reset role;
select pg_catalog.set_config('request.jwt.claims','{}',true);
set local role service_role;
select pg_temp.check_denied();
select pg_catalog.set_config('request.jwt.claims','{"role":"authenticated"}',true);
select pg_temp.check_denied();
select pg_catalog.set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ begin
    assert public.pintheory_data_admin_overview()->'courseOptions' = '[]'::jsonb;
    begin
        perform 1 from pintheory_data.responses;
        raise exception 'direct private access permitted';
    exception when insufficient_privilege then null; end;
end $$;
reset role;

-- Empty snapshot exact top-level shape, numeric totals, zero-filled trends.
do $$ declare m jsonb := public.pintheory_data_admin_overview();
begin
    assert (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(m) k(key)) =
        array['courseOptions','courses','daily','generatedAt','inventory','period','providers','trackingStartedAt','traffic','unassigned'];
    assert m->'traffic' = '{"requests":0,"completed":0,"cacheHits":0,"fetched":0,"coalesced":0,"errors":0,"upstreamCalls":0,"cacheHitRate":null}'::jsonb;
    assert m->'inventory' = '{"courseCount":0,"elevationProfiles":0,"elevationSamples":0,"elevationBytes":0,"elevationLengthMeters":0,"lengthEstimated":false,"unassignedProfiles":0}'::jsonb;
    assert m->'courses' = '{"items":[],"total":0,"page":1,"pageSize":25}'::jsonb;
    assert m->'unassigned' = '{"items":[],"total":0}'::jsonb;
    assert pg_catalog.jsonb_array_length(m->'daily')=7;
    assert m#>>'{daily,6,day}' = (pg_catalog.clock_timestamp() at time zone 'UTC')::date::text;
    assert m#>'{providers,0,enabled}'='false'::jsonb and m#>'{providers,1,dailyLimit}'='100'::jsonb;
    assert m->>'generatedAt' ~ 'Z$' and m->>'trackingStartedAt' ~ 'Z$';
    assert public.pintheory_data_admin_overview(0)->'period'='{"days":0,"label":"All time"}'::jsonb;
    assert pg_catalog.jsonb_array_length(public.pintheory_data_admin_overview(0)->'daily')=30;
    assert pg_catalog.jsonb_array_length(public.pintheory_data_admin_overview(400)->'daily')=366;
    assert public.pintheory_data_admin_overview(-1,null,-1)->'period'=m->'period';
end $$;

insert into auth.users(id,email,is_anonymous,deleted_at,banned_until) values
    ('24000002-0000-4000-8000-000000000001','cache-active@example.invalid',false,null,null),
    ('24000002-0000-4000-8000-000000000002',null,true,null,null),
    ('24000002-0000-4000-8000-000000000003','cache-deleted@example.invalid',false,now(),null),
    ('24000002-0000-4000-8000-000000000004','cache-banned@example.invalid',false,null,now()+interval '1 day'),
    ('24000002-0000-4000-8000-000000000005','cache-blocked@example.invalid',false,null,null),
    ('24000002-0000-4000-8000-000000000006','cache-deleting@example.invalid',false,null,null),
    ('24000002-0000-4000-8000-000000000007','cache-past-ban@example.invalid',false,null,now()-interval '1 day');
insert into pintheory_sync.accounts(user_id,state) values
    ('24000002-0000-4000-8000-000000000005','blocked'),
    ('24000002-0000-4000-8000-000000000006','deleting');

do $$ declare uid uuid := '24000002-0000-4000-8000-000000000001'; c jsonb; token uuid; n bigint;
begin
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',false)->>'status'='DISABLED';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true)->>'status'='CACHE_MISS';
    assert not exists (select 1 from pintheory_data.usage);
    assert not exists (select 1 from pintheory_data.jobs);
    update pintheory_data.settings set enabled=true;
    c := public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',false);
    assert c->>'status'='CLAIMED'; token := (c->>'token')::uuid;
    assert (select state='dispatched' and until>clock_timestamp()+interval '59 seconds'
        from pintheory_data.jobs where key='golf:v1:detail:A');
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',false)->>'status'='PENDING';
    assert (select attempts=1 from pintheory_data.usage where provider='golf');
    assert (select attempts=1 from pintheory_data.per_user_usage where user_id=uid);
    assert (select received=4 and coalesced=1 and errors=2 and hits=0 from pintheory_data.traffic where provider='golf');
    assert not public.pintheory_data_finish('golf:v1:detail:A',gen_random_uuid(),'{"courseID":"A"}');
    assert not public.pintheory_data_finish('golf:v1:detail:A',token,'[]');
    assert not public.pintheory_data_finish('golf:v1:detail:A',token,'{"courseID":"B"}');
    assert not public.pintheory_data_finish('golf:v1:detail:A',token,'{"courseID":"A"}',null,'{"user_id":"private"}');
    assert not public.pintheory_data_finish('golf:v1:detail:A',token,
        jsonb_build_object('courseID','A','large',repeat('x',4194304)));
    assert public.pintheory_data_finish('golf:v1:detail:A',token,
        '{"courseID":"A","courseName":"Å Links","clubName":"Club A","country":"SE","numHoles":"18","exact":1.1234567890123456789,"privateFixture":"not-in-overview"}', 'v1');
    assert not public.pintheory_data_finish('golf:v1:detail:A',token,'{"courseID":"A"}');
    assert not public.pintheory_data_fail('golf:v1:detail:A',token);
    c := public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true);
    assert c->>'status'='HIT' and c->>'datasetVersion'='v1' and c->>'fetchedAt' ~ 'Z$';
    assert c#>'{body,exact}'='1.1234567890123456789'::jsonb;
    assert c->'body'=(select body from pintheory_data.responses where key='golf:v1:detail:A');
    -- Gate all disallowed identities BEFORE hits and never retain their telemetry.
    for n in 2..6 loop
        assert public.pintheory_data_claim(('24000002-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
            'golf:v1:detail:A','golf',true)->>'status'='FORBIDDEN';
    end loop;
    assert public.pintheory_data_claim(null,'golf:v1:detail:A','golf',true)->>'status'='FORBIDDEN';
    assert public.pintheory_data_claim('24000002-0000-4000-8000-000000000099','golf:v1:detail:A','golf',true)->>'status'='FORBIDDEN';
    assert public.pintheory_data_claim('24000002-0000-4000-8000-000000000007','golf:v1:detail:A','golf',true)->>'status'='HIT';
    assert (select count(*)=2 from pintheory_data.per_user_usage);
    -- All cache hits work while disabled, over budget, or provider cooling down.
    update pintheory_data.settings set enabled=false,daily_limit=0,cooldown_until=clock_timestamp()+interval '1 day';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',false,0)->>'status'='HIT';
    update pintheory_data.settings set enabled=true;
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true,0)->>'status'='HIT';
    update pintheory_data.settings set daily_limit=100,cooldown_until=null;
    update pintheory_data.responses set fetched_at=clock_timestamp()-interval '2 days' where key='golf:v1:detail:A';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',false,86400)->>'status'='CLAIMED';
    -- A cache-only caller may still read the original stale value during refresh.
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true,86400)->>'status'='HIT';
    select j.token into token from pintheory_data.jobs j where key='golf:v1:detail:A';
    assert public.pintheory_data_fail('golf:v1:detail:A',token,false,1);
    assert (select cooldown_until is null from pintheory_data.settings where provider='golf');
end $$;

-- Expired dispatched remains UNKNOWN, late same-token finish is allowed unless
-- explicitly resolved, and old tokens cannot complete/fail a successor.
do $$ declare uid uuid := '24000002-0000-4000-8000-000000000001'; a uuid; b uuid; c jsonb; n bigint;
begin
    c:=public.pintheory_data_claim(uid,'golf:v1:detail:late','golf',false); a:=(c->>'token')::uuid;
    assert c->>'status'='CLAIMED';
    assert not public.pintheory_data_admin_resolve('golf:v1:detail:late','ALLOW_PAID_RETRY');
    update pintheory_data.jobs set until=clock_timestamp()-interval '1 day' where key='golf:v1:detail:late';
    select attempts into n from pintheory_data.usage where provider='golf';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:late','golf',false)->>'status'='UNKNOWN';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:late','golf',false)->>'status'='UNKNOWN';
    assert (select attempts=n from pintheory_data.usage where provider='golf');
    assert public.pintheory_data_finish('golf:v1:detail:late',a,'{"courseID":"late"}');
    c:=public.pintheory_data_claim(uid,'golf:v1:detail:resolve','golf',false); a:=(c->>'token')::uuid;
    update pintheory_data.jobs set until=clock_timestamp()-interval '1 day' where key='golf:v1:detail:resolve';
    assert not public.pintheory_data_admin_resolve('golf:v1:detail:resolve','yes');
    assert public.pintheory_data_admin_resolve('golf:v1:detail:resolve','ALLOW_PAID_RETRY');
    assert not public.pintheory_data_admin_resolve('golf:v1:detail:resolve','ALLOW_PAID_RETRY');
    assert not public.pintheory_data_finish('golf:v1:detail:resolve',a,'{"courseID":"resolve"}');
    c:=public.pintheory_data_claim(uid,'golf:v1:detail:resolve','golf',false); b:=(c->>'token')::uuid;
    assert c->>'status'='CLAIMED' and a<>b;
    assert not public.pintheory_data_finish('golf:v1:detail:resolve',a,'{"courseID":"resolve"}');
    assert not public.pintheory_data_fail('golf:v1:detail:resolve',a);
    assert public.pintheory_data_fail('golf:v1:detail:resolve',b,false,0);
    assert (select until between clock_timestamp() and clock_timestamp()+interval '2 seconds'
        from pintheory_data.jobs where key='golf:v1:detail:resolve');
    assert public.pintheory_data_claim(uid,'golf:v1:detail:resolve','golf',false)->>'status'='COOLDOWN';
    update pintheory_data.jobs set until=clock_timestamp()-interval '1 second' where key='golf:v1:detail:resolve';
    c:=public.pintheory_data_claim(uid,'golf:v1:detail:resolve','golf',false); b:=(c->>'token')::uuid;
    assert c->>'status'='CLAIMED';
    assert public.pintheory_data_fail('golf:v1:detail:resolve',b,true,2147483647);
    assert (select cooldown_until between clock_timestamp()+interval '86398 seconds' and clock_timestamp()+interval '86401 seconds'
        from pintheory_data.settings where provider='golf');
    assert public.pintheory_data_claim(uid,'golf:v1:detail:wide','golf',false)->>'status'='COOLDOWN';
    assert (select resolutions=1 and last_resolved_at is not null from pintheory_data.meta);
    update pintheory_data.settings set cooldown_until=null;
end $$;

-- Global concurrency across providers, paid per-user/day and provider/day caps.
do $$ declare uid uuid := '24000002-0000-4000-8000-000000000001'; c jsonb; i integer; n bigint;
begin
    for i in 1..4 loop
        c:=public.pintheory_data_claim(uid,'golf:v1:detail:cap' || i,'golf',false);
        assert c->>'status'='CLAIMED';
    end loop;
    select sum(attempts) into n from pintheory_data.usage;
    assert public.pintheory_data_claim(uid,'gpxz:sample:v1:' || repeat('a',64),'gpxz',false)->>'status'='RATE_LIMIT';
    assert (select sum(attempts)=n from pintheory_data.usage);
    -- Expired ambiguity stops occupying active slots, but never grants retry.
    update pintheory_data.jobs set until=clock_timestamp()-interval '1 second' where state='dispatched';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:cap1','golf',false)->>'status'='UNKNOWN';
    update pintheory_data.settings set daily_limit=0 where provider='gpxz';
    assert public.pintheory_data_claim(uid,'gpxz:sample:v1:' || repeat('a',64),'gpxz',false)->>'status'='BUDGET';
    update pintheory_data.settings set daily_limit=100;
    update pintheory_data.per_user_usage set attempts=100 where user_id=uid;
    assert public.pintheory_data_claim(uid,'golf:v1:detail:usercap','golf',false)->>'status'='RATE_LIMIT';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true)->>'status'='HIT';
    update pintheory_data.per_user_usage set requests=10000 where user_id=uid;
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','golf',true)->>'status'='RATE_LIMIT';
    update pintheory_data.per_user_usage set requests=0,attempts=0 where user_id=uid;
    -- Key/provider mismatch, null flag, invalid max age never dispatch.
    select sum(attempts) into n from pintheory_data.usage;
    assert public.pintheory_data_claim(uid,'golf:v1:detail:A','gpxz',false)->>'status'='CACHE_MISS';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:invalid','golf',null)->>'status'='CACHE_MISS';
    assert public.pintheory_data_claim(uid,'golf:v1:detail:invalid','golf',false,-1)->>'status'='CACHE_MISS';
    assert (select sum(attempts)=n from pintheory_data.usage);
end $$;

-- Elevation linking, metadata allowlist, unassigned endpoints, course inventory
-- enrichment (search-only IDs never become inventory), exact aggregate counts.
do $$ declare uid uuid := '24000002-0000-4000-8000-000000000001'; c jsonb; a uuid; m jsonb;
    k text := 'gpxz:sample:v1:' || repeat('b',64);
    k2 text := 'gpxz:sample:v1:' || repeat('c',64);
    body jsonb := '{"status":"OK","results":[{"lat":57.123456789012345,"lon":12,"elevation":100},{"lat":57.2,"lon":12.1,"elevation":102}],"privateFixture":"not-in-overview"}';
begin
    c:=public.pintheory_data_claim(uid,k,'gpxz',false); a:=(c->>'token')::uuid;
    assert c->>'status'='CLAIMED';
    assert not public.pintheory_data_finish(k,a,body,null,'{"profileLengthMeters":-1}');
    assert not public.pintheory_data_finish(k,a,body,null,'{"profileLengthMeters":"3"}');
    assert not public.pintheory_data_finish(k,a,body,null,'{"courseID":"bad:id"}');
    assert not public.pintheory_data_finish(k,a,body,null,'{"courseID":null}');
    assert not public.pintheory_data_finish(k,a,body,null,'{"userID":"sensitive"}');
    assert not public.pintheory_data_finish(k,a,'{"results":{}}');
    assert public.pintheory_data_finish(k,a,body,'dataset','{"profileLengthMeters":123.45,"courseID":"tagged"}');
    assert public.pintheory_data_tag(k,'tagged');
    assert not public.pintheory_data_tag('golf:v1:detail:A','tagged');
    assert not public.pintheory_data_tag(k,'bad:id');
    assert not public.pintheory_data_tag('missing','A');
    c:=public.pintheory_data_claim(uid,k2,'gpxz',false); a:=(c->>'token')::uuid;
    assert public.pintheory_data_finish(k2,a,body);
    m:=public.pintheory_data_admin_overview();
    assert m#>'{inventory,elevationProfiles}'='2'::jsonb;
    assert m#>'{inventory,elevationSamples}'='4'::jsonb;
    assert (m#>>'{inventory,elevationBytes}')::bigint=2*octet_length(convert_to(body::text,'UTF8'));
    assert m#>'{inventory,elevationLengthMeters}'='123.45'::jsonb;
    assert m#>'{inventory,lengthEstimated}'='true'::jsonb;
    assert m#>'{inventory,unassignedProfiles}'='1'::jsonb;
    assert m#>'{unassigned,items,0,start}'='{"lat":57.123456789012345,"lon":12}'::jsonb;
    assert m#>'{unassigned,items,0,end}'='{"lat":57.2,"lon":12.1}'::jsonb;
    assert not public.pintheory_data_admin_assign(k2,'unknown');
    assert public.pintheory_data_admin_assign(k2,'tagged');
    assert public.pintheory_data_admin_assign(k,'A');
    assert public.pintheory_data_admin_assign(k,'A');
    c:=public.pintheory_data_claim(uid,'golf:v1:coordinates:B','golf',false); a:=(c->>'token')::uuid;
    assert public.pintheory_data_finish('golf:v1:coordinates:B',a,'{"courseID":"B","coordinates":[{}]}');
    c:=public.pintheory_data_claim(uid,'golf:v1:courses:' || repeat('d',64),'golf',false); a:=(c->>'token')::uuid;
    assert public.pintheory_data_finish('golf:v1:courses:' || repeat('d',64),a,
        '{"courses":[{"courseID":"B","courseName":"Bee","clubName":"100%_ Club","country":"NO"},{"courseID":"search-only","courseName":"Not inventory"}]}');
    assert not public.pintheory_data_admin_assign(k,'search-only');
    m:=public.pintheory_data_admin_overview(7,'100%_');
    assert m#>'{courses,total}'='1'::jsonb;
    assert m#>>'{courses,items,0,id}'='B' and m#>>'{courses,items,0,name}'='Bee';
    assert m#>'{courses,items,0,hasCoordinates}'='true'::jsonb;
    assert public.pintheory_data_admin_assign(k,'B');
    m:=public.pintheory_data_admin_overview(7,' a ');
    assert m#>'{inventory,elevationProfiles}'='2'::jsonb;
    assert m#>'{inventory,unassignedProfiles}'='0'::jsonb;
    assert m::text not like '%not-in-overview%';
    assert m::text not like '%' || uid::text || '%';
    assert m::text not like '%elevation": 100%';
    assert (select count(*)=4 from pintheory_data.elevation_courses);
    assert public.pintheory_data_admin_overview(1)->'period'='{"days":1,"label":"Today"}'::jsonb;
    m:=public.pintheory_data_admin_overview();
    assert (m#>>'{traffic,requests}')::bigint=(select sum(received) from pintheory_data.traffic);
    assert (m#>>'{traffic,completed}')::bigint=(select sum(hits+fetched+errors) from pintheory_data.traffic);
    assert (m#>>'{traffic,upstreamCalls}')::bigint=(select sum(attempts) from pintheory_data.usage);
    assert (m#>>'{traffic,coalesced}')::bigint=(select sum(coalesced) from pintheory_data.traffic);
end $$;

-- Bounded pages/options/unassigned; inventory stays global under search.
insert into pintheory_data.responses(key,provider,body,fetched_at)
select 'golf:v1:detail:page' || lpad(n::text,4,'0'),'golf',
    jsonb_build_object('courseID','page' || lpad(n::text,4,'0'),'courseName','Page ' || lpad(n::text,4,'0')),clock_timestamp()
from generate_series(1,1005) n;
insert into pintheory_data.responses(key,provider,body,fetched_at)
select 'gpxz:sample:v1:' || lpad(to_hex(n),64,'0'),'gpxz',
    '{"results":[{"lat":0,"lon":0},{"lat":1,"lon":1}]}',clock_timestamp()+n*interval '1 second'
from generate_series(1,55) n;
do $$ declare m jsonb:=public.pintheory_data_admin_overview(7,'Page',2);
begin
    assert m#>'{courses,total}'='1005'::jsonb and m#>'{courses,page}'='2'::jsonb;
    assert pg_catalog.jsonb_array_length(m#>'{courses,items}')=25;
    assert m#>>'{courses,items,0,id}'='page0026';
    assert pg_catalog.jsonb_array_length(m->'courseOptions')=1000;
    assert pg_catalog.jsonb_array_length(m#>'{unassigned,items}')=50;
    assert m#>'{unassigned,total}'='55'::jsonb;
    assert m#>>'{unassigned,items,0,key}'='gpxz:sample:v1:' || lpad(to_hex(55),64,'0');
    assert public.pintheory_data_admin_overview(7,'no-match')#>'{courses,total}'='0'::jsonb;
    assert public.pintheory_data_admin_overview(7,'no-match')->'inventory'=m->'inventory';
    assert public.pintheory_data_admin_overview(7,'Page',100)#>'{courses,items}'='[]'::jsonb;
end $$;

-- Per-user telemetry is automatically swept on service activity; Auth deletion
-- cascades without removing shared data. Historical aggregates are not reset.
insert into pintheory_data.per_user_usage(user_id,day,requests) values
    ('24000002-0000-4000-8000-000000000001',(clock_timestamp() at time zone 'UTC')::date-30,10),
    ('24000002-0000-4000-8000-000000000001',(clock_timestamp() at time zone 'UTC')::date-29,10);
update pintheory_data.meta set retention_day=null;
select public.pintheory_data_admin_overview(1,'no-match',1) is not null;
do $$ declare n bigint; v_attempts bigint;
begin
    assert not exists (select 1 from pintheory_data.per_user_usage where day<(clock_timestamp() at time zone 'UTC')::date-29);
    assert exists (select 1 from pintheory_data.per_user_usage where day=(clock_timestamp() at time zone 'UTC')::date-29);
    select count(*) into n from pintheory_data.responses;
    select sum(u.attempts) into v_attempts from pintheory_data.usage u;
    delete from auth.users where id='24000002-0000-4000-8000-000000000001';
    assert not exists (select 1 from pintheory_data.per_user_usage where user_id='24000002-0000-4000-8000-000000000001');
    assert (select count(*)=n from pintheory_data.responses);
    assert (select sum(u.attempts)=v_attempts from pintheory_data.usage u);
    assert public.pintheory_data_claim('24000002-0000-4000-8000-000000000001','golf:v1:detail:A','golf',true)->>'status'='FORBIDDEN';
end $$;
rollback;

-- Independent-session concurrency test (NOT represented by sequential DO calls):
-- On a fresh disposable DB, create/commit an active auth.users fixture and enable
-- golf as postgres. Session A: BEGIN; set service JWT claims; call claim for key X;
-- leave transaction open. Session B: BEGIN; same service claims; claim X must block.
-- Commit A => B returns PENDING, with exactly one job/token/usage attempt. Rollback
-- A instead => B returns CLAIMED. Repeat with distinct keys and daily_limit=1:
-- B returns BUDGET after A commits. Repeat with 3 active jobs and two distinct
-- keys: fourth CLAIMED, fifth RATE_LIMIT. At REPEATABLE READ/SERIALIZABLE retry
-- serialization errors; never dispatch HTTP until a CLAIMED transaction commits.