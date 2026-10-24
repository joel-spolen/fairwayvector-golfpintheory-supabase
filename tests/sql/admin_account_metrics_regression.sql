-- NOT EXECUTED. DISPOSABLE STAGING SUPABASE ONLY, as postgres.
-- Requires ALL FOUR migrations through 202610240001_admin_account_metrics.sql.
-- Run manually with stop-on-first-error and PL/pgSQL assertions enabled.
-- No production, secrets, network, extensions, or existing-user changes.
-- Fixtures, temporary helpers, ACL tests and counters all ROLLBACK.
-- SQL role/claim simulation is not verification of real JWT/PostgREST behavior.
begin;
set local plpgsql.check_asserts = on;
set local timezone = 'UTC';

-- Keep baseline/delta expectations deterministic in this disposable test only.
-- These locks block Auth/sync writers; never run this against a live project.
lock table auth.users in share row exclusive mode;
lock table pintheory_sync.accounts, pintheory_sync.records,
    pintheory_sync.change_events, pintheory_sync.mutation_receipts in share row exclusive mode;
select pg_catalog.set_config('request.jwt.claim.role', '', true);
select pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
create temporary table metrics_baseline on commit drop as
select public.pintheory_admin_account_metrics() as metrics;

-- Independently recompute the exact contract from current rows. No assumptions
-- about other staging users or physical file sizes, which may change on rollback.
create function pg_temp.check_admin_metrics()
returns void language plpgsql set search_path = pg_catalog as $$
declare
    m jsonb := public.pintheory_admin_account_metrics();
    k text;
    v jsonb;
    n bigint;
    a bigint;
    r bigint;
    h bigint;
    q bigint;
    mx bigint;
    physical bigint;
