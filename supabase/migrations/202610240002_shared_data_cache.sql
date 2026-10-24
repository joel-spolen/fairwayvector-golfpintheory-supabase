-- Forward-only. Requires the existing pintheory_sync.accounts/Auth migrations.
-- Private schema: do NOT expose through PostgREST or Realtime. No provider secrets.
-- No HTTP occurs here. CLAIMED reserves an attempt BEFORE dispatch; commit the RPC
-- before sending HTTP. A crashed/expired dispatch is UNKNOWN indefinitely, not a
-- lease that authorizes another paid request. Only explicit operator resolution
-- permits retry. Counters never refund uncertain, failed or resolved attempts.
begin;

do $$ begin
    if pg_catalog.to_regclass('pintheory_sync.accounts') is null then
        raise exception 'sync account migrations required';
    end if;
end $$;

create schema pintheory_data authorization postgres;
revoke all on schema pintheory_data from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_data
    revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_data
    revoke all on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_data
    revoke all on sequences from public, anon, authenticated, service_role;

create function pintheory_data.key_valid(p_key text, p_provider text)
returns boolean language sql immutable security definer set search_path = pg_catalog as $$
    select coalesce(case p_provider
        when 'golf' then p_key ~ '^golf:v1:((detail|coordinates):[A-Za-z0-9_-]{1,100}|(clubs|courses):[a-f0-9]{64})$'
        when 'gpxz' then p_key ~ '^gpxz:sample:v1:[a-f0-9]{64}$'
        else false end, false);
$$;

create table pintheory_data.responses (
    key text primary key,
    provider text not null check (provider in ('golf','gpxz')),
    body jsonb not null check (pg_catalog.jsonb_typeof(body) = 'object'
        and pg_catalog.octet_length(body::text) <= 4194304),
    fetched_at timestamptz not null,
    dataset_version text check (pg_catalog.octet_length(dataset_version) <= 200),
    metadata jsonb not null default '{}' check (pg_catalog.jsonb_typeof(metadata) = 'object'),
    check (pintheory_data.key_valid(key, provider))
);
create index responses_provider on pintheory_data.responses(provider);
create table pintheory_data.jobs (
    key text primary key,
    token uuid not null,
    state text not null check (state in ('dispatched','complete','failed')),
    until timestamptz not null,
    check (pintheory_data.key_valid(key, 'golf') or pintheory_data.key_valid(key, 'gpxz'))
);
create index jobs_dispatched_until on pintheory_data.jobs(until) where state = 'dispatched';
create table pintheory_data.settings (
    provider text primary key check (provider in ('golf','gpxz')),
    enabled boolean not null default false,
    daily_limit integer not null default 100 check (daily_limit between 0 and 1000000),
    cooldown_until timestamptz,
    failure_cooldown_seconds integer not null default 300
        check (failure_cooldown_seconds between 1 and 86400)
);
insert into pintheory_data.settings(provider) values ('golf'), ('gpxz');
create table pintheory_data.usage (
    provider text not null references pintheory_data.settings(provider),
    day date not null,
    attempts bigint not null default 0 check (attempts >= 0),
    primary key (provider, day)
);
create table pintheory_data.traffic (
    day date not null,
    provider text not null references pintheory_data.settings(provider),
    received bigint not null default 0 check (received >= 0),
    hits bigint not null default 0 check (hits >= 0),
    fetched bigint not null default 0 check (fetched >= 0),
    coalesced bigint not null default 0 check (coalesced >= 0),
    errors bigint not null default 0 check (errors >= 0),
    primary key (day, provider)
);
create table pintheory_data.per_user_usage (
    user_id uuid not null references auth.users(id) on delete cascade,
    day date not null,
    requests bigint not null default 0 check (requests >= 0),
    attempts bigint not null default 0 check (attempts between 0 and 100),
    primary key (user_id, day)
);
create index per_user_usage_retention on pintheory_data.per_user_usage(day);
create table pintheory_data.elevation_courses (
    key text not null references pintheory_data.responses(key) on delete cascade,
    course_id text not null check (course_id ~ '^[A-Za-z0-9_-]{1,100}$'),
    primary key (key, course_id)
);
create index elevation_courses_course on pintheory_data.elevation_courses(course_id);
create table pintheory_data.meta (
    singleton boolean primary key default true check (singleton),
    tracking_started_at timestamptz not null default pg_catalog.clock_timestamp(),
    resolutions bigint not null default 0 check (resolutions >= 0),
    last_resolved_at timestamptz,
    retention_day date
);
insert into pintheory_data.meta(singleton) values (true);

