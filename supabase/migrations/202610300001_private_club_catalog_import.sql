-- Private, staged import of GolfAPI club/course summaries.
-- Does not enable app reads/search or make provider calls. No data in migrations.
begin;

do $$ begin
    if pg_catalog.to_regclass('pintheory_sync.accounts') is null then
        raise exception 'account/sync foundation migrations are required';
    end if;
end $$;

create schema pintheory_catalog authorization postgres;
revoke all on schema pintheory_catalog from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_catalog
    revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_catalog
    revoke all on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pintheory_catalog
    revoke all on sequences from public, anon, authenticated, service_role;

create table pintheory_catalog.imports (
    import_id text primary key check (import_id ~ '^[a-f0-9]{64}$'),
    source_sha256 text not null check (source_sha256 ~ '^[a-f0-9]{64}$'),
    dataset_version text not null check (pg_catalog.octet_length(dataset_version) between 1 and 100),
    expected_clubs integer not null check (expected_clubs between 1 and 1000000),
    expected_courses integer not null check (expected_courses between 0 and 5000000),
    expected_chunks integer not null check (expected_chunks between 1 and 100000),
    status text not null default 'staging' check (status in ('staging','complete')),
    created_at timestamptz not null default pg_catalog.clock_timestamp(),
    completed_at timestamptz
);
alter table pintheory_catalog.imports owner to postgres;
alter table pintheory_catalog.imports enable row level security;

create table pintheory_catalog.chunks (
    import_id text not null references pintheory_catalog.imports(import_id) on delete cascade,
    chunk_no integer not null check (chunk_no > 0),
    chunk_sha256 text not null check (chunk_sha256 ~ '^[a-f0-9]{64}$'),
    clubs jsonb not null check (pg_catalog.jsonb_typeof(clubs) = 'array'
        and pg_catalog.jsonb_array_length(clubs) between 1 and 100
        and pg_catalog.octet_length(clubs::text) <= 524288),
    club_count integer not null check (club_count between 1 and 100),
    course_count integer not null check (course_count between 0 and 10000),
    created_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (import_id, chunk_no),
    check (club_count = pg_catalog.jsonb_array_length(clubs))
);
alter table pintheory_catalog.chunks owner to postgres;
alter table pintheory_catalog.chunks enable row level security;

create table pintheory_catalog.active_import (
    singleton boolean primary key default true check (singleton),
    import_id text not null references pintheory_catalog.imports(import_id),
    activated_at timestamptz not null default pg_catalog.clock_timestamp()
);
alter table pintheory_catalog.active_import owner to postgres;
alter table pintheory_catalog.active_import enable row level security;

create function pintheory_catalog.require_service()
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode = '42501', message = 'service_role_required';
    end if;
end;
$$;
alter function pintheory_catalog.require_service() owner to postgres;

create function public.pintheory_catalog_import_begin(
    p_import_id text, p_source_sha256 text, p_dataset_version text,
    p_expected_clubs integer, p_expected_courses integer, p_expected_chunks integer
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare v_import pintheory_catalog.imports%rowtype;
begin
    perform pintheory_catalog.require_service();
    if p_import_id is null or p_source_sha256 is null or p_dataset_version is null
       or p_expected_clubs is null or p_expected_courses is null or p_expected_chunks is null
       or p_import_id !~ '^[a-f0-9]{64}$' or p_source_sha256 !~ '^[a-f0-9]{64}$'
       or pg_catalog.octet_length(p_dataset_version) not between 1 and 100
       or p_expected_clubs not between 1 and 1000000
       or p_expected_courses not between 0 and 5000000
       or p_expected_chunks not between 1 and 100000 then
        raise exception using errcode = '22023', message = 'invalid_catalog_import_manifest';
    end if;
    insert into pintheory_catalog.imports(import_id, source_sha256, dataset_version,
        expected_clubs, expected_courses, expected_chunks)
    values (p_import_id, p_source_sha256, p_dataset_version,
        p_expected_clubs, p_expected_courses, p_expected_chunks)
    on conflict (import_id) do nothing;
    select * into strict v_import from pintheory_catalog.imports where import_id = p_import_id for update;
    if v_import.source_sha256 <> p_source_sha256 or v_import.dataset_version <> p_dataset_version
       or v_import.expected_clubs <> p_expected_clubs or v_import.expected_courses <> p_expected_courses
       or v_import.expected_chunks <> p_expected_chunks then
        raise exception using errcode = '22023', message = 'catalog_import_id_conflict';
    end if;
    return pg_catalog.jsonb_build_object('status',v_import.status,
        'receivedChunks',(select pg_catalog.count(*) from pintheory_catalog.chunks where import_id=p_import_id),
        'expectedChunks',v_import.expected_chunks);
end;
$$;
alter function public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer) owner to postgres;

