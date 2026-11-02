-- Disposable LOCAL/STAGING ONLY. Never run these synthetic fixtures on production.
-- Exercises the per-user sync, download and provider caps; no HTTP or paid calls.
begin;
set local plpgsql.check_asserts = on;

insert into auth.users(id, email, is_anonymous)
values ('26000003-0000-4000-8000-000000000001', 'usage-limits@example.invalid', false);
update pintheory_data.settings set enabled = true, daily_limit = 100, cooldown_until = null where provider = 'golf';

-- Sync: the 2001st mutation of the day is rejected with PT429 and leaves no trace.
select pg_catalog.set_config('request.jwt.claims',
    '{"role":"authenticated","sub":"26000003-0000-4000-8000-000000000001"}', true);
do $$
declare
    uid uuid := '26000003-0000-4000-8000-000000000001';
    result jsonb;
begin
    result := public.pintheory_sync_mutate(gen_random_uuid(), gen_random_uuid(), 'golfer_profile', '0',
        'put', 1, '{"name":"Ada"}');
    assert result->>'status' = 'applied', 'first mutation must apply';
    update pintheory_sync.daily_usage set mutations = 2000 where user_id = uid;
    begin
        perform public.pintheory_sync_mutate(gen_random_uuid(), gen_random_uuid(), 'golfer_profile', '0',
            'put', 1, '{"name":"Bea"}');
        raise exception 'daily mutation cap not enforced';
    exception when sqlstate 'PT429' then null; end;
    assert (select count(*) = 1 from pintheory_sync.records where user_id = uid), 'rejected mutation must roll back';

    update pintheory_sync.daily_usage set mutations = 0, bytes = 19999990 where user_id = uid;
    begin
        perform public.pintheory_sync_mutate(gen_random_uuid(), gen_random_uuid(), 'golfer_profile', '0',
            'put', 1, '{"name":"Cy"}');
        raise exception 'daily byte cap not enforced';
    exception when sqlstate 'PT429' then null; end;
end $$;

-- Sync: 5000 live records per user; deleting one frees a slot.
select pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare uid uuid := '26000003-0000-4000-8000-000000000001';
begin
    insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload, revision, created_at, updated_at)
        select uid, gen_random_uuid(), 'golfer_profile', 1, '{"name":"Fill"}', 1000 + n, now(), now()
        from generate_series(1, 4999) as n;
    assert (select count(*) = 5000 from pintheory_sync.records where user_id = uid and deleted_at is null);
    begin
        insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload, revision, created_at, updated_at)
            values (uid, gen_random_uuid(), 'golfer_profile', 1, '{"name":"Over"}', 9000, now(), now());
        raise exception 'live record cap not enforced';
    exception when sqlstate 'PT429' then null; end;
    update pintheory_sync.records set deleted_at = now()
        where record_id = (select record_id from pintheory_sync.records where user_id = uid limit 1);
    insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload, revision, created_at, updated_at)
        values (uid, gen_random_uuid(), 'golfer_profile', 1, '{"name":"Again"}', 9001, now(), now());
end $$;

-- Downloads: 300 tiles or 1 GB per user per day; the service role only.
do $$
declare uid uuid := '26000003-0000-4000-8000-000000000001'; i integer;
begin
    for i in 1..300 loop
        assert public.pintheory_data_download(uid, 1000)->>'status' = 'OK';
    end loop;
    assert public.pintheory_data_download(uid, 1000)->>'status' = 'RATE_LIMIT', 'tile count cap';
    update pintheory_data.per_user_usage set downloads = 0, download_bytes = 999999000
        where user_id = uid and day = (now() at time zone 'UTC')::date;
    assert public.pintheory_data_download(uid, 1000)->>'status' = 'OK';
    assert public.pintheory_data_download(uid, 1)->>'status' = 'RATE_LIMIT', 'byte cap';
    begin
        perform public.pintheory_data_download(uid, 0);
        raise exception 'invalid size accepted';
    exception when sqlstate '22023' then null; end;
end $$;

-- Providers: one user gets at most 20% of the golf budget (100 -> 20 attempts).
do $$
declare uid uuid := '26000003-0000-4000-8000-000000000001'; claim jsonb;
begin
    update pintheory_data.per_user_usage set provider_attempts = '{"golf":20}'
        where user_id = uid and day = (now() at time zone 'UTC')::date;
    delete from pintheory_data.jobs where key = 'golf:v1:detail:usage-limit';
    delete from pintheory_data.responses where key = 'golf:v1:detail:usage-limit';
    claim := public.pintheory_data_claim(uid, 'golf:v1:detail:usage-limit', 'golf', false, null);
    assert claim->>'status' = 'RATE_LIMIT', 'per-user provider share must be enforced';
    update pintheory_data.per_user_usage set provider_attempts = '{"golf":19}'
        where user_id = uid and day = (now() at time zone 'UTC')::date;
    claim := public.pintheory_data_claim(uid, 'golf:v1:detail:usage-limit', 'golf', false, null);
    assert claim->>'status' = 'CLAIMED', 'under the share a claim must succeed';
    assert (select provider_attempts->>'golf' = '20' from pintheory_data.per_user_usage
        where user_id = uid and day = (now() at time zone 'UTC')::date);
end $$;

rollback;
