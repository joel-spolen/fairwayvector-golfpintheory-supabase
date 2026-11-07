-- Stage each OSM refresh separately, then activate it with a small region-row update.
begin;

alter table pintheory_data.osm_green_regions
    add column active_source text not null default 'legacy'
    check (active_source in ('legacy', 'staged'));
alter table pintheory_data.osm_green_regions alter column greens drop not null;

create table pintheory_data.osm_green_staging (
    region text not null check (region ~ '^[a-z0-9-]+(/[a-z0-9-]+)*$' and pg_catalog.length(region) <= 100),
    started_at timestamptz not null,
    osm_type text not null check (osm_type in ('way','relation')),
    osm_id bigint not null check (osm_id > 0),
    min_lat double precision not null, min_lon double precision not null,
    max_lat double precision not null, max_lon double precision not null,
    ring jsonb not null check (pg_catalog.jsonb_typeof(ring) = 'array'),
    primary key (region, started_at, osm_type, osm_id),
    check (min_lat <= max_lat and min_lon <= max_lon and max_lat - min_lat < 0.02 and max_lon - min_lon < 0.04)
);
create index osm_green_staging_box on pintheory_data.osm_green_staging (min_lat, min_lon);
create index osm_green_staging_run on pintheory_data.osm_green_staging (region, started_at);

alter table pintheory_data.osm_green_staging owner to postgres;
alter table pintheory_data.osm_green_staging enable row level security;
revoke all on pintheory_data.osm_green_staging from public, anon, authenticated, service_role;

create or replace function public.pintheory_osm_greens_import(p_region text, p_started_at timestamptz, p_rows jsonb)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
declare v_count integer;
begin
    perform pintheory_data.require_service();
    if p_region is null or p_started_at is null or pg_catalog.jsonb_typeof(p_rows) is distinct from 'array'
       or pg_catalog.jsonb_array_length(p_rows) > 1000 then
        raise exception using errcode = '22023', message = 'invalid_import';
    end if;
    insert into pintheory_data.osm_green_staging(region, started_at, osm_type, osm_id,
        min_lat, min_lon, max_lat, max_lon, ring)
    select p_region, p_started_at, r->>'type', (r->>'id')::bigint,
           (r->>'minLat')::double precision, (r->>'minLon')::double precision,
           (r->>'maxLat')::double precision, (r->>'maxLon')::double precision, r->'ring'
    from pg_catalog.jsonb_array_elements(p_rows) r
    where pg_catalog.jsonb_typeof(r->'ring') = 'array'
      and pg_catalog.jsonb_array_length(r->'ring') between 4 and 2000
    on conflict (region, started_at, osm_type, osm_id) do update set
        min_lat = excluded.min_lat, min_lon = excluded.min_lon,
        max_lat = excluded.max_lat, max_lon = excluded.max_lon, ring = excluded.ring;
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

drop function public.pintheory_osm_greens_finish(text,timestamptz,double precision,double precision,double precision,double precision);
create function public.pintheory_osm_greens_finish(p_region text, p_started_at timestamptz, p_greens integer,
    p_min_lat double precision, p_min_lon double precision, p_max_lat double precision, p_max_lon double precision)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
begin
    perform pintheory_data.require_service();
    if p_region is null or p_started_at is null or p_greens is null or p_greens < 1
       or p_min_lat is null or p_min_lon is null or p_max_lat is null or p_max_lon is null
       or not (p_min_lat <= p_max_lat and p_min_lon <= p_max_lon) then
        raise exception using errcode = '22023', message = 'invalid_import';
    end if;
    if not exists (select 1 from pintheory_data.osm_green_staging
        where region = p_region and started_at = p_started_at) then
        raise exception using errcode = '22023', message = 'empty_import';
    end if;
    insert into pintheory_data.osm_green_regions(region, min_lat, min_lon, max_lat, max_lon, greens, imported_at, active_source)
        values (p_region, p_min_lat, p_min_lon, p_max_lat, p_max_lon, p_greens, p_started_at, 'staged')
        on conflict (region) do update set min_lat = excluded.min_lat, min_lon = excluded.min_lon,
            max_lat = excluded.max_lat, max_lon = excluded.max_lon, greens = excluded.greens,
            imported_at = excluded.imported_at, active_source = 'staged';
    return p_greens;
end;
$$;

-- One-time recovery for rows written by the previous importer before its finalizer failed.
-- Only the newest unactivated legacy run is selected; bounds are supplied from Geofabrik metadata.
create function public.pintheory_osm_greens_recover(p_region text,
    p_min_lat double precision, p_min_lon double precision, p_max_lat double precision, p_max_lon double precision)
returns timestamptz language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_started_at timestamptz;
    v_active_at timestamptz;
begin
    perform pintheory_data.require_service();
    if p_region is null or p_min_lat is null or p_min_lon is null or p_max_lat is null or p_max_lon is null
       or not (p_min_lat <= p_max_lat and p_min_lon <= p_max_lon) then
        raise exception using errcode = '22023', message = 'invalid_recovery';
    end if;
    select imported_at into v_active_at
      from pintheory_data.osm_green_regions where region = p_region;
    select imported_at into v_started_at
      from pintheory_data.osm_greens where region = p_region
      order by imported_at desc limit 1;
    if v_started_at is null or (v_active_at is not null and v_started_at <= v_active_at) then
        raise exception using errcode = '22023', message = 'no_unfinalized_import';
    end if;
    insert into pintheory_data.osm_green_regions(region, min_lat, min_lon, max_lat, max_lon, greens, imported_at, active_source)
        values (p_region, p_min_lat, p_min_lon, p_max_lat, p_max_lon, null, v_started_at, 'legacy')
        on conflict (region) do update set min_lat = excluded.min_lat, min_lon = excluded.min_lon,
            max_lat = excluded.max_lat, max_lon = excluded.max_lon, greens = null,
            imported_at = excluded.imported_at, active_source = 'legacy';
    return v_started_at;