create function public.pintheory_catalog_import_chunk(
    p_import_id text, p_chunk_no integer, p_chunk_sha256 text, p_clubs jsonb, p_course_count integer
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_import pintheory_catalog.imports%rowtype;
    v_existing pintheory_catalog.chunks%rowtype;
    v_club jsonb;
    v_course jsonb;
    v_id text;
    v_count integer;
begin
    perform pintheory_catalog.require_service();
    if p_import_id is null or p_chunk_no is null or p_chunk_sha256 is null or p_clubs is null
       or p_course_count is null or p_import_id !~ '^[a-f0-9]{64}$'
       or p_chunk_sha256 !~ '^[a-f0-9]{64}$' or pg_catalog.jsonb_typeof(p_clubs) <> 'array'
       or pg_catalog.jsonb_array_length(p_clubs) not between 1 and 100
       or pg_catalog.octet_length(p_clubs::text) > 524288 or p_course_count not between 0 and 10000 then
        raise exception using errcode = '22023', message = 'invalid_catalog_chunk';
    end if;
    select * into v_import from pintheory_catalog.imports where import_id=p_import_id for update;
    if not found or p_chunk_no > v_import.expected_chunks then
        raise exception using errcode = '22023', message = 'catalog_import_not_staging';
    end if;
    v_count := pg_catalog.jsonb_array_length(p_clubs);
    for v_club in select value from pg_catalog.jsonb_array_elements(p_clubs) loop
          if pg_catalog.jsonb_typeof(v_club) is distinct from 'object'
              or pg_catalog.jsonb_typeof(v_club->'clubID') is distinct from 'string'
           or pg_catalog.octet_length(v_club->>'clubID') not between 1 and 100
           or pg_catalog.jsonb_typeof(v_club->'clubName') is distinct from 'string'
           or pg_catalog.octet_length(v_club->>'clubName') not between 1 and 500
           or pg_catalog.jsonb_typeof(v_club->'courses') is distinct from 'array'
           or pg_catalog.jsonb_array_length(v_club->'courses') > 100 then
            raise exception using errcode = '22023', message = 'invalid_catalog_club';
        end if;
        for v_course in select value from pg_catalog.jsonb_array_elements(v_club->'courses') loop
                if pg_catalog.jsonb_typeof(v_course) is distinct from 'object'
                    or pg_catalog.jsonb_typeof(v_course->'courseID') is distinct from 'string'
               or pg_catalog.octet_length(v_course->>'courseID') not between 1 and 100
               or pg_catalog.jsonb_typeof(v_course->'courseName') is distinct from 'string'
               or pg_catalog.octet_length(v_course->>'courseName') not between 1 and 500 then
                raise exception using errcode = '22023', message = 'invalid_catalog_course';
            end if;
        end loop;
    end loop;
    if (select pg_catalog.sum(pg_catalog.jsonb_array_length(c.value->'courses'))
        from pg_catalog.jsonb_array_elements(p_clubs) as c(value)) <> p_course_count then
        raise exception using errcode = '22023', message = 'catalog_chunk_course_count_mismatch';
    end if;
    select * into v_existing from pintheory_catalog.chunks
        where import_id=p_import_id and chunk_no=p_chunk_no;
    if found then
        if v_existing.chunk_sha256 <> p_chunk_sha256 or v_existing.clubs <> p_clubs
           or v_existing.course_count <> p_course_count then
            raise exception using errcode = '22023', message = 'catalog_chunk_replay_conflict';
        end if;
        return pg_catalog.jsonb_build_object('status','already_received','chunk',p_chunk_no,
            'clubs',v_existing.club_count,'courses',v_existing.course_count);
    end if;
    if v_import.status <> 'staging' then
        raise exception using errcode = '22023', message = 'catalog_import_not_staging';
    end if;
    insert into pintheory_catalog.chunks(import_id,chunk_no,chunk_sha256,clubs,club_count,course_count)
        values (p_import_id,p_chunk_no,p_chunk_sha256,p_clubs,v_count,p_course_count);
    return pg_catalog.jsonb_build_object('status','received','chunk',p_chunk_no,
        'clubs',v_count,'courses',p_course_count);
end;
$$;
alter function public.pintheory_catalog_import_chunk(text,integer,text,jsonb,integer) owner to postgres;

create function public.pintheory_catalog_import_finalize(p_import_id text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_import pintheory_catalog.imports%rowtype;
    v_chunks bigint;
    v_clubs bigint;
    v_courses bigint;
    v_duplicate_clubs boolean;
begin
    perform pintheory_catalog.require_service();
    if p_import_id is null or p_import_id !~ '^[a-f0-9]{64}$' then
        raise exception using errcode = '22023', message = 'invalid_catalog_import_id';
    end if;
    select * into v_import from pintheory_catalog.imports where import_id=p_import_id for update;
    if not found then raise exception using errcode = '22023', message = 'catalog_import_not_found'; end if;
    select pg_catalog.count(*), coalesce(pg_catalog.sum(club_count),0),
           coalesce(pg_catalog.sum(course_count),0)
    into v_chunks,v_clubs,v_courses from pintheory_catalog.chunks where import_id=p_import_id;
    if v_chunks <> v_import.expected_chunks or v_clubs <> v_import.expected_clubs
       or v_courses <> v_import.expected_courses then
        raise exception using errcode = '22023', message = 'catalog_import_incomplete';
    end if;
    select exists(select 1 from (
        select c.value->>'clubID' as id from pintheory_catalog.chunks ch
        cross join lateral pg_catalog.jsonb_array_elements(ch.clubs) as c(value) where ch.import_id=p_import_id
        group by c.value->>'clubID' having pg_catalog.count(*) > 1
    ) duplicate_ids) into v_duplicate_clubs;
    if v_duplicate_clubs then raise exception using errcode='22023', message='catalog_duplicate_club_id'; end if;
    if v_import.status <> 'complete' then
        update pintheory_catalog.imports set status='complete',completed_at=pg_catalog.clock_timestamp()
            where import_id=p_import_id;
        insert into pintheory_catalog.active_import(singleton,import_id,activated_at)
            values(true,p_import_id,pg_catalog.clock_timestamp())
            on conflict(singleton) do update set import_id=excluded.import_id,activated_at=excluded.activated_at;
    end if;
    return pg_catalog.jsonb_build_object('status','complete','clubs',v_clubs,
        'courses',v_courses,'chunks',v_chunks,'privateOnly',true);
end;
$$;
alter function public.pintheory_catalog_import_finalize(text) owner to postgres;

-- No public, anonymous or authenticated access; no user catalog-search RPC.
revoke all on all tables in schema pintheory_catalog from public, anon, authenticated, service_role;
revoke all on all functions in schema pintheory_catalog from public, anon, authenticated, service_role;
revoke all on all sequences in schema pintheory_catalog from public, anon, authenticated, service_role;
revoke all on function public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer)
    from public, anon, authenticated, service_role;
revoke all on function public.pintheory_catalog_import_chunk(text,integer,text,jsonb,integer)
    from public, anon, authenticated, service_role;
revoke all on function public.pintheory_catalog_import_finalize(text)
    from public, anon, authenticated, service_role;
grant execute on function public.pintheory_catalog_import_begin(text,text,text,integer,integer,integer) to service_role;
grant execute on function public.pintheory_catalog_import_chunk(text,integer,text,jsonb,integer) to service_role;
grant execute on function public.pintheory_catalog_import_finalize(text) to service_role;

commit;