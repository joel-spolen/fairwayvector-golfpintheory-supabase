-- NOT EXECUTED. Disposable staging only, as the trusted postgres migration owner.
-- Run after all three backend migrations; the transaction rolls back all fixtures.
begin;
insert into auth.users(id) values ('44444444-4444-4444-8444-444444444444');

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
select pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object(
        'sub', '44444444-4444-4444-8444-444444444444',
        'role', 'authenticated'
    )::text, true);
do $$
begin
    begin
        perform public.pintheory_begin_account_deletion();
        raise exception 'stale authentication accepted';
    exception when insufficient_privilege then null;
    end;
end;
$$;
select pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object(
        'sub', '44444444-4444-4444-8444-444444444444',
        'role', 'authenticated',
        'iat', pg_catalog.floor(pg_catalog.date_part('epoch', pg_catalog.clock_timestamp()))::bigint - 601
    )::text, true);
do $$
begin
    begin
        perform public.pintheory_begin_account_deletion();
        raise exception 'stale authentication accepted';
    exception when insufficient_privilege then null;
    end;
end;
$$;
select pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object(
        'sub', '44444444-4444-4444-8444-444444444444',
        'role', 'authenticated',
        'iat', pg_catalog.floor(pg_catalog.date_part('epoch', pg_catalog.clock_timestamp()))::bigint
    )::text, true);
select public.pintheory_begin_account_deletion();
do $$
begin
    begin
        perform public.pintheory_sync_changes();
        raise exception 'deleting account pull was allowed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.pintheory_sync_mutate(
            '77777777-7777-4777-8777-777777777777',
            '88888888-8888-4888-8888-888888888888',
            'wedge', '0', 'put', 1,
            '{"name":"56","brand":"","notes":"must not write","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}');
        raise exception 'deleting account mutation was allowed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.pintheory_purge_account('44444444-4444-4444-8444-444444444444');
        raise exception 'authenticated purge bridge call was allowed';
    exception when insufficient_privilege then null;
    end;
end;
$$;

reset role;
insert into pintheory_sync.records(
    user_id, record_id, kind, schema_version, payload, revision, created_at, updated_at
) values (
    '44444444-4444-4444-8444-444444444444', '55555555-5555-4555-8555-555555555555',
    'wedge', 1, '{"name":"56","brand":"","notes":"purge fixture","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}', 1, now(), now()
);
insert into pintheory_sync.change_events(user_id, sequence, record)
values ('44444444-4444-4444-8444-444444444444', 1,
    '{"record_id":"55555555-5555-4555-8555-555555555555","kind":"wedge","schema_version":1,"payload":{"name":"56","brand":"","notes":"purge fixture","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}},"revision":"1","created_at":"2026-10-23T12:00:00Z","updated_at":"2026-10-23T12:00:00Z","deleted_at":null}');
insert into pintheory_sync.mutation_receipts(user_id, mutation_id, request, response)
values (
    '44444444-4444-4444-8444-444444444444', '66666666-6666-4666-8666-666666666666',
    '{"record_id":"55555555-5555-4555-8555-555555555555","kind":"wedge","expected_revision":"0","operation":"put","schema_version":1,"payload":{"name":"56","brand":"","notes":"purge fixture","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}}',
    '{"status":"applied","mutation_id":"66666666-6666-4666-8666-666666666666","record":{"record_id":"55555555-5555-4555-8555-555555555555","kind":"wedge","schema_version":1,"payload":{"name":"56","brand":"","notes":"purge fixture","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}},"revision":"1","created_at":"2026-10-23T12:00:00Z","updated_at":"2026-10-23T12:00:00Z","deleted_at":null}}'
);

set local role authenticated;
select pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object(
        'sub', '44444444-4444-4444-8444-444444444444',
        'role', 'authenticated',
        'iat', pg_catalog.floor(pg_catalog.date_part('epoch', pg_catalog.clock_timestamp()))::bigint - 601
    )::text, true);
select public.pintheory_begin_account_deletion(); -- already deleting: no fresh iat required
reset role;

set local role service_role;
select pg_catalog.set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
select pg_catalog.set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-8444-444444444444","role":"service_role"}', true);
select public.pintheory_purge_account('44444444-4444-4444-8444-444444444444');
select public.pintheory_purge_account('44444444-4444-4444-8444-444444444444'); -- idempotent retry
reset role;

do $$
begin
    assert exists (
        select 1 from pintheory_sync.accounts
        where user_id = '44444444-4444-4444-8444-444444444444' and state = 'deleting'
    ), 'deleting account row was removed';
    assert not exists (select 1 from pintheory_sync.records
        where user_id = '44444444-4444-4444-8444-444444444444'), 'records remain';
    assert not exists (select 1 from pintheory_sync.change_events
        where user_id = '44444444-4444-4444-8444-444444444444'), 'events remain';
    assert not exists (select 1 from pintheory_sync.mutation_receipts
        where user_id = '44444444-4444-4444-8444-444444444444'), 'receipts remain';
end;
$$;
rollback;