-- All mutations share this transaction lock (namespace/key constants). Initial
-- scale deliberately favors simple serializable reservations over parallelism.
-- Every caller obtains it BEFORE reading clock_timestamp, so lock wait time
-- cannot extend a dispatch or accidentally use yesterday's spending bucket.
create function pintheory_data.require_service()
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode = '42501', message = 'service_role_required';
    end if;
end;
$$;

create function pintheory_data.user_allowed(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
    perform pintheory_data.require_service();
    -- Locks linearize existing account blocking/deletion and Auth changes with
    -- claim completion. Missing sync row is allowed, never lazily created here.
    perform 1 from auth.users u where u.id = p_user_id
        and u.is_anonymous is false and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= pg_catalog.clock_timestamp())
        for share;
    if not found then return false; end if;
    perform 1 from pintheory_sync.accounts a where a.user_id = p_user_id for share;
    return not exists (select 1 from pintheory_sync.accounts a
        where a.user_id = p_user_id and a.state in ('blocked','deleting'));
end;
$$;

-- Automatic, once-per-UTC-day lazy retention on claims/admin reads; no scheduler
-- dependency. Keeps today and 29 preceding days of UUID-based rate telemetry.
-- Idle databases are swept on the next service request (not a wall-clock TTL).
-- Aggregate usage/traffic and the shared cache persist, without user identities.
create function pintheory_data.prune_users(p_today date)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
    if exists (select 1 from pintheory_data.meta where singleton
               and retention_day is distinct from p_today) then
        delete from pintheory_data.per_user_usage where day < p_today - 29;
        update pintheory_data.meta set retention_day = p_today where singleton;
    end if;
end;
$$;