begin
    assert (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(m) as x(key))
        = array['activityDefinition','generatedAt','historyComplete','schemaVersion','storage','trackingStartedAt','users'],
        'top-level contract drift / possible identity leakage';
    assert m->'schemaVersion' = '1'::jsonb and m->'historyComplete' = 'false'::jsonb;
    assert m->>'activityDefinition' = 'signed_in_last_30_days';
    assert m->>'generatedAt' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$';
    assert (m->>'generatedAt')::timestamptz = pg_catalog.statement_timestamp();
    assert m->>'trackingStartedAt' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$';
    assert m->>'trackingStartedAt' = (select metrics->>'trackingStartedAt' from pg_temp.metrics_baseline);
    assert (select pg_catalog.array_agg(key order by key)
            from pg_catalog.jsonb_object_keys(m->'users') as x(key))
        = array['active30d','current','knownDeletions','knownRegistrations'];
    assert (select pg_catalog.array_agg(key order by key)
            from pg_catalog.jsonb_object_keys(m->'storage') as x(key))
        = array['averageBytesPerUser','currentUserSyncBytes','databaseBytes','historyBytes',
                'maxBytesPerUser','objectStorageBytes','receiptsBytes','recordsBytes','syncPhysicalBytes'];
    for k, v in select key, value from pg_catalog.jsonb_each(m->'users')
        union all select key, value from pg_catalog.jsonb_each(m->'storage')
        where key <> 'objectStorageBytes'
    loop
        assert pg_catalog.jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^(0|[1-9][0-9]*)$',
            'count/size must be an unsigned decimal JSON string';
        perform (v #>> '{}')::bigint;
    end loop;
    assert m#>'{storage,objectStorageBytes}' = 'null'::jsonb;

    select pg_catalog.count(*), pg_catalog.count(*) filter (
        where last_sign_in_at >= pg_catalog.statement_timestamp() - interval '30 days'
          and last_sign_in_at <= pg_catalog.statement_timestamp())
    into n, a from auth.users where is_anonymous is false and deleted_at is null;
    select coalesce(pg_catalog.sum(pg_catalog.pg_column_size(t.payload)), 0)::bigint into r
    from pintheory_sync.records t join auth.users u on u.id = t.user_id
    where u.is_anonymous is false and u.deleted_at is null;
    select coalesce(pg_catalog.sum(pg_catalog.pg_column_size(t.record)), 0)::bigint into h
    from pintheory_sync.change_events t join auth.users u on u.id = t.user_id
    where u.is_anonymous is false and u.deleted_at is null;
    select coalesce(pg_catalog.sum(pg_catalog.pg_column_size(t.request)::bigint
                                + pg_catalog.pg_column_size(t.response)), 0)::bigint into q
    from pintheory_sync.mutation_receipts t join auth.users u on u.id = t.user_id
    where u.is_anonymous is false and u.deleted_at is null;
    -- Include zero-byte users explicitly in this independent maximum calculation.
    select coalesce(pg_catalog.max(
        coalesce((select pg_catalog.sum(pg_catalog.pg_column_size(t.payload))
            from pintheory_sync.records t where t.user_id = u.id), 0)
        + coalesce((select pg_catalog.sum(pg_catalog.pg_column_size(t.record))
            from pintheory_sync.change_events t where t.user_id = u.id), 0)
        + coalesce((select pg_catalog.sum(pg_catalog.pg_column_size(t.request)::bigint
                                      + pg_catalog.pg_column_size(t.response))
            from pintheory_sync.mutation_receipts t where t.user_id = u.id), 0)
    ), 0)::bigint into mx
    from auth.users u where u.is_anonymous is false and u.deleted_at is null;
    assert (m#>>'{users,current}')::bigint = n and (m#>>'{users,active30d}')::bigint = a;
    assert (m#>>'{users,knownRegistrations}')::bigint =
        (select known_registrations from pintheory_admin.account_counters where singleton);
    assert (m#>>'{users,knownDeletions}')::bigint =
        (select known_deletions from pintheory_admin.account_counters where singleton);
    assert (m#>>'{storage,recordsBytes}')::bigint = r;
    assert (m#>>'{storage,historyBytes}')::bigint = h;
    assert (m#>>'{storage,receiptsBytes}')::bigint = q;
    assert (m#>>'{storage,currentUserSyncBytes}')::bigint = r + h + q;
    assert (m#>>'{storage,maxBytesPerUser}')::bigint = mx;
    assert (m#>>'{storage,averageBytesPerUser}')::bigint =
        case when n = 0 then 0 else pg_catalog.ceil((r::numeric + h + q) / n)::bigint end;
    physical := pg_catalog.pg_total_relation_size('pintheory_sync.accounts'::pg_catalog.regclass)
        + pg_catalog.pg_total_relation_size('pintheory_sync.records'::pg_catalog.regclass)
        + pg_catalog.pg_total_relation_size('pintheory_sync.change_events'::pg_catalog.regclass)
        + pg_catalog.pg_total_relation_size('pintheory_sync.mutation_receipts'::pg_catalog.regclass);
    assert (m#>>'{storage,syncPhysicalBytes}')::bigint = physical;
    -- Whole-database files may change independently, so only validate sane size.
    assert (m#>>'{storage,databaseBytes}')::bigint > 0;
end;
$$;
select pg_temp.check_admin_metrics();

-- Inspect owner/security/ACLs and aggregate-only retained schema.
do $$
declare api_role text; f record;
begin
    for f in select p.* from pg_catalog.pg_proc p
        where p.oid in ('public.pintheory_admin_account_metrics()'::pg_catalog.regprocedure,
                        'pintheory_admin.track_account_event()'::pg_catalog.regprocedure)
    loop
        assert f.prosecdef and pg_catalog.pg_get_userbyid(f.proowner) = 'postgres';
        assert f.proconfig @> array['search_path=pg_catalog'];
        assert not exists (select 1 from pg_catalog.aclexplode(f.proacl) acl
            where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'), 'PUBLIC execute retained';
    end loop;
    assert (select provolatile = 's' from pg_catalog.pg_proc
        where oid = 'public.pintheory_admin_account_metrics()'::pg_catalog.regprocedure);
    foreach api_role in array array['anon','authenticated','service_role'] loop
        assert not pg_catalog.has_schema_privilege(api_role, 'pintheory_admin', 'USAGE');
        assert not pg_catalog.has_schema_privilege(api_role, 'pintheory_admin', 'CREATE');
        assert not pg_catalog.has_table_privilege(api_role, 'pintheory_admin.account_counters',
            'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
        assert not pg_catalog.has_function_privilege(api_role,
            'pintheory_admin.track_account_event()', 'EXECUTE');
        assert pg_catalog.has_function_privilege(api_role,
            'public.pintheory_admin_account_metrics()', 'EXECUTE') = (api_role = 'service_role');
    end loop;
    assert (select pg_catalog.count(*) = 1 from pintheory_admin.account_counters);
    assert (select pg_catalog.array_agg(a.attname::text order by a.attnum)
        from pg_catalog.pg_attribute a
        where a.attrelid = 'pintheory_admin.account_counters'::pg_catalog.regclass
          and a.attnum > 0 and not a.attisdropped)
        = array['singleton','tracking_started_at','known_registrations','known_deletions'],
        'counter retained unexpected identity columns';
    assert (select pg_catalog.count(*) = 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pintheory_admin' and c.relkind in ('r','p','v','m','f')),
        'unexpected retained admin relation';
    begin
        insert into pintheory_admin.account_counters values (false, now(), 0, 0);
        raise exception 'false singleton accepted';
    exception when check_violation then null;
    end;
    begin
        insert into pintheory_admin.account_counters values (true, now(), 0, 0);
        raise exception 'second singleton accepted';
    exception when unique_violation then null;
    end;
end;
$$;

-- ACL denial even with spoofed service claims: API execution grant is required.
set local role anon;
do $$ begin
    begin
        perform public.pintheory_admin_account_metrics();
        raise exception 'anon metrics access allowed';
    exception when insufficient_privilege then null; end;
end; $$;
reset role;
set local role authenticated;
do $$ begin
    begin
        perform public.pintheory_admin_account_metrics();
        raise exception 'authenticated metrics access allowed';
    exception when insufficient_privilege then null; end;
end; $$;
reset role;

-- Guard is independent of ACL/SECURITY DEFINER current_user (postgres).
select pg_catalog.set_config('request.jwt.claims', '{}', true);
do $$ begin
    begin
        perform public.pintheory_admin_account_metrics();
        raise exception 'missing Auth role accepted';
    exception when insufficient_privilege then null; end;
end; $$;
select pg_catalog.set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role service_role;
do $$ begin
    begin
        perform public.pintheory_admin_account_metrics();
        raise exception 'wrong Auth role accepted';
    exception when insufficient_privilege then null; end;
end; $$;
select pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$ begin
    assert public.pintheory_admin_account_metrics()->'schemaVersion' = '1'::jsonb;
    begin
        perform 1 from pintheory_admin.account_counters;
        raise exception 'service role direct counter read allowed';
    exception when insufficient_privilege then null; end;
end; $$;
reset role;

-- Explicit boolean registered/anonymous fixtures. Fixed IDs intentionally fail
-- on collisions; never ON CONFLICT over an existing staging identity.
insert into auth.users(id, email, is_anonymous, last_sign_in_at) values
    ('24000000-0000-4000-8000-000000000001','metrics-recent@example.invalid',false,now()),
    ('24000000-0000-4000-8000-000000000002','metrics-old@example.invalid',false,now()-interval '31 days'),
    ('24000000-0000-4000-8000-000000000003','metrics-future@example.invalid',false,now()+interval '1 day'),
    ('24000000-0000-4000-8000-000000000004','metrics-never@example.invalid',false,null),
    ('24000000-0000-4000-8000-000000000005','metrics-boundary@example.invalid',false,null),
    ('24000000-0000-4000-8000-000000000006',null,true,now()),
    ('24000000-0000-4000-8000-000000000007','metrics-soft@example.invalid',false,null),
    ('24000000-0000-4000-8000-000000000008','metrics-hard@example.invalid',false,null),
    ('24000000-0000-4000-8000-000000000009',null,true,now());
do $$
declare m jsonb; b jsonb := (select metrics from pg_temp.metrics_baseline);
begin
    m := public.pintheory_admin_account_metrics();
    assert (m#>>'{users,knownRegistrations}')::bigint = (b#>>'{users,knownRegistrations}')::bigint + 7;
    assert m#>>'{users,knownDeletions}' = b#>>'{users,knownDeletions}';
    assert (m#>>'{users,current}')::bigint = (b#>>'{users,current}')::bigint + 7;
    -- Set exact boundaries in THIS statement; statement_timestamp is shared by
    -- the helper/RPC calls. Future/null/old are excluded; banned is still included.
    update auth.users set last_sign_in_at = pg_catalog.statement_timestamp() - interval '30 days'
        where id = '24000000-0000-4000-8000-000000000005';
    update auth.users set last_sign_in_at = pg_catalog.statement_timestamp(),
        banned_until = pg_catalog.statement_timestamp() + interval '1 day'
        where id = '24000000-0000-4000-8000-000000000001';
    m := public.pintheory_admin_account_metrics();
    assert (m#>>'{users,active30d}')::bigint = (b#>>'{users,active30d}')::bigint + 2;
    perform pg_temp.check_admin_metrics();
end;
$$;
update auth.users set is_anonymous = false where id = '24000000-0000-4000-8000-000000000006';
-- Repeated unchanged updates must not register twice.
update auth.users set is_anonymous = false, deleted_at = null
    where id = '24000000-0000-4000-8000-000000000006';

-- Real validated RPC writes create records + immutable history + receipts.
-- One current user's tombstone remains chargeable, an anonymous user's data
-- is excluded, and a soon-soft-deleted user's retained data becomes excluded.
do $$
declare uid uuid; result jsonb;
begin
    foreach uid in array array[
        '24000000-0000-4000-8000-000000000001'::uuid,
        '24000000-0000-4000-8000-000000000007'::uuid,
        '24000000-0000-4000-8000-000000000009'::uuid
    ] loop
        perform pg_catalog.set_config('request.jwt.claim.sub', uid::text, true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', uid, 'role', 'authenticated')::text, true);
        result := public.pintheory_sync_mutate(
            '24000000-1000-4000-8000-000000000001', '24000000-2000-4000-8000-000000000001',
            'wedge', '0', 'put', 1,
            '{"name":"56","brand":"","notes":"metrics fixture","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}');
        assert result->>'status' = 'applied';
    end loop;
    perform pg_catalog.set_config('request.jwt.claim.sub', '24000000-0000-4000-8000-000000000001', true);
    perform pg_catalog.set_config('request.jwt.claims',
        '{"sub":"24000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
    result := public.pintheory_sync_mutate(
        '24000000-1000-4000-8000-000000000002', '24000000-2000-4000-8000-000000000001',
        'wedge', '1', 'delete', 1, '{}');
    assert result->>'status' = 'applied' and result#>>'{record,deleted_at}' is not null;
    perform pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
end;
$$;
select pg_temp.check_admin_metrics();

update auth.users set deleted_at = pg_catalog.statement_timestamp()
    where id = '24000000-0000-4000-8000-000000000007';
update auth.users set deleted_at = deleted_at + interval '1 second'
    where id = '24000000-0000-4000-8000-000000000007';
select pg_temp.check_admin_metrics();
do $$
declare m jsonb := public.pintheory_admin_account_metrics(); b jsonb := (select metrics from pg_temp.metrics_baseline);
begin
    assert (m#>>'{users,knownRegistrations}')::bigint = (b#>>'{users,knownRegistrations}')::bigint + 8;
    assert (m#>>'{users,knownDeletions}')::bigint = (b#>>'{users,knownDeletions}')::bigint + 1;
    assert (m#>>'{users,current}')::bigint = (b#>>'{users,current}')::bigint + 7;
    assert exists (select 1 from pintheory_sync.change_events
        where user_id = '24000000-0000-4000-8000-000000000007'), 'soft fixture history missing';
end;
$$;

-- Preserve the existing deletion workflow: deleting state -> service-only purge
-- bridge -> Auth removal. No disabling immutable triggers or direct history DELETE.
insert into pintheory_sync.accounts(user_id, state)
    values ('24000000-0000-4000-8000-000000000008', 'deleting');
update pintheory_sync.accounts set state = 'deleting'
    where user_id in ('24000000-0000-4000-8000-000000000007', '24000000-0000-4000-8000-000000000009');
set local role service_role;
select public.pintheory_purge_account('24000000-0000-4000-8000-000000000007');
select public.pintheory_purge_account('24000000-0000-4000-8000-000000000008');
select public.pintheory_admin_account_metrics();
reset role;
delete from auth.users where id in (
    '24000000-0000-4000-8000-000000000007', '24000000-0000-4000-8000-000000000008');
-- Anonymous soft + hard deletion never affects registered deletion counters.
update auth.users set deleted_at = pg_catalog.statement_timestamp()
    where id = '24000000-0000-4000-8000-000000000009';
set local role service_role;
select public.pintheory_purge_account('24000000-0000-4000-8000-000000000009');
reset role;
delete from auth.users where id = '24000000-0000-4000-8000-000000000009';
select pg_temp.check_admin_metrics();
do $$
declare m jsonb := public.pintheory_admin_account_metrics(); b jsonb := (select metrics from pg_temp.metrics_baseline);
begin
    assert (m#>>'{users,knownRegistrations}')::bigint = (b#>>'{users,knownRegistrations}')::bigint + 8;
    assert (m#>>'{users,knownDeletions}')::bigint = (b#>>'{users,knownDeletions}')::bigint + 2,
        'soft+hard counted twice, hard deletion missed, or anonymous counted';
    assert (m#>>'{users,current}')::bigint = (b#>>'{users,current}')::bigint + 6;
    assert not exists (select 1 from pintheory_sync.accounts where user_id in (
        '24000000-0000-4000-8000-000000000007', '24000000-0000-4000-8000-000000000008',
        '24000000-0000-4000-8000-000000000009')), 'Auth cascade failed';
    -- Rolled-back Auth changes must roll back counter increments atomically.
    begin
        insert into auth.users(id, is_anonymous) values ('24000000-0000-4000-8000-000000000010', false);
        raise exception using errcode = 'P0002', message = 'fixture rollback';
    exception when no_data_found then null; end;
    assert public.pintheory_admin_account_metrics()->'users' = m->'users';
    assert not exists (select 1 from pintheory_admin.account_counters c
        where pg_catalog.to_jsonb(c)::text ~* '24000000|example[.]invalid'), 'retained fixture identity';
end;
$$;

-- Baseline reconstruction is a separate migration-time staging review: on a
-- fresh disposable project seed registered + anonymous + soft-deleted users
-- BEFORE applying migration four; verify knownRegistrations counts all existing
-- nonanonymous rows and knownDeletions only their soft-deleted rows. Pre-baseline
-- physically deleted identities remain unknowable; historyComplete stays false.
-- Also rehearse concurrent Auth writes while migration waits on its table lock.
rollback;