end;
$$;

-- Remove obsolete rows in bounded transactions after activation, never during finalize.
create function public.pintheory_osm_greens_cleanup(p_region text, p_limit integer default 10000)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_deleted integer;
begin
    perform pintheory_data.require_service();
    if p_region is null or p_limit is null or p_limit < 1 or p_limit > 10000 then
        raise exception using errcode = '22023', message = 'invalid_cleanup';
    end if;
    if exists (select 1 from pintheory_data.osm_green_regions
        where region = p_region and active_source = 'staged') then
        with obsolete as (
            select g.ctid
            from pintheory_data.osm_greens g
            where g.region = p_region
            order by g.imported_at
            limit p_limit
        )
        delete from pintheory_data.osm_greens g using obsolete
        where g.ctid = obsolete.ctid;
        get diagnostics v_deleted = row_count;
        if v_deleted > 0 then return v_deleted; end if;
    end if;
    with obsolete as (
        select g.ctid
        from pintheory_data.osm_green_staging g
        left join pintheory_data.osm_green_regions r on r.region = g.region
        where g.region = p_region
          and not coalesce(r.active_source = 'staged' and r.imported_at = g.started_at, false)
        order by g.started_at
        limit p_limit
    )
    delete from pintheory_data.osm_green_staging g using obsolete
    where g.ctid = obsolete.ctid;
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$$;

create or replace function public.pintheory_osm_greens(p_user_id uuid, p_min_lat double precision, p_min_lon double precision,
    p_max_lat double precision, p_max_lon double precision)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_day date := (v_now at time zone 'UTC')::date;
    v_requests integer;
begin
    perform pintheory_data.require_service();
    if not (p_min_lat <= p_max_lat and p_min_lon <= p_max_lon
            and p_max_lat - p_min_lat <= 0.1 and p_max_lon - p_min_lon <= 0.2) then
        raise exception using errcode = '22023', message = 'invalid_box';
    end if;
    if not pintheory_data.user_allowed(p_user_id) then
        return pg_catalog.jsonb_build_object('status', 'FORBIDDEN');
    end if;
    insert into pintheory_data.per_user_usage(user_id, day, requests) values (p_user_id, v_day, 1)
        on conflict (user_id, day) do update set requests = pintheory_data.per_user_usage.requests + 1
        returning requests into v_requests;
    if v_requests > 10000 then
        return pg_catalog.jsonb_build_object('status', 'RATE_LIMIT', 'retryAfter',
            greatest(1, pg_catalog.ceil(extract(epoch from ((v_day + 1)::timestamp at time zone 'UTC') - v_now))::integer));
    end if;
    return pg_catalog.jsonb_build_object('status', 'OK',
        'covered', exists (select 1 from pintheory_data.osm_green_regions
            where min_lat <= p_min_lat and max_lat >= p_max_lat and min_lon <= p_min_lon and max_lon >= p_max_lon),
        'greens', coalesce((
            select pg_catalog.jsonb_agg(active.ring order by active.osm_type, active.osm_id, active.region)
            from (
                select g.region, g.osm_type, g.osm_id, g.ring
                from pintheory_data.osm_greens g
                join pintheory_data.osm_green_regions r on r.region = g.region
                where r.active_source = 'legacy' and g.imported_at = r.imported_at
                  and g.min_lat between p_min_lat - 0.02 and p_max_lat
                  and g.min_lon between p_min_lon - 0.04 and p_max_lon
                  and g.max_lat >= p_min_lat and g.max_lon >= p_min_lon
                union all
                select g.region, g.osm_type, g.osm_id, g.ring
                from pintheory_data.osm_green_staging g
                join pintheory_data.osm_green_regions r
                  on r.region = g.region and r.active_source = 'staged' and r.imported_at = g.started_at
                where g.min_lat between p_min_lat - 0.02 and p_max_lat
                  and g.min_lon between p_min_lon - 0.04 and p_max_lon
                  and g.max_lat >= p_min_lat and g.max_lon >= p_min_lon
            ) active
        ), '[]'::jsonb));
end;
$$;

do $$ declare f text; begin
    foreach f in array array[
        'public.pintheory_osm_greens_import(text,timestamptz,jsonb)',
        'public.pintheory_osm_greens_finish(text,timestamptz,integer,double precision,double precision,double precision,double precision)',
        'public.pintheory_osm_greens_recover(text,double precision,double precision,double precision,double precision)',
        'public.pintheory_osm_greens_cleanup(text,integer)',
        'public.pintheory_osm_greens(uuid,double precision,double precision,double precision,double precision)']
    loop
        execute pg_catalog.format('alter function %s owner to postgres', f);
        execute pg_catalog.format('revoke all on function %s from public, anon, authenticated, service_role', f);
        execute pg_catalog.format('grant execute on function %s to service_role', f);
    end loop;
end $$;

commit;