create function public.pintheory_data_claim(
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
    if p_provider is null or p_provider not in ('golf','gpxz') then
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

create function public.pintheory_data_finish(
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

create function public.pintheory_data_fail(
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
    v_provider := case when pintheory_data.key_valid(p_key,'golf') then 'golf' else 'gpxz' end;
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

create function public.pintheory_data_tag(p_key text, p_course_id text)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
    perform pintheory_data.require_service();
    if p_course_id is null or p_course_id !~ '^[A-Za-z0-9_-]{1,100}$' then return false; end if;
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    if not exists (select 1 from pintheory_data.responses where key = p_key and provider = 'gpxz') then
        return false;
    end if;
    insert into pintheory_data.elevation_courses values (p_key,p_course_id) on conflict do nothing;
    return true;
end;
$$;

create function public.pintheory_data_admin_assign(p_key text, p_course_id text)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
    perform pintheory_data.require_service();
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    if not exists (select 1 from pintheory_data.responses where provider = 'golf'
        and key in ('golf:v1:detail:' || p_course_id, 'golf:v1:coordinates:' || p_course_id))
        and not exists (select 1 from pintheory_data.elevation_courses where course_id = p_course_id) then
        return false;
    end if;
    return public.pintheory_data_tag(p_key,p_course_id);
end;
$$;

create function public.pintheory_data_admin_resolve(p_key text, p_confirmation text)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare v_now timestamptz;
begin
    perform pintheory_data.require_service();
    if p_confirmation is distinct from 'ALLOW_PAID_RETRY' then return false; end if;
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    v_now := pg_catalog.clock_timestamp();
    update pintheory_data.jobs set state = 'failed', until = v_now
        where key = p_key and state = 'dispatched' and until <= v_now;
    if not found then return false; end if;
    update pintheory_data.meta set resolutions = resolutions + 1, last_resolved_at = v_now where singleton;
    return true;
end;
$$;

-- Same snapshot fields as AdminStore.snapshot plus the existing admin HTTP
-- provider settings fields. All counts are JSON numbers, never decimal strings.
-- Traffic is RPC events, NOT guaranteed HTTP completions: completed = HIT +
-- successful persisted fetch + rejection/failure. PENDING increments coalesced
-- for waiting claims, NOT served responses, and is excluded from completed.
-- Polling PENDING then HIT can count twice in requests; no HTTP-delivery claim.
-- UTC event days can differ. Bytes = UTF8 body::text (JSONB formatting differs
-- from SQLite's original JSON). Missing original path length is unknown/estimated
-- zero, never geographic coverage. No payloads except bounded endpoint lat/lon.
create function public.pintheory_data_admin_overview(
    p_days integer default 7, p_search text default '', p_page integer default 1
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_now timestamptz;
    v_today date;
    v_days integer := case when p_days >= 0 then p_days else 7 end;
    v_page integer := case when p_page > 0 then p_page else 1 end;
    v_since date;
    v_trend integer;
    v_result jsonb;
begin
    perform pintheory_data.require_service();
    perform pg_catalog.pg_advisory_xact_lock(20261024, 2);
    v_now := pg_catalog.clock_timestamp();
    v_today := (v_now at time zone 'UTC')::date;
    perform pintheory_data.prune_users(v_today);
    v_since := case when v_days = 0 then '-infinity'::date else v_today - (v_days - 1) end;
    v_trend := case when v_days = 0 then 30 else least(v_days,366) end;
    with elevations as materialized (
        select r.key, r.fetched_at,
            case when pg_catalog.jsonb_typeof(r.body->'results') = 'array'
                then pg_catalog.jsonb_array_length(r.body->'results') else 0 end as samples,
            pg_catalog.octet_length(pg_catalog.convert_to(r.body::text,'UTF8')) as bytes,
            coalesce((r.metadata->>'profileLengthMeters')::numeric,0) as length_meters,
            not (r.metadata ? 'profileLengthMeters') as estimated,
            r.body->'results'->0 as start_point, r.body->'results'->-1 as end_point
        from pintheory_data.responses r where r.provider = 'gpxz'
    ), ids as (
        select pg_catalog.split_part(key,':',4) as id from pintheory_data.responses
            where provider = 'golf' and key ~ '^golf:v1:(detail|coordinates):'
        union select course_id from pintheory_data.elevation_courses
    ), search_candidates as (
        select c.value as body, null::text as club_name, null::text as country, r.fetched_at, r.key
        from pintheory_data.responses r cross join lateral pg_catalog.jsonb_array_elements(
            case when pg_catalog.jsonb_typeof(r.body->'courses') = 'array' then r.body->'courses' else '[]'::jsonb end) c
        where r.provider = 'golf' and r.key like 'golf:v1:courses:%'
        union all
        select c.value, b.value->>'clubName', b.value->>'country', r.fetched_at, r.key
        from pintheory_data.responses r cross join lateral pg_catalog.jsonb_array_elements(
            case when pg_catalog.jsonb_typeof(r.body->'clubs') = 'array' then r.body->'clubs' else '[]'::jsonb end) b
        cross join lateral pg_catalog.jsonb_array_elements(
            case when pg_catalog.jsonb_typeof(b.value->'courses') = 'array' then b.value->'courses' else '[]'::jsonb end) c
        where r.provider = 'golf' and r.key like 'golf:v1:clubs:%'
    ), course_rows as materialized (
        select i.id,
            coalesce(nullif(d.body->>'courseName',''),nullif(c.body->>'courseName',''),
                (select nullif(s.body->>'courseName','') from search_candidates s where s.body->>'courseID' = i.id
                 and nullif(s.body->>'courseName','') is not null order by s.fetched_at desc,s.key limit 1), 'Course ' || i.id) as name,
            coalesce(nullif(d.body->>'clubName',''),nullif(c.body->>'clubName',''),
                (select coalesce(nullif(s.body->>'clubName',''),nullif(s.club_name,'')) from search_candidates s
                 where s.body->>'courseID' = i.id and coalesce(nullif(s.body->>'clubName',''),nullif(s.club_name,'')) is not null
                 order by s.fetched_at desc,s.key limit 1),'') as club_name,
            coalesce(nullif(d.body->>'country',''),nullif(c.body->>'country',''),
                (select coalesce(nullif(s.body->>'country',''),nullif(s.country,'')) from search_candidates s
                 where s.body->>'courseID' = i.id and coalesce(nullif(s.body->>'country',''),nullif(s.country,'')) is not null
                 order by s.fetched_at desc,s.key limit 1),'') as country,
            d.key is not null as has_detail, c.key is not null as has_coordinates,
            case when pg_catalog.jsonb_typeof(c.body->'coordinates') = 'array'
                then pg_catalog.jsonb_array_length(c.body->'coordinates') else 0 end as coordinate_count,
            case when coalesce(nullif(d.body->>'numHoles',''),c.body->>'numHoles') ~ '^[0-9]{1,6}$'
                then coalesce(nullif(d.body->>'numHoles',''),c.body->>'numHoles')::integer else null end as num_holes,
            d.fetched_at as detail_at, c.fetched_at as coordinates_at,
            (select pg_catalog.jsonb_build_object('profiles',pg_catalog.count(*),'samples',coalesce(pg_catalog.sum(e.samples),0),
                'bytes',coalesce(pg_catalog.sum(e.bytes),0),'lengthMeters',coalesce(pg_catalog.sum(e.length_meters),0),
                'lengthEstimated',coalesce(pg_catalog.bool_or(e.estimated),false),
                'lastFetchedAt',pg_catalog.to_char(pg_catalog.max(e.fetched_at) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
             from pintheory_data.elevation_courses l join elevations e on e.key = l.key where l.course_id = i.id) as elevation
        from ids i left join pintheory_data.responses d on d.key = 'golf:v1:detail:' || i.id and d.provider = 'golf'
            left join pintheory_data.responses c on c.key = 'golf:v1:coordinates:' || i.id and c.provider = 'golf'
    ), courses as materialized (
        select id,name,club_name,country,pg_catalog.jsonb_build_object('id',id,'name',name,'clubName',club_name,
            'country',country,'hasDetail',has_detail,'hasCoordinates',has_coordinates,'coordinateCount',coordinate_count,
            'numHoles',num_holes,'detailFetchedAt',pg_catalog.to_char(detail_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'coordinatesFetchedAt',pg_catalog.to_char(coordinates_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'elevation',elevation) as item from course_rows
    ), matching as (
        select * from courses where coalesce(pg_catalog.btrim(p_search),'') = '' or exists (
            select 1 from unnest(array[id,name,club_name,country]) x(value)
            where pg_catalog.strpos(pg_catalog.lower(value),pg_catalog.lower(pg_catalog.btrim(p_search))) > 0)
    ), totals as (
        select coalesce(pg_catalog.sum(received),0) as requests, coalesce(pg_catalog.sum(hits),0) as hits,
            coalesce(pg_catalog.sum(fetched),0) as fetched,coalesce(pg_catalog.sum(coalesced),0) as coalesced,
            coalesce(pg_catalog.sum(errors),0) as errors from pintheory_data.traffic where day between v_since and v_today
    ), provider_usage as (
        select s.*,coalesce((select pg_catalog.sum(u.attempts) from pintheory_data.usage u
            where u.provider=s.provider and u.day between v_since and v_today),0) as calls,
            coalesce((select u.attempts from pintheory_data.usage u where u.provider=s.provider and u.day=v_today),0) as today_calls
        from pintheory_data.settings s
    ), unassigned as materialized (
        select * from elevations e where not exists (select 1 from pintheory_data.elevation_courses l where l.key=e.key)
    ), daily as (
        select v_today - n as day from pg_catalog.generate_series(v_trend-1,0,-1) n
    )
    select pg_catalog.jsonb_build_object(
        'generatedAt',pg_catalog.to_char(v_now at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'trackingStartedAt',(select pg_catalog.to_char(tracking_started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            from pintheory_data.meta where singleton),
        'period',pg_catalog.jsonb_build_object('days',v_days,'label',case when v_days=0 then 'All time'
            when v_days=1 then 'Today' else 'Last ' || v_days || ' days' end),
        'traffic',pg_catalog.jsonb_build_object('requests',t.requests,'completed',t.hits+t.fetched+t.errors,
            'cacheHits',t.hits,'fetched',t.fetched,'coalesced',t.coalesced,'errors',t.errors,
            'upstreamCalls',(select coalesce(pg_catalog.sum(calls),0) from provider_usage),
            'cacheHitRate',t.hits::numeric / nullif(t.hits+t.fetched+t.errors,0)),
        'providers',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',provider,
            'name',case when provider='golf' then 'GolfAPI' else 'GPXZ' end,'upstreamCalls',calls,
            'todayCalls',today_calls,'enabled',enabled,'dailyLimit',daily_limit,
            'cooldownSeconds',greatest(0,pg_catalog.ceil(extract(epoch from cooldown_until-v_now))::integer)) order by provider)
            from provider_usage),
        'daily',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('day',d.day,
            'requests',coalesce((select pg_catalog.sum(received) from pintheory_data.traffic where day=d.day),0),
            'cacheHits',coalesce((select pg_catalog.sum(hits) from pintheory_data.traffic where day=d.day),0),
            'coalesced',coalesce((select pg_catalog.sum(coalesced) from pintheory_data.traffic where day=d.day),0),
            'upstreamCalls',coalesce((select pg_catalog.sum(attempts) from pintheory_data.usage where day=d.day),0),
            'errors',coalesce((select pg_catalog.sum(errors) from pintheory_data.traffic where day=d.day),0)) order by d.day) from daily d),
        'inventory',(select pg_catalog.jsonb_build_object('courseCount',(select pg_catalog.count(*) from courses),
            'elevationProfiles',pg_catalog.count(*),'elevationSamples',coalesce(pg_catalog.sum(samples),0),
            'elevationBytes',coalesce(pg_catalog.sum(bytes),0),'elevationLengthMeters',coalesce(pg_catalog.sum(length_meters),0),
            'lengthEstimated',coalesce(pg_catalog.bool_or(estimated),false),'unassignedProfiles',(select pg_catalog.count(*) from unassigned)) from elevations),
        'courses',pg_catalog.jsonb_build_object('items',coalesce((select pg_catalog.jsonb_agg(item order by name,id)
            from (select * from matching order by name,id limit 25 offset (v_page::bigint-1)*25) p),'[]'::jsonb),
            'total',(select pg_catalog.count(*) from matching),'page',v_page,'pageSize',25),
        'courseOptions',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',id,'name',name) order by name,id)
            from (select id,name from courses order by name,id limit 1000) o),'[]'::jsonb),
        'unassigned',pg_catalog.jsonb_build_object('total',(select pg_catalog.count(*) from unassigned),
            'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('key',key,'samples',samples,'bytes',bytes,
                'lengthMeters',length_meters,'lengthEstimated',estimated,
                'fetchedAt',pg_catalog.to_char(fetched_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'start',pintheory_data.endpoint(start_point),'end',pintheory_data.endpoint(end_point)) order by fetched_at desc,key)
                from (select * from unassigned order by fetched_at desc,key limit 50) u),'[]'::jsonb))
    ) into v_result from totals t;
    return v_result;
end;
$$;

create function pintheory_data.endpoint(p_point jsonb)
returns jsonb language plpgsql immutable security definer set search_path = pg_catalog as $$
begin
    if pg_catalog.jsonb_typeof(p_point->'lat') = 'number' and pg_catalog.jsonb_typeof(p_point->'lon') = 'number' then
        if (p_point->>'lat')::numeric between -90 and 90 and (p_point->>'lon')::numeric between -180 and 180 then
            return pg_catalog.jsonb_build_object('lat',p_point->'lat','lon',p_point->'lon');
        end if;
    end if;
    return null;
end;
$$;

-- Explicit owner, default-deny RLS (no policies), ACLs even against service_role's
-- BYPASSRLS. Only the named public RPCs can be reached by the service role.
do $$ declare r record; begin
    for r in select c.oid::pg_catalog.regclass as name from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='pintheory_data' and c.relkind='r' loop
        execute pg_catalog.format('alter table %s owner to postgres',r.name);
        execute pg_catalog.format('alter table %s enable row level security',r.name);
    end loop;
    for r in select p.oid::pg_catalog.regprocedure as name,n.nspname from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid=p.pronamespace
        where n.nspname='pintheory_data' or (n.nspname='public' and p.proname in (
            'pintheory_data_claim','pintheory_data_finish','pintheory_data_fail','pintheory_data_tag',
            'pintheory_data_admin_assign','pintheory_data_admin_resolve','pintheory_data_admin_overview')) loop
        execute pg_catalog.format('alter function %s owner to postgres',r.name);
        execute pg_catalog.format('revoke all on function %s from public, anon, authenticated, service_role',r.name);
        if r.nspname='public' then
            execute pg_catalog.format('grant execute on function %s to service_role',r.name);
        end if;
    end loop;
end $$;
revoke all on all tables in schema pintheory_data from public, anon, authenticated, service_role;
revoke all on all sequences in schema pintheory_data from public, anon, authenticated, service_role;

comment on table pintheory_data.traffic is
    'UTC RPC event counts, not HTTP completions; coalesced counts PENDING waiters, not served responses. Claim rejections and fenced fail errors; fetched counts successful persistence.';
comment on table pintheory_data.per_user_usage is
    'Rate telemetry only, today + 29 UTC days; lazy daily sweep on claim/overview. Auth hard deletion cascades. No user ownership of shared cache.';
comment on function public.pintheory_data_admin_resolve(text,text) is
    'Operator only: acknowledge ambiguous dispatch and permit paid retry, with aggregate audit and no refund. Never route from a user endpoint.';
commit;