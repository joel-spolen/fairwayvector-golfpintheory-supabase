-- NOT EXECUTED. Disposable staging Supabase only, as migration owner.
-- No extensions, external connections, secrets, or existing users required.
-- The entire fixture transaction is rolled back, including auth.users rows.
begin;
insert into auth.users(id) values
    ('11111111-1111-4111-8111-111111111111'),
    ('22222222-2222-4222-8222-222222222222');

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
do $$
declare
    a jsonb;
    b jsonb;
    page jsonb;
begin
    a := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"local version"}');
    assert a->>'status' = 'applied' and a#>>'{record,revision}' = '1', 'create failed';
    b := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"local version"}');
    assert a = b, 'receipt replay changed';
    begin
        perform public.pintheory_sync_mutate(
            'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
            'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"different"}');
        raise exception 'changed request accepted';
    exception when invalid_parameter_value then null;
    end;
    a := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000002', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"losing edit"}');
    assert a->>'status' = 'conflict' and a#>>'{current,payload,notes}' = 'local version', 'CAS overwrote';
    perform public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000003', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '1', 'delete', 1, '{}');
    b := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000002', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"losing edit"}');
    assert a = b, 'conflict receipt was recomputed';
    b := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000004', 'aaaaaaaa-1111-4111-8111-111111111111',
        'played_round', '1', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"stale resurrection"}');
    assert b->>'status' = 'conflict' and b#>>'{current,deleted_at}' is not null, 'delete/edit lost';
    page := public.pintheory_sync_changes('0', null, 1);
    assert page->>'through' = '2' and page->>'next_after' = '1'
        and (page->>'has_more')::boolean, 'first cursor page wrong';
    page := public.pintheory_sync_changes('1', '2', 1);
    assert page#>>'{events,0,record,deleted_at}' is not null
        and not (page->>'has_more')::boolean, 'tombstone page wrong';
    -- No automatic handicap import: only played_round events so far.
    page := public.pintheory_sync_changes();
    assert pg_catalog.jsonb_array_length(page->'events') = 2, 'unexpected auto-import/event';
    perform public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000005', 'aaaaaaaa-2222-4222-8222-222222222222',
        'handicap_round', '0', 'put', 1,
        '{"date":"2026-10-23T12:00:00Z","clubName":"Fixture Club","courseName":"Fixture Course","teeName":"Blue","holes":18,"inputMode":"adjustedGrossScore","adjustedGrossScore":91,"handicapDifferential":18.2,"par":72,"courseRating":72,"slopeRating":113,"pcc":0,"notes":"Manual entry","sourceSavedRoundID":"aaaaaaaa-1111-4111-8111-111111111111"}');
    b := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000006', 'aaaaaaaa-3333-4333-8333-333333333333',
        'handicap_round', '0', 'put', 1,
        '{"date":"2026-10-23T12:00:00Z","clubName":"Fixture Club","courseName":"Fixture Course","teeName":"Blue","holes":18,"inputMode":"adjustedGrossScore","adjustedGrossScore":91,"handicapDifferential":18.2,"par":72,"courseRating":72,"slopeRating":113,"pcc":0,"notes":"Manual entry","sourceSavedRoundID":"aaaaaaaa-1111-4111-8111-111111111111"}');
    assert b->>'status' = 'source_conflict'
        and b#>>'{source_record,record_id}' = 'aaaaaaaa-2222-4222-8222-222222222222', 'source duplicate';
    begin
        perform public.pintheory_sync_mutate(
            'aaaaaaaa-0000-4000-8000-000000000007', 'aaaaaaaa-3333-4333-8333-333333333333',
            'wedge', '0', 'put', 1, '[]');
        raise exception 'array accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform public.pintheory_sync_mutate(
            'aaaaaaaa-0000-4000-8000-000000000007', 'aaaaaaaa-3333-4333-8333-333333333333',
            'wedge', '0', 'put', 1, pg_catalog.jsonb_build_object('x', pg_catalog.repeat('x', 65536)));
        raise exception 'oversized payload accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform public.pintheory_sync_changes('0', '999', 100);
        raise exception 'future cursor accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform 1 from pintheory_sync.records;
        raise exception 'direct table read allowed';
    exception when insufficient_privilege then null;
    end;
    begin
        delete from pintheory_sync.accounts;
        raise exception 'direct write allowed';
    exception when insufficient_privilege then null;
    end;
end;
$$;

-- Different UID cannot pull or CAS another user's row, even with its known ID.
select pg_catalog.set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
do $$
declare r jsonb;
begin
    r := public.pintheory_sync_changes();
    assert r->'events' = '[]'::jsonb, 'cross-user feed leak';
    r := public.pintheory_sync_mutate(
        'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
        'golfer_profile', '1', 'put', 1, '{"name":"Fixture Player","lowHandicapIndex":4.2}');
    assert r->>'status' = 'conflict' and r->'current' = 'null'::jsonb, 'cross-user CAS leak';
end;
$$;

reset role;
-- Exercise RLS independently of the production ACL denial. These temporary
-- grants exist only inside this rollback-contained test transaction.
grant usage on schema pintheory_sync to authenticated;
grant select on all tables in schema pintheory_sync to authenticated;
set local role authenticated;
do $$
begin
    assert not exists (select 1 from pintheory_sync.accounts
        where user_id <> auth.uid()), 'account RLS leaked';
    assert not exists (select 1 from pintheory_sync.records
        where user_id <> auth.uid()), 'record RLS leaked';
    assert not exists (select 1 from pintheory_sync.change_events
        where user_id <> auth.uid()), 'event RLS leaked';
    assert not exists (select 1 from pintheory_sync.mutation_receipts
        where user_id <> auth.uid()), 'receipt RLS leaked';
end;
$$;
reset role;
revoke select on all tables in schema pintheory_sync from authenticated;
revoke usage on schema pintheory_sync from authenticated;
-- Privileged control-plane flag; no client endpoint exposes this operation.
update pintheory_sync.accounts set state = 'deleting'
    where user_id = '11111111-1111-4111-8111-111111111111';
do $$
begin
    begin
        update pintheory_sync.mutation_receipts set response = '{}';
        raise exception 'receipt mutable';
    exception when sqlstate '55000' then null;
    end;
    begin
        delete from pintheory_sync.change_events;
        raise exception 'event mutable';
    exception when sqlstate '55000' then null;
    end;
end;
$$;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
do $$
begin
    begin
        perform public.pintheory_sync_mutate(
            'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
            'played_round', '0', 'put', 1, '{"version":1,"date":"2026-10-23T12:00:00Z","reference":{"clubName":"Fixture Club","courseName":"Fixture Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Fixture Player","isOwner":true,"handicapIndex":4.2}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"fairway":"Yes"}},"notes":"local version"}');
        raise exception 'blocked account replay allowed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.pintheory_sync_changes();
        raise exception 'blocked account pull allowed';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '', true);
select pg_catalog.set_config('request.jwt.claims', '{"role":"authenticated"}', true);
do $$
begin
    begin
        perform public.pintheory_sync_changes();
        raise exception 'missing UID accepted';
    exception when sqlstate '28000' then null;
    end;
end;
$$;
reset role;
set local role anon;
do $$
begin
    begin
        perform public.pintheory_sync_changes();
        raise exception 'anonymous RPC allowed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.pintheory_sync_mutate(
            'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-1111-4111-8111-111111111111',
            'played_round', '0', 'put', 1, '{}');
        raise exception 'anonymous mutation allowed';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;
rollback;
