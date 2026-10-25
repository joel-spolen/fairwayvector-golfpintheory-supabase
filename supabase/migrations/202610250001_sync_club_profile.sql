-- Add the iOS trajectory bag/profile DTO to the strict sync contract.
-- Apply after 202610230001_sync_domain_validation.sql.
-- Source only until reviewed and applied to the target Supabase project.
begin;

create function pintheory_sync.club_profile_payload_valid(p jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare
    item jsonb;
    club_id text;
    seen text[] := '{}';
    allowed_clubs text[] := array[
        'driver','threeWood','fourWood','fiveWood','sixWood','sevenWood','eightWood','nineWood',
        'threeHybrid','fourHybrid','fiveHybrid','twoIron','threeIron','fourIron','fiveIron',
        'sixIron','sevenIron','eightIron','nineIron','pitchingWedge','approachWedge','gapWedge',
        'fiftyTwoWedge','sandWedge','fiftySixWedge','fiftyEightWedge','lobWedge'
    ];
begin
    if not pintheory_sync.object_keys_valid(p,
        array['schemaVersion','isSetupComplete','detailLevel','handicapBand','availableClubs','clubOverrides'],
        array['exactHandicap','driverCarryM','sevenIronCarryM'])
       or not pintheory_sync.number_valid(p->'schemaVersion', 1, 1, true)
       or pg_catalog.jsonb_typeof(p->'isSetupComplete') is distinct from 'boolean'
       or not pintheory_sync.string_valid(p->'detailLevel', 1, 16)
       or p->>'detailLevel' <> all(array['easy','medium','expert'])
       or not pintheory_sync.string_valid(p->'handicapBand', 1, 40)
       or p->>'handicapBand' <> all(array['plusToZero','zeroToFive','fiveToTen','tenToFifteen',
           'fifteenToTwenty','twentyToTwentyFive','twentyFiveToThirtyFive','thirtyFivePlus'])
       or pg_catalog.jsonb_typeof(p->'availableClubs') is distinct from 'array'
       or pg_catalog.jsonb_typeof(p->'clubOverrides') is distinct from 'array'
       or pg_catalog.jsonb_array_length(p->'availableClubs') > 27
       or pg_catalog.jsonb_array_length(p->'clubOverrides') > 27 then return false; end if;

    if p ? 'exactHandicap' and p->'exactHandicap' <> 'null'::jsonb
       and not pintheory_sync.number_valid(p->'exactHandicap', -5, 40) then return false; end if;
    if p ? 'driverCarryM' and p->'driverCarryM' <> 'null'::jsonb
       and not pintheory_sync.number_valid(p->'driverCarryM', 0, 500) then return false; end if;
    if p ? 'sevenIronCarryM' and p->'sevenIronCarryM' <> 'null'::jsonb
       and not pintheory_sync.number_valid(p->'sevenIronCarryM', 0, 300) then return false; end if;

    seen := '{}';
    for item in select value from pg_catalog.jsonb_array_elements(p->'availableClubs') loop
        if not pintheory_sync.string_valid(item, 1, 32) then return false; end if;
        club_id := item #>> '{}';
        if not (club_id = any(allowed_clubs)) or club_id = any(seen) then return false; end if;
        seen := pg_catalog.array_append(seen, club_id);
    end loop;

    seen := '{}';
    for item in select value from pg_catalog.jsonb_array_elements(p->'clubOverrides') loop
        if not pintheory_sync.object_keys_valid(item, array['club'],
            array['carryDistanceM','ballSpeedMps','launchAngleDeg','spinRateRpm','spinAxisDeg'])
           or not pintheory_sync.string_valid(item->'club', 1, 32) then return false; end if;
        club_id := item->>'club';
        if not (club_id = any(allowed_clubs)) or club_id = any(seen) then return false; end if;
        seen := pg_catalog.array_append(seen, club_id);
        if item ? 'carryDistanceM' and item->'carryDistanceM' <> 'null'::jsonb
           and not pintheory_sync.number_valid(item->'carryDistanceM', 0, 500) then return false; end if;
        if item ? 'ballSpeedMps' and item->'ballSpeedMps' <> 'null'::jsonb
           and not pintheory_sync.number_valid(item->'ballSpeedMps', 0, 150) then return false; end if;
        if item ? 'launchAngleDeg' and item->'launchAngleDeg' <> 'null'::jsonb
           and not pintheory_sync.number_valid(item->'launchAngleDeg', -20, 60) then return false; end if;
        if item ? 'spinRateRpm' and item->'spinRateRpm' <> 'null'::jsonb
           and not pintheory_sync.number_valid(item->'spinRateRpm', 0, 20000) then return false; end if;
        if item ? 'spinAxisDeg' and item->'spinAxisDeg' <> 'null'::jsonb
           and not pintheory_sync.number_valid(item->'spinAxisDeg', -180, 180) then return false; end if;
    end loop;
    return true;
exception when others then return false;
end;
$$;

create function pintheory_sync.approved_payload_valid(p_kind text, p jsonb)
returns boolean language sql immutable set search_path = pg_catalog as $$
    select case when p_kind = 'club_profile'
        then pintheory_sync.club_profile_payload_valid(p)
        else pintheory_sync.payload_valid(p_kind, p)
    end;
$$;

create or replace function pintheory_sync.record_payload_valid(p_record jsonb)
returns boolean language sql immutable set search_path = pg_catalog as $$
    select coalesce(pg_catalog.jsonb_typeof(p_record) = 'object'
       and p_record ? 'kind' and p_record ? 'payload'
       and pintheory_sync.approved_payload_valid(p_record->>'kind', p_record->'payload'), false);
$$;

create or replace function pintheory_sync.receipt_payloads_valid(p_receipt jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v_request jsonb; v_response jsonb; v_current jsonb; v_kind text;
begin
    if not pintheory_sync.object_keys_valid(p_receipt, array['mutation_id','request','response'])
       or not pintheory_sync.uuid_string_valid(p_receipt->'mutation_id')
       or pg_catalog.jsonb_typeof(p_receipt->'request') is distinct from 'object'
       or pg_catalog.jsonb_typeof(p_receipt->'response') is distinct from 'object' then return false; end if;
    v_request := p_receipt->'request';
    v_response := p_receipt->'response';
    v_kind := v_request->>'kind';
    if not pintheory_sync.object_keys_valid(v_request,
        array['record_id','kind','expected_revision','operation','schema_version','payload'])
       or not pintheory_sync.uuid_string_valid(v_request->'record_id')
       or not pintheory_sync.string_valid(v_request->'expected_revision', 1, 19)
       or (v_request->>'expected_revision') !~ '^(0|[1-9][0-9]{0,18})$'
       or not pintheory_sync.number_valid(v_request->'schema_version', 1, 1, true) then return false; end if;
    if v_request->>'operation' = 'delete' then
        if v_request->'payload' <> '{}'::jsonb then return false; end if;
    elsif v_request->>'operation' is distinct from 'put'
       or not pintheory_sync.approved_payload_valid(v_kind, v_request->'payload') then return false;
    end if;
    if v_response->>'status' = 'applied' then
        return pintheory_sync.object_keys_valid(v_response, array['status','mutation_id','record'])
            and pintheory_sync.uuid_string_valid(v_response->'mutation_id')
            and v_response->>'mutation_id' = p_receipt->>'mutation_id'
            and pintheory_sync.record_payload_valid(v_response->'record');
    elsif v_response->>'status' = 'conflict' then
        if not pintheory_sync.object_keys_valid(v_response, array['status','mutation_id','current'])
           or not pintheory_sync.uuid_string_valid(v_response->'mutation_id')
           or v_response->>'mutation_id' <> p_receipt->>'mutation_id'
           or not (v_response ? 'current') then return false; end if;
        v_current := v_response->'current';
        return (v_current = 'null'::jsonb) or pintheory_sync.record_payload_valid(v_current);
    elsif v_response->>'status' = 'source_conflict' then
        if not pintheory_sync.object_keys_valid(v_response,
            array['status','mutation_id','current','source_record'])
           or not pintheory_sync.uuid_string_valid(v_response->'mutation_id')
           or v_response->>'mutation_id' <> p_receipt->>'mutation_id'
           or not (v_response ? 'current') then return false; end if;
        v_current := v_response->'current';
        return ((v_current = 'null'::jsonb) or pintheory_sync.record_payload_valid(v_current))
            and pintheory_sync.record_payload_valid(v_response->'source_record');
    end if;
    return false;
exception when others then return false;
end;
$$;

create or replace function pintheory_sync.validate_mutation_receipt()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin
    if not pintheory_sync.receipt_payloads_valid(pg_catalog.jsonb_build_object(
        'mutation_id', new.mutation_id, 'request', new.request, 'response', new.response)) then
        raise exception using errcode = '22023', message = 'invalid_sync_receipt';
    end if;
    return new;
end;
$$;

create or replace function pintheory_sync.validate_record_payload()
returns trigger language plpgsql set search_path = pg_catalog as $$
declare v_children integer;
begin
    if not pintheory_sync.approved_payload_valid(new.kind, new.payload) then
        raise exception using errcode = '22023', message = 'invalid_sync_payload';
    end if;
    if new.deleted_at is null and not pintheory_sync.custom_references_valid(new.user_id, new.kind, new.payload) then
        raise exception using errcode = '22023', message = 'invalid_custom_record_reference';
    end if;
    if tg_op = 'UPDATE' and new.deleted_at is not null and old.deleted_at is null
       and new.kind in ('custom_club', 'custom_course') then
        if new.kind = 'custom_club' then
            select count(*) into v_children from pintheory_sync.records child
            where child.user_id = new.user_id and child.deleted_at is null
              and (child.kind = 'custom_course' and child.payload->>'clubRecordID' = new.record_id::text
                   or child.kind = 'custom_tee' and child.payload->>'clubRecordID' = new.record_id::text);
        else
            select count(*) into v_children from pintheory_sync.records child
            where child.user_id = new.user_id and child.deleted_at is null
              and child.kind = 'custom_tee' and child.payload->>'courseRecordID' = new.record_id::text;
        end if;
        if v_children > 0 then
            raise exception using errcode = '23503', message = 'custom_record_has_active_children';
        end if;
    end if;
    return new;
end;
$$;

alter table pintheory_sync.records drop constraint records_domain_payload_valid;
alter table pintheory_sync.records add constraint records_domain_payload_valid
    check (pintheory_sync.approved_payload_valid(kind, payload)) not valid;
alter table pintheory_sync.records validate constraint records_domain_payload_valid;
alter table pintheory_sync.change_events drop constraint change_events_domain_payload_valid;
alter table pintheory_sync.change_events add constraint change_events_domain_payload_valid
    check (pintheory_sync.record_payload_valid(record)) not valid;
alter table pintheory_sync.change_events validate constraint change_events_domain_payload_valid;

do $$
begin
    if exists (select 1 from pintheory_sync.records r where not pintheory_sync.approved_payload_valid(r.kind, r.payload)) then
        raise exception 'existing sync records fail the expanded DTO contract';
    end if;
    if exists (select 1 from pintheory_sync.change_events e where not pintheory_sync.record_payload_valid(e.record)) then
        raise exception 'existing sync events fail the expanded DTO contract';
    end if;
    if exists (select 1 from pintheory_sync.mutation_receipts r where not pintheory_sync.receipt_payloads_valid(
        pg_catalog.jsonb_build_object('mutation_id', r.mutation_id, 'request', r.request, 'response', r.response))) then
        raise exception 'existing sync receipts fail the expanded DTO contract';
    end if;
end;
$$;

create or replace function public.pintheory_sync_capabilities()
returns jsonb language sql stable security definer set search_path = pg_catalog as $$
    select pg_catalog.jsonb_build_object(
        'sync_schema_version', 1,
        'payload_validation_version', 2
    );
$$;
alter function public.pintheory_sync_capabilities() owner to postgres;
revoke all on function public.pintheory_sync_capabilities() from public, anon, authenticated, service_role;
grant execute on function public.pintheory_sync_capabilities() to authenticated;

alter function pintheory_sync.validate_record_payload() owner to postgres;
alter function pintheory_sync.validate_mutation_receipt() owner to postgres;
revoke all on all functions in schema pintheory_sync from public, anon, authenticated, service_role;

commit;
