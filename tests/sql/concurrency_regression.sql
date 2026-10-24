-- NOT EXECUTED. Manual multi-session regression, disposable staging ONLY.
-- Execute labelled sections individually in trusted SQL sessions, NOT as one file.
-- No sleep/dblink/extensions required. Fixtures persist until staging is reset.

-- SETUP (migration owner; commit before starting sessions A and B):
begin;
insert into auth.users(id) values ('33333333-3333-4333-8333-333333333333');
commit;

-- SESSION A: leave transaction OPEN after the RPC returns.
begin;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
select public.pintheory_sync_mutate(
    'cccccccc-0000-4000-8000-000000000001', 'cccccccc-1111-4111-8111-111111111111',
    'wedge', '0', 'put', 1,
    '{"name":"56","brand":"","notes":"A","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}');
-- EXPECT applied revision "1". Do not commit yet.

-- SESSION B: execute while A remains open. MUST block, not return early.
begin;
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
select pg_catalog.set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
select public.pintheory_sync_mutate(
    'cccccccc-0000-4000-8000-000000000002', 'cccccccc-1111-4111-8111-111111111111',
    'wedge', '0', 'put', 1,
    '{"name":"56","brand":"","notes":"B","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{}}');

-- SESSION A ONLY: release B.
commit;

-- SESSION B: RPC must now return conflict, current.payload.notes = A,
-- current.revision = "1". Commit, then run assertions as owner below.
commit;

-- VERIFY (migration owner): one event, two receipts, no overwritten version.
do $$
begin
    assert (select a.last_sequence = 1 from pintheory_sync.accounts a
        where a.user_id = '33333333-3333-4333-8333-333333333333'), 'sequence advanced on conflict';
    assert (select count(*) = 1 from pintheory_sync.change_events e
        where e.user_id = '33333333-3333-4333-8333-333333333333'), 'wrong event count';
    assert (select count(*) = 2 from pintheory_sync.mutation_receipts r
        where r.user_id = '33333333-3333-4333-8333-333333333333'), 'receipt missing';
end;
$$;

-- Additional required variants (fresh fixture UID/mutation IDs each time):
-- 1. Same mutation ID + same request in B: waits, then exact receipt, ONE event.
-- 2. Same mutation ID + different payload in B: waits, then SQLSTATE 22023.
-- 3. Different record UUIDs: both apply, revisions "1" then "2"; no gaps.
-- 4. Roll back A rather than commit: B applies at revision "1".
-- 5. Open account first. A (owner) UPDATE accounts SET state='deleting' for UID,
--    leave open. B mutate waits; commit A => B SQLSTATE 42501, no new receipt/event.
-- 6. Reverse #5: A mutation owns lock, B privileged state UPDATE waits;
--    commit A, commit B. Every later write/replay fails 42501.
-- 7. Two handicap_round IDs, same sourceSavedRoundID: one applied, second
--    source_conflict; source_record is the first; only one change event.
-- 8. Pull first page with limit 1; retain through. Concurrently append a write.
--    Continue with same through: new event excluded. Next window includes it.
-- Run at default READ COMMITTED. At SERIALIZABLE/REPEATABLE READ clients must
-- retry transaction failures (40001) with the SAME mutation ID/request.
