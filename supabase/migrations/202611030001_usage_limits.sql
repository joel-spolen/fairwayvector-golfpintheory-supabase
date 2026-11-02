-- Per-user caps so one account cannot grow sync storage, Storage egress or drain a
-- provider's shared daily budget. Existing data, budgets and fences are unchanged.
begin;

do $$ begin
    if pg_catalog.to_regclass('pintheory_data.per_user_usage') is null
       or pg_catalog.to_regclass('pintheory_sync.mutation_receipts') is null
       or not pintheory_data.key_valid('lm:dtm:v1:' || pg_catalog.repeat('a', 64), 'lantmateriet') then
        raise exception 'Lantmäteriet terrain migration is required before usage limits';
    end if;
end $$;

-- 1. Sync: at most 2000 mutations and 20 MB of receipts per user per UTC day,
-- and 5000 live records per user. PT429 becomes HTTP 429 in PostgREST.
create table pintheory_sync.daily_usage (
    user_id uuid not null references pintheory_sync.accounts(user_id) on delete cascade,
    day date not null,
    mutations integer not null default 0 check (mutations >= 0),
    bytes bigint not null default 0 check (bytes >= 0),
    primary key (user_id, day)
);
alter table pintheory_sync.daily_usage enable row level security;
revoke all on pintheory_sync.daily_usage from public, anon, authenticated, service_role;

-- Every non-replayed mutation (applied or conflict) writes exactly one receipt.
create function pintheory_sync.enforce_daily_usage()
returns trigger language plpgsql set search_path = pg_catalog as $$
declare
    v_day date := (pg_catalog.clock_timestamp() at time zone 'UTC')::date;
    v_bytes bigint := pg_catalog.octet_length(new.request::text) + pg_catalog.octet_length(new.response::text);
begin
    insert into pintheory_sync.daily_usage(user_id, day, mutations, bytes)
        values (new.user_id, v_day, 1, v_bytes)
        on conflict (user_id, day) do update
        set mutations = pintheory_sync.daily_usage.mutations + 1,
            bytes = pintheory_sync.daily_usage.bytes + v_bytes
        where pintheory_sync.daily_usage.mutations < 2000
          and pintheory_sync.daily_usage.bytes + v_bytes <= 20000000;
    if not found then
        raise exception using errcode = 'PT429', message = 'sync_daily_limit_exceeded';
    end if;
    delete from pintheory_sync.daily_usage where user_id = new.user_id and day < v_day - 29;
    return new;
end;
$$;
alter function pintheory_sync.enforce_daily_usage() owner to postgres;
create trigger mutation_receipts_daily_usage
    before insert on pintheory_sync.mutation_receipts
    for each row execute function pintheory_sync.enforce_daily_usage();

-- Writes for one user already serialize on the account row, so this count is exact.
create function pintheory_sync.enforce_record_limit()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin
    if new.deleted_at is null and (tg_op = 'INSERT' or old.deleted_at is not null)
       and (select pg_catalog.count(*) from pintheory_sync.records r
            where r.user_id = new.user_id and r.deleted_at is null) >= 5000 then
        raise exception using errcode = 'PT429', message = 'sync_record_limit_exceeded';
    end if;
    return new;
end;
$$;
alter function pintheory_sync.enforce_record_limit() owner to postgres;
create trigger records_live_limit
    before insert or update of deleted_at on pintheory_sync.records
    for each row execute function pintheory_sync.enforce_record_limit();

revoke all on function pintheory_sync.enforce_daily_usage() from public, anon, authenticated, service_role;
revoke all on function pintheory_sync.enforce_record_limit() from public, anon, authenticated, service_role;

-- 2. Terrain tile downloads: at most 300 tiles and 1 GB per user per UTC day.
alter table pintheory_data.per_user_usage
    add column downloads integer not null default 0 check (downloads >= 0),
    add column download_bytes bigint not null default 0 check (download_bytes >= 0),
    add column provider_attempts jsonb not null default '{}'
        check (pg_catalog.jsonb_typeof(provider_attempts) = 'object');

create function public.pintheory_data_download(p_user_id uuid, p_bytes bigint)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_now timestamptz;
    v_day date;
begin
    perform pintheory_data.require_service();
    if p_user_id is null or p_bytes is null or p_bytes < 1 or p_bytes > 64000000 then
        raise exception using errcode = '22023', message = 'invalid_download';
    end if;
    v_now := pg_catalog.clock_timestamp();
    v_day := (v_now at time zone 'UTC')::date;
    if not pintheory_data.user_allowed(p_user_id) then
        return pg_catalog.jsonb_build_object('status', 'FORBIDDEN');
    end if;
    insert into pintheory_data.per_user_usage(user_id, day, downloads, download_bytes)
        values (p_user_id, v_day, 1, p_bytes)
        on conflict (user_id, day) do update
        set downloads = pintheory_data.per_user_usage.downloads + 1,
            download_bytes = pintheory_data.per_user_usage.download_bytes + p_bytes
        where pintheory_data.per_user_usage.downloads < 300
          and pintheory_data.per_user_usage.download_bytes + p_bytes <= 1000000000;
    if not found then
        return pg_catalog.jsonb_build_object('status', 'RATE_LIMIT', 'retryAfter',
            greatest(1, pg_catalog.ceil(extract(epoch from
                ((v_day + 1)::timestamp at time zone 'UTC') - v_now))::integer));
    end if;
    return pg_catalog.jsonb_build_object('status', 'OK');
end;
$$;
alter function public.pintheory_data_download(uuid, bigint) owner to postgres;
revoke all on function public.pintheory_data_download(uuid, bigint) from public, anon, authenticated, service_role;
grant execute on function public.pintheory_data_download(uuid, bigint) to service_role;

-- 3. Paid/external attempts: each user may use at most 20% of a provider's daily
-- budget (min 10, max 100), so one account cannot block new data for everyone.
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
                    where state = 'dispatched' and until > v_now) >= 4 then
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

commit;
