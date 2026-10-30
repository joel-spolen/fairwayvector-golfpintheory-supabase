-- Expand catalog search query from 20 to 200 Unicode characters.
-- Edge validation caps code points at 200; SQL caps UTF-8 bytes at 800.
begin;

do $$ begin
    if pg_catalog.to_regprocedure('public.pintheory_catalog_search(uuid,text,text,text,integer,integer)') is null then
        raise exception 'catalog search migration 202610300002 is required';
    end if;
end $$;

create or replace function public.pintheory_catalog_search(
    p_user_id uuid, p_query text, p_country text, p_state text,
    p_page integer default 1, p_page_size integer default 50
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
    v_query text := pg_catalog.lower(normalize(pg_catalog.btrim(coalesce(p_query,'')), NFC));
    v_country text := pg_catalog.lower(normalize(pg_catalog.btrim(coalesce(p_country,'')), NFC));
    v_state text := pg_catalog.lower(normalize(pg_catalog.btrim(coalesce(p_state,'')), NFC));
    v_day date := (pg_catalog.clock_timestamp() at time zone 'UTC')::date;
    v_allowed boolean;
    v_requests integer;
    v_result jsonb;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception using errcode = '42501', message = 'service_role_required';
    end if;
    if p_user_id is null or p_query is null or p_country is null or p_state is null
       or pg_catalog.octet_length(p_query) > 800 or pg_catalog.octet_length(p_country) > 480
       or pg_catalog.octet_length(p_state) > 480
       or p_page is null or p_page not between 1 and 1000
       or p_page_size is null or p_page_size not between 1 and 50
       or (v_query = '' and v_country = '' and v_state = '') then
        raise exception using errcode = '22023', message = 'invalid_catalog_search';
    end if;

    select pintheory_data.user_allowed(p_user_id) into v_allowed;
    if not coalesce(v_allowed,false) then
        raise exception using errcode = '42501', message = 'catalog_account_not_allowed';
    end if;
    insert into pintheory_catalog.search_usage(user_id,day,requests)
        values(p_user_id,v_day,1)
        on conflict(user_id,day) do update
            set requests=pintheory_catalog.search_usage.requests+1
            where pintheory_catalog.search_usage.requests < 1000
        returning requests into v_requests;
    if not found then
        raise exception using errcode = '54000', message = 'catalog_search_rate_limited';
    end if;
    delete from pintheory_catalog.search_usage where user_id=p_user_id and day < v_day-29;

    with active as materialized (
        select i.import_id, i.dataset_version
        from pintheory_catalog.active_import a
        join pintheory_catalog.imports i on i.import_id=a.import_id and i.status='complete'
        where a.singleton
    ), catalog_clubs as materialized (
        select ch.import_id, c.value as club
        from active a
        join pintheory_catalog.chunks ch on ch.import_id=a.import_id
        cross join lateral pg_catalog.jsonb_array_elements(ch.clubs) as c(value)
    ), matching as materialized (
        select cc.club
        from catalog_clubs cc
        where (v_country='' or pg_catalog.lower(normalize(pg_catalog.btrim(coalesce(cc.club->>'country','')),NFC)) = v_country)
          and (v_state='' or pg_catalog.lower(normalize(pg_catalog.btrim(coalesce(cc.club->>'state','')),NFC)) = v_state)
          and (v_query='' or pg_catalog.strpos(pg_catalog.lower(normalize(coalesce(cc.club->>'clubName',''),NFC)),v_query)>0
            or exists (
                select 1 from pg_catalog.jsonb_array_elements(cc.club->'courses') as course(value)
                where pg_catalog.strpos(pg_catalog.lower(normalize(coalesce(course.value->>'courseName',''),NFC)),v_query)>0
            ))
    ), totals as (
        select pg_catalog.count(*)::integer as total from matching
    ), page_clubs as (
        select pg_catalog.jsonb_build_object(
            'clubID',m.club->'clubID', 'clubName',m.club->'clubName',
            'city',m.club->'city', 'state',m.club->'state', 'country',m.club->'country',
            'courses',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                'courseID',course.value->'courseID','courseName',course.value->'courseName',
                'numHoles',course.value->'numHoles','hasGPS',course.value->'hasGPS',
                'timestampUpdated',course.value->'timestampUpdated')
                order by pg_catalog.lower(course.value->>'courseName'),course.value->>'courseID')
                from pg_catalog.jsonb_array_elements(m.club->'courses') as course(value)),'[]'::jsonb)
        ) as club
        from matching m
        order by pg_catalog.lower(m.club->>'clubName'), m.club->>'clubID'
        limit p_page_size offset (p_page-1)*p_page_size
    )
    select pg_catalog.jsonb_build_object(
        'datasetVersion',(select dataset_version from active),
        'clubs',coalesce((select pg_catalog.jsonb_agg(club order by pg_catalog.lower(club->>'clubName'),club->>'clubID') from page_clubs),'[]'::jsonb),
        'numClubs',(select pg_catalog.count(*)::integer from page_clubs),
        'numAllClubs',totals.total,
        'page',p_page,
        'pageSize',p_page_size,
        'hasMore',((p_page::bigint*p_page_size)<totals.total)
    ) into v_result from totals;
    if v_result->>'datasetVersion' is null then
        raise exception using errcode = '55000', message = 'catalog_not_ready';
    end if;
    return v_result;
end;
$$;
alter function public.pintheory_catalog_search(uuid,text,text,text,integer,integer) owner to postgres;
revoke all on function public.pintheory_catalog_search(uuid,text,text,text,integer,integer)
    from public, anon, authenticated, service_role;
grant execute on function public.pintheory_catalog_search(uuid,text,text,text,integer,integer) to service_role;

commit;
