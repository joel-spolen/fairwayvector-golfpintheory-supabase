-- Our own copy of OpenStreetMap golf greens (ODbL), imported monthly from Geofabrik
-- extracts, so courses never wait on the public Overpass servers.
begin;

do $$ begin
    if pg_catalog.to_regprocedure('pintheory_data.user_allowed(uuid)') is null then
        raise exception 'shared data cache migration is required before the green catalog';
    end if;
end $$;

create table pintheory_data.osm_greens (
    osm_type text not null check (osm_type in ('way','relation')),
    osm_id bigint not null check (osm_id > 0),
    region text not null check (region ~ '^[a-z0-9-]+(/[a-z0-9-]+)*$' and pg_catalog.length(region) <= 100),
    min_lat double precision not null, min_lon double precision not null,
    max_lat double precision not null, max_lon double precision not null,
    -- [[lat, lon], ...], closed.
    ring jsonb not null check (pg_catalog.jsonb_typeof(ring) = 'array'),
    imported_at timestamptz not null,
    primary key (osm_type, osm_id),
    check (min_lat <= max_lat and min_lon <= max_lon and max_lat - min_lat < 0.02 and max_lon - min_lon < 0.04)
);
create index osm_greens_box on pintheory_data.osm_greens (min_lat, min_lon);
create index osm_greens_region on pintheory_data.osm_greens (region, imported_at);

-- A course is "covered" once a region containing it has finished importing.
create table pintheory_data.osm_green_regions (
    region text primary key check (region ~ '^[a-z0-9-]+(/[a-z0-9-]+)*$' and pg_catalog.length(region) <= 100),
    min_lat double precision not null, min_lon double precision not null,
    max_lat double precision not null, max_lon double precision not null,
    greens integer not null check (greens >= 0),
    imported_at timestamptz not null
);

alter table pintheory_data.osm_greens owner to postgres;
alter table pintheory_data.osm_green_regions owner to postgres;
alter table pintheory_data.osm_greens enable row level security;
alter table pintheory_data.osm_green_regions enable row level security;
revoke all on pintheory_data.osm_greens, pintheory_data.osm_green_regions
    from public, anon, authenticated, service_role;

-- Import: one batch of up to 1000 greens for a region run started at p_started_at.
create function public.pintheory_osm_greens_import(p_region text, p_started_at timestamptz, p_rows jsonb)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
declare v_count integer;
begin
    perform pintheory_data.require_service();
    if p_region is null or p_started_at is null or pg_catalog.jsonb_typeof(p_rows) is distinct from 'array'
       or pg_catalog.jsonb_array_length(p_rows) > 1000 then
        raise exception using errcode = '22023', message = 'invalid_import';
    end if;
    insert into pintheory_data.osm_greens(osm_type, osm_id, region, min_lat, min_lon, max_lat, max_lon, ring, imported_at)
    select r->>'type', (r->>'id')::bigint, p_region,
           (r->>'minLat')::double precision, (r->>'minLon')::double precision,
           (r->>'maxLat')::double precision, (r->>'maxLon')::double precision,
           r->'ring', p_started_at
    from pg_catalog.jsonb_array_elements(p_rows) r
    where pg_catalog.jsonb_typeof(r->'ring') = 'array'
      and pg_catalog.jsonb_array_length(r->'ring') between 4 and 2000
    on conflict (osm_type, osm_id) do update set region = excluded.region,
        min_lat = excluded.min_lat, min_lon = excluded.min_lon, max_lat = excluded.max_lat,
        max_lon = excluded.max_lon, ring = excluded.ring, imported_at = excluded.imported_at;
    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- Completes a region run: greens no longer in OpenStreetMap are removed and the region is covered.
create function public.pintheory_osm_greens_finish(p_region text, p_started_at timestamptz,
    p_min_lat double precision, p_min_lon double precision, p_max_lat double precision, p_max_lon double precision)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
declare v_count integer;
begin
    perform pintheory_data.require_service();
    if p_region is null or p_started_at is null or not (p_min_lat <= p_max_lat and p_min_lon <= p_max_lon) then
        raise exception using errcode = '22023', message = 'invalid_import';
    end if;
    delete from pintheory_data.osm_greens where region = p_region and imported_at < p_started_at;
    select pg_catalog.count(*) into v_count from pintheory_data.osm_greens where region = p_region;
    insert into pintheory_data.osm_green_regions(region, min_lat, min_lon, max_lat, max_lon, greens, imported_at)
        values (p_region, p_min_lat, p_min_lon, p_max_lat, p_max_lon, v_count, p_started_at)
        on conflict (region) do update set min_lat = excluded.min_lat, min_lon = excluded.min_lon,
            max_lat = excluded.max_lat, max_lon = excluded.max_lon, greens = excluded.greens,
            imported_at = excluded.imported_at;
    return v_count;
end;
$$;

-- Greens overlapping a course-sized box, for an allowed account.
create function public.pintheory_osm_greens(p_user_id uuid, p_min_lat double precision, p_min_lon double precision,
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
        'greens', coalesce((select pg_catalog.jsonb_agg(g.ring order by g.osm_type, g.osm_id)
            from pintheory_data.osm_greens g
            -- Greens are smaller than 0.02° × 0.04°, so their south-west corner is close to the box.
            where g.min_lat between p_min_lat - 0.02 and p_max_lat
              and g.min_lon between p_min_lon - 0.04 and p_max_lon
              and g.max_lat >= p_min_lat and g.max_lon >= p_min_lon), '[]'::jsonb));
end;
$$;

do $$ declare f text; begin
    foreach f in array array[
        'public.pintheory_osm_greens_import(text,timestamptz,jsonb)',
        'public.pintheory_osm_greens_finish(text,timestamptz,double precision,double precision,double precision,double precision)',
        'public.pintheory_osm_greens(uuid,double precision,double precision,double precision,double precision)']
    loop
        execute pg_catalog.format('alter function %s owner to postgres', f);
        execute pg_catalog.format('revoke all on function %s from public, anon, authenticated, service_role', f);
        execute pg_catalog.format('grant execute on function %s to service_role', f);
    end loop;
end $$;

commit;
