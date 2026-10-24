-- Forward-only strict payload validation for the first approved iOS sync DTOs.
-- Apply AFTER the sync foundation and account-deletion migrations.
-- Reviewed source; do not apply to production before disposable staging tests.
begin;

create function public.pintheory_sync_capabilities()
returns jsonb language sql stable security definer set search_path = pg_catalog as $$
    select pg_catalog.jsonb_build_object(
        'sync_schema_version', 1,
        'payload_validation_version', 1
    );
$$;
alter function public.pintheory_sync_capabilities() owner to postgres;
revoke all on function public.pintheory_sync_capabilities() from public, anon, authenticated, service_role;
grant execute on function public.pintheory_sync_capabilities() to authenticated;

create function pintheory_sync.object_keys_valid(p_value jsonb, p_required text[], p_optional text[] default '{}')
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v_key text;
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'object'
       or not (p_value ?& p_required) then return false; end if;
    for v_key in select key from pg_catalog.jsonb_object_keys(p_value) as keys(key) loop
        if not (v_key = any (p_required || p_optional)) then return false; end if;
    end loop;
    return true;
end;
$$;

create function pintheory_sync.string_valid(p_value jsonb, p_min integer, p_max integer)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v text;
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'string' then return false; end if;
    v := p_value #>> '{}';
    return pg_catalog.char_length(v) between p_min and p_max
       and (p_min = 0 or pg_catalog.length(pg_catalog.btrim(v)) > 0);
end;
$$;

create function pintheory_sync.number_valid(p_value jsonb, p_min numeric, p_max numeric, p_integer boolean default false)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v numeric;
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'number' then return false; end if;
    v := p_value::text::numeric;
    return v between p_min and p_max and (not p_integer or v = pg_catalog.trunc(v));
exception when others then return false;
end;
$$;

