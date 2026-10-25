-- Run after the timestamp-aware club-profile migration on a disposable database.
begin;

do $$
declare
    v_profile jsonb := '{
        "schemaVersion": 1,
        "isSetupComplete": true,
        "detailLevel": "expert",
        "handicapBand": "fiveToTen",
        "availableClubs": ["driver"],
        "clubOverrides": []
    }'::jsonb;
begin
    if not pintheory_sync.approved_payload_valid('club_profile', v_profile) then
        raise exception 'legacy club-profile payload should remain valid';
    end if;
    if not pintheory_sync.approved_payload_valid('club_profile', v_profile ||
        '{"clientUpdatedAt":"2026-10-25T12:00:00.000Z"}'::jsonb) then
        raise exception 'valid timestamped club-profile payload rejected';
    end if;
    if pintheory_sync.approved_payload_valid('club_profile', v_profile ||
        '{"clientUpdatedAt":"not-a-timestamp"}'::jsonb) then
        raise exception 'invalid timestamped club-profile payload accepted';
    end if;
    if pintheory_sync.approved_payload_valid('club_profile', v_profile ||
        '{"clientUpdatedAt":"infinity"}'::jsonb) then
        raise exception 'infinite timestamped club-profile payload accepted';
    end if;
    if not pintheory_sync.approved_payload_valid('wedge',
        '{"name":"PW","brand":"","notes":"","fullCarry":110,"isInBag":true,"fullCarryUserProvided":false,"carryOverrides":{},"clientUpdatedAt":"2026-10-25T12:00:00.000Z"}'::jsonb) then
        raise exception 'valid timestamped wedge payload rejected';
    end if;
    if pintheory_sync.approved_payload_valid('wedge',
        '{"name":"PW","brand":"","notes":"","fullCarry":110,"isInBag":true,"fullCarryUserProvided":false,"carryOverrides":{},"clientUpdatedAt":"not-a-timestamp"}'::jsonb) then
        raise exception 'invalid timestamped wedge payload accepted';
    end if;
end;
$$;

rollback;
