-- Lantmäteriet Markhöjdmodell (1 m, CC BY 4.0, free) as a third cached provider for
-- Swedish course elevation. Same claim/finish/fail fences as GolfAPI and GPXZ.
begin;

do $$ begin
    if pg_catalog.to_regprocedure('public.pintheory_data_finish(text,uuid,jsonb,text,jsonb)') is null
       or not pintheory_data.key_valid('gpxz:raster:v1:' || pg_catalog.repeat('a',64), 'gpxz') then
        raise exception 'course terrain raster migration is required before Lantmäteriet';
    end if;
end $$;

create or replace function pintheory_data.key_valid(p_key text, p_provider text)
returns boolean language sql immutable security definer set search_path = pg_catalog as $$
    select coalesce(case p_provider
        when 'golf' then p_key ~ '^golf:v1:((detail|coordinates):[A-Za-z0-9_-]{1,100}|(clubs|courses):[a-f0-9]{64})$'
        when 'gpxz' then p_key ~ '^gpxz:(sample|raster):v1:[a-f0-9]{64}$'
        when 'lantmateriet' then p_key ~ '^lm:dtm:v1:[a-f0-9]{64}$'
        else false end, false);
$$;

-- Replace the provider/key checks by definition, whatever their generated names.
do $$ declare r record; begin
    for r in select c.conrelid::regclass as tbl, c.conname from pg_catalog.pg_constraint c
        where c.contype = 'c' and c.conrelid in ('pintheory_data.responses'::regclass,
            'pintheory_data.settings'::regclass, 'pintheory_data.jobs'::regclass)
          and pg_catalog.pg_get_constraintdef(c.oid) like '%''gpxz''%'
    loop
        execute pg_catalog.format('alter table %s drop constraint %I', r.tbl, r.conname);
    end loop;
end $$;
alter table pintheory_data.responses add constraint responses_provider_check
    check (provider in ('golf','gpxz','lantmateriet'));
alter table pintheory_data.settings add constraint settings_provider_check
    check (provider in ('golf','gpxz','lantmateriet'));
alter table pintheory_data.jobs add constraint jobs_key_check
    check (pintheory_data.key_valid(key, 'golf') or pintheory_data.key_valid(key, 'gpxz')
        or pintheory_data.key_valid(key, 'lantmateriet'));

-- Free open data, but still budgeted so a fault cannot hammer the agency.
insert into pintheory_data.settings(provider, enabled, daily_limit) values ('lantmateriet', true, 500)
    on conflict (provider) do nothing;

create or replace function public.pintheory_data_claim(
    p_user_id uuid, p_key text, p_provider text, p_cache_only boolean,
    p_max_age_seconds integer default null
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_now timestamptz;
    v_day date;
    v_response pintheory_data.responses%rowtype;
    v_job pintheory_data.jobs%rowtype;
    v_settings pintheory_data.settings%rowtype;
    v_user pintheory_data.per_user_usage%rowtype;
    v_status text;
    v_retry integer;
    v_token uuid;
begin
    perform pintheory_data.require_service();
    if p_provider is null or p_provider not in ('golf','gpxz','lantmateriet') then
        raise exception using errcode = '22023', message = 'invalid_provider';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    v_now := pg_catalog.clock_timestamp();
    v_day := (v_now at time zone 'UTC')::date;
    perform pintheory_data.prune_users(v_day);
    insert into pintheory_data.traffic(day, provider, received) values (v_day, p_provider, 1)
        on conflict (day, provider) do update set received = pintheory_data.traffic.received + 1;

    if not pintheory_data.user_allowed(p_user_id) then
        v_status := 'FORBIDDEN';
    else
        insert into pintheory_data.per_user_usage(user_id, day, requests)
            values (p_user_id, v_day, 1)
            on conflict (user_id, day) do update
            set requests = pintheory_data.per_user_usage.requests + 1
            returning * into v_user;
        if v_user.requests > 10000 then
            v_status := 'RATE_LIMIT';
            v_retry := greatest(1, pg_catalog.ceil(extract(epoch from
                ((v_day + 1)::timestamp at time zone 'UTC') - v_now))::integer);
        elsif not pintheory_data.key_valid(p_key, p_provider) or p_cache_only is null
              or p_max_age_seconds < 0 then
            -- Invalid keys cannot reach paid dispatch or reveal cached data.
            v_status := 'CACHE_MISS';
        else
            select * into strict v_settings from pintheory_data.settings where provider = p_provider;
            select * into v_response from pintheory_data.responses where key = p_key;
            if found and (p_cache_only or not v_settings.enabled or p_max_age_seconds is null
                or v_response.fetched_at > v_now - pg_catalog.make_interval(secs => p_max_age_seconds)) then
                update pintheory_data.traffic set hits = hits + 1 where day = v_day and provider = p_provider;
                return pg_catalog.jsonb_build_object('status','HIT', 'body',v_response.body,
                    'fetchedAt',pg_catalog.to_char(v_response.fetched_at at time zone 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'datasetVersion',v_response.dataset_version);
            end if;
            if p_cache_only then
                v_status := 'CACHE_MISS';
            else
                select * into v_job from pintheory_data.jobs where key = p_key;
                if found and v_job.state = 'dispatched' then
                    if v_job.until > v_now then
                        update pintheory_data.traffic set coalesced = coalesced + 1
                            where day = v_day and provider = p_provider;
                        return pg_catalog.jsonb_build_object('status','PENDING','retryAfter',1);
                    end if;
                    v_status := 'UNKNOWN';
                elsif v_job.state = 'failed' and v_job.until > v_now then
                    v_status := 'COOLDOWN';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from v_job.until - v_now))::integer);
                elsif not v_settings.enabled then
                    v_status := 'DISABLED';
                elsif v_settings.cooldown_until > v_now then
                    v_status := 'COOLDOWN';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from v_settings.cooldown_until - v_now))::integer);
                elsif v_user.attempts >= 100 then
                    v_status := 'RATE_LIMIT';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from
                        ((v_day + 1)::timestamp at time zone 'UTC') - v_now))::integer);
                elsif coalesce((select attempts from pintheory_data.usage
                    where provider = p_provider and day = v_day), 0) >= v_settings.daily_limit then
                    v_status := 'BUDGET';
                elsif (select pg_catalog.count(*) from pintheory_data.jobs
                    where state = 'dispatched' and until > v_now) >= 4 then
                    v_status := 'RATE_LIMIT';
                    v_retry := 2;
                else
                    insert into pintheory_data.usage(provider, day, attempts) values (p_provider, v_day, 1)
                        on conflict (provider, day) do update set attempts = pintheory_data.usage.attempts + 1;
                    update pintheory_data.per_user_usage set attempts = attempts + 1
                        where user_id = p_user_id and day = v_day;
                    v_token := pg_catalog.gen_random_uuid();
                    insert into pintheory_data.jobs(key, token, state, until)
                        values (p_key, v_token, 'dispatched', v_now + interval '60 seconds')
                        on conflict (key) do update set token = excluded.token,
                            state = excluded.state, until = excluded.until;
                    return pg_catalog.jsonb_build_object('status','CLAIMED','token',v_token);
                end if;
            end if;
        end if;
    end if;
    update pintheory_data.traffic set errors = errors + 1 where day = v_day and provider = p_provider;
    return pg_catalog.jsonb_build_object('status',v_status)
        || case when v_retry is null then '{}'::jsonb else pg_catalog.jsonb_build_object('retryAfter',v_retry) end;