create function pintheory_sync.date_valid(p_value jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v text;
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'string' then return false; end if;
    v := p_value #>> '{}';
    if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$' then
        return false;
    end if;
    perform v::timestamptz;
    return true;
exception when others then return false;
end;
$$;

create function pintheory_sync.uuid_string_valid(p_value jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'string'
       or (p_value #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        return false;
    end if;
    perform (p_value #>> '{}')::uuid;
    return true;
exception when others then return false;
end;
$$;

create function pintheory_sync.int_array_valid(p_value jsonb, p_min integer, p_max integer, p_count integer default null, p_unique boolean default false)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare v jsonb; n integer; seen integer[] := '{}'; x integer;
begin
    if p_value is null or pg_catalog.jsonb_typeof(p_value) is distinct from 'array' then return false; end if;
    n := pg_catalog.jsonb_array_length(p_value);
    if p_count is not null and n <> p_count then return false; end if;
    for v in select value from pg_catalog.jsonb_array_elements(p_value) loop
        if not pintheory_sync.number_valid(v, p_min, p_max, true) then return false; end if;
        x := (v #>> '{}')::integer;
        if p_unique and x = any(seen) then return false; end if;
        seen := pg_catalog.array_append(seen, x);
    end loop;
    return true;
exception when others then return false;
end;
$$;

create function pintheory_sync.payload_valid(p_kind text, p jsonb)
returns boolean language plpgsql immutable set search_path = pg_catalog as $$
declare
    v jsonb;
    item jsonb;
    sub jsonb;
    k text;
    uid uuid;
    ids uuid[] := '{}';
    owners integer := 0;
    count_items integer;
    count_holes integer;
    parsed uuid;
    hole_no integer;
    total_par integer := 0;
    hole_ids integer[] := '{}';
    all_pars_present boolean := true;
begin
    if pg_catalog.jsonb_typeof(p) is distinct from 'object' then return false; end if;

    if p_kind = 'golfer_profile' then
        return pintheory_sync.object_keys_valid(p, array['name'], array['lowHandicapIndex'])
            and pintheory_sync.string_valid(p->'name', 1, 200)
            and (not (p ? 'lowHandicapIndex') or p->'lowHandicapIndex' = 'null'::jsonb
                 or pintheory_sync.number_valid(p->'lowHandicapIndex', -10, 54));

    elsif p_kind = 'custom_club' then
        return pintheory_sync.object_keys_valid(p, array['name','city','country'])
            and pintheory_sync.string_valid(p->'name', 1, 200)
            and pintheory_sync.string_valid(p->'city', 0, 200)
            and pintheory_sync.string_valid(p->'country', 1, 100);

    elsif p_kind = 'custom_course' then
        return pintheory_sync.object_keys_valid(p, array['clubRecordID','clubName','name'])
            and pintheory_sync.uuid_string_valid(p->'clubRecordID')
            and pintheory_sync.string_valid(p->'clubName', 1, 200)
            and pintheory_sync.string_valid(p->'name', 1, 200);

    elsif p_kind = 'custom_tee' then
        if not pintheory_sync.object_keys_valid(p,
            array['clubRecordID','courseRecordID','clubName','courseName','name','holes','par','courseRating','slopeRating'],
            array['ratingSex','holePars','holeHandicapIndices'])
           or not pintheory_sync.uuid_string_valid(p->'clubRecordID')
           or not pintheory_sync.uuid_string_valid(p->'courseRecordID')
           or not pintheory_sync.string_valid(p->'clubName', 1, 200)
           or not pintheory_sync.string_valid(p->'courseName', 1, 200)
           or not pintheory_sync.string_valid(p->'name', 1, 100)
           or not pintheory_sync.number_valid(p->'holes', 9, 18, true)
           or not pintheory_sync.number_valid(p->'par', 1, 108, true)
           or not pintheory_sync.number_valid(p->'courseRating', 25, 90)
           or not pintheory_sync.number_valid(p->'slopeRating', 55, 160, true) then return false; end if;
        count_holes := (p->>'holes')::integer;
        if p ? 'ratingSex' and p->'ratingSex' <> 'null'::jsonb
           and (not pintheory_sync.string_valid(p->'ratingSex', 1, 16)
            or p->>'ratingSex' <> all(array['male','female'])) then return false; end if;
        if p ? 'holePars' and p->'holePars' <> 'null'::jsonb then
            if pg_catalog.jsonb_typeof(p->'holePars') is distinct from 'array'
               or pg_catalog.jsonb_array_length(p->'holePars') <> count_holes then return false; end if;
            total_par := 0;
            for item in select value from pg_catalog.jsonb_array_elements(p->'holePars') loop
                if not pintheory_sync.number_valid(item, 3, 8, true) then return false; end if;
                total_par := total_par + (item #>> '{}')::integer;
            end loop;
            if total_par <> (p->>'par')::integer then return false; end if;
        end if;
        if p ? 'holeHandicapIndices' and p->'holeHandicapIndices' <> 'null'::jsonb
           and not pintheory_sync.int_array_valid(p->'holeHandicapIndices', 1, 18, count_holes, true) then return false; end if;
        return true;

    elsif p_kind = 'wedge' then
        if not pintheory_sync.object_keys_valid(p,
            array['name','brand','notes','fullCarry','isInBag','fullCarryUserProvided','carryOverrides'])
           or not pintheory_sync.string_valid(p->'name', 1, 100)
           or not pintheory_sync.string_valid(p->'brand', 0, 200)
           or not pintheory_sync.string_valid(p->'notes', 0, 4096)
           or not pintheory_sync.number_valid(p->'fullCarry', 0, 1000)
           or pg_catalog.jsonb_typeof(p->'isInBag') is distinct from 'boolean'
           or pg_catalog.jsonb_typeof(p->'fullCarryUserProvided') is distinct from 'boolean'
           or pg_catalog.jsonb_typeof(p->'carryOverrides') is distinct from 'object' then return false; end if;
        for k, v in select key, value from pg_catalog.jsonb_each(p->'carryOverrides') loop
            if k <> all(array['knockdown.half','knockdown.threeQuarter','knockdown.full',
                              'stock.half','stock.threeQuarter','stock.full',
                              'high.half','high.threeQuarter','high.full'])
               or not pintheory_sync.number_valid(v, 0, 1000) then return false; end if;
        end loop;
        return true;

    elsif p_kind = 'handicap_round' then
        if not pintheory_sync.object_keys_valid(p,
            array['date','clubName','courseName','teeName','holes','inputMode','par','courseRating','slopeRating','pcc','notes'],
            array['adjustedGrossScore','stablefordPoints','handicapDifferential','holeScores','holePars','holeHandicapIndices','sourceSavedRoundID'])
           or not pintheory_sync.date_valid(p->'date')
           or not pintheory_sync.string_valid(p->'clubName', 0, 200)
           or not pintheory_sync.string_valid(p->'courseName', 0, 200)
           or not pintheory_sync.string_valid(p->'teeName', 0, 100)
           or not pintheory_sync.number_valid(p->'holes', 1, 18, true)
           or not pintheory_sync.string_valid(p->'inputMode', 1, 40)
           or p->>'inputMode' <> all(array['adjustedGrossScore','stablefordPoints','holeByHole'])
           or not pintheory_sync.number_valid(p->'par', 1, 108, true)
           or (p->>'clubName' = '' and p->>'courseName' = '' and
               (not pintheory_sync.number_valid(p->'courseRating', 0, 0)
                or not pintheory_sync.number_valid(p->'slopeRating', 55, 160, true)))
           or (p->>'clubName' <> '' and p->>'courseName' <> '' and
               (not pintheory_sync.number_valid(p->'courseRating', 25, 90)
                or not pintheory_sync.number_valid(p->'slopeRating', 55, 160, true)))
           or (p->>'clubName' = '' and p->>'courseName' <> '')
           or (p->>'clubName' <> '' and p->>'courseName' = '')
           or not pintheory_sync.number_valid(p->'pcc', -1, 3)
           or not pintheory_sync.string_valid(p->'notes', 0, 8192) then return false; end if;
        count_holes := (p->>'holes')::integer;
        if p ? 'adjustedGrossScore' and p->'adjustedGrossScore' <> 'null'::jsonb
           and not pintheory_sync.number_valid(p->'adjustedGrossScore', 1, 1000, true) then return false; end if;
        if p ? 'stablefordPoints' and p->'stablefordPoints' <> 'null'::jsonb
           and not pintheory_sync.number_valid(p->'stablefordPoints', 0, 1000, true) then return false; end if;
        if p ? 'handicapDifferential' and p->'handicapDifferential' <> 'null'::jsonb
           and not pintheory_sync.number_valid(p->'handicapDifferential', -100, 200) then return false; end if;
        if p ? 'sourceSavedRoundID' and p->'sourceSavedRoundID' <> 'null'::jsonb
           and not pintheory_sync.uuid_string_valid(p->'sourceSavedRoundID') then return false; end if;
        if p ? 'holeScores' and p->'holeScores' <> 'null'::jsonb
           and not pintheory_sync.int_array_valid(p->'holeScores', 1, 30, count_holes) then return false; end if;
          if p ? 'holePars' and p->'holePars' <> 'null'::jsonb
              and not pintheory_sync.int_array_valid(p->'holePars', 3, 8, count_holes) then return false; end if;
        if p ? 'holeHandicapIndices' and p->'holeHandicapIndices' <> 'null'::jsonb
           and not pintheory_sync.int_array_valid(p->'holeHandicapIndices', 1, 18, count_holes, true) then return false; end if;
          if p->>'inputMode' = 'adjustedGrossScore'
              and (not (p ? 'adjustedGrossScore') or p->'adjustedGrossScore' = 'null'::jsonb)
              and (not (p ? 'handicapDifferential') or p->'handicapDifferential' = 'null'::jsonb) then return false; end if;
          if p->>'inputMode' = 'stablefordPoints'
              and (not (p ? 'stablefordPoints') or p->'stablefordPoints' = 'null'::jsonb) then return false; end if;
          if p->>'inputMode' = 'holeByHole'
              and (not (p ? 'holeScores') or p->'holeScores' = 'null'::jsonb
                     or not (p ? 'holePars') or p->'holePars' = 'null'::jsonb
                     or not (p ? 'holeHandicapIndices') or p->'holeHandicapIndices' = 'null'::jsonb) then return false; end if;
        return true;

    elsif p_kind = 'played_round' then
        if not pintheory_sync.object_keys_valid(p,
            array['version','date','reference','holes','players','game','detailMode','allowance','scores'], array['notes'])
           or not pintheory_sync.number_valid(p->'version', 1, 1, true)
           or not pintheory_sync.date_valid(p->'date')
           or not pintheory_sync.object_keys_valid(p->'reference',
                array['clubName','courseName','city','region','holeCount','totalPar','teeName','teeSex','courseRating','slopeRating'])
           or not pintheory_sync.string_valid(p#>'{reference,clubName}', 0, 200)
           or not pintheory_sync.string_valid(p#>'{reference,courseName}', 0, 200)
           or not pintheory_sync.string_valid(p#>'{reference,city}', 0, 200)
           or not pintheory_sync.string_valid(p#>'{reference,region}', 0, 200)
           or not pintheory_sync.number_valid(p#>'{reference,holeCount}', 1, 18, true)
           or not pintheory_sync.number_valid(p#>'{reference,totalPar}', 1, 108, true)
           or not pintheory_sync.string_valid(p#>'{reference,teeName}', 0, 100)
           or not pintheory_sync.string_valid(p#>'{reference,teeSex}', 0, 32)
           or not pintheory_sync.number_valid(p#>'{reference,courseRating}', 0, 200)
           or not pintheory_sync.number_valid(p#>'{reference,slopeRating}', 0, 200, true)
           or pg_catalog.jsonb_typeof(p->'holes') is distinct from 'array'
           or pg_catalog.jsonb_typeof(p->'players') is distinct from 'array'
           or pg_catalog.jsonb_typeof(p->'scores') is distinct from 'object'
           or not pintheory_sync.string_valid(p->'game', 1, 40)
           or p->>'game' <> all(array['Stroke play','Stableford'])
           or not pintheory_sync.string_valid(p->'detailMode', 1, 40)
           or p->>'detailMode' <> all(array['Detailed','Strokes only'])
           or not pintheory_sync.number_valid(p->'allowance', 0, 100, true)
           or (p ? 'notes' and p->'notes' <> 'null'::jsonb and not pintheory_sync.string_valid(p->'notes', 0, 8192)) then return false; end if;

        count_holes := pg_catalog.jsonb_array_length(p->'holes');
        count_items := pg_catalog.jsonb_array_length(p->'players');
        if count_holes < 1 or count_holes > 18 or count_items < 1 or count_items > 8
           or count_holes <> (p#>>'{reference,holeCount}')::integer then return false; end if;
        total_par := 0;
        for item in select value from pg_catalog.jsonb_array_elements(p->'holes') loop
            if not pintheory_sync.object_keys_valid(item, array['number'], array['par','strokeIndex'])
               or not pintheory_sync.number_valid(item->'number', 1, 18, true) then return false; end if;
            hole_no := (item->>'number')::integer;
            if hole_no = any(hole_ids) then return false; end if;
            hole_ids := pg_catalog.array_append(hole_ids, hole_no);
            if item ? 'par' and item->'par' <> 'null'::jsonb then
                if not pintheory_sync.number_valid(item->'par', 3, 6, true) then return false; end if;
                total_par := total_par + (item->>'par')::integer;
            else
                all_pars_present := false;
            end if;
            if item ? 'strokeIndex' and item->'strokeIndex' <> 'null'::jsonb
               and not pintheory_sync.number_valid(item->'strokeIndex', 1, 18, true) then return false; end if;
        end loop;
        if all_pars_present and total_par <> (p#>>'{reference,totalPar}')::integer then return false; end if;

        for item in select value from pg_catalog.jsonb_array_elements(p->'players') loop
            if not pintheory_sync.object_keys_valid(item, array['id','name','isOwner'], array['handicapIndex','keepsDetailedScore'])
               or not pintheory_sync.uuid_string_valid(item->'id')
               or not pintheory_sync.string_valid(item->'name', 1, 200)
               or pg_catalog.jsonb_typeof(item->'isOwner') is distinct from 'boolean' then return false; end if;
            uid := (item->>'id')::uuid;
            if uid = any(ids) then return false; end if;
            ids := pg_catalog.array_append(ids, uid);
            if (item->>'isOwner')::boolean then owners := owners + 1; end if;
            if item ? 'handicapIndex' and item->'handicapIndex' <> 'null'::jsonb
               and not pintheory_sync.number_valid(item->'handicapIndex', -10, 54) then return false; end if;
            if item ? 'keepsDetailedScore' and item->'keepsDetailedScore' <> 'null'::jsonb
               and pg_catalog.jsonb_typeof(item->'keepsDetailedScore') is distinct from 'boolean' then return false; end if;
        end loop;
        if owners <> 1 then return false; end if;

        for k, v in select key, value from pg_catalog.jsonb_each(p->'scores') loop
                if k !~* '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([1-9][0-9]?)$'
               or not pintheory_sync.object_keys_valid(v, array['strokes','fairway'], array['putts','bunkerShots','penalties'])
               or not pintheory_sync.number_valid(v->'strokes', 1, 30, true)
                    or not pintheory_sync.string_valid(v->'fairway', 1, 32)
               or v->>'fairway' <> all(array['Not recorded','Yes','No','Left','Right','Long','Short','N/A']) then return false; end if;
            parsed := pg_catalog.split_part(k, ':', 1)::uuid;
            hole_no := pg_catalog.split_part(k, ':', 2)::integer;
            if not (parsed = any(ids)) or not (hole_no = any(hole_ids)) then return false; end if;
            if v ? 'putts' and v->'putts' <> 'null'::jsonb
               and not pintheory_sync.number_valid(v->'putts', 0, (v->>'strokes')::numeric, true) then return false; end if;
            if v ? 'bunkerShots' and v->'bunkerShots' <> 'null'::jsonb
               and not pintheory_sync.number_valid(v->'bunkerShots', 0, (v->>'strokes')::numeric, true) then return false; end if;
            if v ? 'penalties' and v->'penalties' <> 'null'::jsonb
               and not pintheory_sync.number_valid(v->'penalties', 0, (v->>'strokes')::numeric, true) then return false; end if;
            if coalesce((v->>'putts')::integer, 0) + coalesce((v->>'penalties')::integer, 0) > (v->>'strokes')::integer then return false; end if;
        end loop;
        return true;
    end if;

    -- club_profile, flag_position and unknown kinds are not part of the approved
    -- sync surface; add explicit DTOs and a later schema migration before enabling them.
    return false;
exception when others then return false;
end;
$$;

create function pintheory_sync.custom_references_valid(p_user_id uuid, p_kind text, p_payload jsonb)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare v_club pintheory_sync.records%rowtype; v_course pintheory_sync.records%rowtype;
begin
    if p_kind = 'custom_course' then
        select r.* into v_club from pintheory_sync.records r
        where r.user_id = p_user_id and r.record_id = (p_payload->>'clubRecordID')::uuid
          and r.kind = 'custom_club' and r.deleted_at is null;
        return found and v_club.payload->>'name' = p_payload->>'clubName';
    elsif p_kind = 'custom_tee' then
        select r.* into v_club from pintheory_sync.records r
        where r.user_id = p_user_id and r.record_id = (p_payload->>'clubRecordID')::uuid
          and r.kind = 'custom_club' and r.deleted_at is null;
        if not found or v_club.payload->>'name' <> p_payload->>'clubName' then return false; end if;
        select r.* into v_course from pintheory_sync.records r
        where r.user_id = p_user_id and r.record_id = (p_payload->>'courseRecordID')::uuid
          and r.kind = 'custom_course' and r.deleted_at is null;
        return found and v_course.payload->>'clubRecordID' = p_payload->>'clubRecordID'
            and v_course.payload->>'clubName' = p_payload->>'clubName'
            and v_course.payload->>'name' = p_payload->>'courseName';
    end if;
    return true;
exception when others then return false;
end;
$$;
alter function pintheory_sync.custom_references_valid(uuid, text, jsonb) owner to postgres;

create function pintheory_sync.record_payload_valid(p_record jsonb)
returns boolean language sql immutable set search_path = pg_catalog as $$
    select coalesce(pg_catalog.jsonb_typeof(p_record) = 'object'
       and p_record ? 'kind' and p_record ? 'payload'
       and pintheory_sync.payload_valid(p_record->>'kind', p_record->'payload'), false);
$$;

create function pintheory_sync.receipt_payloads_valid(p_receipt jsonb)
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
       or not pintheory_sync.payload_valid(v_kind, v_request->'payload') then return false;
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

create function pintheory_sync.validate_mutation_receipt()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin
    if not pintheory_sync.receipt_payloads_valid(pg_catalog.jsonb_build_object(
        'mutation_id', new.mutation_id, 'request', new.request, 'response', new.response)) then
        raise exception using errcode = '22023', message = 'invalid_sync_receipt';
    end if;
    return new;
end;
$$;

create trigger mutation_receipts_domain_validation
    before insert on pintheory_sync.mutation_receipts
    for each row execute function pintheory_sync.validate_mutation_receipt();

-- A trigger gives both the RPC and any future trusted write path identical
-- validation. Tombstones keep the last valid payload and need no parent lookup.
create function pintheory_sync.validate_record_payload()
returns trigger language plpgsql set search_path = pg_catalog as $$
declare v_children integer;
begin
    if not pintheory_sync.payload_valid(new.kind, new.payload) then
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
alter function pintheory_sync.validate_record_payload() owner to postgres;

alter function pintheory_sync.validate_mutation_receipt() owner to postgres;

-- Refuse to bless already stored arbitrary JSON. No data is rewritten or deleted.
do $$
begin
    if exists (select 1 from pintheory_sync.records r where not pintheory_sync.payload_valid(r.kind, r.payload)) then
        raise exception 'existing sync records fail strict DTO validation; inspect disposable staging data before migration';
    end if;
    if exists (select 1 from pintheory_sync.records r
        where r.deleted_at is null
          and not pintheory_sync.custom_references_valid(r.user_id, r.kind, r.payload)) then
        raise exception 'existing active custom records have invalid parent links; inspect disposable staging data before migration';
    end if;
    if exists (select 1 from pintheory_sync.change_events e where not pintheory_sync.record_payload_valid(e.record)) then
        raise exception 'existing sync events fail strict DTO validation; inspect disposable staging data before migration';
    end if;
    if exists (select 1 from pintheory_sync.mutation_receipts r where not pintheory_sync.receipt_payloads_valid(
        pg_catalog.jsonb_build_object('mutation_id', r.mutation_id, 'request', r.request, 'response', r.response))) then
        raise exception 'existing sync receipts fail strict DTO validation; inspect disposable staging data before migration';
    end if;
end;
$$;

alter table pintheory_sync.records
    add constraint records_domain_payload_valid
    check (pintheory_sync.payload_valid(kind, payload)) not valid;
alter table pintheory_sync.records validate constraint records_domain_payload_valid;
alter table pintheory_sync.change_events
    add constraint change_events_domain_payload_valid
    check (pintheory_sync.record_payload_valid(record)) not valid;
alter table pintheory_sync.change_events validate constraint change_events_domain_payload_valid;
create trigger records_domain_validation
    before insert or update of kind, payload, deleted_at on pintheory_sync.records
    for each row execute function pintheory_sync.validate_record_payload();

-- Ensure the existing PostgREST entry point executes private helpers as the
-- trusted postgres owner, independent of the role that originally applied v1.
alter function public.pintheory_sync_mutate(uuid, uuid, text, text, text, integer, jsonb) owner to postgres;
revoke all on function public.pintheory_sync_mutate(uuid, uuid, text, text, text, integer, jsonb)
    from public, anon, authenticated, service_role;
grant execute on function public.pintheory_sync_mutate(uuid, uuid, text, text, text, integer, jsonb)
    to authenticated;

revoke all on all functions in schema pintheory_sync from public, anon, authenticated, service_role;
-- The existing SECURITY DEFINER mutation function owner must be able to call the
-- private validation helpers; no client role receives private-schema access.

commit;
