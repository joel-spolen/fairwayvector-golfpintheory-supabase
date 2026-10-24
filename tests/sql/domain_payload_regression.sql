-- NOT EXECUTED. Run only after 202610230001_sync_domain_validation.sql
-- in disposable staging as the trusted migration owner; entire test rolls back.
begin;

do $$
declare
    profile jsonb := '{"name":"Ada","lowHandicapIndex":4.2}'::jsonb;
    club jsonb := '{"name":"My Club","city":"Uppsala","country":"Sweden"}'::jsonb;
    course jsonb := '{"clubRecordID":"33333333-3333-4333-8333-333333333333","clubName":"My Club","name":"North"}'::jsonb;
    tee jsonb := '{"clubRecordID":"33333333-3333-4333-8333-333333333333","courseRecordID":"44444444-4444-4444-8444-444444444444","clubName":"My Club","courseName":"North","name":"Blue","holes":9,"par":36,"courseRating":35.4,"slopeRating":118,"ratingSex":"male","holePars":[4,4,4,4,4,4,4,4,4],"holeHandicapIndices":[1,2,3,4,5,6,7,8,9]}'::jsonb;
    wedge jsonb := '{"name":"56","brand":"Example","notes":"","fullCarry":82,"isInBag":true,"fullCarryUserProvided":true,"carryOverrides":{"stock.threeQuarter":57}}'::jsonb;
    handicap jsonb := '{"date":"2026-10-23T12:00:00.000Z","clubName":"","courseName":"","teeName":"","holes":18,"inputMode":"adjustedGrossScore","adjustedGrossScore":91,"handicapDifferential":18.2,"par":72,"courseRating":0,"slopeRating":113,"pcc":0,"notes":"Manual entry","holeScores":[5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,6],"holePars":[4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4],"holeHandicapIndices":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18],"sourceSavedRoundID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}'::jsonb;
    played jsonb := '{"version":1,"date":"2026-10-23T12:00:00.000Z","reference":{"clubName":"Club","courseName":"Course","city":"Town","region":"Region","holeCount":9,"totalPar":36,"teeName":"Blue","teeSex":"male","courseRating":35.4,"slopeRating":118},"holes":[{"number":1,"par":4,"strokeIndex":1},{"number":2,"par":4,"strokeIndex":2},{"number":3,"par":4,"strokeIndex":3},{"number":4,"par":4,"strokeIndex":4},{"number":5,"par":4,"strokeIndex":5},{"number":6,"par":4,"strokeIndex":6},{"number":7,"par":4,"strokeIndex":7},{"number":8,"par":4,"strokeIndex":8},{"number":9,"par":4,"strokeIndex":9}],"players":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Ada","isOwner":true,"handicapIndex":4.2,"keepsDetailedScore":true}],"game":"Stroke play","detailMode":"Detailed","allowance":100,"scores":{"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA:1":{"strokes":5,"putts":2,"fairway":"Yes","bunkerShots":0,"penalties":0}}}'::jsonb;
begin
    assert pintheory_sync.payload_valid('golfer_profile', profile), 'valid golfer profile rejected';
    assert pintheory_sync.payload_valid('custom_club', club), 'valid custom club rejected';
    assert pintheory_sync.payload_valid('custom_course', course), 'valid custom course rejected';
    assert pintheory_sync.payload_valid('custom_tee', tee), 'valid custom tee rejected';
    assert pintheory_sync.payload_valid('wedge', wedge), 'valid wedge rejected';
    assert pintheory_sync.payload_valid('handicap_round', handicap), 'valid handicap round rejected';
    assert pintheory_sync.payload_valid('played_round', played), 'valid saved scorecard rejected';

    assert not pintheory_sync.payload_valid('golfer_profile', profile || '{"email":"private"}'::jsonb),
        'unknown personal field accepted';
    assert not pintheory_sync.payload_valid('wedge', wedge || '{"password":"secret"}'::jsonb),
        'unknown wedge field accepted';
    assert not pintheory_sync.payload_valid('custom_tee', tee || '{"geometry":[]}'::jsonb),
        'course geometry accepted';
    assert not pintheory_sync.payload_valid('custom_tee', jsonb_set(tee, '{holePars}', '[4,4]'::jsonb)),
        'wrong-length tee par list accepted';
    assert not pintheory_sync.payload_valid('handicap_round', jsonb_set(handicap, '{date}', '"not-a-date"'::jsonb)),
        'invalid date accepted';
    assert not pintheory_sync.payload_valid('played_round', jsonb_set(played, '{holes,1,number}', '1'::jsonb)),
        'duplicate scorecard hole accepted';
    assert not pintheory_sync.payload_valid('played_round', played || '{"course":{}}'::jsonb),
        'course geometry accepted in saved scorecard';
    assert not pintheory_sync.payload_valid('flag_position', '{"x":1}'::jsonb),
        'unapproved flag payload accepted';
end;
$$;

-- The references must belong to the same user and point to active custom parents.
insert into auth.users(id) values ('22222222-2222-4222-8222-222222222222');
insert into pintheory_sync.accounts(user_id) values ('22222222-2222-4222-8222-222222222222');
insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload,
    revision, created_at, updated_at)
values ('22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333',
    'custom_club', 1, '{"name":"My Club","city":"Uppsala","country":"Sweden"}',
    1, now(), now());
insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload,
    revision, created_at, updated_at)
values ('22222222-2222-4222-8222-222222222222', '44444444-4444-4444-8444-444444444444',
    'custom_course', 1,
    '{"clubRecordID":"33333333-3333-4333-8333-333333333333","clubName":"My Club","name":"North"}',
    2, now(), now());

-- A valid tee references the matching active course/club.
insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload,
    revision, created_at, updated_at)
values ('22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555',
    'custom_tee', 1,
    '{"clubRecordID":"33333333-3333-4333-8333-333333333333","courseRecordID":"44444444-4444-4444-8444-444444444444","clubName":"My Club","courseName":"North","name":"Blue","holes":9,"par":36,"courseRating":35.4,"slopeRating":118}',
    3, now(), now());

-- A parent cannot be tombstoned while it still has active descendants; delete
-- tee -> course -> club in that order to preserve referential integrity.
do $$
begin
        begin
                update pintheory_sync.records set deleted_at = now()
                where user_id = '22222222-2222-4222-8222-222222222222'
                    and record_id = '44444444-4444-4444-8444-444444444444';
                raise exception 'course with active tee was deleted';
        exception when sqlstate '23503' then null;
        end;
        update pintheory_sync.records set deleted_at = now()
        where user_id = '22222222-2222-4222-8222-222222222222'
            and record_id = '55555555-5555-4555-8555-555555555555';
        update pintheory_sync.records set deleted_at = now()
        where user_id = '22222222-2222-4222-8222-222222222222'
            and record_id = '44444444-4444-4444-8444-444444444444';
        update pintheory_sync.records set deleted_at = now()
        where user_id = '22222222-2222-4222-8222-222222222222'
            and record_id = '33333333-3333-4333-8333-333333333333';
end;
$$;

do $$
begin
    begin
        insert into pintheory_sync.records(user_id, record_id, kind, schema_version, payload,
            revision, created_at, updated_at)
        values ('22222222-2222-4222-8222-222222222222', '66666666-6666-4666-8666-666666666666',
            'custom_course', 1,
            '{"clubRecordID":"77777777-7777-4777-8777-777777777777","clubName":"Other","name":"Orphan"}',
            4, now(), now());
        raise exception 'orphan custom course accepted';
    exception when sqlstate '22023' then null;
    end;
end;
$$;

rollback;