end;
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
                       when pintheory_data.key_valid(p_key,'gpxz') then 'gpxz'
                       when pintheory_data.key_valid(p_key,'lantmateriet') then 'lantmateriet' end;
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
    elsif p_key like 'gpxz:raster:%' or v_provider = 'lantmateriet' then
        -- Manifest only: the packed grid is a content-addressed Storage object.
        if p_metadata ? 'profileLengthMeters'
            or p_body->>'format' is distinct from 'pttr-v1'
            or coalesce(p_body->>'sha256', '') !~ '^[a-f0-9]{64}$'
            or p_body->>'storagePath' is distinct from (p_body->>'sha256') || '.pttr' then return false; end if;
    else
        if pg_catalog.jsonb_typeof(p_body->'results') is distinct from 'array' then return false; end if;
        if pg_catalog.jsonb_array_length(p_body->'results') not between 2 and 512 then return false; end if;
    end if;
    v_now := pg_catalog.clock_timestamp();
    insert into pintheory_data.responses(key, provider, body, fetched_at, dataset_version, metadata)
        values (p_key, v_provider, p_body, v_now, p_dataset_version, p_metadata)
        on conflict (key) do update set body = excluded.body, fetched_at = excluded.fetched_at,
            dataset_version = excluded.dataset_version, metadata = excluded.metadata;
    if v_provider in ('gpxz','lantmateriet') and p_metadata ? 'courseID' then
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

create or replace function public.pintheory_data_fail(
    p_key text, p_token uuid, p_provider_wide boolean default true, p_retry_after integer default 300
)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare v_now timestamptz; v_provider text; v_until timestamptz;
begin
    perform pintheory_data.require_service();
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    if not exists (select 1 from pintheory_data.jobs where key = p_key
        and token = p_token and state = 'dispatched') then return false; end if;
    v_now := pg_catalog.clock_timestamp();
    v_provider := case when pintheory_data.key_valid(p_key,'golf') then 'golf'
                       when pintheory_data.key_valid(p_key,'lantmateriet') then 'lantmateriet' else 'gpxz' end;
    v_until := v_now + pg_catalog.make_interval(secs => least(86400, greatest(1, coalesce(p_retry_after,300))));
    update pintheory_data.jobs set state = 'failed', until = v_until where key = p_key;
    if coalesce(p_provider_wide,true) then
        update pintheory_data.settings set cooldown_until = greatest(cooldown_until,v_until)
            where provider = v_provider;
    end if;
    insert into pintheory_data.traffic(day, provider, errors)
        values ((v_now at time zone 'UTC')::date, v_provider, 1)
        on conflict (day, provider) do update set errors = pintheory_data.traffic.errors + 1;
    return true;
end;
$$;

create or replace function public.pintheory_data_tag(p_key text, p_course_id text)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
    perform pintheory_data.require_service();
    if p_course_id is null or p_course_id !~ '^[A-Za-z0-9_-]{1,100}$' then return false; end if;
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    if not exists (select 1 from pintheory_data.responses where key = p_key
        and provider in ('gpxz','lantmateriet')) then
        return false;
    end if;
    insert into pintheory_data.elevation_courses values (p_key,p_course_id) on conflict do nothing;
    return true;
end;
$$;

commit;
