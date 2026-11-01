-- Course-wide GPXZ raster tiles. Packed grids live in the private course-terrain
-- Storage bucket; the cache row stores only their manifest. Provider settings,
-- budgets, cooldowns and existing gpxz:sample rows are unchanged.
begin;

do $$ begin
    if pg_catalog.to_regprocedure('public.pintheory_data_finish(text,uuid,jsonb,text,jsonb)') is null then
        raise exception 'shared data cache migration is required before course terrain';
    end if;
end $$;

create or replace function pintheory_data.key_valid(p_key text, p_provider text)
returns boolean language sql immutable security definer set search_path = pg_catalog as $$
    select coalesce(case p_provider
        when 'golf' then p_key ~ '^golf:v1:((detail|coordinates):[A-Za-z0-9_-]{1,100}|(clubs|courses):[a-f0-9]{64})$'
        when 'gpxz' then p_key ~ '^gpxz:(sample|raster):v1:[a-f0-9]{64}$'
        else false end, false);
$$;

create or replace function public.pintheory_data_finish(
    p_key text, p_token uuid, p_body jsonb, p_dataset_version text default null,
    p_metadata jsonb default '{}'
)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_now timestamptz;
    v_provider text;
    v_id text;
begin
    perform pintheory_data.require_service();
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    -- Expiry alone does not fence out a late owner; resolution/success/failure or
    -- a successor token does. Validate only after the fencing check.
    if not exists (select 1 from pintheory_data.jobs where key = p_key
        and token = p_token and state = 'dispatched') then return false; end if;
    v_provider := case when pintheory_data.key_valid(p_key,'golf') then 'golf'
                       when pintheory_data.key_valid(p_key,'gpxz') then 'gpxz' end;
    if v_provider is null or pg_catalog.jsonb_typeof(p_body) is distinct from 'object'
        or pg_catalog.octet_length(p_body::text) > 4194304
        or pg_catalog.octet_length(p_dataset_version) > 200
        or pg_catalog.jsonb_typeof(p_metadata) is distinct from 'object'
        or (p_metadata - array['profileLengthMeters','courseID']) <> '{}'::jsonb then
        return false;
    end if;
    if p_metadata ? 'courseID' and (pg_catalog.jsonb_typeof(p_metadata->'courseID') <> 'string'
        or (p_metadata->>'courseID') !~ '^[A-Za-z0-9_-]{1,100}$') then return false; end if;
    if p_metadata ? 'profileLengthMeters' then
        if pg_catalog.jsonb_typeof(p_metadata->'profileLengthMeters') <> 'number' then return false; end if;
        if (p_metadata->>'profileLengthMeters')::numeric not between 0 and 100000000 then return false; end if;
    end if;
    if v_provider = 'golf' then
        if p_metadata <> '{}'::jsonb then return false; end if;
        if p_key ~ '^golf:v1:(detail|coordinates):' then
            v_id := pg_catalog.split_part(p_key, ':', 4);
            if p_body->>'courseID' is distinct from v_id then return false; end if;
            if p_key like 'golf:v1:coordinates:%'
                and pg_catalog.jsonb_typeof(p_body->'coordinates') is distinct from 'array' then return false; end if;
        elsif p_key like 'golf:v1:courses:%' then
            if pg_catalog.jsonb_typeof(p_body->'courses') is distinct from 'array' then return false; end if;
        elsif pg_catalog.jsonb_typeof(p_body->'clubs') is distinct from 'array' then return false;
        end if;
    elsif p_key like 'gpxz:raster:%' then
        -- Manifest only: the packed grid is a content-addressed Storage object.
        if p_metadata ? 'profileLengthMeters'
            or p_body->>'format' is distinct from 'pttr-v1'
            or coalesce(p_body->>'sha256', '') !~ '^[a-f0-9]{64}$'
            or p_body->>'storagePath' is distinct from (p_body->>'sha256') || '.pttr' then return false; end if;
    else
        if pg_catalog.jsonb_typeof(p_body->'results') is distinct from 'array' then return false; end if;
        if pg_catalog.jsonb_array_length(p_body->'results') not between 2 and 512 then return false; end if;
    end if;
    -- Full provider/sample geometry validation belongs to Edge. JSONB preserves
    -- numeric values, not original JSON whitespace/key order. Never rewrite body.
    v_now := pg_catalog.clock_timestamp();
    insert into pintheory_data.responses(key, provider, body, fetched_at, dataset_version, metadata)
        values (p_key, v_provider, p_body, v_now, p_dataset_version, p_metadata)
        on conflict (key) do update set body = excluded.body, fetched_at = excluded.fetched_at,
            dataset_version = excluded.dataset_version, metadata = excluded.metadata;
    if v_provider = 'gpxz' and p_metadata ? 'courseID' then
        insert into pintheory_data.elevation_courses(key, course_id)
            values (p_key, p_metadata->>'courseID') on conflict do nothing;
    end if;
    update pintheory_data.jobs set state = 'complete', until = v_now where key = p_key;
    insert into pintheory_data.traffic(day, provider, fetched)
        values ((v_now at time zone 'UTC')::date, v_provider, 1)
        on conflict (day, provider) do update set fetched = pintheory_data.traffic.fetched + 1;
    return true;
end;
$$;

-- Private: no anon/authenticated policies; only the Edge service role reads or writes.
do $$ begin
    if pg_catalog.to_regclass('storage.buckets') is not null then
        insert into storage.buckets(id, name, public) values ('course-terrain', 'course-terrain', false)
            on conflict (id) do update set public = false;
    end if;
end $$;

commit;
