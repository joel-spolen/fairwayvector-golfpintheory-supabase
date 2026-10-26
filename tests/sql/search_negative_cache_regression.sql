-- Disposable LOCAL/STAGING ONLY. Never run these synthetic fixtures on production.
-- Exercises the real claim/finish database cache; no HTTP or paid calls.
begin;
set local plpgsql.check_asserts = on;

insert into auth.users(id, email, is_anonymous)
values ('26000001-0000-4000-8000-000000000001', 'negative-cache@example.invalid', false);
select pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);
select pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);

update pintheory_data.settings set enabled = true, cooldown_until = null where provider = 'golf';

do $$
declare
    uid uuid := '26000001-0000-4000-8000-000000000001';
    cache_key text := 'golf:v1:clubs:' || pg_catalog.repeat('b', 64);
    claim jsonb;
    attempts_before bigint;
begin
    -- Isolate this synthetic key without touching production or other cache data.
    delete from pintheory_data.jobs where key = cache_key;
    delete from pintheory_data.responses where key = cache_key;
    select coalesce(sum(attempts), 0) into attempts_before
        from pintheory_data.usage where provider = 'golf';

    claim := public.pintheory_data_claim(uid, cache_key, 'golf', false, null);
    assert claim->>'status' = 'CLAIMED', 'first unseen search must reserve one attempt';
    assert public.pintheory_data_finish(cache_key, (claim->>'token')::uuid,
        '{"clubs":[],"numClubs":0}'::jsonb), 'valid empty searches must be cached';

    -- An old timestamp is not an expiry: ordinary searches use max_age = null.
    update pintheory_data.responses set fetched_at = now() - interval '2 years' where key = cache_key;
    claim := public.pintheory_data_claim(uid, cache_key, 'golf', false, null);
    assert claim->>'status' = 'HIT', 'negative search cache must not expire automatically';
    assert claim#>'{body,clubs}' = '[]'::jsonb, 'empty result must be returned unchanged';
    assert (select coalesce(sum(attempts), 0) = attempts_before + 1
        from pintheory_data.usage where provider = 'golf'), 'repeat empty search must not spend again';
end;
$$;

rollback;