-- NOT EXECUTED. Rollback-contained profile DTO contract test.
-- Run only after 202610250001_sync_club_profile.sql in disposable staging.
begin;
insert into auth.users(id) values ('91919191-9191-4191-8191-919191919191');
do $$
declare
    profile jsonb := '{"schemaVersion":1,"isSetupComplete":true,"detailLevel":"expert","handicapBand":"fiveToTen","exactHandicap":7.4,"driverCarryM":220,"sevenIronCarryM":145,"availableClubs":["driver","sevenIron","fiveHybrid"],"clubOverrides":[{"club":"sevenIron","carryDistanceM":145,"ballSpeedMps":48,"launchAngleDeg":17.5,"spinRateRpm":5200,"spinAxisDeg":-2}]}'::jsonb;
begin
    assert pintheory_sync.club_profile_payload_valid(profile), 'valid trajectory profile rejected';
    assert not pintheory_sync.club_profile_payload_valid(profile || '{"distanceUnit":"yards"}'::jsonb),
        'device unit preference accepted in account profile';
    assert not pintheory_sync.club_profile_payload_valid(jsonb_set(profile, '{availableClubs}', '["driver","unknownClub"]'::jsonb)),
        'unknown club ID accepted';
    assert not pintheory_sync.club_profile_payload_valid(jsonb_set(profile, '{clubOverrides,0,spinRateRpm}', '25000'::jsonb)),
        'out-of-range launch data accepted';
end;
$$;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '91919191-9191-4191-8191-919191919191', true);
select pg_catalog.set_config('request.jwt.claims',
    '{"sub":"91919191-9191-4191-8191-919191919191","role":"authenticated"}', true);
do $$
declare result jsonb; page jsonb;
    profile jsonb := '{"schemaVersion":1,"isSetupComplete":true,"detailLevel":"expert","handicapBand":"fiveToTen","exactHandicap":7.4,"driverCarryM":220,"sevenIronCarryM":145,"availableClubs":["driver","sevenIron","fiveHybrid"],"clubOverrides":[{"club":"sevenIron","carryDistanceM":145,"ballSpeedMps":48,"launchAngleDeg":17.5,"spinRateRpm":5200,"spinAxisDeg":-2}]}'::jsonb;
begin
    result := public.pintheory_sync_mutate(
        '91919191-0000-4000-8000-000000000001',
        '91919191-1111-4111-8111-919191919191',
        'club_profile', '0', 'put', 1, profile);
    assert result->>'status' = 'applied', 'club profile sync mutation failed';
    assert result#>>'{record,payload,availableClubs,1}' = 'sevenIron', 'club bag selection missing in mutation result';
    page := public.pintheory_sync_changes();
    assert page#>>'{events,0,record,kind}' = 'club_profile', 'club profile missing from changes feed';
    assert page#>>'{events,0,record,payload,availableClubs,1}' = 'sevenIron', 'bag selection did not round-trip';
end;
$$;
rollback;
