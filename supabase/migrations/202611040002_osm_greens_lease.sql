-- OpenStreetMap greens: public Overpass servers often need 30 s+ per query, so osm jobs get a
-- 150 s lease. The data is free, so an expired osm job is simply claimed again instead of
-- needing operator resolution, and at most two run at once (Overpass allows two per IP)
-- without taking concurrency from paid providers.
begin;

do $$ begin
    if not pintheory_data.key_valid('osm:greens:v1:A', 'osm') then
        raise exception 'OpenStreetMap green outlines migration is required first';
    end if;
end $$;

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
    v_osm boolean;
begin
    perform pintheory_data.require_service();
    if p_provider is null or p_provider not in ('golf','gpxz','lantmateriet','osm') then
        raise exception using errcode = '22023', message = 'invalid_provider';
    end if;
    v_osm := p_provider = 'osm';
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
                if found and v_job.state = 'dispatched' and v_job.until > v_now then
                    update pintheory_data.traffic set coalesced = coalesced + 1
                        where day = v_day and provider = p_provider;
                    return pg_catalog.jsonb_build_object('status','PENDING','retryAfter',1);
                elsif found and v_job.state = 'dispatched' and not v_osm then
                    v_status := 'UNKNOWN';
                elsif v_job.state = 'failed' and v_job.until > v_now then
                    v_status := 'COOLDOWN';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from v_job.until - v_now))::integer);
                elsif not v_settings.enabled then
                    v_status := 'DISABLED';
                elsif v_settings.cooldown_until > v_now then
                    v_status := 'COOLDOWN';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from v_settings.cooldown_until - v_now))::integer);
                elsif v_user.attempts >= 100
                      or coalesce((v_user.provider_attempts->>p_provider)::integer, 0)
                         >= least(100, greatest(10, v_settings.daily_limit / 5)) then
                    v_status := 'RATE_LIMIT';
                    v_retry := greatest(1, pg_catalog.ceil(extract(epoch from
                        ((v_day + 1)::timestamp at time zone 'UTC') - v_now))::integer);
                elsif coalesce((select attempts from pintheory_data.usage
                    where provider = p_provider and day = v_day), 0) >= v_settings.daily_limit then
                    v_status := 'BUDGET';
                elsif (select pg_catalog.count(*) from pintheory_data.jobs
                    where state = 'dispatched' and until > v_now and (key like 'osm:%') = v_osm)
                    >= case when v_osm then 2 else 4 end then
                    v_status := 'RATE_LIMIT';
                    v_retry := 2;
                else
                    insert into pintheory_data.usage(provider, day, attempts) values (p_provider, v_day, 1)
                        on conflict (provider, day) do update set attempts = pintheory_data.usage.attempts + 1;
                    update pintheory_data.per_user_usage set attempts = attempts + 1,
                        provider_attempts = pg_catalog.jsonb_set(provider_attempts, array[p_provider],
                            pg_catalog.to_jsonb(coalesce((provider_attempts->>p_provider)::integer, 0) + 1))
                        where user_id = p_user_id and day = v_day;
                    v_token := pg_catalog.gen_random_uuid();
                    insert into pintheory_data.jobs(key, token, state, until)
                        values (p_key, v_token, 'dispatched',
                            v_now + case when v_osm then interval '150 seconds' else interval '60 seconds' end)
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

commit;
